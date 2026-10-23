// Package store 是中转的 SQLite 持久层。
//
// 职责：打开库、设置连接级 PRAGMA、建表与版本迁移，以及全部仓储方法（账户、电脑、
// 邀请码、配对码、设备、账户状态、用量）。SQL 只允许出现在本包，HTTP 与 WS 层
// 不得出现裸 SQL。
//
// 并发模型按 DESIGN §6：写走一条被独占的连接并串行化，读走连接池；写事务统一
// BEGIN IMMEDIATE，进程内不会互撞写锁。
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	// BusyTimeoutMS 是 SQLite 的锁等待上限，与 Python 版
	// sqlite3.connect(timeout=15) 的 15 秒对齐（2026-10-23 决策）。
	//
	// 写事务走专用的 BEGIN IMMEDIATE 连接，进程内不会再撞自己的写锁；这个超时
	// 覆盖的是"另一个进程（admin CLI、备份、运维脚本）持有写锁"的情况。
	BusyTimeoutMS = 15000

	// maxOpenConns = 4 条读连接 + 1 条专用写连接（DESIGN §6）。
	maxOpenConns = 5
)

// Store 持有数据库句柄与一条专用写连接。
//
// 读走 *sql.DB 的连接池（最多 4 条并发），写只走 write 这一条被独占的连接并在
// writeMu 下串行化；所有写事务统一 BEGIN IMMEDIATE。
type Store struct {
	path string
	// db / write 是加了计时与 SQL 名称的包装；仓储方法看到的接口不变。
	db      *observedDB
	write   *observedConn
	writeMu sync.Mutex
	version int
	observe observer

	closeOnce sync.Once
	closeErr  error
}

// execQuerier 是写事务内可用的最小接口；*sql.Conn 满足它。
type execQuerier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// Open 打开（必要时创建）数据库，建表并迁移到当前 schema 版本。
func Open(path string) (*Store, error) {
	return OpenContext(context.Background(), path)
}

// OpenContext 是 Open 的上下文版本；ctx 只作用于打开与迁移阶段。
func OpenContext(ctx context.Context, path string) (*Store, error) {
	return OpenContextWith(ctx, path, Options{})
}

// OpenWith 与 Open 相同，但带可观测性配置（日志器与慢查询阈值）。
//
// serve 用它把库层的慢查询/忙等日志接到进程的 JSON 日志器上；admin/purge 等
// 一次性命令用 Open 即可（默认 slog.Default）。
func OpenWith(path string, options Options) (*Store, error) {
	return OpenContextWith(context.Background(), path, options)
}

// OpenContextWith 是 OpenWith 的上下文版本。
func OpenContextWith(ctx context.Context, path string, options Options) (*Store, error) {
	abs, err := preparePath(path)
	if err != nil {
		return nil, err
	}
	observed := newObserver(options)

	db, err := sql.Open(driverName, dsn(abs))
	if err != nil {
		return nil, fmt.Errorf("store: 打开 %s: %w", abs, err)
	}
	// 4 条读连接 + 1 条专用写连接（DESIGN §6）。
	db.SetMaxOpenConns(maxOpenConns)
	db.SetMaxIdleConns(maxOpenConns)

	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("store: 打开 %s: %w", abs, err)
	}

	// WAL 是库文件级属性，只在打开时设一次并回读确认。
	// busy_timeout / foreign_keys 是每连接属性，由 DSN 在每个新连接上设置。
	if err := ensureWAL(ctx, db); err != nil {
		db.Close()
		return nil, err
	}

	version, err := initSchema(ctx, db)
	if err != nil {
		db.Close()
		return nil, err
	}

	// 专用写连接：从池里取一条并一直持有，进程内的写全部走它。取不到说明库
	// 已经不可用，不带着半套连接启动。
	write, err := db.Conn(ctx)
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("store: 取写连接: %w", err)
	}
	return &Store{
		path:    abs,
		db:      &observedDB{DB: db, observer: observed},
		write:   &observedConn{Conn: write, observer: observed},
		version: version, observe: observed,
	}, nil
}

// writeTx 在一个 BEGIN IMMEDIATE 事务里执行 fn。
//
// 事务由专用写连接承载并全程持有 writeMu：同一时刻只有一个写事务，且它一开始
// 就拿写锁（不是"先读后升级"）。fn 返回错误、提交失败或 panic 都会回滚；回滚走
// 自己的 context，避免调用方的 ctx 已取消导致事务悬挂。
func (s *Store) writeTx(ctx context.Context, fn func(context.Context, execQuerier) error) (err error) {
	start := time.Now()
	defer func() { s.observe.observeTx(ctx, "write transaction", start, err) }()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()

	// Close 会把专用写连接置空；并发到达的写（周期冲盘、对账）必须得到错误，
	// 不能在 nil *sql.Conn 上调用方法（那是 panic，不是可处理的失败）。
	if s.write == nil {
		return errors.New("store: closed")
	}
	if _, err := s.write.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return fmt.Errorf("store: BEGIN IMMEDIATE: %w", err)
	}
	rollback := func() {
		_, _ = s.write.ExecContext(context.Background(), "ROLLBACK")
	}
	committed := false
	defer func() {
		if !committed {
			rollback()
		}
	}()

	if err := fn(ctx, s.write); err != nil {
		return err
	}
	if _, err := s.write.ExecContext(ctx, "COMMIT"); err != nil {
		return fmt.Errorf("store: 提交写事务: %w", err)
	}
	committed = true
	return nil
}

// preparePath 解析绝对路径并建好目录（与 Python 版 os.makedirs(exist_ok=True) 一致）。
func preparePath(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", errors.New("store: db 路径为空")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("store: 解析路径 %q: %w", path, err)
	}
	if dir := filepath.Dir(abs); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return "", fmt.Errorf("store: 创建目录 %s: %w", dir, err)
		}
	}
	return abs, nil
}

// dsn 拼出驱动连接串。
//
// 参数名取两个驱动都认的那一套（modernc 兼容 mattn 的简写），所以换驱动不用改这里：
//   - _busy_timeout：SQLite 锁等待上限（毫秒）；
//   - _foreign_keys=1：每个新连接都打开外键约束（库文件不记住这条）。
//
// 不用 file: 前缀：两个驱动在没有该前缀时都按第一个 '?' 切开查询串，路径里的空格
// 无需转义；带前缀会按 SQLite URI 规则解析，反而要求转义。
func dsn(absPath string) string {
	return fmt.Sprintf("%s?_busy_timeout=%d&_foreign_keys=1", absPath, BusyTimeoutMS)
}

// ensureWAL 把库切到 WAL 并回读确认；切不过去就在启动时报错，不带着未知日志模式跑。
func ensureWAL(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, "PRAGMA journal_mode=WAL"); err != nil {
		return fmt.Errorf("store: 设置 journal_mode=WAL: %w", err)
	}
	var mode string
	if err := db.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&mode); err != nil {
		return fmt.Errorf("store: 读 journal_mode: %w", err)
	}
	if !strings.EqualFold(mode, "wal") {
		return fmt.Errorf("store: journal_mode = %q，期望 wal（库只读或被占用？）", mode)
	}
	return nil
}

// initSchema 建表并把库升到 SchemaVersion，返回打开后的实际版本。
//
// 顺序与 Python 版 Store.__init__ 一致：先 SCHEMA（新库一次建全，老库补新表），
// 再按 user_version 补 IF NOT EXISTS 表达不了的部分（加列、改约束、回填）。
// 两步包在同一个 BEGIN IMMEDIATE 事务里：半途失败不会留下"版本已记、结构没改"的库。
//
// 版本比这份代码新时保持原样：回滚到旧版不能把库"降级"（Python 版同样处理）。
func initSchema(ctx context.Context, db *sql.DB) (int, error) {
	conn, err := db.Conn(ctx)
	if err != nil {
		return 0, fmt.Errorf("store: 取迁移连接: %w", err)
	}
	defer conn.Close()

	if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return 0, fmt.Errorf("store: BEGIN IMMEDIATE: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			// ctx 可能已取消；回滚必须走自己的 context。
			_, _ = conn.ExecContext(context.Background(), "ROLLBACK")
		}
	}()

	var current int
	if err := conn.QueryRowContext(ctx, "PRAGMA user_version").Scan(&current); err != nil {
		return 0, fmt.Errorf("store: 读 user_version: %w", err)
	}

	if _, err := conn.ExecContext(ctx, Schema); err != nil {
		return 0, fmt.Errorf("store: 建表: %w", err)
	}

	for _, step := range migrations {
		if step.version <= current || step.version > SchemaVersion {
			continue
		}
		if err := step.apply(ctx, conn); err != nil {
			return 0, fmt.Errorf("store: 迁移 %d: %w", step.version, err)
		}
		// PRAGMA user_version 不支持绑定参数。
		stamp := fmt.Sprintf("PRAGMA user_version = %d", step.version)
		if _, err := conn.ExecContext(ctx, stamp); err != nil {
			return 0, fmt.Errorf("store: 记录版本 %d: %w", step.version, err)
		}
	}

	if _, err := conn.ExecContext(ctx, "COMMIT"); err != nil {
		return 0, fmt.Errorf("store: 提交迁移: %w", err)
	}
	committed = true

	if current > SchemaVersion {
		return current, nil
	}
	return SchemaVersion, nil
}

// Path 是库的绝对路径。
func (s *Store) Path() string { return s.path }

// Version 是打开时读到的 schema 版本，可能高于 SchemaVersion（库由更新的构建创建）。
func (s *Store) Version() int { return s.version }

// Ping 检查数据库仍然可用。
func (s *Store) Ping(ctx context.Context) error {
	if err := s.db.PingContext(ctx); err != nil {
		return fmt.Errorf("store: ping: %w", err)
	}
	return nil
}

// Close 关闭数据库。可重复调用。
//
// 先还回专用写连接再关池；顺序反了会让 write.Close 报 "database is closed"。
func (s *Store) Close() error {
	s.closeOnce.Do(func() {
		s.writeMu.Lock()
		defer s.writeMu.Unlock()
		if s.write != nil {
			if err := s.write.Close(); err != nil {
				s.closeErr = err
			}
			s.write = nil
		}
		if err := s.db.Close(); err != nil && s.closeErr == nil {
			s.closeErr = err
		}
	})
	return s.closeErr
}

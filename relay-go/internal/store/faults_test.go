package store

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
)

// 这个文件是 SQLite 故障注入的仓储层一半：只读库、只读目录、外部写锁（等待与
// 超时）以及对应的日志。HTTP 层把同一组真实错误映射成 JSON 信封的用例在
// internal/httpapi/faults_test.go；两边用同一种错误来源（SQLite 自己给的），
// 不手写错误字符串。
//
// 不碰真实数据：每个用例一个 t.TempDir() 库；只读权限在 cleanup 里恢复。

// openReadOnly 用 SQLite 的 `mode=ro` 打开同一个库文件。
//
// 这是 SQLite 官方的只读打开方式：写入会得到真实的 SQLITE_READONLY，而不是
// 测试自己编一个 "readonly database" 错误。驱动名取当前构建链进去的那个
// （见 driver_cgo.go / driver_nocgo.go），与生产同一条路径。
func openReadOnly(t *testing.T, path string) *sql.DB {
	t.Helper()
	db, err := sql.Open(driverName, "file:"+path+"?mode=ro")
	if err != nil {
		t.Fatalf("以只读方式打开库: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.Ping(); err != nil {
		t.Fatalf("只读连接 ping: %v", err)
	}
	return db
}

// TestReadOnlyDatabaseRejectsWritesWithRealSQLiteError 取证"只读库会给出哪一类
// 错误"：这是 HTTP 层映射的输入。
//
// 断言两条：错误文案来自 SQLite（含 readonly），且 **不能** 被 IsBusy 认成
// busy——只读是运维事实，重试不会恢复；把它映射成 503 会误导客户端反复重试。
func TestReadOnlyDatabaseRejectsWritesWithRealSQLiteError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.db")
	st, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	account, err := st.CreateAccount(context.Background(), "readonly-probe")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	if err := st.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	readOnly := openReadOnly(t, path)
	var count int
	if err := readOnly.QueryRow("SELECT COUNT(*) FROM accounts").Scan(&count); err != nil {
		t.Fatalf("只读连接读不到数据: %v", err)
	}
	if count != 1 {
		t.Fatalf("读到的账户数 = %d", count)
	}
	_, writeErr := readOnly.Exec(
		"UPDATE accounts SET name = ? WHERE accountId = ?", "x", account.AccountID)
	if writeErr == nil {
		t.Fatal("只读连接竟然写成功了")
	}
	if !strings.Contains(strings.ToLower(writeErr.Error()), "readonly") {
		t.Fatalf("写入错误不是 SQLITE_READONLY：%v", writeErr)
	}
	if IsBusy(writeErr) {
		t.Fatalf("只读被误判成 busy（会被映射成 503）：%v", writeErr)
	}
	// 报告里要引用原始文案；测试输出里留一行，便于复现时对照驱动差异。
	t.Logf("只读写入的 SQLite 错误：%v", writeErr)
}

// TestReadOnlyDirectoryFailsFastOnOpen 覆盖"目录不可写、库文件只读"的启动路径。
//
// 期望：Open 返回错误（不带着半可用的库启动），错误里能看出是 journal_mode/
// 只读/打不开，而不是一句无上下文的 EOF。运行中的进程不会被 chmod 影响已持有
// 的文件描述符，所以这个故障只在启动时可构造（见报告里的 blocked/边界说明）。
func TestReadOnlyDirectoryFailsFastOnOpen(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.db")
	st, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := st.CreateAccount(context.Background(), "readonly-dir"); err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	if err := st.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	if err := os.Chmod(path, 0o444); err != nil {
		t.Fatalf("chmod 库文件: %v", err)
	}
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatalf("chmod 目录: %v", err)
	}
	t.Cleanup(func() {
		// 恢复写权限，否则 t.TempDir 的清理会失败。
		_ = os.Chmod(dir, 0o755)
		_ = os.Chmod(path, 0o644)
	})

	opened, err := Open(path)
	if err == nil {
		_ = opened.Close()
		t.Fatal("只读目录里的库竟然打开成功：会以读得出、写不进的半可用状态启动")
	}
	message := strings.ToLower(err.Error())
	explained := strings.Contains(message, "journal_mode") ||
		strings.Contains(message, "read-only") ||
		strings.Contains(message, "readonly") ||
		strings.Contains(message, "unable to open")
	if !explained {
		t.Fatalf("启动错误没有说明是库不可写：%v", err)
	}
	t.Logf("只读目录下 Open 的错误：%v", err)
}

// lockWrite 是"另一个进程"持写锁：独立连接 + BEGIN IMMEDIATE。
//
// 返回的 release 幂等（回滚并关闭连接）；用例失败时 cleanup 也会调用它。
func lockWrite(t *testing.T, path string) (release func()) {
	t.Helper()
	db, err := sql.Open(driverName, dsn(path))
	if err != nil {
		t.Fatalf("打开加锁连接: %v", err)
	}
	conn, err := db.Conn(context.Background())
	if err != nil {
		db.Close()
		t.Fatalf("取加锁连接: %v", err)
	}
	if _, err := conn.ExecContext(context.Background(), "BEGIN IMMEDIATE"); err != nil {
		conn.Close()
		db.Close()
		t.Fatalf("BEGIN IMMEDIATE: %v", err)
	}
	released := false
	release = func() {
		if released {
			return
		}
		released = true
		_, _ = conn.ExecContext(context.Background(), "ROLLBACK")
		_ = conn.Close()
		_ = db.Close()
	}
	t.Cleanup(release)
	return release
}

// TestWriteTransactionWaitsForAnExternalWriteLock 覆盖"请求等待"：写请求在
// 外部写锁上等，锁一放开就成功，日志里留下一条慢事务记录（带 requestId）。
func TestWriteTransactionWaitsForAnExternalWriteLock(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.db")
	buffer := &observeBuffer{}
	st, err := OpenWith(path, Options{
		Logger:    slog.New(slog.NewJSONHandler(buffer, nil)),
		SlowQuery: 10 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("OpenWith: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	release := lockWrite(t, path)
	released := make(chan struct{})
	go func() {
		time.Sleep(250 * time.Millisecond)
		release()
		close(released)
	}()

	ctx := reqctx.With(context.Background(), reqctx.NewScope("trace-wait"))
	started := time.Now()
	if _, err := st.CreateAccount(ctx, "waited"); err != nil {
		t.Fatalf("持锁 250ms 后写事务仍失败: %v", err)
	}
	elapsed := time.Since(started)
	<-released
	if elapsed < 200*time.Millisecond {
		t.Fatalf("写事务只用了 %v：没有在外部写锁上等待", elapsed)
	}

	// 日志口径：事务耗时（不只是单条语句）进 slow transaction，带 tx=true 与
	// requestId，且不泄漏 SQL 全文或参数。
	entries := buffer.entries(t)
	var slowTx map[string]any
	for _, entry := range entries {
		if entry["msg"] == "relay: slow database transaction" {
			slowTx = entry
			break
		}
	}
	if slowTx == nil {
		t.Fatalf("没有 slow database transaction 日志：%v", entries)
	}
	if slowTx["tx"] != true {
		t.Fatalf("慢事务日志缺 tx=true：%v", slowTx)
	}
	if slowTx["requestId"] != "trace-wait" {
		t.Fatalf("慢事务日志 requestId = %v", slowTx["requestId"])
	}
	if slowTx["sql"] != "write transaction" {
		t.Fatalf("慢事务日志 sql 名称 = %v", slowTx["sql"])
	}
	if duration, _ := slowTx["duration_ms"].(float64); duration < 200 {
		t.Fatalf("慢事务日志 duration_ms = %v，期望 >=200", slowTx["duration_ms"])
	}
	for _, entry := range entries {
		if entry["msg"] == "relay: database is busy" {
			t.Fatalf("等到了锁却记了 busy：%v", entry)
		}
	}
	// 只记 SQL 名称，不记语句正文。
	if body, _ := slowTx["sql"].(string); strings.Contains(body, "INSERT") {
		t.Fatalf("日志带上了 SQL 正文：%v", slowTx)
	}
}

// TestBusyTimeoutSurfacesAsBusyAndIsLogged 覆盖"超时"：外部写锁超过
// busy_timeout 后写事务失败，错误被归类为 busy（HTTP 层据此回 503），日志有
// 一条带 tx=true 与 requestId 的 busy 记录。
//
// 生产 busy_timeout 是 15 秒（BusyTimeoutMS，对齐 Python 的 timeout=15）。用例
// 把**这条连接的** PRAGMA 压到 20ms 只是为了覆盖超时分支本身；15 秒等待不产生
// 额外语义，只会把套件拖长（黑盒的写锁探针覆盖了真实 2 秒等待）。
func TestBusyTimeoutSurfacesAsBusyAndIsLogged(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.db")
	buffer := &observeBuffer{}
	st, err := OpenWith(path, Options{
		Logger:    slog.New(slog.NewJSONHandler(buffer, nil)),
		SlowQuery: time.Hour,
	})
	if err != nil {
		t.Fatalf("OpenWith: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	ctx := reqctx.With(context.Background(), reqctx.NewScope("trace-busy"))
	// 专用写连接上的 PRAGMA 是连接级设置，不影响池里其他连接。
	if _, err := st.write.ExecContext(ctx, "PRAGMA busy_timeout = 20"); err != nil {
		t.Fatalf("收紧 busy_timeout: %v", err)
	}
	release := lockWrite(t, path)
	defer release()

	started := time.Now()
	_, err = st.CreateAccount(ctx, "blocked")
	elapsed := time.Since(started)
	if err == nil {
		t.Fatal("外部写锁一直持有时，写事务竟然成功了")
	}
	if !IsBusy(err) {
		t.Fatalf("超时错误没被识别成 busy：%v", err)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("超时用了 %v，busy_timeout=20ms 没有生效", elapsed)
	}

	// 两条日志：BEGIN IMMEDIATE 这条语句自己一条（sql=begin），写事务收尾再一条
	// （sql=write transaction、tx=true）。后者是"一次写事务整体被锁挡住"的记录。
	entries := buffer.entries(t)
	var statementBusy, transactionBusy map[string]any
	for _, entry := range entries {
		if entry["msg"] != "relay: database is busy" {
			continue
		}
		if entry["tx"] == true {
			transactionBusy = entry
		} else {
			statementBusy = entry
		}
	}
	if statementBusy == nil || statementBusy["sql"] != "begin" {
		t.Fatalf("缺 BEGIN IMMEDIATE 的 busy 日志：%v", entries)
	}
	if transactionBusy == nil {
		t.Fatalf("缺写事务的 busy 日志（tx=true）：%v", entries)
	}
	if transactionBusy["requestId"] != "trace-busy" {
		t.Fatalf("事务 busy 日志 requestId = %v", transactionBusy["requestId"])
	}
	if transactionBusy["sql"] != "write transaction" {
		t.Fatalf("事务 busy 日志 sql 名称 = %v", transactionBusy["sql"])
	}
}

// TestDiskFullEquivalentSurfacesAsSQLiteFull 覆盖"磁盘写满"在 SQLite 层的等价
// 注入：把连接允许的页数压到当前值，再写入一段需要新页的大文本，SQLite 返回
// SQLITE_FULL（与文件系统 ENOSPC 同一类错误文案 "database or disk is full"）。
//
// 这不是文件系统 ENOSPC：本机无法安全构造真正的写满（见报告的 blocked 项）。
// 但中转能看到的就是这个错误，所以它验证的是同一段映射路径；报告里明确标注
// 注入点，不把它写成"磁盘满已验证"。
func TestDiskFullEquivalentSurfacesAsSQLiteFull(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.db")
	st, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()

	var pages int
	if err := st.db.QueryRowContext(ctx, "PRAGMA page_count").Scan(&pages); err != nil {
		t.Fatalf("读 page_count: %v", err)
	}
	if _, err := st.write.ExecContext(ctx,
		fmt.Sprintf("PRAGMA max_page_count = %d", pages)); err != nil {
		t.Fatalf("收紧 max_page_count: %v", err)
	}
	// 256 KiB 的账户名需要远超当前页数的空间。
	_, err = st.CreateAccount(ctx, strings.Repeat("x", 256*1024))
	if err == nil {
		t.Fatal("页数上限已到，写入竟然成功")
	}
	if !strings.Contains(strings.ToLower(err.Error()), "full") {
		t.Fatalf("写入错误不是 SQLITE_FULL：%v", err)
	}
	if IsBusy(err) {
		t.Fatalf("SQLITE_FULL 被误判成 busy（会被映射成 503）：%v", err)
	}
	t.Logf("SQLITE_FULL 错误：%v", err)

	// 恢复：抬高上限后同一个连接能继续写，说明失败没有把连接弄坏。
	if _, err := st.write.ExecContext(ctx, "PRAGMA max_page_count = 1000000"); err != nil {
		t.Fatalf("恢复 max_page_count: %v", err)
	}
	if _, err := st.CreateAccount(ctx, "recovered"); err != nil {
		t.Fatalf("恢复空间后仍写不进去: %v", err)
	}
}

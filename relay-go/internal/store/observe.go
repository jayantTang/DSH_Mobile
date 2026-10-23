package store

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
)

// DefaultSlowQuery 是慢查询的判定线：超过它记一条 WARN。
//
// 100 ms 是"用户能感觉到"的下界：黑盒的写锁探针在 2 秒持锁下等待约 2 秒，
// 正常的单行读写远低于 1 ms；落在 100 ms 以上的基本是锁等待、大扫描或磁盘抖动，
// 都值得一条日志。
const DefaultSlowQuery = 100 * time.Millisecond

// Options 是打开库时的可观测性配置（零值取默认：slog.Default + 100 ms）。
type Options struct {
	Logger    *slog.Logger
	SlowQuery time.Duration
}

// observer 把"慢查询/事务"与"数据库忙"写进日志。
//
// 只记 **SQL 名称**（动词 + 表名，由 statementName 从编译期常量里取），不记 SQL
// 全文、参数或任何用户数据：日志是运维通道，不该变成第二份数据库内容。
type observer struct {
	log  *slog.Logger
	slow time.Duration
}

func newObserver(options Options) observer {
	log := options.Logger
	if log == nil {
		log = slog.Default()
	}
	slow := options.SlowQuery
	if slow <= 0 {
		slow = DefaultSlowQuery
	}
	return observer{log: log, slow: slow}
}

// observe 记一次单条语句的耗时；错误只记 busy/locked（其余由调用方按上下文记）。
func (o observer) observe(ctx context.Context, name string, start time.Time, err error) {
	elapsed := time.Since(start)
	switch {
	case err != nil && IsBusy(err):
		o.log.WarnContext(ctx, "relay: database is busy",
			append(observerArgs(ctx, name, elapsed), "error", err)...)
	case err != nil:
		// 普通 SQL 错误由调用方（handler/后台任务）按业务上下文记一条，
		// 这里再记一次只会制造两份重复日志。
	case elapsed >= o.slow:
		o.log.WarnContext(ctx, "relay: slow database query",
			append(observerArgs(ctx, name, elapsed),
				"threshold_ms", o.slow.Milliseconds())...)
	}
}

// observerArgs 是数据库日志的公共字段。
//
// 有请求作用域时带上 requestId：一次 5xx 的数据库等待与它的访问日志、告警能用
// 同一个 id 检索；后台任务（冲盘、对账）没有作用域，字段就不出现。
func observerArgs(ctx context.Context, name string, elapsed time.Duration) []any {
	args := []any{"sql", name, "duration_ms", elapsed.Milliseconds()}
	if id := reqctx.ID(ctx); id != "" {
		args = append(args, "requestId", id)
	}
	return args
}

// observeTx 记一次写事务的耗时（busy/locked 同样单独一条）。
func (o observer) observeTx(ctx context.Context, name string, start time.Time, err error) {
	elapsed := time.Since(start)
	switch {
	case err != nil && IsBusy(err):
		o.log.WarnContext(ctx, "relay: database is busy",
			append(observerArgs(ctx, name, elapsed), "tx", true, "error", err)...)
	case err != nil:
		// 业务结果（冲突、未找到、邀请码被拒）是正常返回，不是数据库故障：
		// 它们都实现了 domainError 标记（见 errors.go），不在这里记。
		var domain interface{ domainError() }
		if errors.As(err, &domain) {
			return
		}
		o.log.WarnContext(ctx, "relay: database transaction failed",
			append(observerArgs(ctx, name, elapsed), "tx", true, "error", err)...)
	case elapsed >= o.slow:
		o.log.WarnContext(ctx, "relay: slow database transaction",
			append(observerArgs(ctx, name, elapsed), "tx", true,
				"threshold_ms", o.slow.Milliseconds())...)
	}
}

// observedDB 把 *sql.DB 的三条查询入口包一层计时。
//
// 用嵌入而不是改 49 个调用点：SQL 名称与计时口径只有这一份，仓储方法保持原样。
// 事务/连接/池配置等其余方法由嵌入的 *sql.DB 原样提供。
type observedDB struct {
	*sql.DB
	observer
}

func (d *observedDB) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	start := time.Now()
	rows, err := d.DB.QueryContext(ctx, query, args...)
	d.observe(ctx, statementName(query), start, err)
	return rows, err
}

func (d *observedDB) QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row {
	start := time.Now()
	row := d.DB.QueryRowContext(ctx, query, args...)
	// QueryRow 的错误要等到 Scan 才出现；这里只能记耗时（Scan 的错误由调用方处理）。
	d.observe(ctx, statementName(query), start, nil)
	return row
}

func (d *observedDB) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	start := time.Now()
	result, err := d.DB.ExecContext(ctx, query, args...)
	d.observe(ctx, statementName(query), start, err)
	return result, err
}

// observedConn 是专用写连接的计时包装（写事务的所有语句都走它）。
type observedConn struct {
	*sql.Conn
	observer
}

func (c *observedConn) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	start := time.Now()
	rows, err := c.Conn.QueryContext(ctx, query, args...)
	c.observe(ctx, statementName(query), start, err)
	return rows, err
}

func (c *observedConn) QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row {
	start := time.Now()
	row := c.Conn.QueryRowContext(ctx, query, args...)
	c.observe(ctx, statementName(query), start, nil)
	return row
}

func (c *observedConn) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	start := time.Now()
	result, err := c.Conn.ExecContext(ctx, query, args...)
	c.observe(ctx, statementName(query), start, err)
	return result, err
}

// statementName 从 SQL 文本里取一个稳定的短名：`select devices`、`insert pairCodes`。
//
// 只取动词与第一张表，绝不拼参数或字符串字面量；认不出的语句退化成动词本身。
// 这样日志可以按名字聚合，又不会把 SQL 全文（以及将来可能被拼进去的值）带到
// 运维通道里。
func statementName(query string) string {
	text := strings.TrimSpace(query)
	for {
		switch {
		case strings.HasPrefix(text, "--"):
			if index := strings.IndexByte(text, '\n'); index >= 0 {
				text = strings.TrimSpace(text[index+1:])
				continue
			}
			return "statement"
		case strings.HasPrefix(text, "/*"):
			if index := strings.Index(text, "*/"); index >= 0 {
				text = strings.TrimSpace(text[index+2:])
				continue
			}
			return "statement"
		}
		break
	}
	verb := leadingWord(text)
	if verb == "" {
		return "statement"
	}
	switch verb {
	case "select":
		return joinName(verb, wordAfter(text, " from "))
	case "insert":
		return joinName(verb, wordAfter(text, " into "))
	case "update":
		return joinName(verb, firstWordAfterVerb(text))
	case "delete":
		return joinName(verb, wordAfter(text, " from "))
	case "replace":
		return joinName(verb, wordAfter(text, " into "))
	case "pragma":
		return joinName(verb, firstWordAfterVerb(text))
	default:
		return verb
	}
}

// leadingWord 是文本里第一个标识符（小写）。
func leadingWord(text string) string {
	for index := 0; index < len(text); index++ {
		ch := text[index]
		if isWordByte(ch) {
			end := index
			for end < len(text) && isWordByte(text[end]) {
				end++
			}
			return strings.ToLower(text[index:end])
		}
		if ch != ' ' && ch != '\n' && ch != '\t' && ch != '\r' {
			return ""
		}
	}
	return ""
}

// firstWordAfterVerb 跳过动词本身，取随后的第一个标识符（update/pragma 的表名）。
func firstWordAfterVerb(text string) string {
	seenVerb := false
	for index := 0; index < len(text); index++ {
		if !isWordByte(text[index]) {
			continue
		}
		end := index
		for end < len(text) && isWordByte(text[end]) {
			end++
		}
		if !seenVerb {
			seenVerb = true
			index = end - 1
			continue
		}
		return strings.ToLower(text[index:end])
	}
	return ""
}

// wordAfter 取 marker（如 " from "）之后的第一个标识符。
func wordAfter(text, marker string) string {
	lower := strings.ToLower(text)
	index := strings.Index(lower, marker)
	if index < 0 {
		return ""
	}
	rest := lower[index+len(marker):]
	return leadingWord(rest)
}

// joinName 把动词与表名拼成日志里的 SQL 名称；没有表名时只留动词。
func joinName(verb, table string) string {
	table = strings.Trim(table, "`\"[];")
	if table == "" {
		return verb
	}
	return verb + " " + table
}

func isWordByte(ch byte) bool {
	return ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' ||
		ch >= '0' && ch <= '9' || ch == '_'
}

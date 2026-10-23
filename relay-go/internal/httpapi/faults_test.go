package httpapi

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 这个文件是 SQLite 故障注入的 HTTP 层一半：把仓储层真实产生的 SQLITE_READONLY
// 与 SQLITE_BUSY 放进写请求，断言返回 JSON 信封、5xx 带 requestId、进程继续服务。
//
// 为什么注入点在 Store 端口：macOS 上无法把**运行中**的进程变成"库只读"。
// chmod 只影响之后 open(2) 的调用，不回收已持有的文件描述符；而只读库/只读目录
// 会让 store.Open 在 ensureWAL/迁移阶段直接失败（见 store/faults_test.go 的
// TestReadOnlyDirectoryFailsFastOnOpen），根本走不到"请求返回错误"这一步。
// 所以这里保留真实 SQLite 错误作为输入，只替换"写方法把错误交出来"这一层，
// 信封、状态码、requestId、日志与后续存活都是真实 handler 的行为。
//
// 每个用例一个临时库；不碰真实数据。

// faultyStore 只替换写方法，其余读写仍走真实仓储。
type faultyStore struct {
	Store
	err error
}

func (s *faultyStore) PutAccountStateBatch(ctx context.Context, accountID string,
	writes []store.StateWrite, deviceID *string) (store.BatchPutResult, error) {
	return store.BatchPutResult{}, s.err
}

// rawSQLite 打开一条与生产同驱动的原生连接。
//
// 驱动名由构建标签决定（cgo → sqlite3，纯 Go → sqlite），测试里按注册名探测；
// 两个名字都不会同时注册，探测失败说明构建装配坏了，直接失败。
func rawSQLite(t *testing.T, dsn string) *sql.DB {
	t.Helper()
	var (
		db   *sql.DB
		errs []string
	)
	for _, name := range []string{"sqlite3", "sqlite"} {
		candidate, err := sql.Open(name, dsn)
		if err != nil {
			errs = append(errs, name+": "+err.Error())
			continue
		}
		if err := candidate.Ping(); err != nil {
			errs = append(errs, name+": "+err.Error())
			_ = candidate.Close()
			continue
		}
		db = candidate
		t.Cleanup(func() { _ = candidate.Close() })
		break
	}
	if db == nil {
		t.Fatalf("没有可用的 SQLite 驱动（%s）", strings.Join(errs, "; "))
	}
	return db
}

// realReadOnlyError 用 SQLite 的 `mode=ro` 产生真实的 SQLITE_READONLY。
func realReadOnlyError(t *testing.T, path string) error {
	t.Helper()
	db := rawSQLite(t, "file:"+path+"?mode=ro")
	_, err := db.Exec("UPDATE accounts SET name = name")
	if err == nil {
		t.Fatal("只读连接竟然写成功")
	}
	return err
}

// realBusyError 用两条连接产生真实的 SQLITE_BUSY：
// 一条 BEGIN IMMEDIATE 持写锁，另一条把 busy_timeout 压到 20ms 后也去要写锁。
func realBusyError(t *testing.T, path string) error {
	t.Helper()
	holder := rawSQLite(t, path+"?_busy_timeout=15000")
	holderConn, err := holder.Conn(context.Background())
	if err != nil {
		t.Fatalf("取持锁连接: %v", err)
	}
	defer holderConn.Close()
	if _, err := holderConn.ExecContext(context.Background(), "BEGIN IMMEDIATE"); err != nil {
		t.Fatalf("BEGIN IMMEDIATE: %v", err)
	}
	defer func() { _, _ = holderConn.ExecContext(context.Background(), "ROLLBACK") }()

	victim := rawSQLite(t, path+"?_busy_timeout=20")
	victimConn, err := victim.Conn(context.Background())
	if err != nil {
		t.Fatalf("取等待连接: %v", err)
	}
	defer victimConn.Close()
	_, busyErr := victimConn.ExecContext(context.Background(), "BEGIN IMMEDIATE")
	if busyErr == nil {
		t.Fatal("外部写锁还被持有时，第二条连接竟然拿到了写锁")
	}
	if !store.IsBusy(busyErr) {
		t.Fatalf("SQLite 返回的错误不是 busy：%v", busyErr)
	}
	return busyErr
}

// newFaultAPI 建一套真实 handler，写方法换成带 injected 错误的 Store。
func newFaultAPI(t *testing.T, injected error) (*testAPI, testTenant, string) {
	t.Helper()
	st := openTestStore(t)
	api := newTestAPIWithPort(t, Options{MaxPairedDevices: 8}, st, &faultyStore{Store: st, err: injected})
	tenant := api.newTenant("fault-mac")
	token := tokenOf(api.pairDevice(tenant, "fault-iPhone", ""))
	return api, tenant, token
}

// putState 发一次真实的 PUT /account/state，并带上调用方 requestId。
func putState(t *testing.T, api *testAPI, token, requestID string) *httptest.ResponseRecorder {
	t.Helper()
	body := `{"entries":[{"key":"theme","value":"dark","updatedAt":1}]}`
	req := httptest.NewRequest(http.MethodPut, "/account/state", strings.NewReader(body))
	req.RemoteAddr = "127.0.0.1:51000"
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set(reqctx.Header, requestID)
	rec := httptest.NewRecorder()
	api.handler.ServeHTTP(rec, req)
	return rec
}

// TestReadOnlyWriteFailureReturnsJSONEnvelopeWithRequestID：只读库上的写请求
// 必须得到可解析的 JSON 信封与 requestId，且 handler 继续服务（同进程下一次
// 读请求照常 200）。
//
// 状态码取 500 而不是 503：DESIGN §6 只把 busy/locked 映射为 503 + Retry-After，
// 只读（SQLITE_READONLY）不是瞬态，重试不会恢复；回 503 会让客户端一直重试。
func TestReadOnlyWriteFailureReturnsJSONEnvelopeWithRequestID(t *testing.T) {
	st := openTestStore(t)
	injected := realReadOnlyError(t, st.Path())
	api := newTestAPIWithPort(t, Options{MaxPairedDevices: 8}, st, &faultyStore{Store: st, err: injected})
	tenant := api.newTenant("readonly-mac")
	token := tokenOf(api.pairDevice(tenant, "readonly-iPhone", ""))

	rec := putState(t, api, token, "trace-readonly")
	payload := assertEnvelope(t, rec, http.StatusInternalServerError, "internal/error")
	if payload["requestId"] != "trace-readonly" {
		t.Fatalf("500 信封 requestId = %v", payload["requestId"])
	}
	if header := rec.Header().Get(reqctx.Header); header != "trace-readonly" {
		t.Fatalf("响应头 requestId = %q", header)
	}
	if retry := rec.Header().Get("Retry-After"); retry != "" {
		t.Fatalf("只读不是瞬态，不该带 Retry-After：%q", retry)
	}
	if !strings.Contains(rec.Body.String(), "could not complete") {
		t.Fatalf("错误文案不含可读说明：%s", rec.Body.String())
	}

	// 进程没有崩：同一个 handler 的下一个请求仍然被正常处理。
	readRec := api.do(http.MethodGet, "/account/state", nil, token)
	if readRec.Code != http.StatusOK {
		t.Fatalf("故障之后的读请求 = %d %s", readRec.Code, readRec.Body.String())
	}
	// 再写一次仍是结构化错误，而不是 500 默认页 / 空响应。
	second := putState(t, api, token, "trace-readonly-2")
	assertEnvelope(t, second, http.StatusInternalServerError, "internal/error")
}

// TestBusyWriteFailureReturns503EnvelopeWithRequestID：SQLITE_BUSY 映射为
// 503 + Retry-After: 1 + db/busy，5xx 信封带 requestId。
func TestBusyWriteFailureReturns503EnvelopeWithRequestID(t *testing.T) {
	st := openTestStore(t)
	injected := realBusyError(t, st.Path())
	api := newTestAPIWithPort(t, Options{MaxPairedDevices: 8}, st, &faultyStore{Store: st, err: injected})
	tenant := api.newTenant("busy-mac")
	token := tokenOf(api.pairDevice(tenant, "busy-iPhone", ""))

	rec := putState(t, api, token, "trace-busy")
	payload := assertEnvelope(t, rec, http.StatusServiceUnavailable, "db/busy")
	if payload["requestId"] != "trace-busy" {
		t.Fatalf("503 信封 requestId = %v", payload["requestId"])
	}
	if retry := rec.Header().Get("Retry-After"); retry != "1" {
		t.Fatalf("Retry-After = %q", retry)
	}
	// 故障之后 handler 仍可用。
	if readRec := api.do(http.MethodGet, "/account/state", nil, token); readRec.Code != http.StatusOK {
		t.Fatalf("故障之后的读请求 = %d %s", readRec.Code, readRec.Body.String())
	}
}

// logBuffer 是并发安全的 JSON 日志缓冲（服务端日志可能来自多个 goroutine）。
type logBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *logBuffer) Write(payload []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(payload)
}

func (b *logBuffer) entries(t *testing.T) []map[string]any {
	t.Helper()
	b.mu.Lock()
	text := b.buf.String()
	b.mu.Unlock()
	entries := make([]map[string]any, 0, 8)
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("日志不是 JSON：%v（%s）", err, line)
		}
		entries = append(entries, entry)
	}
	return entries
}

// TestWriteRequestWaitsForAnExternalWriteLockAndLogsTheTransaction 是"请求等待"
// 的端到端版本：另开连接 BEGIN IMMEDIATE 持锁 300ms，PUT /account/state 必须
// 等锁、随后成功，并在日志里留下带 requestId 的慢事务记录。
func TestWriteRequestWaitsForAnExternalWriteLockAndLogsTheTransaction(t *testing.T) {
	logs := &logBuffer{}
	logger := slog.New(slog.NewJSONHandler(logs, nil))
	// 库的慢查询/事务日志在 Open 时绑定日志器，所以要在这里用同一个 logger 打开。
	st, err := store.OpenWith(filepath.Join(t.TempDir(), "state.db"), store.Options{
		Logger: logger,
	})
	if err != nil {
		t.Fatalf("OpenWith: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	api := newTestAPIWithStore(t, Options{MaxPairedDevices: 8, Logger: logger}, st)
	tenant := api.newTenant("lock-mac")
	token := tokenOf(api.pairDevice(tenant, "lock-iPhone", ""))

	holder := rawSQLite(t, st.Path()+"?_busy_timeout=15000")
	conn, err := holder.Conn(context.Background())
	if err != nil {
		t.Fatalf("取持锁连接: %v", err)
	}
	if _, err := conn.ExecContext(context.Background(), "BEGIN IMMEDIATE"); err != nil {
		t.Fatalf("BEGIN IMMEDIATE: %v", err)
	}
	released := make(chan struct{})
	go func() {
		time.Sleep(300 * time.Millisecond)
		_, _ = conn.ExecContext(context.Background(), "ROLLBACK")
		_ = conn.Close()
		close(released)
	}()
	t.Cleanup(func() {
		<-released
		_ = holder.Close()
	})

	started := time.Now()
	rec := putState(t, api, token, "trace-lock")
	elapsed := time.Since(started)
	<-released
	if rec.Code != http.StatusOK {
		t.Fatalf("持锁 300ms 后的写请求 = %d %s", rec.Code, rec.Body.String())
	}
	if elapsed < 250*time.Millisecond {
		t.Fatalf("写请求只用了 %v：没有在外部写锁上等待", elapsed)
	}

	entries := logs.entries(t)
	var slowTx map[string]any
	for _, entry := range entries {
		// 只认这一次请求：-race 下配对/建库的事务也可能超过 100ms，取第一条会把
		// 别人（或 setup）的慢事务当成本次结果。
		if entry["msg"] == "relay: slow database transaction" &&
			entry["requestId"] == "trace-lock" {
			slowTx = entry
			break
		}
	}
	if slowTx == nil {
		t.Fatalf("没有 requestId=trace-lock 的慢事务日志：%v", entries)
	}
	if slowTx["tx"] != true || slowTx["requestId"] != "trace-lock" {
		t.Fatalf("慢事务日志字段 = %v", slowTx)
	}
	if duration, _ := slowTx["duration_ms"].(float64); duration < 250 {
		t.Fatalf("慢事务 duration_ms = %v，期望 >=250", slowTx["duration_ms"])
	}
}

// realDiskFullError 在同一个库上产生真实的 SQLITE_FULL：把这条连接的
// max_page_count 压到当前页数，再插入一段需要新页的大文本。
//
// 这不是文件系统 ENOSPC（本机无法安全构造，见报告 blocked 项），但中转看到的
// 错误与写满磁盘相同（"database or disk is full"），所以 HTTP 层的处理路径一致。
// 报告里按"SQLite FULL 等价注入"记录，不写成磁盘满已验证。
func realDiskFullError(t *testing.T, path string) error {
	t.Helper()
	db := rawSQLite(t, path+"?_busy_timeout=15000")
	var pages int
	if err := db.QueryRow("PRAGMA page_count").Scan(&pages); err != nil {
		t.Fatalf("读 page_count: %v", err)
	}
	if _, err := db.Exec(fmt.Sprintf("PRAGMA max_page_count = %d", pages)); err != nil {
		t.Fatalf("收紧 max_page_count: %v", err)
	}
	_, err := db.Exec(
		"INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
		"acc_disk_full_probe", strings.Repeat("x", 256*1024), time.Now().UnixMilli())
	if err == nil {
		t.Fatal("页数上限已到，写入竟然成功")
	}
	if !strings.Contains(strings.ToLower(err.Error()), "full") {
		t.Fatalf("写入错误不是 SQLITE_FULL：%v", err)
	}
	return err
}

// TestDiskFullEquivalentWriteReturnsJSONEnvelopeWithRequestID：SQLITE_FULL 与
// 只读同一分支（非瞬态）→ 500 JSON 信封 + requestId，进程继续服务。
func TestDiskFullEquivalentWriteReturnsJSONEnvelopeWithRequestID(t *testing.T) {
	st := openTestStore(t)
	injected := realDiskFullError(t, st.Path())
	api := newTestAPIWithPort(t, Options{MaxPairedDevices: 8}, st,
		&faultyStore{Store: st, err: injected})
	tenant := api.newTenant("full-mac")
	token := tokenOf(api.pairDevice(tenant, "full-iPhone", ""))

	rec := putState(t, api, token, "trace-full")
	payload := assertEnvelope(t, rec, http.StatusInternalServerError, "internal/error")
	if payload["requestId"] != "trace-full" {
		t.Fatalf("500 信封 requestId = %v", payload["requestId"])
	}
	if retry := rec.Header().Get("Retry-After"); retry != "" {
		t.Fatalf("SQLITE_FULL 不是瞬态，不该带 Retry-After：%q", retry)
	}
	if readRec := api.do(http.MethodGet, "/account/state", nil, token); readRec.Code != http.StatusOK {
		t.Fatalf("故障之后的读请求 = %d %s", readRec.Code, readRec.Body.String())
	}
}

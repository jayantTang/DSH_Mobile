package store

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// observeBuffer 是并发安全的日志缓冲。
type observeBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *observeBuffer) Write(payload []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(payload)
}

func (b *observeBuffer) entries(t *testing.T) []map[string]any {
	t.Helper()
	b.mu.Lock()
	text := b.buf.String()
	b.mu.Unlock()
	entries := make([]map[string]any, 0, 4)
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("日志不是 JSON：%v (%s)", err, line)
		}
		entries = append(entries, entry)
	}
	return entries
}

func TestStatementNameIsTheShortFormNotTheSQL(t *testing.T) {
	cases := []struct {
		query string
		want  string
	}{
		{"SELECT deviceId, name FROM devices WHERE deviceId = ?", "select devices"},
		{"INSERT INTO pairCodes (codeHash) VALUES (?)", "insert paircodes"},
		{"UPDATE devices SET lastSeenAt = ? WHERE deviceId = ?", "update devices"},
		{"DELETE FROM feedbackMessages WHERE threadId = ?", "delete feedbackmessages"},
		{"PRAGMA user_version", "pragma user_version"},
		{"BEGIN IMMEDIATE", "begin"},
		{"-- 读今天的用量\nSELECT day FROM usageDaily", "select usagedaily"},
		{"/* migration */ SELECT * FROM accounts", "select accounts"},
		{"", "statement"},
	}
	for _, c := range cases {
		if got := statementName(c.query); got != c.want {
			t.Errorf("statementName(%q) = %q，期望 %q", c.query, got, c.want)
		}
	}
}

func TestSlowQueryLogsTheSQLNameButNotTheStatement(t *testing.T) {
	buffer := &observeBuffer{}
	st, err := OpenWith(filepath.Join(t.TempDir(), "state.db"), Options{
		Logger:    slog.New(slog.NewJSONHandler(buffer, nil)),
		SlowQuery: time.Nanosecond,
	})
	if err != nil {
		t.Fatalf("OpenWith: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	if _, err := st.CreateAccount(context.Background(), "Alice Secret"); err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}

	var slow []map[string]any
	for _, entry := range buffer.entries(t) {
		if entry["msg"] == "relay: slow database query" ||
			entry["msg"] == "relay: slow database transaction" {
			slow = append(slow, entry)
		}
	}
	if len(slow) == 0 {
		t.Fatalf("阈值 1ns 下没有慢查询日志：%v", buffer.entries(t))
	}
	sawStatement := false
	for _, entry := range slow {
		name, ok := entry["sql"].(string)
		if !ok || name == "" {
			t.Fatalf("慢查询缺 sql 名称：%v", entry)
		}
		if strings.Contains(name, "INSERT INTO") || strings.Contains(name, "(") {
			t.Fatalf("sql 字段带上了全文：%v", entry)
		}
		if strings.Contains(name, "Alice") {
			t.Fatalf("sql 名称里出现了用户数据：%v", entry)
		}
		if name == "insert accounts" || name == "write transaction" {
			sawStatement = true
		}
		if _, ok := entry["duration_ms"]; !ok {
			t.Fatalf("慢查询缺 duration_ms：%v", entry)
		}
	}
	if !sawStatement {
		t.Fatalf("没有看到写事务或 insert accounts 的慢记账：%v", slow)
	}
}

func TestBusyIsLoggedWithTheSQLName(t *testing.T) {
	buffer := &observeBuffer{}
	observer := newObserver(Options{
		Logger: slog.New(slog.NewJSONHandler(buffer, nil)), SlowQuery: time.Hour,
	})
	observer.observe(context.Background(), "select devices", time.Now().Add(-time.Second),
		errors.New("database is locked (5) (SQLITE_BUSY)"))
	observer.observeTx(context.Background(), "write transaction",
		time.Now().Add(-time.Second), errors.New("database table is locked"))

	entries := buffer.entries(t)
	if len(entries) != 2 {
		t.Fatalf("busy 日志 = %v", entries)
	}
	for _, entry := range entries {
		if entry["msg"] != "relay: database is busy" || entry["level"] != "WARN" {
			t.Fatalf("busy 日志 = %v", entry)
		}
		if entry["sql"] == "" || entry["sql"] == nil {
			t.Fatalf("busy 日志缺 sql 名称：%v", entry)
		}
	}
	if entries[1]["tx"] != true {
		t.Fatalf("事务 busy 没标 tx：%v", entries[1])
	}
}

func TestBusinessTransactionErrorsAreNotLoggedAsDatabaseFailures(t *testing.T) {
	buffer := &observeBuffer{}
	observer := newObserver(Options{
		Logger: slog.New(slog.NewJSONHandler(buffer, nil)), SlowQuery: time.Hour,
	})
	observer.observeTx(context.Background(), "write transaction", time.Now(),
		newConflict("pair code already claimed"))
	if entries := buffer.entries(t); len(entries) != 0 {
		t.Fatalf("业务冲突不该记数据库故障：%v", entries)
	}
}

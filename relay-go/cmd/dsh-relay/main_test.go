package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// TestOpsSubcommandsAreWired 只钉路由：两个运维 timer 调用的子命令必须走到各自
// 实现（参数不全时回各自的用法错误），而不是掉进「未知子命令」。
func TestOpsSubcommandsAreWired(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want int
	}{
		{"purge 缺 --db", []string{"purge", "--all-agents"}, 2},
		{"purge --help", []string{"purge", "--help"}, 0},
		{"alert-dispatch 缺目录", []string{"alert-dispatch"}, 2},
	}
	for _, test := range cases {
		var stdout, stderr bytes.Buffer
		code := run(test.args, func(string) string { return "" }, &stdout, &stderr)
		if code != test.want {
			t.Fatalf("%s: 退出码 = %d，期望 %d（stderr=%s）",
				test.name, code, test.want, stderr.String())
		}
		if strings.Contains(stderr.String(), "未知子命令") {
			t.Fatalf("%s: 子命令没有接线：%s", test.name, stderr.String())
		}
	}
}

// TestServeOnReadOnlyDatabaseExitsWithStructuredError 是"只读库/目录不可写"的
// 进程级断言：serve 必须以退出码 1 + 一条 JSON 错误日志结束，不能 panic，也不能
// 带着半可用的库继续监听。
//
// 运行中的进程无法被 chmod 改成只读（已打开的文件描述符不受权限位影响），所以
// 只读故障的构造点在启动；HTTP 层"写请求返回 JSON 信封 + requestId"由
// internal/httpapi/faults_test.go 用同一个 SQLITE_READONLY 错误覆盖。
func TestServeOnReadOnlyDatabaseExitsWithStructuredError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.db")
	st, err := store.Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
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
		_ = os.Chmod(dir, 0o755)
		_ = os.Chmod(path, 0o644)
	})

	var stdout, stderr bytes.Buffer
	code := run([]string{"serve", "--db", path}, func(string) string { return "" },
		&stdout, &stderr)
	if code != 1 {
		t.Fatalf("只读库上的 serve 退出码 = %d，期望 1（stderr=%s）", code, stderr.String())
	}
	if strings.Contains(stderr.String(), "panic") {
		t.Fatalf("只读库导致 panic：%s", stderr.String())
	}
	line := strings.TrimSpace(stderr.String())
	var entry map[string]any
	if err := json.Unmarshal([]byte(line), &entry); err != nil {
		t.Fatalf("启动错误不是一行 JSON：%v（%s）", err, stderr.String())
	}
	if entry["msg"] != "relay: open store failed" || entry["level"] != "ERROR" {
		t.Fatalf("启动错误日志 = %v", entry)
	}
	if message, _ := entry["error"].(string); message == "" {
		t.Fatalf("启动错误日志没有原因：%v", entry)
	}
	if db, _ := entry["db"].(string); db != path {
		t.Fatalf("启动错误日志的 db 字段 = %v，期望 %s", entry["db"], path)
	}
}

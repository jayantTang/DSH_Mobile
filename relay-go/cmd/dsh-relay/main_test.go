package main

import (
	"bytes"
	"strings"
	"testing"
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

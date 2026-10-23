package main

import (
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"
)

// TestPprofServerServesIndex 验证"显式开启后 pprof 真的可用"，
// 而不是只有一个没人验证过的接线。绑 127.0.0.1:0，不占固定端口。
func TestPprofServerServesIndex(t *testing.T) {
	stop, addr, err := startPprof("127.0.0.1:0", slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatalf("startPprof: %v", err)
	}
	defer stop()

	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Get("http://" + addr + "/debug/pprof/")
	if err != nil {
		t.Fatalf("GET /debug/pprof/: %v", err)
	}
	defer func() { _ = response.Body.Close() }()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("读响应: %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("状态码 = %d", response.StatusCode)
	}
	for _, want := range []string{"goroutine", "heap", "allocs"} {
		if !strings.Contains(string(body), want) {
			t.Fatalf("pprof 首页缺少 %q", want)
		}
	}
}

// TestPprofServerReportsBindFailure 端口被占时要把错误交给调用方（启动失败），
// 不能静默留下一个"开了但没起来"的诊断面。地址的环回校验在 config 里，不在这一层。
func TestPprofServerReportsBindFailure(t *testing.T) {
	stop, addr, err := startPprof("127.0.0.1:0", slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatalf("startPprof: %v", err)
	}
	defer stop()
	if _, _, err := startPprof(addr, slog.New(slog.NewTextHandler(io.Discard, nil))); err == nil {
		t.Fatal("重复监听同一地址应该报错")
	}
}

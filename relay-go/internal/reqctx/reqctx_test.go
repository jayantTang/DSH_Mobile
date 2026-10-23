package reqctx_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
)

func TestSanitizeAcceptsTraceIDsAndRejectsInjection(t *testing.T) {
	cases := []struct {
		raw  string
		want string
	}{
		{"  abc-123.attempt_1  ", "abc-123.attempt_1"},
		{"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
			"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"},
		{"bad\nvalue", ""},             // 换行 = 日志注入
		{"bad value", ""},              // 空格不在白名单
		{`bad"quote`, ""},              // 引号不在白名单
		{"", ""},                       // 空 = 没带
		{strings.Repeat("a", 129), ""}, // 超长
	}
	for _, c := range cases {
		if got := reqctx.Sanitize(c.raw); got != c.want {
			t.Errorf("Sanitize(%q) = %q, 期望 %q", c.raw, got, c.want)
		}
	}
}

func TestNewIDIsRandomAndWellFormed(t *testing.T) {
	pattern := regexp.MustCompile(`^req_[0-9a-f]{16}$`)
	first := reqctx.NewID()
	if !pattern.MatchString(first) {
		t.Fatalf("NewID() = %q，不符合 req_+16 hex", first)
	}
	if second := reqctx.NewID(); second == first {
		t.Fatalf("两次 NewID 相同：%q", first)
	}
}

func TestMiddlewarePassesThroughAndGenerates(t *testing.T) {
	var seen string
	handler := reqctx.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = reqctx.ID(r.Context())
		reqctx.NoteAgent(r.Context(), "agt_demo")
		reqctx.NoteDevice(r.Context(), "dev_demo")
	}))

	// 透传：客户端带的 ID 原样进 context 与响应头。
	request := httptest.NewRequest(http.MethodGet, "/x", nil)
	request.Header.Set(reqctx.Header, "client-trace-1")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if seen != "client-trace-1" {
		t.Fatalf("context ID = %q", seen)
	}
	if got := recorder.Header().Get(reqctx.Header); got != "client-trace-1" {
		t.Fatalf("响应头 = %q", got)
	}

	// 没带（或带了非法值）：生成一个，响应头回写。
	for _, header := range []string{"", "bad value"} {
		request = httptest.NewRequest(http.MethodGet, "/x", nil)
		if header != "" {
			request.Header.Set(reqctx.Header, header)
		}
		recorder = httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		if !regexp.MustCompile(`^req_[0-9a-f]{16}$`).MatchString(seen) {
			t.Fatalf("生成的 ID 不合法：%q", seen)
		}
		if got := recorder.Header().Get(reqctx.Header); got != seen {
			t.Fatalf("响应头 = %q，context = %q", got, seen)
		}
	}
}

func TestScopeWithoutMiddlewareIsSafe(t *testing.T) {
	// 没有作用域的 context：读 ID 得到空串，写身份是空操作，不 panic。
	ctx := context.Background()
	if got := reqctx.ID(ctx); got != "" {
		t.Fatalf("ID = %q", got)
	}
	reqctx.NoteAgent(ctx, "agt_x")
	reqctx.NoteDevice(ctx, "dev_x")
	if agent, device := reqctx.From(ctx).Actor(); agent != "" || device != "" {
		t.Fatalf("Actor = %q/%q", agent, device)
	}
}

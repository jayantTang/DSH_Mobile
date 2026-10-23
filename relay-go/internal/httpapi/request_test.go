package httpapi

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/monitor"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
)

// lockedBuffer 是并发安全的日志缓冲（中间件在 handler goroutine 里写）。
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(payload []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(payload)
}

func (b *lockedBuffer) lines(t *testing.T) []map[string]any {
	t.Helper()
	b.mu.Lock()
	text := b.buf.String()
	b.mu.Unlock()
	lines := make([]map[string]any, 0, 4)
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("日志不是 JSON: %v (%s)", err, line)
		}
		lines = append(lines, entry)
	}
	return lines
}

// newLogBuffer 返回一个把 JSON 日志写进缓冲的 logger。
func newLogBuffer() (*slog.Logger, *lockedBuffer) {
	buffer := &lockedBuffer{}
	return slog.New(slog.NewJSONHandler(buffer, &slog.HandlerOptions{Level: slog.LevelDebug})), buffer
}

// accessEntries 只挑访问日志（relay: access / relay: slow request）。
func accessEntries(entries []map[string]any) []map[string]any {
	out := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		switch entry["msg"] {
		case "relay: access", "relay: slow request":
			out = append(out, entry)
		}
	}
	return out
}

func TestRequestIDIsGeneratedEchoedAndLogged(t *testing.T) {
	logger, buffer := newLogBuffer()
	api := newTestAPIWithOptions(t, Options{Logger: logger, AccessLog: AccessLogAll})

	recorder := api.do(http.MethodGet, "/healthz", nil, "")
	header := recorder.Header().Get(reqctx.Header)
	if !strings.HasPrefix(header, "req_") || len(header) != len("req_")+16 {
		t.Fatalf("响应头 %s = %q", reqctx.Header, header)
	}

	entries := accessEntries(buffer.lines(t))
	if len(entries) != 1 {
		t.Fatalf("访问日志条数 = %d：%v", len(entries), buffer.lines(t))
	}
	entry := entries[0]
	if entry["requestId"] != header {
		t.Fatalf("日志 requestId = %v，响应头 = %q", entry["requestId"], header)
	}
	if entry["route"] != "/healthz" || entry["method"] != http.MethodGet {
		t.Fatalf("method/route = %v/%v", entry["method"], entry["route"])
	}
	if entry["status"] != float64(http.StatusOK) {
		t.Fatalf("status = %v", entry["status"])
	}
	if bytes, _ := entry["bytes"].(float64); bytes <= 0 {
		t.Fatalf("bytes = %v", entry["bytes"])
	}
	if _, ok := entry["duration_ms"]; !ok {
		t.Fatalf("缺 duration_ms：%v", entry)
	}
	if entry["remote_ip"] != "127.0.0.1" {
		t.Fatalf("remote_ip = %v", entry["remote_ip"])
	}
}

func TestRequestIDIsPassedThroughWhenValid(t *testing.T) {
	logger, buffer := newLogBuffer()
	api := newTestAPIWithOptions(t, Options{Logger: logger, AccessLog: AccessLogAll})

	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	request.RemoteAddr = "127.0.0.1:51000"
	request.Header.Set(reqctx.Header, "client-trace-42")
	recorder := httptest.NewRecorder()
	api.handler.ServeHTTP(recorder, request)

	if got := recorder.Header().Get(reqctx.Header); got != "client-trace-42" {
		t.Fatalf("响应头 = %q", got)
	}
	entries := accessEntries(buffer.lines(t))
	if len(entries) != 1 || entries[0]["requestId"] != "client-trace-42" {
		t.Fatalf("访问日志 = %v", entries)
	}

	// 非法头（换行 = 日志注入）必须被替换掉，不能原样回写。
	request = httptest.NewRequest(http.MethodGet, "/healthz", nil)
	request.RemoteAddr = "127.0.0.1:51000"
	request.Header[reqctx.Header] = []string{"bad\nvalue"}
	recorder = httptest.NewRecorder()
	api.handler.ServeHTTP(recorder, request)
	if got := recorder.Header().Get(reqctx.Header); got == "bad\nvalue" || !strings.HasPrefix(got, "req_") {
		t.Fatalf("非法 ID 未被替换：%q", got)
	}
}

// newAccessChain 直接装配"requestId → 访问日志"两层中间件，用于精确控制状态码与耗时。
func newAccessChain(t *testing.T, mode string, slow time.Duration,
	handler http.Handler) (http.Handler, *lockedBuffer) {
	t.Helper()
	logger, buffer := newLogBuffer()
	s := &server{logger: logger, accessLogMode: NormalizeAccessLog(mode), slowRequest: slow}
	return reqctx.Middleware(s.accessLog(handler)), buffer
}

func TestAccessLogErrorsModeOnlyRecordsFiveHundredsAndSlowRequests(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /ok", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("GET /boom", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(500) })
	mux.HandleFunc("GET /slow", func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(5 * time.Millisecond)
		w.WriteHeader(200)
	})
	handler, buffer := newAccessChain(t, AccessLogErrors, time.Millisecond, mux)

	for _, path := range []string{"/ok", "/not-found"} {
		handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil))
	}
	if entries := accessEntries(buffer.lines(t)); len(entries) != 0 {
		t.Fatalf("errors 模式不该记录快速 2xx/4xx：%v", entries)
	}

	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/slow", nil))
	entries := accessEntries(buffer.lines(t))
	if len(entries) != 1 || entries[0]["msg"] != "relay: slow request" {
		t.Fatalf("慢请求日志 = %v", entries)
	}
	if entries[0]["level"] != "WARN" {
		t.Fatalf("慢请求级别 = %v", entries[0]["level"])
	}

	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/boom", nil))
	entries = accessEntries(buffer.lines(t))
	if len(entries) != 2 || entries[1]["status"] != float64(500) {
		t.Fatalf("5xx 日志 = %v", entries)
	}
	if entries[1]["level"] != "ERROR" || entries[1]["msg"] != "relay: access" {
		t.Fatalf("5xx 级别/消息 = %v/%v", entries[1]["level"], entries[1]["msg"])
	}
}

func TestAccessLogOffRecordsNothing(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /boom", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(500) })
	handler, buffer := newAccessChain(t, AccessLogOff, time.Millisecond, mux)
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/boom", nil))
	if entries := accessEntries(buffer.lines(t)); len(entries) != 0 {
		t.Fatalf("off 模式仍有日志：%v", entries)
	}
}

func TestAccessLogAllRecordsEveryRequestAndStripsQuery(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /files/down", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
	})
	handler, buffer := newAccessChain(t, AccessLogAll, time.Hour, mux)

	request := httptest.NewRequest(http.MethodGet,
		"/files/down?path=/Users/someone/secret.txt&token=abc123", nil)
	request.Header.Set(reqctx.Header, "trace-7")
	handler.ServeHTTP(httptest.NewRecorder(), request)

	entries := accessEntries(buffer.lines(t))
	if len(entries) != 1 {
		t.Fatalf("all 模式访问日志 = %v", entries)
	}
	entry := entries[0]
	if entry["requestId"] != "trace-7" || entry["route"] != "/files/down" {
		t.Fatalf("requestId/route = %v/%v", entry["requestId"], entry["route"])
	}
	raw := strings.Join([]string{
		stringOf(entry["route"]), stringOf(entry["requestId"]),
	}, " ")
	for _, secret := range []string{"/Users/someone", "secret.txt", "abc123"} {
		if strings.Contains(raw, secret) {
			t.Fatalf("访问日志泄露了 %q：%v", secret, entry)
		}
	}

	// 没匹配到路由的请求只记 <unmatched>，不把原始路径写进日志。
	request = httptest.NewRequest(http.MethodGet, "/no/such/route?token=abc123", nil)
	handler.ServeHTTP(httptest.NewRecorder(), request)
	entries = accessEntries(buffer.lines(t))
	if len(entries) != 2 || entries[1]["route"] != "<unmatched>" {
		t.Fatalf("未匹配路由 = %v", entries)
	}
	if strings.Contains(stringOf(entries[1]["route"]), "abc123") {
		t.Fatalf("未匹配路由泄露 query：%v", entries[1])
	}
}

func TestFiveHundredCarriesRequestIDButFourHundredDoesNot(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /boom", func(w http.ResponseWriter, r *http.Request) {
		writeErrorFor(w, r, http.StatusInternalServerError, "internal/error", "boom", nil)
	})
	mux.HandleFunc("GET /bad", func(w http.ResponseWriter, r *http.Request) {
		writeErrorFor(w, r, http.StatusBadRequest, "pair/bad-request", "bad", nil)
	})
	handler, _ := newAccessChain(t, AccessLogErrors, time.Hour, mux)

	request := httptest.NewRequest(http.MethodGet, "/boom", nil)
	request.Header.Set(reqctx.Header, "trace-500")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	var enveloped map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &enveloped); err != nil {
		t.Fatalf("500 不是 JSON: %v", err)
	}
	if enveloped["requestId"] != "trace-500" {
		t.Fatalf("500 信封 requestId = %v", enveloped["requestId"])
	}
	if recorder.Header().Get(reqctx.Header) != "trace-500" {
		t.Fatalf("500 响应头 = %q", recorder.Header().Get(reqctx.Header))
	}

	recorder = httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/bad", nil))
	enveloped = map[string]any{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &enveloped); err != nil {
		t.Fatalf("400 不是 JSON: %v", err)
	}
	if _, present := enveloped["requestId"]; present {
		t.Fatalf("4xx 不该出现 requestId（旧响应逐字不变）：%v", enveloped)
	}
}

func TestPanicRecoveryLogsRequestIDStackAndPathAndAlerts(t *testing.T) {
	alertDir := t.TempDir()
	logger, buffer := newLogBuffer()
	incidents := monitor.New(monitor.Options{AlertDir: alertDir, Logger: logger})

	mux := http.NewServeMux()
	mux.HandleFunc("GET /explode", func(http.ResponseWriter, *http.Request) {
		panic("boom in the handler")
	})
	s := &server{logger: logger, accessLogMode: AccessLogAll, slowRequest: time.Hour}
	handler := reqctx.Middleware(s.accessLog(monitor.Middleware(incidents, logger)(mux)))

	request := httptest.NewRequest(http.MethodGet, "/explode", nil)
	request.Header.Set(reqctx.Header, "trace-panic")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("状态码 = %d", recorder.Code)
	}
	var enveloped map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &enveloped); err != nil {
		t.Fatalf("500 不是 JSON: %v", err)
	}
	if enveloped["requestId"] != "trace-panic" {
		t.Fatalf("panic 响应 requestId = %v", enveloped["requestId"])
	}

	// 日志：同一条 panic 日志带 requestId、路径与完整栈。
	var panicEntry map[string]any
	for _, entry := range buffer.lines(t) {
		if entry["msg"] == "relay: handler panicked" {
			panicEntry = entry
		}
	}
	if panicEntry == nil {
		t.Fatalf("没有 panic 日志：%v", buffer.lines(t))
	}
	if panicEntry["requestId"] != "trace-panic" || panicEntry["path"] != "/explode" {
		t.Fatalf("panic 日志字段 = %v", panicEntry)
	}
	stack := stringOf(panicEntry["stack"])
	if !strings.Contains(stack, "goroutine") || !strings.Contains(stack, "httpapi") {
		t.Fatalf("stack 不完整：%q", stack)
	}

	// 告警：同一 requestId 能在队列里检索到，且带路径与栈。
	payload, err := os.ReadFile(filepath.Join(alertDir, monitor.QueueName))
	if err != nil {
		t.Fatalf("读告警队列: %v", err)
	}
	if !strings.Contains(string(payload), `"requestId":"trace-panic"`) ||
		!strings.Contains(string(payload), "/explode") ||
		!strings.Contains(string(payload), `"stack"`) {
		t.Fatalf("告警队列缺少关联字段：%s", payload)
	}

	// 访问日志：同一次请求一条 ERROR。
	entries := accessEntries(buffer.lines(t))
	if len(entries) != 1 || entries[0]["status"] != float64(500) ||
		entries[0]["requestId"] != "trace-panic" || entries[0]["level"] != "ERROR" {
		t.Fatalf("访问日志 = %v", entries)
	}
}

func stringOf(value any) string {
	text, _ := value.(string)
	return text
}

package feedback

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

type feedbackLogBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *feedbackLogBuffer) Write(payload []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(payload)
}

func (b *feedbackLogBuffer) entries(t *testing.T) []map[string]any {
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

func TestFeedbackOperationsLogThreadAndResultButNeverTheBody(t *testing.T) {
	buffer := &feedbackLogBuffer{}
	st, err := store.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	handlers := New(Options{
		Store:    st,
		ClientID: func(r *http.Request) string { return r.RemoteAddr },
		Logger:   slog.New(slog.NewJSONHandler(buffer, nil)),
	})
	mux := http.NewServeMux()
	handlers.Register(mux, "")

	const body = "登录之后一直转圈，用户目录里有个很私密的名字"
	request := httptest.NewRequest(http.MethodPost, "/feedback/submit",
		strings.NewReader(`{"text":"`+body+`"}`))
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("submit 状态码 = %d：%s", recorder.Code, recorder.Body.String())
	}
	var submitted map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &submitted); err != nil {
		t.Fatalf("响应不是 JSON: %v", err)
	}

	var handled map[string]any
	for _, entry := range buffer.entries(t) {
		if entry["msg"] == "relay: feedback handled" {
			handled = entry
			break
		}
	}
	if handled == nil {
		t.Fatalf("没有反馈操作日志：%v", buffer.entries(t))
	}
	if handled["op"] != "submit" || handled["ok"] != true ||
		handled["status"] != float64(http.StatusOK) {
		t.Fatalf("操作日志 = %v", handled)
	}
	if handled["threadId"] != submitted["threadId"] {
		t.Fatalf("threadId = %v，响应 = %v", handled["threadId"], submitted["threadId"])
	}
	if handled["anonymous"] != true {
		t.Fatalf("anonymous = %v", handled["anonymous"])
	}

	// 正文、凭据、Authorization 不得出现在日志里。
	buffer.mu.Lock()
	raw := buffer.buf.String()
	buffer.mu.Unlock()
	for _, forbidden := range []string{"转圈", "私密", stringOf(submitted["ticketKey"])} {
		if forbidden != "" && strings.Contains(raw, forbidden) {
			t.Fatalf("反馈日志泄露了 %q：%s", forbidden, raw)
		}
	}
	for _, entry := range buffer.entries(t) {
		if strings.Contains(strings.ToLower(stringOf(entry["msg"])), "ticket") {
			t.Fatalf("日志消息里出现了凭据字样：%v", entry)
		}
	}
}

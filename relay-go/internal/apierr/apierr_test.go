package apierr_test

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
)

// newRequest 造一个带 requestId 与路由模板的请求，贴近生产中间件链的形态。
func newRequest() *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/devices", nil)
	r.Pattern = "GET /devices"
	r = r.WithContext(reqctx.With(r.Context(), reqctx.NewScope("req_test123")))
	return r
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// TestWriteStoreErrorBusy 验证 busy 映射：503 + Retry-After: 1 + 信封 db/busy，
// 且 5xx 带 requestId。
func TestWriteStoreErrorBusy(t *testing.T) {
	recorder := httptest.NewRecorder()
	busy := errors.New("database is locked")
	code := apierr.WriteStoreError(recorder, newRequest(), discardLogger(),
		func(err error) bool { return errors.Is(err, busy) }, busy,
		"internal/error", "the relay could not complete this request")

	if code != "db/busy" {
		t.Errorf("返回 code = %q，期望 db/busy", code)
	}
	response := recorder.Result()
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status = %d，期望 503", response.StatusCode)
	}
	if got := response.Header.Get("Retry-After"); got != "1" {
		t.Errorf("Retry-After = %q，期望 1", got)
	}
	var envelope apierr.Envelope
	if err := json.NewDecoder(response.Body).Decode(&envelope); err != nil {
		t.Fatalf("响应不是合法 JSON：%v", err)
	}
	if envelope.OK {
		t.Error("信封 ok 应为 false")
	}
	if envelope.RequestID != "req_test123" {
		t.Errorf("requestId = %q，期望 req_test123", envelope.RequestID)
	}
	if envelope.Error.Code != "db/busy" ||
		envelope.Error.Message != "the relay database is busy; retry shortly" {
		t.Errorf("信封 error = %+v，期望 db/busy 固定文案", envelope.Error)
	}
}

// TestWriteStoreErrorPlain 验证非 busy 映射：500 + 调用方给的 code/message，
// 无 Retry-After。
func TestWriteStoreErrorPlain(t *testing.T) {
	recorder := httptest.NewRecorder()
	err := errors.New("disk full")
	code := apierr.WriteStoreError(recorder, newRequest(), discardLogger(),
		func(error) bool { return false }, err,
		"internal/error", "the relay could not complete this request")

	if code != "internal/error" {
		t.Errorf("返回 code = %q，期望 internal/error", code)
	}
	response := recorder.Result()
	if response.StatusCode != http.StatusInternalServerError {
		t.Errorf("status = %d，期望 500", response.StatusCode)
	}
	if got := response.Header.Get("Retry-After"); got != "" {
		t.Errorf("非 busy 不应带 Retry-After，实得 %q", got)
	}
	var envelope apierr.Envelope
	if err := json.NewDecoder(response.Body).Decode(&envelope); err != nil {
		t.Fatalf("响应不是合法 JSON：%v", err)
	}
	if envelope.RequestID != "req_test123" {
		t.Errorf("requestId = %q，期望 req_test123", envelope.RequestID)
	}
	if envelope.Error.Code != "internal/error" ||
		envelope.Error.Message != "the relay could not complete this request" {
		t.Errorf("信封 error = %+v，期望沿用调用方的 code/message", envelope.Error)
	}
}

// TestWriteForRequestIDOnlyOn5xx 验证 4xx 不带 requestId、5xx 带。
func TestWriteForRequestIDOnlyOn5xx(t *testing.T) {
	recorder := httptest.NewRecorder()
	apierr.WriteFor(recorder, newRequest(), http.StatusBadRequest, "pair/bad-request", "bad", nil)
	var fourxx apierr.Envelope
	if err := json.NewDecoder(recorder.Result().Body).Decode(&fourxx); err != nil {
		t.Fatalf("响应不是合法 JSON：%v", err)
	}
	if fourxx.RequestID != "" {
		t.Errorf("4xx 不应带 requestId，实得 %q", fourxx.RequestID)
	}
	if strings.Contains(recorder.Body.String(), "requestId") {
		t.Error("4xx 响应字节里不应出现 requestId 字段（omitempty）")
	}

	recorder = httptest.NewRecorder()
	apierr.WriteFor(recorder, newRequest(), http.StatusInternalServerError,
		"internal/error", "boom", nil)
	var fivexx apierr.Envelope
	if err := json.NewDecoder(recorder.Result().Body).Decode(&fivexx); err != nil {
		t.Fatalf("响应不是合法 JSON：%v", err)
	}
	if fivexx.RequestID != "req_test123" {
		t.Errorf("5xx requestId = %q，期望 req_test123", fivexx.RequestID)
	}
}

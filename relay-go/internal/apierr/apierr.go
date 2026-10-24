// Package apierr 是全站唯一的错误信封实现：`{"ok":false,"error":{...}}`。
//
// HTTP 面（internal/httpapi）与 WebSocket 握手（internal/wsapi）都要写这种响应，
// 两处各写一份迟早会漂移——错误形状是契约的一部分（DESIGN §6/§7：5xx 也必须是
// JSON），所以只在这里定义一次。
package apierr

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
)

// Body 是错误信封里的 error 对象；details 可选，内容不属于契约。
type Body struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

// Envelope 是全站唯一的错误形状：{"ok": false, "error": {...}}。
//
// RequestID 只在 5xx 上出现（omitempty）：运维拿到一个 500 就能按这个 id 去日志
// 与告警队列里找同一次请求。4xx 是协议的一部分，不占用这个字段，旧响应逐字不变。
type Envelope struct {
	OK        bool   `json:"ok"`
	RequestID string `json:"requestId,omitempty"`
	Error     Body   `json:"error"`
}

// Write 写一次错误信封（不带 requestId，与旧响应逐字一致），返回实际写出的 code。
func Write(w http.ResponseWriter, status int, code, message string, details map[string]any) string {
	return WriteWithRequestID(w, status, code, message, details, "")
}

// WriteWithRequestID 与 Write 相同，但把 requestId 写进信封顶层。
//
// 调用方只应在 5xx 上带 id（见 Envelope 的注释）；空 id 时与 Write 逐字一致。
// 返回实际写出的 code（序列化兜底路径与传入值不同，见函数体）。
func WriteWithRequestID(w http.ResponseWriter, status int, code, message string,
	details map[string]any, requestID string) string {
	payload, err := json.Marshal(Envelope{OK: false, RequestID: requestID, Error: Body{
		Code: code, Message: message, Details: details,
	}})
	if err != nil {
		// 结构体不可能序列化失败；真发生了也必须给可解析的信封，不能回退纯文本。
		const fallbackCode = "internal/error"
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"` + fallbackCode + `",` +
			`"message":"the relay could not encode this response"}}`))
		return fallbackCode
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(payload)
	return code
}

// WriteFor 写一次错误信封；5xx 额外带上这次请求的 requestId，返回实际写出的 code。
//
// 只有 5xx 带：4xx 是协议的一部分，响应形状保持与 Python 版逐字一致；5xx 是
// 事故，运维要能用响应里的 id 直接检索日志与告警。
func WriteFor(w http.ResponseWriter, r *http.Request, status int, code, message string,
	details map[string]any) string {
	if status >= 500 {
		return WriteWithRequestID(w, status, code, message, details, reqctx.ID(r.Context()))
	}
	return Write(w, status, code, message, details)
}

// WriteStoreError 把仓储层错误兜底成 5xx JSON 信封，返回实际写出的 code。
//
// busy/locked（isBusy 判定，由调用方传入，apierr 不依赖 store）按契约映射成
// 503 + Retry-After + 信封 db/busy；其余按 500 + 调用方给的 code/message。
// 日志字段与历史 httpapi 版一致（requestId/method/route/status/error），
// route 取注册路由模板，空则 <unmatched>，不落原始路径。
func WriteStoreError(w http.ResponseWriter, r *http.Request, log *slog.Logger,
	isBusy func(error) bool, err error, code, message string) string {
	if isBusy(err) {
		w.Header().Set("Retry-After", "1")
		log.Warn("relay: request failed",
			"requestId", reqctx.ID(r.Context()), "method", r.Method,
			"route", reqctx.RouteTemplate(r), "status", http.StatusServiceUnavailable,
			"error", err)
		return WriteFor(w, r, http.StatusServiceUnavailable, "db/busy",
			"the relay database is busy; retry shortly", nil)
	}
	log.Error("relay: request failed",
		"requestId", reqctx.ID(r.Context()),
		"method", r.Method, "route", reqctx.RouteTemplate(r), "error", err)
	return WriteFor(w, r, http.StatusInternalServerError, code, message, nil)
}

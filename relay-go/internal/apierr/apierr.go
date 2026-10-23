// Package apierr 是全站唯一的错误信封实现：`{"ok":false,"error":{...}}`。
//
// HTTP 面（internal/httpapi）与 WebSocket 握手（internal/wsapi）都要写这种响应，
// 两处各写一份迟早会漂移——错误形状是契约的一部分（DESIGN §6/§7：5xx 也必须是
// JSON），所以只在这里定义一次。
package apierr

import (
	"encoding/json"
	"net/http"
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

// Write 写一次错误信封（不带 requestId，与旧响应逐字一致）。
func Write(w http.ResponseWriter, status int, code, message string, details map[string]any) {
	WriteWithRequestID(w, status, code, message, details, "")
}

// WriteWithRequestID 与 Write 相同，但把 requestId 写进信封顶层。
//
// 调用方只应在 5xx 上带 id（见 Envelope 的注释）；空 id 时与 Write 逐字一致。
func WriteWithRequestID(w http.ResponseWriter, status int, code, message string,
	details map[string]any, requestID string) {
	payload, err := json.Marshal(Envelope{OK: false, RequestID: requestID, Error: Body{
		Code: code, Message: message, Details: details,
	}})
	if err != nil {
		// 结构体不可能序列化失败；真发生了也必须给可解析的信封，不能回退纯文本。
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"internal/error",` +
			`"message":"the relay could not encode this response"}}`))
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(payload)
}

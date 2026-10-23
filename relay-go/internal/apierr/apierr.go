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
type Envelope struct {
	OK    bool `json:"ok"`
	Error Body `json:"error"`
}

// Write 写一次错误信封。
func Write(w http.ResponseWriter, status int, code, message string, details map[string]any) {
	payload, err := json.Marshal(Envelope{OK: false, Error: Body{
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

// Package httpjson 是 HTTP 层的 JSON 请求体与响应写入规则。
//
// 它存在的原因是同一个口径要在两处用：普通端点（internal/httpapi，32 MB 上限）
// 与反馈四端点（internal/feedback，16 KB 上限）。解析规则（空正文 = {}、只接受单个
// JSON 对象、数字保留原文）必须一致，上限不同；把这个区别做成参数，规则就只留一份。
package httpjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
)

// Status 是一次请求体读取的结论。
type Status int

const (
	// OK 表示拿到了一个 JSON 对象（空正文按 {} 处理）。
	OK Status = iota
	// TooLarge 表示正文超过调用方给的上限。
	TooLarge
	// Invalid 表示读失败、不是合法 JSON，或者不是 JSON 对象。
	Invalid
)

// ReadObject 按 limit 字节上限读一个 JSON 对象。
//
// 口径与 Python 版 api.read_json 一致：
//   - 空正文（或全空白）= 空对象 `{}`，不是错误；
//   - 非法 JSON、非对象（数组/字符串/数字）返回 Invalid；
//   - 数字按 json.Number 保留原文，调用方据此区分整数与浮点（Python 的 int 判定）。
func ReadObject(r *http.Request, limit int64) (map[string]any, Status) {
	raw, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		return nil, Invalid
	}
	if int64(len(raw)) > limit {
		return nil, TooLarge
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return map[string]any{}, OK
	}

	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, Invalid
	}
	// Python 的 json.loads 不允许正文后面还有别的内容，这里同样只接受单个值。
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, Invalid
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, Invalid
	}
	return object, OK
}

// WriteJSON 写一次 JSON 响应。
func WriteJSON(w http.ResponseWriter, status int, payload any) {
	body, err := json.Marshal(payload)
	if err != nil {
		// 走到这里说明响应结构本身有问题；5xx 也必须是可解析的信封，不能回纯文本。
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"ok":false,"error":{"code":"internal/error",` +
			`"message":"the relay could not encode this response"}}`))
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// Int 只接受"整数字面量"的 JSON 数字，对应 Python 的 isinstance(value, int)。
//
// 带小数点或指数的（600.0 / 6e2）在 Python 里是 float，会走"不是整数"的分支；
// 字符串、布尔、null 同样不通过。
func Int(value any) (int64, bool) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, false
	}
	parsed, err := number.Int64()
	if err != nil {
		return 0, false
	}
	return parsed, true
}

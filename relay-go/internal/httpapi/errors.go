package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/authn"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/httpjson"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// maxBodyBytes 是单次请求正文上限，与 Python 版 aiohttp 的 client_max_size
// （dlp.MAX_FRAME_BYTES = 32 MB）一致。
const maxBodyBytes = 32 << 20

// writeJSON 写一次 JSON 响应（规则由 internal/httpjson 只留一份）。
func writeJSON(w http.ResponseWriter, status int, payload any) {
	httpjson.WriteJSON(w, status, payload)
}

// writeError 写一次错误信封（形状由 internal/apierr 统一定义，WS 握手用同一份）。
func writeError(w http.ResponseWriter, status int, code, message string, details map[string]any) {
	apierr.Write(w, status, code, message, details)
}

// writeErrorFor 写一次错误信封；5xx 额外带上这次请求的 requestId。
//
// 只有 5xx 带：4xx 是协议的一部分，响应形状保持与 Python 版逐字一致；5xx 是
// 事故，运维要能用响应里的 id 直接检索日志与告警。
func writeErrorFor(w http.ResponseWriter, r *http.Request, status int, code, message string,
	details map[string]any) {
	if status >= 500 {
		apierr.WriteWithRequestID(w, status, code, message, details,
			reqctx.ID(r.Context()))
		return
	}
	apierr.Write(w, status, code, message, details)
}

// readJSONObject 把请求体解析成 JSON 对象，口径与 Python 版 api.read_json 一致：
//
//   - 空正文（或全空白）= 空对象 `{}`，不是错误；
//   - 非法 JSON、非对象（数组/字符串/数字）返回 ok=false；
//   - 数字按 json.Number 保留原文，调用方据此区分整数与浮点（Python 的 int 判定）。
func readJSONObject(r *http.Request) (map[string]any, bool) {
	body, status := httpjson.ReadObject(r, maxBodyBytes)
	return body, status == httpjson.OK
}

// jsonInt 只接受"整数字面量"的 JSON 数字，对应 Python 的 isinstance(value, int)。
//
// 带小数点或指数的（600.0 / 6e2）在 Python 里是 float，会走"不是整数"的分支；
// 字符串、布尔、null 同样不通过。判定规则由 internal/httpjson 只留一份。
func jsonInt(value any) (int64, bool) { return httpjson.Int(value) }

// stringValue 取字符串字段；缺失或类型不对时返回空串。
func stringValue(value any) string {
	text, _ := value.(string)
	return text
}

// marshalCompact 把已解析的 JSON 值重新编码成紧凑形式，与 Python
// json.dumps(..., ensure_ascii=False, separators=(",", ":")) 的口径一致。
//
// 不转义 HTML 字符：Python 默认也不转义，两边存进库里的文本因此可互读。
func marshalCompact(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	encoded := bytes.TrimSuffix(buffer.Bytes(), []byte("\n"))
	out := make([]byte, len(encoded))
	copy(out, encoded)
	return out, nil
}

// writeStoreError 把仓储层错误兜底成 5xx JSON 信封。
//
// busy/locked 按 DESIGN §6 映射成 503 + Retry-After；其余按 500。所有 5xx 都是
// JSON，绝不回退到 Go 的纯文本错误页。
func (s *server) writeStoreError(w http.ResponseWriter, r *http.Request, err error) {
	if store.IsBusy(err) {
		w.Header().Set("Retry-After", "1")
		s.log().Warn("relay: request failed",
			"requestId", reqctx.ID(r.Context()), "method", r.Method,
			"route", routeTemplate(r), "status", http.StatusServiceUnavailable,
			"error", err)
		writeErrorFor(w, r, http.StatusServiceUnavailable, "db/busy",
			"the relay database is busy; retry shortly", nil)
		return
	}
	s.log().Error("relay: request failed",
		"requestId", reqctx.ID(r.Context()),
		"method", r.Method, "route", routeTemplate(r), "error", err)
	writeErrorFor(w, r, http.StatusInternalServerError, "internal/error",
		"the relay could not complete this request", nil)
}

// log 返回服务器的 logger；测试里没有配置时用一个丢弃输出的实例。
func (s *server) log() *slog.Logger {
	if s.logger != nil {
		return s.logger
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// trimSpace 是 strings.TrimSpace 的短别名，避免每处都 import strings。
func trimSpace(value string) string { return strings.TrimSpace(value) }

// bearerToken 只是 authn.BearerToken 的本地别名：HTTP 与 WS 读的是同一个头，
// 解析口径只允许有一份。
func bearerToken(r *http.Request) string { return authn.BearerToken(r) }

package httpapi

import (
	"log/slog"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
)

// DefaultSlowRequest 是"慢请求"的判定线（P0：>500 ms 用 WARN 记一条）。
const DefaultSlowRequest = 500 * time.Millisecond

// 访问日志的三个档位。字符串口径与 --access-log 的取值一一对应。
const (
	AccessLogOff    = "off"
	AccessLogErrors = "errors"
	AccessLogAll    = "all"
)

// NormalizeAccessLog 把配置值规整成三档之一；认不出的值回退默认（errors）。
//
// 校验发生在 config.Validate（启动时报错）；这里是最后一道兜底，保证运行期
// 只会看到三个合法值之一。
func NormalizeAccessLog(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case AccessLogOff:
		return AccessLogOff
	case AccessLogAll:
		return AccessLogAll
	default:
		return AccessLogErrors
	}
}

// accessLog 是访问日志中间件：它只观察，不改变响应。
//
// 级别口径：5xx 用 ERROR、慢请求用 WARN、其余 INFO。档位决定"记不记"：
//   - off：一条不记；
//   - errors（默认）：只记 5xx 与慢请求；
//   - all：每个请求一条。
//
// 字段与隐私边界见 relay-go/README.md「日志字段」：只记模板路由（不记 query
// 值与真实路径）、方法、状态码、耗时、来源 IP、响应字节与认证后的身份；
// 不记 token、Authorization、请求正文或完整文件路径。
func (s *server) accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		observed := &observingWriter{ResponseWriter: w}
		start := time.Now()
		defer func() {
			if recovered := recover(); recovered != nil {
				// 内层异常兜底已经把 500 写掉；走到这里的只有 http.ErrAbortHandler
				// （主动中止）这类不该记成一次正常响应的路径。原样继续抛给 net/http。
				panic(recovered)
			}
			s.noteAccess(r, observed, time.Since(start))
		}()
		next.ServeHTTP(observed, r)
	})
}

// noteAccess 写一条访问日志（档位与级别在 accessLog 的注释里）。
func (s *server) noteAccess(r *http.Request, observed *observingWriter, elapsed time.Duration) {
	mode := s.accessLogMode
	if mode == "" {
		mode = AccessLogErrors // 直接构造 server 的调用方（测试）拿到的也是默认档位
	}
	if mode == AccessLogOff {
		return
	}
	status := observed.status
	if status == 0 {
		// 没有 WriteHeader：WebSocket 升级由 socket 直接写 101，普通 handler 没写
		// 状态行时 net/http 会替我们回 200。两种都还原成真实的语义。
		if isUpgradeRequest(r) {
			status = http.StatusSwitchingProtocols
		} else {
			status = http.StatusOK
		}
	}
	slow := elapsed >= s.slowRequest
	if mode == AccessLogErrors && status < 500 && !slow {
		return
	}

	level := slog.LevelInfo
	message := "relay: access"
	if status >= 500 {
		level = slog.LevelError
	} else if slow {
		level = slog.LevelWarn
		message = "relay: slow request"
	}
	agentID, deviceID := reqctx.From(r.Context()).Actor()
	args := []any{
		"requestId", reqctx.ID(r.Context()),
		"method", r.Method,
		"route", routeTemplate(r),
		"status", status,
		"duration_ms", math.Round(elapsed.Seconds()*1000*1000) / 1000,
		"remote_ip", clientIdentifier(r),
		"bytes", observed.bytes,
	}
	if agentID != "" {
		args = append(args, "agentId", agentID)
	}
	if deviceID != "" {
		args = append(args, "deviceId", deviceID)
	}
	s.log().Log(r.Context(), level, message, args...)
}

// routeTemplate 返回注册时的方法+路径模板里的路径部分（如 `/files/down`）。
//
// Go 1.22 起 ServeMux 把自己匹配到的模板写进 http.Request.Pattern：它不含 query，
// 也不含真实分段值，正是"可按路由聚合、又不泄露参数"的形态。没匹配到路由
// （404）时没有模板，用 `<unmatched>` 表示，仍然不记录原始路径。
func routeTemplate(r *http.Request) string {
	pattern := strings.TrimSpace(r.Pattern)
	if pattern == "" {
		return "<unmatched>"
	}
	if _, path, found := strings.Cut(pattern, " "); found {
		return strings.TrimSpace(path)
	}
	return pattern
}

// isUpgradeRequest 判断这次请求是不是 WebSocket 升级（用于还原 101 状态）。
func isUpgradeRequest(r *http.Request) bool {
	return strings.EqualFold(strings.TrimSpace(r.Header.Get("Upgrade")), "websocket")
}

// observingWriter 记录状态码与响应字节数；它不改写任何响应。
//
// 实现 Unwrap（ResponseController / coder/websocket 顺着它找底层 writer）与
// Flush（文件下载的流式刷新）；不实现 Hijacker，避免改变升级路径的类型断言。
type observingWriter struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (w *observingWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *observingWriter) Write(payload []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	written, err := w.ResponseWriter.Write(payload)
	w.bytes += int64(written)
	return written, err
}

func (w *observingWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *observingWriter) Flush() {
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

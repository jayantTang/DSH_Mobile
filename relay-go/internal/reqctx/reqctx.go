// Package reqctx 是请求作用域诊断信息的唯一所有者：requestId 与认证后的身份。
//
// 为什么要有这个包：一次 5xx 要能把 HTTP 响应、日志与告警串起来，串起来的东西
// 必须只有一个来源。requestId 的生成/透传规则、头部名、允许的字符集，以及
// "谁认出来了"（agentId/deviceId），都只在这里定义一份；httpapi、wsapi、files、
// feedback、monitor 都从 context 读同一份。
//
// 隐私：这里只存标识，不存令牌、Authorization、正文或路径。身份由认证成功的那
// 一步写入（NoteAgent/NoteDevice），日志中间件只读。
package reqctx

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"sync"
)

// Header 是请求级关联 ID 的 HTTP 头（请求可自带，响应必回写）。
const Header = "X-Request-Id"

// maxIDLength 是透传 ID 的长度上限：够 UUID/ULID/traceparent 用，也挡住把日志
// 字段撑爆的恶意头。
const maxIDLength = 128

// Scope 是一次请求的诊断作用域。
//
// 身份字段会被认证路径并发写入（同一个请求里先认设备再查电脑），日志中间件在
// 请求结束时读取，所以用一把小锁而不是裸字段。
type Scope struct {
	id string

	mu       sync.Mutex
	agentID  string
	deviceID string
}

// NewScope 建一个带固定 requestId 的作用域。
func NewScope(id string) *Scope { return &Scope{id: id} }

// ID 是这个作用域的 requestId（作用域本身永远不会是 nil）。
func (s *Scope) ID() string {
	if s == nil {
		return ""
	}
	return s.id
}

// SetAgent / SetDevice 记下认证成功后的身份（空串表示"还没认出来"）。
func (s *Scope) SetAgent(id string) {
	if s == nil || id == "" {
		return
	}
	s.mu.Lock()
	s.agentID = id
	s.mu.Unlock()
}

func (s *Scope) SetDevice(id string) {
	if s == nil || id == "" {
		return
	}
	s.mu.Lock()
	s.deviceID = id
	s.mu.Unlock()
}

// Actor 返回这次请求认出来的身份（可能只有一个，也可能都没有）。
func (s *Scope) Actor() (agentID, deviceID string) {
	if s == nil {
		return "", ""
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.agentID, s.deviceID
}

type contextKey struct{}

// With 把作用域放进 context。
func With(ctx context.Context, scope *Scope) context.Context {
	return context.WithValue(ctx, contextKey{}, scope)
}

// From 取回作用域；没有时返回 nil。
func From(ctx context.Context) *Scope {
	scope, _ := ctx.Value(contextKey{}).(*Scope)
	return scope
}

// ID 是 From(ctx).ID() 的短写。
func ID(ctx context.Context) string { return From(ctx).ID() }

// NoteAgent / NoteDevice 是认证路径上唯一的身份写入点（没有作用域时是空操作）。
func NoteAgent(ctx context.Context, id string)  { From(ctx).SetAgent(id) }
func NoteDevice(ctx context.Context, id string) { From(ctx).SetDevice(id) }

// NewID 生成一个中转自己的 requestId：`req_` + 8 字节随机数的十六进制。
//
// 随机而不是自增：中转重启后编号不重复，跨机器抓日志也不会撞。
func NewID() string {
	var raw [8]byte
	if _, err := rand.Read(raw[:]); err != nil {
		// 熵源坏掉时宁可没有 ID 也不能 panic 掉请求；中间件会把它当成"没带"。
		return ""
	}
	return "req_" + hex.EncodeToString(raw[:])
}

// Sanitize 校验并规整一个外部传入的 requestId。
//
// 只接受 1..128 个 [A-Za-z0-9._:-]：这些字符能安全地出现在 JSON 日志与 HTTP 头里，
// 换行/引号/控制字符一律不接受（否则就是日志注入）。不合法时返回空串，由调用方
// 换成新生成的 ID。
func Sanitize(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" || len(text) > maxIDLength {
		return ""
	}
	for index := 0; index < len(text); index++ {
		ch := text[index]
		switch {
		case ch >= 'a' && ch <= 'z':
		case ch >= 'A' && ch <= 'Z':
		case ch >= '0' && ch <= '9':
		case ch == '.', ch == '_', ch == ':', ch == '-':
		default:
			return ""
		}
	}
	return text
}

// Middleware 生成或透传 requestId，写进 context 与响应头。
//
// 它必须是**最外层**中间件：内层的 panic 兜底、访问日志与告警都要拿到同一个 ID。
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := Sanitize(r.Header.Get(Header))
		if id == "" {
			id = NewID()
		}
		scope := NewScope(id)
		if id != "" {
			w.Header().Set(Header, id)
		}
		next.ServeHTTP(w, r.WithContext(With(r.Context(), scope)))
	})
}

package httpapi

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/config"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/feedback"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/files"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/monitor"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/wsapi"
)

// 与 Python 版 hub.Limits 的默认值对齐。
//
// 这两个常量的**所有者**分别是 dlp（帧上限）与 hub（队列深度），这里只是给 M1 的
// 调用点留一个稳定的名字；数值不允许在这里另写一份。
const (
	// MaxFrameBytes 是单帧/单请求上限（Python dlp.MAX_FRAME_BYTES）。
	MaxFrameBytes = dlp.MaxFrameBytes
	// DefaultAgentQueueDepth 是连接器侧队列深度（hub.Limits 的默认值）。
	DefaultAgentQueueDepth = 4096
)

// CORS 响应头，与 Python api.CORS_HEADERS 逐项一致。
var corsHeaders = map[string]string{
	"access-control-allow-origin":   "*",
	"access-control-allow-methods":  "GET, POST, PUT, OPTIONS",
	"access-control-allow-headers":  "authorization, content-type, range, if-range",
	"access-control-expose-headers": "content-range, etag",
	"access-control-max-age":        "600",
}

// Limits 是 hub.Limits 的别名：限额只有一个所有者在 hub，/stats 报的与转发实行的
// 是同一份数。别名保留是为了让 M1 的调用点与单测不用改写法。
type Limits = hub.Limits

// DefaultLimits 返回与 Python 版一致的默认值。
func DefaultLimits() Limits { return hub.DefaultLimits() }

// Options 是装配一次 HTTP 服务需要的全部输入。
type Options struct {
	// Store 是本包自己用到的 15 个仓储方法（见 ports.go）；/healthz 不依赖它。
	Store Store
	// Health 是 /healthz 的版本与部署指纹。
	Health Health
	// PairTTL / DeviceTTL 是配对码与设备令牌的有效期；零值取 Python 默认值。
	PairTTL   time.Duration
	DeviceTTL time.Duration
	// MaxPairedDevices 是一个账户未撤销设备的上限（0 = 不限）。
	MaxPairedDevices int
	// Limits 是构造 hub 时的限额输入；Hub 非空时忽略（以 Hub 的为准）。
	Limits Limits
	// Hub 是活连接的所有者。为空时按 Limits 建一个**没有转发**的实例，
	// 让 /stats 与账户状态通知在单测里也能跑（生产由 main 注入）。
	Hub *hub.Hub
	// BasePath 是可选挂载前缀；带前缀与去前缀两种形式都服务。
	BasePath string
	// Logger 可选；为空时错误日志丢弃。
	Logger *slog.Logger
	// Monitor 是异常监控（panic 与 5xx）；nil = 只做 panic 兜底、不记录。
	Monitor *monitor.Monitor
	// Push 是 APNs 投递器；只在本包自己造 hub（Hub 为空）时用得上。
	Push hub.PushSender
	// WS / Files / Feedback 是三个子 handler，由组合根构造后注入（DESIGN §2.5）。
	//
	// 本包不再 new 它们：httpapi 的端口只有 15 个方法，凑不出 wsapi 的 4 个与
	// feedback 的 9 个；把三者并成一个更大的接口等于换个名字的上帝接口。
	// nil = 该组路由不挂（生产始终注入；只有 /healthz 这类单测会留空）。
	WS       *wsapi.Handlers
	Files    *files.Handlers
	Feedback *feedback.Handlers
	// AccessLog 是访问日志档位：off / errors（默认）/ all。空值取 errors。
	AccessLog string
	// SlowRequest 是"慢请求"判定线；零值取 DefaultSlowRequest（500 ms）。
	SlowRequest time.Duration
}

// server 持有一份不可变配置与两个限流桶。
type server struct {
	store            Store
	health           Health
	pairTTLMS        int64
	deviceTTLMS      int64
	maxPairedDevices int
	basePath         string
	logger           *slog.Logger

	// hub 是活连接与限额的唯一所有者；/stats、撤销断开与账户状态通知都问它。
	hub *hub.Hub
	// ws 是两条 /link/* 端点。
	ws *wsapi.Handlers
	// files 是两条文件通道端点；桥的状态机在 hub，这里只是 HTTP 面。
	files *files.Handlers
	// feedback 是反馈四端点；线程/留言的读写归 store，限流与校验归它自己。
	feedback *feedback.Handlers

	claimLimiter  *ClaimLimiter
	enrollLimiter *ClaimLimiter
	// internalResolveLimiter 只服务 /internal/tokens/resolve（环回来源）。
	internalResolveLimiter *ClaimLimiter

	// 访问日志的档位与慢请求判定线（装配时定好，不再变）。
	accessLogMode string
	slowRequest   time.Duration
}

// 与 Python api.py 的限流口径一致。
const (
	claimFailures  = 10
	claimWindow    = 300 * time.Second
	enrollFailures = 5
	enrollWindow   = 900 * time.Second
)

// New 装配 serve 用的 HTTP 处理器（路由 + CORS + panic 兜底）。
//
// basePath 可以是 ""、"/dsh-link" 或未规范化的 "dsh-link/"；注册时两条路径都挂：
// 带前缀的原样转发与前端剥掉前缀（Caddy handle_path）都要能用，与 Python 版一致。
func New(opts Options) http.Handler {
	limits := opts.Limits
	if limits == (Limits{}) {
		limits = DefaultLimits()
	}
	liveHub := opts.Hub
	if liveHub == nil {
		// fallback hub 不接 Store：/stats 的 today 段走 errNoStore 的空段
		// （行为与"读库失败"一致），生产始终注入 Hub，故生产路径无可观察变化。
		liveHub = hub.New(hub.Options{
			Limits: limits, Logger: opts.Logger,
			Push: opts.Push, Monitor: opts.Monitor,
		})
	}
	slowRequest := opts.SlowRequest
	if slowRequest <= 0 {
		slowRequest = DefaultSlowRequest
	}
	s := &server{
		store:                  opts.Store,
		health:                 opts.Health,
		pairTTLMS:              durationMS(opts.PairTTL, store.DefaultPairTTLMS),
		deviceTTLMS:            durationMS(opts.DeviceTTL, store.DefaultDeviceTTLMS),
		maxPairedDevices:       opts.MaxPairedDevices,
		basePath:               config.NormalizeBasePath(opts.BasePath),
		logger:                 opts.Logger,
		hub:                    liveHub,
		claimLimiter:           NewClaimLimiter(claimFailures, claimWindow),
		enrollLimiter:          NewClaimLimiter(enrollFailures, enrollWindow),
		internalResolveLimiter: NewClaimLimiter(internalResolveLimit, internalResolveWindow),
		accessLogMode:          NormalizeAccessLog(opts.AccessLog),
		slowRequest:            slowRequest,
	}
	s.ws = opts.WS
	s.files = opts.Files
	s.feedback = opts.Feedback

	mux := http.NewServeMux()
	s.registerRoutes(mux, "")
	if s.basePath != "" {
		s.registerRoutes(mux, s.basePath)
	}
	// 顺序固定：requestId 最外层（内层都要读它）→ 访问日志 → CORS → 异常兜底。
	// 异常兜底在内层，访问日志才看得到它写出的 500；CORS 在兜底之外，升级/普通
	// 响应的 ACAO 与旧行为一致。
	return reqctx.Middleware(s.accessLog(
		corsMiddleware(monitor.Middleware(opts.Monitor, s.log())(mux))))
}

// durationMS 把时长换成毫秒；零值取 fallback（Python 的默认值）。
func durationMS(value time.Duration, fallback int64) int64 {
	if value <= 0 {
		return fallback
	}
	return value.Milliseconds()
}

// registerRoutes 把全部 M1 路由挂到 mux 上；prefix 为空或挂载前缀。
func (s *server) registerRoutes(mux *http.ServeMux, prefix string) {
	handle := func(method, path string, handler http.HandlerFunc) {
		mux.HandleFunc(method+" "+prefix+path, handler)
	}

	s.health.register(mux, prefix+"/healthz")
	handle(http.MethodGet, "/stats", s.handleStats)
	// 环回诊断快照：连接、队列、版本、最后错误（非环回 404，见 handler）。
	handle(http.MethodGet, "/debug/conns", s.handleDebugConns)
	handle(http.MethodPost, "/pair/claim", s.handlePairClaim)
	handle(http.MethodPost, "/pair/refresh", s.handlePairRefresh)
	handle(http.MethodPost, "/pair/code", s.handlePairCode)
	handle(http.MethodPost, "/pair/code/regenerate", s.handlePairCodeRegenerate)
	handle(http.MethodGet, "/devices", s.handleDevicesList)
	handle(http.MethodPost, "/devices/revoke", s.handleDevicesRevoke)
	handle(http.MethodPost, "/devices/push", s.handleDevicesPush)
	handle(http.MethodGet, "/account/state", s.handleAccountStateGet)
	handle(http.MethodPut, "/account/state", s.handleAccountStatePut)
	handle(http.MethodPost, "/agents/enroll", s.handleAgentsEnroll)
	// 文件通道：路由与鉴权在 handler 内部（与 Python 的 route 表一一对应）。
	if s.files != nil {
		s.files.Register(mux, prefix)
	}
	// 反馈通道：四个追加式端点，鉴权可选（无效令牌降级匿名）。
	if s.feedback != nil {
		s.feedback.Register(mux, prefix)
	}
	// 服务间端点（环回）：信件服务的运行时依赖，不对外。
	handle(http.MethodPost, "/internal/tokens/resolve", s.handleInternalTokenResolve)
	handle(http.MethodPost, "/internal/account-state/touch", s.handleInternalAccountStateTouch)
	// WebSocket 两条端点由 wsapi 自带（方法模式由它注册，前缀原样拼）。
	if s.ws != nil {
		s.ws.Register(mux, prefix)
	}
}

// corsMiddleware 应答所有路径的 OPTIONS，并给普通响应补上 ACAO。
//
// 用中间件而不是兜底路由：未知路径仍然是 404，不会变成让人困惑的 405。
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			for name, value := range corsHeaders {
				w.Header().Set(name, value)
			}
			w.WriteHeader(http.StatusNoContent)
			return
		}
		// 预检放行不等于正文可读：跨域响应同样必须有 ACAO。
		// 必须在 next 之前设置：net/http 在 WriteHeader 时快照响应头，
		// 之后再 Set 的头不会发到真实连接上（单测的 ResponseRecorder 漏检过）。
		w.Header().Set("access-control-allow-origin", "*")
		next.ServeHTTP(w, r)
	})
}

// deviceFromBearer 用 Bearer 设备令牌认人；ok=false 时调用方回 401。
//
// 认出来之后把 deviceId/agentId 记进请求作用域：访问日志的两个身份字段由此而来，
// 没有第二条"日志自己解析令牌"的路径。
func (s *server) deviceFromBearer(r *http.Request) (store.Device, bool, error) {
	token := bearerToken(r)
	if token == "" {
		return store.Device{}, false, nil
	}
	device, found, err := s.store.DeviceByToken(r.Context(), token)
	if err == nil && found {
		reqctx.NoteDevice(r.Context(), device.DeviceID)
		reqctx.NoteAgent(r.Context(), device.AgentID)
	}
	return device, found, err
}

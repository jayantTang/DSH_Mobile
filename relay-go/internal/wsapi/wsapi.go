// Package wsapi 是两条 WebSocket 端点的握手与读取面。
//
//	WS  /link/agent?agentId=<id>   电脑侧连接器，Bearer <agentSecret>
//	WS  /link/device?agentId=<id>  手机，Bearer <deviceToken> 或 dsh.device.<token>
//
// 这个包只做"认出是谁 + 跑读循环"：写队列、心跳、背压、路由与配额都在 internal/hub。
// 分界线的判据是"谁拥有这条连接的生命周期"——hub 拥有，所以关闭也由它执行；
// wsapi 只在读循环结束时告诉 hub"这条连接没了"。
package wsapi

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/coder/websocket"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/authn"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 连接收尾的等待上限。
//
// 关闭帧由写循环**先写**、再等对端回答，所以这里只是给"对端还没回"留一点余量：
// 等不到就直接断开，手机已经收到关闭码了。
const (
	closeWait  = 2 * time.Second
	refuseWait = 5 * time.Second
	touchWait  = 5 * time.Second
)

// SurrogateReporter 是"上游送来了落单代理项"的接收方（*monitor.Monitor 实现）。
//
// 用最小接口而不是 import internal/monitor：wsapi 只负责把 damaged 帧的事实交出去，
// 告警的分类、去重与落盘不归它。
type SurrogateReporter interface {
	NoteUnpairedSurrogates(agentID, deviceID, frameType string, damage dlp.SurrogateDamage)
}

// Options 是装配两条端点需要的输入。
type Options struct {
	Hub     *hub.Hub
	Store   *store.Store
	Logger  *slog.Logger
	Monitor SurrogateReporter
}

// Handlers 是 /link/agent 与 /link/device 的处理器。
type Handlers struct {
	hub    *hub.Hub
	store  *store.Store
	limits hub.Limits
	log    *slog.Logger
	// monitor 只收"修好了一个坏字符"这一类事件；nil = 不记。
	monitor SurrogateReporter
	// frames 是读缓冲池：一帧的生命周期是"读循环取 → 写循环还"，
	// 不再由 conn.Read 里的 io.ReadAll 每帧新建 512 B（M2.5 报告 §3）。
	frames *dlp.BufferPool
}

// New 建一对 WS 端点处理器。
func New(options Options) *Handlers {
	log := options.Logger
	if log == nil {
		log = slog.Default()
	}
	// 限额只有 hub 一个来源：握手时读的是转发真正在用的那一份。
	limits := hub.DefaultLimits()
	if options.Hub != nil {
		limits = options.Hub.Limits()
	}
	return &Handlers{
		hub: options.Hub, store: options.Store, limits: limits, log: log,
		monitor: options.Monitor, frames: dlp.NewBufferPool(),
	}
}

// Register 把两条路由挂到 mux 上（base path 的原样与去前缀两种形式由调用方各挂一次）。
func (h *Handlers) Register(mux *http.ServeMux, prefix string) {
	mux.HandleFunc("GET "+prefix+"/link/agent", h.ServeAgent)
	mux.HandleFunc("GET "+prefix+"/link/device", h.ServeDevice)
}

// ServeAgent 处理电脑侧连接：认人 → 升级 → 读循环 → 拆除。
func (h *Handlers) ServeAgent(w http.ResponseWriter, r *http.Request) {
	token := authn.BearerToken(r)
	if token == "" {
		apierr.Write(w, http.StatusUnauthorized, "auth/missing-token",
			"missing bearer token", nil)
		return
	}
	agent, found, err := h.store.AgentBySecret(r.Context(), token)
	if err != nil {
		h.log.Error("relay: agent lookup failed", "error", err)
		apierr.Write(w, http.StatusInternalServerError, "internal/error",
			"the relay could not complete this request", nil)
		return
	}
	if !found {
		apierr.Write(w, http.StatusUnauthorized, "auth/invalid-token",
			"unknown or disabled agent token", nil)
		return
	}
	if wanted := r.URL.Query().Get("agentId"); wanted != "" && wanted != agent.AgentID {
		apierr.Write(w, http.StatusForbidden, "auth/agent-mismatch",
			"agentId does not match the bearer token", nil)
		return
	}

	conn, err := h.accept(w, r)
	if err != nil {
		return // Accept 已经把拒绝写进 HTTP 响应
	}
	conn.SetReadLimit(int64(h.limits.MaxFrameBytes))

	link := h.hub.AttachAgent(r.Context(), agent, &sink{conn: conn})
	h.touchAgent(r.Context(), agent.AgentID)
	h.readAgent(r.Context(), conn, link)

	h.hub.DetachAgent(link)
	waitDone(link.Done(), closeWait)
	_ = conn.CloseNow()
}

// ServeDevice 处理手机侧连接。
func (h *Handlers) ServeDevice(w http.ResponseWriter, r *http.Request) {
	// 浏览器无法在 WS 握手设自定义头：头优先（iOS/连接器零感知），子协议兜底。
	token := authn.BearerToken(r)
	if token == "" {
		token = authn.DeviceSubprotocolToken(r)
	}
	if token == "" {
		apierr.Write(w, http.StatusUnauthorized, "auth/missing-token",
			"missing bearer token", nil)
		return
	}
	device, found, err := h.store.DeviceByToken(r.Context(), token)
	if err != nil {
		h.log.Error("relay: device lookup failed", "error", err)
		apierr.Write(w, http.StatusInternalServerError, "internal/error",
			"the relay could not complete this request", nil)
		return
	}
	if !found {
		apierr.Write(w, http.StatusUnauthorized, "auth/invalid-token",
			"unknown, revoked, or expired device token", nil)
		return
	}
	if wanted := r.URL.Query().Get("agentId"); wanted != "" && wanted != device.AgentID {
		apierr.Write(w, http.StatusForbidden, "auth/agent-mismatch",
			"agentId does not match the device token", nil)
		return
	}

	conn, err := h.accept(w, r)
	if err != nil {
		return
	}
	conn.SetReadLimit(int64(h.limits.MaxFrameBytes))

	// 设备上限：先把 socket 升起来，再用**一帧** error 说明原因，最后以 4012 关闭。
	// 升级前直接回 403 的话，手机只能看到"握手失败"，分不清是网络坏了还是电脑满了
	// （Python 版为此改过一次，见 relay._refuse_upgrade 的注释）。
	if h.limits.MaxDevicesPerAgent > 0 &&
		h.hub.DeviceBudgetExceeded(device.AgentID, device.DeviceID) {
		h.refuse(conn, "limit/devices",
			"this host already has as many devices connected as it allows",
			dlp.CloseDeviceLimit,
			map[string]any{"maxDevicesPerAgent": h.limits.MaxDevicesPerAgent})
		return
	}

	link, err := h.hub.AttachDevice(r.Context(), device, &sink{conn: conn})
	if err != nil {
		if errors.Is(err, hub.ErrDeviceLimit) {
			// 最后防线：预检查放行之后、升级期间别人挤满了名额。
			h.refuse(conn, "limit/devices",
				"this host already has as many devices connected as it allows",
				dlp.CloseDeviceLimit,
				map[string]any{"maxDevicesPerAgent": h.limits.MaxDevicesPerAgent})
			return
		}
		// AttachDevice 只有设备上限一种失败，已在上面处理；走到这里说明状态不对，
		// 但 socket 已经升级过了，只能用 DLP 帧说明原因，不能再写 HTTP 响应。
		h.log.Error("relay: could not attach a device",
			"deviceId", device.DeviceID, "error", err)
		h.refuse(conn, "internal/error", "the relay could not attach this device",
			1011, nil)
		return
	}
	h.touchDevice(r.Context(), device.DeviceID)
	h.readDevice(r.Context(), conn, link)

	h.hub.DetachDevice(link)
	waitDone(link.Done(), closeWait)
	_ = conn.CloseNow()
}

// accept 升级连接，并回显客户端提出的 `dsh.device.*` 子协议。
//
// 子协议回显是"服务端接受这个子协议"的唯一信号；不回显时浏览器与客户端库都可能
// 把握手判为失败（Python 版的 aiohttp WS 也是显式回显）。
func (h *Handlers) accept(w http.ResponseWriter, r *http.Request) (*websocket.Conn, error) {
	return websocket.Accept(w, r, &websocket.AcceptOptions{
		Subprotocols: authn.DeviceProtocolsOffered(r),
		// 鉴权靠令牌，不靠来源：手机 App 与网页端是跨源连接，Python 版同样不做
		// Origin 校验（中转前面还有 Caddy，真正的前置限制在那里）。
		InsecureSkipVerify: true,
		CompressionMode:    websocket.CompressionDisabled,
	})
}

// refuse 在**已升级**的 socket 上发一帧拒绝原因，然后干净关闭。
func (h *Handlers) refuse(conn *websocket.Conn, code, message string, closeCode int,
	details map[string]any) {
	payload, err := dlp.Encode(dlp.ErrorFrame(code, message, true, details))
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), refuseWait)
		_ = conn.Write(ctx, websocket.MessageText, payload)
		cancel()
	}
	_ = conn.Close(websocket.StatusCode(closeCode), message)
	h.log.Warn("relay: refused a device socket", "code", code, "reason", message)
}

// readAgent 是电脑侧读循环：解析、结构校验，然后交给 hub 路由。
//
// 电脑侧的坏帧**只记 debug、不回错误帧**（与 Python 一致）：连接器是我们自己的
// 代码，给它发错误帧只会让一条本来还能用的链路多一次往返。
func (h *Handlers) readAgent(ctx context.Context, conn *websocket.Conn, link *hub.AgentLink) {
	for {
		messageType, wire, damage, err := h.readWire(ctx, conn)
		if err != nil {
			if errors.Is(err, dlp.ErrInvalidFrame) {
				// 电脑侧的坏帧只记 debug、不回错误帧（与 Python 一致）。
				h.log.Debug("relay: bad frame from the agent",
					"link", link.Label(), "error", err)
				continue
			}
			h.logReadEnd(link.Label(), err)
			return
		}
		if messageType == websocket.MessageBinary {
			wire.Release()
			h.hub.SendControl(link, dlp.ErrorFrame("protocol/binary-unsupported",
				"binary frames are reserved for DLP v2", false, nil))
			continue
		}
		if damage != nil {
			h.noteSurrogate(link, wire, damage)
		}
		if problem := dlp.ValidateFromAgent(wire); problem != "" {
			wire.Release()
			h.log.Debug("relay: invalid frame from the agent",
				"link", link.Label(), "problem", problem)
			continue
		}
		h.hub.RouteFromAgent(link, wire)
	}
}

// readDevice 是手机侧读循环：坏帧回 `protocol/bad-frame`，二进制帧单独一个码，
// 都不把 socket 弄断（真正的结构错误由客户端修）。
func (h *Handlers) readDevice(ctx context.Context, conn *websocket.Conn, link *hub.DeviceLink) {
	for {
		messageType, wire, damage, err := h.readWire(ctx, conn)
		if err != nil {
			if errors.Is(err, dlp.ErrInvalidFrame) {
				h.hub.SendControl(link, dlp.ErrorFrame("protocol/bad-frame", err.Error(), false, nil))
				continue
			}
			h.logReadEnd(link.Label(), err)
			return
		}
		switch messageType {
		case websocket.MessageBinary:
			wire.Release()
			h.hub.SendControl(link, dlp.ErrorFrame("protocol/binary-unsupported",
				"binary frames are reserved for DLP v2", false, nil))
		default:
			if damage != nil {
				h.logSurrogate(link.Label(), wire.Type(), damage)
			}
			if problem := dlp.ValidateFromDevice(wire); problem != "" {
				wire.Release()
				h.hub.SendControl(link, dlp.ErrorFrame("protocol/bad-frame", problem, false, nil))
				continue
			}
			h.hub.RouteFromDevice(link, wire)
		}
	}
}

// readWire 把一条 WS 消息读进池化缓冲并扫描成转发视图。
//
// 缓冲的所有权在这里交出：成功返回的 Wire 持有它，调用方（读循环）负责最终归还；
// 入队成功时所有权会转移到写循环。
//
// 错误分两类，调用方据此决定"继续读"还是"收尾"：
//   - 坏帧（errors.Is(err, dlp.ErrInvalidFrame)）：缓冲已归还，回错误帧后继续读；
//   - 读失败：连接已经不可用，返回给 readXxx 记日志并收尾。
func (h *Handlers) readWire(ctx context.Context, conn *websocket.Conn) (
	websocket.MessageType, dlp.Wire, *dlp.SurrogateDamage, error) {
	buffer := h.frames.Get()
	messageType, err := readInto(ctx, conn, buffer)
	if err != nil {
		buffer.Release()
		return 0, dlp.Wire{}, nil, err
	}
	if messageType == websocket.MessageBinary {
		// 二进制帧不解析：交给读循环回 protocol/binary-unsupported。
		return messageType, dlp.Wire{}.WithBuffer(buffer), nil, nil
	}
	wire, damage, err := dlp.Scan(buffer.Bytes())
	if err != nil {
		// 坏帧的判定与文案来自 dlp.Scan（M2 的三种错误说明原样保留）。
		buffer.Release()
		return messageType, dlp.Wire{}, nil, err
	}
	return messageType, wire.WithBuffer(buffer), damage, nil
}

// readInto 把一整条 WS 消息读进 buffer，复用它的容量。
//
// 替代 conn.Read：后者内部是 io.ReadAll，每条消息都要新建一块 512 B 起的切片。
func readInto(ctx context.Context, conn *websocket.Conn, buffer *dlp.Buffer) (websocket.MessageType, error) {
	messageType, reader, err := conn.Reader(ctx)
	if err != nil {
		return 0, err
	}
	data := buffer.Bytes()[:0]
	emptyReads := 0
	for {
		if len(data) == cap(data) {
			// 扩容：append 一个字节再把长度收回来，让底层数组按 Go 的规则翻倍。
			data = append(data, 0)[:len(data)]
		}
		read, readErr := reader.Read(data[len(data):cap(data)])
		data = data[:len(data)+read]
		if errors.Is(readErr, io.EOF) {
			buffer.SetBytes(data)
			buffer.Headroom()
			return messageType, nil
		}
		if readErr != nil {
			return messageType, readErr
		}
		// Reader 不该返回 (0, nil)，真出现时也不能让读循环空转。
		if read == 0 {
			emptyReads++
			if emptyReads > 16 {
				return messageType, io.ErrNoProgress
			}
		}
	}
}

// logSurrogate 记一条"上游送来了坏字符"的诊断日志。
//
// Go 的 encoding/json 已经在解析时把落单代理项换成了 U+FFFD（见 internal/dlp），
// 所以这条日志**不是**"我们修好了"，而是定位上游根因的唯一线索：
// trailingChars 接近 0 说明坏字符卡在帧尾（典型是被按字符切分的流式分片截断）。
func (h *Handlers) logSurrogate(label, frameType string, damage *dlp.SurrogateDamage) {
	h.log.Warn("relay: repaired unpaired surrogate(s) carried by an upstream frame",
		"link", label, "frame", frameType, "count", damage.Count,
		"firstIndex", damage.FirstIndex, "totalBytes", damage.TotalChars,
		"trailingBytes", damage.TrailingChars, "kinds", damage.Kinds)
}

// noteSurrogate 记日志，并把"转发路径修好了一个坏字符"交给监控器。
//
// 只有 **agent → 设备** 的帧才进告警：那是 2026-10-17 事故的来源（按 UTF-8 计费时
// 编码失败），设备发来的坏帧由"校正客户端"那条路径处理，不属于同一类事故。
func (h *Handlers) noteSurrogate(link *hub.AgentLink, wire dlp.Wire,
	damage *dlp.SurrogateDamage) {
	frameType := wire.Type()
	h.logSurrogate(link.Label(), frameType, damage)
	if h.monitor == nil || !dlp.IsAgentToDevice(frameType) {
		return
	}
	deviceID := wire.FieldText("deviceId")
	if deviceID == "" {
		return
	}
	h.monitor.NoteUnpairedSurrogates(link.AgentID, deviceID, frameType, *damage)
}

// logReadEnd 只把异常结束记成 info：对端正常关闭是最常见的情况。
func (h *Handlers) logReadEnd(label string, err error) {
	if errors.Is(err, context.Canceled) || websocket.CloseStatus(err) != -1 {
		h.log.Info("relay: socket closed", "link", label,
			"status", int(websocket.CloseStatus(err)))
		return
	}
	h.log.Info("relay: socket read ended", "link", label, "error", err)
}

// touchAgent / touchDevice 记一次在线时间；失败不影响转发。
func (h *Handlers) touchAgent(parent context.Context, agentID string) {
	ctx, cancel := context.WithTimeout(parent, touchWait)
	defer cancel()
	if err := h.store.TouchAgent(ctx, agentID, 0); err != nil {
		h.log.Warn("relay: could not record the agent's last-seen time",
			"agentId", agentID, "error", err)
	}
}

func (h *Handlers) touchDevice(parent context.Context, deviceID string) {
	ctx, cancel := context.WithTimeout(parent, touchWait)
	defer cancel()
	if err := h.store.TouchDevice(ctx, deviceID, 0); err != nil {
		h.log.Warn("relay: could not record the device's last-seen time",
			"deviceId", deviceID, "error", err)
	}
}

// waitDone 等写循环退出，最多等 timeout。
func waitDone(done <-chan struct{}, timeout time.Duration) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
	}
}

// sink 把 coder/websocket 适配成 hub 需要的写口。
type sink struct {
	conn *websocket.Conn
}

func (s *sink) Write(ctx context.Context, payload []byte) error {
	return s.conn.Write(ctx, websocket.MessageText, payload)
}

func (s *sink) Ping(ctx context.Context) error { return s.conn.Ping(ctx) }

func (s *sink) Close(code int, reason string) error {
	return s.conn.Close(websocket.StatusCode(code), reason)
}

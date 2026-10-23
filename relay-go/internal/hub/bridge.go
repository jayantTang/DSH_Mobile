package hub

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// 文件桥（R-1 C-17 / C-19）。
//
// 一条 HTTP 请求与连接器 WebSocket 上的 `fs*` 回帧是两段不同的对话，bridge 就是
// 它们之间的汇合点：HTTP handler 等待，hub 的路由把回帧交给它。两个方向各有一种：
//
//   - PutBridge：`PUT /files/up`，请求体由手机推、每一片都被转发给连接器，最后等
//     一个 `fsPutDone`（或 `fsErr`）。
//   - FetchBridge：`GET /files/down`，请求方按片拉取，连接器的 `fsGetChunk` 进一个
//     有界队列，HTTP handler 一片一片写进响应体。
//
// 与 Python 版一样，这里**不持久化**：中断的上传由 App 从头重来，下载由 Range
// 续传。桥的名字（bid）只活在一次请求里。

// 桥的等待上限（Python api.BRIDGE_ACK_TIMEOUT_S）。
const (
	BridgeAckTimeout = 5 * time.Second
	// FetchQueueDepth 是一条下载桥最多攒多少片还没被 HTTP 侧取走（Python
	// FileFetchBridge.QUEUE_DEPTH = 8）。
	FetchQueueDepth = 8
)

// BridgeOutcome 是一条上行桥的终局。
//
// 三种结局只有一种会成立：成功（Path/Bytes 有值）、连接器拒绝（ErrCode 非空）、
// 电脑掉线（ErrCode = host/offline）。ErrCode 为空即成功。
type BridgeOutcome struct {
	ErrCode    string
	ErrMessage string
	Path       *string
	Bytes      *int64
}

// Failed 表示这次上传没有成功。
func (o BridgeOutcome) Failed() bool { return o.ErrCode != "" }

// bridge 是两种桥的共同接口（hub 的路由与断线收尾只认这三件事）。
type bridge interface {
	owner() *AgentLink
	// deliver 把连接器的一条回帧交给桥；false 表示读者已经走了（只可能发生在
	// 下载桥上——上传的读者是 HTTP 请求体，自己推完才等结果）。
	deliver(kind string, frame dlp.Frame) bool
	// fail 让等待中的请求立刻以错误结束（电脑掉线、进程收尾）。
	fail(reason string)
}

// ── 上行（PUT /files/up） ────────────────────────────────────────────────────

// PutBridge 是一次进行中的上传。
//
// 成功判定只有一个来源：连接器的 `fsPutDone`。ack 用来区分"连接器认识这族帧"与
// "版本太旧、静默忽略"——后者是唯一能检测出旧连接器的信号，所以 ack 有 5 秒期限。
type PutBridge struct {
	bid     string
	agent   *AgentLink
	log     *slog.Logger
	acked   chan struct{}
	ackOnce sync.Once
	done    chan struct{}
	doneOne sync.Once

	mu      sync.Mutex
	settled bool
	outcome BridgeOutcome
}

// Bid 是这次上传使用的桥标识（App 自带的那个，上行不重新铸）。
func (b *PutBridge) Bid() string { return b.bid }

func (b *PutBridge) owner() *AgentLink { return b.agent }

// deliver 处理连接器的一条上行回帧。
func (b *PutBridge) deliver(kind string, frame dlp.Frame) bool {
	switch kind {
	case "fsPutAck":
		b.markAcked()
	case "fsPutDone":
		b.settle(BridgeOutcome{
			Path:  optionalText(frame["path"]),
			Bytes: optionalInt(frame["bytes"]),
		})
	case "fsErr":
		// 连接器给的 code/message 原样带回手机：手机靠它判断"不该重试"。
		b.settle(BridgeOutcome{
			ErrCode:    textOr(frame["code"], "file/rejected"),
			ErrMessage: textOr(frame["message"], "the connector refused the upload"),
		})
		// 一次失败**也是答复**：在 fsPutBegin 就拒绝的连接器不会发 ack，不在这里
		// 放行的话调用方会白等满 5 秒，把"连接器说不行"报成"连接器太旧"。
		b.markAcked()
	}
	// 上传桥没有会中途走掉的读者：请求体由调用方推完，回帧全部落进同一个终局，
	// 所以这里永远返回 true。
	return true
}

func (b *PutBridge) fail(reason string) {
	b.settle(BridgeOutcome{ErrCode: "host/offline", ErrMessage: reason})
	b.markAcked()
}

// settle 写入终局（只认第一次）。
//
// 旧连接与新连接的读循环可能同时送来回帧（路由按 bid 认，不按 socket 认），所以
// 终局必须只落一次：先到的成功不能被后到的断线通知覆盖。
func (b *PutBridge) settle(outcome BridgeOutcome) {
	b.mu.Lock()
	if b.settled {
		b.mu.Unlock()
		return
	}
	b.settled = true
	b.outcome = outcome
	b.mu.Unlock()
	b.finish()
}

// delivered 报告终局是否已落定。
func (b *PutBridge) delivered() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.settled
}

// markAcked 放行 ack 等待（幂等）。
func (b *PutBridge) markAcked() {
	b.ackOnce.Do(func() { close(b.acked) })
}

// finish 让请求读到终局（幂等）。
func (b *PutBridge) finish() {
	b.doneOne.Do(func() { close(b.done) })
}

// WaitAck 等连接器接受这次传输。
//
// 超出 timeout 或请求被取消都返回 false；调用方据此回 501 "连接器版本过旧"。
func (b *PutBridge) WaitAck(ctx context.Context, timeout time.Duration) bool {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-b.acked:
		return true
	case <-timer.C:
		return false
	case <-ctx.Done():
		return false
	}
}

// TryOutcome 在终局已经到达时立刻返回它（不阻塞）。
//
// 用法是"begin 被拒绝"那条路：连接器在 fsPutBegin 就回 fsErr 时，ack 与终局
// 同时到达，调用方不必再读一个没人要的请求体。
func (b *PutBridge) TryOutcome() (BridgeOutcome, bool) {
	if !b.delivered() {
		return BridgeOutcome{}, false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.outcome, true
}

// WaitDone 等终局；ctx 取消时返回 false。
func (b *PutBridge) WaitDone(ctx context.Context) (BridgeOutcome, bool) {
	select {
	case <-b.done:
		b.mu.Lock()
		defer b.mu.Unlock()
		return b.outcome, true
	case <-ctx.Done():
		return BridgeOutcome{}, false
	}
}

// ── 下行（GET /files/down） ──────────────────────────────────────────────────

// FetchBridge 是一次进行中的下载。
//
// 与上行不同，下载是**一片一片拉**的：连接器的 `fsGetChunk` 进一个有界队列，
// HTTP handler 取一片写一片。队列必须有界——手机停止读取（关 App、切网）时，
// 不能让连接器把整份文件堆在中转内存里。
type FetchBridge struct {
	bid    string
	agent  *AgentLink
	log    *slog.Logger
	acked  chan struct{}
	frames chan dlp.Frame

	ackOnce sync.Once

	mu              sync.Mutex
	abandoned       bool
	cancelRequested bool
	size            *int64
	version         string
}

// Bid 是这次下载的桥标识（**由中转现铸**，不沿用 App 的 bid）。
func (b *FetchBridge) Bid() string { return b.bid }

func (b *FetchBridge) owner() *AgentLink { return b.agent }

// deliver 处理连接器的一条下行回帧。
//
// 返回 false 表示 HTTP 侧已经不读了（队列满，或桥已被放弃），路由层据此发
// `fsGetCancel` 让连接器停手。
func (b *FetchBridge) deliver(kind string, frame dlp.Frame) bool {
	if kind == "fsGetAck" {
		// size/version 是"可续传"的全部来源；两者都可缺失（旧连接器）。
		if size, ok := intValue(frame["size"]); ok && size >= 0 {
			b.mu.Lock()
			b.size = &size
			b.mu.Unlock()
		}
		if version, ok := frame["version"].(string); ok && version != "" {
			b.mu.Lock()
			b.version = version
			b.mu.Unlock()
		}
		b.ackOnce.Do(func() { close(b.acked) })
		// ack 是唯一**放弃之后仍然接受**的回帧：If-Range 切换时旧 run 的 ack 可能
		// 还在路上，而 ack 只带元数据、不可能污染正文。
		return true
	}

	b.mu.Lock()
	abandoned := b.abandoned
	b.mu.Unlock()
	if abandoned {
		return false
	}

	switch kind {
	case "fsErr":
		// 与上行同一条规则：把连接器自己的码原样交给手机。
		b.end(dlp.Frame{
			"_terminal": true,
			"error":     textOr(frame["code"], "file/rejected"),
			"message":   textOr(frame["message"], "the connector refused the download"),
		})
		return true
	case "fsGetChunk":
		select {
		case b.frames <- frame:
			return true
		default:
			b.log.Warn("relay: download is not being read; giving up", "bid", b.bid)
			b.mu.Lock()
			b.abandoned = true
			b.mu.Unlock()
			return false
		}
	case "fsGetEnd":
		b.end(frame)
		return true
	}
	return true
}

// end 把终局帧排在已经入队的片之后。
func (b *FetchBridge) end(frame dlp.Frame) {
	b.ackOnce.Do(func() { close(b.acked) })
	terminal := make(dlp.Frame, len(frame)+1)
	for key, value := range frame {
		terminal[key] = value
	}
	terminal["_terminal"] = true
	select {
	case b.frames <- terminal:
	default:
		// 读者已经走了；丢掉终局帧，没有人需要被通知。
		b.mu.Lock()
		b.abandoned = true
		b.mu.Unlock()
	}
}

func (b *FetchBridge) fail(reason string) {
	b.end(dlp.Frame{
		"error":   "host/offline",
		"message": reason,
	})
}

// WaitAck 等连接器接受这次下载（口径与上行相同）。
func (b *FetchBridge) WaitAck(ctx context.Context, timeout time.Duration) bool {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-b.acked:
		return true
	case <-timer.C:
		return false
	case <-ctx.Done():
		return false
	}
}

// NextFrame 取下一片；读者已放弃或 ctx 结束时返回 false。
func (b *FetchBridge) NextFrame(ctx context.Context) (dlp.Frame, bool) {
	b.mu.Lock()
	abandoned := b.abandoned
	b.mu.Unlock()
	if abandoned {
		return nil, false
	}
	select {
	case frame := <-b.frames:
		return frame, true
	case <-ctx.Done():
		return nil, false
	}
}

// Size 是连接器在 `fsGetAck` 里报告的文件总长；没报告时 ok=false。
func (b *FetchBridge) Size() (int64, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.size == nil {
		return 0, false
	}
	return *b.size, true
}

// Version 是连接器报告的文件版本；没有时为空（此时不发 ETag）。
func (b *FetchBridge) Version() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.version
}

// Abandon 表示 HTTP 侧不再读取：之后的片一律丢掉。
func (b *FetchBridge) Abandon() {
	b.mu.Lock()
	b.abandoned = true
	b.mu.Unlock()
}

// takeCancel 标记"已经为该桥发过 fsGetCancel"；返回 false 表示不必再发。
func (b *FetchBridge) takeCancel() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cancelRequested {
		return false
	}
	b.cancelRequested = true
	return true
}

// ── hub 侧的桥注册表与路由 ──────────────────────────────────────────────────

// OpenPutBridge 登记一次上传；同名 bid 会覆盖旧的登记（与 Python 一致：App 带着
// 同一个 bid 重试，连接器那边也是覆盖语义）。
func (h *Hub) OpenPutBridge(bid string, agent *AgentLink) *PutBridge {
	bridge := &PutBridge{
		bid: bid, agent: agent, log: h.log,
		acked: make(chan struct{}), done: make(chan struct{}),
	}
	h.bridgesMu.Lock()
	h.bridges[bid] = bridge
	h.bridgesMu.Unlock()
	return bridge
}

// OpenFetchBridge 登记一次下载。
func (h *Hub) OpenFetchBridge(bid string, agent *AgentLink) *FetchBridge {
	bridge := &FetchBridge{
		bid: bid, agent: agent, log: h.log,
		acked: make(chan struct{}), frames: make(chan dlp.Frame, FetchQueueDepth),
	}
	h.bridgesMu.Lock()
	h.bridges[bid] = bridge
	h.bridgesMu.Unlock()
	return bridge
}

// CloseBridge 摘掉一条登记（HTTP handler 的收尾，幂等）。
func (h *Hub) CloseBridge(bid string) {
	h.bridgesMu.Lock()
	delete(h.bridges, bid)
	h.bridgesMu.Unlock()
}

// bridgeFor 取一条登记；没有时返回 nil。
func (h *Hub) bridgeFor(bid string) bridge {
	h.bridgesMu.Lock()
	defer h.bridgesMu.Unlock()
	return h.bridges[bid]
}

// routeBridgeFrame 把连接器的一条 fs* 回帧交给等待它的请求。
//
// 没有被认领的帧（请求已经结束、或旧 run 的迟到分片）只能丢掉——这正是"旧 run
// 的分片不许落进新桥接"的唯一实现点。返回 false 让路由层发 fsGetCancel。
func (h *Hub) routeBridgeFrame(link *AgentLink, wire dlp.Wire) {
	frame, err := wire.Decode()
	if err != nil {
		h.log.Debug("relay: could not decode a file-bridge frame",
			"agentId", link.AgentID, "error", err)
		return
	}
	bid, _ := frame["bid"].(string)
	if bid == "" {
		h.log.Debug("relay: file-bridge frame without a bid",
			"agentId", link.AgentID, "frame", frame.Type())
		return
	}
	bridge := h.bridgeFor(bid)
	if bridge == nil {
		h.log.Debug("relay: no bridge waiting for a file-bridge frame",
			"agentId", link.AgentID, "frame", frame.Type(), "bid", bid)
		return
	}
	if bridge.deliver(frame.Type(), frame) {
		return
	}
	if fetch, ok := bridge.(*FetchBridge); ok {
		h.CancelFetch(link, fetch)
	}
}

// CancelFetch 告诉连接器停止为一条没人读的下载继续读文件。
//
// 每条桥最多发一次：连接器对不认识的 bid 是空操作，重复发虽然无害，但一次被顶替的
// run 会变成一串 fsGetCancel。帧走同一个连接发送队列，所以不可能越过它的
// fsGetBegin。
func (h *Hub) CancelFetch(link *AgentLink, bridge *FetchBridge) {
	if link == nil || bridge == nil {
		return
	}
	if !bridge.takeCancel() {
		return
	}
	h.SendControl(link, dlp.FetchCancelFrame(bridge.bid))
	h.log.Debug("relay: cancelling a download nobody is reading", "bid", bridge.bid)
}

// dropAgentBridges 让一条断掉（或被顶替）的连接器上的全部桥立刻结束。
//
// 没有这一步，上传请求会一直等到自己的超时、下载请求会等到 120 秒的静默上限；
// 用户看到的是"一直在传/一直在下"，而不是"失败了"。
func (h *Hub) dropAgentBridges(link *AgentLink, reason string) {
	h.bridgesMu.Lock()
	waiting := make([]bridge, 0, 4)
	for _, bridge := range h.bridges {
		if bridge.owner() == link {
			waiting = append(waiting, bridge)
		}
	}
	h.bridgesMu.Unlock()
	for _, bridge := range waiting {
		bridge.fail(reason)
	}
}

// failAllBridges 是进程收尾用的：所有等待中的请求都以 host/offline 结束。
func (h *Hub) failAllBridges(reason string) {
	h.bridgesMu.Lock()
	waiting := make([]bridge, 0, len(h.bridges))
	for _, bridge := range h.bridges {
		waiting = append(waiting, bridge)
	}
	h.bridgesMu.Unlock()
	for _, bridge := range waiting {
		bridge.fail(reason)
	}
}

// ── 帧字段的宽容读取 ────────────────────────────────────────────────────────

// textOr 取一个字符串字段；缺失或空串时用 fallback。
func textOr(value any, fallback string) string {
	if text, ok := value.(string); ok && text != "" {
		return text
	}
	return fallback
}

// optionalText 把可缺失的字符串字段保留成指针（响应里输出 null 而不是 ""）。
func optionalText(value any) *string {
	text, ok := value.(string)
	if !ok {
		return nil
	}
	return &text
}

// optionalInt 把可缺失的整数保留成指针。数字按 json.Number 解析（UseNumber），
// 浮点与字符串都不算。
func optionalInt(value any) *int64 {
	number, ok := intValue(value)
	if !ok {
		return nil
	}
	return &number
}

// intValue 只接受 JSON 整数字面量。
func intValue(value any) (int64, bool) {
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

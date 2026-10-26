package hub

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/bridge"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/push"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/quota"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// PushSender 是 hub 需要的 APNs 投递面（*push.Sender 实现；单测可注入桩）。
//
// 只暴露两个方法：hub 只负责"哪些设备要推"与"推完怎么记日志"，签名、HTTP/2、
// 限速都在 internal/push。
type PushSender interface {
	Enabled() bool
	SendMany(ctx context.Context, targets []push.Target, kind, sid string,
		eid *string, ignoreThrottle bool) []push.Result
}

// IncidentReporter 是"一条 agent 链路断了"与"帧被丢了"的接收方
// （*monitor.Monitor 实现）。
type IncidentReporter interface {
	NoteAgentDisconnect(agentID, name string)
	NoteControlDrop(link, frameType string)
	// NoteStreamDrop 记录一条连接的流式帧丢弃满了一个告警窗口
	// （dropped 是这个窗口里丢的帧数；链路标识里有 agentId/deviceId）。
	NoteStreamDrop(link string, dropped int64)
}

// Options 是装配一个 Hub 需要的全部输入。
type Options struct {
	// Store 是 hub 的仓储端口（hub.Store，10 个方法；见 ports.go）。
	Store Store
	// UsageSink 覆盖 quota 的落库/取数去处（Sink 的 3 个方法），nil 时用 Store。
	// 单测用它注入失败实现，验证"写失败就把这批放回内存"的回放路径；生产不设置。
	UsageSink        quota.Sink
	Limits           Limits
	Logger           *slog.Logger
	RelayVersion     string
	Heartbeat        time.Duration
	HeartbeatTimeout time.Duration
	WriteTimeout     time.Duration
	// ControlWait 是必达控制帧在优先队列满时的有界等待上限；零值取 5 秒。
	ControlWait time.Duration
	// Day 覆盖"本地日"的计算；单测用它验证跨日重置。默认 store.LocalDay。
	Day func() int64
	// UsageFlushInterval / UsageFlushBytes 是周期冲盘的两个触发条件（Python 的
	// hub.usage_flush_interval / usage_flush_bytes）；零值取默认 30s / 1 MiB。
	UsageFlushInterval time.Duration
	UsageFlushBytes    int64
	// RevokeReconcileInterval 是「库已撤销但 socket 还活着」的对账周期（Python 的
	// DLP_REVOKE_RECONCILE_S，默认 5 秒）；负数关闭（只给测试与极端场景用）。
	RevokeReconcileInterval time.Duration
	// Push 是 APNs 投递器；nil = 不推送（未配置的部署就是这样）。
	Push PushSender
	// Monitor 是异常监控；nil = 不记（测试与未配置的部署）。
	Monitor IncidentReporter
	// Presence 是连接器准入策略的窗口；零值取 presence 的默认（见该包的常量）。
	Presence presence.Options
}

// Hub 是活连接的编排者：准入、路由、背压、心跳与关停都在这里。
//
// 连接图（谁在线、谁挂在谁身上）归 registry（同包的 registry.go）：本类型只持有它
// 并调用它的方法，不直接碰分片 map。日额度、用量账本与每设备令牌桶的状态在
// internal/quota（DESIGN §3.3）；本类型持有它们的具体实现并对外委托，热路径仍然
// 只有一次具体方法调用。
//
// 锁的规则只有一条：**不同时持有两把分片锁**（锁在 registry 内部）。任何需要
// "先看 agent 再看设备"的操作都分成两步、各自加解锁，因此不存在交叉等待。
type Hub struct {
	store        Store
	limits       Limits
	log          *slog.Logger
	relayVersion string
	linkOptions  linkOptions

	// registry 是连接图三份索引的唯一写者与唯一读入口。
	registry *registry

	quota *quota.Ledger
	usage *quota.Usage

	// presence 是连接器准入策略：重复连接抑制、未验证连接器的退避与计数。
	// 它不持有连接，注册表仍然只有这里一份（见 internal/presence 的包注释）。
	presence *presence.Gate

	// push 是 APNs 投递器；monitor 是"断链""控制帧丢弃"告警的接收方。两者都是
	// 注入的，hub 不为推送与告警负责，只为它们取数。
	push    PushSender
	monitor IncidentReporter

	// controlDrops 是进程生命周期内被丢弃的可丢控制帧数（/stats 的 controlDrops）。
	// 它由 Link 在丢弃时经 onControlDrop 回调累计，是运维判"是否又在丢 pong"的唯一
	// 全局证据：连接一断，逐链路的计数就没了，恰好会在最需要它的时候归零。
	controlDrops atomic.Int64

	// opDeduped / opUncounted 是操作统计的卫生指标：前者说明重发被折叠，
	// 后者说明客户端没带稳定幂等键。两者都不进入 usageDaily。
	opDeduped   atomic.Uint64
	opUncounted atomic.Uint64

	// 周期任务的参数（见 StartBackground）。
	usageFlushInterval      time.Duration
	usageFlushBytes         int64
	revokeReconcileInterval time.Duration
	backgroundOnce          sync.Once

	// 文件桥登记表（bid → 桥）。状态机与锁都在 internal/bridge；这里只持有它，
	// 并在断线/顶替/关停时按连接身份收尾。
	bridges *bridge.Registry

	closed atomic.Bool
}

// New 建一个空的 hub。
func New(options Options) *Hub {
	limits := options.Limits.normalize()
	log := options.Logger
	if log == nil {
		log = slog.New(slog.NewTextHandler(discardWriter{}, nil))
	}
	today := options.Day
	if today == nil {
		today = store.LocalDay
	}
	// 额度与用量的仓储面（quota.Sink）默认就是 hub 的 Store 端口；单测可以整体
	// 换成一个会失败的实现，验证回放路径。
	sink := options.UsageSink
	if sink == nil && options.Store != nil {
		sink = options.Store
	}
	hub := &Hub{
		store:        options.Store,
		limits:       limits,
		log:          log,
		relayVersion: options.RelayVersion,
		push:         options.Push,
		monitor:      options.Monitor,
		linkOptions: linkOptions{
			heartbeat:        options.Heartbeat,
			heartbeatTimeout: options.HeartbeatTimeout,
			writeTimeout:     options.WriteTimeout,
			controlWait:      options.ControlWait,
		}.withDefaults(),
	}
	// 控制帧丢弃的记账回调要在 hub 建好之后挂：它需要 hub 的计数器与监控器。
	hub.linkOptions.onControlDrop = hub.noteControlDrop
	// 流式帧丢弃的告警同理（阈值窗口在 Link 里，这里只负责留证据）。
	hub.linkOptions.onStreamDrop = hub.noteStreamDrop
	hub.registry = newRegistry()
	hub.quota = quota.NewLedger(sink, limits.DeviceDailyBytes, today, log)
	hub.usage = quota.NewUsage(sink, today, log)
	hub.presence = presence.New(options.Presence)
	hub.bridges = bridge.NewRegistry(log)
	hub.usageFlushInterval = options.UsageFlushInterval
	if hub.usageFlushInterval <= 0 {
		hub.usageFlushInterval = DefaultUsageFlushInterval
	}
	hub.usageFlushBytes = options.UsageFlushBytes
	if hub.usageFlushBytes <= 0 {
		hub.usageFlushBytes = DefaultUsageFlushBytes
	}
	hub.revokeReconcileInterval = options.RevokeReconcileInterval
	if hub.revokeReconcileInterval == 0 {
		hub.revokeReconcileInterval = DefaultRevokeReconcileInterval
	}
	return hub
}

// discardWriter 吞掉未配置 logger 时的日志。
type discardWriter struct{}

func (discardWriter) Write(payload []byte) (int, error) { return len(payload), nil }

// Limits 返回生效中的限额（/stats 的唯一来源）。
func (h *Hub) Limits() Limits { return h.limits }

// RelayVersion 是中转自己的部署版本号（随 hostStatus 一起发给手机）。
func (h *Hub) RelayVersion() string { return h.relayVersion }

// ControlDrops 是进程启动以来被丢弃的可丢控制帧总数（/stats 的 controlDrops）。
func (h *Hub) ControlDrops() int64 { return h.controlDrops.Load() }

// PresenceStats 是连接生命周期的计数（/stats 的 superseded / reconnectStorm /
// unverifiedAgents 等字段的唯一来源）。
//
// 未验证连接数是 gauge：遍历注册表逐条问 presence「这一代连接报了版本没有」。
// 注册表仍然是「谁在线」的唯一所有者，presence 只回答某一代连接的状态。
func (h *Hub) PresenceStats() presence.Stats {
	stats := h.presence.Stats()
	now := time.Now()
	for _, agent := range h.registry.agents() {
		if h.presence.Unverified(agent.AgentID, agent.generation, now) {
			stats.UnverifiedAgents++
		}
	}
	return stats
}

// Devices 返回某个 agent 当前挂着的设备 id（按 id 排序，供诊断与测试）。
func (h *Hub) Devices(agentID string) []string {
	return h.registry.devices(agentID)
}

// Agent 返回 agentId 当前登记的那条连接（没有时 nil）。
func (h *Hub) Agent(agentID string) *AgentLink {
	return h.registry.agent(agentID)
}

// Device 返回 deviceId 当前登记的那条连接（没有时 nil）。
func (h *Hub) Device(deviceID string) *DeviceLink {
	return h.registry.device(deviceID)
}

// DeviceBudgetExceeded 判断再接入 deviceID 是否会超过这台电脑的设备上限。
//
// "设备上限"只有这一处定义：升级前的预检查（能在握手前干净地拒绝）与
// AttachDevice（最后一道防线）都问它，两条路径不可能给出不同答案。
//
// 重连的设备不算**新**设备：手机可能在新连接到达时还没清掉旧 socket，把自己算进
// 名额里会把一台手机锁在自己的中转外面。
func (h *Hub) DeviceBudgetExceeded(agentID, deviceID string) bool {
	return h.registry.deviceBudgetExceeded(agentID, deviceID, h.limits.MaxDevicesPerAgent)
}

// ── 关停 ─────────────────────────────────────────────────────────────────────

// Shutdown 通知所有连接并等待写循环退出（有上限）。
//
// 顺序：先停接受（由调用方关监听）→ 通知全部连接 → 等队列排空/关闭握手 →
// 把内存账本的尾巴冲盘 → 退出。冲盘放在两个返回点（等完、ctx 提前结束）之前
// 统一做一次：ctx 被取消时连接等不到头，账不能跟着丢（Python hub.py 的关停
// 同样显式 flush）。
func (h *Hub) Shutdown(ctx context.Context) {
	if !h.closed.CompareAndSwap(false, true) {
		return
	}
	defer h.flushUsageOnShutdown()
	// 先让等待中的文件请求以 host/offline 结束：连接即将断开，回帧不会再来。
	h.failAllBridges("the relay is shutting down")
	links := make([]*Link, 0, 64)
	for _, agent := range h.registry.agents() {
		links = append(links, agent.Link)
	}
	for _, device := range h.registry.allDevices() {
		links = append(links, device.Link)
	}
	for _, link := range links {
		link.RequestClose(1001, "relay shutting down")
	}
	for _, link := range links {
		select {
		case <-link.Done():
		case <-ctx.Done():
			return
		}
	}
}

// flushUsageOnShutdown 是关停收尾的最后一次冲盘。
//
// 用独立的时限，不复用传入的 ctx：Shutdown 的调用方可能已经把 ctx 取消
// （那正是走到这里的原因），账本的尾巴仍要落库。失败只记 WARN 不阻塞关停：
// 写不进去的这批留在内存账本的语义不存在了，进程退出即丢失，至少要留下证据。
func (h *Hub) flushUsageOnShutdown() {
	if !h.usage.Pending() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), usageWriteTimeout)
	defer cancel()
	if err := h.FlushUsage(ctx); err != nil {
		h.log.Warn("relay: final usage flush failed during shutdown", "error", err)
	}
}

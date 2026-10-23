package hub

import (
	"context"
	"errors"
	"hash/fnv"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/push"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// shardCount 是注册表的分片数（DESIGN §5.2：默认 64 片）。
//
// 分片的意义是**没有全局大锁**：查找、挂接、摘除只锁一片，1000 台设备同时上线时
// 不会在一条 RWMutex 上排队。
const shardCount = 64

// ErrDeviceLimit 表示这台电脑的在线设备数已达上限（调用方回 4012）。
var ErrDeviceLimit = errors.New("relay: device limit reached")

// PushSender 是 hub 需要的 APNs 投递面（*push.Sender 实现；单测可注入桩）。
//
// 只暴露两个方法：hub 只负责"哪些设备要推"与"推完怎么记日志"，签名、HTTP/2、
// 限速都在 internal/push。
type PushSender interface {
	Enabled() bool
	SendMany(ctx context.Context, targets []push.Target, kind, sid string,
		eid *string, ignoreThrottle bool) []push.Result
}

// IncidentReporter 是"一条 agent 链路断了"与"控制帧被丢了"的接收方
// （*monitor.Monitor 实现）。
type IncidentReporter interface {
	NoteAgentDisconnect(agentID, name string)
	NoteControlDrop(link, frameType string)
}

// agentShard 是 agentId 哈希到的一片 agent 注册表。
type agentShard struct {
	mu     sync.RWMutex
	agents map[string]*AgentLink
}

// deviceShard 是 deviceId 哈希到的一片设备注册表（含未挂上电脑的设备）。
type deviceShard struct {
	mu      sync.RWMutex
	devices map[string]*DeviceLink
}

// Options 是装配一个 Hub 需要的全部输入。
type Options struct {
	Store            *store.Store
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

// Hub 是活连接的唯一所有者：注册表、路由、背压、心跳、配额与用量记账都在这里。
//
// 锁的规则只有一条：**不同时持有两把分片锁**。任何需要"先看 agent 再看设备"的
// 操作都分成两步、各自加解锁，因此不存在交叉等待。
type Hub struct {
	store        *store.Store
	limits       Limits
	log          *slog.Logger
	relayVersion string
	linkOptions  linkOptions
	today        func() int64

	agentShards  [shardCount]agentShard
	deviceShards [shardCount]deviceShard

	quota *quotaLedger
	usage *usageLedger
	// usageSink 是冲盘的去处（store.Store）；单测可注入失败实现验证回放。
	usageSink usageWriter

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

	// 周期任务的参数（见 StartBackground）。
	usageFlushInterval      time.Duration
	usageFlushBytes         int64
	revokeReconcileInterval time.Duration
	backgroundOnce          sync.Once

	// 文件桥登记表（bid → bridge）。它不在转发热路径上：只有 fs* 控制帧和
	// /files/* 的 HTTP handler 会碰它，所以一把普通互斥锁就够。
	bridgesMu sync.Mutex
	bridges   map[string]bridge

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
	hub := &Hub{
		store:        options.Store,
		limits:       limits,
		log:          log,
		relayVersion: options.RelayVersion,
		today:        today,
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
	for index := range hub.agentShards {
		hub.agentShards[index].agents = map[string]*AgentLink{}
		hub.deviceShards[index].devices = map[string]*DeviceLink{}
	}
	hub.quota = newQuotaLedger(options.Store, limits.DeviceDailyBytes, today, log)
	hub.usage = newUsageLedger(today, log)
	hub.presence = presence.New(options.Presence)
	hub.bridges = map[string]bridge{}
	if options.Store != nil {
		hub.usageSink = options.Store
	}
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
	for index := range h.agentShards {
		shard := &h.agentShards[index]
		shard.mu.RLock()
		for _, agent := range shard.agents {
			if h.presence.Unverified(agent.AgentID, agent.generation, now) {
				stats.UnverifiedAgents++
			}
		}
		shard.mu.RUnlock()
	}
	return stats
}

// noteControlDrop 是 Link 丢弃可丢控制帧时的唯一记账点（/stats 与 monitor 都从这里取数）。
func (h *Hub) noteControlDrop(link *Link, frameType string) {
	total := h.controlDrops.Add(1)
	h.log.Warn("relay: dropped a lossy control frame under backpressure",
		"link", link.Label(), "frame", frameType, "total", total,
		"linkControlDrops", link.ControlDrops(),
		"queueDepth", link.QueueDepth(), "queuedBytes", link.QueuedBytes(),
		"remote_ip", link.Remote(), "lastInboundAge", link.LastInboundAge().String())
	if h.monitor != nil {
		h.monitor.NoteControlDrop(link.Label(), frameType)
	}
}

// shardIndex 把 id 映射到分片。
func shardIndex(id string) uint32 {
	hasher := fnv.New32a()
	_, _ = hasher.Write([]byte(id))
	return hasher.Sum32() % shardCount
}

// ── agent 生命周期 ───────────────────────────────────────────────────────────

// AgentLink 是一个 agentId 对应的连接器 WebSocket。
type AgentLink struct {
	*Link
	AgentID   string
	AccountID string
	Name      string

	// generation 是 presence 在准入时分配的连接代编号；迟到的事件按它对齐，
	// 不会把新连接的状态改错。attachedAt 是这一代挂上注册表的时刻。
	generation uint64
	attachedAt time.Time

	// devices 只在所属分片的写锁下修改（同一个 agent 永远落在同一片）。
	devices map[string]*DeviceLink

	superseded atomic.Bool
	// versionMu 保护两段上报版本（只在控制帧 hostStatus 上更新）。
	versionMu        sync.Mutex
	connectorVersion string
	hostVersion      string
	// deviceEgress 是这台电脑名下的设备收到过的字节数（Python 的
	// AgentLink.egress_bytes：回答"谁在用带宽"，不是这条 socket 自己写了多少）。
	deviceEgress atomic.Int64
}

// Devices 返回某个 agent 当前挂着的设备 id（按 id 排序，供诊断与测试）。
func (h *Hub) Devices(agentID string) []string {
	shard := &h.agentShards[shardIndex(agentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	agent := shard.agents[agentID]
	if agent == nil {
		return nil
	}
	ids := make([]string, 0, len(agent.devices))
	for id := range agent.devices {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// Agent 返回 agentId 当前登记的那条连接（没有时 nil）。
func (h *Hub) Agent(agentID string) *AgentLink {
	shard := &h.agentShards[shardIndex(agentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	return shard.agents[agentID]
}

// AgentRefusal 是一次被连接生命周期策略拒绝的连接器握手。
//
// 拒绝发生在 WebSocket 升级**之前**（wsapi 据此回 429）：连接器把非 101 的握手
// 当成连接失败，自己那套指数退避会逐步拉长间隔；如果先升级再关（4001），连接器
// 的会话循环会把退避归零，又回到秒级重连——这是 2026-10-23 两次回滚的共同形态。
type AgentRefusal struct {
	Reason     string
	RetryAfter time.Duration

	// 以下是诊断字段（只进日志，不改变 429 响应）：一次拒绝要能回答
	// "等了多久、旧连接退没退、它是不是从没报过版本"。
	Waited        time.Duration
	WaitResult    string // exited / timeout / canceled / not-waited
	Unverified    bool
	Streak        int
	OldGeneration uint64
	OldConnected  bool
	OldIdle       time.Duration
}

func (e *AgentRefusal) Error() string {
	return "relay: refused the agent connection (" + e.Reason + ")"
}

// AdmitAgent 是连接器握手前的准入判定，返回一张票或一次拒绝。
//
// 判定本身在 internal/presence；这里只做它要求的两件 hub 才能做的事：
//
//  1. 策略说「等旧连接退出」时，等在旧连接的 Done 上（有界，随请求 ctx 取消）；
//  2. 等不到就按抑制记账并拒绝，不把旧连接顶掉。
//
// 旧连接已退出（正常网络抖动后的重连）时 presence 直接 Allow，没有任何等待。
func (h *Hub) AdmitAgent(ctx context.Context, agent store.Agent) (*presence.Ticket, *AgentRefusal) {
	waitResult := "not-waited"
	var waited time.Duration
	var observation presence.Observation
	refuse := func(decision presence.Decision) (*presence.Ticket, *AgentRefusal) {
		refusal := &AgentRefusal{
			Reason: decision.Reason, RetryAfter: decision.RetryAfter,
			Waited: waited, WaitResult: waitResult, Unverified: decision.Unverified,
			Streak: decision.Streak, OldGeneration: observation.Generation,
			OldConnected: observation.Connected,
		}
		if observation.Connected {
			reference := observation.AttachedAt
			if observation.LastInbound.After(reference) {
				reference = observation.LastInbound
			}
			if !reference.IsZero() {
				refusal.OldIdle = time.Since(reference)
			}
		}
		h.noteAgentRefusal(agent, refusal)
		return nil, refusal
	}
	for attempt := 0; attempt < 2; attempt++ {
		now := time.Now()
		current := h.Agent(agent.AgentID)
		observation = presence.Observation{}
		if current != nil && !current.Closed() {
			observation = presence.Observation{
				Connected: true, Generation: current.generation,
				AttachedAt: current.attachedAt, LastInbound: current.LastInbound(),
			}
		}
		decision := h.presence.Admit(agent.AgentID, now, observation)
		switch decision.Verdict {
		case presence.Allow:
			return h.presence.Grant(agent.AgentID), nil
		case presence.Refuse:
			return refuse(decision)
		case presence.Wait:
			if current == nil || attempt > 0 {
				// 第二次仍然只能等：这不是「旧连接正要退出」，而是「它还在用」。
				return refuse(h.presence.Suppress(
					agent.AgentID, presence.ReasonDuplicate, time.Now()))
			}
			start := time.Now()
			exited, canceled := waitForOld(current.Done(), decision.WaitFor, ctx)
			waited = time.Since(start)
			switch {
			case canceled:
				waitResult = "canceled"
				// 客户端在等待期间自己走了：不记账（不是一次被抑制的到达），
				// 也不该按"被拒绝"记日志——它只是没等。
				return nil, &AgentRefusal{
					Reason: "client-gone", RetryAfter: decision.WaitFor,
					Waited: waited, WaitResult: waitResult,
				}
			case !exited:
				waitResult = "timeout"
				return refuse(h.presence.Suppress(
					agent.AgentID, presence.ReasonDuplicate, time.Now()))
			default:
				waitResult = "exited"
			}
			// 旧连接在窗口内退出了：再问一次，这次会走「已退出」的立即允许。
		}
	}
	return refuse(h.presence.Suppress(agent.AgentID, presence.ReasonDuplicate, time.Now()))
}

// noteAgentRefusal 记一条拒绝日志。
//
// 级别固定为 INFO（未上报版本用 WARN）：连接风暴在 journal 里必须看得见，不能
// 默认落在 DEBUG 里被运维漏掉。频率仍然由 presence 统计（streak 逐次累加），
// 但不再把后续到达降级——"每分钟只看得到一条"正是 2026-10-23 那类事件被漏掉的
// 原因。字段里带上等待结果与旧连接状态，一行就能判断是顶替、退避还是并发到达。
func (h *Hub) noteAgentRefusal(agent store.Agent, refusal *AgentRefusal) {
	level := slog.LevelInfo
	message := "relay: refused a duplicate agent connection"
	switch refusal.Reason {
	case presence.ReasonUnverified:
		level = slog.LevelWarn
		message = "relay: refused a reconnect from an agent that never reported its versions; " +
			"backing off"
	case presence.ReasonPending:
		message = "relay: refused an agent connection while another arrival is in flight"
	}
	h.log.Log(context.Background(), level, message,
		"agentId", agent.AgentID, "name", agent.Name, "reason", refusal.Reason,
		"retryAfterMs", refusal.RetryAfter.Milliseconds(), "streak", refusal.Streak,
		"waitResult", refusal.WaitResult, "waitedMs", refusal.Waited.Milliseconds(),
		"unverified", refusal.Unverified, "oldGeneration", refusal.OldGeneration,
		"oldConnected", refusal.OldConnected,
		"oldIdleMs", refusal.OldIdle.Milliseconds())
}

// waitForOld 等旧连接的写循环退出；返回 (退出了, 请求被取消)。
func waitForOld(done <-chan struct{}, timeout time.Duration, ctx context.Context) (bool, bool) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-done:
		return true, false
	case <-timer.C:
		return false, false
	case <-ctx.Done():
		return false, true
	}
}

// supersedeDrain 是顶替一条旧连接时等待它退出写循环的上限。
//
// 能走到顶替这一步，旧连接要么已经僵死、要么已经在关闭路上，正常情况下是毫秒级；
// 上限只防一条卡在坏 socket 上的写循环把新连接永远挡在门外。
const supersedeDrain = 2 * time.Second

// AttachAgent 登记一条已通过准入的连接器连接，并让旧连接按顺序退场。
//
// 关闭顺序是固定的，且必须在注册新连接**之前**完成：
//
//	① 标记旧连接退出（superseded）：路由层从此丢弃它的帧，读侧不再影响世界；
//	② RequestClose 走旧连接自己的队列：排空写队列、必要时发关闭帧；
//	③ 等写循环退出（有界），socket 随之关闭，读循环自行收尾；
//	④ 才把新连接登记进注册表并启动写循环。
//
// 这样两台电脑的帧不会同时写同一批设备，连接器也不会在旧 socket 还活着时看到
// 新连接已经接管。旧连接退出后设备不关闭，由新连接重新认领（见 adoptDevices）。
func (h *Hub) AttachAgent(ctx context.Context, agent store.Agent, sink Sink,
	ticket *presence.Ticket) *AgentLink {
	if ticket == nil {
		// 票只能来自 AdmitAgent：没有票就挂接等于绕过准入，这条路径不允许存在。
		panic("hub: AttachAgent requires a ticket from AdmitAgent")
	}
	now := time.Now()
	link := &AgentLink{
		Link: newLink(sink, "agent "+agent.AgentID, h.limits.AgentQueueDepth,
			h.limits.QueueBytes, h.log, h.linkOptions),
		AgentID:    agent.AgentID,
		AccountID:  agent.AccountID,
		Name:       agent.Name,
		generation: ticket.Generation(),
		attachedAt: now,
		devices:    map[string]*DeviceLink{},
	}
	link.Link.SetRemote(remoteOf(sink))
	// 文件上行桥的字节额度跟着**这条**连接器链路走：帧压在它的队列里，额度就该
	// 记在它头上；连接器被顶替时新链路拿一份新的，旧链路的额度随旧队列一起清空。
	link.Link.credits = newBridgeCredits(h.limits.BridgeBytes)
	// 连接器链路的心跳是 DLP ping：连接器的读循环会把 ping 原样回成 pong。
	link.Link.heartbeatKind = heartbeatDLP

	h.retireAgent(agent.AgentID, link.generation)

	shard := &h.agentShards[shardIndex(agent.AgentID)]
	shard.mu.Lock()
	shard.agents[agent.AgentID] = link
	shard.mu.Unlock()
	ticket.Commit(now)

	// 写循环要先于 adoptDevices / tellAgentAboutTheGone 启动：这两步会发必达的
	// deviceAttach/deviceDetach 控制帧，优先队列满时它们要等写循环腾位置。
	link.Start(ctx)

	adopted := h.adoptDevices(ctx, link)
	h.tellAgentAboutTheGone(ctx, link, agent)

	connector, host := link.Versions()
	h.log.Info("relay: agent connected",
		"agentId", agent.AgentID, "name", agent.Name, "devices", adopted,
		"generation", link.generation, "accountId", agent.AccountID,
		"remote_ip", link.Remote(), "connectorVersion", connector, "hostVersion", host)
	return link
}

// retireAgent 让某个 agent 的旧连接按「停读 → 排空写 → 关闭」的顺序退场。
//
// 返回时旧连接的写循环要么已经退出，要么等满了 supersedeDrain（记一条 WARN）。
func (h *Hub) retireAgent(agentID string, newGeneration uint64) {
	previous := h.Agent(agentID)
	if previous == nil {
		return
	}
	if !previous.Closed() {
		// superseded 必须在 RequestClose 之前置位：读循环可能还有最后的帧在
		// 路上，RouteFromAgent 按它丢弃，旧连接不能在新连接登记后继续改状态。
		previous.superseded.Store(true)
		previous.RequestClose(dlp.CloseSuperseded, "superseded by a new agent connection")
		h.presence.NoteSuperseded()
		connector, host := previous.Versions()
		h.log.Info("relay: agent superseded by a new connection",
			"agentId", agentID,
			"oldGeneration", previous.generation, "newGeneration", newGeneration,
			"oldDurationMs", previous.Lifetime().Milliseconds(),
			"oldLastInboundAge", previous.LastInboundAge().String(),
			"remote_ip", previous.Remote(),
			"connectorVersion", connector, "hostVersion", host)
	}
	if !waitForOldLink(previous.Done(), supersedeDrain) {
		h.log.Warn("relay: the superseded agent link did not finish closing in time",
			"agentId", agentID, "oldGeneration", previous.generation,
			"newGeneration", newGeneration, "drain", supersedeDrain,
			"queueDepth", previous.QueueDepth())
	}
}

// Versions 返回这条连接上报的两段版本（连接器与宿主）；还没报时都是空串。
func (a *AgentLink) Versions() (connector, host string) {
	if a == nil {
		return "", ""
	}
	a.versionMu.Lock()
	defer a.versionMu.Unlock()
	return a.connectorVersion, a.hostVersion
}

// waitForOldLink 是 retireAgent 的无 ctx 等待版本（关闭顺序不能被单个请求的
// 取消打断，否则新旧连接会交错）。
func waitForOldLink(done <-chan struct{}, timeout time.Duration) bool {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-done:
		return true
	case <-timer.C:
		return false
	}
}

// adoptDevices 把仍然活着的设备挂回新连接，并让两边都看到当前状态。
func (h *Hub) adoptDevices(_ context.Context, link *AgentLink) int {
	devices := h.devicesOfAgent(link.AgentID)
	adopted := 0
	for _, device := range devices {
		if device.Closed() {
			continue
		}
		if !h.bindDevice(link, device) {
			continue // 这条 agent 连接已被更新的连接顶替，不要再往它身上挂
		}
		adopted++
		h.SendControl(link, dlp.DeviceAttachFrame(
			device.DeviceID, device.Name, device.Model, link.AgentID))
		h.SendControl(device, dlp.HostStatus(true, link.AgentID, link.Name, "",
			map[string]any{"relayVersion": h.relayVersion}))
	}
	return adopted
}

// bindDevice 在 agent 分片写锁下把设备挂到链路上；返回 false 表示本次不该挂。
func (h *Hub) bindDevice(link *AgentLink, device *DeviceLink) bool {
	shard := &h.agentShards[shardIndex(link.AgentID)]
	shard.mu.Lock()
	defer shard.mu.Unlock()
	if shard.agents[link.AgentID] != link {
		return false // 已经被新连接顶替
	}
	if device.Closed() {
		return false
	}
	device.agent.Store(link)
	link.devices[device.DeviceID] = device
	return true
}

// devicesOfAgent 从设备注册表里取某台电脑名下的活设备（不持锁返回）。
func (h *Hub) devicesOfAgent(agentID string) []*DeviceLink {
	var found []*DeviceLink
	for index := range h.deviceShards {
		shard := &h.deviceShards[index]
		shard.mu.RLock()
		for _, device := range shard.devices {
			if device.AgentID == agentID && !device.Closed() {
				found = append(found, device)
			}
		}
		shard.mu.RUnlock()
	}
	return found
}

// tellAgentAboutTheGone 告诉刚连上的连接器：这些设备永远回不来了（已撤销或已过期）。
//
// 连接器可能还留着上一次 attach 的设备记录，每条记录挂着一条 `$events` 值班流；
// 库里已撤销或配对已满 365 天的设备不可能再连上（device_by_token 两种都拒），所以
// 逐条告知"放下"。只报**不在线**的那些：在线设备的撤销由对账踢掉。
func (h *Hub) tellAgentAboutTheGone(ctx context.Context, link *AgentLink, agent store.Agent) {
	if h.store == nil {
		return
	}
	rows, err := h.store.ListDevices(ctx, agent.AgentID, true)
	if err != nil {
		h.log.Warn("relay: could not list devices for the reconnect notice",
			"agentId", agent.AgentID, "error", err)
		return
	}
	expired, err := h.store.ExpiredIDsOfAgent(ctx, agent.AgentID)
	if err != nil {
		h.log.Warn("relay: could not list expired devices",
			"agentId", agent.AgentID, "error", err)
		expired = map[string]struct{}{}
	}
	live := map[string]struct{}{}
	for _, device := range h.devicesOfAgent(agent.AgentID) {
		live[device.DeviceID] = struct{}{}
	}
	gone := map[string]struct{}{}
	for _, row := range rows {
		if row.RevokedAt != nil {
			gone[row.DeviceID] = struct{}{}
		}
	}
	for id := range expired {
		gone[id] = struct{}{}
	}
	stale := make([]string, 0, len(gone))
	for id := range gone {
		if _, online := live[id]; online {
			continue
		}
		stale = append(stale, id)
	}
	if len(stale) == 0 {
		return
	}
	sort.Strings(stale)
	for _, id := range stale {
		h.SendControl(link, dlp.DeviceDetachFrame(id, "revoked"))
	}
	h.log.Info("relay: told the connector about devices that can never come back",
		"agentId", agent.AgentID, "devices", len(stale))
	if threshold := h.limits.DeadDeviceWarnThreshold; threshold > 0 && len(stale) > threshold {
		h.log.Warn("relay: too many dead device records; every reconnect replays that many "+
			"deviceDetach frames", "agentId", agent.AgentID, "deadDevices", len(stale),
			"threshold", threshold)
	}
}

// DetachAgent 摘掉一条连接器连接；设备保留并被告知 host offline。
func (h *Hub) DetachAgent(link *AgentLink) {
	// 生命周期策略先记账：一次版本都没报就退出的连接器会被标记 unverified，
	// 它接下来的重连走有界退避。被顶替的旧连接按代编号自然被忽略。
	if h.presence.Detached(link.AgentID, link.generation, time.Now()) {
		h.log.Warn("relay: an agent disconnected without ever reporting its versions; "+
			"its reconnects will be backed off", "agentId", link.AgentID, "name", link.Name,
			"generation", link.generation)
	}
	shard := &h.agentShards[shardIndex(link.AgentID)]
	shard.mu.Lock()
	if shard.agents[link.AgentID] != link {
		shard.mu.Unlock()
		// 已经被更新的连接顶替，摘除与通知都归新连接——但**挂在这条旧 socket 上的
		// 文件桥**必须在这里结束：它们的 fs* 回帧永远不会再来了。按链接身份而不是
		// agentId 收尾，才不会误伤新连接刚开的传输。
		h.dropAgentBridges(link, "the PC connector reconnected")
		return
	}
	delete(shard.agents, link.AgentID)
	devices := make([]*DeviceLink, 0, len(link.devices))
	for _, device := range link.devices {
		devices = append(devices, device)
	}
	link.devices = map[string]*DeviceLink{}
	shard.mu.Unlock()

	// 挂在断掉这条链路的上传/下载立刻以 host/offline 结束，不让 HTTP 请求等到
	// 自己的超时。Python 只在"真断线"路径做这件事；这里把被顶替的那条也一并
	// 收尾（按链接身份匹配），避免它们的请求永远等不到回帧。
	h.dropAgentBridges(link, "the PC connector disconnected")
	link.RequestClose(1001, "agent disconnected")
	if link.superseded.Load() {
		return
	}
	closeCode, closeReason := link.CloseInfo()
	if closeCode == 0 {
		closeCode, closeReason = 1001, "socket closed"
	}
	connector, host := link.Versions()
	h.log.Info("relay: agent disconnected",
		"agentId", link.AgentID, "name", link.Name, "generation", link.generation,
		"duration_ms", link.Lifetime().Milliseconds(),
		"closeCode", closeCode, "reason", closeReason,
		"remote_ip", link.Remote(), "connectorVersion", connector, "hostVersion", host,
		"lastInbound", link.LastInboundMS(),
		"lastInboundAge", link.LastInboundAge().String(),
		"lastError", link.LastError())
	// 一条链路断了本身是常态（锁屏、断网、换网），**反复断**才是故障。是不是
	// "反复"由监控器按窗口判定，hub 只报"断了一条"（2026-10-17 那次连接器每
	// 分钟重连一轮，日志里 702 条 disconnected，没人注意到）。
	if h.monitor != nil {
		h.monitor.NoteAgentDisconnect(link.AgentID, link.Name)
	}
	for _, device := range devices {
		if device.agent.CompareAndSwap(link, nil) {
			h.SendControl(device, dlp.HostStatus(false, link.AgentID, "", "", nil))
		}
	}
}

// ── 设备生命周期 ─────────────────────────────────────────────────────────────

// DeviceLink 是一台设备对应的 WebSocket。
type DeviceLink struct {
	*Link
	DeviceID  string
	AgentID   string
	AccountID string
	Name      string
	Model     string

	agent      atomic.Pointer[AgentLink]
	appVersion atomic.Pointer[string]

	// idMember 是 `"deviceId":"<id>"` 的预编码字节：每帧就地追加，不在热路径上编码。
	idMember []byte

	bucket     *tokenBucket
	pacedNanos atomic.Int64
	closed     atomic.Bool

	// hub 用来记当天用量（设备对象不持有账本，只持有回调）。
	hub *Hub
}

// Device 返回 deviceId 当前登记的那条连接（没有时 nil）。
func (h *Hub) Device(deviceID string) *DeviceLink {
	shard := &h.deviceShards[shardIndex(deviceID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	return shard.devices[deviceID]
}

// DeviceBudgetExceeded 判断再接入 deviceID 是否会超过这台电脑的设备上限。
//
// "设备上限"只有这一处定义：升级前的预检查（能在握手前干净地拒绝）与
// AttachDevice（最后一道防线）都问它，两条路径不可能给出不同答案。
//
// 重连的设备不算**新**设备：手机可能在新连接到达时还没清掉旧 socket，把自己算进
// 名额里会把一台手机锁在自己的中转外面。
func (h *Hub) DeviceBudgetExceeded(agentID, deviceID string) bool {
	shard := &h.agentShards[shardIndex(agentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	agent := shard.agents[agentID]
	if agent == nil {
		return false
	}
	return h.budgetExceededLocked(agent, deviceID)
}

// budgetExceededLocked 是设备上限规则的唯一实现；调用方持有对应分片的锁。
func (h *Hub) budgetExceededLocked(agent *AgentLink, deviceID string) bool {
	limit := h.limits.MaxDevicesPerAgent
	if limit <= 0 {
		return false
	}
	live := 0
	for id, device := range agent.devices {
		if id == deviceID || device.Closed() {
			continue
		}
		live++
	}
	return live >= limit
}

// AttachDevice 登记一条设备连接并挂到它的电脑上。
//
// 返回 ErrDeviceLimit 时**什么都没登记**：调用方可以在同一条 socket 上发拒连帧，
// 不需要回滚任何状态。
func (h *Hub) AttachDevice(ctx context.Context, device store.Device, sink Sink) (*DeviceLink, error) {
	link := &DeviceLink{
		DeviceID:  device.DeviceID,
		AgentID:   device.AgentID,
		AccountID: device.AccountID,
		Name:      device.Name,
		Model:     stringValue(device.Model),
	}
	link.Link = newLink(sink, "device "+device.DeviceID, h.limits.QueueDepth,
		h.limits.QueueBytes, h.log, h.linkOptions)
	link.Link.SetRemote(remoteOf(sink))
	link.idMember = dlp.DeviceIDMember(device.DeviceID)
	link.bucket = newTokenBucket(h.limits.DeviceBytesPerSecond, time.Now())
	link.Link.pace = link.pace
	link.Link.onSent = link.countEgress
	link.hub = h

	// 日额度的基线要在挂上去之前定好（读库，不在转发热路径上）。
	h.quota.Seat(ctx, device.DeviceID)

	agent, err := h.attachToAgent(link)
	if err != nil {
		return nil, err
	}

	previous := h.registerDevice(link)
	if previous != nil && previous != link {
		// 同一台设备又开了一条、旧的还活着：直接覆盖登记（与 Python 一致，不关旧
		// socket、也不通知连接器）。区别在于这里**留下一条 WARNING**——否则旧连接
		// 消失得无声无息，日志里只看得到一条条对不上的 attach/detach。
		h.log.Warn("relay: device attached again while its previous socket is still open; "+
			"replacing the registration (the old socket is now untracked)",
			"deviceId", device.DeviceID, "agentId", device.AgentID)
	}

	// 写循环先于首批控制帧启动：hostStatus 是可丢帧，但 deviceAttach 是必达帧，
	// 优先队列满时它要等写循环腾位置，不能等一个还没启动的写循环。
	link.Start(ctx)
	if agent == nil {
		h.SendControl(link, dlp.HostStatus(false, device.AgentID, "", "", nil))
	} else {
		h.SendControl(link, dlp.HostStatus(true, agent.AgentID, agent.Name, "",
			map[string]any{"relayVersion": h.relayVersion}))
		h.SendControl(agent, dlp.DeviceAttachFrame(
			device.DeviceID, link.Name, link.Model, agent.AgentID))
	}
	h.usage.NoteConnection(link)
	h.log.Info("relay: device attached",
		"deviceId", device.DeviceID, "name", device.Name, "agentId", device.AgentID,
		"accountId", device.AccountID, "remote_ip", link.Remote(),
		"hostOnline", agent != nil)
	return link, nil
}

// attachToAgent 在 agent 分片写锁下做**判定 + 挂接**，两者必须原子。
func (h *Hub) attachToAgent(link *DeviceLink) (*AgentLink, error) {
	shard := &h.agentShards[shardIndex(link.AgentID)]
	shard.mu.Lock()
	defer shard.mu.Unlock()
	agent := shard.agents[link.AgentID]
	if agent == nil {
		return nil, nil // 电脑不在线：设备照样能连，只是收不到帧
	}
	if h.budgetExceededLocked(agent, link.DeviceID) {
		h.log.Warn("relay: refused a device socket at the device limit",
			"agentId", link.AgentID, "deviceId", link.DeviceID,
			"limit", h.limits.MaxDevicesPerAgent)
		return nil, ErrDeviceLimit
	}
	agent.devices[link.DeviceID] = link
	link.agent.Store(agent)
	return agent, nil
}

// registerDevice 把设备登记进注册表，返回被顶替的那条（可能为 nil）。
func (h *Hub) registerDevice(link *DeviceLink) *DeviceLink {
	shard := &h.deviceShards[shardIndex(link.DeviceID)]
	shard.mu.Lock()
	defer shard.mu.Unlock()
	previous := shard.devices[link.DeviceID]
	shard.devices[link.DeviceID] = link
	return previous
}

// DetachDevice 摘掉一条设备连接，并（在应当通知时）告诉电脑它下线了。
//
// 这是设备拆除的唯一路径：撤销、配额、背压、对端关闭都走这里，所以
// deviceDetach 的"发还是不发"只有一个判断点。
func (h *Hub) DetachDevice(link *DeviceLink) {
	h.detachDevice(link, "socket closed", 1001)
}

// detachDevice 是 DetachDevice 的实现，带关闭码与原因。
func (h *Hub) detachDevice(link *DeviceLink, reason string, closeCode int) {
	if !link.closed.CompareAndSwap(false, true) {
		return // 已经拆过了
	}
	notified := false
	replaced := false
	// `closed` 已经置位，接下来读 agent 并摘除必须和 bindDevice **同一把锁**：
	// 电脑重连认领设备的那个瞬间如果不互斥，拆除会漏掉刚挂上的那条登记。
	if agent := link.agent.Load(); agent != nil {
		shard := &h.agentShards[shardIndex(agent.AgentID)]
		shard.mu.Lock()
		current, registered := agent.devices[link.DeviceID]
		switch {
		case !registered:
			// 已经被摘掉了：没有可发的通知。
		case current == link:
			delete(agent.devices, link.DeviceID)
			notified = true
		default:
			// 这条 socket 已经被同 deviceId 的新连接顶替过。连接器会认为那台设备
			// 还在（新连接也是它），所以**没有** deviceDetach 可发；留下这条日志，
			// 免得把 attach/detach 条数相等误读成"每条都通知到了"。
			replaced = true
		}
		link.agent.Store(nil)
		shard.mu.Unlock()
		if notified {
			h.SendControl(agent, dlp.DeviceDetachFrame(link.DeviceID, reason))
		} else if replaced {
			h.log.Info("relay: device closed a socket that had already been replaced; "+
				"no detach notification sent", "deviceId", link.DeviceID, "agentId", agent.AgentID)
		}
	}

	shard := &h.deviceShards[shardIndex(link.DeviceID)]
	shard.mu.Lock()
	if shard.devices[link.DeviceID] == link {
		delete(shard.devices, link.DeviceID)
	}
	shard.mu.Unlock()

	link.RequestClose(closeCode, reason)
	h.log.Info("relay: device detached",
		"deviceId", link.DeviceID, "agentId", link.AgentID, "reason", reason,
		"closeCode", closeCode, "duration_ms", link.Lifetime().Milliseconds(),
		"remote_ip", link.Remote(), "notified", notified,
		"lastInboundAge", link.LastInboundAge().String(),
		"lastError", link.LastError())
	// 断开时冲一次：这一批的尾巴不留在内存里，运维命令跑完就是准的。
	// 异步是为了不让一次写库（最坏等满 busy_timeout）拖住拆除路径。
	h.flushUsageOnDetach()
}

// DropDevice 按 id 断开一台在线设备；不在线时返回 false。
func (h *Hub) DropDevice(deviceID, reason string, closeCode int) bool {
	device := h.Device(deviceID)
	if device == nil {
		return false
	}
	h.detachDevice(device, reason, closeCode)
	return true
}

// pace 是这台设备唯一的限速点：写循环在每次发送前调用。
func (d *DeviceLink) pace(ctx context.Context, size int) error {
	wait := d.bucket.take(size, time.Now())
	if wait <= 0 {
		return nil
	}
	d.pacedNanos.Add(int64(wait))
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// countEgress 在一条消息真正写出后记账：设备、所属电脑、当天的用量。
func (d *DeviceLink) countEgress(size int) {
	if agent := d.agent.Load(); agent != nil {
		agent.deviceEgress.Add(int64(size))
	}
	if d.hub != nil {
		d.hub.usage.NoteEgress(d, size)
	}
}

// PacedSeconds 是这台设备因为限速累计等待的秒数。
func (d *DeviceLink) PacedSeconds() float64 {
	return float64(d.pacedNanos.Load()) / float64(time.Second)
}

// Pace 是 /files/down 的响应体写作路径使用的限速入口。
//
// 与 WebSocket 写循环调用的是**同一个** pace（同一条 TokenBucket）：HTTP 下载
// 不能成为绕开每设备限速的第二条通路。
func (d *DeviceLink) Pace(ctx context.Context, size int) error { return d.pace(ctx, size) }

// NoteEgress 记一条不走 WebSocket 写循环的出口字节（HTTP 下载正文）。
//
// WebSocket 路径在每条消息写出后由 Link.write 计数；下载路径直接写 HTTP 正文，
// 没有那条路径可借用，所以在这里补上同一个计数器（设备、所属电脑、当天用量），
// 而不是让 /stats 的 egressBytes 漏掉下载。
func (d *DeviceLink) NoteEgress(size int) {
	if size <= 0 {
		return
	}
	d.Link.egress.Add(int64(size))
	d.countEgress(size)
}

// Agent 返回这台设备当前挂着的电脑（离线时 nil）。
func (d *DeviceLink) Agent() *AgentLink { return d.agent.Load() }

// ── 路由 ─────────────────────────────────────────────────────────────────────

// RouteFromDevice 处理一条结构校验通过的设备帧。
//
// 转发路径直接在原始字节上盖 deviceId（见 dlp.Wire）：M2 这里是"全量解析 + 克隆 +
// 重编码"，一帧 48 字节要付 1.8 KiB 分配（M2.5 报告 §3）。缓冲的归属在这里唯一：
// 成功入队才把所有权交给写循环，其余每个出口都由 defer 归还。
func (h *Hub) RouteFromDevice(link *DeviceLink, wire dlp.Wire) {
	// 任意一帧都算"对端还活着"：设备链路的心跳走 WS ping/pong，这份记录只用于
	// 诊断与后续统一两套心跳口径。
	link.NoteInbound()
	owned := wire.Buffer()
	defer func() {
		if owned != nil {
			owned.Release()
		}
	}()

	switch {
	case wire.Is("ping"):
		if frame, err := wire.Decode(); err == nil {
			h.SendControl(link, dlp.Pong(frame.Ts()))
		}
		return
	case wire.Is("hello"):
		wanted := wire.FieldText("agentId")
		if wanted != "" && wanted != link.AgentID {
			h.SendControl(link, dlp.ErrorFrame("auth/agent-mismatch",
				"hello names a different agent", true, nil))
			h.detachDevice(link, "agent mismatch", 1001)
		}
		return
	case wire.IsHello():
		// 手机的构建号就搭在这条调用上：记下来，运维"那台手机升级了吗"
		// 才不用去翻配对当时的版本。
		h.noteClientBuild(link, wire)
	}

	agent := link.agent.Load()
	if agent == nil || agent.Closed() {
		h.SendControl(link, dlp.ErrorFrame("host/offline",
			"the PC connector is not connected", false, nil))
		h.SendControl(link, dlp.HostStatus(false, link.AgentID, "", "", nil))
		return
	}

	stamped, err := wire.WithDeviceIDMember(link.idMember)
	payload := []byte(nil)
	var payloadOwner *dlp.Buffer
	if err == nil {
		payload, payloadOwner = stamped.Bytes(), stamped.Buffer()
		wire = stamped
	} else {
		// 设备自己带了 deviceId（覆盖语义）等不常见形状：走全量解析，与 M2 一致。
		frame, decodeErr := wire.Decode()
		if decodeErr != nil {
			h.log.Warn("relay: could not decode a device frame",
				"deviceId", link.DeviceID, "error", decodeErr)
			return
		}
		payload, err = dlp.Encode(dlp.WithDeviceID(frame, link.DeviceID))
		if err != nil {
			h.log.Warn("relay: could not encode a device frame",
				"deviceId", link.DeviceID, "error", err)
			return
		}
	}
	switch agent.Enqueue(payload, classOf(wire.Kind()), payloadOwner) {
	case Enqueued:
		if payloadOwner != nil && payloadOwner == owned {
			owned = nil // 所有权已交给写循环
		}
	case FrameDropped:
		h.log.Warn("relay: dropped a stream frame for a saturated agent link",
			"agentId", link.AgentID, "deviceId", link.DeviceID, "frame", wire.Type())
	case Overloaded:
		// 电脑不在（或已经被自己那批帧堵死）：设备不能继续站着等，给 4010。
		h.log.Warn("relay: agent link is saturated; dropping the device",
			"deviceId", link.DeviceID, "agentId", link.AgentID)
		h.detachDevice(link, "agent unavailable", dlp.CloseAgentOffline)
	}
}

// RouteFromAgent 处理一条结构校验通过的电脑帧。
func (h *Hub) RouteFromAgent(link *AgentLink, wire dlp.Wire) {
	// 读循环在这里记下"最后收到对端一帧的时刻"：DLP 心跳的 watchdog 用它区分
	// "真断网"（什么都收不到）与"旧连接器不回答中转 ping"（还在发业务帧）。
	link.NoteInbound()
	// 与设备侧同一条所有权规则：默认在本函数返回时归还，入队成功才转移。
	owned := wire.Buffer()
	defer func() {
		if owned != nil {
			owned.Release()
		}
	}()
	if link.superseded.Load() {
		// 旧连接正在退场（新连接已经或即将登记）：它读循环里残留的帧不能再认领设备、
		// 记账或发推送，否则新旧两条连接会同时改写同一份世界状态。
		return
	}

	var hostStatus dlp.Frame
	switch {
	case wire.Is("hostStatus"):
		if frame, err := wire.Decode(); err == nil {
			hostStatus = frame
			h.noteAgentVersions(link, frame)
		}
	case wire.Is("ping"):
		if frame, err := wire.Decode(); err == nil {
			h.SendControl(link, dlp.Pong(frame.Ts()))
		}
		return
	case wire.Is("pong"):
		// 这是中转自己 DLP ping 的回答：心跳 watchdog 用它清掉截止时间。
		link.NotePong()
		return
	case wire.Is("notify"):
		// `notify` 是 agent 侧控制帧：**不跨到设备**，只在"手机此刻不在线"时
		// 转成一条 APNs 提醒（见 deliverNotify）。
		if frame, err := wire.Decode(); err == nil {
			h.deliverNotify(link, frame)
		}
		return
	}
	kind := wire.Kind()
	if dlp.IsAgentControlKind(kind) {
		// fs* 帧不是 DLP，永远不跨到设备；它们只属于某一次等待中的 /files/* 请求。
		h.routeBridgeFrame(link, wire)
		return
	}

	deviceID := wire.Field("deviceId")
	if len(deviceID) == 0 {
		if hostStatus != nil {
			h.broadcast(link, hostStatus)
			return
		}
		h.log.Debug("relay: dropping an unaddressed frame from the agent",
			"agentId", link.AgentID, "frame", wire.Type())
		return
	}

	device := h.deviceOfAgent(link, deviceID)
	if device == nil {
		h.log.Debug("relay: agent sent a frame for an unknown device",
			"agentId", link.AgentID, "deviceId", string(deviceID), "frame", wire.Type())
		return
	}

	// 类别要在就地改写**之前**算：改写会移动字节，指向原数组的切片会失效
	// （Wire 自己会刷新 kind，但调用方手里的副本不会）。
	class := classOf(kind)
	stripped, err := wire.WithoutDeviceID()
	payload := []byte(nil)
	var payloadOwner *dlp.Buffer
	if err == nil {
		payload, payloadOwner = stripped.Bytes(), stripped.Buffer()
		wire = stripped
	} else {
		frame, decodeErr := wire.Decode()
		if decodeErr != nil {
			h.log.Warn("relay: could not decode an agent frame",
				"agentId", link.AgentID, "deviceId", device.DeviceID, "error", decodeErr)
			return
		}
		payload, err = dlp.Encode(dlp.WithoutDeviceID(frame))
		if err != nil {
			h.log.Warn("relay: could not encode an agent frame",
				"agentId", link.AgentID, "deviceId", device.DeviceID, "error", err)
			return
		}
	}

	// 额度按"真正发往手机的字节"记账，超限时先告诉手机为什么，再以 4011 关闭：
	// 一个不断重连进已经用光额度的客户端，比一个显示"今天的流量用完了"的更糟。
	if allowed, _ := h.quota.Charge(device.DeviceID, len(payload)); !allowed {
		h.log.Warn("relay: device exceeded its daily allowance",
			"deviceId", device.DeviceID, "limitBytes", h.limits.DeviceDailyBytes)
		h.SendControl(device, dlp.ErrorFrame("quota/device-daily",
			"this device reached its daily traffic allowance", false,
			map[string]any{"limitBytes": h.limits.DeviceDailyBytes}))
		h.detachDevice(device, "daily quota", dlp.CloseQuotaExceeded)
		return
	}

	switch device.Enqueue(payload, class, payloadOwner) {
	case Enqueued:
		if payloadOwner != nil && payloadOwner == owned {
			owned = nil
		}
	case FrameDropped:
		h.log.Debug("relay: dropped a stream frame for a slow device",
			"deviceId", device.DeviceID, "frame", wire.Type())
	case Overloaded:
		h.log.Warn("relay: device send queue is full; dropping the device",
			"deviceId", device.DeviceID)
		h.detachDevice(device, "backpressure", dlp.CloseBackpressure)
	}
}

// ── APNs 推送（notify → 提醒）──────────────────────────────────────────────

// deliverNotify 把连接器的一条 `notify` 变成对"需要提醒的手机"的 APNs 推送。
//
// 四个条件都成立才推（Python hub._should_push）：
//
//	① 此刻不在线——在线的手机自己会弹本地通知，再推就是重复；
//	② 有推送登记（令牌与环境都有效，store 已把撤销/过期滤掉）；
//	③ 用户开着这一类提醒。
//
// 投递放在 goroutine 里：路由路径绝不等 Apple，推送失败只是一行日志。
func (h *Hub) deliverNotify(link *AgentLink, frame dlp.Frame) {
	sender := h.push
	if sender == nil || !sender.Enabled() {
		return
	}
	kind, _ := frame["kind"].(string)
	sid, _ := frame["sid"].(string)
	if (kind != "turnEnd" && kind != "attention") || sid == "" {
		h.log.Debug("relay: ignoring malformed notify from agent", "agentId", link.AgentID)
		return
	}
	var eid *string
	if value, ok := frame["eid"].(string); ok && value != "" {
		eid = &value
	}
	if h.store == nil {
		return
	}
	go h.sendReminders(link, kind, sid, eid)
}

// sendReminders 读推送目标、筛出该推的那几台、投递并按结果清理失效登记。
func (h *Hub) sendReminders(link *AgentLink, kind, sid string, eid *string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rows, err := h.store.PushTargets(ctx, link.AgentID)
	if err != nil {
		h.log.Warn("relay: could not read push targets",
			"agentId", link.AgentID, "error", err)
		return
	}
	wanted := make([]store.Device, 0, len(rows))
	for _, row := range rows {
		if h.shouldPush(link, row, kind) {
			wanted = append(wanted, row)
		}
	}
	if len(wanted) == 0 {
		return
	}
	targets := make([]push.Target, 0, len(wanted))
	for _, row := range wanted {
		targets = append(targets, push.Target{
			DeviceID: row.DeviceID, Token: stringValue(row.APNSToken), Env: row.APNSEnv,
		})
	}
	results := h.push.SendMany(ctx, targets, kind, sid, eid, false)
	for index, row := range wanted {
		if index >= len(results) {
			break
		}
		result := results[index]
		if result.OK {
			h.log.Info("relay: pushed a reminder",
				"kind", kind, "deviceId", row.DeviceID)
			continue
		}
		if result.DeadToken {
			// Apple 的判定是这套系统唯一的自动清理：App 没了或重装了，登记就是
			// 陈旧记录，等它回来重新登记。
			h.log.Info("relay: device push token is dead; clearing it",
				"deviceId", row.DeviceID, "kind", kind,
				"status", statusValue(result.Status), "reason", stringValue(result.Reason))
			if err := h.store.ClearPush(ctx, row.DeviceID); err != nil {
				h.log.Warn("relay: could not clear push",
					"deviceId", row.DeviceID, "error", err)
			}
			continue
		}
		if result.Skipped != nil {
			h.log.Info("relay: push skipped", "deviceId", row.DeviceID,
				"kind", kind, "skipped", stringValue(result.Skipped))
			continue
		}
		h.log.Warn("relay: push failed",
			"deviceId", row.DeviceID, "kind", kind,
			"status", statusValue(result.Status),
			"reason", stringValue(result.Reason))
	}
}

// shouldPush 判断一台设备要不要收这条提醒。
func (h *Hub) shouldPush(link *AgentLink, row store.Device, kind string) bool {
	// ① 此刻不在线。在线的手机自己会弹本地通知（$events → App），再推就是重复。
	if h.deviceOnlineOn(link, row.DeviceID) {
		return false
	}
	// ② 有推送登记（令牌与环境都有效；store 已把撤销/过期滤掉）。
	if row.APNSToken == nil || row.APNSEnv == nil {
		return false
	}
	// ③ 用户开着这一类提醒。
	if kind == "turnEnd" {
		return row.PushTurnEnd != 0
	}
	return row.PushAttention != 0
}

// deviceOnlineOn 报告这台设备是否挂在**这一条**（且仍是当前）的 agent 连接上。
//
// 只查 map 不够：被顶替的旧连接还留着 devices 时，答案会从"在线"漂成"离线"或
// 反过来。所以先确认这条连接仍是注册表里的那一条。
func (h *Hub) deviceOnlineOn(link *AgentLink, deviceID string) bool {
	shard := &h.agentShards[shardIndex(link.AgentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	current := shard.agents[link.AgentID]
	if current == nil || current != link {
		return false
	}
	_, online := current.devices[deviceID]
	return online
}

// classOf 把帧类型映射成背压类别。
func classOf(kind []byte) Class {
	if dlp.IsStreamingKind(kind) {
		return ClassStream
	}
	return ClassControl
}

// deviceOfAgent 只在这台电脑自己名下的设备里找。
//
// 不能查全局设备表：一枚设备令牌只该寻址自己那台电脑的设备，否则任意连接器都能
// 往别人的手机上投帧。
func (h *Hub) deviceOfAgent(link *AgentLink, deviceID []byte) *DeviceLink {
	shard := &h.agentShards[shardIndex(link.AgentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	if shard.agents[link.AgentID] != link {
		return nil
	}
	return link.devices[string(deviceID)]
}

// broadcast 把一条无寻址帧发给这台电脑的全部设备（hostStatus 的常规路径）。
//
// 走控制优先队列而不是流式大队列：hostStatus 是可丢的状态广播，不能因为某台手机
// 正在收一堆大帧就把它的连接按 4008 断掉，也不能排在那些大帧后面。
func (h *Hub) broadcast(link *AgentLink, frame dlp.Frame) {
	payload, err := dlp.Encode(frame)
	if err != nil {
		h.log.Warn("relay: could not encode a broadcast frame",
			"agentId", link.AgentID, "error", err)
		return
	}
	kind := frame.Type()
	droppable := dlp.IsDroppableControl(kind)
	for _, device := range h.attachedDevices(link) {
		device.EnqueueControl(payload, kind, droppable)
	}
}

// attachedDevices 取这台电脑当前挂着的设备（不持锁返回）。
func (h *Hub) attachedDevices(link *AgentLink) []*DeviceLink {
	shard := &h.agentShards[shardIndex(link.AgentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	devices := make([]*DeviceLink, 0, len(link.devices))
	for _, device := range link.devices {
		devices = append(devices, device)
	}
	return devices
}

// Target 是 SendControl 需要的最小接口。*AgentLink / *DeviceLink 通过内嵌的
// *Link 满足它，所以调用方不必写两次类型转换。
type Target interface {
	Enqueue(payload []byte, class Class, owned *dlp.Buffer) EnqueueResult
	EnqueueControl(payload []byte, frameType string, droppable bool) EnqueueResult
	Label() string
	RequestClose(code int, reason string)
}

// SendControl 发一帧中转控制帧。
//
// 分级只看帧类型（dlp.IsDroppableControl）：
//   - 可丢（pong/ping/hostStatus/accountState）：队列满时丢弃并计数，不断链；
//   - 必达（deviceAttach/deviceDetach/error/fs*）：最多等 controlWait，仍发不进去
//     才以 4008 断开这条连接——必达帧静默丢失比断线更难排查。
//
// 走哪条通道由 dlp.IsOrderedControl 决定：心跳/生命周期/状态走优先队列，永远排在
// 流式帧之前；error/fs* 与它们所属的数据帧共用大队列以保序。这是 2026-10-23 故障
// 之后"pong 不再被流式帧挤掉"的落点。
func (h *Hub) SendControl(link Target, frame dlp.Frame) {
	payload, err := dlp.Encode(frame)
	if err != nil {
		h.log.Warn("relay: could not encode a control frame", "link", link.Label(), "error", err)
		return
	}
	kind := frame.Type()
	if link.EnqueueControl(payload, kind, dlp.IsDroppableControl(kind)) == Overloaded {
		h.log.Warn("relay: control frame could not be queued; closing the link",
			"link", link.Label(), "frame", kind)
		link.RequestClose(dlp.CloseBackpressure, "backpressure")
	}
}

// SendBridgeChunk 把一条上行分片交给连接器的发送队列，并把这笔桥字节额度转移过去。
//
// 额度的所有权在**入队成功时**归队列（帧写出去、被丢弃或随连接关闭清空时归还）；
// 失败（链路已关、队列满、编码失败）时立刻归还并返回 false——调用方据此结束这次
// 上传。两条路都只归还一次：额度不会因为一次失败的上传漏掉。
func (h *Hub) SendBridgeChunk(link *AgentLink, frame dlp.Frame, creditBytes int64) bool {
	if link == nil {
		return false
	}
	payload, err := dlp.Encode(frame)
	if err != nil {
		h.log.Warn("relay: could not encode an upload chunk", "link", link.Label(), "error", err)
		link.ReleaseBridgeBytes(creditBytes)
		return false
	}
	if link.EnqueueWithCredit(payload, ClassControl, link.credits, creditBytes) != Enqueued {
		h.log.Warn("relay: upload chunk could not be queued; closing the link",
			"link", link.Label())
		link.ReleaseBridgeBytes(creditBytes)
		link.RequestClose(dlp.CloseBackpressure, "backpressure")
		return false
	}
	return true
}

// ── 记账 ─────────────────────────────────────────────────────────────────────

// noteClientBuild 记录手机上报的构建号（只在值变化时写库）。
func (h *Hub) noteClientBuild(link *DeviceLink, wire dlp.Wire) {
	frame, err := wire.Decode()
	if err != nil {
		return
	}
	args, ok := frame["args"].(map[string]any)
	if !ok {
		return
	}
	var parts []string
	for _, key := range []string{"clientVersion", "clientBuild"} {
		if text, ok := args[key].(string); ok && text != "" {
			parts = append(parts, text)
		}
	}
	if len(parts) == 0 {
		return
	}
	reported := strings.Join(parts, " ")
	// 记进当天那行要在"和上次一样就跳过"之前：重连时设备行里已经是这个构建号，
	// 早退的话当天那行的 lastBuild 永远是空的。
	h.usage.NoteBuild(link, reported)
	if current := link.appVersion.Load(); current != nil && *current == reported {
		return
	}
	link.appVersion.Store(&reported)
	if h.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.store.SetDeviceAppVersion(ctx, link.DeviceID, reported); err != nil {
		h.log.Warn("relay: could not record the client build",
			"deviceId", link.DeviceID, "error", err)
		return
	}
	h.log.Info("relay: device reports its build",
		"deviceId", link.DeviceID, "build", reported)
}

// noteAgentVersions 记下这台电脑跑的是哪套版本（只认控制帧 hostStatus）。
//
// 用户报问题时我们手里只有中转：设备行里有手机的构建号，但电脑上是哪版连接器、
// 哪版 DSH 只有这里能留下。写库只在值变化时发生，一次连接最多一行。
func (h *Hub) noteAgentVersions(link *AgentLink, frame dlp.Frame) {
	info, ok := frame["info"].(map[string]any)
	if !ok {
		return
	}
	text := func(key string) string {
		value, ok := info[key].(string)
		if !ok {
			return ""
		}
		return strings.TrimSpace(value)
	}
	connector, host := text("version"), text("hostVersion")
	if connector == "" && host == "" {
		return
	}
	link.versionMu.Lock()
	if connector == link.connectorVersion && host == link.hostVersion {
		link.versionMu.Unlock()
		return
	}
	link.connectorVersion, link.hostVersion = connector, host
	link.versionMu.Unlock()

	// 这条连接完成了初始化：解除该 agent 的 unverified 标记与重连退避。
	// 只认当前代（迟到的旧连接上报不能给新连接背书）。
	if h.presence.Verified(link.AgentID, link.generation, time.Now()) {
		h.log.Info("relay: agent cleared its unverified state",
			"agentId", link.AgentID, "connector", connector, "host", host)
	}

	if h.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.store.SetAgentVersions(ctx, link.AgentID,
		optionalString(connector), optionalString(host), 0); err != nil {
		h.log.Warn("relay: could not record the agent versions",
			"agentId", link.AgentID, "error", err)
		return
	}
	h.log.Info("relay: agent reports its versions",
		"agentId", link.AgentID, "connector", connector, "host", host)
}

// ── 账户级通知 ───────────────────────────────────────────────────────────────

// NotifyAccountState 给同账户的在线设备各发一帧 accountState，返回送达数。
//
// **尽力而为**：入队失败（对端太慢）就当没发，不重试、不入队、不阻断写入方——
// 这条通道的意义是"两三秒内其他设备跟上"，最终一致性靠客户端前台拉取兜底。
// 排除写入者：它自己刚写完，本机已经改了。
func (h *Hub) NotifyAccountState(accountID string, keys []string, excludeDeviceID string) int {
	if accountID == "" || len(keys) == 0 {
		return 0
	}
	payload, err := dlp.Encode(dlp.AccountStateFrame(keys))
	if err != nil {
		h.log.Warn("relay: could not encode an accountState frame", "error", err)
		return 0
	}
	sent := 0
	for _, device := range h.allDevices() {
		if device.AccountID != accountID || device.Closed() {
			continue
		}
		if excludeDeviceID != "" && device.DeviceID == excludeDeviceID {
			continue
		}
		if device.EnqueueControl(payload, "accountState", true) == Enqueued {
			sent++
		}
	}
	return sent
}

// allDevices 取全部在线设备（跨分片快照）。
func (h *Hub) allDevices() []*DeviceLink {
	var devices []*DeviceLink
	for index := range h.deviceShards {
		shard := &h.deviceShards[index]
		shard.mu.RLock()
		for _, device := range shard.devices {
			devices = append(devices, device)
		}
		shard.mu.RUnlock()
	}
	return devices
}

// ── 关停 ─────────────────────────────────────────────────────────────────────

// Shutdown 通知所有连接并等待写循环退出（有上限）。
//
// 顺序：先停接受（由调用方关监听）→ 通知全部连接 → 等队列排空/关闭握手 → 退出。
func (h *Hub) Shutdown(ctx context.Context) {
	if !h.closed.CompareAndSwap(false, true) {
		return
	}
	// 先让等待中的文件请求以 host/offline 结束：连接即将断开，回帧不会再来。
	h.failAllBridges("the relay is shutting down")
	links := make([]*Link, 0, 64)
	for index := range h.agentShards {
		shard := &h.agentShards[index]
		shard.mu.RLock()
		for _, agent := range shard.agents {
			links = append(links, agent.Link)
		}
		shard.mu.RUnlock()
	}
	for _, device := range h.allDevices() {
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

// optionalString 把空串转成 nil（"上报方没给这一项"，不拿旧值去补）。
func optionalString(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

// stringValue 取 *string 的内容；nil 时为空串。
func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

// statusValue 取 *int 的内容（日志字段用；nil 时是 nil）。
func statusValue(value *int) any {
	if value == nil {
		return nil
	}
	return *value
}

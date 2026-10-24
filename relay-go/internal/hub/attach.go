package hub

import (
	"context"
	"log/slog"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/bridge"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/quota"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 连接生命周期编排（DESIGN-20261023 §2.3 / §3.6 的 attach 单元）。
//
// 准入、登记、顶替、断线、设备挂接与拆除都在这里；连接图本身归 registry，
// 本文件只按固定顺序调用它，并在需要时发控制帧、写日志、冲账。

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

// noteStreamDrop 是一条连接的流式帧丢弃满一个告警窗口时的唯一告警点
// （WARN 日志与 monitor 都从这里取数；窗口计数在 Link 里）。
func (h *Hub) noteStreamDrop(link *Link, dropped int64) {
	h.log.Warn("relay: stream frames are being dropped under sustained backpressure",
		"link", link.Label(), "droppedInWindow", dropped,
		"totalDropped", link.DroppedFrames(),
		"queueDepth", link.QueueDepth(), "queuedBytes", link.QueuedBytes(),
		"remote_ip", link.Remote(), "lastInboundAge", link.LastInboundAge().String())
	if h.monitor != nil {
		h.monitor.NoteStreamDrop(link.Label(), dropped)
	}
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

	// devices 只在所属分片的写锁下由 registry 修改（同一个 agent 永远落在同一片）。
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
	link.Link.credits = bridge.NewCredits(h.limits.BridgeBytes)
	// 连接器链路的心跳是 DLP ping：连接器的读循环会把 ping 原样回成 pong。
	link.Link.heartbeatKind = heartbeatDLP

	h.retireAgent(agent.AgentID, link.generation)

	h.registry.registerAgent(link)
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
	devices := h.registry.devicesOfAgent(link.AgentID)
	adopted := 0
	for _, device := range devices {
		if device.Closed() {
			continue
		}
		if !h.registry.bindDevice(link, device) {
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
	for _, device := range h.registry.devicesOfAgent(agent.AgentID) {
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
	devices, current := h.registry.detachAgent(link)
	if !current {
		// 已经被更新的连接顶替，摘除与通知都归新连接——但**挂在这条旧 socket 上的
		// 文件桥**必须在这里结束：它们的 fs* 回帧永远不会再来了。按链接身份而不是
		// agentId 收尾，才不会误伤新连接刚开的传输。
		h.dropAgentBridges(link, "the PC connector reconnected")
		return
	}

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
	for _, device := range h.registry.releaseDevices(link, devices) {
		h.SendControl(device, dlp.HostStatus(false, link.AgentID, "", "", nil))
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

	// agent 是"这台设备此刻挂在哪条电脑连接上"的热路径只读缓存（每帧原子 Load）；
	// 写入只允许 registry（见 registry.go 的三索引规则）。
	agent      atomic.Pointer[AgentLink]
	appVersion atomic.Pointer[string]

	// idMember 是 `"deviceId":"<id>"` 的预编码字节：每帧就地追加，不在热路径上编码。
	idMember []byte

	bucket     *quota.Bucket
	pacedNanos atomic.Int64
	closed     atomic.Bool

	// usage 是当天用量的唯一账本（状态在 quota）。设备对象不反向持有 Hub
	// （DESIGN §3.3）；nil 只出现在单测直接构造的 DeviceLink 上。
	usage *quota.Usage
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
	link.bucket = quota.NewBucket(h.limits.DeviceBytesPerSecond, time.Now())
	link.Link.pace = link.pace
	link.Link.onSent = link.countEgress
	link.usage = h.usage

	// 日额度的基线要在挂上去之前定好（读库，不在转发热路径上）。
	h.quota.Seat(ctx, device.DeviceID)

	agent, err := h.registry.attachToAgent(link, h.limits.MaxDevicesPerAgent)
	if err != nil {
		h.log.Warn("relay: refused a device socket at the device limit",
			"agentId", link.AgentID, "deviceId", link.DeviceID,
			"limit", h.limits.MaxDevicesPerAgent)
		return nil, err
	}

	previous := h.registry.registerDevice(link)
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
	h.usage.NoteConnection(link.ref())
	h.log.Info("relay: device attached",
		"deviceId", device.DeviceID, "name", device.Name, "agentId", device.AgentID,
		"accountId", device.AccountID, "remote_ip", link.Remote(),
		"hostOnline", agent != nil)
	return link, nil
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
	// 关系摘除与"要不要通知"的判定在 registry 里用同一把 agent 分片锁完成：
	// 电脑重连认领设备的那个瞬间如果不互斥，拆除会漏掉刚挂上的那条登记。
	if agent, didNotify, didReplace := h.registry.detachFromAgent(link); agent != nil {
		notified, replaced = didNotify, didReplace
		if notified {
			h.SendControl(agent, dlp.DeviceDetachFrame(link.DeviceID, reason))
		} else if replaced {
			h.log.Info("relay: device closed a socket that had already been replaced; "+
				"no detach notification sent", "deviceId", link.DeviceID, "agentId", agent.AgentID)
		}
	}

	h.registry.unregisterDevice(link)

	link.RequestClose(closeCode, reason)
	h.log.Info("relay: device detached",
		"deviceId", link.DeviceID, "agentId", link.AgentID, "reason", reason,
		"closeCode", closeCode, "duration_ms", link.Lifetime().Milliseconds(),
		"remote_ip", link.Remote(), "notified", notified,
		"lastInboundAge", link.LastInboundAge().String(),
		"lastError", link.LastError())
	// 断开时同步冲一次：这一批的尾巴不留在内存里，运维命令跑完就是准的。
	// 同步是为了"拆完就能读到"；上限 usageWriteTimeout 保证不会真的挂住拆除路径
	// （DESIGN §3.3：不改成异步）。
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
	wait := d.bucket.Take(size, time.Now())
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
	if d.usage != nil {
		d.usage.NoteEgress(d.ref(), size)
	}
}

// ref 是 quota 记账需要的设备身份（账本按 deviceId，冲盘行还要 agent/account）。
func (d *DeviceLink) ref() quota.DeviceRef {
	return quota.DeviceRef{
		DeviceID: d.DeviceID, AgentID: d.AgentID, AccountID: d.AccountID,
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

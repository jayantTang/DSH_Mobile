// Package presence 是连接器连接的生命周期策略：准入、重复连接抑制、
// 未上报版本连接器的有界退避，以及这几个决策的计数。
//
// 它不持有 socket、不持有注册表、也不起连接：活连接仍然只由 hub 拥有。
// hub 在握手前把「注册表里这个 agent 现在是什么状态」交给这里（Observation），
// 这里只回答「现在能不能接、要不要等、拒绝多久」；等待旧连接退出由 hub 执行，
// 因为只有 hub 拿得到那条连接的 Done 通道。这样职责只有一份：
//
//   - hub：谁是当前连接、哪条 socket 要关；
//   - presence：什么条件下允许一条新连接（策略与计数）。
//
// 三个窗口的口径（常量见下）：
//
//	HelloTimeout  连接后多久没上报 connectorVersion/hostVersion 就算 unverified。
//	              正常连接器连上后立刻发 hostStatus（含两段版本），这个窗口只用来
//	              区分「还没报」与「根本不会报」。
//	ActiveIdle    一条连接多久没有任何入站帧算僵死。僵死的旧连接可以被新连接顶替；
//	              仍然活跃的旧连接不许被顶替（那正是秒级重连循环的成因）。
//	WaitForOld    旧连接仍活跃时，新连接最多等它自己退出这么久；等不到就拒绝。
//	              正常网络抖动后旧 socket 会先退出，走的是「立即允许」那条路。
package presence

import (
	"sync"
	"time"
)

// 默认窗口。理由见包注释；BackoffBase/BackoffMax 是未验证连接器的服务端退避区间。
const (
	DefaultHelloTimeout  = 10 * time.Second
	DefaultActiveIdle    = 45 * time.Second
	DefaultWaitForOld    = 1500 * time.Millisecond
	DefaultBackoffBase   = 5 * time.Second
	DefaultBackoffMax    = 60 * time.Second
	DefaultSweepInterval = 5 * time.Second

	// refusalLogInterval 是同一个 agent 拒绝日志的最小间隔：风暴下每个请求都记
	// 一条 Info 会把 journal 冲掉，运维看到的应该是一条趋势而不是几千行。
	refusalLogInterval = 60 * time.Second
)

// 拒绝原因（写进 429 的 details 与日志，用例也按它断言）。
const (
	// ReasonDuplicate 表示同一 agent 的现有连接仍活跃，新连接被抑制。
	ReasonDuplicate = "duplicate-active"
	// ReasonUnverified 表示该 agent 此前被判定为未上报版本，正在退避窗口内。
	ReasonUnverified = "unverified-backoff"
	// ReasonPending 表示同一 agent 的另一条连接已经通过准入、还没完成挂接。
	ReasonPending = "arrival-in-flight"
	// ReasonStale 不是拒绝：旧连接已经僵死，允许新连接顶替。
	ReasonStale = "stale-connection"
)

// Options 是策略窗口；零值一律取默认。
type Options struct {
	HelloTimeout  time.Duration
	ActiveIdle    time.Duration
	WaitForOld    time.Duration
	BackoffBase   time.Duration
	BackoffMax    time.Duration
	SweepInterval time.Duration
}

func (o Options) withDefaults() Options {
	if o.HelloTimeout <= 0 {
		o.HelloTimeout = DefaultHelloTimeout
	}
	if o.ActiveIdle <= 0 {
		o.ActiveIdle = DefaultActiveIdle
	}
	if o.WaitForOld <= 0 {
		o.WaitForOld = DefaultWaitForOld
	}
	if o.BackoffBase <= 0 {
		o.BackoffBase = DefaultBackoffBase
	}
	if o.BackoffMax < o.BackoffBase {
		o.BackoffMax = DefaultBackoffMax
		if o.BackoffMax < o.BackoffBase {
			o.BackoffMax = o.BackoffBase
		}
	}
	if o.SweepInterval <= 0 {
		o.SweepInterval = DefaultSweepInterval
	}
	return o
}

// Observation 是 hub 在准入前交来的、关于该 agent 现有连接的事实。
//
// 它只描述注册表此刻的样子，不包含任何策略判断：判断全部在 Gate 里。
type Observation struct {
	// Connected 表示注册表里仍有一条未进入关闭流程的连接。
	Connected bool
	// Generation 是那条连接的代编号（由 Grant 分配）；Connected=false 时忽略。
	Generation uint64
	// AttachedAt 是那条连接挂上的时刻；LastInbound 是最后一次收到它任何帧的时刻
	// （零值表示从未收到）。两者共同决定「僵死」：取较晚的那个算空闲。
	AttachedAt  time.Time
	LastInbound time.Time
}

// Verdict 是一次准入询问的答案类别。
type Verdict int

const (
	// Allow 表示可以挂接；hub 随后用 Grant 取一张票。
	Allow Verdict = iota
	// Wait 表示旧连接仍活跃，hub 应先等它退出 WaitFor；退出后重新询问即可。
	Wait
	// Refuse 表示按策略拒绝（握手前回 429），RetryAfter 是建议的重试间隔。
	Refuse
)

// Decision 是一次准入询问的完整答案。
type Decision struct {
	Verdict Verdict
	// WaitFor 只在 Verdict==Wait 时非零。
	WaitFor time.Duration
	// RetryAfter 只在 Verdict==Refuse 时非零。
	RetryAfter time.Duration
	// Reason 是原因标签（Reason* 常量或 "reconnect"）。
	Reason string
	// Log 表示这次拒绝值得记一条日志（同一 agent 每分钟最多一次）。
	Log bool
	// Streak 是该 agent 连续被抑制的到达次数（1 表示刚进入风暴），供日志与用例读。
	Streak int
	// Unverified 表示这次拒绝发生在"该 agent 从未上报版本"的退避窗口内。
	// 日志用它把一次普通顶替与被降级的连接器分开。
	Unverified bool
}

// Stats 是 /stats 暴露的生命周期计数。
//
// UnverifiedAgents 是**当前**在线且未上报版本的连接数（gauge），由 hub 遍历
// 注册表时填入；其余都是进程启动以来的累计值。UnverifiedTotal 是累计被标记
// unverified 的连接数，用来区分「一个坏连接器」与「很多坏连接器」。
type Stats struct {
	Superseded        int64 `json:"superseded"`
	ReconnectStorm    int64 `json:"reconnectStorm"`
	UnverifiedAgents  int   `json:"unverifiedAgents"`
	UnverifiedTotal   int64 `json:"unverifiedTotal"`
	RefusedDuplicate  int64 `json:"refusedDuplicate"`
	RefusedUnverified int64 `json:"refusedUnverified"`
}

// agentState 是单个 agent 的生命周期状态。
//
// generation 每通过一次准入就 +1：旧连接退出时的 Detached 带着旧编号，晚到的
// 通知不会把新连接的状态改错（同 device 的 closed 标志是同一套思路）。
type agentState struct {
	generation uint64
	attached   bool
	attachedAt time.Time
	verified   bool
	// pending 表示已准入、还没完成挂接（含正在做握手的这条）。
	pending bool

	// unverified 是「这个 agent 有过不报版本的连接」的持久标记，直到出现一次
	// 上报了版本的连接才清除。
	unverified bool
	// failures 是未验证退避的连续档位；nextAllowed 之前一律拒绝。
	failures    int
	nextAllowed time.Time

	// streak 是连续被抑制的到达次数（成功挂接时归零）；lastRefusalLog 控制日志频率。
	streak         int
	lastRefusalLog time.Time
}

// Gate 是全部 agent 的生命周期策略状态。并发安全。
type Gate struct {
	mu      sync.Mutex
	options Options
	agents  map[string]*agentState
	stats   Stats
}

// New 建一个空的 Gate。
func New(options Options) *Gate {
	return &Gate{options: options.withDefaults(), agents: map[string]*agentState{}}
}

// Options 返回生效中的窗口（hub 用它决定 sweep 周期与等待上限）。
func (g *Gate) Options() Options { return g.options }

func (g *Gate) stateLocked(agentID string) *agentState {
	state := g.agents[agentID]
	if state == nil {
		state = &agentState{}
		g.agents[agentID] = state
	}
	return state
}

// Admit 判定一次到达。纯内存判断，不阻塞、不持有连接。
func (g *Gate) Admit(agentID string, now time.Time, obs Observation) Decision {
	g.mu.Lock()
	defer g.mu.Unlock()
	state := g.stateLocked(agentID)

	// 同一 agent 的另一条连接已经通过了准入：两次握手同时到达时只放一条进去。
	if state.pending {
		return g.refuseLocked(state, now, ReasonPending)
	}

	// 先补一次「连上超过 HelloTimeout 仍没报版本」的判定：统计页与退避都读这一位。
	if obs.Connected && state.attached && obs.Generation == state.generation &&
		!state.verified && now.Sub(state.attachedAt) >= g.options.HelloTimeout {
		g.markUnverifiedLocked(state)
	}

	// 未验证连接器的退避窗口：无论它现在有没有旧连接，都先挡在门外。
	if state.unverified && now.Before(state.nextAllowed) {
		return g.refuseLocked(state, now, ReasonUnverified)
	}

	// 旧连接已经退出（或被判定退出）：正常网络抖动后的重连，立即允许。
	if !obs.Connected {
		// 允许的同时占住 pending：两条握手并发到达时，第二个会看到 pending 并被
		// 拒绝，不会出现「都通过准入、各拿一张票」的窗口。Grant 复用这个标记。
		state.pending = true
		return Decision{Verdict: Allow, Reason: "reconnect"}
	}

	// 旧连接僵死（足够久没有任何入站帧）：允许顶替，避免一条死 socket 把
	// 真正的重连挡在门外。
	if g.staleLocked(obs, now) {
		state.pending = true
		return Decision{Verdict: Allow, Reason: ReasonStale}
	}

	// 旧连接仍然活跃：不允许立即顶替。hub 会等 WaitFor，旧连接自己退出就放行；
	// 等不到才走 Suppress 拒绝并计数。
	return Decision{Verdict: Wait, WaitFor: g.options.WaitForOld, Reason: ReasonDuplicate}
}

// staleLocked 判断注册表里的旧连接是否已经僵死。
//
// 空闲从「挂上」与「最后入站」里较晚的那个算起：刚挂上、还没来得及发任何帧的
// 连接**不算**僵死——否则异常连接器每秒开一条新连接就能把「刚连上的那条」当成
// 死的顶掉，正是要消除的形态。
func (g *Gate) staleLocked(obs Observation, now time.Time) bool {
	reference := obs.AttachedAt
	if obs.LastInbound.After(reference) {
		reference = obs.LastInbound
	}
	if reference.IsZero() {
		return true // 连时间都不知道：按没有旧连接处理
	}
	return now.Sub(reference) >= g.options.ActiveIdle
}

// Grant 发放一张准入票：占住 pending，并把代编号 +1。
//
// 调用方必须在握手失败或放弃时 Release；成功挂接后 Commit。票不是连接的所有者，
// 只是「这次准入已经记账」的凭证。挂接时刻由 Commit 记，Grant 不重复收一份时间。
func (g *Gate) Grant(agentID string) *Ticket {
	g.mu.Lock()
	defer g.mu.Unlock()
	state := g.stateLocked(agentID)
	state.generation++
	state.pending = true
	state.verified = false
	return &Ticket{gate: g, agentID: agentID, generation: state.generation}
}

// Ticket 是一次准入的凭证（见 Grant）。
type Ticket struct {
	gate       *Gate
	agentID    string
	generation uint64
	committed  bool
	released   bool
}

// Generation 是这次准入分配的连接代编号；hub 把它记在连接上，之后的
// Verified/Detached/MarkUnverified 都按它对齐。
func (t *Ticket) Generation() uint64 { return t.generation }

// Commit 在连接真正挂进注册表后调用：从这一刻起 helloTimeout 开始计时。
func (t *Ticket) Commit(now time.Time) {
	if t == nil || t.gate == nil {
		return
	}
	g := t.gate
	g.mu.Lock()
	defer g.mu.Unlock()
	state := g.stateLocked(t.agentID)
	if state.generation != t.generation {
		return
	}
	if t.committed {
		return
	}
	t.committed = true
	state.pending = false
	state.attached = true
	state.attachedAt = now
	state.verified = false
	state.streak = 0
}

// Release 释放一张没被用掉的票（握手失败、客户端在升级前断开）。
func (t *Ticket) Release() {
	if t == nil || t.gate == nil {
		return
	}
	g := t.gate
	g.mu.Lock()
	defer g.mu.Unlock()
	if t.released {
		return
	}
	t.released = true
	state := g.stateLocked(t.agentID)
	if state.pending && state.generation == t.generation {
		state.pending = false
	}
}

// Suppress 记一次「已决定拒绝」：计数、必要时升一档退避，并给出 RetryAfter。
//
// 它由 hub 在两种情形调用：Admit 返回 Wait 但旧连接在窗口内没有退出；以及
// Admit 已经返回 Refuse 时（Admit 内部已计过数，不重复调用）。
func (g *Gate) Suppress(agentID, reason string, now time.Time) Decision {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.refuseLocked(g.stateLocked(agentID), now, reason)
}

// refuseLocked 是拒绝记账的唯一实现。
func (g *Gate) refuseLocked(state *agentState, now time.Time, reason string) Decision {
	// 未验证退避正在生效时，真正让这次到达被拒的是退避，不是 duplicate：
	// 否则 429 会说 duplicate-active，却要求等 60 秒，并把计数算进 duplicate。
	// （pending 是更早、更具体的并发握手原因，保留它。）
	if reason == ReasonDuplicate && state.unverified && now.Before(state.nextAllowed) {
		reason = ReasonUnverified
	}
	state.streak++
	g.stats.ReconnectStorm++
	if reason == ReasonUnverified {
		g.stats.RefusedUnverified++
	} else {
		g.stats.RefusedDuplicate++
	}
	// 未验证连接器：每过一个允许窗口才升一档。风暴期间每秒一次的到达不会把
	// nextAllowed 无限往后推（那会让一个抖动中的连接器永久出局）。
	if state.unverified && !now.Before(state.nextAllowed) {
		if state.failures < 30 {
			state.failures++
		}
		state.nextAllowed = now.Add(g.backoffLocked(state.failures))
	}
	logNow := state.streak == 1 || now.Sub(state.lastRefusalLog) >= refusalLogInterval
	if logNow {
		state.lastRefusalLog = now
	}
	return Decision{
		Verdict: Refuse, Reason: reason,
		RetryAfter: g.retryAfterLocked(state, now), Log: logNow, Streak: state.streak,
		Unverified: state.unverified,
	}
}

// backoffLocked 是 5s → 10s → … → 60s 的指数退避（函数名保留 Locked 后缀：
// 调用方持有 g.mu，与其它 *Locked 方法一致）。
func (g *Gate) backoffLocked(failures int) time.Duration {
	delay := g.options.BackoffBase
	for step := 1; step < failures && delay < g.options.BackoffMax; step++ {
		delay *= 2
	}
	if delay > g.options.BackoffMax {
		delay = g.options.BackoffMax
	}
	return delay
}

// retryAfterLocked 给出 429 的 Retry-After：优先用退避窗口，否则用等待窗口
// （验证过的连接器不受服务端退避，重试节奏交给连接器自己的指数退避）。
func (g *Gate) retryAfterLocked(state *agentState, now time.Time) time.Duration {
	if wait := state.nextAllowed.Sub(now); wait > 0 {
		return wait
	}
	if wait := g.options.WaitForOld; wait > 0 {
		return wait
	}
	return time.Second
}

// Verified 记录「这条连接上报了 connectorVersion/hostVersion」。
//
// 只有当前代的连接能清掉 unverified 与退避：迟到的旧连接上报不能给一条新连接
// 背书。返回 false 表示这次上报不属于当前代。
func (g *Gate) Verified(agentID string, generation uint64, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	state := g.agents[agentID]
	if state == nil || state.generation != generation {
		return false
	}
	state.verified = true
	state.unverified = false
	state.failures = 0
	state.nextAllowed = time.Time{}
	return true
}

// Detached 在一条连接退出后调用；返回 true 表示这次退出让 agent 首次被标记
// unverified。
//
// 连接建起来后一次版本都没报就退了，也算 unverified（不看存活时长）：正常连接器
// 连上后立刻发 hostStatus，连这条帧都没有的连接器不可能完成初始化。这个标记是
// 后面有界退避的依据。
func (g *Gate) Detached(agentID string, generation uint64, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	state := g.agents[agentID]
	if state == nil || !state.attached || state.generation != generation {
		return false
	}
	state.attached = false
	return g.markDetachedUnverifiedLocked(state)
}

func (g *Gate) markDetachedUnverifiedLocked(state *agentState) bool {
	if state.verified || state.unverified {
		return false
	}
	return g.markUnverifiedLocked(state)
}

// MarkUnverified 在周期扫描里补记「连上超过 HelloTimeout 仍没报版本」。
// 返回 true 表示这次首次标记，hub 据此记一条 WARN（每条连接只记一次）。
func (g *Gate) MarkUnverified(agentID string, generation uint64, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	state := g.agents[agentID]
	if state == nil || !state.attached || state.generation != generation ||
		state.verified || state.unverified {
		return false
	}
	if now.Sub(state.attachedAt) < g.options.HelloTimeout {
		return false
	}
	return g.markUnverifiedLocked(state)
}

func (g *Gate) markUnverifiedLocked(state *agentState) bool {
	if state.unverified {
		return false
	}
	state.unverified = true
	g.stats.UnverifiedTotal++
	return true
}

// Unverified 报告某条**在线**连接此刻是否算未上报版本（纯读，不记状态）。
//
// /stats 的 unverifiedAgents 用它逐个数：注册表是连接的所有者，这里只回答
// 「这一代连接有没有报版本、挂了多久」。
func (g *Gate) Unverified(agentID string, generation uint64, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	state := g.agents[agentID]
	if state == nil || !state.attached || state.generation != generation || state.verified {
		return false
	}
	return now.Sub(state.attachedAt) >= g.options.HelloTimeout
}

// NoteSuperseded 记一次「旧连接被新连接顶替」。只在 hub 真的关掉旧连接时调用。
func (g *Gate) NoteSuperseded() {
	g.mu.Lock()
	g.stats.Superseded++
	g.mu.Unlock()
}

// Stats 返回累计计数（UnverifiedAgents 为 0，由 hub 遍历注册表填入）。
func (g *Gate) Stats() Stats {
	g.mu.Lock()
	defer g.mu.Unlock()
	stats := g.stats
	stats.UnverifiedAgents = 0
	return stats
}

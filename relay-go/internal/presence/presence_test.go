package presence

import (
	"testing"
	"time"
)

// base 是一条连接挂上的时刻；所有用例都以它为原点，避免依赖真实时钟。
var base = time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)

// connect 走一遍「准入 → 挂接」，返回票与挂接时刻。
func connect(t *testing.T, gate *Gate, agentID string, now time.Time) *Ticket {
	t.Helper()
	decision := gate.Admit(agentID, now, Observation{})
	if decision.Verdict != Allow {
		t.Fatalf("空 agent 的准入 = %+v，期望 Allow", decision)
	}
	ticket := gate.Grant(agentID)
	ticket.Commit(now)
	return ticket
}

func TestAdmitAllowsWhenTheOldConnectionIsGone(t *testing.T) {
	gate := New(Options{})
	decision := gate.Admit("agt_1", base, Observation{Connected: false})
	if decision.Verdict != Allow {
		t.Fatalf("旧连接已退出时 = %+v，期望 Allow", decision)
	}
}

func TestAdmitWaitsWhileTheOldConnectionIsActive(t *testing.T) {
	gate := New(Options{})
	decision := gate.Admit("agt_1", base, Observation{
		Connected: true, Generation: 1,
		AttachedAt: base.Add(-time.Minute), LastInbound: base.Add(-time.Second),
	})
	if decision.Verdict != Wait {
		t.Fatalf("旧连接活跃时 = %+v，期望 Wait", decision)
	}
	if decision.WaitFor != DefaultWaitForOld {
		t.Fatalf("等待上限 = %v，期望 %v", decision.WaitFor, DefaultWaitForOld)
	}
}

func TestAFreshConnectionWithoutAnyInboundIsNotStale(t *testing.T) {
	// 刚挂上、还没有任何入站帧的连接不能被当成僵死：否则异常连接器每秒开一条
	// 新连接就能顶掉上一条，秒级循环原样保留。
	gate := New(Options{})
	decision := gate.Admit("agt_1", base, Observation{
		Connected: true, Generation: 1,
		AttachedAt: base.Add(-time.Second),
	})
	if decision.Verdict != Wait {
		t.Fatalf("刚连上 1 秒的连接 = %+v，期望 Wait", decision)
	}
}

func TestAdmitAllowsSupersedeAfterTheOldConnectionWentIdle(t *testing.T) {
	gate := New(Options{})
	decision := gate.Admit("agt_1", base, Observation{
		Connected: true, Generation: 1,
		AttachedAt: base.Add(-time.Hour), LastInbound: base.Add(-time.Minute),
	})
	if decision.Verdict != Allow || decision.Reason != ReasonStale {
		t.Fatalf("僵死旧连接 = %+v，期望 Allow(%s)", decision, ReasonStale)
	}
}

func TestATicketHoldsOffOtherArrivalsUntilReleased(t *testing.T) {
	gate := New(Options{})
	ticket := gate.Grant("agt_1")
	if decision := gate.Admit("agt_1", base, Observation{}); decision.Verdict != Refuse ||
		decision.Reason != ReasonPending {
		t.Fatalf("进行中的到达 = %+v，期望拒绝(%s)", decision, ReasonPending)
	}
	ticket.Commit(base)
	if decision := gate.Admit("agt_1", base, Observation{
		Connected: false, Generation: ticket.Generation(),
	}); decision.Verdict != Allow {
		t.Fatalf("挂接完成后（旧连接不在） = %+v，期望 Allow", decision)
	}
	if stats := gate.Stats(); stats.ReconnectStorm != 1 || stats.RefusedDuplicate != 1 {
		t.Fatalf("拒绝计数 = %+v", stats)
	}
}

func TestReleasedTicketDoesNotBlockTheNextArrival(t *testing.T) {
	gate := New(Options{})
	ticket := gate.Grant("agt_1")
	ticket.Release()
	decision := gate.Admit("agt_1", base, Observation{})
	if decision.Verdict != Allow {
		t.Fatalf("释放后的到达 = %+v，期望 Allow", decision)
	}
}

func TestDetachWithoutAVersionMarksTheAgentUnverified(t *testing.T) {
	gate := New(Options{})
	ticket := connect(t, gate, "agt_1", base)
	if !gate.Detached("agt_1", ticket.Generation(), base.Add(time.Second)) {
		t.Fatal("一次版本都没报就断开，应当首次标记 unverified")
	}
	if got := gate.Stats().UnverifiedTotal; got != 1 {
		t.Fatalf("unverifiedTotal = %d，期望 1", got)
	}
	// 迟到的旧代退出通知不能重复计数。
	if gate.Detached("agt_1", ticket.Generation(), base.Add(2*time.Second)) {
		t.Fatal("同一代的第二次退出不该再次标记")
	}
}

func TestAnAgentThatReportedVersionsIsNotMarkedUnverified(t *testing.T) {
	gate := New(Options{})
	ticket := connect(t, gate, "agt_1", base)
	if !gate.Verified("agt_1", ticket.Generation(), base) {
		t.Fatal("当前代上报版本应当被接受")
	}
	if gate.Detached("agt_1", ticket.Generation(), base.Add(time.Second)) {
		t.Fatal("上报过版本的连接退出不该标记 unverified")
	}
	if gate.Unverified("agt_1", ticket.Generation(), base.Add(time.Hour)) {
		t.Fatal("已上报版本的连接不该被算作 unverified")
	}
}

func TestMarkUnverifiedWaitsForTheHelloTimeout(t *testing.T) {
	gate := New(Options{HelloTimeout: 10 * time.Second})
	ticket := connect(t, gate, "agt_1", base)
	if gate.MarkUnverified("agt_1", ticket.Generation(), base.Add(5*time.Second)) {
		t.Fatal("还没到 helloTimeout 不该标记")
	}
	if !gate.MarkUnverified("agt_1", ticket.Generation(), base.Add(10*time.Second)) {
		t.Fatal("到 helloTimeout 应当标记")
	}
	if !gate.Unverified("agt_1", ticket.Generation(), base.Add(11*time.Second)) {
		t.Fatal("标记之后 /stats 的计数应当看得见这条连接")
	}
}

func TestUnverifiedReconnectsAreBackedOffAndBounded(t *testing.T) {
	gate := New(Options{
		HelloTimeout: 10 * time.Second,
		ActiveIdle:   time.Hour, // 旧连接一直算「活跃」，由退避那一臂处理
		BackoffBase:  5 * time.Second,
		BackoffMax:   20 * time.Second,
	})
	ticket := connect(t, gate, "agt_1", base)
	connected := Observation{
		Connected: true, Generation: ticket.Generation(), AttachedAt: base,
	}

	// 到 helloTimeout 仍没报版本：第一次到达先等旧连接（Wait），等不到才抑制。
	if decision := gate.Admit("agt_1", base.Add(11*time.Second), connected); decision.Verdict != Wait {
		t.Fatalf("首次重复到达 = %+v，期望 Wait", decision)
	}
	first := gate.Suppress("agt_1", ReasonDuplicate, base.Add(11*time.Second))
	if first.Verdict != Refuse || first.RetryAfter != 5*time.Second {
		t.Fatalf("第一次抑制 = %+v，期望拒绝且退避 5s", first)
	}

	// 退避窗口内：拒绝但不升档（否则风暴本身会把窗口越推越长）。
	early := gate.Admit("agt_1", base.Add(12*time.Second), connected)
	if early.Verdict != Refuse || early.Reason != ReasonUnverified || early.RetryAfter != 4*time.Second {
		t.Fatalf("窗口内到达 = %+v，期望拒绝且剩余 4s", early)
	}

	// 窗口过后再抑制一次：升到 10s。
	second := gate.Suppress("agt_1", ReasonDuplicate, base.Add(16*time.Second))
	if second.RetryAfter != 10*time.Second {
		t.Fatalf("第二次抑制的退避 = %v，期望 10s", second.RetryAfter)
	}
	// 再一档封顶在 BackoffMax。
	third := gate.Suppress("agt_1", ReasonDuplicate, base.Add(26*time.Second))
	if third.RetryAfter != 20*time.Second {
		t.Fatalf("第三次抑制的退避 = %v，期望封顶 20s", third.RetryAfter)
	}
	fourth := gate.Suppress("agt_1", ReasonDuplicate, base.Add(46*time.Second))
	if fourth.RetryAfter != 20*time.Second {
		t.Fatalf("封顶后仍应是 20s，得到 %v", fourth.RetryAfter)
	}
	stats := gate.Stats()
	if stats.ReconnectStorm != 5 || stats.RefusedUnverified != 1 || stats.RefusedDuplicate != 4 {
		t.Fatalf("计数 = %+v", stats)
	}
}

func TestAVerifiedConnectionClearsTheUnverifiedBackoff(t *testing.T) {
	gate := New(Options{
		HelloTimeout: 10 * time.Second,
		ActiveIdle:   time.Hour,
		BackoffBase:  5 * time.Second,
	})
	first := connect(t, gate, "agt_1", base)
	gate.Detached("agt_1", first.Generation(), base.Add(time.Second))
	if decision := gate.Suppress("agt_1", ReasonDuplicate, base.Add(2*time.Second)); decision.RetryAfter != 5*time.Second {
		t.Fatalf("退避 = %v", decision.RetryAfter)
	}
	if decision := gate.Admit("agt_1", base.Add(3*time.Second), Observation{}); decision.Verdict != Refuse {
		t.Fatalf("退避窗口内 = %+v，期望拒绝", decision)
	}

	// 退避窗口过后连接成功，并且这次报了版本：unverified 与退避都清掉。
	decision := gate.Admit("agt_1", base.Add(8*time.Second), Observation{})
	if decision.Verdict != Allow {
		t.Fatalf("窗口过后 = %+v，期望 Allow", decision)
	}
	second := gate.Grant("agt_1")
	second.Commit(base.Add(8 * time.Second))
	if !gate.Verified("agt_1", second.Generation(), base.Add(8*time.Second)) {
		t.Fatal("当前代上报版本应当被接受")
	}
	if decision := gate.Admit("agt_1", base.Add(9*time.Second), Observation{}); decision.Verdict != Allow {
		t.Fatalf("上报版本后的重连 = %+v，期望立即 Allow", decision)
	}
	if got := gate.Stats().UnverifiedTotal; got != 1 {
		t.Fatalf("unverifiedTotal = %d，期望 1（只记过第一次）", got)
	}
}

func TestStatsSupersededCountsOnlyRealReplacements(t *testing.T) {
	gate := New(Options{})
	gate.NoteSuperseded()
	gate.NoteSuperseded()
	stats := gate.Stats()
	if stats.Superseded != 2 {
		t.Fatalf("superseded = %d，期望 2", stats.Superseded)
	}
	if stats.UnverifiedAgents != 0 {
		t.Fatalf("gauge 应由 hub 填，Gate 里应为 0：%d", stats.UnverifiedAgents)
	}
}

func TestAllowReservesTheSlotAgainstAConcurrentArrival(t *testing.T) {
	gate := New(Options{})
	if decision := gate.Admit("agt_1", base, Observation{}); decision.Verdict != Allow {
		t.Fatalf("第一次到达 = %+v，期望 Allow", decision)
	}
	// 第一条还没 Grant 完，第二条到达：必须被挡在 pending 上，不能两条都通过。
	second := gate.Admit("agt_1", base, Observation{})
	if second.Verdict != Refuse || second.Reason != ReasonPending {
		t.Fatalf("并发到达 = %+v，期望拒绝(%s)", second, ReasonPending)
	}
	ticket := gate.Grant("agt_1")
	ticket.Commit(base)
	if decision := gate.Admit("agt_1", base, Observation{
		Connected: false, Generation: ticket.Generation(),
	}); decision.Verdict != Allow {
		t.Fatalf("挂接完成后的到达 = %+v，期望 Allow", decision)
	}
}

func TestSuppressInsideUnverifiedBackoffCountsAsUnverified(t *testing.T) {
	// 回归：风暴里先等旧连接、等不到再 Suppress 时，如果退避窗口正在生效，
	// 429 的原因与计数都必须是 unverified-backoff，不能写着 duplicate-active
	// 却要求等 60 秒。
	gate := New(Options{
		HelloTimeout: 10 * time.Second,
		ActiveIdle:   time.Hour,
		BackoffBase:  5 * time.Second,
		BackoffMax:   20 * time.Second,
	})
	ticket := connect(t, gate, "agt_1", base)
	if !gate.MarkUnverified("agt_1", ticket.Generation(), base.Add(10*time.Second)) {
		t.Fatal("到 helloTimeout 应当标记 unverified")
	}
	first := gate.Suppress("agt_1", ReasonDuplicate, base.Add(10*time.Second))
	if first.RetryAfter != 5*time.Second {
		t.Fatalf("第一次抑制退避 = %v，期望 5s", first.RetryAfter)
	}
	within := gate.Suppress("agt_1", ReasonDuplicate, base.Add(12*time.Second))
	if within.Reason != ReasonUnverified {
		t.Fatalf("退避窗口内 Suppress 的原因 = %q，期望 %q", within.Reason, ReasonUnverified)
	}
	stats := gate.Stats()
	if stats.RefusedUnverified != 1 || stats.RefusedDuplicate != 1 {
		t.Fatalf("计数 = %+v，期望 unverified=1 duplicate=1", stats)
	}
}

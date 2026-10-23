package hub

import (
	"context"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
)

// 这几个用例钉住连接生命周期策略在 hub 层的接线：判定在 internal/presence，
// hub 负责等待、关闭顺序与计数。窗口全部调到毫秒级，用例不靠真实时长。

// TestASecondAgentConnectionIsRefusedWhileTheFirstIsActive 是秒级重连循环的回归：
// 旧连接仍在工作时，新连接不许把它顶掉（否则连接器收到 4001 立刻重连，循环成立）。
func TestASecondAgentConnectionIsRefusedWhileTheFirstIsActive(t *testing.T) {
	fixture := newFixture(t, Options{
		Limits: DefaultLimits(),
		Presence: presence.Options{
			// 窗口足够大：旧连接在用例里始终算「活跃」。
			ActiveIdle: time.Hour,
			WaitForOld: 20 * time.Millisecond,
		},
	})
	owner := fixture.newTenant("storm-mac")
	first, firstSink := fixture.attachAgent(owner)
	first.NoteInbound() // 模拟连接器刚发过一帧：它是活的

	started := time.Now()
	ticket, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if ticket != nil || refusal == nil {
		t.Fatalf("活跃旧连接存在时第二连接 = ticket:%v refusal:%v，期望被拒绝", ticket, refusal)
	}
	if refusal.Reason != presence.ReasonDuplicate {
		t.Fatalf("拒绝原因 = %q，期望 %q", refusal.Reason, presence.ReasonDuplicate)
	}
	if elapsed := time.Since(started); elapsed < 15*time.Millisecond {
		t.Fatalf("拒绝前没有等旧连接（%v）：应当有界等待而不是立即顶替", elapsed)
	}
	// 旧连接必须原样活着：没有被 4001 关掉，也没有被摘出注册表。
	if fixture.hub.Agent(owner.agent.AgentID) != first {
		t.Fatal("拒绝新连接时把旧连接摘出了注册表")
	}
	if first.Closed() {
		t.Fatal("拒绝新连接时关掉了仍活跃的旧连接")
	}
	for _, call := range firstSink.closeCalls() {
		if call.Code == dlp.CloseSuperseded {
			t.Fatalf("旧连接收到了 4001：%+v", call)
		}
	}

	stats := fixture.hub.PresenceStats()
	if stats.Superseded != 0 {
		t.Fatalf("superseded = %d，期望 0（没有发生顶替）", stats.Superseded)
	}
	if stats.ReconnectStorm != 1 || stats.RefusedDuplicate != 1 {
		t.Fatalf("风暴计数 = %+v，期望 reconnectStorm=1 refusedDuplicate=1", stats)
	}
}

// TestReconnectAfterTheOldConnectionExitedIsAllowed：旧连接已经退出时，新连接必须
// 立即放行——正常网络抖动后的重连不能被抑制误伤。
func TestReconnectAfterTheOldConnectionExitedIsAllowed(t *testing.T) {
	fixture := newFixture(t, Options{
		Limits:   DefaultLimits(),
		Presence: presence.Options{ActiveIdle: time.Hour, WaitForOld: 50 * time.Millisecond},
	})
	owner := fixture.newTenant("reconnect-mac")
	first, _ := fixture.attachAgent(owner)
	fixture.hub.DetachAgent(first)
	select {
	case <-first.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("旧连接没有退出")
	}

	ticket, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if refusal != nil {
		t.Fatalf("旧连接已退出时仍被拒绝：%v", refusal)
	}
	second := fixture.hub.AttachAgent(context.Background(), owner.agent, newFakeSink(), ticket)
	t.Cleanup(func() { fixture.hub.DetachAgent(second) })
	if second.generation <= first.generation {
		t.Fatalf("新一代编号 = %d，期望大于旧代 %d", second.generation, first.generation)
	}
	if stats := fixture.hub.PresenceStats(); stats.ReconnectStorm != 0 {
		t.Fatalf("正常重连被记成风暴：%+v", stats)
	}
}

// TestAnAgentThatNeverReportsVersionsIsBackedOff：连上超过 helloTimeout 仍没有
// connectorVersion/hostVersion 的连接器，其重连进入服务端退避（不是秒级重试）。
func TestAnAgentThatNeverReportsVersionsIsBackedOff(t *testing.T) {
	fixture := newFixture(t, Options{
		Limits: DefaultLimits(),
		Presence: presence.Options{
			HelloTimeout: 10 * time.Millisecond,
			ActiveIdle:   time.Hour,
			WaitForOld:   10 * time.Millisecond,
			BackoffBase:  time.Minute,
			BackoffMax:   time.Minute,
		},
	})
	owner := fixture.newTenant("unverified-mac")
	agent, _ := fixture.attachAgent(owner)
	agent.NoteInbound() // 连接是活的，只是从不报文版本
	time.Sleep(20 * time.Millisecond)

	// 第一次重复到达：等不到旧连接退出 → 抑制，并因 unverified 进入退避。
	if _, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent); refusal == nil {
		t.Fatal("未上报版本的重复到达没有被抑制")
	}
	// 第二次紧接着到达：直接落在退避窗口里。
	_, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if refusal == nil || refusal.Reason != presence.ReasonUnverified {
		t.Fatalf("退避窗口内的到达 = %v，期望 %q", refusal, presence.ReasonUnverified)
	}
	if refusal.RetryAfter < 30*time.Second {
		t.Fatalf("退避 = %v，期望接近 1 分钟（不是毫秒级重试）", refusal.RetryAfter)
	}
	stats := fixture.hub.PresenceStats()
	if stats.UnverifiedAgents != 1 {
		t.Fatalf("unverifiedAgents = %d，期望 1", stats.UnverifiedAgents)
	}
	if stats.UnverifiedTotal != 1 || stats.RefusedUnverified < 1 {
		t.Fatalf("未验证计数 = %+v", stats)
	}
}

// TestAnAgentThatReportedVersionsIsNotBackedOff：上报过版本的连接器即使被抑制，
// 也只是普通重复连接（重试节奏交给连接器自己的退避），不进服务端退避。
func TestAnAgentThatReportedVersionsIsNotBackedOff(t *testing.T) {
	fixture := newFixture(t, Options{
		Limits: DefaultLimits(),
		Presence: presence.Options{
			HelloTimeout: 10 * time.Millisecond,
			ActiveIdle:   time.Hour,
			WaitForOld:   10 * time.Millisecond,
			BackoffBase:  time.Minute,
			BackoffMax:   time.Minute,
		},
	})
	owner := fixture.newTenant("verified-mac")
	agent, _ := fixture.attachAgent(owner)
	fixture.hub.RouteFromAgent(agent, wireOf(t, dlp.Frame{
		"t": "hostStatus",
		"info": map[string]any{
			"version":     "0.6.6",
			"hostVersion": "0.2026.10",
		},
	}))
	time.Sleep(20 * time.Millisecond)

	_, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if refusal == nil || refusal.Reason != presence.ReasonDuplicate {
		t.Fatalf("重复到达 = %v，期望 %q", refusal, presence.ReasonDuplicate)
	}
	if refusal.RetryAfter >= 30*time.Second {
		t.Fatalf("已上报版本的连接被按 unverified 退避了：%v", refusal.RetryAfter)
	}
	stats := fixture.hub.PresenceStats()
	if stats.UnverifiedAgents != 0 || stats.RefusedUnverified != 0 {
		t.Fatalf("已上报版本仍被算作未验证：%+v", stats)
	}
}

// TestAStaleAgentConnectionIsSupersededAndCounted：旧连接僵死后才允许顶替，
// 关闭码是 4001，并计入 superseded。
func TestAStaleAgentConnectionIsSupersededAndCounted(t *testing.T) {
	fixture := newFixture(t, Options{
		Limits:   DefaultLimits(),
		Presence: presence.Options{ActiveIdle: time.Millisecond},
	})
	owner := fixture.newTenant("stale-mac")
	first, firstSink := fixture.attachAgent(owner)
	time.Sleep(5 * time.Millisecond)

	ticket, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if refusal != nil {
		t.Fatalf("僵死旧连接应当允许顶替：%v", refusal)
	}
	second := fixture.hub.AttachAgent(context.Background(), owner.agent, newFakeSink(), ticket)
	t.Cleanup(func() { fixture.hub.DetachAgent(second) })
	select {
	case <-first.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("被顶替的旧连接没有退出")
	}
	found := false
	for _, call := range firstSink.closeCalls() {
		if call.Code == dlp.CloseSuperseded {
			found = true
		}
	}
	if !found {
		t.Fatalf("旧连接没有收到 4001：%+v", firstSink.closeCalls())
	}
	if stats := fixture.hub.PresenceStats(); stats.Superseded != 1 {
		t.Fatalf("superseded = %d，期望 1", stats.Superseded)
	}
}

// TestFramesFromASupersededAgentAreIgnored：旧连接退场途中残留的帧不能再改状态。
func TestFramesFromASupersededAgentAreIgnored(t *testing.T) {
	fixture := newFixture(t, Options{
		Limits:   DefaultLimits(),
		Presence: presence.Options{ActiveIdle: time.Millisecond},
	})
	owner := fixture.newTenant("stale-frames")
	first, _ := fixture.attachAgent(owner)
	time.Sleep(5 * time.Millisecond)
	ticket, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if refusal != nil {
		t.Fatalf("AdmitAgent: %v", refusal)
	}
	second := fixture.hub.AttachAgent(context.Background(), owner.agent, newFakeSink(), ticket)
	t.Cleanup(func() { fixture.hub.DetachAgent(second) })

	before := second.connectorVersion
	fixture.hub.RouteFromAgent(first, wireOf(t, dlp.Frame{
		"t": "hostStatus", "info": map[string]any{"version": "9.9.9"},
	}))
	if second.connectorVersion != before {
		t.Fatalf("旧连接的 hostStatus 改到了新连接：%q -> %q", before, second.connectorVersion)
	}
}

// TestOneSecondReconnectDoesNotFormAReplacementLoop 按生产窗口（1 秒）复现
// 「同一 agent 每秒重连」：新连接不能被立即接受并顶掉旧连接；旧连接退出后，
// 同一条重连路径必须立即放行（正常抖动不能被误伤）。
func TestOneSecondReconnectDoesNotFormAReplacementLoop(t *testing.T) {
	fixture := newFixture(t, Options{
		Limits: DefaultLimits(),
		Presence: presence.Options{
			ActiveIdle: time.Hour,
			WaitForOld: time.Second,
		},
	})
	owner := fixture.newTenant("one-second")
	first, firstSink := fixture.attachAgent(owner)
	first.NoteInbound()

	started := time.Now()
	ticket, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if ticket != nil || refusal == nil || refusal.Reason != presence.ReasonDuplicate {
		t.Fatalf("1 秒内的重复连接 = ticket:%v refusal:%v，期望被抑制", ticket, refusal)
	}
	if elapsed := time.Since(started); elapsed < 900*time.Millisecond {
		t.Fatalf("等待 %v：应当在旧连接的等待窗口上用满约 1 秒", elapsed)
	}
	if fixture.hub.Agent(owner.agent.AgentID) != first || first.Closed() {
		t.Fatal("旧连接在抑制期间被顶替/关闭")
	}
	for _, call := range firstSink.closeCalls() {
		if call.Code == dlp.CloseSuperseded {
			t.Fatalf("旧连接收到 4001：%+v", call)
		}
	}

	// 旧连接退出：新连接立即允许（不等抑制窗口）。
	fixture.hub.DetachAgent(first)
	select {
	case <-first.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("旧连接没有退出")
	}
	started = time.Now()
	ticket, refusal = fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if refusal != nil {
		t.Fatalf("旧连接退出后的重连仍被拒绝：%v", refusal)
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("旧连接退出后的准入等了 %v，期望立即", elapsed)
	}
	second := fixture.hub.AttachAgent(context.Background(), owner.agent, newFakeSink(), ticket)
	t.Cleanup(func() { fixture.hub.DetachAgent(second) })
	if stats := fixture.hub.PresenceStats(); stats.Superseded != 0 {
		t.Fatalf("superseded = %d，期望 0（没有发生顶替）", stats.Superseded)
	}
}

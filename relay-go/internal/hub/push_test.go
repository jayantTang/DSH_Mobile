package hub

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/push"
)

// fakePusher 记录"谁被要求推送"，并可按需返回预设结果。
type fakePusher struct {
	enabled bool

	mu      sync.Mutex
	calls   []pushCall
	results []push.Result
	// resultFor 按设备给结果；需要"同一次扇出里一台死令牌、其余正常"的用例用它。
	// 非 nil 时优先于 results（按 targets 顺序套 results 会依赖仓储排序）。
	resultFor func(push.Target) push.Result
	done      chan struct{}
	// block 非 nil 时 SendMany 会等它关闭（验证路由不阻塞）。
	block chan struct{}
}

type pushCall struct {
	targets        []push.Target
	kind           string
	sid            string
	eid            *string
	ignoreThrottle bool
}

func newFakePusher(results ...push.Result) *fakePusher {
	return &fakePusher{enabled: true, results: results, done: make(chan struct{})}
}

func (f *fakePusher) Enabled() bool { return f.enabled }

func (f *fakePusher) SendMany(_ context.Context, targets []push.Target, kind, sid string,
	eid *string, ignoreThrottle bool) []push.Result {
	if f.block != nil {
		<-f.block
	}
	copied := make([]push.Target, len(targets))
	copy(copied, targets)
	call := pushCall{targets: copied, kind: kind, sid: sid, eid: eid,
		ignoreThrottle: ignoreThrottle}
	f.mu.Lock()
	f.calls = append(f.calls, call)
	results := f.results
	resultFor := f.resultFor
	f.mu.Unlock()
	select {
	case <-f.done:
	default:
		close(f.done)
	}
	if resultFor != nil {
		out := make([]push.Result, len(targets))
		for index, target := range targets {
			out[index] = resultFor(target)
		}
		return out
	}
	if len(results) > 0 {
		out := make([]push.Result, len(targets))
		for index := range out {
			if index < len(results) {
				out[index] = results[index]
			}
		}
		return out
	}
	out := make([]push.Result, len(targets))
	for index := range out {
		ok := true
		out[index] = push.Result{OK: ok}
	}
	return out
}

func (f *fakePusher) wait(t *testing.T) pushCall {
	t.Helper()
	select {
	case <-f.done:
	case <-time.After(3 * time.Second):
		t.Fatal("等待推送超时")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.calls) == 0 {
		t.Fatal("没有记录到推送调用")
	}
	return f.calls[len(f.calls)-1]
}

func (f *fakePusher) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

// callsCopy 返回迄今全部推送调用的副本（按发生顺序）。
func (f *fakePusher) callsCopy() []pushCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]pushCall(nil), f.calls...)
}

// setResults 替换后续 SendMany 的预设结果（第二次推送要看清理结果的用例用）。
func (f *fakePusher) setResults(results ...push.Result) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.results = results
	f.resultFor = nil
}

// setResultFor 让结果按设备决定（同一次扇出里模拟部分设备死令牌）。
func (f *fakePusher) setResultFor(resultFor func(push.Target) push.Result) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.resultFor = resultFor
}

// fakeReporter 记录 agent 断开事件。
type fakeReporter struct {
	mu    sync.Mutex
	calls []disconnectCall
}

type disconnectCall struct {
	agentID string
	name    string
}

func (r *fakeReporter) NoteAgentDisconnect(agentID, name string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, disconnectCall{agentID: agentID, name: name})
}

// NoteControlDrop 是 IncidentReporter 的第二条方法；推送用例不关心控制帧丢弃。
func (r *fakeReporter) NoteControlDrop(link, frameType string) {}

// NoteStreamDrop 是 IncidentReporter 的第三条方法；推送用例不关心流式帧丢弃。
func (r *fakeReporter) NoteStreamDrop(link string, dropped int64) {}

func (r *fakeReporter) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.calls)
}

func registerPush(t *testing.T, f *fixture, deviceID string, turnEnd, attention bool) {
	t.Helper()
	registerPushWith(t, f, deviceID, strings.Repeat("ab", 32), "sandbox", turnEnd, attention)
}

// registerPushWith 用指定令牌与环境登记，多设备用例据此区分目标。
func registerPushWith(t *testing.T, f *fixture, deviceID, token, env string,
	turnEnd, attention bool) {
	t.Helper()
	if err := f.store.SetPush(context.Background(), deviceID, &token, &env,
		turnEnd, attention); err != nil {
		t.Fatalf("SetPush: %v", err)
	}
}

func notifyWire(t *testing.T, frame dlp.Frame) dlp.Wire {
	t.Helper()
	frame["t"] = "notify"
	return wireOf(t, frame)
}

func TestAnOfflineDeviceIsPushedOnceWithTheRightArguments(t *testing.T) {
	sender := newFakePusher()
	f := newFixture(t, Options{Push: sender})
	owner := f.newTenant("pusher")
	device := f.pairDevice(owner, "iPhone")
	registerPush(t, f, device.DeviceID, true, true)
	agentLink, _ := f.attachAgent(owner)

	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-1",
	}))
	call := sender.wait(t)
	if call.kind != "turnEnd" || call.sid != "s-1" || call.eid != nil {
		t.Fatalf("调用 = %+v", call)
	}
	if len(call.targets) != 1 || call.targets[0].DeviceID != device.DeviceID {
		t.Fatalf("targets = %+v", call.targets)
	}
	if call.targets[0].Token != strings.Repeat("ab", 32) ||
		call.targets[0].Env == nil || *call.targets[0].Env != "sandbox" {
		t.Fatalf("target = %+v", call.targets[0])
	}
	if call.ignoreThrottle {
		t.Fatal("路由触发的推送不该忽略限速")
	}
}

func TestAConnectedDeviceIsNotPushed(t *testing.T) {
	sender := newFakePusher()
	f := newFixture(t, Options{Push: sender})
	owner := f.newTenant("pusher")
	device := f.pairDevice(owner, "iPhone")
	registerPush(t, f, device.DeviceID, true, true)
	agentLink, _ := f.attachAgent(owner)
	f.mustAttachDevice(device)

	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-1",
	}))
	// 在线的设备只收自己的本地通知；这里给它一个"否定"的观察窗口。
	time.Sleep(120 * time.Millisecond)
	if count := sender.callCount(); count != 0 {
		t.Fatalf("在线的设备不该被推送（%d 次）", count)
	}
}

func TestTheSwitchForThatKindTurnsThePushOff(t *testing.T) {
	sender := newFakePusher()
	f := newFixture(t, Options{Push: sender})
	owner := f.newTenant("pusher")
	device := f.pairDevice(owner, "iPhone")
	// 用户只想被通知"跑完了"，不想被通知"有待确认"。
	registerPush(t, f, device.DeviceID, true, false)
	agentLink, _ := f.attachAgent(owner)

	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "attention", "sid": "s-1", "eid": "e-1",
	}))
	time.Sleep(120 * time.Millisecond)
	if count := sender.callCount(); count != 0 {
		t.Fatalf("attention 开关关着，却推送了 %d 次", count)
	}

	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-1",
	}))
	call := sender.wait(t)
	if call.kind != "turnEnd" {
		t.Fatalf("kind = %q", call.kind)
	}
}

func TestADeviceWithoutRegistrationIsNotPushed(t *testing.T) {
	sender := newFakePusher()
	f := newFixture(t, Options{Push: sender})
	owner := f.newTenant("pusher")
	f.pairDevice(owner, "iPhone")
	agentLink, _ := f.attachAgent(owner)

	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-1",
	}))
	time.Sleep(120 * time.Millisecond)
	if count := sender.callCount(); count != 0 {
		t.Fatalf("没有推送登记却推了 %d 次", count)
	}
}

func TestARevokedDeviceIsNotPushed(t *testing.T) {
	sender := newFakePusher()
	f := newFixture(t, Options{Push: sender})
	owner := f.newTenant("pusher")
	device := f.pairDevice(owner, "iPhone")
	registerPush(t, f, device.DeviceID, true, true)
	if err := f.store.RevokeDevice(context.Background(), device.DeviceID); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}
	agentLink, _ := f.attachAgent(owner)

	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-1",
	}))
	time.Sleep(120 * time.Millisecond)
	if count := sender.callCount(); count != 0 {
		t.Fatalf("已撤销的设备不该被推送（%d 次）", count)
	}
}

func TestADeadTokenIsClearedByTheRelay(t *testing.T) {
	reason := "Unregistered"
	sender := newFakePusher(push.Result{OK: false, DeadToken: true, Reason: &reason})
	f := newFixture(t, Options{Push: sender})
	owner := f.newTenant("pusher")
	device := f.pairDevice(owner, "iPhone")
	registerPush(t, f, device.DeviceID, true, true)
	agentLink, _ := f.attachAgent(owner)

	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-1",
	}))
	sender.wait(t)
	waitFor(t, "失效令牌的登记被清掉", func() bool {
		row, found, err := f.store.DeviceByID(context.Background(), device.DeviceID)
		if err != nil || !found {
			return false
		}
		return row.APNSToken == nil && row.APNSEnv == nil
	})
}

func TestAMalformedNotifyIsIgnored(t *testing.T) {
	sender := newFakePusher()
	f := newFixture(t, Options{Push: sender})
	owner := f.newTenant("pusher")
	device := f.pairDevice(owner, "iPhone")
	registerPush(t, f, device.DeviceID, true, true)
	agentLink, _ := f.attachAgent(owner)

	for _, frame := range []dlp.Frame{
		{"kind": "made-up", "sid": "s-1"},
		{"kind": "turnEnd"},
		{"kind": "turnEnd", "sid": ""},
		{"sid": "s-1"},
	} {
		f.hub.RouteFromAgent(agentLink, notifyWire(t, frame))
	}
	time.Sleep(120 * time.Millisecond)
	if count := sender.callCount(); count != 0 {
		t.Fatalf("坏 notify 不该推送（%d 次）", count)
	}
}

func TestPushDeliveryNeverBlocksTheAgentLink(t *testing.T) {
	sender := newFakePusher()
	sender.block = make(chan struct{})
	f := newFixture(t, Options{Push: sender})
	owner := f.newTenant("pusher")
	device := f.pairDevice(owner, "iPhone")
	registerPush(t, f, device.DeviceID, true, true)
	agentLink, _ := f.attachAgent(owner)

	started := time.Now()
	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-1",
	}))
	if elapsed := time.Since(started); elapsed > 300*time.Millisecond {
		close(sender.block)
		t.Fatalf("推送阻塞了 agent 链路 %v", elapsed)
	}
	close(sender.block)
	sender.wait(t)
}

func TestAnAgentDisconnectIsReportedToTheMonitor(t *testing.T) {
	reporter := &fakeReporter{}
	f := newFixture(t, Options{Monitor: reporter})
	owner := f.newTenant("flapper")
	agentLink, _ := f.attachAgent(owner)
	f.hub.DetachAgent(agentLink)
	if reporter.count() != 1 {
		t.Fatalf("断开上报次数 = %d", reporter.count())
	}
	reporter.mu.Lock()
	call := reporter.calls[0]
	reporter.mu.Unlock()
	if call.agentID != owner.agent.AgentID || call.name != owner.agent.Name {
		t.Fatalf("上报 = %+v", call)
	}
}

func TestASupersededAgentDoesNotReportADisconnect(t *testing.T) {
	reporter := &fakeReporter{}
	f := newFixture(t, Options{
		Monitor:  reporter,
		Presence: presence.Options{ActiveIdle: time.Millisecond},
	})
	owner := f.newTenant("flapper")
	first, _ := f.attachAgent(owner)
	time.Sleep(5 * time.Millisecond) // 旧连接过了僵死窗口
	second, _ := f.attachAgent(owner)

	f.hub.DetachAgent(first) // 旧连接收尾：被顶替不算断开
	if reporter.count() != 0 {
		t.Fatalf("被顶替的旧连接不该报断开：%d", reporter.count())
	}
	f.hub.DetachAgent(second)
	if reporter.count() != 1 {
		t.Fatalf("新连接断开应上报一次：%d", reporter.count())
	}
}

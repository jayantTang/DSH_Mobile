package hub

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
)

// TestDeviceFramesAreStampedWithTheDeviceID 钉住设备 → 电脑的寻址约定：
// 一条 agent socket 复用给多台设备，所以每一帧都必须带上 deviceId。
func TestDeviceFramesAreStampedWithTheDeviceID(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	_, agentSink := fixture.attachAgent(owner)
	link, deviceSink := fixture.mustAttachDevice(device)

	// 设备首帧是本机状态；电脑侧收到的是 deviceAttach。
	attach := waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	if attach.DeviceID() != device.DeviceID {
		t.Fatalf("deviceAttach 的 deviceId = %q", attach.DeviceID())
	}
	status := waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))
	info := status["info"].(map[string]any)
	if info["online"] != true || info["agentId"] != owner.agent.AgentID {
		t.Fatalf("hostStatus = %v", status)
	}

	fixture.hub.RouteFromDevice(link, scanWire(t, `{"t":"req","id":"r1","method":"session/list"}`))
	forwarded := waitFrame(t, agentSink, "转发的 req", isKind("req"))
	if forwarded.ID() != "r1" || forwarded.Method() != "session/list" {
		t.Fatalf("转发内容不对：%v", forwarded)
	}
	if forwarded.DeviceID() != device.DeviceID {
		t.Fatalf("转发帧没有盖上 deviceId：%v", forwarded)
	}
}

// TestAgentFramesAreAddressedBackToTheDevice 覆盖回程：带 deviceId 的帧送到那台设备，
// 并且中转内部键在到达手机前被摘掉。
func TestAgentFramesAreAddressedBackToTheDevice(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)

	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	fixture.hub.RouteFromAgent(agentLink, scanWire(t,
		`{"t":"res","id":"r1","ok":true,"deviceId":"`+device.DeviceID+`","value":{"sessions":[]}}`))
	reply := waitFrame(t, deviceSink, "回程 res", isKind("res"))
	if reply.ID() != "r1" {
		t.Fatalf("回程 res = %v", reply)
	}
	if _, leaked := reply["deviceId"]; leaked {
		t.Fatalf("deviceId 不该到达设备：%v", reply)
	}
	if value, ok := reply["value"].(map[string]any); !ok || value["sessions"] == nil {
		t.Fatalf("内容被改坏了：%v", reply)
	}
}

// TestFramesForForeignDevicesAreDropped 是"一枚设备令牌只能寻址自己电脑的设备"的
// 唯一执行点：另一台电脑的 deviceId 到这里必须查不到。
func TestFramesForForeignDevicesAreDropped(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	first := fixture.newTenant("M2-first")
	second := fixture.newTenant("M2-second")
	foreign := fixture.pairDevice(second, "M2-foreign")

	firstLink, firstAgentSink := fixture.attachAgent(first)
	_, firstDeviceSink := fixture.mustAttachDevice(fixture.pairDevice(first, "M2-first-phone"))
	waitFrame(t, firstAgentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, firstDeviceSink, "hostStatus", isKind("hostStatus"))

	fixture.hub.RouteFromAgent(firstLink, scanWire(t,
		`{"t":"res","id":"evil","deviceId":"`+foreign.DeviceID+`"}`))
	expectNoFrame(t, firstDeviceSink, "别人的设备", isKind("res"))
}

// TestUnknownFrameTypesAreForwardedVerbatim：DLP 的 `t` 向前兼容，未知类型必须原样
// 穿过（判成错误会让未来新增的帧在旧中转上直接失效）。
func TestUnknownFrameTypesAreForwardedVerbatim(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	_, agentSink := fixture.attachAgent(owner)
	link, _ := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))

	fixture.hub.RouteFromDevice(link, scanWire(t,
		`{"t":"futureFrame","id":"f1","extra":{"a":1}}`))
	forwarded := waitFrame(t, agentSink, "未知类型的帧", isKind("futureFrame"))
	extra, ok := forwarded["extra"].(map[string]any)
	if !ok || extra["a"] != json.Number("1") {
		t.Fatalf("未知帧的内容没原样穿过：%v", forwarded)
	}
	if forwarded.DeviceID() != device.DeviceID {
		t.Fatalf("未知帧也要盖 deviceId：%v", forwarded)
	}
}

// TestPingIsAnsweredLocally：DLP 的 ping 由中转自己回答，不跨到另一侧。
func TestPingIsAnsweredLocally(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	_, agentSink := fixture.attachAgent(owner)
	link, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	fixture.hub.RouteFromDevice(link, scanWire(t, `{"t":"ping","ts":41}`))
	pong := waitFrame(t, deviceSink, "pong", isKind("pong"))
	if pong["ts"] != json.Number("41") {
		t.Fatalf("pong = %v", pong)
	}
	// 没有跨到电脑：agent 侧只有 deviceAttach 这一条控制帧。
	expectNoFrame(t, agentSink, "电脑不该看到 ping", isKind("ping"))
}

// TestAgentPingIsAnsweredLocally 是设备侧 ping 用例的回程补位。
//
// 两个方向的 ping 现在共用 routePing：只测设备侧会让"连接器发来的 ping 也回
// pong"这条分支失去覆盖，所以在这里单独钉一次，且断言它不跨到设备。
func TestAgentPingIsAnsweredLocally(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	fixture.hub.RouteFromAgent(agentLink, scanWire(t, `{"t":"ping","ts":42}`))
	pong := waitFrame(t, agentSink, "pong", isKind("pong"))
	if pong["ts"] != json.Number("42") {
		t.Fatalf("pong = %v", pong)
	}
	expectNoFrame(t, deviceSink, "设备不该看到 ping", isKind("ping"))
}

// TestDeviceWithoutTheConnectorIsToldTheHostIsOffline 覆盖"电脑不在线"：
// 设备照样能连，只是首帧是 online=false，发帧会得到 host/offline 错误帧。
func TestDeviceWithoutTheConnectorIsToldTheHostIsOffline(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	link, deviceSink := fixture.mustAttachDevice(device)

	status := waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))
	if status["info"].(map[string]any)["online"] != false {
		t.Fatalf("电脑不在线时首帧应为 online=false：%v", status)
	}
	fixture.hub.RouteFromDevice(link, scanWire(t, `{"t":"req","id":"r1","method":"x"}`))
	offline := waitFrame(t, deviceSink, "host/offline", func(frame dlp.Frame) bool {
		return frame.Type() == "error" && frame["code"] == "host/offline"
	})
	if fatal, _ := offline["fatal"].(bool); fatal {
		t.Fatalf("host/offline 不是致命错误：%v", offline)
	}
}

// TestHelloWithTheWrongAgentIsFatal：hello 指名了另一台电脑 → 致命错误 + 断开。
func TestHelloWithTheWrongAgentIsFatal(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	link, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	fixture.hub.RouteFromDevice(link, scanWire(t, `{"t":"hello","agentId":"agt_somebody-else"}`))
	refusal := waitFrame(t, deviceSink, "auth/agent-mismatch", func(frame dlp.Frame) bool {
		return frame.Type() == "error"
	})
	if refusal["code"] != "auth/agent-mismatch" || refusal["fatal"] != true {
		t.Fatalf("hello 拒绝帧 = %v", refusal)
	}
	waitFor(t, "socket 被关闭", func() bool { return closeStatus(deviceSink) == dlp.CloseGoingAway })
}

// TestAgentReconnectReAdoptsLiveDevices：电脑重连不关闭设备，新连接要把它们认回来。
func TestAgentReconnectReAdoptsLiveDevices(t *testing.T) {
	// 顶替只发生在旧连接僵死时：把窗口调到毫秒级，并在两次连接之间让它空闲过界。
	fixture := newFixture(t, Options{
		Limits:   DefaultLimits(),
		Presence: presence.Options{ActiveIdle: time.Millisecond},
	})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	firstAgent, firstSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, firstSink, "deviceAttach", isKind("deviceAttach"))
	time.Sleep(5 * time.Millisecond)

	secondAgent, secondSink := fixture.attachAgent(owner)
	attach := waitFrame(t, secondSink, "重连后的 deviceAttach", isKind("deviceAttach"))
	if attach.DeviceID() != device.DeviceID {
		t.Fatalf("重连后没有认回设备：%v", attach)
	}
	// 旧连接必须被关掉（4001），否则两台电脑会同时往同一批设备写。
	waitFor(t, "旧 agent 被顶替", func() bool {
		status := closeStatus(firstSink)
		return status == dlp.CloseSuperseded
	})
	// 设备会再收到一次 online=true（新的连接信息）。
	waitFrame(t, deviceSink, "重新上线", func(frame dlp.Frame) bool {
		info, ok := frame["info"].(map[string]any)
		return frame.Type() == "hostStatus" && ok && info["online"] == true
	})
	if fixture.hub.Agent(owner.agent.AgentID) != secondAgent {
		t.Fatal("注册表里应是新连接")
	}
	fixture.hub.DetachAgent(firstAgent) // 旧连接迟到的拆除不能摘掉新连接
	if fixture.hub.Agent(owner.agent.AgentID) != secondAgent {
		t.Fatal("旧连接的拆除摘掉了新连接")
	}
}

// TestDetachingTheAgentLeavesDevicesOnline：电脑掉线时设备不关闭，只被告知 offline。
func TestDetachingTheAgentLeavesDevicesOnline(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	fixture.hub.DetachAgent(agentLink)
	offline := waitFrame(t, deviceSink, "offline 通知", func(frame dlp.Frame) bool {
		info, ok := frame["info"].(map[string]any)
		return frame.Type() == "hostStatus" && ok && info["online"] == false
	})
	if offline["info"].(map[string]any)["agentId"] != owner.agent.AgentID {
		t.Fatalf("offline 帧 = %v", offline)
	}
	if closeStatus(deviceSink) != 0 {
		t.Fatal("电脑掉线不该关闭设备 socket")
	}
}

// TestDeviceDetachCarriesTheReason：设备断开时电脑必须收到 deviceDetach + reason，
// 那是连接器释放设备记录（$events 值班流）的唯一信号。
func TestDeviceDetachCarriesTheReason(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	_, agentSink := fixture.attachAgent(owner)
	link, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	fixture.hub.DetachDevice(link)
	detach := waitFrame(t, agentSink, "deviceDetach", isKind("deviceDetach"))
	if detach["reason"] != "socket closed" {
		t.Fatalf("detach 原因 = %v", detach["reason"])
	}
	waitFor(t, "设备 socket 关闭", func() bool { return closeStatus(deviceSink) == dlp.CloseGoingAway })
	if fixture.hub.Device(device.DeviceID) != nil {
		t.Fatal("注册表里还留着已经断开的设备")
	}
}

// TestTheDeviceLimitIsRefusedAnd4012：满额时 AttachDevice 什么都不登记（可回滚），
// 重连自己的设备不算新名额。
func TestTheDeviceLimitIsRefusedAnd4012(t *testing.T) {
	limits := DefaultLimits()
	limits.MaxDevicesPerAgent = 1
	fixture := newFixture(t, Options{Limits: limits})
	owner := fixture.newTenant("M2-mac")
	first := fixture.pairDevice(owner, "M2-first")
	second := fixture.pairDevice(owner, "M2-second")
	fixture.attachAgent(owner)
	firstLink, _ := fixture.mustAttachDevice(first)

	if !fixture.hub.DeviceBudgetExceeded(owner.agent.AgentID, second.DeviceID) {
		t.Fatal("第二台设备应当被判超额")
	}
	if _, _, err := fixture.attachDevice(second); err != ErrDeviceLimit {
		t.Fatalf("AttachDevice(second) = %v，期望 ErrDeviceLimit", err)
	}
	if fixture.hub.Device(second.DeviceID) != nil {
		t.Fatal("被拒绝的设备不该留在注册表里")
	}

	// 同一台设备重连：不能算成新名额（否则手机会把自己锁在门外）。
	reconnect, _, err := fixture.attachDevice(first)
	if err != nil {
		t.Fatalf("同一台设备重连被拒：%v", err)
	}
	if fixture.hub.DeviceBudgetExceeded(owner.agent.AgentID, first.DeviceID) {
		t.Fatal("自己的设备不该计入名额")
	}
	_ = reconnect
	_ = firstLink
}

// TestReplacingADeviceSocketDoesNotNotifyTwice：同一 deviceId 再开一条时，旧 socket
// 关闭**不再**发 deviceDetach（连接器那边设备并没走），新 socket 关闭才发一次。
func TestReplacingADeviceSocketDoesNotNotifyTwice(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	_, agentSink := fixture.attachAgent(owner)
	oldLink, _ := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "第一条 deviceAttach", isKind("deviceAttach"))

	newLink, newSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "第二条 deviceAttach", isKind("deviceAttach"))

	fixture.hub.DetachDevice(oldLink)
	expectNoFrame(t, agentSink, "旧 socket 不该产生 deviceDetach", isKind("deviceDetach"))
	if fixture.hub.Device(device.DeviceID) != newLink {
		t.Fatal("新连接被旧连接的拆除摘掉了")
	}

	fixture.hub.DetachDevice(newLink)
	detach := waitFrame(t, agentSink, "新 socket 的 deviceDetach", isKind("deviceDetach"))
	if detach.DeviceID() != device.DeviceID {
		t.Fatalf("detach = %v", detach)
	}
	waitFor(t, "新 socket 关闭", func() bool { return closeStatus(newSink) == dlp.CloseGoingAway })
}

// TestStreamFramesAreDroppedUnderBackpressure 与
// TestControlFramesNeverDisappearSilently 合起来钉住 DESIGN §5.1 的背压口径。
func TestStreamFramesAreDroppedUnderBackpressure(t *testing.T) {
	limits := DefaultLimits()
	limits.QueueDepth = 1
	fixture := newFixture(t, Options{Limits: limits})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	release := deviceSink.setBlocking()
	defer release()
	// 第一帧被写循环拿住，第二帧占满队列，第三帧开始只能丢。
	for index := 0; index < 4; index++ {
		fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
			"t": "res", "id": fmt.Sprintf("r%d", index), "deviceId": device.DeviceID,
		}))
	}
	waitFor(t, "流式帧被丢弃并计数", func() bool {
		return fixture.hub.Device(device.DeviceID) != nil &&
			fixture.deviceDropped(device.DeviceID) > 0
	})
	if closeStatus(deviceSink) != 0 {
		t.Fatalf("流式帧丢弃不该断开连接，实际关闭码 %d", closeStatus(deviceSink))
	}
}

// deviceDropped 读一台设备的丢帧计数（连接断掉后仍可从注册表外拿不到，先用快照）。
func (f *fixture) deviceDropped(deviceID string) int64 {
	for _, row := range f.hub.Traffic().Devices {
		if row.DeviceID == deviceID {
			return row.DroppedFrames
		}
	}
	return 0
}

// TestControlFramesNeverDisappearSilently：控制帧走独立的优先队列之后，
//   - 可丢控制帧（accountState 等）在优先队列满时被丢弃并计数，连接继续；
//   - 必达控制帧（error/deviceAttach/fs*）等不到槽位才按 4008 断开。
//
// 流式大队列塞满不再能挤掉控制帧——那正是 2026-10-23 故障的形态。
func TestControlFramesNeverDisappearSilently(t *testing.T) {
	limits := DefaultLimits()
	limits.QueueDepth = 1
	fixture := newFixture(t, Options{Limits: limits, ControlWait: 50 * time.Millisecond})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	release := deviceSink.setBlocking()
	defer release()
	link := fixture.hub.Device(device.DeviceID)
	// 写循环拿住一条，大队列里再塞满一条，下一条流式帧就没地方去了。
	for index := 0; index < 3; index++ {
		link.Enqueue([]byte(`{"t":"item","id":"x"}`), ClassStream, nil)
	}
	// 优先队列还是空的：可丢帧先占满 64 槽，再来的那一条被丢弃。
	for index := 0; index < DefaultControlQueueDepth; index++ {
		fixture.hub.SendControl(link,
			dlp.AccountStateFrame([]string{fmt.Sprintf("k%d", index)}))
	}
	fixture.hub.SendControl(link, dlp.AccountStateFrame([]string{"one-too-many"}))
	if drops := fixture.hub.ControlDrops(); drops != 1 {
		t.Fatalf("controlDrops = %d，期望 1", drops)
	}
	if closeStatus(deviceSink) != 0 {
		t.Fatalf("可丢控制帧被丢弃不该断开连接，实际关闭码 %d", closeStatus(deviceSink))
	}
	// 必达控制帧等满 ControlWait 仍没有槽位：4008 断开，而不是继续丢。
	fixture.hub.SendControl(link, dlp.ErrorFrame("test/required", "must arrive", false, nil))
	waitFor(t, "慢连接按 4008 断开", func() bool {
		return closeStatus(deviceSink) == dlp.CloseBackpressure
	})
}

// TestDailyQuotaAnswersErrorThenCloses4011 是 test_contract_limits 的内部对应：
// 超限先给一帧带 limitBytes 的 error，再以 4011 关闭，并通知电脑 daily quota。
func TestDailyQuotaAnswersErrorThenCloses4011(t *testing.T) {
	limits := DefaultLimits()
	limits.DeviceDailyBytes = 100
	fixture := newFixture(t, Options{Limits: limits})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	big := make([]byte, 200)
	for index := range big {
		big[index] = 'x'
	}
	frame := dlp.Frame{
		"t": "res", "id": "big", "deviceId": device.DeviceID,
		"value": map[string]any{"text": string(big)},
	}
	fixture.hub.RouteFromAgent(agentLink, wireOf(t, frame))

	errorFrame := waitFrame(t, deviceSink, "配额错误帧", func(candidate dlp.Frame) bool {
		return candidate.Type() == "error"
	})
	if errorFrame["code"] != "quota/device-daily" {
		t.Fatalf("错误帧 = %v", errorFrame)
	}
	details := errorFrame["details"].(map[string]any)
	if details["limitBytes"] != json.Number("100") {
		t.Fatalf("details = %v", details)
	}
	if fatal, _ := errorFrame["fatal"].(bool); fatal {
		t.Fatal("配额不是致命协议错误")
	}
	waitFor(t, "以 4011 关闭", func() bool { return closeStatus(deviceSink) == dlp.CloseQuotaExceeded })
	detach := waitFrame(t, agentSink, "配额断开通知", isKind("deviceDetach"))
	if detach["reason"] != "daily quota" {
		t.Fatalf("detach 原因 = %v", detach["reason"])
	}
	// 超限的那一帧本身不该送到手机。
	expectNoFrame(t, deviceSink, "超限帧", func(candidate dlp.Frame) bool {
		return candidate.Type() == "res"
	})
}

// TestTheDailyQuotaSurvivesAReconnect：额度按设备记，重连不清零。
func TestTheDailyQuotaSurvivesAReconnect(t *testing.T) {
	limits := DefaultLimits()
	limits.DeviceDailyBytes = 100
	fixture := newFixture(t, Options{Limits: limits})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	agentLink, _ := fixture.attachAgent(owner)
	firstLink, firstSink := fixture.mustAttachDevice(device)
	waitFrame(t, firstSink, "hostStatus", isKind("hostStatus"))

	// 60 字节（含 JSON 开销）记在第一次连接上。
	payload := make([]byte, 40)
	for index := range payload {
		payload[index] = 'a'
	}
	fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
		"t": "res", "id": "one", "deviceId": device.DeviceID,
		"value": map[string]any{"text": string(payload)},
	}))
	waitFrame(t, firstSink, "第一帧", isKind("res"))
	fixture.hub.DetachDevice(firstLink)

	// 重连后再收一帧同样大的：合计超过 100 就该被拒。
	_, secondSink := fixture.mustAttachDevice(device)
	fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
		"t": "res", "id": "two", "deviceId": device.DeviceID,
		"value": map[string]any{"text": string(payload)},
	}))
	waitFor(t, "重连后额度仍然算数", func() bool {
		return closeStatus(secondSink) == dlp.CloseQuotaExceeded
	})
}

// TestTheQuotaIsPerDeviceNotPerAccount：一台用光不影响另一台。
func TestTheQuotaIsPerDeviceNotPerAccount(t *testing.T) {
	limits := DefaultLimits()
	limits.DeviceDailyBytes = 100
	fixture := newFixture(t, Options{Limits: limits})
	owner := fixture.newTenant("M2-mac")
	greedy := fixture.pairDevice(owner, "M2-greedy")
	frugal := fixture.pairDevice(owner, "M2-frugal")
	agentLink, _ := fixture.attachAgent(owner)
	_, greedySink := fixture.mustAttachDevice(greedy)
	_, frugalSink := fixture.mustAttachDevice(frugal)
	waitFrame(t, greedySink, "hostStatus", isKind("hostStatus"))
	waitFrame(t, frugalSink, "hostStatus", isKind("hostStatus"))

	big := make([]byte, 200)
	fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
		"t": "res", "id": "greedy", "deviceId": greedy.DeviceID,
		"value": map[string]any{"text": string(big)},
	}))
	waitFor(t, "贪心设备被限额", func() bool {
		return closeStatus(greedySink) == dlp.CloseQuotaExceeded
	})

	fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
		"t": "res", "id": "frugal-fine", "deviceId": frugal.DeviceID,
		"value": map[string]any{"text": "ok"},
	}))
	fine := waitFrame(t, frugalSink, "另一台设备", isKind("res"))
	if fine.ID() != "frugal-fine" {
		t.Fatalf("另一台设备的帧 = %v", fine)
	}
}

// TestTheWebSocketEgressLandsInTodaysUsage：写循环真正送出的字节要进当天账本。
//
// 这是 DeviceLink 用 *quota.Usage 取代 *Hub 反向指针后的关键接线：/stats 的 today
// 与运维命令读的是同一份内存账本，WebSocket 与 /files/down 两条出口都不能漏记。
func TestTheWebSocketEgressLandsInTodaysUsage(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	before, err := fixture.hub.Today(context.Background())
	if err != nil {
		t.Fatalf("Today: %v", err)
	}
	fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
		"t": "res", "id": "usage", "deviceId": device.DeviceID,
		"value": map[string]any{"text": "egress"},
	}))
	waitFrame(t, deviceSink, "res", isKind("res"))

	after, err := fixture.hub.Today(context.Background())
	if err != nil {
		t.Fatalf("Today: %v", err)
	}
	if delta := after.TotalEgressBytes - before.TotalEgressBytes; delta <= 0 {
		t.Fatalf("写出去的帧没有进当天账本：%d", delta)
	}
	found := false
	for _, row := range after.Devices {
		if row.DeviceID == device.DeviceID && row.EgressBytes > 0 {
			found = true
		}
	}
	if !found {
		t.Fatalf("today.devices 缺少设备行：%+v", after.Devices)
	}
}

// TestAccountStateNotificationsSkipTheWriter：尽力而为的通知，排除写入者。
func TestAccountStateNotificationsSkipTheWriter(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	writer := fixture.pairDevice(owner, "M2-writer")
	listener := fixture.pairDevice(owner, "M2-listener")
	_, writerSink := fixture.mustAttachDevice(writer)
	_, listenerSink := fixture.mustAttachDevice(listener)
	waitFrame(t, writerSink, "hostStatus", isKind("hostStatus"))
	waitFrame(t, listenerSink, "hostStatus", isKind("hostStatus"))

	sent := fixture.hub.NotifyAccountState(owner.account.AccountID, []string{"alertPrefs"}, writer.DeviceID)
	if sent != 1 {
		t.Fatalf("notify 送达数 = %d，期望 1", sent)
	}
	notification := waitFrame(t, listenerSink, "accountState", isKind("accountState"))
	keys, ok := notification["keys"].([]any)
	if !ok || len(keys) != 1 || keys[0] != "alertPrefs" {
		t.Fatalf("accountState = %v", notification)
	}
	expectNoFrame(t, writerSink, "写入者不该收到通知", isKind("accountState"))
}

// TestHeartbeatClosesADeadConnection：连接器链路用 DLP ping 做心跳，ping 发出后
// 在 heartbeatTimeout 内没有任何回音即断开（DESIGN §5.3）。
//
// 这里刻意断言 sink.pings == 0：agent 链路不再用 WS 控制帧 ping，更不允许写循环
// 同步等 pong（2026-10-23 生产回滚的根因）。
func TestHeartbeatClosesADeadConnection(t *testing.T) {
	limits := DefaultLimits()
	fixture := newFixture(t, Options{
		Limits:           limits,
		Heartbeat:        10 * time.Millisecond,
		HeartbeatTimeout: 20 * time.Millisecond,
	})
	owner := fixture.newTenant("M2-mac")
	sink := newFakeSink()
	link := fixture.attachAgentWithSink(owner, sink)

	waitFor(t, "心跳超时后关闭", func() bool { return closeStatus(sink) == dlp.CloseGoingAway })
	select {
	case <-link.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("写循环没有退出")
	}
	// 先等到第一条 ping 被写出去：它证明心跳确实走了 DLP 控制帧。
	waitFrame(t, sink, "DLP ping", isKind("ping"))
	if sink.pingCount() != 0 {
		t.Fatalf("agent 链路不该再用 WS ping，实际 %d 次", sink.pingCount())
	}
}

// TestAgentLinkStaysUpWhilePongsArrive：pong 是 DLP 心跳的活性证据；读循环每收到
// 一帧 pong 就清掉截止时间，链路应当一直保持。
func TestAgentLinkStaysUpWhilePongsArrive(t *testing.T) {
	fixture := newFixture(t, Options{
		Limits:           DefaultLimits(),
		Heartbeat:        10 * time.Millisecond,
		HeartbeatTimeout: 20 * time.Millisecond,
	})
	owner := fixture.newTenant("M2-mac")
	sink := newFakeSink()
	link := fixture.attachAgentWithSink(owner, sink)
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(5 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				// 走真实读循环入口（RouteFromAgent），不直接改内部状态。
				fixture.hub.RouteFromAgent(link, scanWire(t, `{"t":"pong","ts":1}`))
			}
		}
	}()
	time.Sleep(150 * time.Millisecond)
	close(stop)
	<-done
	if status := closeStatus(sink); status != 0 {
		t.Fatalf("持续收到 pong 时不该断开，关闭码 %d", status)
	}
	// 停止喂 pong 之后必须能正常判死，证明上面的"没断"不是 watchdog 根本没跑。
	waitFor(t, "停止 pong 后断开", func() bool { return closeStatus(sink) != 0 })
}

// TestStatsLoadTrafficAndSnapshot：/stats 的三段都从注册表实时取数。
func TestStatsLoadTrafficAndSnapshot(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M2-mac")
	device := fixture.pairDevice(owner, "M2-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))
	fixture.hub.RouteFromAgent(agentLink, scanWire(t,
		`{"t":"res","id":"r1","deviceId":"`+device.DeviceID+`","value":{"text":"hello"}}`))
	waitFrame(t, deviceSink, "res", isKind("res"))

	agents, devices := fixture.hub.Load()
	if agents != 1 || devices != 1 {
		t.Fatalf("load = %d/%d，期望 1/1", agents, devices)
	}
	traffic := fixture.hub.Traffic()
	if len(traffic.Devices) != 1 || traffic.Devices[0].DeviceID != device.DeviceID {
		t.Fatalf("traffic = %+v", traffic)
	}
	if traffic.TotalEgressBytes <= 0 || traffic.Devices[0].EgressBytes <= 0 {
		t.Fatalf("出口字节没有记账：%+v", traffic)
	}
	if traffic.Devices[0].QuotaRemainingBytes != -1 {
		t.Fatalf("不限量时应为 -1：%d", traffic.Devices[0].QuotaRemainingBytes)
	}
	snapshot := fixture.hub.Snapshot()
	if len(snapshot.Agents) != 1 || len(snapshot.Devices) != 1 {
		t.Fatalf("snapshot = %+v", snapshot)
	}
	if !snapshot.Devices[0].HostOnline {
		t.Fatal("电脑在线时 hostOnline 应为 true")
	}
	if snapshot.Agents[0].Devices[0] != device.DeviceID {
		t.Fatalf("snapshot.agents = %+v", snapshot.Agents[0])
	}
}

// TestQueueByteLimitStopsSmallFrameBuildup 钉住 M2.5 新增的字节限额：
// 深度只约束帧数，小帧堆积仍然要按字节拦（否则几百个 32 MiB 级的帧能撑爆进程）。
func TestQueueByteLimitStopsSmallFrameBuildup(t *testing.T) {
	limits := DefaultLimits()
	limits.QueueDepth = 512
	limits.QueueBytes = 1024
	fixture := newFixture(t, Options{Limits: limits})
	owner := fixture.newTenant("M25-mac")
	device := fixture.pairDevice(owner, "M25-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	release := deviceSink.setBlocking()
	defer release()
	// 每条 400 字节：第一帧被写循环拿走，第二帧入队，第三帧起超过 1024 的字节上限。
	payload := strings.Repeat("x", 360)
	for index := 0; index < 6; index++ {
		fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
			"t": "res", "id": fmt.Sprintf("r%d", index), "deviceId": device.DeviceID,
			"value": map[string]any{"text": payload},
		}))
	}
	waitFor(t, "超过字节上限的流式帧被丢弃", func() bool {
		return fixture.deviceDropped(device.DeviceID) >= 2
	})
	if closeStatus(deviceSink) != 0 {
		t.Fatalf("字节背压不该断开连接，实际关闭码 %d", closeStatus(deviceSink))
	}
	if queued := fixture.hub.Device(device.DeviceID).QueuedBytes(); queued > 1024 {
		t.Fatalf("队列字节 = %d，超过限额 1024", queued)
	}
}

// TestQueueByteLimitAlwaysAdmitsOversizedFrame：比限额还大的单帧必须放行，
// 否则一张 32 MiB 的图片会被自己的体积挡在门外（协议行为变化）。
func TestQueueByteLimitAlwaysAdmitsOversizedFrame(t *testing.T) {
	limits := DefaultLimits()
	limits.QueueBytes = 1024
	fixture := newFixture(t, Options{Limits: limits})
	owner := fixture.newTenant("M25-mac")
	device := fixture.pairDevice(owner, "M25-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	_, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	big := strings.Repeat("y", 4096)
	fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
		"t": "res", "id": "big", "deviceId": device.DeviceID,
		"value": map[string]any{"text": big},
	}))
	reply := waitFrame(t, deviceSink, "超过限额的单帧", func(frame dlp.Frame) bool {
		return frame.Type() == "res" && frame.ID() == "big"
	})
	value, _ := reply["value"].(map[string]any)
	if value == nil || value["text"] != big {
		t.Fatalf("大帧内容不完整：%v 字节", len(fmt.Sprint(reply["value"])))
	}
}

// bufferedWire 造一条"带池化缓冲"的帧，用来验证所有权（归还）路径。
func bufferedWire(t *testing.T, pool *dlp.BufferPool, raw string) dlp.Wire {
	t.Helper()
	buffer := pool.Get()
	buffer.SetBytes(append(buffer.Bytes()[:0], raw...))
	buffer.Headroom()
	wire, _, err := dlp.Scan(buffer.Bytes())
	if err != nil {
		t.Fatalf("Scan(%s): %v", raw, err)
	}
	return wire.WithBuffer(buffer)
}

// TestDroppedFramesReturnTheirBuffers 是缓冲所有权的回归：每一条丢弃路径都必须把
// 读缓冲还给池子，否则转发层会退化成"每帧新建 512 B"。
func TestDroppedFramesReturnTheirBuffers(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M25-mac")
	device := fixture.pairDevice(owner, "M25-iPhone")
	// 只挂设备、不挂电脑：每一帧都会走 host/offline 的丢弃路径。
	link, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	pool := dlp.NewBufferPool()
	for index := 0; index < 5; index++ {
		fixture.hub.RouteFromDevice(link, bufferedWire(t, pool,
			`{"t":"req","id":"r`+fmt.Sprint(index)+`","method":"session/list"}`))
		waitFrame(t, deviceSink, "host/offline 错误帧", func(frame dlp.Frame) bool {
			return frame.Type() == "error"
		})
	}
	if outstanding := pool.Outstanding(); outstanding != 0 {
		t.Fatalf("丢弃路径上有 %d 个缓冲没有归还", outstanding)
	}
}

// TestForwardedFramesReturnTheirBuffers：成功转发的帧由写循环归还缓冲。
func TestForwardedFramesReturnTheirBuffers(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M25-mac")
	device := fixture.pairDevice(owner, "M25-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	link, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	pool := dlp.NewBufferPool()
	fixture.hub.RouteFromDevice(link, bufferedWire(t, pool,
		`{"t":"req","id":"up","method":"session/list"}`))
	waitFrame(t, agentSink, "转发的 req", isKind("req"))
	fixture.hub.RouteFromAgent(agentLink, bufferedWire(t, pool,
		`{"t":"res","id":"down","deviceId":"`+device.DeviceID+`"}`))
	waitFrame(t, deviceSink, "回程 res", isKind("res"))

	waitFor(t, "缓冲全部归还", func() bool { return pool.Outstanding() == 0 })
}

// TestClosingALinkReturnsQueuedBuffers 钉住关闭路径：连接收尾时队列里剩下的帧
// 必须把读缓冲还给池子，而不是留在队列里等 GC。
func TestClosingALinkReturnsQueuedBuffers(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("M25-mac")
	device := fixture.pairDevice(owner, "M25-iPhone")
	agentLink, agentSink := fixture.attachAgent(owner)
	link, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	release := deviceSink.setBlocking()
	defer release()
	pool := dlp.NewBufferPool()
	for index := 0; index < 4; index++ {
		fixture.hub.RouteFromAgent(agentLink, bufferedWire(t, pool,
			`{"t":"res","id":"r`+fmt.Sprint(index)+`","deviceId":"`+device.DeviceID+`"}`))
	}
	waitFor(t, "帧进入队列", func() bool { return link.Pending() >= 2 })

	fixture.hub.DetachDevice(link)
	release()
	waitFor(t, "写循环退出", func() bool {
		select {
		case <-link.Done():
			return true
		default:
			return false
		}
	})
	waitFor(t, "队列里的缓冲全部归还", func() bool { return pool.Outstanding() == 0 })
	if queued := link.QueuedBytes(); queued != 0 {
		t.Fatalf("关闭后队列字节 = %d，期望 0", queued)
	}
}

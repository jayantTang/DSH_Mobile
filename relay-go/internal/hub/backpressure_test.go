package hub

import (
	"fmt"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// TestSlowDeviceBackpressureMatrix 是慢客户端/背压的集成矩阵，覆盖 DESIGN §5.1
// 的四条口径在同一时刻的相互关系：
//
//  1. 流式帧（res/item）在队列满时丢弃并计数，连接继续用；
//  2. 可丢控制帧（accountState）在优先队列满时丢弃并计数，连接继续用；
//  3. 必达控制帧（deviceAttach 这类）等满 ControlWait 仍进不去，才按 4008 断开；
//  4. 同一台电脑下的另一台设备完全不受影响（不丢帧、不断线、继续收帧）。
//
// 现有单测分别钉住了 1/2/3（TestStreamFramesAreDroppedUnderBackpressure、
// TestLossyControlDropIsCountedAndDoesNotClose、TestControlFramesNeverDisappear
// Silently）；这个用例把它们放进同一条链路，并补上"邻居隔离"与 /stats 快照的
// 一致性——那才是 2026-10-23 慢客户端故障真正的运维判据。
//
// 桩 sink 而不是真 socket：阻塞写入是确定性的，慢客户端在真 TCP 上要填满内核缓冲
// 才可复现，时间不可控。
func TestSlowDeviceBackpressureMatrix(t *testing.T) {
	limits := DefaultLimits()
	limits.QueueDepth = 1
	fixture := newFixture(t, Options{
		Limits:      limits,
		ControlWait: 40 * time.Millisecond,
	})
	owner := fixture.newTenant("backpressure-mac")
	slow := fixture.pairDevice(owner, "backpressure-slow")
	fast := fixture.pairDevice(owner, "backpressure-fast")
	agentLink, agentSink := fixture.attachAgent(owner)
	slowLink, slowSink := fixture.mustAttachDevice(slow)
	_, fastSink := fixture.mustAttachDevice(fast)
	waitFrame(t, agentSink, "slow deviceAttach", func(frame dlp.Frame) bool {
		return frame.Type() == "deviceAttach" && frame.DeviceID() == slow.DeviceID
	})
	waitFrame(t, agentSink, "fast deviceAttach", func(frame dlp.Frame) bool {
		return frame.Type() == "deviceAttach" && frame.DeviceID() == fast.DeviceID
	})
	waitFrame(t, slowSink, "slow hostStatus", isKind("hostStatus"))
	waitFrame(t, fastSink, "fast hostStatus", isKind("hostStatus"))

	// 慢客户端：写循环卡在第一次 Write 里，后面所有入队都只能排队/丢弃。
	release := slowSink.setBlocking()
	defer release()

	// 1) 流式帧：写循环拿住一条、队列里再排一条，第三条起开始丢。
	for index := 0; index < 5; index++ {
		fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
			"t": "res", "id": fmt.Sprintf("slow-%d", index), "deviceId": slow.DeviceID,
		}))
	}
	waitFor(t, "慢设备流式帧被丢弃并计数", func() bool {
		return fixture.deviceDropped(slow.DeviceID) > 0
	})
	if closeStatus(slowSink) != 0 {
		t.Fatalf("流式帧丢弃不该断开慢设备，实际关闭码 %d", closeStatus(slowSink))
	}

	// 2) 可丢控制帧：优先队列 64 槽填满后再来一条 → 丢弃、计数、不断链。
	for index := 0; index < DefaultControlQueueDepth; index++ {
		fixture.hub.SendControl(slowLink,
			dlp.AccountStateFrame([]string{fmt.Sprintf("k%d", index)}))
	}
	fixture.hub.SendControl(slowLink, dlp.AccountStateFrame([]string{"overflow"}))
	if drops := fixture.hub.ControlDrops(); drops != 1 {
		t.Fatalf("进程级 controlDrops = %d，期望 1", drops)
	}
	if drops := slowLink.ControlDrops(); drops != 1 {
		t.Fatalf("连接级 controlDrops = %d，期望 1", drops)
	}
	if closeStatus(slowSink) != 0 {
		t.Fatalf("可丢控制帧被丢弃不该断开连接，实际关闭码 %d", closeStatus(slowSink))
	}

	// 3) 邻居隔离：慢设备卡住时，同一电脑下的另一台设备照常收发。
	fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
		"t": "res", "id": "fast-1", "deviceId": fast.DeviceID,
	}))
	fastFrame := waitFrame(t, fastSink, "快设备收到帧", func(frame dlp.Frame) bool {
		return frame.Type() == "res" && frame.ID() == "fast-1"
	})
	if fastFrame.DeviceID() != "" {
		t.Fatalf("发给设备的帧不该带内部 deviceId：%v", fastFrame)
	}
	if closeStatus(fastSink) != 0 {
		t.Fatalf("快设备被慢设备的背压牵连，关闭码 %d", closeStatus(fastSink))
	}

	// 4) 必达控制帧：优先队列满 → 有界等待 → 4008 断开。
	fixture.hub.SendControl(slowLink, dlp.DeviceAttachFrame("probe", "", "", ""))
	waitFor(t, "慢设备按 4008 断开", func() bool {
		return closeStatus(slowSink) == dlp.CloseBackpressure
	})
	// 生产里 socket 关闭后读循环退出，wsapi 调 DetachDevice；单测没有读循环，
	// 这里显式补上这一步，才能验证"电脑收到 deviceDetach"。
	fixture.hub.DetachDevice(slowLink)
	detach := waitFrame(t, agentSink, "电脑收到背压摘除通知", func(frame dlp.Frame) bool {
		return frame.Type() == "deviceDetach" && frame.DeviceID() == slow.DeviceID
	})
	// 原因来自"谁先拆这条连接"：本次是中转控制帧发不出去后 4008 关闭，随后
	// wsapi 的读循环退出并调 DetachDevice（reason=socket closed）。手机看到的是
	// 4008；电脑只需要知道设备不在了，reason 是诊断字段。
	switch reason := detach["reason"]; reason {
	case "socket closed", "backpressure":
	default:
		t.Fatalf("deviceDetach 原因 = %v，期望 socket closed 或 backpressure", reason)
	}
	waitFor(t, "慢设备已从注册表摘除", func() bool {
		return fixture.hub.Device(slow.DeviceID) == nil
	})

	// 断开之后：快设备仍在、还能收帧，丢帧计数只挂在慢设备上。
	fixture.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
		"t": "res", "id": "fast-2", "deviceId": fast.DeviceID,
	}))
	waitFrame(t, fastSink, "快设备在慢设备断开后继续收帧", func(frame dlp.Frame) bool {
		return frame.Type() == "res" && frame.ID() == "fast-2"
	})
	if agents, devices := fixture.hub.Load(); agents != 1 || devices != 1 {
		t.Fatalf("背压断开后 load = agents:%d devices:%d，期望 1/1", agents, devices)
	}
	traffic := fixture.hub.Traffic()
	var fastRow *TrafficDevice
	for index := range traffic.Devices {
		if traffic.Devices[index].DeviceID == fast.DeviceID {
			fastRow = &traffic.Devices[index]
		}
	}
	if fastRow == nil {
		t.Fatalf("traffic 里没有快设备：%+v", traffic.Devices)
	}
	if fastRow.DroppedFrames != 0 {
		t.Fatalf("快设备 droppedFrames = %d，期望 0", fastRow.DroppedFrames)
	}
	if fixture.hub.ControlDrops() != 1 {
		t.Fatalf("controlDrops 在断开过程中被重复计数：%d", fixture.hub.ControlDrops())
	}
}

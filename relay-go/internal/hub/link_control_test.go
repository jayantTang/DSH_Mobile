package hub

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// startTestLink 起一条只测 Link 的连接（不经过 hub 的注册表）。
func startTestLink(t *testing.T, sink *fakeSink, options linkOptions) *Link {
	t.Helper()
	return startTestLinkWithKind(t, sink, options, heartbeatWebSocket)
}

func startTestLinkWithKind(t *testing.T, sink *fakeSink, options linkOptions,
	kind heartbeatKind) *Link {
	t.Helper()
	options = options.withDefaults()
	link := newLink(sink, "agent test", 32, 1<<20, testLogger(t), options)
	link.heartbeatKind = kind
	ctx, cancel := context.WithCancel(context.Background())
	link.Start(ctx)
	t.Cleanup(func() {
		cancel()
		select {
		case <-link.Done():
		case <-time.After(2 * time.Second):
			t.Error("写循环没有退出")
		}
	})
	return link
}

// TestControlFramesOvertakeQueuedStreams 钉住"优先队列"的核心承诺：
// 大队列里排着一串流式帧时，后到的 pong 仍然紧跟着当前那帧写出去。
func TestControlFramesOvertakeQueuedStreams(t *testing.T) {
	sink := newFakeSink()
	link := startTestLink(t, sink, linkOptions{heartbeat: time.Hour})

	release := sink.setBlocking()
	defer release()
	link.Enqueue([]byte(`{"t":"item","id":"blocked"}`), ClassStream, nil)
	waitFor(t, "写循环拿住第一帧", func() bool { return link.Pending() == 0 })
	for index := 0; index < 20; index++ {
		link.Enqueue([]byte(`{"t":"item","id":"stream"}`), ClassStream, nil)
	}
	// 流式帧已经排在队里，再放 pong：它必须插到它们前面（紧跟在当前这帧之后）。
	payload, err := dlp.Encode(dlp.Pong(1))
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	if result := link.EnqueueControl(payload, "pong", true); result != Enqueued {
		t.Fatalf("pong 入队 = %v，期望 Enqueued", result)
	}
	release()

	waitFor(t, "pong 写出", func() bool {
		for _, frame := range sink.frames(t) {
			if frame.Type() == "pong" {
				return true
			}
		}
		return false
	})
	frames := sink.frames(t)
	if len(frames) < 2 || frames[1].Type() != "pong" {
		t.Fatalf("第二帧应是 pong（优先于 20 条流式帧），实际顺序 %v", kinds(frames))
	}
}

// kinds 把帧序列变成类型序列（失败信息用）。
func kinds(frames []dlp.Frame) []string {
	out := make([]string, 0, len(frames))
	for _, frame := range frames {
		out = append(out, frame.Type())
	}
	return out
}

// TestLossyControlDropIsCountedAndDoesNotClose 钉住"可丢控制帧只丢不断"。
func TestLossyControlDropIsCountedAndDoesNotClose(t *testing.T) {
	sink := newFakeSink()
	var mu sync.Mutex
	var dropped []string
	link := startTestLink(t, sink, linkOptions{
		heartbeat: time.Hour,
		onControlDrop: func(_ *Link, frameType string) {
			mu.Lock()
			defer mu.Unlock()
			dropped = append(dropped, frameType)
		},
	})

	release := sink.setBlocking()
	defer release()
	link.Enqueue([]byte(`{"t":"item","id":"blocked"}`), ClassStream, nil)
	waitFor(t, "写循环拿住第一帧", func() bool { return link.Pending() == 0 })
	for index := 0; index < DefaultControlQueueDepth; index++ {
		if result := link.EnqueueControl([]byte(`{"t":"pong","ts":1}`), "pong", true); result != Enqueued {
			t.Fatalf("第 %d 条 pong 入队 = %v", index, result)
		}
	}
	if result := link.EnqueueControl([]byte(`{"t":"pong","ts":2}`), "pong", true); result != FrameDropped {
		t.Fatalf("优先队列满时 pong 入队 = %v，期望 FrameDropped", result)
	}
	mu.Lock()
	calls := append([]string(nil), dropped...)
	mu.Unlock()
	if len(calls) != 1 || calls[0] != "pong" {
		t.Fatalf("丢弃回调 = %v，期望一次 pong", calls)
	}
	if call, ok := sink.lastClose(); ok {
		t.Fatalf("可丢帧被丢弃不该关闭连接，实际关闭 %+v", call)
	}
}

// TestRequiredControlGivesUpAfterTheWaitBudget 钉住"必达控制帧有界等待"：
// 优先队列一直满时，最多等 controlWait 就返回 Overloaded（调用方据此 4008）。
func TestRequiredControlGivesUpAfterTheWaitBudget(t *testing.T) {
	sink := newFakeSink()
	link := startTestLink(t, sink, linkOptions{
		heartbeat:   time.Hour,
		controlWait: 40 * time.Millisecond,
	})

	release := sink.setBlocking()
	defer release()
	link.Enqueue([]byte(`{"t":"item","id":"blocked"}`), ClassStream, nil)
	waitFor(t, "写循环拿住第一帧", func() bool { return link.Pending() == 0 })
	for index := 0; index < DefaultControlQueueDepth; index++ {
		if result := link.EnqueueControl([]byte(`{"t":"pong","ts":1}`), "pong", true); result != Enqueued {
			t.Fatalf("第 %d 条 pong 入队 = %v", index, result)
		}
	}
	started := time.Now()
	result := link.EnqueueControl([]byte(`{"t":"deviceAttach","deviceId":"d"}`),
		"deviceAttach", false)
	elapsed := time.Since(started)
	if result != Overloaded {
		t.Fatalf("必达控制帧入队 = %v，期望 Overloaded", result)
	}
	if elapsed < 30*time.Millisecond || elapsed > time.Second {
		t.Fatalf("等待时长 = %v，期望约 40ms（有界等待）", elapsed)
	}
	if call, ok := sink.lastClose(); ok {
		t.Fatalf("EnqueueControl 只返回结果，不该自己关连接，实际 %+v", call)
	}
}

// TestOrderedControlsStayBehindTheirChunks 钉住"保序控制帧不能越过数据帧"：
// fsPutEnd 必须排在先入队的 fsPutChunk 之后，否则上传方先看到结束、再看到分片，
// 会一直等 fsPutDone（files 包的单测在改造中实测过这个挂死）。
func TestOrderedControlsStayBehindTheirChunks(t *testing.T) {
	sink := newFakeSink()
	link := startTestLink(t, sink, linkOptions{heartbeat: time.Hour})

	release := sink.setBlocking()
	defer release()
	link.Enqueue([]byte(`{"t":"fsPutChunk","bid":"b","seq":0}`), ClassControl, nil)
	link.Enqueue([]byte(`{"t":"fsPutChunk","bid":"b","seq":1}`), ClassControl, nil)
	if result := link.EnqueueControl([]byte(`{"t":"fsPutEnd","bid":"b"}`),
		"fsPutEnd", false); result != Enqueued {
		t.Fatalf("fsPutEnd 入队 = %v", result)
	}
	release()

	waitFor(t, "fsPutEnd 写出", func() bool {
		for _, frame := range sink.frames(t) {
			if frame.Type() == "fsPutEnd" {
				return true
			}
		}
		return false
	})
	order := kinds(sink.frames(t))
	want := []string{"fsPutChunk", "fsPutChunk", "fsPutEnd"}
	for index := range want {
		if index >= len(order) || order[index] != want[index] {
			t.Fatalf("写出顺序 = %v，期望 %v", order, want)
		}
	}
}

// TestAgentHeartbeatNeverWaitsForAPong：DLP 心跳只入队、不等回答；一个 pong 都没
// 回来时写循环仍然照常写后面的流式帧（2026-10-23 故障的直接对照）。
func TestAgentHeartbeatNeverWaitsForAPong(t *testing.T) {
	sink := newFakeSink()
	link := startTestLinkWithKind(t, sink, linkOptions{
		heartbeat:        5 * time.Millisecond,
		heartbeatTimeout: 10 * time.Second, // 故意放长：本用例只验证"不会被 pong 卡住"
	}, heartbeatDLP)

	// 等至少一个心跳周期，让写循环把 ping 放出去。
	time.Sleep(20 * time.Millisecond)
	link.Enqueue([]byte(`{"t":"item","id":"after-ping"}`), ClassStream, nil)
	waitFrame(t, sink, "ping 之后仍能写流式帧", func(frame dlp.Frame) bool {
		return frame.Type() == "item" && frame.ID() == "after-ping"
	})
	waitFrame(t, sink, "DLP ping", isKind("ping"))
	if count := sink.pingCount(); count != 0 {
		t.Fatalf("agent 链路不该调用 WS Ping，实际 %d 次", count)
	}
}

// TestWebSocketHeartbeatClosesTheDeviceLink：设备链路（iOS 只实现 WS ping/pong）
// 的活性检查仍在，但已经移到 watchdog goroutine。
func TestWebSocketHeartbeatClosesTheDeviceLink(t *testing.T) {
	sink := &fakeSink{pingErr: context.DeadlineExceeded}
	link := startTestLink(t, sink, linkOptions{
		heartbeat:        10 * time.Millisecond,
		heartbeatTimeout: 20 * time.Millisecond,
	})
	waitFor(t, "WS 心跳失败后关闭", func() bool { return closeStatus(sink) == dlp.CloseGoingAway })
	select {
	case <-link.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("写循环没有退出")
	}
	if sink.pingCount() == 0 {
		t.Fatal("一次 WS 心跳都没发")
	}
}

// TestIdleLinkSurvivesTheWriteTimeout：空闲 10 秒不是故障。写超时计时器只应约束
// 一次真实的写，不能在连接建立后无条件取消写上下文（否则下一次写必失败，链路被误杀）。
func TestIdleLinkSurvivesTheWriteTimeout(t *testing.T) {
	sink := newFakeSink()
	link := startTestLink(t, sink, linkOptions{
		heartbeat:    time.Hour,
		writeTimeout: 20 * time.Millisecond,
	})
	// 超过 writeTimeout 什么都不写，再写一帧：它必须仍能写出去。
	time.Sleep(60 * time.Millisecond)
	link.Enqueue([]byte(`{"t":"item","id":"after-idle"}`), ClassStream, nil)
	waitFrame(t, sink, "空闲超过写超时后仍能写", func(frame dlp.Frame) bool {
		return frame.ID() == "after-idle"
	})
}

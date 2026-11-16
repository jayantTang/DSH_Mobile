package hub

import (
	"testing"
)

// TestStreamBurstWithinByteBudgetIsNotDropped 是 2026-11-16 事故的回归用例。
//
// 生产现场（修复前）：512 帧的条数上限在 141824 字节（告警里 141651）处判满，
// 随后 500 帧突发（4 毫秒内）被全部静默丢弃，而 4 MiB 的字节预算只用了 3.4%。
// 修复后帧数只是字节预算的兜底，这种量级的突发必须全部入队。
func TestStreamBurstWithinByteBudgetIsNotDropped(t *testing.T) {
	const (
		byteLimit = 4 << 20
		// frameSize 取生产告警里的平均值：141651 字节 / 512 帧 ≈ 277。
		frameSize = 277
	)
	depth := DefaultLimits().QueueDepth
	var windows []int64
	link := newLink(newFakeSink(), "device dev_repro", depth, byteLimit,
		discardLogger(), linkOptions{
			onStreamDrop: func(_ *Link, dropped int64) {
				windows = append(windows, dropped)
			},
		}.withDefaults())

	payload := make([]byte, frameSize)
	for index := range 512 {
		if got := link.Enqueue(payload, ClassStream, nil); got != Enqueued {
			t.Fatalf("第 %d 帧入队结果 = %v，期望 %v", index, got, Enqueued)
		}
	}
	for index := range 500 {
		if got := link.Enqueue(payload, ClassStream, nil); got != Enqueued {
			t.Fatalf("突发第 %d 帧入队结果 = %v，期望 %v（字节预算远未到）", index, got, Enqueued)
		}
	}
	if got := link.DroppedFrames(); got != 0 {
		t.Fatalf("丢弃帧数 = %d，期望 0", got)
	}
	if len(windows) != 0 {
		t.Fatalf("告警窗口 = %d 个，期望 0", len(windows))
	}
	if got := link.QueueDepth(); got != 1012 {
		t.Fatalf("队列深度 = %d，期望 1012", got)
	}
	if used := link.QueuedBytes(); used != 1012*frameSize {
		t.Fatalf("队列字节 = %d，期望 %d", used, 1012*frameSize)
	}
}

// TestStreamDropOnlyAfterByteBudget 钉住修复后的唯一丢帧条件：字节预算耗尽。
// 帧数上限（16384）在这条路径上不能先触发，否则又回到"条数先把预算饿死"的旧形态。
func TestStreamDropOnlyAfterByteBudget(t *testing.T) {
	const (
		byteLimit = 4 << 20
		frameSize = 277
	)
	var windows int
	link := newLink(newFakeSink(), "device dev_budget", DefaultLimits().QueueDepth,
		byteLimit, discardLogger(), linkOptions{
			onStreamDrop: func(_ *Link, _ int64) { windows++ },
		}.withDefaults())

	payload := make([]byte, frameSize)
	accepted := 0
	for {
		if got := link.Enqueue(payload, ClassStream, nil); got == FrameDropped {
			break
		}
		accepted++
		if accepted > 20000 {
			t.Fatal("入队 20000 帧仍未触发丢弃，用例没测到字节预算")
		}
	}
	if used := link.QueuedBytes(); used+frameSize <= byteLimit {
		t.Fatalf("首次丢弃时队列 %d 字节，预算 %d 字节：还没到预算就丢了", used, byteLimit)
	}
	if used := link.QueuedBytes(); used > byteLimit {
		t.Fatalf("队列字节 = %d，超过预算 %d", used, byteLimit)
	}
	if accepted*frameSize > byteLimit+frameSize {
		t.Fatalf("接受了 %d 帧（%d 字节），超过预算 %d", accepted, accepted*frameSize, byteLimit)
	}
	// 再丢满一个告警窗口（100 帧），确认丢帧确实进了告警通道。
	for range streamDropAlertThreshold {
		link.Enqueue(payload, ClassStream, nil)
	}
	if windows == 0 {
		t.Fatal("达到预算后没有产生告警窗口")
	}
}

// TestUnaryResponseIsNotInTheDroppableClass：res 是一元调用的唯一响应，不能走
// item 的可丢路径。丢了只能等 60 秒超时，那是"静默坏结果"。
func TestUnaryResponseIsNotInTheDroppableClass(t *testing.T) {
	if got := classOf([]byte("item")); got != ClassStream {
		t.Fatalf("item 归 %v，期望 %v", got, ClassStream)
	}
	if got := classOf([]byte("res")); got != ClassControl {
		t.Fatalf("res 归 %v，期望 %v", got, ClassControl)
	}
}

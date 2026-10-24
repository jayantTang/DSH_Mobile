package hub

import (
	"sync"
	"testing"
)

// TestStreamEnqueueNeverExceedsTheByteLimit 钉住 B1 的 CAS 硬界：多 goroutine
// 同时入队流式帧，queuedBytes 在任何时刻都不许越过 byteLimit。
//
// 旧的"读-判-加"两步在并发下会瞬时超标（双方同时读到没超，各自 Add 之后总量
// 越界）；这个用例用持续采样抓峰值，没有写循环排水，留下的账就是最终证据。
func TestStreamEnqueueNeverExceedsTheByteLimit(t *testing.T) {
	const (
		byteLimit  = 1000
		frameSize  = 100
		goroutines = 8
		attempts   = 200
	)
	link := newLink(newFakeSink(), "device race", attempts*goroutines, byteLimit,
		discardLogger(), linkOptions{}.withDefaults())

	stop := make(chan struct{})
	var peak int64
	var sampler sync.WaitGroup
	sampler.Add(1)
	go func() {
		defer sampler.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			if used := link.QueuedBytes(); used > peak {
				peak = used
			}
		}
	}()

	var workers sync.WaitGroup
	for range goroutines {
		workers.Add(1)
		go func() {
			defer workers.Done()
			payload := make([]byte, frameSize)
			for range attempts {
				link.Enqueue(payload, ClassStream, nil)
			}
		}()
	}
	workers.Wait()
	close(stop)
	sampler.Wait()

	if peak > byteLimit {
		t.Fatalf("queuedBytes 峰值 = %d，越过 byteLimit %d", peak, byteLimit)
	}
	if used := link.QueuedBytes(); used > byteLimit {
		t.Fatalf("最终 queuedBytes = %d，越过 byteLimit %d", used, byteLimit)
	}
	if link.DroppedFrames() == 0 {
		t.Fatal("注入压力不足：没有发生任何丢弃，用例没测到硬界")
	}
	// 账必须平：排进队列的字节 + 被丢的帧字节 = 全部尝试过的字节。
	enqueued := int64(link.Pending()) * frameSize
	if link.QueuedBytes() != enqueued {
		t.Fatalf("queuedBytes = %d，与队列内容 %d 不符", link.QueuedBytes(), enqueued)
	}
}

// TestStreamDropAlertFiresOncePerWindow 钉住 B3：流式帧丢弃累计满一个告警窗口
// 回调一次并重新开窗；回调只带链路与窗口计数，不带帧内容（内容不进告警通道）。
func TestStreamDropAlertFiresOncePerWindow(t *testing.T) {
	type alert struct {
		label   string
		dropped int64
	}
	var mu sync.Mutex
	var alerts []alert
	link := newLink(newFakeSink(), "device dev_alert", 1, 1<<20,
		discardLogger(), linkOptions{
			onStreamDrop: func(link *Link, dropped int64) {
				mu.Lock()
				defer mu.Unlock()
				alerts = append(alerts, alert{label: link.Label(), dropped: dropped})
			},
		}.withDefaults())

	// 队列深 1 且不开写循环：第一帧排队，其余全部丢弃。
	payload := make([]byte, 64)
	const attempts = streamDropAlertThreshold*2 + 3
	for range attempts {
		link.Enqueue(payload, ClassStream, nil)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(alerts) != 2 {
		t.Fatalf("告警次数 = %d，期望每满 %d 帧一次（共 2 次）",
			len(alerts), streamDropAlertThreshold)
	}
	for index, entry := range alerts {
		if entry.label != "device dev_alert" {
			t.Fatalf("第 %d 条告警的链路 = %q", index, entry.label)
		}
		if entry.dropped != streamDropAlertThreshold {
			t.Fatalf("第 %d 条告警的窗口计数 = %d，期望 %d",
				index, entry.dropped, streamDropAlertThreshold)
		}
	}
}

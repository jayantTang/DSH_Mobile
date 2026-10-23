package quota

import (
	"sort"
	"sync"
	"testing"
	"time"
)

// TestTokenBucketPacesSustainedVolume：桶一开始是满的（普通一轮对话完全不等），
// 只有持续的大流量才开始等待；等待时长按超出的字节数算。
func TestTokenBucketPacesSustainedVolume(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	bucket := NewBucket(1000, now) // 1000 B/s，突发额度 64 KiB
	if wait := bucket.Take(1000, now); wait != 0 {
		t.Fatalf("突发额度内的第一帧不该等待：%v", wait)
	}
	wait := bucket.Take(64*1024, now)
	if wait < 900*time.Millisecond || wait > 1100*time.Millisecond {
		t.Fatalf("超出 1000 字节应等待约 1 秒，实际 %v", wait)
	}
	// 过 2 秒再取：桶按速率回填（上限是 burst），小帧不再等待。
	later := now.Add(2 * time.Second)
	if wait := bucket.Take(1000, later); wait != 0 {
		t.Fatalf("回填后不该等待：%v", wait)
	}
}

// TestTokenBucketDisabledMeansNoWait：rate<=0 是"不限速"，任何大小都不等待。
func TestTokenBucketDisabledMeansNoWait(t *testing.T) {
	bucket := NewBucket(0, time.Now())
	if wait := bucket.Take(32<<20, time.Now()); wait != 0 {
		t.Fatalf("不限速时不该等待：%v", wait)
	}
}

// TestBucketBurstAndRate 钉住桶数学与并发安全（DESIGN §5.3）。
//
// 128 条并发写路径同时消耗同一个桶（WebSocket 写循环 + /files/down 的正文）：
// 同一时刻没有任何回填，所以等待时长的**多重集**是确定的——前 64 KiB（burst）
// 不等，之后第 k 个 1 KiB 等待 k KiB/rate。若 Take 少了锁，-race 会红。
func TestBucketBurstAndRate(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	const rate = 1 << 15 // 32 KiB/s：低于 64 KiB 时 burst 取 64 KiB
	const writers = 128
	const chunk = 1024
	bucket := NewBucket(rate, now)

	waits := make([]time.Duration, writers)
	var group sync.WaitGroup
	start := make(chan struct{})
	for index := 0; index < writers; index++ {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			<-start
			waits[index] = bucket.Take(chunk, now)
		}(index)
	}
	close(start)
	group.Wait()

	sort.Slice(waits, func(i, j int) bool { return waits[i] < waits[j] })
	// burst = 64 KiB：第 64 个正好把桶取空，第 65 个开始等。
	if waits[63] != 0 || waits[64] == 0 {
		t.Fatalf("突发边界不对：第 64 个 = %v，第 65 个 = %v", waits[63], waits[64])
	}
	want := time.Duration(float64(writers-64) * chunk / rate * float64(time.Second))
	if diff := waits[writers-1] - want; diff < -time.Millisecond || diff > time.Millisecond {
		t.Fatalf("第 %d 个等待 = %v，期望约 %v", writers, waits[writers-1], want)
	}
	for index, wait := range waits {
		if wait < 0 {
			t.Fatalf("第 %d 个等待为负：%v", index, wait)
		}
	}
	// 同一时刻继续取：桶不会凭空回填，等待必然更长。
	if wait := bucket.Take(chunk, now); wait <= waits[writers-1] {
		t.Fatalf("同一时刻继续取应当等更久，实际 %v（上一个 %v）", wait, waits[writers-1])
	}
}

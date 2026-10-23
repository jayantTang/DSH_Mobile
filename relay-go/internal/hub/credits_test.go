package hub

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
)

// bridgeCredits 的用例只回答四个问题：额度会不会等、等的人会不会被叫醒、
// 取消/顶替会不会漏账、超容量的一笔会不会死锁。全部用整数毫秒级超时，
// 不允许"睡一会儿看看"。

func acquireAsync(ctx context.Context, credits *bridgeCredits, n int64) <-chan error {
	done := make(chan error, 1)
	go func() { done <- credits.Acquire(ctx, n) }()
	return done
}

func waitError(t *testing.T, what string, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(2 * time.Second):
		t.Fatalf("等待超时：%s", what)
		return nil
	}
}

func waitGranted(t *testing.T, what string, done <-chan error) {
	t.Helper()
	if err := waitError(t, what, done); err != nil {
		t.Fatalf("%s 应该拿到额度，得到 %v", what, err)
	}
}

func expectStillWaiting(t *testing.T, what string, done <-chan error) {
	t.Helper()
	select {
	case err := <-done:
		t.Fatalf("%s 不该被放行（err=%v）", what, err)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestBridgeCreditsGrantAndRelease(t *testing.T) {
	credits := newBridgeCredits(100)
	if err := credits.Acquire(context.Background(), 60); err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if got := credits.InUse(); got != 60 {
		t.Fatalf("InUse = %d, 期望 60", got)
	}
	credits.Release(60)
	if got := credits.InUse(); got != 0 || credits.overReleased() != 0 {
		t.Fatalf("归还后 InUse = %d, overReleased = %d", got, credits.overReleased())
	}
}

func TestBridgeCreditsBlocksUntilRelease(t *testing.T) {
	credits := newBridgeCredits(10)
	if err := credits.Acquire(context.Background(), 10); err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	waiting := acquireAsync(context.Background(), credits, 4)
	expectStillWaiting(t, "额度用满时的第二笔", waiting)
	if got := credits.Waiting(); got != 1 {
		t.Fatalf("Waiting = %d, 期望 1", got)
	}
	credits.Release(4)
	waitGranted(t, "归还后的一笔", waiting)
	if got := credits.InUse(); got != 10 {
		t.Fatalf("InUse = %d, 期望 10", got)
	}
}

// 先进先出：后来者不许插队（否则小请求会在大请求前面反复抢到额度）。
func TestBridgeCreditsWakeInFIFOOrder(t *testing.T) {
	credits := newBridgeCredits(10)
	if err := credits.Acquire(context.Background(), 10); err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	first := acquireAsync(context.Background(), credits, 10)
	waitFor(t, "第一个等待者入队", func() bool { return credits.Waiting() == 1 })
	second := acquireAsync(context.Background(), credits, 10)
	waitFor(t, "第二个等待者入队", func() bool { return credits.Waiting() == 2 })
	expectStillWaiting(t, "第一个等待者", first)
	expectStillWaiting(t, "第二个等待者", second)

	credits.Release(10)
	waitGranted(t, "第一个等待者", first)
	expectStillWaiting(t, "第二个等待者（第一个已占满）", second)

	credits.Release(10)
	waitGranted(t, "第二个等待者", second)
	if got := credits.InUse(); got != 10 {
		t.Fatalf("InUse = %d, 期望 10", got)
	}
}

// 取消时如果额度已在取消的同时发下来，必须原样还回去；不许漏，也不许多还。
func TestBridgeCreditsCancelledWaiterReturnsItsReservation(t *testing.T) {
	credits := newBridgeCredits(10)
	if err := credits.Acquire(context.Background(), 10); err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	waiting := acquireAsync(ctx, credits, 10)
	expectStillWaiting(t, "取消前的等待者", waiting)
	cancel()
	if err := waitError(t, "取消的等待者", waiting); !errors.Is(err, context.Canceled) {
		t.Fatalf("取消应返回 context.Canceled，得到 %v", err)
	}
	if got := credits.Waiting(); got != 0 {
		t.Fatalf("取消后 Waiting = %d, 期望 0", got)
	}
	if got := credits.InUse(); got != 10 {
		t.Fatalf("取消不该改变已占用额度：InUse = %d", got)
	}
	// 把已占用的还回去，确认取消过的那一笔没有偷偷占着。
	credits.Release(10)
	if got := credits.InUse(); got != 0 || credits.overReleased() != 0 {
		t.Fatalf("InUse = %d, overReleased = %d", got, credits.overReleased())
	}
}

// 取消与放行撞在一起（release 先发生）时，额度已经计入，必须由取消路径归还。
func TestBridgeCreditsCancelAfterGrantDoesNotLeak(t *testing.T) {
	for attempt := 0; attempt < 50; attempt++ {
		credits := newBridgeCredits(1)
		if err := credits.Acquire(context.Background(), 1); err != nil {
			t.Fatalf("Acquire: %v", err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		waiting := acquireAsync(ctx, credits, 1)
		expectStillWaiting(t, "等待者", waiting)
		cancel()
		credits.Release(1) // 与取消撞在一起
		_ = waitError(t, "等待者", waiting)
		// 两种合法结局：取消赢了（额度留在原地）或放行赢了（取消路径已归还）。
		// 无论哪种，额度都必须回到"全空"或"全占"的确定状态，不能漏。
		if used := credits.InUse(); used != 0 && used != 1 {
			t.Fatalf("InUse = %d，期望 0 或 1", used)
		}
		if credits.overReleased() != 0 {
			t.Fatalf("overReleased = %d", credits.overReleased())
		}
	}
}

func TestBridgeCreditsCloseWakesWaiters(t *testing.T) {
	credits := newBridgeCredits(10)
	if err := credits.Acquire(context.Background(), 10); err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	waiting := acquireAsync(context.Background(), credits, 10)
	expectStillWaiting(t, "关闭前的等待者", waiting)
	credits.Close()
	if err := waitError(t, "关闭后的等待者", waiting); !errors.Is(err, ErrBridgeCreditClosed) {
		t.Fatalf("关闭应返回 ErrBridgeCreditClosed，得到 %v", err)
	}
	if err := credits.Acquire(context.Background(), 1); !errors.Is(err, ErrBridgeCreditClosed) {
		t.Fatalf("关闭后的新 Acquire = %v", err)
	}
	credits.Release(10)
	if got := credits.InUse(); got != 0 {
		t.Fatalf("Release 后 InUse = %d", got)
	}
}

// 单笔比总容量还大：只在"一分钱都没花"时放行，之后同类的请求继续等。
func TestBridgeCreditsOversizedRequestWaitsForAnEmptyBudget(t *testing.T) {
	credits := newBridgeCredits(4)
	if err := credits.Acquire(context.Background(), 4); err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	oversized := acquireAsync(context.Background(), credits, 8)
	expectStillWaiting(t, "超容量的一笔（额度未清空）", oversized)
	credits.Release(4)
	waitGranted(t, "额度清空后的超容量一笔", oversized)
	if got := credits.InUse(); got != 8 {
		t.Fatalf("InUse = %d, 期望 8", got)
	}
	credits.Release(8)
	if got := credits.InUse(); got != 0 {
		t.Fatalf("InUse = %d", got)
	}
}

// 并发拿额度时占用不超过容量，且容量真的能被用满（第 33 个字节必须等）。
//
// 旧写法用「峰值接近 32」做下界，在 -race + 全包并行的负载下会因为 goroutine
// 没被同时调度而偶发（实测 21/32）；这里改成显式的等待栅栏：16 个 worker 各占
// 2 字节，占满后第 33 个字节必须阻塞，放行后全部归还。判定不再依赖调度时序。
func TestBridgeCreditsConcurrentBudgetNeverExceeded(t *testing.T) {
	const (
		capacity  = 32
		workers   = 16
		perWorker = 2
	)
	credits := newBridgeCredits(capacity)
	holding := make(chan struct{})
	var group sync.WaitGroup
	for worker := 0; worker < workers; worker++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if err := credits.Acquire(context.Background(), perWorker); err != nil {
				t.Errorf("Acquire: %v", err)
				return
			}
			<-holding
			credits.Release(perWorker)
		}()
	}
	waitFor(t, "全部额度被 worker 占满", func() bool { return credits.InUse() == capacity })

	extra := acquireAsync(context.Background(), credits, 1)
	expectStillWaiting(t, "额度占满时的第 33 个字节", extra)
	close(holding)
	waitGranted(t, "释放后的第 33 个字节", extra)
	credits.Release(1)
	group.Wait()
	if got := credits.InUse(); got != 0 {
		t.Fatalf("全部归还后 InUse = %d", got)
	}
	if got := credits.overReleased(); got != 0 {
		t.Fatalf("overReleased = %d", got)
	}
}

// 额度随帧走：写出去之后才归还；连接关闭时队列里的帧也会归还（不泄漏）。
func TestLinkReleasesBridgeCreditAfterWrite(t *testing.T) {
	sink := newFakeSink()
	link := newLink(sink, "agent test", 8, 4<<20, testLogger(t), linkOptions{}.withDefaults())
	link.credits = newBridgeCredits(1 << 20)
	link.Start(context.Background())
	defer link.RequestClose(1001, "test done")

	if err := link.AcquireBridgeBytes(context.Background(), 1024); err != nil {
		t.Fatalf("AcquireBridgeBytes: %v", err)
	}
	if result := link.EnqueueWithCredit([]byte(`{"t":"fsPutChunk"}`), ClassControl,
		link.credits, 1024); result != Enqueued {
		t.Fatalf("EnqueueWithCredit = %v", result)
	}
	waitFor(t, "写出去之后额度归零", func() bool { return link.BridgeBytesInUse() == 0 })
}

func TestLinkReleasesQueuedCreditsWhenItStops(t *testing.T) {
	sink := newFakeSink()
	release := sink.setBlocking()
	link := newLink(sink, "agent test", 8, 4<<20, testLogger(t), linkOptions{}.withDefaults())
	link.credits = newBridgeCredits(4 << 10)
	ctx, cancel := context.WithCancel(context.Background())
	link.Start(ctx)

	for index := 0; index < 3; index++ {
		if err := link.AcquireBridgeBytes(context.Background(), 1024); err != nil {
			t.Fatalf("第 %d 笔 AcquireBridgeBytes: %v", index, err)
		}
		if result := link.EnqueueWithCredit([]byte(`{"t":"fsPutChunk"}`), ClassControl,
			link.credits, 1024); result != Enqueued {
			t.Fatalf("第 %d 帧入队 = %v", index, result)
		}
	}
	waitFor(t, "三笔额度都在用", func() bool { return link.BridgeBytesInUse() == 3*1024 })

	// 写循环卡在第一次写上；取消链路 = 连接坏掉，队列里剩下的两帧不会再写。
	cancel()
	release()
	waitFor(t, "链路退出后额度归零", func() bool { return link.BridgeBytesInUse() == 0 })
}

// 连接器被顶替：旧链路上等额度的请求立刻失败（不许无限期挂着），新链路拿一份
// 全新的、未被旧连接占用的额度。旧链路已占用的部分在它退出时归零。
func TestSupersededAgentReleasesBridgeCredits(t *testing.T) {
	f := newFixture(t, Options{
		Limits:   Limits{BridgeBytes: 2 << 20},
		Presence: presence.Options{ActiveIdle: time.Millisecond},
	})
	owner := f.newTenant("bridge-credits")
	first, _ := f.attachAgent(owner)
	if got := first.BridgeBytesCapacity(); got != 2<<20 {
		t.Fatalf("第一条链路的额度 = %d，期望 2 MiB", got)
	}
	// 占满额度，再让第二个请求排队等。
	if err := first.AcquireBridgeBytes(context.Background(), 2<<20); err != nil {
		t.Fatalf("AcquireBridgeBytes: %v", err)
	}
	waiting := acquireAsync(context.Background(), first.credits, 1<<20)
	waitFor(t, "等待者入队", func() bool { return first.BridgeBytesWaiting() == 1 })

	time.Sleep(5 * time.Millisecond) // 让旧连接过了僵死窗口，允许顶替
	second := f.hub.AttachAgent(context.Background(), owner.agent, newFakeSink(), f.admitAgent(owner))
	t.Cleanup(func() { f.hub.DetachAgent(second) })

	if err := waitError(t, "被顶替链路上的等待者", waiting); !errors.Is(err, ErrBridgeCreditClosed) {
		t.Fatalf("顶替后等待者 = %v，期望 ErrBridgeCreditClosed", err)
	}
	first.ReleaseBridgeBytes(2 << 20)
	waitFor(t, "旧链路的额度归零", func() bool { return first.BridgeBytesInUse() == 0 })
	if got := second.BridgeBytesInUse(); got != 0 {
		t.Fatalf("新链路不该继承旧链路的占用：InUse = %d", got)
	}
	if got := second.BridgeBytesCapacity(); got != 2<<20 {
		t.Fatalf("新链路额度 = %d", got)
	}
}

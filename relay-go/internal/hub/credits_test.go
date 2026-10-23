package hub

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/bridge"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
)

// 桥字节额度的状态机与等待队列在 internal/bridge；这里只钉住 **Link 的转移规则**：
// 额度随帧走、写出去（或随连接关闭清空）之后才归还、顶替只关闭旧链路的额度。
// 全部用整数毫秒级超时，不允许"睡一会儿看看"。

func acquireAsync(ctx context.Context, credits *bridge.Credits, n int64) <-chan error {
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

// 额度随帧走：写出去之后才归还；连接关闭时队列里的帧也会归还（不泄漏）。
func TestLinkReleasesBridgeCreditAfterWrite(t *testing.T) {
	sink := newFakeSink()
	link := newLink(sink, "agent test", 8, 4<<20, testLogger(t), linkOptions{}.withDefaults())
	link.credits = bridge.NewCredits(1 << 20)
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
	link.credits = bridge.NewCredits(4 << 10)
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

	if err := waitError(t, "被顶替链路上的等待者", waiting); !errors.Is(err, bridge.ErrCreditsClosed) {
		t.Fatalf("顶替后等待者 = %v，期望 bridge.ErrCreditsClosed", err)
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

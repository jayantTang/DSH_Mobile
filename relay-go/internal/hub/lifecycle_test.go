package hub

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// fakeUsageWriter 记录冲盘批次；可注入一次失败。
//
// 它是 quota.Sink 的测试替身，只覆盖冲盘去路：这些用例没有真实挂接设备，
// 所以不 Seat 额度、也不读 today；基线与今日查询返回空是从未被观察到的分支。
type fakeUsageWriter struct {
	mu      sync.Mutex
	batches [][]store.UsageEntry
	err     error
	calls   int
}

func (w *fakeUsageWriter) AddUsage(_ context.Context, entries []store.UsageEntry) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.calls++
	if w.err != nil {
		return 0, w.err
	}
	w.batches = append(w.batches, append([]store.UsageEntry(nil), entries...))
	return len(entries), nil
}

func (w *fakeUsageWriter) UsageBytesOn(context.Context, int64, string) (int64, error) {
	return 0, nil
}

func (w *fakeUsageWriter) TodayUsage(context.Context, int64) (store.TodayUsage, error) {
	return store.TodayUsage{}, nil
}

func (w *fakeUsageWriter) setError(err error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.err = err
}

// flatten 返回写成功的全部行。
func (w *fakeUsageWriter) flatten() []store.UsageEntry {
	w.mu.Lock()
	defer w.mu.Unlock()
	var out []store.UsageEntry
	for _, batch := range w.batches {
		out = append(out, batch...)
	}
	return out
}

func (w *fakeUsageWriter) entriesFor(deviceID string) []store.UsageEntry {
	var out []store.UsageEntry
	for _, entry := range w.flatten() {
		if entry.DeviceID == deviceID {
			out = append(out, entry)
		}
	}
	return out
}

func TestFlushUsageRestoresTheBatchWhenTheWriteFails(t *testing.T) {
	writer := &fakeUsageWriter{err: context.DeadlineExceeded}
	fx := newFixture(t, Options{UsageSink: writer})
	// 账本方法只认设备字段；这里不挂真连接，免得连接建立本身写出的 hostStatus
	// 帧混进"这一批到底有多少字节"的断言。
	link := &DeviceLink{DeviceID: "dev_retry", AgentID: "agt_1", AccountID: "acc_1"}

	fx.hub.usage.NoteConnection(link.ref())
	fx.hub.usage.NoteEgress(link.ref(), 100)

	if err := fx.hub.FlushUsage(context.Background()); err == nil {
		t.Fatal("写库失败时应当返回错误")
	}
	if !fx.hub.usage.Pending() {
		t.Fatal("失败的那一批必须放回内存")
	}
	snapshot := fx.hub.usage.Snapshot()
	if len(snapshot) != 1 || snapshot[0].EgressBytes != 100 || snapshot[0].Connections != 1 {
		t.Fatalf("回放后的账本 = %+v", snapshot)
	}

	// 失败期间又产生了一些字节：恢复时要合并，而不是覆盖。
	fx.hub.usage.NoteEgress(link.ref(), 50)
	writer.setError(nil)
	if err := fx.hub.FlushUsage(context.Background()); err != nil {
		t.Fatalf("第二次冲盘失败：%v", err)
	}
	if pending := fx.hub.usage.Pending(); pending {
		t.Fatal("成功之后账本应当清空")
	}
	written := writer.entriesFor(link.DeviceID)
	if len(written) != 1 || written[0].EgressBytes != 150 || written[0].Connections != 1 {
		t.Fatalf("写进库的内容 = %+v", written)
	}
	if written[0].Day != store.LocalDay() {
		t.Fatalf("day = %d", written[0].Day)
	}
}

// flakyUsageWriter 第一次写失败，之后委托给真实仓储：用来证明"回放之后真的落库"。
// 嵌入 *store.Store 补齐 quota.Sink 的另外两个方法（基线也读真实库）。
type flakyUsageWriter struct {
	*store.Store
	failures int
}

func (w *flakyUsageWriter) AddUsage(ctx context.Context, entries []store.UsageEntry) (int, error) {
	if w.failures > 0 {
		w.failures--
		return 0, context.DeadlineExceeded
	}
	return w.Store.AddUsage(ctx, entries)
}

func TestFlushUsageLandsInTheRealStoreAndSeedsTheQuota(t *testing.T) {
	limits := DefaultLimits()
	limits.DeviceDailyBytes = 1000
	st := openTestStore(t)
	fx := newFixtureWithStore(t, st, Options{
		Limits:    limits,
		UsageSink: &flakyUsageWriter{Store: st, failures: 1},
	})
	link := &DeviceLink{DeviceID: "dev_real", AgentID: "agt_1", AccountID: "acc_1"}
	fx.hub.usage.NoteEgress(link.ref(), 100)
	fx.hub.usage.NoteConnection(link.ref())

	// 第一次写失败：这批必须回到内存，库里仍然是空的。
	if err := fx.hub.FlushUsage(context.Background()); err == nil {
		t.Fatal("第一次冲盘应当失败")
	}
	day := store.LocalDay()
	if stored, err := fx.store.UsageBytesOn(context.Background(), day, link.DeviceID); err != nil ||
		stored != 0 {
		t.Fatalf("失败之后库里不该有数：%d err=%v", stored, err)
	}
	if !fx.hub.usage.Pending() {
		t.Fatal("失败的那一批必须还在内存里")
	}

	// 第二次写成功：库里有 100，日额度的基线也随之读到它。
	if err := fx.hub.FlushUsage(context.Background()); err != nil {
		t.Fatalf("第二次冲盘失败：%v", err)
	}
	if stored, err := fx.store.UsageBytesOn(context.Background(), day, link.DeviceID); err != nil ||
		stored != 100 {
		t.Fatalf("库里的出口字节 = %d err=%v", stored, err)
	}
	fx.hub.SeatDeviceQuota(context.Background(), link.DeviceID)
	if remaining := fx.hub.DeviceQuotaRemaining(link.DeviceID); remaining != 900 {
		t.Fatalf("额度基线没有读到刚冲下去的那一行：remaining = %d", remaining)
	}
	if fx.hub.usage.Pending() {
		t.Fatal("成功之后账本应当清空")
	}
}

func TestUsageFlushLoopWritesAtTheByteThreshold(t *testing.T) {
	writer := &fakeUsageWriter{}
	fx := newFixture(t, Options{
		UsageSink:          writer,
		UsageFlushInterval: 5 * time.Millisecond,
		UsageFlushBytes:    10,
		Logger:             discardLogger(),
	})
	link := &DeviceLink{DeviceID: "dev_loop", AgentID: "agt_1", AccountID: "acc_1"}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	fx.hub.StartBackground(ctx)

	fx.hub.usage.NoteEgress(link.ref(), 32)
	waitFor(t, "冲盘循环写出 32 字节", func() bool {
		entries := writer.entriesFor(link.DeviceID)
		return len(entries) == 1 && entries[0].EgressBytes == 32
	})
	// 账本已经空了一段时间；再次触发只应当是空转，不能再写一遍（累加会翻倍）。
	time.Sleep(30 * time.Millisecond)
	if entries := writer.entriesFor(link.DeviceID); len(entries) != 1 {
		t.Fatalf("同一批被写了 %d 次", len(entries))
	}
}

func TestUsageFlushLoopFlushesThePreviousDayOnRollover(t *testing.T) {
	var day atomic.Int64
	day.Store(2_000_000)
	writer := &fakeUsageWriter{}
	fx := newFixture(t, Options{
		Day:                func() int64 { return day.Load() },
		UsageSink:          writer,
		UsageFlushInterval: 10 * time.Millisecond,
		UsageFlushBytes:    1 << 30, // 不靠字节阈值，只靠跨日
		Logger:             discardLogger(),
	})
	link := &DeviceLink{DeviceID: "dev_rollover", AgentID: "agt_1", AccountID: "acc_1"}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	fx.hub.StartBackground(ctx)

	fx.hub.usage.NoteEgress(link.ref(), 7)
	day.Store(2_000_001)

	waitFor(t, "跨日冲盘", func() bool {
		entries := writer.entriesFor(link.DeviceID)
		return len(entries) == 1 && entries[0].Day == 2_000_000 && entries[0].EgressBytes == 7
	})
}

func TestReconcileDetachesDevicesRevokedBehindTheRelaysBack(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("reconcile")
	device := fx.pairDevice(owner, "reconcile-phone")
	agent, agentSink := fx.attachAgent(owner)
	_, deviceSink := fx.mustAttachDevice(device)

	if err := fx.store.RevokeDevice(context.Background(), device.DeviceID); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}
	detached, err := fx.hub.ReconcileRevokedDevices(context.Background())
	if err != nil {
		t.Fatalf("ReconcileRevokedDevices: %v", err)
	}
	if len(detached) != 1 || detached[0] != device.DeviceID {
		t.Fatalf("被踢的设备 = %v", detached)
	}
	waitFor(t, "设备以 1001 断开", func() bool {
		return closeStatus(deviceSink) == dlp.CloseGoingAway
	})
	waitFor(t, "连接器收到 deviceDetach(revoked)", func() bool {
		return countFrames(agentSink, func(frame dlp.Frame) bool {
			return frame.Type() == "deviceDetach" &&
				frame["deviceId"] == device.DeviceID && frame["reason"] == "revoked"
		}) == 1
	})
	if remaining := fx.hub.Device(device.DeviceID); remaining != nil {
		t.Fatalf("撤销的设备仍然登记着：%+v", remaining)
	}
	fx.hub.DetachAgent(agent)

	// 没有在线设备时不必查库，也不会误报。
	if again, err := fx.hub.ReconcileRevokedDevices(context.Background()); err != nil ||
		len(again) != 0 {
		t.Fatalf("第二轮 = %v err=%v", again, err)
	}
}

func TestReconcileLoopKeepsTicking(t *testing.T) {
	fx := newFixture(t, Options{
		RevokeReconcileInterval: 5 * time.Millisecond,
		Logger:                  discardLogger(),
	})
	owner := fx.newTenant("reconcile-loop")
	device := fx.pairDevice(owner, "reconcile-loop-phone")
	agent, _ := fx.attachAgent(owner)
	fx.mustAttachDevice(device)

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	fx.hub.StartBackground(ctx)

	if err := fx.store.RevokeDevice(context.Background(), device.DeviceID); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}
	waitFor(t, "对账循环踢掉已撤销设备", func() bool {
		return fx.hub.Device(device.DeviceID) == nil
	})
	fx.hub.DetachAgent(agent)
}

// TestShutdownFlushesThePendingUsage 钉住 B2：关停收尾必须把内存账本的尾巴
// 冲进库，即使传入的 ctx 已经取消（那正是提前走到收尾的原因）。
func TestShutdownFlushesThePendingUsage(t *testing.T) {
	fx := newFixture(t, Options{Logger: discardLogger()})
	link := &DeviceLink{DeviceID: "dev_shutdown", AgentID: "agt_1", AccountID: "acc_1"}
	fx.hub.usage.NoteConnection(link.ref())
	fx.hub.usage.NoteEgress(link.ref(), 256)
	if !fx.hub.usage.Pending() {
		t.Fatal("前置：账本里应当有待冲盘的一批")
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // 已取消的 ctx：冲盘用独立时限，不许复用它
	fx.hub.Shutdown(ctx)

	if fx.hub.usage.Pending() {
		t.Fatal("Shutdown 之后账本应当清空")
	}
	stored, err := fx.store.UsageBytesOn(context.Background(), store.LocalDay(), link.DeviceID)
	if err != nil || stored != 256 {
		t.Fatalf("库里的出口字节 = %d err=%v，期望 256", stored, err)
	}
}

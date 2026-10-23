package quota

import (
	"context"
	"sync"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 编译期断言：生产实现必须满足 quota 的仓储面（DESIGN §2.5 的消费者做法）。
var _ Sink = (*store.Store)(nil)

// recordingSink 记录冲盘批次，可注入一次失败（只用于 Usage 的冲盘路径）。
type recordingSink struct {
	mu      sync.Mutex
	batches [][]store.UsageEntry
	err     error
	calls   int
}

func (s *recordingSink) AddUsage(_ context.Context, entries []store.UsageEntry) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	if s.err != nil {
		return 0, s.err
	}
	s.batches = append(s.batches, append([]store.UsageEntry(nil), entries...))
	return len(entries), nil
}

func (s *recordingSink) UsageBytesOn(context.Context, int64, string) (int64, error) {
	return 0, nil
}

func (s *recordingSink) TodayUsage(context.Context, int64) (store.TodayUsage, error) {
	return store.TodayUsage{}, nil
}

func (s *recordingSink) setError(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.err = err
}

func (s *recordingSink) callCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

func (s *recordingSink) flatten() []store.UsageEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []store.UsageEntry
	for _, batch := range s.batches {
		out = append(out, batch...)
	}
	return out
}

// TestUsageFlushRestoresExactlyOnce 钉住冲盘失败的回放（DESIGN §5.3）：
// 失败的那一批放回内存，下一次写成功不重复计数；账本空了就不再调仓储。
func TestUsageFlushRestoresExactlyOnce(t *testing.T) {
	day := int64(2_000_000)
	sink := &recordingSink{err: context.DeadlineExceeded}
	usage := NewUsage(sink, func() int64 { return day }, discardLogger())
	ref := DeviceRef{DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1"}
	usage.NoteConnection(ref)
	usage.NoteEgress(ref, 100)

	if err := usage.Flush(context.Background()); err == nil {
		t.Fatal("写库失败时应当返回错误")
	}
	if !usage.Pending() {
		t.Fatal("失败的那一批必须放回内存")
	}
	if calls := sink.callCount(); calls != 1 {
		t.Fatalf("失败只该尝试一次，实际 %d 次", calls)
	}

	// 重试成功：写进去的仍然是 100 字节 / 1 次连接，不多不少。
	sink.setError(nil)
	if err := usage.Flush(context.Background()); err != nil {
		t.Fatalf("第二次冲盘失败：%v", err)
	}
	if usage.Pending() {
		t.Fatal("成功之后账本应当清空")
	}
	written := sink.flatten()
	if len(written) != 1 || written[0].EgressBytes != 100 || written[0].Connections != 1 {
		t.Fatalf("写进库的内容 = %+v", written)
	}
	if written[0].Day != day {
		t.Fatalf("day = %d，期望 %d", written[0].Day, day)
	}

	// 空账本再冲一次是 no-op：AddUsage 是累加，重复写会把用量翻倍。
	if err := usage.Flush(context.Background()); err != nil {
		t.Fatalf("空账本冲盘错误 = %v", err)
	}
	if calls := sink.callCount(); calls != 2 {
		t.Fatalf("空账本不该再调仓储，实际调用 %d 次", calls)
	}
	if total := sink.totalEgress(); total != 100 {
		t.Fatalf("累计写入 = %d，期望 100", total)
	}
}

// totalEgress 是写成功的全部字节（断言"没有重复计数"）。
func (s *recordingSink) totalEgress() int64 {
	var total int64
	for _, entry := range s.flatten() {
		total += entry.EgressBytes
	}
	return total
}

// TestUsageLedgerKeepsBothSidesOfADayRollover：跨日前后的尾巴都要保留。
func TestUsageLedgerKeepsBothSidesOfADayRollover(t *testing.T) {
	day := int64(1_000_000)
	usage := NewUsage(nil, func() int64 { return day }, discardLogger())
	ref := DeviceRef{DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1"}
	usage.NoteEgress(ref, 100)
	day = 1_000_001
	usage.NoteEgress(ref, 50)

	entries := usage.Drain()
	if len(entries) != 2 {
		t.Fatalf("跨日的两条记录都必须保留：%+v", entries)
	}
	if entries[0].Day != 1_000_000 || entries[0].EgressBytes != 100 {
		t.Fatalf("前一天 = %+v", entries[0])
	}
	if entries[1].Day != 1_000_001 || entries[1].EgressBytes != 50 {
		t.Fatalf("当天 = %+v", entries[1])
	}
	if pending := usage.Pending(); pending {
		t.Fatal("Drain 之后账本应当是空的")
	}
}

// TestUsageLedgerMergesUnflushedBytesIntoToday：/stats 的 today = 库里那份 + 内存里那份。
func TestUsageLedgerMergesUnflushedBytesIntoToday(t *testing.T) {
	st := openTestStore(t)
	day := store.LocalDay()
	if _, err := st.AddUsage(context.Background(), []store.UsageEntry{{
		Day: day, DeviceID: "dev_a", AgentID: "agt_1", AccountID: "acc_1",
		EgressBytes: 100, Connections: 1, At: store.NowMS(),
	}}); err != nil {
		t.Fatalf("AddUsage: %v", err)
	}
	usage := NewUsage(st, func() int64 { return day }, discardLogger())
	first := DeviceRef{DeviceID: "dev_a", AgentID: "agt_1", AccountID: "acc_1"}
	second := DeviceRef{DeviceID: "dev_b", AgentID: "agt_1", AccountID: "acc_1"}
	usage.NoteConnection(first)
	usage.NoteEgress(first, 50)
	usage.NoteConnection(second)
	usage.NoteEgress(second, 30)
	usage.NoteBuild(first, "9.9.9")

	base, err := st.TodayUsage(context.Background(), day)
	if err != nil {
		t.Fatalf("TodayUsage: %v", err)
	}
	merged := usage.MergeToday(day, base)
	if merged.TotalEgressBytes != 180 {
		t.Fatalf("合计 = %d，期望 180", merged.TotalEgressBytes)
	}
	if len(merged.Devices) != 2 {
		t.Fatalf("设备行数 = %d", len(merged.Devices))
	}
	byID := map[string]store.TodayDevice{}
	for _, row := range merged.Devices {
		byID[row.DeviceID] = row
	}
	if byID["dev_a"].EgressBytes != 150 || byID["dev_a"].Connections != 2 {
		t.Fatalf("dev_a = %+v", byID["dev_a"])
	}
	if byID["dev_a"].LastBuild == nil || *byID["dev_a"].LastBuild != "9.9.9" {
		t.Fatalf("dev_a 的构建号 = %v", byID["dev_a"].LastBuild)
	}
	if len(merged.Accounts) != 1 || merged.Accounts[0].Devices != 2 ||
		merged.Accounts[0].EgressBytes != 180 {
		t.Fatalf("账户侧 = %+v", merged.Accounts)
	}

	// Snapshot 是冲盘入口：只有有内容的行。
	entries := usage.Snapshot()
	if len(entries) != 2 || entries[0].DeviceID != "dev_a" || entries[0].EgressBytes != 50 {
		t.Fatalf("Snapshot = %+v", entries)
	}

	// Today 走同一个口径（库 + 内存），hub 的 /stats 门面直接用它。
	today, err := usage.Today(context.Background())
	if err != nil {
		t.Fatalf("Today: %v", err)
	}
	if today.TotalEgressBytes != 180 {
		t.Fatalf("Today 合计 = %d，期望 180", today.TotalEgressBytes)
	}
}

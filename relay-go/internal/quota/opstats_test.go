package quota

import (
	"context"
	"sync"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

func usageCounts(entries []store.UsageEntry) map[string][2]int64 {
	out := map[string][2]int64{}
	for _, entry := range entries {
		out[entry.DeviceID] = [2]int64{entry.Prompts, entry.Answers}
	}
	return out
}

// TestNoteOpOnceDeduplicatesPerDeviceAndOp 钉住三件事：同设备同操作同指纹只计一次；
// prompt 与 answer 使用独立指纹表；不同设备互不影响。
func TestNoteOpOnceDeduplicatesPerDeviceAndOp(t *testing.T) {
	usage := NewUsage(nil, func() int64 { return 20261026 }, discardLogger())
	first := DeviceRef{DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1"}
	second := DeviceRef{DeviceID: "dev_2", AgentID: "agt_1", AccountID: "acc_1"}

	if !usage.NoteOpOnce(first, OpPrompt, 11) {
		t.Fatal("第一次 prompt 应当计数")
	}
	if usage.NoteOpOnce(first, OpPrompt, 11) {
		t.Fatal("同一 prompt 指纹不应重复计数")
	}
	if !usage.NoteOpOnce(first, OpAnswer, 11) {
		t.Fatal("同指纹的 answer 属于另一种操作，应当计数")
	}
	if !usage.NoteOpOnce(second, OpPrompt, 11) {
		t.Fatal("另一台设备的同指纹应当独立计数")
	}

	counts := usageCounts(usage.Snapshot())
	if counts["dev_1"] != [2]int64{1, 1} {
		t.Fatalf("dev_1 计数 = %v", counts["dev_1"])
	}
	if counts["dev_2"] != [2]int64{1, 0} {
		t.Fatalf("dev_2 计数 = %v", counts["dev_2"])
	}
	if usage.OpsSinceFlush() != 3 {
		t.Fatalf("OpsSinceFlush = %d，期望 3", usage.OpsSinceFlush())
	}

	usage.ForgetDevice("dev_1")
	if usage.seen.deviceCount() != 1 {
		t.Fatalf("ForgetDevice 后设备数 = %d，期望 1", usage.seen.deviceCount())
	}
	if !usage.NoteOpOnce(first, OpPrompt, 11) {
		t.Fatal("设备指纹表清空后同一指纹应当重新计数")
	}
}

// TestNoteOpDedupSurvivesDayRollover：跨日后迟到重发仍是同一次操作，不进入新一天。
func TestNoteOpDedupSurvivesDayRollover(t *testing.T) {
	day := int64(20261026)
	usage := NewUsage(nil, func() int64 { return day }, discardLogger())
	ref := DeviceRef{DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1"}

	if !usage.NoteOpOnce(ref, OpPrompt, 7) {
		t.Fatal("第一次应当计数")
	}
	day = 20261027
	if usage.NoteOpOnce(ref, OpPrompt, 7) {
		t.Fatal("跨日后的同一指纹不应再计数")
	}
	if entries := usage.Snapshot(); len(entries) != 1 || entries[0].Day != 20261026 {
		t.Fatalf("迟到重发不该创建新一天的行：%+v", entries)
	}
	if !usage.NoteOpOnce(ref, OpPrompt, 8) {
		t.Fatal("新指纹在跨日后应当计数到新一天")
	}
	entries := usage.Snapshot()
	if len(entries) != 2 || entries[1].Day != 20261027 {
		t.Fatalf("跨日后的新操作 = %+v", entries)
	}
}

// TestNoteOpFlushRestoresCountsExactlyOnce 钉住失败回放：计数随批次回放，不翻倍。
func TestNoteOpFlushRestoresCountsExactlyOnce(t *testing.T) {
	day := int64(20261026)
	sink := &recordingSink{err: context.DeadlineExceeded}
	usage := NewUsage(sink, func() int64 { return day }, discardLogger())
	ref := DeviceRef{DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1"}
	usage.NoteOpOnce(ref, OpPrompt, 1)
	usage.NoteOpOnce(ref, OpAnswer, 2)

	if err := usage.Flush(context.Background()); err == nil {
		t.Fatal("写库失败时应当返回错误")
	}
	if !usage.Pending() {
		t.Fatal("失败批次必须放回内存")
	}

	sink.setError(nil)
	if err := usage.Flush(context.Background()); err != nil {
		t.Fatalf("第二次冲盘失败：%v", err)
	}
	written := sink.flatten()
	if len(written) != 1 || written[0].Prompts != 1 || written[0].Answers != 1 {
		t.Fatalf("写库内容 = %+v，期望 prompts=1 answers=1", written)
	}
	if usage.Pending() || usage.OpsSinceFlush() != 0 {
		t.Fatalf("成功后账本应当清空：pending=%v ops=%d",
			usage.Pending(), usage.OpsSinceFlush())
	}
	if err := usage.Flush(context.Background()); err != nil {
		t.Fatalf("空账本冲盘：%v", err)
	}
	if calls := sink.callCount(); calls != 2 {
		t.Fatalf("空账本不该再调仓储，实际 %d 次", calls)
	}
}

// TestNoteOpOnceConcurrentDuplicatesCountOnce 覆盖同一指纹并发到达。
func TestNoteOpOnceConcurrentDuplicatesCountOnce(t *testing.T) {
	usage := NewUsage(nil, func() int64 { return 20261026 }, discardLogger())
	ref := DeviceRef{DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1"}
	const workers = 64
	var (
		start sync.WaitGroup
		done  sync.WaitGroup
		yes   int
		mu    sync.Mutex
	)
	start.Add(1)
	for index := 0; index < workers; index++ {
		done.Add(1)
		go func() {
			defer done.Done()
			start.Wait()
			if usage.NoteOpOnce(ref, OpPrompt, 42) {
				mu.Lock()
				yes++
				mu.Unlock()
			}
		}()
	}
	start.Done()
	done.Wait()
	if yes != 1 {
		t.Fatalf("并发同指纹计数了 %d 次，期望 1", yes)
	}
}

// TestNoteOpOnceHotPathDoesNotAllocate：重复键是风暴主路径，必须零分配。
func TestNoteOpOnceHotPathDoesNotAllocate(t *testing.T) {
	usage := NewUsage(nil, func() int64 { return 20261026 }, discardLogger())
	ref := DeviceRef{DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1"}
	if !usage.NoteOpOnce(ref, OpPrompt, 99) {
		t.Fatal("预热计数失败")
	}
	allocs := testing.AllocsPerRun(200, func() {
		if usage.NoteOpOnce(ref, OpPrompt, 99) {
			t.Fatal("重复键不应计数")
		}
	})
	if allocs != 0 {
		t.Fatalf("重复键路径分配了 %.2f 次/次", allocs)
	}
}

// TestNoteOpOnceRejectsUnknownOp：未知操作不写入账本，也不占去重表。
func TestNoteOpOnceRejectsUnknownOp(t *testing.T) {
	usage := NewUsage(nil, func() int64 { return 20261026 }, discardLogger())
	ref := DeviceRef{DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1"}
	if usage.NoteOpOnce(ref, Op(99), 1) {
		t.Fatal("未知操作不应计数")
	}
	if usage.Pending() {
		t.Fatal("未知操作不该留下账本行")
	}
}

// TestSeenRingEvictsOldest：槽满后覆盖最旧键；这是有界误差的固定行为。
func TestSeenRingEvictsOldest(t *testing.T) {
	var ring seenRing
	for index := 0; index < seenSlots; index++ {
		if !ring.add(uint64(index + 1)) {
			t.Fatalf("第 %d 个键不应重复", index)
		}
	}
	if ring.add(uint64(seenSlots+1)) != true {
		t.Fatal("新键在槽满后仍应接受")
	}
	if ring.add(1) != true {
		t.Fatal("最旧键已被挤出，重新出现时会被当成新键")
	}
}

// TestMergeTodayAddsOperationCounts：/stats 的 today = 库里已冲盘 + 内存未冲盘。
func TestMergeTodayAddsOperationCounts(t *testing.T) {
	st := openTestStore(t)
	day := store.LocalDay()
	if _, err := st.AddUsage(context.Background(), []store.UsageEntry{{
		Day: day, DeviceID: "dev_a", AgentID: "agt_1", AccountID: "acc_1",
		EgressBytes: 10, Connections: 1, Prompts: 2, Answers: 1, At: store.NowMS(),
	}}); err != nil {
		t.Fatalf("AddUsage: %v", err)
	}
	usage := NewUsage(st, func() int64 { return day }, discardLogger())
	ref := DeviceRef{DeviceID: "dev_a", AgentID: "agt_1", AccountID: "acc_1"}
	usage.NoteOpOnce(ref, OpPrompt, 100)
	usage.NoteOpOnce(ref, OpAnswer, 200)

	base, err := st.TodayUsage(context.Background(), day)
	if err != nil {
		t.Fatalf("TodayUsage: %v", err)
	}
	merged := usage.MergeToday(day, base)
	if merged.TotalPrompts != 3 || merged.TotalAnswers != 2 {
		t.Fatalf("merged totals = %d/%d，期望 3/2", merged.TotalPrompts, merged.TotalAnswers)
	}
	if len(merged.Devices) != 1 || merged.Devices[0].Prompts != 3 ||
		merged.Devices[0].Answers != 2 {
		t.Fatalf("merged devices = %+v", merged.Devices)
	}
}

// TestDuplicateStormCountsOnce：同一请求被重发风暴打满，计数仍是 1，账本只多一行。
func TestDuplicateStormCountsOnce(t *testing.T) {
	usage := NewUsage(nil, func() int64 { return 20261026 }, discardLogger())
	ref := DeviceRef{DeviceID: "dev_storm", AgentID: "agt_1", AccountID: "acc_1"}
	const attempts = 20000
	counted := 0
	for index := 0; index < attempts; index++ {
		if usage.NoteOpOnce(ref, OpPrompt, 12345) {
			counted++
		}
	}
	if counted != 1 {
		t.Fatalf("风暴中计数了 %d 次，期望 1", counted)
	}
	entries := usage.Snapshot()
	if len(entries) != 1 || entries[0].Prompts != 1 || entries[0].Answers != 0 {
		t.Fatalf("风暴后的账本 = %+v，期望一行 prompts=1", entries)
	}
	if usage.OpsSinceFlush() != 1 {
		t.Fatalf("OpsSinceFlush = %d，期望 1", usage.OpsSinceFlush())
	}
}

// TestSeenStorePrunesIdleDevices：长期没有操作的设备指纹表必须释放，避免随历史
// 设备数无限增长；仍活跃的设备保留。
func TestSeenStorePrunesIdleDevices(t *testing.T) {
	var seen seenStore
	seen.add("dev_old", OpPrompt, 1)
	seen.add("dev_new", OpPrompt, 2)
	now := store.NowMS()
	seen.devices["dev_old"].lastAt = now - seenMaxAgeMS - 1
	if removed := seen.prune(now, seenMaxAgeMS); removed != 1 {
		t.Fatalf("prune 删除 %d 台，期望 1", removed)
	}
	if seen.deviceCount() != 1 {
		t.Fatalf("剩余设备 = %d，期望 1", seen.deviceCount())
	}
	if !seen.add("dev_old", OpPrompt, 1) {
		t.Fatal("被清理的设备重新出现时应重新计数")
	}
}

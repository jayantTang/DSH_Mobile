package hub

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// TestTokenBucketPacesSustainedVolume：桶一开始是满的（普通一轮对话完全不等），
// 只有持续的大流量才开始等待；等待时长按超出的字节数算。
func TestTokenBucketPacesSustainedVolume(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	bucket := newTokenBucket(1000, now) // 1000 B/s，突发额度 64 KiB
	if wait := bucket.take(1000, now); wait != 0 {
		t.Fatalf("突发额度内的第一帧不该等待：%v", wait)
	}
	wait := bucket.take(64*1024, now)
	if wait < 900*time.Millisecond || wait > 1100*time.Millisecond {
		t.Fatalf("超出 1000 字节应等待约 1 秒，实际 %v", wait)
	}
	// 过 2 秒再取：桶按速率回填（上限是 burst），小帧不再等待。
	later := now.Add(2 * time.Second)
	if wait := bucket.take(1000, later); wait != 0 {
		t.Fatalf("回填后不该等待：%v", wait)
	}
}

// TestTokenBucketDisabledMeansNoWait：rate<=0 是"不限速"，任何大小都不等待。
func TestTokenBucketDisabledMeansNoWait(t *testing.T) {
	bucket := newTokenBucket(0, time.Now())
	if wait := bucket.take(32<<20, time.Now()); wait != 0 {
		t.Fatalf("不限速时不该等待：%v", wait)
	}
}

// TestQuotaLedgerChargesThenRefuses：先记账再判定——把额度撑爆的那一帧本身不算送达。
func TestQuotaLedgerChargesThenRefuses(t *testing.T) {
	day := int64(20261023)
	quota := newQuotaLedger(nil, 100, func() int64 { return day }, discardLogger())

	if allowed, used := quota.Charge("dev_1", 60); !allowed || used != 60 {
		t.Fatalf("第一次记账 = %v/%d", allowed, used)
	}
	if allowed, used := quota.Charge("dev_1", 60); allowed || used != 120 {
		t.Fatalf("超限那一帧应被拒：%v/%d", allowed, used)
	}
	if remaining := quota.Remaining("dev_1"); remaining != 0 {
		t.Fatalf("用光后剩余 = %d", remaining)
	}
	// 每台设备各有账本。
	if allowed, _ := quota.Charge("dev_2", 60); !allowed {
		t.Fatal("另一台设备不该受牵连")
	}
}

// TestQuotaLedgerResetsOnANewDay：本地日一变，额度重新开始（与 Python DailyQuota 一致）。
func TestQuotaLedgerResetsOnANewDay(t *testing.T) {
	day := int64(20261023)
	quota := newQuotaLedger(nil, 100, func() int64 { return day }, discardLogger())
	quota.Charge("dev_1", 200)
	if allowed, _ := quota.Charge("dev_1", 1); allowed {
		t.Fatal("当天额度应当已经用光")
	}
	day = 20261024
	if allowed, used := quota.Charge("dev_1", 50); !allowed || used != 50 {
		t.Fatalf("跨日后应重新开始：%v/%d", allowed, used)
	}
}

// TestQuotaLedgerSeedsFromStoredUsage：新进程/新连接要把库里已经用掉的算进基线。
func TestQuotaLedgerSeedsFromStoredUsage(t *testing.T) {
	st := openTestStore(t)
	day := store.LocalDay()
	if _, err := st.AddUsage(context.Background(), []store.UsageEntry{{
		Day: day, DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1",
		EgressBytes: 80, Connections: 1, At: store.NowMS(),
	}}); err != nil {
		t.Fatalf("AddUsage: %v", err)
	}
	quota := newQuotaLedger(st, 100, func() int64 { return day }, discardLogger())
	quota.Seat(context.Background(), "dev_1")
	if used := quota.Used("dev_1"); used != 80 {
		t.Fatalf("基线 = %d，期望 80", used)
	}
	if allowed, _ := quota.Charge("dev_1", 30); allowed {
		t.Fatal("基线之上再记 30 就该超限")
	}
	// Seat 幂等：第二次不该把基线再加一遍。
	quota.Seat(context.Background(), "dev_1")
	if used := quota.Used("dev_1"); used != 110 {
		t.Fatalf("Seat 不该重复累加：%d", used)
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
	ledger := newUsageLedger(func() int64 { return day }, discardLogger())
	first := &DeviceLink{DeviceID: "dev_a", AgentID: "agt_1", AccountID: "acc_1"}
	second := &DeviceLink{DeviceID: "dev_b", AgentID: "agt_1", AccountID: "acc_1"}
	ledger.NoteConnection(first)
	ledger.NoteEgress(first, 50)
	ledger.NoteConnection(second)
	ledger.NoteEgress(second, 30)
	ledger.NoteBuild(first, "9.9.9")

	base, err := st.TodayUsage(context.Background(), day)
	if err != nil {
		t.Fatalf("TodayUsage: %v", err)
	}
	merged := ledger.MergeToday(day, base)
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

	// Snapshot 是 M3 冲盘的入口：只有有内容的行。
	entries := ledger.Snapshot()
	if len(entries) != 2 || entries[0].DeviceID != "dev_a" || entries[0].EgressBytes != 50 {
		t.Fatalf("Snapshot = %+v", entries)
	}
}

// TestTruncateReasonKeepsUTF8：关闭原因上限 120 字节，且不能把一个汉字切成半个。
func TestTruncateReasonKeepsUTF8(t *testing.T) {
	reason := ""
	for index := 0; index < 100; index++ {
		reason += "中转"
	}
	truncated := truncateReason(reason)
	if len(truncated) > maxCloseReason {
		t.Fatalf("截断后仍然超长：%d", len(truncated))
	}
	if !utf8Valid(truncated) {
		t.Fatal("截断切坏了 UTF-8")
	}
	if short := "short"; truncateReason(short) != short {
		t.Fatal("短原因不该被改")
	}
}

// TestLimitsDescribeUsesNullForUnlimited：0 = 不限 → JSON null（Python 口径）。
func TestLimitsDescribeUsesNullForUnlimited(t *testing.T) {
	described := DefaultLimits().Describe()
	if described.MaxDevicesPerAgent != nil || described.DeviceDailyBytes != nil ||
		described.DeviceBytesPerSecond != nil {
		t.Fatalf("默认不限的项应为 null：%+v", described)
	}
	if described.MaxFrameBytes != dlp.MaxFrameBytes || described.QueueDepth != 512 ||
		described.AgentQueueDepth != 4096 {
		t.Fatalf("默认限额 = %+v", described)
	}
	if described.DeadDeviceWarnThreshold == nil || *described.DeadDeviceWarnThreshold != 200 {
		t.Fatalf("deadDeviceWarnThreshold = %v", described.DeadDeviceWarnThreshold)
	}

	limits := Limits{MaxDevicesPerAgent: 2, DeviceDailyBytes: 1024, QueueDepth: 8,
		AgentQueueDepth: 16, MaxFrameBytes: 4096, DeviceBytesPerSecond: 250}
	described = limits.Describe()
	if described.MaxDevicesPerAgent == nil || *described.MaxDevicesPerAgent != 2 {
		t.Fatalf("maxDevicesPerAgent = %v", described.MaxDevicesPerAgent)
	}
	if described.DeviceDailyBytes == nil || *described.DeviceDailyBytes != 1024 {
		t.Fatalf("deviceDailyBytes = %v", described.DeviceDailyBytes)
	}
	if described.DeviceBytesPerSecond == nil || *described.DeviceBytesPerSecond != 250 {
		t.Fatalf("deviceBytesPerSecond = %v", described.DeviceBytesPerSecond)
	}
}

// ── 小工具 ───────────────────────────────────────────────────────────────────

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func openTestStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(t.TempDir() + "/state.db")
	if err != nil {
		t.Fatalf("打开临时库: %v", err)
	}
	t.Cleanup(func() {
		if err := st.Close(); err != nil {
			t.Errorf("关闭临时库: %v", err)
		}
	})
	return st
}

// utf8Valid 只在用例里用：避免为了一个断言再引入 unicode/utf8 的别名。
func utf8Valid(text string) bool {
	return string([]rune(text)) == text
}

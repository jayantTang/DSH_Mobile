package opsreport

import (
	"context"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// TestUsageScanSplitsMessageCohortsByFirstUse 钉住“超 7 天回访”的定义：
// 不是“离开超过 7 天”，而是“首次使用设备距今超过 7 天，且今天仍有消息”。
//
//   - 首次使用设备在今天 -> 当日新增
//   - 首次使用设备在 7 天内 -> 7 天内回访
//   - 首次使用设备在 7 天以前 -> 超 7 天回访
func TestUsageScanSplitsMessageCohortsByFirstUse(t *testing.T) {
	makeRow := func(device, account string) store.UsageRow {
		return store.UsageRow{
			DeviceID: device, AgentID: "agt_1", AccountID: account,
			EgressBytes: 1, Connections: 1, Prompts: 1,
			FirstSeenAt: 1, LastSeenAt: 1,
		}
	}
	source := &fakeSource{usage: map[int64][]store.UsageRow{
		20261026: {
			makeRow("dev_new", "acc_new"),
			makeRow("dev_recent", "acc_recent"),
			makeRow("dev_old", "acc_old"),
			makeRow("dev_old_only", "acc_old_only"),
		},
	}}
	firstSeen := map[string]int64{
		"acc_new": 20261026, "acc_recent": 20261020,
		"acc_old": 20261010, "acc_old_only": 20261010,
	}

	known := map[string]struct{}{
		"dev_new": {}, "dev_recent": {}, "dev_old": {}, "dev_old_only": {},
	}
	names := map[string]*string{
		"acc_new": str("new"), "acc_recent": str("recent"),
		"acc_old": str("old"), "acc_old_only": str("old-only"),
	}
	series, ranked, activeSets, messageSets, err := usageScan(
		context.Background(), source, 2, at(20261026, 12, 0),
		nil, names, known, nil, firstSeen)
	if err != nil {
		t.Fatalf("usageScan: %v", err)
	}
	if len(series) != 2 {
		t.Fatalf("series 天数 = %d，期望 2", len(series))
	}
	last := series[len(series)-1]
	if last.Day != 20261026 {
		t.Fatalf("最后一天 = %d", last.Day)
	}
	if last.MessageAccounts != 4 || last.MessageNewAccounts != 1 ||
		last.MessageReturning7Accounts != 1 || last.MessageReturningOldAccounts != 2 {
		t.Fatalf("消息分层 = total:%d new:%d 7d:%d old:%d，期望 4/1/1/2",
			last.MessageAccounts, last.MessageNewAccounts,
			last.MessageReturning7Accounts, last.MessageReturningOldAccounts)
	}
	if last.MessageNewAccounts+last.MessageReturning7Accounts+
		last.MessageReturningOldAccounts != last.MessageAccounts {
		t.Fatalf("三层之和 != messageAccounts：%+v", last)
	}
	if last.Accounts != 4 || last.NewAccounts != 0 {
		// NewAccounts 由 buildUsageReport 按连接首次活跃填，不该在 usageScan 里重复算。
		t.Fatalf("usageScan accounts/new = %d/%d", last.Accounts, last.NewAccounts)
	}
	report := buildUsageReport(series, ranked, activeSets, messageSets, firstSeen)
	got := report.PerDay[len(report.PerDay)-1]
	if got.NewAccounts != 1 || got.ReturningAccounts != 3 {
		t.Fatalf("连接活跃 new/returning = %d/%d，期望 1/3",
			got.NewAccounts, got.ReturningAccounts)
	}
}

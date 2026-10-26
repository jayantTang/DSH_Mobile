package opsreport

import (
	"context"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// TestUsageScanSplitsActiveCohortsByFirstUse 钉住“超 7 天回访”的定义：
// 不是“离开超过 7 天”，也不是“今天发消息”；而是首次使用设备距今超过 7 天，
// 且今天仍活跃的账号。三档按首次使用日互斥。
func TestUsageScanSplitsActiveCohortsByFirstUse(t *testing.T) {
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
	last := series[len(series)-1]
	if last.Day != 20261026 {
		t.Fatalf("最后一天 = %d", last.Day)
	}
	if last.Accounts != 4 || last.Returning7Accounts != 1 || last.ReturningOldAccounts != 2 {
		t.Fatalf("活跃分层 = accounts:%d 7d:%d old:%d，期望 4/1/2",
			last.Accounts, last.Returning7Accounts, last.ReturningOldAccounts)
	}
	if last.NewAccounts != 0 {
		// NewAccounts 由 buildUsageReport 填，usageScan 里不应再算一份。
		t.Fatalf("usageScan NewAccounts = %d，期望 0", last.NewAccounts)
	}
	report := buildUsageReport(series, ranked, activeSets, messageSets, firstSeen)
	got := report.PerDay[len(report.PerDay)-1]
	if got.NewAccounts != 1 || got.ReturningAccounts != 3 {
		t.Fatalf("buildUsageReport new/returning = %d/%d，期望 1/3",
			got.NewAccounts, got.ReturningAccounts)
	}
	if got.Returning7Accounts+got.ReturningOldAccounts != got.ReturningAccounts {
		t.Fatalf("回访分层之和 = %d+%d，总数 = %d",
			got.Returning7Accounts, got.ReturningOldAccounts, got.ReturningAccounts)
	}
}

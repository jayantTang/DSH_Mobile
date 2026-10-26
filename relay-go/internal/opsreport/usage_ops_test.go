package opsreport

import (
	"context"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// TestUsageScanSplitsReturningBySevenDays 钉住三层口径：
//   - D 当天首次活跃 -> 新增（由 buildUsageReport 计）
//   - D-7..D-1 活跃过 -> 7 天内回访
//   - 更早或窗口前活跃 -> 超 7 天回访
func TestUsageScanSplitsReturningBySevenDays(t *testing.T) {
	makeRow := func(device, account string) store.UsageRow {
		return store.UsageRow{
			DeviceID: device, AgentID: "agt_1", AccountID: account,
			EgressBytes: 1, Connections: 1, Prompts: 1,
			FirstSeenAt: 1, LastSeenAt: 1,
		}
	}
	source := &fakeSource{usage: map[int64][]store.UsageRow{
		20261010: {{DeviceID: "dev_old", AgentID: "agt_1", AccountID: "acc_old",
			EgressBytes: 1, Connections: 1, Prompts: 1}},
		20261020: {{DeviceID: "dev_recent", AgentID: "agt_1", AccountID: "acc_recent",
			EgressBytes: 1, Connections: 1, Prompts: 1}},
		20261026: {
			makeRow("dev_new", "acc_new"),
			makeRow("dev_recent", "acc_recent"),
			makeRow("dev_old", "acc_old"),
			makeRow("dev_old_only", "acc_old_only"),
		},
	}}
	firstSeen := map[string]int64{
		"acc_new": 20261026, "acc_recent": 20261001,
		"acc_old": 20261001, "acc_old_only": 20261001,
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
	if last.Returning7Accounts != 1 || last.ReturningOldAccounts != 2 {
		t.Fatalf("回访拆分 = 7d:%d old:%d，期望 1/2",
			last.Returning7Accounts, last.ReturningOldAccounts)
	}
	if last.Accounts != 4 || last.NewAccounts != 0 {
		// NewAccounts 由 buildUsageReport 填；usageScan 里应仍为 0，避免两处各算一份。
		t.Fatalf("usageScan accounts/new = %d/%d", last.Accounts, last.NewAccounts)
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

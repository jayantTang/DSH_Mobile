package store

import (
	"context"
	"path/filepath"
	"testing"
)

func openUsageStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() {
		if err := s.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return s
}

// TestAddUsageAccumulatesOperationCounts 钉住 UPSERT 的累加语义：同一设备同一天
// 写两次，消息/作答必须相加，不能被第二次覆盖。
func TestAddUsageAccumulatesOperationCounts(t *testing.T) {
	s := openUsageStore(t)
	ctx := context.Background()
	day := LocalDay()
	entry := UsageEntry{
		Day: day, DeviceID: "dev_ops", AgentID: "agt_1", AccountID: "acc_1",
		EgressBytes: 100, Connections: 1, Prompts: 2, Answers: 1, At: NowMS(),
	}
	if _, err := s.AddUsage(ctx, []UsageEntry{entry}); err != nil {
		t.Fatalf("AddUsage first: %v", err)
	}
	entry.EgressBytes = 50
	entry.Prompts = 3
	entry.Answers = 4
	if _, err := s.AddUsage(ctx, []UsageEntry{entry}); err != nil {
		t.Fatalf("AddUsage second: %v", err)
	}

	rows, err := s.UsageRows(ctx, day)
	if err != nil {
		t.Fatalf("UsageRows: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("rows = %+v", rows)
	}
	row := rows[0]
	if row.Prompts != 5 || row.Answers != 5 {
		t.Fatalf("prompts/answers = %d/%d，期望 5/5", row.Prompts, row.Answers)
	}
	if row.EgressBytes != 150 || row.Connections != 2 {
		t.Fatalf("egress/connections = %d/%d，期望 150/2", row.EgressBytes, row.Connections)
	}
}

// TestUsageTotalsSumsOperationCounts 钉住按账号求和、按设备分行两条口径。
func TestUsageTotalsSumsOperationCounts(t *testing.T) {
	s := openUsageStore(t)
	ctx := context.Background()
	day := LocalDay()
	if _, err := s.AddUsage(ctx, []UsageEntry{
		{Day: day, DeviceID: "dev_a", AgentID: "agt_1", AccountID: "acc_1",
			EgressBytes: 10, Connections: 1, Prompts: 2, Answers: 1, At: NowMS()},
		{Day: day, DeviceID: "dev_b", AgentID: "agt_1", AccountID: "acc_1",
			EgressBytes: 20, Connections: 1, Prompts: 3, Answers: 4, At: NowMS()},
	}); err != nil {
		t.Fatalf("AddUsage: %v", err)
	}

	accounts, err := s.UsageTotals(ctx, 1, "account")
	if err != nil {
		t.Fatalf("UsageTotals account: %v", err)
	}
	if len(accounts) != 1 {
		t.Fatalf("账号汇总 = %+v", accounts)
	}
	if accounts[0].Prompts != 5 || accounts[0].Answers != 5 || accounts[0].Devices != 2 {
		t.Fatalf("账号汇总 = %+v", accounts[0])
	}

	devices, err := s.UsageTotals(ctx, 1, "device")
	if err != nil {
		t.Fatalf("UsageTotals device: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("设备汇总 = %+v", devices)
	}
	byID := map[string]UsageTotal{}
	for _, row := range devices {
		byID[*row.DeviceID] = row
	}
	if byID["dev_a"].Prompts != 2 || byID["dev_b"].Answers != 4 {
		t.Fatalf("设备汇总 = %+v", devices)
	}
}

// TestTodayUsageAggregatesOperationCounts 钉住 /stats 的 today 形状：设备行与合计
// 都要带上计数。
func TestTodayUsageAggregatesOperationCounts(t *testing.T) {
	s := openUsageStore(t)
	ctx := context.Background()
	day := LocalDay()
	if _, err := s.AddUsage(ctx, []UsageEntry{
		{Day: day, DeviceID: "dev_a", AgentID: "agt_1", AccountID: "acc_1",
			EgressBytes: 10, Connections: 1, Prompts: 2, Answers: 1, At: NowMS()},
		{Day: day, DeviceID: "dev_b", AgentID: "agt_1", AccountID: "acc_2",
			EgressBytes: 20, Connections: 1, Prompts: 3, Answers: 4, At: NowMS()},
	}); err != nil {
		t.Fatalf("AddUsage: %v", err)
	}
	today, err := s.TodayUsage(ctx, day)
	if err != nil {
		t.Fatalf("TodayUsage: %v", err)
	}
	if today.TotalPrompts != 5 || today.TotalAnswers != 5 {
		t.Fatalf("today totals = %d/%d，期望 5/5", today.TotalPrompts, today.TotalAnswers)
	}
	if len(today.Devices) != 2 {
		t.Fatalf("today devices = %+v", today.Devices)
	}
	byID := map[string]TodayDevice{}
	for _, row := range today.Devices {
		byID[row.DeviceID] = row
	}
	if byID["dev_a"].Prompts != 2 || byID["dev_b"].Answers != 4 {
		t.Fatalf("today rows = %+v", today.Devices)
	}
}

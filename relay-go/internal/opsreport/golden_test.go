package opsreport

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 报告里的绝对毫秒来自本地时区；golden 要跨机器稳定，本包的测试统一按 +0800
// 解释本地日。生产路径不受影响（那里用进程自己的 time.Local）。
func TestMain(m *testing.M) {
	time.Local = time.FixedZone("CST", 8*3600)
	os.Exit(m.Run())
}

var updateGolden = flag.Bool("update-golden", false, "重写 opsreport 的 golden 文件")

func at(day int64, hour, minute int) int64 {
	return time.Date(int(day/10000), time.Month(day/100%100), int(day%100),
		hour, minute, 0, 0, time.Local).UnixMilli()
}

func i64(value int64) *int64   { return &value }
func str(value string) *string { return &value }

// richSource 是一份覆盖全部板块的固定输入；golden 用它钉住字段名、键序与缩进。
func richSource() *fakeSource {
	accounts := []store.Account{
		{AccountID: "acc_alpha", Name: "alpha", CreatedAt: at(20260920, 8, 0)},
		{AccountID: "acc_beta", Name: "beta", CreatedAt: at(20261005, 8, 0)},
		{AccountID: "acc_test", Name: "DSH-tester", CreatedAt: at(20261001, 8, 0)},
	}
	agents := []store.Agent{
		{AgentID: "agt_mac", AccountID: "acc_alpha", Name: "mac",
			ConnectorVersion: str("0.4.1"), HostVersion: str("1.2.3"),
			VersionsAt: i64(at(20261020, 9, 0))},
		{AgentID: "agt_beta", AccountID: "acc_beta", Name: "beta-mac"},
		{AgentID: "agt_debug", AccountID: "acc_test", Name: "DSH-debug"},
	}
	devices := []store.Device{
		{DeviceID: "dev_one", DeviceTokenHash: "hash-one-0123456789",
			AgentID: "agt_mac", AccountID: "acc_alpha", Name: "Alpha iPhone",
			Model: str("iPhone17,1"), AppVersion: str("20261023.1200"),
			CreatedAt: at(20261020, 8, 0), ExpiresAt: at(20271020, 8, 0),
			LastSeenAt: i64(at(20261025, 9, 0)),
			APNSToken:  str("abcdef0123456789"), APNSEnv: str("production"),
			PushTurnEnd: 1, PushAttention: 1, PushUpdatedAt: i64(at(20261025, 9, 0)),
			DeviceKey: str("phone-key")},
		{DeviceID: "dev_two", DeviceTokenHash: "hash-two-0123456789",
			AgentID: "agt_mac", AccountID: "acc_alpha", Name: "Alpha iPad",
			Model: str("iPhone16,2"), AppVersion: str("20261020.0900"),
			CreatedAt: at(20261021, 8, 0), ExpiresAt: at(20271021, 8, 0),
			LastSeenAt: i64(at(20261024, 20, 0))},
		{DeviceID: "dev_beta", DeviceTokenHash: "hash-beta-0123456789",
			AgentID: "agt_beta", AccountID: "acc_beta", Name: "Beta iPhone",
			Model: str("iPhone15,3"), AppVersion: str("20261006.0100"),
			CreatedAt: at(20261005, 8, 0), ExpiresAt: at(20271005, 8, 0),
			LastSeenAt: i64(at(20261025, 8, 30))},
		{DeviceID: "dev_gone", DeviceTokenHash: "hash-gone-0123456789",
			AgentID: "agt_mac", AccountID: "acc_alpha", Name: "Old Phone",
			Model: str("iPhone14,2"), AppVersion: str("20261001.0100"),
			CreatedAt: at(20261001, 8, 0), ExpiresAt: at(20271001, 8, 0),
			RevokedAt: i64(at(20261023, 12, 0))},
		{DeviceID: "dev_debug", DeviceTokenHash: "hash-debug-0123456789",
			AgentID: "agt_debug", AccountID: "acc_test", Name: "DSH-Test",
			Model: str("simulator"), CreatedAt: at(20261022, 8, 0),
			ExpiresAt: at(20271022, 8, 0)},
	}

	usage := map[int64][]store.UsageRow{}
	alphaDays := []int64{
		20260928, 20260930, 20261001,
		20261018, 20261019, 20261020, 20261021, 20261022, 20261023, 20261024,
		20261025,
	}
	for index, day := range alphaDays {
		atMS := at(day, 10, 0)
		usage[day] = append(usage[day], store.UsageRow{
			Day: day, DeviceID: "dev_one", AgentID: "agt_mac", AccountID: "acc_alpha",
			EgressBytes: int64(1000 * (index + 1)), Connections: int64(index + 2),
			FirstSeenAt: atMS, LastSeenAt: atMS, LastBuild: str("20261023.1200"),
		})
		if day >= 20261020 {
			usage[day] = append(usage[day], store.UsageRow{
				Day: day, DeviceID: "dev_two", AgentID: "agt_mac", AccountID: "acc_alpha",
				EgressBytes: int64(300 * (index + 1)), Connections: int64(index + 1),
				FirstSeenAt: atMS, LastSeenAt: atMS, LastBuild: str("20261020.0900"),
			})
		}
	}
	for _, day := range []int64{20261006, 20261020, 20261024, 20261025} {
		atMS := at(day, 8, 30)
		usage[day] = append(usage[day], store.UsageRow{
			Day: day, DeviceID: "dev_beta", AgentID: "agt_beta", AccountID: "acc_beta",
			EgressBytes: 700, Connections: 1,
			FirstSeenAt: atMS, LastSeenAt: atMS, LastBuild: str("20261006.0100"),
		})
	}

	threads := []store.FeedbackThread{
		{ThreadID: "th_alpha", Subject: str("无法连接中转"), CreatedAt: at(20261020, 10, 0),
			LastMessageAt: at(20261021, 15, 0), Status: "replied",
			AccountID: str("acc_alpha"), DeviceID: str("dev_one"),
			AppVersion: str("20261023.1200"), DeviceModel: str("iPhone17,1"),
			SystemVersion: str("iOS 18.2"), MessageCount: 2},
		{ThreadID: "th_open", CreatedAt: at(20261022, 9, 0),
			LastMessageAt: at(20261022, 9, 0), Status: "open",
			DeviceModel: str("iPad14,1"), MessageCount: 1},
		{ThreadID: "th_sim", CreatedAt: at(20261021, 7, 0),
			LastMessageAt: at(20261021, 7, 0), Status: "open",
			DeviceModel: str("simulator"), MessageCount: 1},
		{ThreadID: "th_debugdev", CreatedAt: at(20261021, 8, 0),
			LastMessageAt: at(20261021, 8, 0), Status: "open",
			DeviceID: str("dev_debug"), MessageCount: 1},
		{ThreadID: "th_old", CreatedAt: at(20260801, 9, 0),
			LastMessageAt: at(20260801, 9, 0), Status: "open", MessageCount: 1},
		{ThreadID: "th_future", CreatedAt: at(20261026, 1, 0),
			LastMessageAt: at(20261026, 1, 0), Status: "open", MessageCount: 1},
		{ThreadID: "th_today", Subject: str("今天的问题"), CreatedAt: at(20261025, 8, 0),
			LastMessageAt: at(20261025, 8, 0), Status: "open",
			AccountID: str("acc_beta"), DeviceID: str("dev_beta"),
			DeviceModel: str("iPhone15,3"), MessageCount: 1},
	}
	digest := map[string]store.FeedbackDigestEntry{
		"th_alpha": {Subject: str("无法连接中转"), Excerpt: "连接一直失败，重装了也没有用，麻烦看一下。",
			Format: "text", FirstReplyAt: i64(at(20261021, 15, 0))},
		"th_open":     {Excerpt: "打开 App 之后一直是灰色的。", Format: "html"},
		"th_sim":      {Excerpt: "测试台来源", Format: "text"},
		"th_old":      {Excerpt: "很早以前的一封信", Format: "text"},
		"th_future":   {Excerpt: "锚点之后才创建", Format: "text"},
		"th_today":    {Excerpt: "今天的问题", Format: "text"},
		"th_debugdev": {Excerpt: "调试设备", Format: "text"},
	}
	unread := map[string]int{"th_alpha": 2, "th_open": 1}

	invites := []store.Invite{
		{CodeHash: "hash-a", CreatedAt: at(20261001, 8, 0), ExpiresAt: at(20261008, 8, 0),
			UsedAt: i64(at(20261005, 8, 0)), Note: str("bob")},
		{CodeHash: "hash-b", CreatedAt: at(20261020, 8, 0), ExpiresAt: at(20261028, 8, 0),
			Note: str("soon")},
		{CodeHash: "hash-c", CreatedAt: at(20261020, 8, 0), ExpiresAt: at(20261110, 8, 0),
			Note: str("later")},
		{CodeHash: "hash-d", CreatedAt: at(20261001, 8, 0), ExpiresAt: at(20261015, 8, 0),
			Note: str("gone")},
	}
	enrollments := []store.Enrollment{
		{UsedAt: at(20261005, 8, 0), InviteNote: str("bob"), AccountID: "acc_beta",
			AccountName: str("beta"), AgentID: "agt_beta", AgentName: "beta-mac",
			Devices: 1, LastSeenAt: i64(at(20261025, 8, 30))},
		{UsedAt: at(20261025, 10, 0), InviteNote: str("later"), AccountID: "acc_beta",
			AccountName: str("beta"), AgentID: "agt_beta", AgentName: "beta-mac",
			Devices: 1, LastSeenAt: i64(at(20261025, 8, 30))},
		{UsedAt: at(20261005, 8, 0), AccountID: "acc_test",
			AccountName: str("DSH-tester"), AgentID: "agt_debug", AgentName: "DSH-debug",
			Devices: 1},
	}
	return &fakeSource{
		devices: devices, agents: agents, accounts: accounts,
		invites: invites, enrollments: enrollments, usage: usage,
		totals: usageTotalRows(usage), unread: unread, threads: threads, digest: digest,
	}
}

// journalLines 是固定的 systemd 日志：两台设备一进一出，覆盖 buckets 的非零段。
func journalLines(string, int64, int64) ([]string, bool) {
	return []string{
		"2026-10-24T09:00:00+0800 host dsh-relay[1]: device dev_one attached to agent agt_mac",
		"2026-10-24T11:30:00+0800 host dsh-relay[1]: device dev_one detached",
		"2026-10-25T08:00:00+0800 host dsh-relay[1]: device dev_beta attached to agent agt_beta",
		"2026-10-25T09:00:00+0800 host dsh-relay[1]: device dev_beta detached",
	}, true
}

func richOptions() Options {
	return Options{
		Days: 30, AsOfStamp: at(20261026, 0, 0) - 1,
		GeneratedAt: at(20261025, 23, 0), JournalUnit: "dsh-relay",
		Journal: journalLines,
	}
}

func encodeReport(t *testing.T, value any) []byte {
	t.Helper()
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		t.Fatalf("编码报告: %v", err)
	}
	return buffer.Bytes()
}

// TestOpsReportGolden 钉住整份 JSON：字段名、键序、缩进、转义与各板块的数值。
func TestOpsReportGolden(t *testing.T) {
	report, err := Report(context.Background(), richSource(), richOptions())
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	got := encodeReport(t, report)
	path := filepath.Join("testdata", "opsreport.golden.json")
	if *updateGolden {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatalf("建 testdata: %v", err)
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatalf("写 golden: %v", err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读 golden（首次请跑 go test ./internal/opsreport -update-golden）: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("ops-report 输出与 golden 不一致\n--- got ---\n%s\n--- want ---\n%s",
			truncate(got), truncate(want))
	}
}

func truncate(value []byte) string {
	const limit = 4000
	if len(value) <= limit {
		return string(value)
	}
	return string(value[:limit]) + "\n…（截断）"
}

// TestOpsReportWithoutJournalKeepsBucketsNull：取不到日志时不编数字。
func TestOpsReportWithoutJournalKeepsBucketsNull(t *testing.T) {
	options := richOptions()
	options.Journal = nil
	report, err := Report(context.Background(), richSource(), options)
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	output, ok := report.(opsReport)
	if !ok {
		t.Fatalf("Report 返回 %T", report)
	}
	if output.HourlyActivity.Buckets != nil {
		t.Fatalf("没有日志时 buckets 应为 nil，得到 %v", output.HourlyActivity.Buckets)
	}
	encoded := string(encodeReport(t, report))
	if !bytes.Contains([]byte(encoded), []byte(`"buckets": null`)) {
		t.Fatalf("JSON 里 buckets 应为 null：%s", encoded[:200])
	}
}

// TestOpsReportEmptySource 是空库边界：不 panic、结构齐全、数组是 [] 不是 null。
func TestOpsReportEmptySource(t *testing.T) {
	options := Options{AsOfStamp: at(20261022, 12, 0), GeneratedAt: at(20261022, 12, 0),
		JournalUnit: "dsh-relay"}
	report, err := Report(context.Background(), &fakeSource{usage: map[int64][]store.UsageRow{}},
		options)
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	output := report.(opsReport)
	if output.Days != 1 {
		t.Fatalf("Days 0 应归一化成 1，得到 %d", output.Days)
	}
	if output.HourlyActivity.Buckets != nil {
		t.Fatalf("空库应没有 buckets")
	}
	if output.Versions == nil || output.Devices.List == nil || output.Devices.NewPerDay == nil ||
		output.Usage.PerDay == nil || output.Usage.TopAccounts == nil ||
		output.Feedback.Threads == nil || output.Retention.Weeks == nil ||
		output.Invites.Unused == nil || output.Invites.Enrollments == nil ||
		output.Today.TopAccounts == nil || output.Today.Devices.List == nil ||
		output.Today.Feedback.Threads == nil || output.Today.Invites.Enrollments == nil {
		t.Fatalf("空库的数组必须是 []，不能是 nil：%+v", output)
	}
	if output.Retention.Scope != "external" || output.Days != 1 {
		t.Fatalf("空库的留存/窗口不对：%+v", output.Retention)
	}
}

// TestOpsReportCrossesMonthBoundary：窗口跨月时按日历日展开，不生成 20260931。
func TestOpsReportCrossesMonthBoundary(t *testing.T) {
	source := &fakeSource{
		devices: []store.Device{{DeviceID: "dev_x", AccountID: "acc_x",
			CreatedAt: at(20260901, 8, 0), ExpiresAt: at(20270901, 8, 0)}},
		usage: map[int64][]store.UsageRow{
			20260929: {{Day: 20260929, DeviceID: "dev_x", AccountID: "acc_x",
				EgressBytes: 10, Connections: 1, FirstSeenAt: at(20260929, 9, 0),
				LastSeenAt: at(20260929, 9, 0)}},
			20261002: {{Day: 20261002, DeviceID: "dev_x", AccountID: "acc_x",
				EgressBytes: 20, Connections: 2, FirstSeenAt: at(20261002, 9, 0),
				LastSeenAt: at(20261002, 9, 0)}},
		}}
	options := Options{Days: 10, AsOfStamp: at(20261003, 12, 0),
		GeneratedAt: at(20261003, 12, 0), JournalUnit: "dsh-relay"}
	report, err := Report(context.Background(), source, options)
	if err != nil {
		t.Fatalf("Report: %v", err)
	}
	output := report.(opsReport)
	want := []int64{20260924, 20260925, 20260926, 20260927, 20260928,
		20260929, 20260930, 20261001, 20261002, 20261003}
	if len(output.Usage.PerDay) != len(want) {
		t.Fatalf("perDay 天数 = %d，期望 %d", len(output.Usage.PerDay), len(want))
	}
	for index, entry := range output.Usage.PerDay {
		if entry.Day != want[index] {
			t.Fatalf("perDay[%d] = %d，期望 %d", index, entry.Day, want[index])
		}
	}
	if output.Usage.PerDay[5].EgressBytes != 10 || output.Usage.PerDay[8].EgressBytes != 20 {
		t.Fatalf("跨月窗口的用量落错天：%+v", output.Usage.PerDay)
	}
}

// TestResolveAsOf 钉住三种锚点语义。
func TestResolveAsOf(t *testing.T) {
	now := at(20261023, 15, 0)
	if stamp, err := ResolveAsOf("now", now); err != nil || stamp != now {
		t.Fatalf("now: %d %v", stamp, err)
	}
	yesterday, err := ResolveAsOf("yesterday", now)
	if err != nil || yesterday != at(20261023, 0, 0)-1 {
		t.Fatalf("yesterday: %d %v", yesterday, err)
	}
	day, err := ResolveAsOf("2026-10-01", now)
	if err != nil || day != at(20261002, 0, 0)-1 {
		t.Fatalf("YYYY-MM-DD: %d %v", day, err)
	}
	if _, err := ResolveAsOf("2026-13-40", now); err == nil {
		t.Fatal("非法日期应报错")
	}
}

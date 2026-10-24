package admincli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/monitor"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/push"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// runAdminEnv 与 runAdmin 相同，但可以注入环境变量（阈值与 APNs 配置都走 env）。
func runAdminEnv(dbPath string, env map[string]string, args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	full := append([]string{"--db", dbPath}, args...)
	code := Main(full, func(name string) string { return env[name] }, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

// seeded 是一套"账户 + 电脑 + 已配对设备"。
type seeded struct {
	account     store.Account
	agent       store.Agent
	device      store.Device
	deviceToken string
}

// seedTenant 经仓储层建账户、电脑与设备（与 admin 子命令走同一个库）。
func seedTenant(t *testing.T, dbPath string) seeded {
	t.Helper()
	ctx := context.Background()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer st.Close()
	account, err := st.CreateAccount(ctx, "ops")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	agent, _, err := st.RegisterAgent(ctx, account.AccountID, "mac", nil)
	if err != nil {
		t.Fatalf("RegisterAgent: %v", err)
	}
	minted, err := st.MintPairCode(ctx, agent.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	claimed, err := st.ClaimPairCode(ctx, minted.Code, store.ClaimParams{
		DeviceName: "iPhone", MaxPairedDevices: 8, TTLMS: store.DefaultDeviceTTLMS,
	})
	if err != nil {
		t.Fatalf("ClaimPairCode: %v", err)
	}
	device, found, err := st.DeviceByID(ctx, claimed.DeviceID)
	if err != nil || !found {
		t.Fatalf("DeviceByID: found=%v err=%v", found, err)
	}
	return seeded{account: account, agent: agent, device: device, deviceToken: claimed.DeviceToken}
}

func decodeList(t *testing.T, text string) []map[string]any {
	t.Helper()
	var rows []map[string]any
	if err := json.Unmarshal([]byte(text), &rows); err != nil {
		t.Fatalf("输出不是 JSON 数组: %v (%q)", err, text)
	}
	return rows
}

// ── 账户 / 电脑 / 邀请码 ───────────────────────────────────────────────────

func TestAccountListAgentListAndToggles(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)

	code, out, errOut := runAdmin(dbPath, "account-list")
	if code != 0 {
		t.Fatalf("account-list 退出码 = %d, stderr = %s", code, errOut)
	}
	accounts := decodeList(t, out)
	if len(accounts) != 1 || accounts[0]["name"] != "ops" {
		t.Fatalf("account-list = %v", accounts)
	}

	code, out, errOut = runAdmin(dbPath, "agent-list")
	if code != 0 {
		t.Fatalf("agent-list 退出码 = %d, stderr = %s", code, errOut)
	}
	agents := decodeList(t, out)
	if len(agents) != 1 || !strings.HasSuffix(agents[0]["secretHash"].(string), "…") {
		t.Fatalf("agent-list = %v", agents)
	}

	code, out, errOut = runAdmin(dbPath, "agent-disable", "--agent", seed.agent.AgentID)
	if code != 0 {
		t.Fatalf("agent-disable 退出码 = %d, stderr = %s", code, errOut)
	}
	disabled := decodeOutput(t, out)
	if disabled["ok"] != true || disabled["disabled"] != true ||
		disabled["agentId"] != seed.agent.AgentID {
		t.Fatalf("agent-disable = %v", disabled)
	}
	code, out, _ = runAdmin(dbPath, "agent-enable", "--agent", seed.agent.AgentID)
	if code != 0 || decodeOutput(t, out)["disabled"] != false {
		t.Fatalf("agent-enable = %v", out)
	}

	code, out, errOut = runAdmin(dbPath, "agent-rotate", "--agent", seed.agent.AgentID)
	if code != 0 {
		t.Fatalf("agent-rotate 退出码 = %d, stderr = %s", code, errOut)
	}
	rotated := decodeOutput(t, out)
	if rotated["agentId"] != seed.agent.AgentID || rotated["accountId"] != seed.account.AccountID {
		t.Fatalf("agent-rotate = %v", rotated)
	}
	if _, present := rotated["rotated"]; present {
		t.Fatalf("agent-rotate 不该带 rotated 字段：%v", rotated)
	}
	if !strings.HasPrefix(rotated["agentSecret"].(string), "as_") {
		t.Fatalf("agentSecret = %v", rotated["agentSecret"])
	}
}

func TestInviteListRevokeAndCheck(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	code, out, errOut := runAdmin(dbPath, "invite-mint", "--note", "给 Sam")
	if code != 0 {
		t.Fatalf("invite-mint 退出码 = %d, stderr = %s", code, errOut)
	}
	invite := decodeOutput(t, out)
	inviteCode := invite["code"].(string)

	code, out, errOut = runAdmin(dbPath, "invite-list")
	if code != 0 {
		t.Fatalf("invite-list 退出码 = %d, stderr = %s", code, errOut)
	}
	rows := decodeList(t, out)
	if len(rows) != 1 {
		t.Fatalf("invite-list = %v", rows)
	}
	row := rows[0]
	if row["note"] != "给 Sam" || !strings.HasSuffix(row["codeHash"].(string), "…") {
		t.Fatalf("invite-list 行 = %v", row)
	}
	if row["expiresInSeconds"].(float64) <= 0 {
		t.Fatalf("expiresInSeconds = %v", row["expiresInSeconds"])
	}
	if row["usedAt"] != nil || row["usedByAgentId"] != nil {
		t.Fatalf("未使用的码不该有 used 字段：%v", row)
	}

	code, out, errOut = runAdmin(dbPath, "invite-check", "--code", inviteCode)
	if code != 0 {
		t.Fatalf("invite-check 退出码 = %d, stderr = %s", code, errOut)
	}
	checked := decodeList(t, out)
	if len(checked) != 1 || checked[0]["state"] != "unused" || checked[0]["code"] != inviteCode {
		t.Fatalf("invite-check = %v", checked)
	}

	code, out, errOut = runAdmin(dbPath, "invite-revoke", "--code", inviteCode)
	if code != 0 {
		t.Fatalf("invite-revoke 退出码 = %d, stderr = %s", code, errOut)
	}
	revoked := decodeOutput(t, out)
	if revoked["revoked"] != true || len(revoked["codeHash"].(string)) != 12 {
		t.Fatalf("invite-revoke = %v", revoked)
	}

	// 再作废一次：打印 JSON 并退出码 1，不额外打 stderr。
	code, out, errOut = runAdmin(dbPath, "invite-revoke", "--code", inviteCode)
	if code != 1 || errOut != "" {
		t.Fatalf("第二次作废退出码 = %d, stderr = %q", code, errOut)
	}
	if payload := decodeOutput(t, out); payload["revoked"] != false ||
		payload["reason"] != "already-expired" {
		t.Fatalf("第二次作废 = %v", payload)
	}
}

func TestEnrollmentsJoinInWhoTookAnInvite(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	ctx := context.Background()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	minted, err := st.MintInvite(ctx, store.DefaultInviteTTLMS, stringPtr("试用"), "")
	if err != nil {
		t.Fatalf("MintInvite: %v", err)
	}
	if _, err := st.ClaimInvite(ctx, minted.Code, "Sam 的电脑", nil, "", ""); err != nil {
		t.Fatalf("ClaimInvite: %v", err)
	}
	_ = st.Close()

	code, out, errOut := runAdmin(dbPath, "enrollments")
	if code != 0 {
		t.Fatalf("enrollments 退出码 = %d, stderr = %s", code, errOut)
	}
	payload := decodeOutput(t, out)
	totals := payload["totals"].(map[string]any)
	if totals["minted"] != float64(1) || totals["used"] != float64(1) ||
		totals["remaining"] != float64(0) {
		t.Fatalf("totals = %v", totals)
	}
	rows := payload["enrollments"].([]any)
	if len(rows) != 1 {
		t.Fatalf("enrollments = %v", rows)
	}
	row := rows[0].(map[string]any)
	if row["agentName"] != "Sam 的电脑" || row["inviteNote"] != "试用" {
		t.Fatalf("enrollment = %v", row)
	}
}

// ── 设备 ───────────────────────────────────────────────────────────────────

func TestDeviceRevokePrintsExactlyTheNewContract(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)

	code, out, errOut := runAdmin(dbPath, "device-revoke", "--device", seed.device.DeviceID)
	if code != 0 {
		t.Fatalf("device-revoke 退出码 = %d, stderr = %s", code, errOut)
	}
	payload := decodeOutput(t, out)
	want := map[string]any{
		"ok": true, "deviceId": seed.device.DeviceID, "revoked": true,
		"detach": "relay-reconcile",
	}
	for key, value := range want {
		if payload[key] != value {
			t.Fatalf("device-revoke = %v", payload)
		}
	}
	if len(payload) != len(want) {
		t.Fatalf("device-revoke 多出字段：%v", payload)
	}

	// 已撤销的令牌：一行错误 + 退出码 1。
	code, _, errOut = runAdmin(dbPath, "device-revoke", "--token", seed.deviceToken)
	if code != 1 || !strings.Contains(errOut, "unknown, revoked, or expired") {
		t.Fatalf("已撤销令牌：code=%d stderr=%q", code, errOut)
	}

	// 两个都不给。
	code, _, errOut = runAdmin(dbPath, "device-revoke")
	if code != 1 || !strings.Contains(errOut, "pass --device or --token") {
		t.Fatalf("缺参数：code=%d stderr=%q", code, errOut)
	}
}

func TestDeviceRevokeByTokenIsFieldForFieldIdentical(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)
	code, out, errOut := runAdmin(dbPath, "device-revoke", "--token", seed.deviceToken)
	if code != 0 {
		t.Fatalf("device-revoke 退出码 = %d, stderr = %s", code, errOut)
	}
	payload := decodeOutput(t, out)
	if payload["deviceId"] != seed.device.DeviceID || payload["detach"] != "relay-reconcile" {
		t.Fatalf("payload = %v", payload)
	}
}

func TestDeviceHygieneCountsAndThreshold(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)
	ctx := context.Background()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := st.RevokeDevice(ctx, seed.device.DeviceID); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}
	_ = st.Close()

	code, out, errOut := runAdminEnv(dbPath,
		map[string]string{"DLP_DEAD_DEVICE_WARN_THRESHOLD": "0"},
		"device-hygiene", "--agent", seed.agent.AgentID)
	if code != 0 {
		t.Fatalf("device-hygiene 退出码 = %d, stderr = %s", code, errOut)
	}
	payload := decodeOutput(t, out)
	if payload["ok"] != true || payload["revoked"] != float64(1) ||
		payload["dead"] != float64(1) || payload["live"] != float64(0) {
		t.Fatalf("device-hygiene = %v", payload)
	}
	if payload["agentId"] != seed.agent.AgentID {
		t.Fatalf("agentId = %v", payload["agentId"])
	}
	if payload["warnThreshold"] != float64(0) || payload["overThreshold"] != nil {
		t.Fatalf("阈值 = %v / %v", payload["warnThreshold"], payload["overThreshold"])
	}
	for _, key := range []string{"total", "live", "revoked", "expired", "dead",
		"warnThreshold", "overThreshold", "hint"} {
		if _, ok := payload[key]; !ok {
			t.Fatalf("device-hygiene 缺字段 %q：%v", key, payload)
		}
	}

	// 点名 agent 且阈值 > 0 时给出结论。
	code, out, _ = runAdminEnv(dbPath,
		map[string]string{"DLP_DEAD_DEVICE_WARN_THRESHOLD": "200"},
		"device-hygiene", "--agent", seed.agent.AgentID)
	_ = code
	if over := decodeOutput(t, out)["overThreshold"]; over != false {
		t.Fatalf("overThreshold = %v", over)
	}
}

// ── 用量与清理 ─────────────────────────────────────────────────────────────

func TestUsageAggregatesByAccountAndDevice(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)
	ctx := context.Background()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	build := "20261023.1200"
	now := store.NowMS()
	if _, err := st.AddUsage(ctx, []store.UsageEntry{{
		Day: store.LocalDay(), DeviceID: seed.device.DeviceID, AgentID: seed.agent.AgentID,
		AccountID: seed.account.AccountID, EgressBytes: 1000, Connections: 2,
		At: now, LastBuild: &build,
	}, {
		Day: store.LocalDay(), DeviceID: "dev_second", AgentID: seed.agent.AgentID,
		AccountID: seed.account.AccountID, EgressBytes: 500, Connections: 1,
		At: now, LastBuild: &build,
	}}); err != nil {
		t.Fatalf("AddUsage: %v", err)
	}
	_ = st.Close()

	code, out, errOut := runAdmin(dbPath, "usage", "--days", "1")
	if code != 0 {
		t.Fatalf("usage 退出码 = %d, stderr = %s", code, errOut)
	}
	rows := decodeList(t, out)
	if len(rows) != 1 {
		t.Fatalf("按账号汇总应是一行：%v", rows)
	}
	row := rows[0]
	if row["accountId"] != seed.account.AccountID || row["name"] != "ops" {
		t.Fatalf("账号行 = %v", row)
	}
	if row["egressBytes"] != float64(1500) || row["connections"] != float64(3) ||
		row["devices"] != float64(2) {
		t.Fatalf("汇总数字 = %v", row)
	}
	if _, present := row["deviceId"]; present {
		t.Fatalf("按账号汇总不该出现 deviceId：%v", row)
	}

	code, out, _ = runAdmin(dbPath, "usage", "--days", "1", "--by", "device")
	if code != 0 {
		t.Fatalf("usage --by device 退出码 = %d", code)
	}
	deviceRows := decodeList(t, out)
	if len(deviceRows) != 2 {
		t.Fatalf("按设备汇总应是两行：%v", deviceRows)
	}
	if deviceRows[0]["deviceId"] != seed.device.DeviceID {
		t.Fatalf("第一行应是出口更大的设备：%v", deviceRows[0])
	}
	if _, present := deviceRows[0]["accountId"]; present {
		t.Fatalf("按设备汇总不该出现 accountId：%v", deviceRows[0])
	}
}

func TestPurgeDropsExpiredPairCodes(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)
	code, out, errOut := runAdmin(dbPath, "code-mint", "--agent", seed.agent.AgentID,
		"--ttl-seconds", "0")
	if code != 0 {
		t.Fatalf("code-mint 退出码 = %d, stderr = %s", code, errOut)
	}
	code, out, errOut = runAdmin(dbPath, "purge", "--json")
	if code != 0 {
		t.Fatalf("purge 退出码 = %d, stderr = %s", code, errOut)
	}
	payload := decodeOutput(t, out)
	if payload["ok"] != true || payload["removed"] != float64(1) {
		t.Fatalf("purge = %v", payload)
	}
}

// ── push-test ──────────────────────────────────────────────────────────────

// stubPushTester 是 push-test 的注入桩：不碰真实 APNs。
type stubPushTester struct {
	enabled bool
	result  push.Result
	request *push.Request
}

func (s *stubPushTester) Enabled() bool { return s.enabled }
func (s *stubPushTester) Close() error  { return nil }

func (s *stubPushTester) Send(_ context.Context, request push.Request) push.Result {
	s.request = &request
	return s.result
}

func usePushTester(t *testing.T, tester pushTester) {
	t.Helper()
	previous := newPushSender
	newPushSender = func(func(string) string) pushTester { return tester }
	t.Cleanup(func() { newPushSender = previous })
}

func TestPushTestSendsOneAndPrintsWhatAppleSaid(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)
	ctx := context.Background()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	token := strings.Repeat("ab", 32)
	env := "sandbox"
	if err := st.SetPush(ctx, seed.device.DeviceID, &token, &env, true, true); err != nil {
		t.Fatalf("SetPush: %v", err)
	}
	_ = st.Close()

	status, apnsID := 200, "abc-123"
	tester := &stubPushTester{enabled: true, result: push.Result{
		OK: true, Status: &status, APNSID: &apnsID,
	}}
	usePushTester(t, tester)

	code, out, errOut := runAdmin(dbPath, "push-test", "--device", seed.device.DeviceID)
	if code != 0 {
		t.Fatalf("push-test 退出码 = %d, stderr = %s", code, errOut)
	}
	report := decodeOutput(t, out)
	if report["ok"] != true || report["status"] != float64(200) ||
		report["apnsId"] != "abc-123" || report["env"] != "sandbox" ||
		report["kind"] != "turnEnd" {
		t.Fatalf("报告 = %v", report)
	}
	if tester.request == nil || tester.request.DeviceID != seed.device.DeviceID ||
		tester.request.Token != token || !tester.request.IgnoreThrottle {
		t.Fatalf("请求 = %+v", tester.request)
	}
}

func TestPushTestPrintsTheRejectionAndClearsADeadToken(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)
	ctx := context.Background()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	token := strings.Repeat("ab", 32)
	env := "sandbox"
	if err := st.SetPush(ctx, seed.device.DeviceID, &token, &env, true, true); err != nil {
		t.Fatalf("SetPush: %v", err)
	}
	_ = st.Close()

	status, reason := 400, "BadDeviceToken"
	tester := &stubPushTester{enabled: true, result: push.Result{
		OK: false, Status: &status, Reason: &reason, DeadToken: true,
	}}
	usePushTester(t, tester)

	code, out, errOut := runAdmin(dbPath, "push-test", "--device", seed.device.DeviceID,
		"--kind", "attention")
	if code != 1 {
		t.Fatalf("push-test 退出码 = %d, stderr = %s", code, errOut)
	}
	report := decodeOutput(t, out)
	if report["ok"] != false || report["reason"] != "BadDeviceToken" ||
		report["deadToken"] != true || report["cleared"] != true {
		t.Fatalf("报告 = %v", report)
	}
	st, err = store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	row, _, _ := st.DeviceByID(ctx, seed.device.DeviceID)
	_ = st.Close()
	if row.APNSToken != nil {
		t.Fatalf("失效令牌没有被清掉：%v", row.APNSToken)
	}
}

func TestPushTestExplainsTyposAndMissingConfiguration(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)

	code, _, errOut := runAdmin(dbPath, "push-test", "--device", "dev_nope")
	if code != 1 || !strings.Contains(errOut, "dev_nope") ||
		strings.Contains(errOut, "Traceback") {
		t.Fatalf("打错 device：code=%d stderr=%q", code, errOut)
	}

	code, _, errOut = runAdmin(dbPath, "push-test", "--device", seed.device.DeviceID)
	if code != 1 || !strings.Contains(errOut, "推送登记") {
		t.Fatalf("未登记：code=%d stderr=%q", code, errOut)
	}

	// 有登记但 APNs 没配置：给出配置提示，而不是空指针。
	ctx := context.Background()
	st, _ := store.Open(dbPath)
	token, env := "ab", "sandbox"
	_ = st.SetPush(ctx, seed.device.DeviceID, &token, &env, true, true)
	_ = st.Close()
	code, _, errOut = runAdmin(dbPath, "push-test", "--device", seed.device.DeviceID)
	if code != 1 || !strings.Contains(errOut, "APNs 未配置") {
		t.Fatalf("未配置：code=%d stderr=%q", code, errOut)
	}
}

// ── ops-report ─────────────────────────────────────────────────────────────

func TestOpsReportHasEverySectionAndExcludesDebugDevices(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	seed := seedTenant(t, dbPath)
	ctx := context.Background()
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	now := store.NowMS()
	build := "20261023.1200"
	if _, err := st.AddUsage(ctx, []store.UsageEntry{{
		Day: store.LocalDay(), DeviceID: seed.device.DeviceID, AgentID: seed.agent.AgentID,
		AccountID: seed.account.AccountID, EgressBytes: 4096, Connections: 3,
		At: now, LastBuild: &build,
	}}); err != nil {
		t.Fatalf("AddUsage: %v", err)
	}
	if err := st.SetDeviceAppVersion(ctx, seed.device.DeviceID, build); err != nil {
		t.Fatalf("SetDeviceAppVersion: %v", err)
	}
	// 一台调试设备（DSH- 前缀）：日报的设备与用量板块都必须把它剔掉。
	debugAgent, _, err := st.RegisterAgent(ctx, seed.account.AccountID, "DSH-debug", nil)
	if err != nil {
		t.Fatalf("RegisterAgent debug: %v", err)
	}
	debugCode, err := st.MintPairCode(ctx, debugAgent.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode debug: %v", err)
	}
	if _, err := st.ClaimPairCode(ctx, debugCode.Code, store.ClaimParams{
		DeviceName: "DSH-Test", MaxPairedDevices: 8, TTLMS: store.DefaultDeviceTTLMS,
	}); err != nil {
		t.Fatalf("ClaimPairCode debug: %v", err)
	}
	_ = st.Close()
	_ = seed

	code, out, errOut := runAdmin(dbPath, "ops-report", "--days", "7")
	if code != 0 {
		t.Fatalf("ops-report 退出码 = %d, stderr = %s", code, errOut)
	}
	report := decodeOutput(t, out)
	for _, key := range []string{"ok", "generatedAt", "asOf", "days", "versions",
		"versionsWindowHours", "hourlyActivity", "today", "feedback", "devices",
		"usage", "retention", "invites"} {
		if _, ok := report[key]; !ok {
			t.Fatalf("ops-report 缺 section %q", key)
		}
	}
	if report["days"] != float64(7) || report["ok"] != true {
		t.Fatalf("头部 = %v", report)
	}
	devices := report["devices"].(map[string]any)
	if devices["paired"] != float64(1) || devices["newInWindow"] != float64(1) {
		t.Fatalf("devices = %v", devices)
	}
	usage := report["usage"].(map[string]any)
	perDay := usage["perDay"].([]any)
	total := float64(0)
	for _, entry := range perDay {
		total += entry.(map[string]any)["egressBytes"].(float64)
	}
	if total != float64(4096) {
		t.Fatalf("窗口内出口 = %v", total)
	}
	today := report["today"].(map[string]any)
	todayUsage := today["usage"].(map[string]any)
	if todayUsage["egressBytes"] != float64(4096) || todayUsage["connections"] != float64(3) {
		t.Fatalf("today.usage = %v", todayUsage)
	}
	if today["day"].(float64) != float64(store.LocalDay()) {
		t.Fatalf("today.day = %v", today["day"])
	}
	versions := report["versions"].([]any)
	if len(versions) != 1 || versions[0].(map[string]any)["appVersion"] != build {
		t.Fatalf("versions = %v", versions)
	}
	// 没有 systemd 日志时 buckets 必须是 null（不编数字）。
	hourly := report["hourlyActivity"].(map[string]any)
	if hourly["windowDays"] != float64(14) || hourly["windowHours"] != float64(336) {
		t.Fatalf("hourlyActivity = %v", hourly)
	}
	if hourly["buckets"] != nil {
		t.Fatalf("没有日志时 buckets 应为 null：%v", hourly)
	}
}

func TestOpsReportAsOfAnchorsTheWholePreviousDay(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	code, out, errOut := runAdmin(dbPath, "ops-report", "--days", "1", "--as-of", "yesterday")
	if code != 0 {
		t.Fatalf("ops-report 退出码 = %d, stderr = %s", code, errOut)
	}
	report := decodeOutput(t, out)
	asOf := int64(report["asOf"].(float64))
	generated := int64(report["generatedAt"].(float64))
	if asOf >= generated {
		t.Fatalf("as-of yesterday 的锚点应当早于生成时刻：%d vs %d", asOf, generated)
	}
	local := time.UnixMilli(asOf).In(time.Local)
	wantDay := int64(local.Year())*10000 + int64(local.Month())*100 + int64(local.Day())
	if report["today"].(map[string]any)["day"].(float64) != float64(wantDay) {
		t.Fatalf("today.day 应当取锚点那天：%v", report["today"])
	}
}

// ── alert-dispatch ─────────────────────────────────────────────────────────

// fakeMail 写一个假信箱 admin：记录 argv 与正文，按给定退出码结束。
func fakeMail(t *testing.T, exitCode int) (scriptPath, logPath string) {
	t.Helper()
	dir := t.TempDir()
	scriptPath = filepath.Join(dir, "fake_mail.py")
	logPath = filepath.Join(dir, "calls.txt")
	script := fmt.Sprintf(`#!/bin/sh
log=%q
{
  printf '%%s\n' "$@"
  echo '---BODY---'
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--body-file" ]; then
      shift
      cat "$1"
    fi
    shift
  done
} > "$log"
exit %d
`, logPath, exitCode)
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("写假信箱脚本: %v", err)
	}
	return scriptPath, logPath
}

func writeAlertQueue(t *testing.T, dir string, records ...monitor.Record) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("建目录: %v", err)
	}
	path := filepath.Join(dir, monitor.QueueName)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatalf("开队列: %v", err)
	}
	defer file.Close()
	for _, record := range records {
		line, err := json.Marshal(record)
		if err != nil {
			t.Fatalf("编码告警: %v", err)
		}
		if _, err := file.Write(append(line, '\n')); err != nil {
			t.Fatalf("写队列: %v", err)
		}
	}
	return path
}

func alertRecord(key string) monitor.Record {
	return monitor.Record{
		TS: 1_700_000_000, Key: key, Kind: "exception",
		Title:   "中转异常：ValueError @ hub.py:1042",
		Summary: "/link/agent → ValueError: boom",
		Details: map[string]any{"path": "/link/agent", "place": "hub.py:1042"},
		Count:   143, NewCategory: true,
	}
}

func TestAlertDispatchDryRunPrintsTheBodyAndKeepsTheQueue(t *testing.T) {
	dir := t.TempDir()
	queue := writeAlertQueue(t, dir, alertRecord("a"))
	code, out, errOut := runAdmin(filepath.Join(dir, "s.db"), "alert-dispatch",
		"--alert-dir", dir, "--account", "acc_owner", "--mail-db", "mail.db",
		"--mail-admin", "/bin/false", "--mail-python", "/bin/sh", "--dry-run")
	if code != 0 {
		t.Fatalf("dry-run 退出码 = %d, stderr = %s", code, errOut)
	}
	if !strings.Contains(out, "中转异常") || !strings.Contains(out, "[新类别]") ||
		!strings.Contains(out, "累计 143 次") {
		t.Fatalf("正文 = %q", out)
	}
	if _, err := os.Stat(queue); err != nil {
		t.Fatal("预演不许动队列")
	}
}

func TestAlertDispatchDeliversAndClearsTheQueue(t *testing.T) {
	dir := t.TempDir()
	writeAlertQueue(t, dir, alertRecord("a"))
	script, logPath := fakeMail(t, 0)
	code, _, errOut := runAdmin(filepath.Join(dir, "s.db"), "alert-dispatch",
		"--alert-dir", dir, "--account", "acc_owner", "--mail-db", "mail.db",
		"--mail-admin", script, "--mail-python", "/bin/sh")
	if code != 0 {
		t.Fatalf("投递退出码 = %d, stderr = %s", code, errOut)
	}
	calls, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("读假信箱调用记录: %v", err)
	}
	for _, expected := range []string{"feedback-notify", "--account", "acc_owner",
		"--yes", "---BODY---", "中转异常"} {
		if !strings.Contains(string(calls), expected) {
			t.Fatalf("调用记录缺 %q：%s", expected, calls)
		}
	}
	for _, path := range []string{monitor.QueueName, monitor.TakenName} {
		if _, err := os.Stat(filepath.Join(dir, path)); !os.IsNotExist(err) {
			t.Fatalf("投递成功后 %s 应当不存在", path)
		}
	}
}

func TestAlertDispatchFailurePutsEveryRecordBack(t *testing.T) {
	dir := t.TempDir()
	queue := writeAlertQueue(t, dir, alertRecord("a"), alertRecord("b"))
	before, err := os.ReadFile(queue)
	if err != nil {
		t.Fatalf("读队列: %v", err)
	}
	script, _ := fakeMail(t, 1)
	code, _, _ := runAdmin(filepath.Join(dir, "s.db"), "alert-dispatch",
		"--alert-dir", dir, "--account", "acc_owner", "--mail-db", "mail.db",
		"--mail-admin", script, "--mail-python", "/bin/sh")
	if code != 3 {
		t.Fatalf("投递失败退出码 = %d", code)
	}
	after, err := os.ReadFile(queue)
	if err != nil {
		t.Fatalf("读放回后的队列: %v", err)
	}
	if string(after) != string(before) {
		t.Fatalf("投递失败必须一条不少地放回：\n%q\n%q", after, before)
	}
	if _, err := os.Stat(filepath.Join(dir, monitor.TakenName)); !os.IsNotExist(err) {
		t.Fatal("放回之后 taken 应当删除")
	}
}

func TestAlertDispatchWithoutARecipientSendsNothing(t *testing.T) {
	dir := t.TempDir()
	queue := writeAlertQueue(t, dir, alertRecord("a"))
	script, _ := fakeMail(t, 0)
	code, _, errOut := runAdmin(filepath.Join(dir, "s.db"), "alert-dispatch",
		"--alert-dir", dir, "--mail-db", "mail.db", "--mail-admin", script,
		"--mail-python", "/bin/sh")
	if code != 2 || !strings.Contains(errOut, "no recipient account") {
		t.Fatalf("code=%d stderr=%q", code, errOut)
	}
	if _, err := os.Stat(queue); err != nil {
		t.Fatal("没有收件人时不许动队列")
	}
}

func TestAlertDispatchMissingQueueIsNotAnError(t *testing.T) {
	dir := t.TempDir()
	script, _ := fakeMail(t, 0)
	code, _, errOut := runAdmin(filepath.Join(dir, "s.db"), "alert-dispatch",
		"--alert-dir", dir, "--account", "acc_owner", "--mail-db", "mail.db",
		"--mail-admin", script, "--mail-python", "/bin/sh")
	if code != 0 {
		t.Fatalf("空队列退出码 = %d, stderr = %s", code, errOut)
	}
}

func TestAlertDispatchSkipsMalformedLines(t *testing.T) {
	dir := t.TempDir()
	queue := writeAlertQueue(t, dir, alertRecord("a"))
	file, err := os.OpenFile(queue, os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatalf("开队列: %v", err)
	}
	_, _ = file.WriteString("{not json\n")
	_ = file.Close()
	script, logPath := fakeMail(t, 0)
	code, _, errOut := runAdmin(filepath.Join(dir, "s.db"), "alert-dispatch",
		"--alert-dir", dir, "--account", "acc_owner", "--mail-db", "mail.db",
		"--mail-admin", script, "--mail-python", "/bin/sh")
	if code != 0 || !strings.Contains(errOut, "malformed") {
		t.Fatalf("code=%d stderr=%q", code, errOut)
	}
	calls, err := os.ReadFile(logPath)
	if err != nil || !strings.Contains(string(calls), "中转异常") {
		t.Fatalf("正文 = %s, err=%v", calls, err)
	}
}

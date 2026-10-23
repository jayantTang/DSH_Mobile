package admincli

import (
	"bytes"
	"context"
	"encoding/json"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// runAdmin 跑一次 admin 调用并返回退出码、stdout、stderr。
func runAdmin(dbPath string, args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	full := append([]string{"--db", dbPath}, args...)
	code := Main(full, func(string) string { return "" }, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func decodeOutput(t *testing.T, text string) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal([]byte(text), &payload); err != nil {
		t.Fatalf("admin 输出不是 JSON: %v (%q)", err, text)
	}
	return payload
}

func TestAccountCreateAndAgentRegister(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")

	code, out, errOut := runAdmin(dbPath, "account-create", "--name", "示例账户")
	if code != 0 {
		t.Fatalf("account-create 退出码 = %d, stderr = %s", code, errOut)
	}
	account := decodeOutput(t, out)
	if !strings.HasPrefix(account["accountId"].(string), "acc_") ||
		account["name"] != "示例账户" {
		t.Fatalf("account-create 输出 = %v", account)
	}
	if _, ok := account["createdAt"].(float64); !ok {
		t.Fatalf("createdAt 缺失: %v", account)
	}

	code, out, errOut = runAdmin(dbPath, "agent-register",
		"--account", account["accountId"].(string), "--name", "MacBook")
	if code != 0 {
		t.Fatalf("agent-register 退出码 = %d, stderr = %s", code, errOut)
	}
	agent := decodeOutput(t, out)
	if !strings.HasPrefix(agent["agentId"].(string), "agt_") ||
		!strings.HasPrefix(agent["agentSecret"].(string), "as_") {
		t.Fatalf("agent-register 输出 = %v", agent)
	}
	if agent["rotated"] != false || agent["accountId"] != account["accountId"] {
		t.Fatalf("agent-register 字段 = %v", agent)
	}

	// 轮换：同一个 agentId，新的 secret，rotated=true。
	code, out, errOut = runAdmin(dbPath, "agent-register",
		"--account", account["accountId"].(string), "--name", "MacBook",
		"--agent", agent["agentId"].(string))
	if code != 0 {
		t.Fatalf("轮换退出码 = %d, stderr = %s", code, errOut)
	}
	rotated := decodeOutput(t, out)
	if rotated["rotated"] != true || rotated["agentId"] != agent["agentId"] {
		t.Fatalf("轮换输出 = %v", rotated)
	}
	if rotated["agentSecret"] == agent["agentSecret"] {
		t.Fatal("轮换没有换发新 secret")
	}

	// 未知账户 / 未知 agent 是业务错误（退出码 1）。
	code, _, errOut = runAdmin(dbPath, "agent-register", "--account", "acc_nope", "--name", "X")
	if code != 1 || !strings.Contains(errOut, "does not exist") {
		t.Fatalf("未知账户退出码 = %d, stderr = %s", code, errOut)
	}
}

func TestCodeMintAndInviteMint(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	_, out, _ := runAdmin(dbPath, "account-create", "--name", "示例")
	accountID := decodeOutput(t, out)["accountId"].(string)
	_, out, _ = runAdmin(dbPath, "agent-register", "--account", accountID, "--name", "Mac")
	agentID := decodeOutput(t, out)["agentId"].(string)

	// 立即过期的码（黑盒用例靠它验证 pair/expired-code）。
	code, out, errOut := runAdmin(dbPath, "code-mint", "--agent", agentID, "--ttl-seconds", "0")
	if code != 0 {
		t.Fatalf("code-mint 退出码 = %d, stderr = %s", code, errOut)
	}
	minted := decodeOutput(t, out)
	codePattern := regexp.MustCompile(`^[A-Z2-9]{4}-[A-Z2-9]{4}$`)
	if !codePattern.MatchString(minted["code"].(string)) {
		t.Fatalf("配对码格式 = %v", minted["code"])
	}
	if minted["persistent"] != false || minted["ttlMs"] != float64(0) {
		t.Fatalf("限时码字段 = %v", minted)
	}
	if minted["agentId"] != agentID {
		t.Fatalf("agentId = %v", minted["agentId"])
	}
	if qr, _ := minted["qrPayload"].(string); !strings.HasPrefix(qr, "dsh://pair?relay=") ||
		!strings.Contains(qr, "&code=") {
		t.Fatalf("qrPayload = %v", minted["qrPayload"])
	}

	// 邀请码：默认 7 天，带 note 与登记命令。
	code, out, errOut = runAdmin(dbPath, "invite-mint", "--note", "给 Sam")
	if code != 0 {
		t.Fatalf("invite-mint 退出码 = %d, stderr = %s", code, errOut)
	}
	invite := decodeOutput(t, out)
	if invite["note"] != "给 Sam" || invite["ttlMs"] != float64(store.DefaultInviteTTLMS) {
		t.Fatalf("邀请码字段 = %v", invite)
	}
	invitePattern := regexp.MustCompile(`^[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$`)
	if !invitePattern.MatchString(invite["code"].(string)) {
		t.Fatalf("邀请码格式 = %v", invite["code"])
	}
	command, _ := invite["enrollCommand"].(string)
	if !strings.Contains(command, invite["code"].(string)) ||
		!strings.HasPrefix(command, "dsh-mobile-link enroll --invite ") {
		t.Fatalf("enrollCommand = %v", command)
	}

	// --count 2 输出数组。
	code, out, errOut = runAdmin(dbPath, "invite-mint", "--count", "2")
	if code != 0 {
		t.Fatalf("invite-mint --count 退出码 = %d, stderr = %s", code, errOut)
	}
	var invites []map[string]any
	if err := json.Unmarshal([]byte(out), &invites); err != nil || len(invites) != 2 {
		t.Fatalf("多枚邀请码输出 = %q (%v)", out, err)
	}
}

func TestDeviceListOutput(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	_, out, _ := runAdmin(dbPath, "account-create", "--name", "设备账户")
	accountID := decodeOutput(t, out)["accountId"].(string)
	_, out, _ = runAdmin(dbPath, "agent-register", "--account", accountID, "--name", "Mac")
	agent := decodeOutput(t, out)

	// 用仓储层造一台已配对设备（等价于一次 /pair/claim）。
	seeded, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	ctx := context.Background()
	ttl := int64(600_000)
	code, err := seeded.MintPairCode(ctx, agent["agentId"].(string), &ttl)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	if _, err := seeded.ClaimPairCode(ctx, code.Code, store.ClaimParams{
		DeviceName: "BLACKBOX-iPhone", Model: ptr("iPhone17,1"), AppVersion: ptr("9.9.9"),
		TTLMS: store.DefaultDeviceTTLMS, MaxPairedDevices: 8,
	}); err != nil {
		t.Fatalf("ClaimPairCode: %v", err)
	}
	if err := seeded.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	exit, out, errOut := runAdmin(dbPath, "device-list")
	if exit != 0 {
		t.Fatalf("device-list 退出码 = %d, stderr = %s", exit, errOut)
	}
	var rows []map[string]any
	if err := json.Unmarshal([]byte(out), &rows); err != nil {
		t.Fatalf("device-list 输出不是数组: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("device-list 行数 = %d", len(rows))
	}
	row := rows[0]
	for _, key := range []string{"deviceId", "deviceTokenHash", "agentId", "accountId",
		"name", "model", "appVersion", "createdAt", "expiresAt", "lastSeenAt", "revokedAt",
		"apnsToken", "apnsEnv", "pushTurnEnd", "pushAttention", "pushUpdatedAt", "deviceKey",
		"connectorVersion", "hostVersion", "versionsAt", "push"} {
		if _, ok := row[key]; !ok {
			t.Fatalf("device-list 缺字段 %q: %v", key, row)
		}
	}
	if row["name"] != "BLACKBOX-iPhone" || row["model"] != "iPhone17,1" {
		t.Fatalf("设备行 = %v", row)
	}
	if hash, _ := row["deviceTokenHash"].(string); !strings.HasSuffix(hash, "…") ||
		len([]rune(hash)) != 13 {
		t.Fatalf("deviceTokenHash 没有打码: %v", row["deviceTokenHash"])
	}
	push := row["push"].(map[string]any)
	if push["registered"] != false || push["turnEnd"] != true || push["attention"] != true {
		t.Fatalf("push = %v", push)
	}
	if row["connectorVersion"] != nil || row["versionsAt"] != nil {
		t.Fatalf("未上报版本时应为 null: %v", row)
	}

	// 撤销之后默认不出现，--all 才出现。
	deviceID := row["deviceId"].(string)
	revokedStore, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := revokedStore.RevokeDevice(ctx, deviceID); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}
	if err := revokedStore.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	_, out, _ = runAdmin(dbPath, "device-list")
	if strings.TrimSpace(out) != "[]" {
		t.Fatalf("撤销后默认列表 = %q", out)
	}
	_, out, _ = runAdmin(dbPath, "device-list", "--all")
	var all []map[string]any
	if err := json.Unmarshal([]byte(out), &all); err != nil || len(all) != 1 {
		t.Fatalf("--all 列表 = %q (%v)", out, err)
	}
}

func TestUsageErrorsExitWith2(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	if code, _, errOut := runAdmin(dbPath, "account-create"); code != 2 ||
		!strings.Contains(errOut, "--name") {
		t.Fatalf("缺少 --name 退出码 = %d, stderr = %s", code, errOut)
	}
	if code, _, errOut := runAdmin(dbPath, "nope"); code != 2 ||
		!strings.Contains(errOut, "未知子命令") {
		t.Fatalf("未知子命令退出码 = %d, stderr = %s", code, errOut)
	}
}

func ptr(value string) *string { return &value }

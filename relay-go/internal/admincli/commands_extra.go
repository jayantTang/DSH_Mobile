package admincli

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/opsreport"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/push"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 与 admin.py 的默认值一致。
const (
	defaultUsageDays = 7
	// DefaultDeadDeviceWarnThreshold 是 hub 与 admin 共用的告警阈值（Python
	// hub.DEFAULT_DEAD_DEVICE_WARN_THRESHOLD）。
	DefaultDeadDeviceWarnThreshold = 200
	deviceHygieneHint              = "purge-revoked-devices.py --db <db> --all-agents --apply " +
		"（去掉 --apply 只是预演）"
)

// runAccountList 实现 account-list。
func runAccountList(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdAccountList, stderr)
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	accounts, err := st.ListAccounts(ctx)
	if err != nil {
		return err
	}
	return emit(stdout, accounts)
}

// agentRotateOutput 是 agent-rotate 的输出（Python 的 created 字典 + 可选 configPath）。
type agentRotateOutput struct {
	AgentID     string `json:"agentId"`
	AgentSecret string `json:"agentSecret"`
	AccountID   string `json:"accountId"`
	Name        string `json:"name"`
	ConfigPath  string `json:"configPath,omitempty"`
}

// runAgentRotate 实现 agent-rotate：轮换一台已有电脑的 secret。
func runAgentRotate(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdAgentRotate, stderr)
	agentRef := fs.String("agent", "", "agentId 或唯一的电脑名")
	name := fs.String("name", "", "新名字（省略时沿用原名）")
	relay := fs.String("relay", DefaultRelay, "中转地址（写进身份文件与输出）")
	configPath := fs.String("write-config", "", "把连接器身份写进这个文件（0600）")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if err := requireFlag("agent", *agentRef); err != nil {
		return err
	}
	existing, err := resolveAgent(ctx, st, *agentRef)
	if err != nil {
		return err
	}
	chosen := *name
	if chosen == "" {
		chosen = existing.Name
	}
	agent, secret, err := st.RegisterAgent(ctx, existing.AccountID, chosen, &existing.AgentID)
	if err != nil {
		return err
	}
	output := agentRotateOutput{
		AgentID: agent.AgentID, AgentSecret: secret, AccountID: agent.AccountID,
		Name: agent.Name,
	}
	if *configPath != "" {
		if err := writeAgentConfig(*configPath, *relay, agent, secret); err != nil {
			return err
		}
		output.ConfigPath = *configPath
	}
	return emit(stdout, output)
}

// agentListEntry 是 agent-list 的一行：全部列 + 打码后的 secretHash。
//
// 显式字段而不是嵌入 store.Agent：Python 的 `{**agent, "secretHash": 截断}` 把
// secretHash 留在**原来的位置**，嵌入结构体会让它跑到末尾；两版输出的键序要能 diff。
type agentListEntry struct {
	AgentID          string  `json:"agentId"`
	AccountID        string  `json:"accountId"`
	Name             string  `json:"name"`
	SecretHash       string  `json:"secretHash"`
	CreatedAt        int64   `json:"createdAt"`
	UpdatedAt        int64   `json:"updatedAt"`
	Disabled         int     `json:"disabled"`
	LastSeenAt       *int64  `json:"lastSeenAt"`
	ConnectorVersion *string `json:"connectorVersion"`
	HostVersion      *string `json:"hostVersion"`
	VersionsAt       *int64  `json:"versionsAt"`
}

// runAgentList 实现 agent-list [--account]。
func runAgentList(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdAgentList, stderr)
	accountID := fs.String("account", "", "只看这个账户")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	agents, err := st.ListAgents(ctx, *accountID)
	if err != nil {
		return err
	}
	rows := make([]agentListEntry, 0, len(agents))
	for _, agent := range agents {
		rows = append(rows, agentListEntry{
			AgentID: agent.AgentID, AccountID: agent.AccountID, Name: agent.Name,
			SecretHash: opsreport.MaskPrefix(agent.SecretHash, 12),
			CreatedAt:  agent.CreatedAt, UpdatedAt: agent.UpdatedAt,
			Disabled: agent.Disabled, LastSeenAt: agent.LastSeenAt,
			ConnectorVersion: agent.ConnectorVersion, HostVersion: agent.HostVersion,
			VersionsAt: agent.VersionsAt,
		})
	}
	return emit(stdout, rows)
}

// agentToggleOutput 是 agent-disable / agent-enable 的输出。
type agentToggleOutput struct {
	OK       bool   `json:"ok"`
	AgentID  string `json:"agentId"`
	Disabled bool   `json:"disabled"`
}

// runAgentToggle 实现 agent-disable / agent-enable。
func runAgentToggle(ctx context.Context, st *store.Store, command string, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(command, stderr)
	agentRef := fs.String("agent", "", "agentId 或唯一的电脑名")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if err := requireFlag("agent", *agentRef); err != nil {
		return err
	}
	agent, err := resolveAgent(ctx, st, *agentRef)
	if err != nil {
		return err
	}
	disabled := command == cmdAgentDisable
	if err := st.SetAgentDisabled(ctx, agent.AgentID, disabled); err != nil {
		return err
	}
	return emit(stdout, agentToggleOutput{OK: true, AgentID: agent.AgentID, Disabled: disabled})
}

// inviteListEntry 是 invite-list 的一行；哈希只显示前 12 字符。
type inviteListEntry struct {
	CodeHash         string  `json:"codeHash"`
	Note             *string `json:"note"`
	CreatedAt        int64   `json:"createdAt"`
	ExpiresAt        int64   `json:"expiresAt"`
	ExpiresInSeconds int64   `json:"expiresInSeconds"`
	UsedAt           *int64  `json:"usedAt"`
	UsedByAgentID    *string `json:"usedByAgentId"`
}

// runInviteList 实现 invite-list [--all]（只给哈希，永远不给码）。
func runInviteList(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdInviteList, stderr)
	includeUsed := fs.Bool("all", false, "包含已使用的邀请码")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	invites, err := st.ListInvites(ctx, *includeUsed)
	if err != nil {
		return err
	}
	now := store.NowMS()
	rows := make([]inviteListEntry, 0, len(invites))
	for _, invite := range invites {
		remaining := invite.ExpiresAt - now
		if remaining < 0 {
			remaining = 0
		}
		rows = append(rows, inviteListEntry{
			CodeHash: opsreport.MaskPrefix(invite.CodeHash, 12), Note: invite.Note,
			CreatedAt: invite.CreatedAt, ExpiresAt: invite.ExpiresAt,
			ExpiresInSeconds: remaining / 1000,
			UsedAt:           invite.UsedAt, UsedByAgentID: invite.UsedByAgentID,
		})
	}
	return emit(stdout, rows)
}

// runInviteRevoke 实现 invite-revoke --code；作废失败也打印 JSON，退出码 1。
func runInviteRevoke(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdInviteRevoke, stderr)
	code := fs.String("code", "", "要作废的邀请码")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if err := requireFlag("code", *code); err != nil {
		return err
	}
	result, err := st.RevokeInvite(ctx, *code, 0)
	if err != nil {
		return err
	}
	if err := emit(stdout, result); err != nil {
		return err
	}
	if !result.Revoked {
		return reported{}
	}
	return nil
}

// inviteCheckEntry 是 invite-check 的一行：码 + 它的状态（与 invite_status 同形）。
type inviteCheckEntry struct {
	Code string `json:"code"`
	store.InviteStatus
}

// runInviteCheck 实现 invite-check（只读；--stdin 每行一张码）。
func runInviteCheck(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdInviteCheck, stderr)
	var codes stringListFlag
	fs.Var(&codes, "code", "邀请码（可重复）")
	fromStdin := fs.Bool("stdin", false, "从标准输入逐行读邀请码")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	all := append([]string{}, codes...)
	if *fromStdin {
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			if line := strings.TrimSpace(scanner.Text()); line != "" {
				all = append(all, line)
			}
		}
		if err := scanner.Err(); err != nil {
			return fmt.Errorf("读标准输入: %w", err)
		}
	}
	rows := make([]inviteCheckEntry, 0, len(all))
	for _, code := range all {
		status, err := st.InviteStatus(ctx, code)
		if err != nil {
			return err
		}
		rows = append(rows, inviteCheckEntry{Code: code, InviteStatus: status})
	}
	return emit(stdout, rows)
}

// deviceRevokeOutput 是 device-revoke 的固定四个字段。
//
// 这个形状是契约（C-04 F3）：`ok:true` 只陈述 admin 自己核实过的事实；踢在线设备
// 由中转的撤销对账做，admin 不、也没有去直连中转。
type deviceRevokeOutput struct {
	OK       bool   `json:"ok"`
	DeviceID string `json:"deviceId"`
	Revoked  bool   `json:"revoked"`
	Detach   string `json:"detach"`
}

// runDeviceRevoke 实现 device-revoke（--device 与 --token 结果完全相同）。
func runDeviceRevoke(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdDeviceRevoke, stderr)
	deviceID := fs.String("device", "", "deviceId")
	token := fs.String("token", "", "设备令牌")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	target := ""
	switch {
	case *token != "":
		device, ok, err := st.DeviceByToken(ctx, *token)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("that device token is unknown, revoked, or expired")
		}
		target = device.DeviceID
	case *deviceID != "":
		target = *deviceID
	default:
		return fmt.Errorf("pass --device or --token")
	}
	if err := st.RevokeDevice(ctx, target); err != nil {
		return err
	}
	return emit(stdout, deviceRevokeOutput{
		OK: true, DeviceID: target, Revoked: true, Detach: "relay-reconcile",
	})
}

// deviceHygieneOutput 是 device-hygiene 的输出。
type deviceHygieneOutput struct {
	OK            bool   `json:"ok"`
	Total         int    `json:"total"`
	Live          int    `json:"live"`
	Revoked       int    `json:"revoked"`
	Expired       int    `json:"expired"`
	Dead          int    `json:"dead"`
	AgentID       string `json:"agentId,omitempty"`
	WarnThreshold int    `json:"warnThreshold"`
	// OverThreshold 是 *bool：没点名 agent 时是 null（"没判"不等于"没超"）。
	OverThreshold *bool  `json:"overThreshold"`
	Hint          string `json:"hint"`
}

// runDeviceHygiene 实现 device-hygiene（只读，不删任何东西）。
func runDeviceHygiene(ctx context.Context, st *store.Store, getenv func(string) string,
	args []string, stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdDeviceHygiene, stderr)
	agentRef := fs.String("agent", "", "只看这台电脑（默认整个库）")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	agentID := ""
	if *agentRef != "" {
		agent, err := resolveAgent(ctx, st, *agentRef)
		if err != nil {
			return err
		}
		agentID = agent.AgentID
	}
	counts, err := st.DeviceHygiene(ctx, agentID)
	if err != nil {
		return err
	}
	threshold := deadDeviceWarnThreshold(getenv)
	output := deviceHygieneOutput{
		OK: true, Total: counts.Total, Live: counts.Live, Revoked: counts.Revoked,
		Expired: counts.Expired, Dead: counts.Dead, AgentID: counts.AgentID,
		WarnThreshold: threshold, Hint: deviceHygieneHint,
	}
	if agentID != "" && threshold != 0 {
		over := counts.Dead > threshold
		output.OverThreshold = &over
	}
	return emit(stdout, output)
}

// enrollmentsOutput 是 enrollments 的两段。
type enrollmentsOutput struct {
	Totals      store.InviteTotals `json:"totals"`
	Enrollments []store.Enrollment `json:"enrollments"`
}

// runEnrollments 实现 enrollments（只读联表视图）。
func runEnrollments(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdEnrollments, stderr)
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	totals, err := st.InviteTotals(ctx)
	if err != nil {
		return err
	}
	enrollments, err := st.ListEnrollments(ctx)
	if err != nil {
		return err
	}
	return emit(stdout, enrollmentsOutput{Totals: totals, Enrollments: enrollments})
}

// runUsage 实现 usage [--days] [--by account|device]。
func runUsage(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdUsage, stderr)
	days := fs.Int("days", defaultUsageDays, "往回看多少天")
	by := fs.String("by", "account", "account 或 device")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if *by != "account" && *by != "device" {
		return newUsageError("--by 只支持 account 或 device，收到 %q", *by)
	}
	daysValue := *days
	if daysValue < 1 {
		daysValue = 1
	}
	rows, err := st.UsageTotals(ctx, daysValue, *by)
	if err != nil {
		return err
	}
	return emit(stdout, rows)
}

// purgeOutput 是 purge 的输出。
type purgeOutput struct {
	OK      bool  `json:"ok"`
	Removed int64 `json:"removed"`
}

// runPurge 实现 purge（删过期配对码与早就作废的码）。
func runPurge(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdPurge, stderr)
	// --json 是 Python 版的历史参数：输出本来就是 JSON，这里接受但不改变行为。
	_ = fs.Bool("json", false, "以 JSON 输出（默认即是）")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	removed, err := st.PurgeExpired(ctx, 0)
	if err != nil {
		return err
	}
	return emit(stdout, purgeOutput{OK: true, Removed: removed})
}

// pushTester 是 push-test 需要的投递面（*push.Sender 实现；单测可注入桩）。
type pushTester interface {
	Enabled() bool
	Close() error
	Send(ctx context.Context, request push.Request) push.Result
}

// newPushSender 是构造入口，单测替换它来验证输出契约（不碰真实 APNs）。
var newPushSender = func(getenv func(string) string) pushTester {
	return push.FromEnv(getenv, nil)
}

// pushTestReport 是 push-test 打印给运维的报告；这是该命令的全部价值。
type pushTestReport struct {
	OK        bool    `json:"ok"`
	DeviceID  string  `json:"deviceId"`
	Env       *string `json:"env"`
	Kind      string  `json:"kind"`
	Status    *int    `json:"status"`
	Reason    *string `json:"reason"`
	APNSID    *string `json:"apnsId"`
	DeadToken bool    `json:"deadToken"`
	Skipped   *string `json:"skipped"`
	Cleared   bool    `json:"cleared,omitempty"`
}

// runPushTest 实现 push-test：现在发一条，并打印 Apple 的原话。
//
// 它存在的理由：令牌登记到了错误环境时，中转接受、APNs 回 BadDeviceToken，手机
// 就是不响，别处也不会说什么。所以这里**打印状态与原因**，并故意忽略"设备在线"
// （换机期手机常因 keep-alive 还连着，拒绝发送会让唯一能分辨环境的命令失去意义）。
func runPushTest(ctx context.Context, st *store.Store, getenv func(string) string,
	args []string, stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdPushTest, stderr)
	deviceRef := fs.String("device", "", "deviceId（device-list 里有）")
	kind := fs.String("kind", "turnEnd", "turnEnd 或 attention")
	sid := fs.String("sid", "push-test", "放进 payload 的会话 id（不显示）")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if err := requireFlag("device", *deviceRef); err != nil {
		return err
	}
	if *kind != "turnEnd" && *kind != "attention" {
		return newUsageError("--kind 只支持 turnEnd 或 attention，收到 %q", *kind)
	}
	row, found, err := st.DeviceByID(ctx, *deviceRef)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("no device %q; `device-list` shows the ids", *deviceRef)
	}
	if row.APNSToken == nil || *row.APNSToken == "" {
		return fmt.Errorf("device %s 没有推送登记（App 启动/开关变化时才会上报）", *deviceRef)
	}
	if row.RevokedAt != nil {
		return fmt.Errorf("device %s 已被撤销，不会再收到推送", *deviceRef)
	}

	sender := newPushSender(getenv)
	defer func() { _ = sender.Close() }()
	if !sender.Enabled() {
		return fmt.Errorf("APNs 未配置或已关闭；需要 DLP_APNS_ENABLED=1 与 " +
			"DLP_APNS_KEY_PATH/KEY_ID/TEAM_ID/TOPIC（见 deploy/apns.env.example）")
	}

	result := sender.Send(ctx, push.Request{
		DeviceID: row.DeviceID, Token: *row.APNSToken, Env: row.APNSEnv,
		Kind: *kind, SID: *sid, IgnoreThrottle: true,
	})
	report := pushTestReport{
		OK: result.OK, DeviceID: row.DeviceID, Env: row.APNSEnv, Kind: *kind,
		Status: result.Status, Reason: result.Reason, APNSID: result.APNSID,
		DeadToken: result.DeadToken, Skipped: result.Skipped,
	}
	if result.DeadToken {
		// 与 relay 在线时的行为一致：Apple 说令牌死了，就清掉登记。
		if err := st.ClearPush(ctx, row.DeviceID); err != nil {
			return err
		}
		report.Cleared = true
	}
	if err := emit(stdout, report); err != nil {
		return err
	}
	if !result.OK {
		return reported{}
	}
	return nil
}

// deadDeviceWarnThreshold 是 DLP_DEAD_DEVICE_WARN_THRESHOLD：
// 坏值回退默认、负数夹到 0（Python hub.dead_device_warn_threshold_from_env）。
func deadDeviceWarnThreshold(getenv func(string) string) int {
	if getenv == nil {
		return DefaultDeadDeviceWarnThreshold
	}
	raw := strings.TrimSpace(getenv("DLP_DEAD_DEVICE_WARN_THRESHOLD"))
	if raw == "" {
		return DefaultDeadDeviceWarnThreshold
	}
	var value int
	parsed, err := strconv.Atoi(raw)
	if err != nil {
		return DefaultDeadDeviceWarnThreshold
	}
	value = parsed
	if value < 0 {
		value = 0
	}
	return value
}

package admincli

import (
	"context"
	"flag"
	"io"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 与 admin.py 的 argparse 默认值一致。
const (
	defaultCodeTTLSeconds   = int64(store.DefaultPairTTLMS / 1000)
	defaultInviteTTLSeconds = int64(store.DefaultInviteTTLMS / 1000)
)

// newFlagSet 建一个静默的 FlagSet：出错时由调用方统一打印，避免重复两行用法。
func newFlagSet(name string, stderr io.Writer) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(stderr)
	return fs
}

// runAccountCreate 实现 account-create --name。
func runAccountCreate(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdAccountCreate, stderr)
	name := fs.String("name", "", "账户名")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if err := requireFlag("name", *name); err != nil {
		return err
	}
	account, err := st.CreateAccount(ctx, *name)
	if err != nil {
		return err
	}
	return emit(stdout, account)
}

// agentRegisterOutput 是 agent-register 的输出（Python created + rotated [+ configPath]）。
type agentRegisterOutput struct {
	AgentID     string `json:"agentId"`
	AgentSecret string `json:"agentSecret"`
	AccountID   string `json:"accountId"`
	Name        string `json:"name"`
	Rotated     bool   `json:"rotated"`
	ConfigPath  string `json:"configPath,omitempty"`
}

// runAgentRegister 实现 agent-register：新建一台电脑，或轮换已有 agent 的 secret。
func runAgentRegister(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdAgentRegister, stderr)
	accountID := fs.String("account", "", "账户 ID")
	name := fs.String("name", "", "电脑名")
	agentRef := fs.String("agent", "", "已有 agentId（给了就轮换 secret）")
	relay := fs.String("relay", DefaultRelay, "中转地址（写进身份文件与输出）")
	configPath := fs.String("write-config", "", "把连接器身份写进这个文件（0600）")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	if err := requireFlag("account", *accountID); err != nil {
		return err
	}
	if err := requireFlag("name", *name); err != nil {
		return err
	}

	var rotateID *string
	if *agentRef != "" {
		existing, err := resolveAgent(ctx, st, *agentRef)
		if err != nil {
			return err
		}
		rotateID = &existing.AgentID
	}

	agent, secret, err := st.RegisterAgent(ctx, *accountID, *name, rotateID)
	if err != nil {
		return err
	}
	output := agentRegisterOutput{
		AgentID: agent.AgentID, AgentSecret: secret, AccountID: agent.AccountID,
		Name: agent.Name, Rotated: rotateID != nil,
	}
	if *configPath != "" {
		if err := writeAgentConfig(*configPath, *relay, agent, secret); err != nil {
			return err
		}
		output.ConfigPath = *configPath
	}
	return emit(stdout, output)
}

// codeMintOutput 是 code-mint 的输出（Python mint_pair_code + qrPayload）。
type codeMintOutput struct {
	Code       string `json:"code"`
	ExpiresAt  *int64 `json:"expiresAt"`
	AgentID    string `json:"agentId"`
	TTLMs      *int64 `json:"ttlMs"`
	Persistent bool   `json:"persistent"`
	QRPayload  string `json:"qrPayload"`
}

// runCodeMint 实现 code-mint --agent。
//
// --ttl-seconds 0 是合法的（"一出生就过期"的码），黑盒用例靠它验证过期路径。
func runCodeMint(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdCodeMint, stderr)
	agentRef := fs.String("agent", "", "agentId 或唯一的电脑名")
	ttlSeconds := fs.Int64("ttl-seconds", defaultCodeTTLSeconds, "配对码有效期（秒，0 = 立即过期）")
	relay := fs.String("relay", DefaultRelay, "中转地址（用于二维码深链）")
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
	ttlMS := *ttlSeconds * 1000
	minted, err := st.MintPairCode(ctx, agent.AgentID, &ttlMS)
	if err != nil {
		return err
	}
	return emit(stdout, codeMintOutput{
		Code: minted.Code, ExpiresAt: minted.ExpiresAt, AgentID: minted.AgentID,
		TTLMs: minted.TTLMs, Persistent: minted.Persistent,
		QRPayload: qrPayload(*relay, minted.Code),
	})
}

// inviteMintOutput 是 invite-mint 的输出。
type inviteMintOutput struct {
	Code          string  `json:"code"`
	ExpiresAt     int64   `json:"expiresAt"`
	TTLMs         int64   `json:"ttlMs"`
	Note          *string `json:"note"`
	EnrollCommand string  `json:"enrollCommand"`
}

// runInviteMint 实现 invite-mint；--count > 1 时输出数组（与 Python 一致）。
func runInviteMint(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdInviteMint, stderr)
	ttlSeconds := fs.Int64("ttl-seconds", defaultInviteTTLSeconds, "邀请码有效期（秒）")
	note := fs.String("note", "", "自由文本备注（例如这是给谁的）")
	relay := fs.String("relay", DefaultRelay, "中转地址（用于登记命令）")
	count := fs.Int("count", 1, "一次铸几枚")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}

	// note 只有显式给出时才写成非 NULL：argparse 的默认值是 None，与空串不同。
	var noteValue *string
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "note" {
			value := *note
			noteValue = &value
		}
	})

	ttlMS := *ttlSeconds * 1000
	total := *count
	if total < 1 {
		total = 1
	}
	minted := make([]inviteMintOutput, 0, total)
	for index := 0; index < total; index++ {
		invite, err := st.MintInvite(ctx, ttlMS, noteValue, "")
		if err != nil {
			return err
		}
		minted = append(minted, inviteMintOutput{
			Code: invite.Code, ExpiresAt: invite.ExpiresAt, TTLMs: invite.TTLMs,
			Note: invite.Note, EnrollCommand: enrollCommand(*relay, invite.Code),
		})
	}
	if total == 1 {
		return emit(stdout, minted[0])
	}
	return emit(stdout, minted)
}

// pushInfo 是 device-list 里 push 段（Python 同名结构）。
type pushInfo struct {
	Registered bool    `json:"registered"`
	Env        *string `json:"env"`
	TurnEnd    bool    `json:"turnEnd"`
	Attention  bool    `json:"attention"`
	UpdatedAt  *int64  `json:"updatedAt"`
}

// deviceListEntry 是 device-list 的一行：设备全列 + 那台电脑的版本三段 + 推送登记。
//
// 字段名与 admin.py 输出逐项一致；deviceTokenHash 与 apnsToken 打码（终端记录不该
// 留下可用凭据）。
type deviceListEntry struct {
	DeviceID         string   `json:"deviceId"`
	DeviceTokenHash  string   `json:"deviceTokenHash"`
	AgentID          string   `json:"agentId"`
	AccountID        string   `json:"accountId"`
	Name             string   `json:"name"`
	Model            *string  `json:"model"`
	AppVersion       *string  `json:"appVersion"`
	CreatedAt        int64    `json:"createdAt"`
	ExpiresAt        int64    `json:"expiresAt"`
	LastSeenAt       *int64   `json:"lastSeenAt"`
	RevokedAt        *int64   `json:"revokedAt"`
	APNSToken        *string  `json:"apnsToken"`
	APNSEnv          *string  `json:"apnsEnv"`
	PushTurnEnd      int      `json:"pushTurnEnd"`
	PushAttention    int      `json:"pushAttention"`
	PushUpdatedAt    *int64   `json:"pushUpdatedAt"`
	DeviceKey        *string  `json:"deviceKey"`
	ConnectorVersion *string  `json:"connectorVersion"`
	HostVersion      *string  `json:"hostVersion"`
	VersionsAt       *int64   `json:"versionsAt"`
	Push             pushInfo `json:"push"`
}

// maskPrefix 复刻 admin.py 的打码：保留前 n 个字符再加省略号。
func maskPrefix(value string, n int) string {
	if len(value) <= n {
		return value + "…"
	}
	return value[:n] + "…"
}

// runDeviceList 实现 device-list [--agent] [--all]。
func runDeviceList(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdDeviceList, stderr)
	agentRef := fs.String("agent", "", "只看这台电脑（默认整个库）")
	includeRevoked := fs.Bool("all", false, "包含已撤销的设备")
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

	devices, err := st.ListDevices(ctx, agentID, *includeRevoked)
	if err != nil {
		return err
	}
	agents, err := st.ListAgents(ctx, "")
	if err != nil {
		return err
	}
	versions := make(map[string]store.Agent, len(agents))
	for _, agent := range agents {
		versions[agent.AgentID] = agent
	}

	rows := make([]deviceListEntry, 0, len(devices))
	for _, device := range devices {
		agent := versions[device.AgentID]
		entry := deviceListEntry{
			DeviceID: device.DeviceID, DeviceTokenHash: maskPrefix(device.DeviceTokenHash, 12),
			AgentID: device.AgentID, AccountID: device.AccountID, Name: device.Name,
			Model: device.Model, AppVersion: device.AppVersion, CreatedAt: device.CreatedAt,
			ExpiresAt: device.ExpiresAt, LastSeenAt: device.LastSeenAt,
			RevokedAt: device.RevokedAt, APNSEnv: device.APNSEnv,
			PushTurnEnd: device.PushTurnEnd, PushAttention: device.PushAttention,
			PushUpdatedAt: device.PushUpdatedAt, DeviceKey: device.DeviceKey,
			ConnectorVersion: agent.ConnectorVersion, HostVersion: agent.HostVersion,
			VersionsAt: agent.VersionsAt,
		}
		if device.APNSToken != nil {
			masked := maskPrefix(*device.APNSToken, 8)
			entry.APNSToken = &masked
		}
		entry.Push = pushInfo{
			Registered: device.APNSToken != nil,
			Env:        device.APNSEnv,
			TurnEnd:    device.PushTurnEnd != 0,
			Attention:  device.PushAttention != 0,
			UpdatedAt:  device.PushUpdatedAt,
		}
		rows = append(rows, entry)
	}
	return emit(stdout, rows)
}

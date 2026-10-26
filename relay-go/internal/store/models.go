package store

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
)

// scanner 是 *sql.Row 与 *sql.Rows 共有的读取接口。
type scanner interface {
	Scan(dest ...any) error
}

// Account 是一行 accounts。
type Account struct {
	AccountID string `json:"accountId"`
	Name      string `json:"name"`
	CreatedAt int64  `json:"createdAt"`
}

// Agent 是一行 agents。Nullable 列用指针，JSON 里输出 null（与 Python dict 一致）。
type Agent struct {
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

// Device 是一行 devices（列序与 Python SCHEMA 一致）。
type Device struct {
	DeviceID        string  `json:"deviceId"`
	DeviceTokenHash string  `json:"deviceTokenHash"`
	AgentID         string  `json:"agentId"`
	AccountID       string  `json:"accountId"`
	Name            string  `json:"name"`
	Model           *string `json:"model"`
	AppVersion      *string `json:"appVersion"`
	CreatedAt       int64   `json:"createdAt"`
	ExpiresAt       int64   `json:"expiresAt"`
	LastSeenAt      *int64  `json:"lastSeenAt"`
	RevokedAt       *int64  `json:"revokedAt"`
	APNSToken       *string `json:"apnsToken"`
	APNSEnv         *string `json:"apnsEnv"`
	PushTurnEnd     int     `json:"pushTurnEnd"`
	PushAttention   int     `json:"pushAttention"`
	PushUpdatedAt   *int64  `json:"pushUpdatedAt"`
	DeviceKey       *string `json:"deviceKey"`
}

// PairCode 是一行 pairCodes。
type PairCode struct {
	CodeHash   string
	AgentID    string
	AccountID  string
	CreatedAt  int64
	ExpiresAt  *int64
	UsedAt     *int64
	DeviceID   *string
	RevokedAt  *int64
	LastUsedAt *int64
	UseCount   int
}

// Invite 是一行 invites。
type Invite struct {
	CodeHash      string  `json:"codeHash"`
	CreatedAt     int64   `json:"createdAt"`
	ExpiresAt     int64   `json:"expiresAt"`
	UsedAt        *int64  `json:"usedAt"`
	UsedByAgentID *string `json:"usedByAgentId"`
	Note          *string `json:"note"`
}

// StateValue 是账户状态条目在 JSON 里的形状（Python account_state 的 value 结构）。
type StateValue struct {
	Value             any     `json:"value"`
	UpdatedAt         int64   `json:"updatedAt"`
	UpdatedByDeviceID *string `json:"updatedByDeviceId"`
}

// StoredState 是 PUT /account/state 响应里一条写入结果。
//
// 与读取路径的 StateValue 分成两个类型，是因为 Python 版的 PUT 会在每条 stored
// 里带上 "key"，而 GET 的 entries 是按 key 索引的对象、条目里没有 "key"。
type StoredState struct {
	Key               string  `json:"key"`
	Value             any     `json:"value"`
	UpdatedAt         int64   `json:"updatedAt"`
	UpdatedByDeviceID *string `json:"updatedByDeviceId"`
}

// PutStateResult 是一次写入的结果；Applied=false 表示已存的时间戳更新，本次未覆盖。
type PutStateResult struct {
	Key     string
	Applied bool
	Stored  StoredState
}

// BatchPutResult 是一批写入的结果：Applied 按入参顺序，Stored 按 key 覆盖。
type BatchPutResult struct {
	Applied []string
	Stored  map[string]StoredState
}

// Hygiene 是设备记录的健康计数（Python device_hygiene 的返回）。
type Hygiene struct {
	Total   int    `json:"total"`
	Live    int    `json:"live"`
	Revoked int    `json:"revoked"`
	Expired int    `json:"expired"`
	Dead    int    `json:"dead"`
	AgentID string `json:"agentId,omitempty"`
}

// UsageRow 是一行 usageDaily。
type UsageRow struct {
	Day         int64   `json:"day"`
	DeviceID    string  `json:"deviceId"`
	AgentID     string  `json:"agentId"`
	AccountID   string  `json:"accountId"`
	EgressBytes int64   `json:"egressBytes"`
	Connections int64   `json:"connections"`
	Prompts     int64   `json:"prompts"`
	Answers     int64   `json:"answers"`
	FirstSeenAt int64   `json:"firstSeenAt"`
	LastSeenAt  int64   `json:"lastSeenAt"`
	LastBuild   *string `json:"lastBuild"`
}

// UsageTotal 是 `admin usage` 的一行：按账号或按设备汇总的每日用量。
//
// AccountID / DeviceID 只有一个出现（与 Python 的 `SELECT u.{key}` 同形），所以两个
// 字段都用 omitempty 指针：JSON 里不会出现一个恒为 null 的另一种键。
type UsageTotal struct {
	Day         int64   `json:"day"`
	AccountID   *string `json:"accountId,omitempty"`
	DeviceID    *string `json:"deviceId,omitempty"`
	Name        *string `json:"name"`
	EgressBytes int64   `json:"egressBytes"`
	Connections int64   `json:"connections"`
	Prompts     int64   `json:"prompts"`
	Answers     int64   `json:"answers"`
	LastSeenAt  int64   `json:"lastSeenAt"`
	LastBuild   *string `json:"lastBuild"`
	Devices     int     `json:"devices"`
}

// UsageEntry 是一次用量增量（AddUsage 的入参）。
type UsageEntry struct {
	Day         int64
	DeviceID    string
	AgentID     string
	AccountID   string
	EgressBytes int64
	Connections int64
	Prompts     int64
	Answers     int64
	At          int64
	LastBuild   *string
}

// TodayDevice 是 /stats 里 today.devices 的一行。
type TodayDevice struct {
	DeviceID    string  `json:"deviceId"`
	AgentID     string  `json:"agentId"`
	AccountID   string  `json:"accountId"`
	EgressBytes int64   `json:"egressBytes"`
	Connections int64   `json:"connections"`
	Prompts     int64   `json:"prompts"`
	Answers     int64   `json:"answers"`
	LastBuild   *string `json:"lastBuild"`
}

// TodayAccount 是 /stats 里 today.accounts 的一行。
type TodayAccount struct {
	AccountID   string `json:"accountId"`
	EgressBytes int64  `json:"egressBytes"`
	Devices     int    `json:"devices"`
}

// TodayUsage 是 /stats 里 today 的完整形状（Python hub.usage_today）。
type TodayUsage struct {
	Day              int64          `json:"day"`
	TotalEgressBytes int64          `json:"totalEgressBytes"`
	TotalPrompts     int64          `json:"totalPrompts"`
	TotalAnswers     int64          `json:"totalAnswers"`
	Devices          []TodayDevice  `json:"devices"`
	Accounts         []TodayAccount `json:"accounts"`
}

// ClaimResult 是一次配对码认领的结果。
type ClaimResult struct {
	AgentID     string
	AgentName   string
	AccountID   string
	DeviceID    string
	DeviceToken string
	ExpiresAt   int64
	Reused      bool
}

// RefreshResult 是一次设备令牌轮换的结果。
type RefreshResult struct {
	DeviceID    string
	AgentID     string
	AccountID   string
	DeviceToken string
	ExpiresAt   int64
}

// MintedPairCode 是铸码的结果（Python mint_pair_code 的返回）。
type MintedPairCode struct {
	Code       string `json:"code"`
	ExpiresAt  *int64 `json:"expiresAt"`
	AgentID    string `json:"agentId"`
	TTLMs      *int64 `json:"ttlMs"`
	Persistent bool   `json:"persistent"`
}

// MintedInvite 是铸邀请码的结果（Python mint_invite 的返回）。
type MintedInvite struct {
	Code      string  `json:"code"`
	ExpiresAt int64   `json:"expiresAt"`
	TTLMs     int64   `json:"ttlMs"`
	Note      *string `json:"note"`
}

// InviteStatus 是邀请码状态（Python invite_status 的返回）。
type InviteStatus struct {
	Exists        bool    `json:"exists"`
	State         string  `json:"state,omitempty"`
	ExpiresAt     *int64  `json:"expiresAt,omitempty"`
	UsedAt        *int64  `json:"usedAt,omitempty"`
	UsedByAgentID *string `json:"usedByAgentId,omitempty"`
}

// EnrolledIdentity 是兑换邀请码建出的身份（Python claim_invite 的返回）。
type EnrolledIdentity struct {
	AccountID   string
	AgentID     string
	AgentName   string
	AgentSecret string
	InviteNote  *string
}

// RevokeInviteResult 是作废邀请码的结果（Python revoke_invite 的返回）。
type RevokeInviteResult struct {
	Revoked       bool    `json:"revoked"`
	Reason        string  `json:"reason,omitempty"`
	CodeHash      string  `json:"codeHash,omitempty"`
	Note          *string `json:"note,omitempty"`
	ExpiresAt     *int64  `json:"expiresAt,omitempty"`
	UsedAt        *int64  `json:"usedAt,omitempty"`
	UsedByAgentID *string `json:"usedByAgentId,omitempty"`
}

// Enrollment 是"谁兑换了邀请码"的一行（Python list_enrollments）。
type Enrollment struct {
	UsedAt      int64   `json:"usedAt"`
	InviteNote  *string `json:"inviteNote"`
	AccountID   string  `json:"accountId"`
	AccountName *string `json:"accountName"`
	AgentID     string  `json:"agentId"`
	AgentName   string  `json:"agentName"`
	Devices     int     `json:"devices"`
	LastSeenAt  *int64  `json:"lastSeenAt"`
}

// InviteTotals 是邀请码账目（Python invite_totals）。
type InviteTotals struct {
	Minted    int `json:"minted"`
	Used      int `json:"used"`
	Remaining int `json:"remaining"`
}

const agentColumns = "agentId, accountId, name, secretHash, createdAt, updatedAt, disabled," +
	" lastSeenAt, connectorVersion, hostVersion, versionsAt"

const deviceColumns = "deviceId, deviceTokenHash, agentId, accountId, name, model, appVersion," +
	" createdAt, expiresAt, lastSeenAt, revokedAt, apnsToken, apnsEnv, pushTurnEnd," +
	" pushAttention, pushUpdatedAt, deviceKey"

const pairCodeColumns = "codeHash, agentId, accountId, createdAt, expiresAt, usedAt, deviceId," +
	" revokedAt, lastUsedAt, useCount"

const inviteColumns = "codeHash, createdAt, expiresAt, usedAt, usedByAgentId, note"

func scanAgent(row scanner) (Agent, error) {
	var (
		agent                         Agent
		lastSeen, versionsAt          sql.NullInt64
		connectorVersion, hostVersion sql.NullString
	)
	err := row.Scan(&agent.AgentID, &agent.AccountID, &agent.Name, &agent.SecretHash,
		&agent.CreatedAt, &agent.UpdatedAt, &agent.Disabled, &lastSeen,
		&connectorVersion, &hostVersion, &versionsAt)
	if err != nil {
		return Agent{}, err
	}
	agent.LastSeenAt = nullInt64(lastSeen)
	agent.ConnectorVersion = nullString(connectorVersion)
	agent.HostVersion = nullString(hostVersion)
	agent.VersionsAt = nullInt64(versionsAt)
	return agent, nil
}

func scanDevice(row scanner) (Device, error) {
	var (
		device                                           Device
		model, appVersion, apnsToken, apnsEnv, deviceKey sql.NullString
		lastSeen, revokedAt, pushUpdatedAt               sql.NullInt64
	)
	err := row.Scan(&device.DeviceID, &device.DeviceTokenHash, &device.AgentID,
		&device.AccountID, &device.Name, &model, &appVersion, &device.CreatedAt,
		&device.ExpiresAt, &lastSeen, &revokedAt, &apnsToken, &apnsEnv,
		&device.PushTurnEnd, &device.PushAttention, &pushUpdatedAt, &deviceKey)
	if err != nil {
		return Device{}, err
	}
	device.Model = nullString(model)
	device.AppVersion = nullString(appVersion)
	device.LastSeenAt = nullInt64(lastSeen)
	device.RevokedAt = nullInt64(revokedAt)
	device.APNSToken = nullString(apnsToken)
	device.APNSEnv = nullString(apnsEnv)
	device.PushUpdatedAt = nullInt64(pushUpdatedAt)
	device.DeviceKey = nullString(deviceKey)
	return device, nil
}

func scanPairCode(row scanner) (PairCode, error) {
	var (
		code                                     PairCode
		expiresAt, usedAt, revokedAt, lastUsedAt sql.NullInt64
		deviceID                                 sql.NullString
	)
	err := row.Scan(&code.CodeHash, &code.AgentID, &code.AccountID, &code.CreatedAt,
		&expiresAt, &usedAt, &deviceID, &revokedAt, &lastUsedAt, &code.UseCount)
	if err != nil {
		return PairCode{}, err
	}
	code.ExpiresAt = nullInt64(expiresAt)
	code.UsedAt = nullInt64(usedAt)
	code.DeviceID = nullString(deviceID)
	code.RevokedAt = nullInt64(revokedAt)
	code.LastUsedAt = nullInt64(lastUsedAt)
	return code, nil
}

func scanInvite(row scanner) (Invite, error) {
	var (
		invite              Invite
		usedAt              sql.NullInt64
		usedByAgentID, note sql.NullString
	)
	err := row.Scan(&invite.CodeHash, &invite.CreatedAt, &invite.ExpiresAt, &usedAt,
		&usedByAgentID, &note)
	if err != nil {
		return Invite{}, err
	}
	invite.UsedAt = nullInt64(usedAt)
	invite.UsedByAgentID = nullString(usedByAgentID)
	invite.Note = nullString(note)
	return invite, nil
}

func nullInt64(value sql.NullInt64) *int64 {
	if !value.Valid {
		return nil
	}
	out := value.Int64
	return &out
}

func nullString(value sql.NullString) *string {
	if !value.Valid {
		return nil
	}
	out := value.String
	return &out
}

// decodeStateValue 把库里存的 JSON 文本解析成响应里的值。
//
// 解析不出来（手工写坏、旧格式）时按字符串原样返回，与 Python 版一致：一条坏状态
// 不该让整次读取失败。
func decodeStateValue(raw string) any {
	if json.Valid([]byte(raw)) {
		return json.RawMessage(raw)
	}
	return raw
}

// encodeStateValue 把请求里的 JSON 值压缩成库里存的那份文本。
//
// Python 侧是 json.dumps(value, ensure_ascii=False, separators=(",", ":"))；
// 这里保留客户端原始 JSON 的语义与紧凑形式（不重排键），两者可被同一套读取端解析。
func encodeStateValue(raw json.RawMessage) (string, error) {
	if len(raw) == 0 {
		return "null", nil
	}
	var compacted bytes.Buffer
	if err := json.Compact(&compacted, raw); err != nil {
		return "", fmt.Errorf("account state value 不是合法 JSON: %w", err)
	}
	return compacted.String(), nil
}

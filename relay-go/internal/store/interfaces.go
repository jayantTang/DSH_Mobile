package store

import "context"

// 本文件是 Store 的**领域分类**，不是消费者依赖的字段类型。
//
// 三个用途（DESIGN-20261023 §2.4）：
//
//  1. 固定"每个方法属于哪个领域"，Store 再长方法时必须先回答归属；
//  2. 给覆盖测试一份可核对的清单（interfaces_test.go 用反射逐项核对）；
//  3. 让"消费者只依赖自己用到的方法"有子集可依据——各包的端口必须是这里
//     某个领域接口的子集（DESIGN §2.5）。
//
// 方法签名与 *Store 的现有实现逐字一致：这里只是分组，不改 SQL、不改返回值、
// 不改错误映射。新增 Store 方法时，先决定它属于哪个领域，再同时改接口与测试。

// 编译期断言：*Store 必须同时实现全部领域接口。任何一个方法被改名或改签名，
// 这里先红，而不是等到某个消费者的端口断言才发现。
var (
	_ AccountStore      = (*Store)(nil)
	_ AgentStore        = (*Store)(nil)
	_ PairStore         = (*Store)(nil)
	_ DeviceStore       = (*Store)(nil)
	_ AccountStateStore = (*Store)(nil)
	_ FeedbackStore     = (*Store)(nil)
	_ UsageStore        = (*Store)(nil)
	_ InviteStore       = (*Store)(nil)
	_ MaintenanceStore  = (*Store)(nil)
)

// AccountStore 是账户生命周期：建、查、列。
//
// 边界：账户本身没有可变的运营状态（名称建后不改）；账户下的电脑归 AgentStore，
// 账户级状态位归 AccountStateStore，账户下的设备归 DeviceStore。
type AccountStore interface {
	CreateAccount(ctx context.Context, name string) (Account, error)
	GetAccount(ctx context.Context, accountID string) (Account, bool, error)
	ListAccounts(ctx context.Context) ([]Account, error)
}

// AgentStore 是"电脑身份"：注册、停用、按 id/密钥查、lastSeen、版本上报。
//
// 边界：一台电脑的凭据与展示字段归这里；它名下的设备行、令牌与推送登记归
// DeviceStore；配对码归 PairStore。
type AgentStore interface {
	RegisterAgent(ctx context.Context, accountID, name string, agentID *string) (Agent, string, error)
	SetAgentDisabled(ctx context.Context, agentID string, disabled bool) error
	AgentByID(ctx context.Context, agentID string) (Agent, bool, error)
	AgentBySecret(ctx context.Context, secret string) (Agent, bool, error)
	ListAgents(ctx context.Context, accountID string) ([]Agent, error)
	TouchAgent(ctx context.Context, agentID string, at int64) error
	SetAgentVersions(ctx context.Context, agentID string, connectorVersion, hostVersion *string, at int64) error
}

// PairStore 是配对码：铸造、重新生成、认领、过期清理。
//
// 边界：配对码是"一次性凭据"，认领成功后产生设备行（归 DeviceStore）——本接口
// 只负责码本身的状态迁移，不负责设备之后的生命周期。
type PairStore interface {
	MintPairCode(ctx context.Context, agentID string, ttlMS *int64) (MintedPairCode, error)
	RegeneratePairCode(ctx context.Context, agentID string, ttlMS *int64) (MintedPairCode, int64, error)
	ClaimPairCode(ctx context.Context, code string, params ClaimParams) (ClaimResult, error)
	PurgeExpired(ctx context.Context, at int64) (int64, error)
}

// DeviceStore 是设备行：令牌解析、身份查询、撤销/过期判定、推送登记、lastSeen。
//
// 边界：一行设备记录的全生命周期都在这里；"设备现在在不在线"不在这里（那是
// hub 的连接图）；账户级状态归 AccountStateStore。
type DeviceStore interface {
	DeviceByToken(ctx context.Context, token string) (Device, bool, error)
	DeviceByID(ctx context.Context, deviceID string) (Device, bool, error)
	RevokedIDsAmong(ctx context.Context, deviceIDs []string) (map[string]struct{}, error)
	GoneIDsAmong(ctx context.Context, deviceIDs []string) (map[string]struct{}, error)
	ExpiredIDsOfAgent(ctx context.Context, agentID string) (map[string]struct{}, error)
	DeviceHygiene(ctx context.Context, agentID string) (Hygiene, error)
	ListDevices(ctx context.Context, agentID string, includeRevoked bool) ([]Device, error)
	RefreshDevice(ctx context.Context, token string, ttlMS int64) (RefreshResult, error)
	RevokeDevice(ctx context.Context, deviceID string) error
	SetPush(ctx context.Context, deviceID string, token, env *string, turnEnd, attention bool) error
	ClearPush(ctx context.Context, deviceID string) error
	PushTargets(ctx context.Context, agentID string) ([]Device, error)
	SetDeviceAppVersion(ctx context.Context, deviceID, version string) error
	TouchDevice(ctx context.Context, deviceID string, at int64) error
	CountPairedDevices(ctx context.Context, accountID string) (int, error)
}

// AccountStateStore 是账户级键值状态（多设备同步的那一份）。
//
// 边界：键值状态本身与它的批量写事务；"状态变了要通知谁"是 hub 的事，不在
// 仓储层。
type AccountStateStore interface {
	AccountState(ctx context.Context, accountID string, keys []string) (map[string]StateValue, error)
	PutAccountState(ctx context.Context, accountID string, write StateWrite, deviceID *string) (PutStateResult, error)
	PutAccountStateBatch(ctx context.Context, accountID string, writes []StateWrite, deviceID *string) (BatchPutResult, error)
}

// FeedbackStore 是反馈通道的持久面：线程、留言、通知、已读水位、摘要。
//
// 边界：既服务用户侧四个端点也服务 owner 侧运维命令，但**两边的写入口不同**
// （用户侧 CreateFeedbackThread/AppendFeedbackMessage，owner 侧 CreateNotice 等）；
// 用户侧端点只能拿到它在 ports 里声明的 9 个方法（DESIGN §2.5）。
type FeedbackStore interface {
	CreateFeedbackThread(ctx context.Context, in CreateFeedbackThreadInput) (CreatedFeedbackThread, error)
	SetFeedbackSubject(ctx context.Context, threadID string, subject *string) (bool, error)
	AppendFeedbackMessage(ctx context.Context, in AppendFeedbackInput) (*AppendedFeedbackMessage, error)
	CreateNotice(ctx context.Context, in CreateNoticeInput) (CreatedNotice, error)
	FeedbackThread(ctx context.Context, threadID string, ticketHash *string, messagesPerThread int) (*FeedbackThread, error)
	FeedbackThreadsByTickets(ctx context.Context, pairs []TicketPair, messagesPerThread int) ([]FeedbackThread, error)
	FeedbackThreadsByDevice(ctx context.Context, deviceID string, accountID *string, messagesPerThread int) ([]FeedbackThread, error)
	MarkThreadRead(ctx context.Context, threadID string, uptoMS *int64) (bool, error)
	NoticesForAccount(ctx context.Context, accountID string, limit int) ([]Notice, error)
	MarkNoticesRead(ctx context.Context, accountID string, notices []string, at int64) (int64, error)
	OwnerUnreadCounts(ctx context.Context) (map[string]int, error)
	TouchOwnerRead(ctx context.Context, threadID string, at int64) (bool, error)
	ListFeedbackThreads(ctx context.Context, status *string, sinceMS *int64, limit int, messagesPerThread int) ([]FeedbackThread, error)
	DeleteFeedbackThread(ctx context.Context, threadID string) (int64, error)
	FeedbackDigest(ctx context.Context, threadIDs []string, excerptChars int) (map[string]FeedbackDigestEntry, error)
}

// UsageStore 是日用量账本：增量落盘与几种读法（按设备、按天、按维度汇总）。
//
// 边界：只存"已经写出去了多少字节"，不判额度；额度判定与内存账本在 hub
// （步骤 2 之后在 quota 包）。
type UsageStore interface {
	AddUsage(ctx context.Context, entries []UsageEntry) (int, error)
	UsageRows(ctx context.Context, day int64) ([]UsageRow, error)
	UsageBytesOn(ctx context.Context, day int64, deviceID string) (int64, error)
	UsageTotals(ctx context.Context, days int, by string) ([]UsageTotal, error)
	TodayUsage(ctx context.Context, day int64) (TodayUsage, error)
}

// InviteStore 是邀请码与自助登记：铸造、查询、认领、撤销、过期清理、登记明细。
//
// 边界：邀请码的发放与消耗；认领成功后产生的账户/电脑仍由 Account/Agent 领域
// 写，本接口只回答"这张码还能不能用、用了之后是谁"。
type InviteStore interface {
	MintInvite(ctx context.Context, ttlMS int64, note *string, code string) (MintedInvite, error)
	InviteStatus(ctx context.Context, code string) (InviteStatus, error)
	ClaimInvite(ctx context.Context, code, name string, limiter FailureLimiter, countKey, clientKey string) (EnrolledIdentity, error)
	ListInvites(ctx context.Context, includeUsed bool) ([]Invite, error)
	RevokeInvite(ctx context.Context, code string, at int64) (RevokeInviteResult, error)
	PurgeInvites(ctx context.Context, at int64) (int64, error)
	InviteTotals(ctx context.Context) (InviteTotals, error)
	ListEnrollments(ctx context.Context) ([]Enrollment, error)
}

// MaintenanceStore 是跨实体的运维动作：清理、备份、以及清理前的点数。
//
// 边界：这些方法不属于任何一个业务实体领域（它们同时看账户/电脑/设备），单列
// 是为了避免把它们塞进 DeviceStore 或 AgentStore 里假装属于某个实体。
type MaintenanceStore interface {
	AgentIDsWithDevices(ctx context.Context) ([]string, error)
	DevicePurgeReport(ctx context.Context, agentIDs []string, now int64) ([]DevicePurgeAgent, error)
	DeleteDoomedDevices(ctx context.Context, agentIDs []string, now int64) (int64, error)
	CountDevicesOfAgents(ctx context.Context, agentIDs []string) (map[string]int, error)
	BackupTo(ctx context.Context, path string) error
}

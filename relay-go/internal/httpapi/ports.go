package httpapi

import (
	"context"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// Store 是 HTTP 面**自己**需要的仓储端口（DESIGN-20261023 §2.5：15 个方法）。
//
// 它故意不是 wsapi/files/feedback 端口的并集：那三个子 handler 由组合根
// （cmd/dsh-relay/main.go）分别构造并注入，各自只拿自己的最小端口。httpapi 只
// 保留路由、中间件、CORS、限流与这 15 个方法。
//
// 领域归属：AccountStateStore、DeviceStore、InviteStore、PairStore、AgentStore
// 的子集。
type Store interface {
	// AccountStateStore 子集：账户状态的批量读写。
	AccountState(ctx context.Context, accountID string, keys []string) (map[string]store.StateValue, error)
	PutAccountStateBatch(ctx context.Context, accountID string, writes []store.StateWrite, deviceID *string) (store.BatchPutResult, error)

	// DeviceStore 子集：设备列表/查找/撤销/推送登记/卫生检查。
	ListDevices(ctx context.Context, agentID string, includeRevoked bool) ([]store.Device, error)
	CountPairedDevices(ctx context.Context, accountID string) (int, error)
	DeviceByID(ctx context.Context, deviceID string) (store.Device, bool, error)
	DeviceByToken(ctx context.Context, token string) (store.Device, bool, error)
	RevokeDevice(ctx context.Context, deviceID string) error
	SetPush(ctx context.Context, deviceID string, token, env *string, turnEnd, attention bool) error
	DeviceHygiene(ctx context.Context, agentID string) (store.Hygiene, error)

	// InviteStore / PairStore / AgentStore 子集：自助登记与配对码。
	ClaimInvite(ctx context.Context, code, name string, limiter store.FailureLimiter, countKey, clientKey string) (store.EnrolledIdentity, error)
	ClaimPairCode(ctx context.Context, code string, params store.ClaimParams) (store.ClaimResult, error)
	RefreshDevice(ctx context.Context, token string, ttlMS int64) (store.RefreshResult, error)
	MintPairCode(ctx context.Context, agentID string, ttlMS *int64) (store.MintedPairCode, error)
	RegeneratePairCode(ctx context.Context, agentID string, ttlMS *int64) (store.MintedPairCode, int64, error)
	AgentBySecret(ctx context.Context, secret string) (store.Agent, bool, error)
}

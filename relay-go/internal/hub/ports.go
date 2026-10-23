package hub

import (
	"context"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// Store 是 hub 需要的最小仓储端口（DESIGN-20261023 §2.5：10 个方法）。
//
// 它不是"Store 的另一个名字"：这 10 个方法就是 hub 在生产代码里真正调用的全部
// 仓储面（attach 时通知设备清单、控制帧里上报版本、后台冲盘与撤销对账）。转发
// 数据热路径**没有** Store 调用，所以端口收窄不会给每帧增加动态派发。
//
// 领域归属见 internal/store/interfaces.go：本端口是 DeviceStore、UsageStore 的
// 子集。仓储的具体实现类型只允许出现在组合根与运维例外（admincli/purge）。
type Store interface {
	// DeviceStore 子集：设备清单、过期/撤销判定、版本与推送登记。
	SetAgentVersions(ctx context.Context, agentID string, connectorVersion, hostVersion *string, at int64) error
	ListDevices(ctx context.Context, agentID string, includeRevoked bool) ([]store.Device, error)
	ExpiredIDsOfAgent(ctx context.Context, agentID string) (map[string]struct{}, error)
	RevokedIDsAmong(ctx context.Context, deviceIDs []string) (map[string]struct{}, error)
	SetDeviceAppVersion(ctx context.Context, deviceID, version string) error
	PushTargets(ctx context.Context, agentID string) ([]store.Device, error)
	ClearPush(ctx context.Context, deviceID string) error

	// UsageStore 子集：额度基线、冲盘与"今日"查询。
	UsageBytesOn(ctx context.Context, day int64, deviceID string) (int64, error)
	AddUsage(ctx context.Context, entries []store.UsageEntry) (int, error)
	TodayUsage(ctx context.Context, day int64) (store.TodayUsage, error)
}

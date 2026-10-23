package wsapi

import (
	"context"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// Store 是 WS 端点在**握手期**需要的仓储面（DESIGN-20261023 §2.5：4 个方法）。
//
// 读循环开始之后不再有仓储调用：帧的转发、队列、心跳全部经由 hub 与 Link。
// 因此这里的端口小是结构性的，不是为了数字好看。
//
// 领域归属：前两个方法属于 AgentStore / DeviceStore，后两个是 lastSeen 更新。
type Store interface {
	AgentBySecret(ctx context.Context, secret string) (store.Agent, bool, error)
	DeviceByToken(ctx context.Context, token string) (store.Device, bool, error)
	TouchAgent(ctx context.Context, agentID string, at int64) error
	TouchDevice(ctx context.Context, deviceID string, at int64) error
}

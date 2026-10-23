package files

import (
	"context"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/bridge"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// Store 是文件端点需要的唯一仓储方法（DESIGN-20261023 §2.5：1 个方法）。
//
// 两条文件端点只认设备令牌：上传/下载的桥状态机在 internal/bridge，字节额度在
// Link，仓储层只负责"这个令牌是谁"。因此这里不需要 ListDevices 或推送方法。
type Store interface {
	DeviceByToken(ctx context.Context, token string) (store.Device, bool, error)
}

// Hub 是文件端点需要的连接与桥门面（DESIGN-20261023 §2.2 / §3.6）。
//
// 这里只列文件通道真正调用的 11 个方法；*hub.Hub 全部满足，组合根注入的仍是
// 同一个实例。它**不**暴露分片 map、registry 或 Link 的内部状态：文件端点通过
// 门面拿连接、开/关桥、发控制帧与记账，不能从 Hub 上另走一条旁路。
//
// 返回的连接类型（*hub.AgentLink / *hub.DeviceLink）仍由 hub 定义：它们分别是
// 桥字节额度与 HTTP 下载限速/出口记账的入口，步骤 3 已明确留在 Link 上；端口
// 固定的是"允许调用哪些方法"，不是重新包装这些值类型。
type Hub interface {
	Agent(agentID string) *hub.AgentLink
	Device(deviceID string) *hub.DeviceLink

	OpenPutBridge(bid string, agent *hub.AgentLink) *bridge.PutBridge
	OpenFetchBridge(bid string, agent *hub.AgentLink) *bridge.FetchBridge
	CloseBridge(bid string)
	CancelFetch(link *hub.AgentLink, fetch *bridge.FetchBridge)

	SendControl(link hub.Target, frame dlp.Frame)
	SendBridgeChunk(link *hub.AgentLink, frame dlp.Frame, creditBytes int64) bool

	SeatDeviceQuota(ctx context.Context, deviceID string)
	DeviceQuotaRemaining(deviceID string) int64
	ChargeDeviceQuota(deviceID string, size int) (bool, int64)
}

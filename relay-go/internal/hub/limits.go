package hub

import (
	"context"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/config"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// Limits 是 hub 的全部可调项，也是 `/stats` 里 limits 段的唯一来源。
//
// 这些值来自启动参数（config.Config），但**行为与展示都从这里读**：/stats 报的和
// 转发实行的必须是同一份数，否则运维看到的限额与真正生效的限额会悄悄分叉。
//
// 额度与令牌桶的**状态**在 internal/quota（DESIGN §3.3）；这里只保留配置值与展示。
type Limits struct {
	MaxFrameBytes   int
	QueueDepth      int
	AgentQueueDepth int
	// QueueBytes 是每连接队列的字节上限（M2.5 新增）：深度只约束帧数，
	// 大帧会把帧数很少的队列撑到几百 MiB。0 = 只按 MaxFrameBytes 兜底。
	QueueBytes int64
	// BridgeBytes 是每条连接器链路上文件上行桥的在途字节上限（M4a 新增）。
	//
	// 上行分片是 ClassControl（丢一片就是坏一次上传），绕过 QueueBytes；没有这项
	// 额度时，慢连接器能把 4096 深度的队列堆到 4096 × 1.33 MB。它约束的是**排队
	// 帧的字节数**，额度不足时上传 handler 停止读请求体（真正的背压）。
	BridgeBytes             int64
	MaxDevicesPerAgent      int
	DeviceBytesPerSecond    float64
	DeviceDailyBytes        int64
	DeadDeviceWarnThreshold int
}

// DefaultLimits 是与 Python hub.Limits 一致的默认值。
func DefaultLimits() Limits {
	return Limits{
		MaxFrameBytes:           dlp.MaxFrameBytes,
		QueueDepth:              config.DefaultQueueDepth,
		AgentQueueDepth:         4096,
		QueueBytes:              config.DefaultQueueBytes,
		BridgeBytes:             config.DefaultBridgeBytes,
		MaxDevicesPerAgent:      config.DefaultMaxDevicesPerAgent,
		DeviceBytesPerSecond:    config.DefaultDeviceRateKbps * 1000 / 8,
		DeviceDailyBytes:        int64(config.DefaultDeviceDailyMB * 1024 * 1024),
		DeadDeviceWarnThreshold: config.DefaultDeadDeviceWarnThreshold,
	}
}

// normalize 把非法/零值收敛到可工作的默认值：队列深度为 0 时连接一建立就会满，
// 那不是"不限"，是"不可用"。
func (l Limits) normalize() Limits {
	if l.MaxFrameBytes <= 0 {
		l.MaxFrameBytes = dlp.MaxFrameBytes
	}
	if l.QueueDepth <= 0 {
		l.QueueDepth = config.DefaultQueueDepth
	}
	if l.QueueBytes <= 0 {
		l.QueueBytes = config.DefaultQueueBytes
	}
	if l.BridgeBytes <= 0 {
		l.BridgeBytes = config.DefaultBridgeBytes
	}
	if l.AgentQueueDepth <= 0 {
		l.AgentQueueDepth = 4096
	}
	if l.MaxDevicesPerAgent < 0 {
		l.MaxDevicesPerAgent = 0
	}
	if l.DeviceBytesPerSecond < 0 {
		l.DeviceBytesPerSecond = 0
	}
	if l.DeviceDailyBytes < 0 {
		l.DeviceDailyBytes = 0
	}
	if l.DeadDeviceWarnThreshold < 0 {
		l.DeadDeviceWarnThreshold = 0
	}
	return l
}

// Description 是 `/stats` 里 limits 段的 JSON 形状（Python Limits.describe）。
//
// 0 在 Python 里表示"不限"，输出成 null；这里用指针表达同一个意思。
type Description struct {
	MaxFrameBytes           int      `json:"maxFrameBytes"`
	QueueDepth              int      `json:"queueDepth"`
	AgentQueueDepth         int      `json:"agentQueueDepth"`
	QueueBytes              int64    `json:"queueBytes"`
	BridgeBytes             int64    `json:"bridgeBytes"`
	MaxDevicesPerAgent      *int     `json:"maxDevicesPerAgent"`
	DeviceBytesPerSecond    *float64 `json:"deviceBytesPerSecond"`
	DeviceDailyBytes        *int64   `json:"deviceDailyBytes"`
	DeadDeviceWarnThreshold *int     `json:"deadDeviceWarnThreshold"`
}

// Describe 复刻 Python Limits.describe：0 输出 null。
func (l Limits) Describe() Description {
	described := Description{
		MaxFrameBytes:   l.MaxFrameBytes,
		QueueDepth:      l.QueueDepth,
		AgentQueueDepth: l.AgentQueueDepth,
		QueueBytes:      l.QueueBytes,
		BridgeBytes:     l.BridgeBytes,
	}
	if l.MaxDevicesPerAgent > 0 {
		value := l.MaxDevicesPerAgent
		described.MaxDevicesPerAgent = &value
	}
	if l.DeviceBytesPerSecond > 0 {
		value := l.DeviceBytesPerSecond
		described.DeviceBytesPerSecond = &value
	}
	if l.DeviceDailyBytes > 0 {
		value := l.DeviceDailyBytes
		described.DeviceDailyBytes = &value
	}
	if l.DeadDeviceWarnThreshold > 0 {
		value := l.DeadDeviceWarnThreshold
		described.DeadDeviceWarnThreshold = &value
	}
	return described
}

// ── /files/down 的计费入口 ──────────────────────────────────────────────────

// SeatDeviceQuota 确保这台设备今天的额度基线已从 usageDaily 读出来。
//
// 设备可能没有 WebSocket（HTTP 下载只需要令牌），所以下载路径自己先落座：否则
// 基线是 0，一次下载会凭空获得一整天的额度。已落座时是一次 map 查询。
func (h *Hub) SeatDeviceQuota(ctx context.Context, deviceID string) {
	h.quota.Seat(ctx, deviceID)
}

// DeviceQuotaRemaining 是这台设备今天还剩多少出口字节；-1 表示不限量。
func (h *Hub) DeviceQuotaRemaining(deviceID string) int64 {
	return h.quota.Remaining(deviceID)
}

// ChargeDeviceQuota 记一次出口字节并回答是否仍在额度内。
//
// 与 WebSocket 路径共用同一个账本：下载绕不过去日额度，两边也不会各记一份。
func (h *Hub) ChargeDeviceQuota(deviceID string, size int) (bool, int64) {
	return h.quota.Charge(deviceID, size)
}

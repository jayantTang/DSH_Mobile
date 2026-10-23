package hub

import (
	"context"
	"log/slog"
	"math"
	"sync"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/config"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// Limits 是 hub 的全部可调项，也是 `/stats` 里 limits 段的唯一来源。
//
// 这些值来自启动参数（config.Config），但**行为与展示都从这里读**：/stats 报的和
// 转发实行的必须是同一份数，否则运维看到的限额与真正生效的限额会悄悄分叉。
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

// tokenBucket 是一台设备的每秒字节额度（Python hub.TokenBucket）。
//
// 中转跑在固定带宽的机器上，那份带宽由所有设备共享。一台设备传几张截图（十张就
// 27 MB）就会把整条通道占满几十秒，别人全都变慢。这不是恶意行为，所以做法是限速
// 而不是封禁：桶一开始是满的，并有至少 64 KiB 的突发额度，普通一轮对话完全不会等。
//
// 限速发生在**写循环**里，不是丢弃：帧照常到达，只是摊开在时间上。若在入队时收费，
// 慢下来就会变成队列被填满、进而被判"背压"断开（4008）——那是完全不同的坏消息。
//
// 一个桶会被两条写路径同时使用：WebSocket 写循环与 /files/down 的 HTTP 正文。
// Python 版只有一个事件循环，所以它的 TokenBucket 不需要锁；Go 版必须加，
// 否则一次下载与一条正在转发的连接会在 tokens/updated 上竞争。
type tokenBucket struct {
	mu      sync.Mutex
	rate    float64
	burst   float64
	tokens  float64
	updated time.Time
}

// newTokenBucket 建一个满桶；rate<=0 表示不限速。
func newTokenBucket(rate float64, now time.Time) *tokenBucket {
	bucket := &tokenBucket{rate: math.Max(0, rate), updated: now}
	bucket.burst = math.Max(bucket.rate, 64*1024)
	bucket.tokens = bucket.burst
	return bucket
}

// take 为 n 字节计费，返回发送前应等待的时长。
//
// 正数表示已超额；无论是否超额都立即记账，保证一串小帧按写入顺序排队。
func (b *tokenBucket) take(size int, now time.Time) time.Duration {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.rate <= 0 {
		return 0
	}
	if now.After(b.updated) {
		b.tokens = math.Min(b.burst, b.tokens+now.Sub(b.updated).Seconds()*b.rate)
		b.updated = now
	}
	b.tokens -= float64(size)
	if b.tokens >= 0 {
		return 0
	}
	return time.Duration(-b.tokens / b.rate * float64(time.Second))
}

// quotaLedger 是"每台设备每天已经收了多少字节"的唯一账本。
//
// 与 Python 的一处有意差异：Python 的 DailyQuota 是每个连接一个对象，基线在 attach
// 时从库里读一次；Go 版把计数放在 hub 上、按 **deviceId** 记，所以同一台设备断开
// 重连不会把当天的额度清零（手机换网、锁屏、中转重启都会重连，而"2 GB 一天"说的是
// 一天，不是一个连接）。
//
// 基线仍来自 usageDaily（与运维报表同一份数）。M2 不做周期冲盘（M3 补），所以
// 进程重启后基线只等于上次落库的数——这段差距写在 M2 的未完成项里。
type quotaLedger struct {
	store Store
	limit int64
	log   *slog.Logger
	today func() int64

	mu     sync.Mutex
	day    int64
	used   map[string]int64
	seated map[string]bool
}

func newQuotaLedger(st Store, limit int64, today func() int64, log *slog.Logger) *quotaLedger {
	return &quotaLedger{
		store: st, limit: limit, log: log, today: today,
		used: map[string]int64{}, seated: map[string]bool{},
	}
}

// rollLocked 在跨本地日时把账本清空；调用方必须持有 mu。
func (q *quotaLedger) rollLocked(day int64) {
	if q.day == day {
		return
	}
	q.day = day
	q.used = map[string]int64{}
	q.seated = map[string]bool{}
}

// Seat 为这台设备确定当天的基线，只在本次进程第一次见到它时读库。
//
// 读库失败只记一条告警、把基线当 0：记账出错时宁可给额度，也不能因此拒绝连接。
func (q *quotaLedger) Seat(ctx context.Context, deviceID string) {
	if q.limit <= 0 || q.store == nil {
		return
	}
	day := q.today()
	q.mu.Lock()
	q.rollLocked(day)
	if q.seated[deviceID] {
		q.mu.Unlock()
		return
	}
	q.seated[deviceID] = true
	q.mu.Unlock()

	stored, err := q.store.UsageBytesOn(ctx, day, deviceID)
	if err != nil {
		q.log.Warn("relay: could not read today's usage; starting the allowance from zero",
			"deviceId", deviceID, "error", err)
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.day == day && stored > q.used[deviceID] {
		q.used[deviceID] = stored
	}
}

// Charge 记一次出口字节，返回是否仍在额度内。
//
// 与 Python 的 DailyQuota.charge 同口径：**先记账再判定**，所以把额度撑爆的那一帧
// 本身不会送达（调用方据此发 error 帧再以 4011 关闭）。
func (q *quotaLedger) Charge(deviceID string, size int) (bool, int64) {
	if q.limit <= 0 {
		return true, 0
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.rollLocked(q.today())
	q.used[deviceID] += int64(size)
	used := q.used[deviceID]
	return used <= q.limit, used
}

// Remaining 是这台设备今天还剩多少字节；不限量时返回 -1（Python 同口径）。
func (q *quotaLedger) Remaining(deviceID string) int64 {
	if q.limit <= 0 {
		return -1
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.rollLocked(q.today())
	remaining := q.limit - q.used[deviceID]
	if remaining < 0 {
		return 0
	}
	return remaining
}

// Used 是这台设备今天已经收到的字节（诊断用）。
func (q *quotaLedger) Used(deviceID string) int64 {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.rollLocked(q.today())
	return q.used[deviceID]
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

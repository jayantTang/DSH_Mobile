package hub

import (
	"context"
	"sort"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// 后台周期任务的默认节奏，与 Python hub.RelayHub 的实例属性一致：
//   - 用量冲盘：每 30 秒，或累计 1 MiB 出口字节（跨日无条件冲一次）；
//   - 撤销对账：每 5 秒（DLP_REVOKE_RECONCILE_S；0 或负数关闭）。
const (
	DefaultUsageFlushInterval      = 30 * time.Second
	DefaultUsageFlushBytes         = int64(1 << 20)
	DefaultRevokeReconcileInterval = 5 * time.Second

	// usageWriteTimeout 是单次冲盘/对账查询的上限：一次数据库抖动不能把周期任务
	// 永久挂住（丢失的只是这一次机会，账还在内存里）。
	usageWriteTimeout = 10 * time.Second
)

// StartBackground 起用量冲盘与撤销对账两条周期任务；幂等，随 ctx 结束退出。
//
// 由 main 在服务启动后调用。对账的 try/catch 在**循环体内**（与 Python 一致）：
// 一次数据库抖动绝不能让撤销唯一的兜底停摆。
func (h *Hub) StartBackground(ctx context.Context) {
	h.backgroundOnce.Do(func() {
		if h.usageFlushInterval > 0 {
			// 冲盘循环由 quota 拥有（跨日判断、字节阈值、失败回放都在那边）；
			// hub 只提供两个装配参数。
			go h.usage.Start(ctx, h.usageFlushInterval, h.usageFlushBytes)
		}
		if h.revokeReconcileInterval > 0 {
			h.log.Info("relay: revoke reconcile loop every " +
				h.revokeReconcileInterval.String() + " (0 = off)")
			go h.revokeReconcileLoop(ctx)
		}
		// 连接生命周期扫描：只做一件小事——把「连上超过 helloTimeout 仍没上报
		// 版本」的连接标成 unverified。一次遍历几十个 agent，不是热路径。
		go h.presenceSweepLoop(ctx)
	})
}

// presenceSweepLoop 周期标记未上报版本的连接器。
//
// 为什么不用每条连接一个定时器：连接数会随风暴涨落，每个连接再挂一个 goroutine
// 正是要避免的放大；一个进程级扫描的代价与连接数成正比、次数固定。
func (h *Hub) presenceSweepLoop(ctx context.Context) {
	interval := h.presence.Options().SweepInterval
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			h.sweepUnverified(now)
		}
	}
}

// sweepUnverified 标记一次并记一条 WARN；每条连接最多标记一次。
func (h *Hub) sweepUnverified(now time.Time) {
	for index := range h.agentShards {
		shard := &h.agentShards[index]
		shard.mu.RLock()
		agents := make([]*AgentLink, 0, len(shard.agents))
		for _, agent := range shard.agents {
			agents = append(agents, agent)
		}
		shard.mu.RUnlock()
		for _, agent := range agents {
			if !h.presence.MarkUnverified(agent.AgentID, agent.generation, now) {
				continue
			}
			h.log.Warn("relay: an agent has not reported its connector/host version; "+
				"reconnect backoff armed",
				"agentId", agent.AgentID, "name", agent.Name,
				"connectedFor", now.Sub(agent.attachedAt).String(),
				"helloTimeout", h.presence.Options().HelloTimeout.String())
		}
	}
}

// usageFlushLoop 已迁入 internal/quota（Usage.Start，DESIGN §2.6）：跨日判断、
// 字节阈值与失败回放都跟着账本走，hub 只保留周期任务的装配参数。

// revokeReconcileLoop 是撤销对账的周期任务。
func (h *Hub) revokeReconcileLoop(ctx context.Context) {
	ticker := time.NewTicker(h.revokeReconcileInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		if _, err := h.ReconcileRevokedDevices(ctx); err != nil {
			h.log.Warn("relay: revoke reconcile tick failed", "error", err)
		}
	}
}

// ReconcileRevokedDevices 让在线世界与「库里已撤销」这条唯一事实来源保持一致。
//
// 为什么需要：撤销可能来自中转够不着的地方（admin.py 直接写库、运维手工改库）。
// socket 一旦留在「库已撤、自己还在线」这种状态，那台手机**永远回不来**（令牌已
// 被 DeviceByToken 否掉），而连接器会一直替它留着 $events 值班流。
//
// 只处理**在线**设备，且只因为「已撤销」。令牌过期（配对满 365 天）不在这一臂里：
// 在线 socket 不做重新鉴权，踢它等于打断一条此刻仍能工作的连接；过期残留由
// AttachAgent 的 tellAgentAboutTheGone 收。
//
// 返回被踢的设备 id（排序），供日志与测试断言。
func (h *Hub) ReconcileRevokedDevices(ctx context.Context) ([]string, error) {
	devices := h.allDevices()
	if len(devices) == 0 {
		return nil, nil // 没人在线就不查库
	}
	if h.store == nil {
		return nil, errNoStore
	}
	live := make([]string, 0, len(devices))
	for _, device := range devices {
		live = append(live, device.DeviceID)
	}
	stale, err := h.store.RevokedIDsAmong(ctx, live)
	if err != nil {
		return nil, err
	}
	detached := make([]string, 0, len(stale))
	for deviceID := range stale {
		device := h.Device(deviceID)
		if device == nil {
			continue // 竞态：这一轮里它自己断开了
		}
		h.log.Info("relay: device was revoked in the database but still connected; "+
			"detaching (reason=revoked)", "deviceId", deviceID)
		h.detachDevice(device, "revoked", dlp.CloseGoingAway)
		detached = append(detached, deviceID)
	}
	sort.Strings(detached)
	return detached, nil
}

// flushUsageOnDetach 在设备断开后同步冲一次账。
//
// 与 Python 的 detach_device 一样**在拆除路径上等它**：这一批的尾巴不留在内存里，
// 运维命令跑完就是准的。代价是这条连接（不是整个进程）多一次本地 SQLite 写；
// 时限 usageWriteTimeout 保证数据库卡死时也不会真的挂住（DESIGN §3.3：不改成异步）。
func (h *Hub) flushUsageOnDetach() {
	if !h.usage.Pending() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), usageWriteTimeout)
	defer cancel()
	_ = h.FlushUsage(ctx)
}

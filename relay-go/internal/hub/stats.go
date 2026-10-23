package hub

import (
	"sort"
	"time"
)

// `/stats` 的 live 段：load / traffic / snapshot。
//
// 形状与 Python hub.RelayHub 的对应方法一致，两种差异是**新增字段**（旧读法不受
// 影响）：snapshot 与 traffic 多一个 `droppedFrames`（DESIGN §8 要求丢弃计数可见），
// 背压丢帧不再是静默行为。

// TrafficDevice 是 traffic.devices 的一行。
type TrafficDevice struct {
	DeviceID            string  `json:"deviceId"`
	AgentID             string  `json:"agentId"`
	Name                string  `json:"name"`
	EgressBytes         int64   `json:"egressBytes"`
	PacedSeconds        float64 `json:"pacedSeconds"`
	QuotaRemainingBytes int64   `json:"quotaRemainingBytes"`
	DroppedFrames       int64   `json:"droppedFrames"`
}

// Traffic 是出口流量记账（按设备降序）。
type Traffic struct {
	TotalEgressBytes int64           `json:"totalEgressBytes"`
	Devices          []TrafficDevice `json:"devices"`
}

// SnapshotAgent 是 snapshot.agents 的一行。
type SnapshotAgent struct {
	AgentID       string   `json:"agentId"`
	Name          string   `json:"name"`
	Devices       []string `json:"devices"`
	Pending       int      `json:"pending"`
	QueuedBytes   int64    `json:"queuedBytes"`
	EgressBytes   int64    `json:"egressBytes"`
	DroppedFrames int64    `json:"droppedFrames"`
	// BridgeBytesInUse 是这条链路上文件上行桥已占用的字节（上限见 limits.bridgeBytes）。
	// 慢连接器时它会贴着上限，正好是"背压生效"的观测点。
	BridgeBytesInUse int64 `json:"bridgeBytesInUse"`
}

// SnapshotDevice 是 snapshot.devices 的一行。
type SnapshotDevice struct {
	DeviceID            string  `json:"deviceId"`
	AgentID             string  `json:"agentId"`
	Name                string  `json:"name"`
	Pending             int     `json:"pending"`
	QueuedBytes         int64   `json:"queuedBytes"`
	HostOnline          bool    `json:"hostOnline"`
	EgressBytes         int64   `json:"egressBytes"`
	PacedSeconds        float64 `json:"pacedSeconds"`
	QuotaRemainingBytes int64   `json:"quotaRemainingBytes"`
	DroppedFrames       int64   `json:"droppedFrames"`
}

// Snapshot 是运维看到的实时连接视图。
type Snapshot struct {
	Agents  []SnapshotAgent  `json:"agents"`
	Devices []SnapshotDevice `json:"devices"`
}

// Load 是当前活跃的连接数（/stats 的 load 段）。
func (h *Hub) Load() (agents int, devices int) {
	for index := range h.agentShards {
		shard := &h.agentShards[index]
		shard.mu.RLock()
		agents += len(shard.agents)
		shard.mu.RUnlock()
	}
	return agents, len(h.allDevices())
}

// Traffic 是出口流量记账，最有用的一条排最前。
//
// 机器自己的网卡计数回答不了"哪台电脑在用带宽"（它混进了 SSH、OTA 与机器上其他
// 一切）；这些数字是中转自己的，判断该不该给某台设备更小的额度时看的就是它。
func (h *Hub) Traffic() Traffic {
	devices := h.allDevices()
	sort.Slice(devices, func(i, j int) bool {
		return devices[i].EgressBytes() > devices[j].EgressBytes()
	})
	report := Traffic{TotalEgressBytes: 0, Devices: make([]TrafficDevice, 0, len(devices))}
	for _, device := range devices {
		egress := device.EgressBytes()
		report.TotalEgressBytes += egress
		report.Devices = append(report.Devices, TrafficDevice{
			DeviceID:            device.DeviceID,
			AgentID:             device.AgentID,
			Name:                device.Name,
			EgressBytes:         egress,
			PacedSeconds:        device.PacedSeconds(),
			QuotaRemainingBytes: h.quota.Remaining(device.DeviceID),
			DroppedFrames:       device.DroppedFrames(),
		})
	}
	return report
}

// Snapshot 是注册表的即时快照（agent 与 device 两个平面）。
func (h *Hub) Snapshot() Snapshot {
	snapshot := Snapshot{
		Agents:  []SnapshotAgent{},
		Devices: []SnapshotDevice{},
	}
	for index := range h.agentShards {
		shard := &h.agentShards[index]
		shard.mu.RLock()
		for _, agent := range shard.agents {
			ids := make([]string, 0, len(agent.devices))
			for id := range agent.devices {
				ids = append(ids, id)
			}
			sort.Strings(ids)
			snapshot.Agents = append(snapshot.Agents, SnapshotAgent{
				AgentID:          agent.AgentID,
				Name:             agent.Name,
				Devices:          ids,
				Pending:          agent.Pending(),
				QueuedBytes:      agent.QueuedBytes(),
				EgressBytes:      agent.deviceEgress.Load(),
				DroppedFrames:    agent.DroppedFrames(),
				BridgeBytesInUse: agent.BridgeBytesInUse(),
			})
		}
		shard.mu.RUnlock()
	}
	sort.Slice(snapshot.Agents, func(i, j int) bool {
		return snapshot.Agents[i].AgentID < snapshot.Agents[j].AgentID
	})

	for _, device := range h.allDevices() {
		agent := device.Agent()
		snapshot.Devices = append(snapshot.Devices, SnapshotDevice{
			DeviceID:            device.DeviceID,
			AgentID:             device.AgentID,
			Name:                device.Name,
			Pending:             device.Pending(),
			QueuedBytes:         device.QueuedBytes(),
			HostOnline:          agent != nil && !agent.Closed(),
			EgressBytes:         device.EgressBytes(),
			PacedSeconds:        device.PacedSeconds(),
			QuotaRemainingBytes: h.quota.Remaining(device.DeviceID),
			DroppedFrames:       device.DroppedFrames(),
		})
	}
	sort.Slice(snapshot.Devices, func(i, j int) bool {
		return snapshot.Devices[i].DeviceID < snapshot.Devices[j].DeviceID
	})
	return snapshot
}

// ── /debug/conns（仅环回）────────────────────────────────────────────────────

// DebugConn 是一条活连接的诊断快照。
//
// 它只回答"这条 socket 现在怎么样"，不包含令牌、Authorization、帧内容或文件路径：
// 这个端点虽然只允许环回来源，仍然按"要能被运维贴进工单"的隐私标准来写。
type DebugConn struct {
	Kind string `json:"kind"` // agent / device
	// AgentID 在设备行上是它所属的电脑（连接器）；连接器行上就是自己。
	AgentID  string `json:"agentId"`
	DeviceID string `json:"deviceId,omitempty"`

	Remote      string `json:"remote"`
	ConnectedAt int64  `json:"connectedAt"` // Unix 毫秒
	LastInbound int64  `json:"lastInbound"` // Unix 毫秒；0 = 从未收到
	// LastInboundAgeMs 是"距最后一次入站多久"，运维不用自己拿 now 去减。
	LastInboundAgeMs int64 `json:"lastInboundAgeMs"`

	QueueDepth    int   `json:"queueDepth"`
	QueuedBytes   int64 `json:"queuedBytes"`
	ControlDrops  int64 `json:"controlDrops"`
	DroppedFrames int64 `json:"droppedFrames"`

	ConnectorVersion string `json:"connectorVersion"`
	HostVersion      string `json:"hostVersion"`

	Generation uint64 `json:"generation"`
	Closing    bool   `json:"closing"`
	CloseCode  int    `json:"closeCode"` // 0 = 还没要求关闭
	LastError  string `json:"lastError"`
}

// DebugConns 是全量连接快照（/debug/conns 的唯一数据来源）。
type DebugConns struct {
	Now     int64       `json:"now"`
	Agents  []DebugConn `json:"agents"`
	Devices []DebugConn `json:"devices"`
}

// DebugConns 采集此刻的 agent 与 device 连接快照。
//
// 逐分片读锁、不跨片持锁（与 Snapshot 同一条规则），所以它不会在连接风暴时把
// 转发卡住；输出的顺序按 id 排序，便于两次抓取做 diff。
func (h *Hub) DebugConns() DebugConns {
	now := time.Now()
	snapshot := DebugConns{Now: now.UnixMilli(), Agents: []DebugConn{}, Devices: []DebugConn{}}
	describe := func(link *Link) DebugConn {
		lastInbound := link.LastInbound()
		lastInboundMS := int64(0)
		ageMS := int64(0)
		if !lastInbound.IsZero() {
			lastInboundMS = lastInbound.UnixMilli()
			ageMS = now.Sub(lastInbound).Milliseconds()
		}
		code, _ := link.CloseInfo()
		return DebugConn{
			Remote:           link.Remote(),
			ConnectedAt:      link.ConnectedAt().UnixMilli(),
			LastInbound:      lastInboundMS,
			LastInboundAgeMs: ageMS,
			QueueDepth:       link.QueueDepth(),
			QueuedBytes:      link.QueuedBytes(),
			ControlDrops:     link.ControlDrops(),
			DroppedFrames:    link.DroppedFrames(),
			Closing:          link.Closed(),
			CloseCode:        code,
			LastError:        link.LastError(),
		}
	}

	for index := range h.agentShards {
		shard := &h.agentShards[index]
		shard.mu.RLock()
		for _, agent := range shard.agents {
			connector, host := agent.Versions()
			row := describe(agent.Link)
			row.Kind = "agent"
			row.AgentID = agent.AgentID
			row.ConnectorVersion = connector
			row.HostVersion = host
			row.Generation = agent.generation
			snapshot.Agents = append(snapshot.Agents, row)
		}
		shard.mu.RUnlock()
	}
	for _, device := range h.allDevices() {
		row := describe(device.Link)
		row.Kind = "device"
		row.AgentID = device.AgentID
		row.DeviceID = device.DeviceID
		snapshot.Devices = append(snapshot.Devices, row)
	}
	sort.Slice(snapshot.Agents, func(i, j int) bool {
		return snapshot.Agents[i].AgentID < snapshot.Agents[j].AgentID
	})
	sort.Slice(snapshot.Devices, func(i, j int) bool {
		return snapshot.Devices[i].DeviceID < snapshot.Devices[j].DeviceID
	})
	return snapshot
}

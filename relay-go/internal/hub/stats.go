package hub

import (
	"sort"
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

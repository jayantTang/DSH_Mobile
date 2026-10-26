package httpapi

import (
	"net/http"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// /stats 的 live 段全部来自 hub：限额、load、traffic、snapshot、today 各只有一个
// 所有者。这里的结构体只负责把它们拼进一个响应。

type statsLoad struct {
	Agents  int `json:"agents"`
	Devices int `json:"devices"`
}

type statsResponse struct {
	OK      bool            `json:"ok"`
	Version int             `json:"version"`
	Now     int64           `json:"now"`
	Limits  hub.Description `json:"limits"`
	Load    statsLoad       `json:"load"`
	Traffic hub.Traffic     `json:"traffic"`
	// ControlDrops 是进程启动以来被丢弃的可丢控制帧数（pong/ping/hostStatus/
	// accountState）。它是"背压有没有重新把 pong 挤掉"的全局证据：逐链路的计数
	// 会随重连归零，恰好会在事故最需要它的时候消失。
	ControlDrops  int64            `json:"controlDrops"`
	Snapshot      hub.Snapshot     `json:"snapshot"`
	DeviceRecords store.Hygiene    `json:"deviceRecords"`
	Today         store.TodayUsage `json:"today"`
	// OpStats 是操作计数的卫生指标：deduped 说明重发被折叠，uncounted 说明
	// 帧缺少稳定幂等键。它们不进入 usageDaily，只用于判断统计是否可信。
	OpStats hub.OperationStats `json:"opStats"`
	// 连接生命周期计数（内嵌 = JSON 平铺）：superseded / reconnectStorm /
	// unverifiedAgents / unverifiedTotal / refusedDuplicate / refusedUnverified。
	// 新增字段，旧读法不受影响。
	presence.Stats
}

// handleStats 是运维用的实时负载与流量页（Python api.stats）。
//
// 只有回环来源能读：页面里有设备名与字节数，不该因为一次部署把中转挪到 0.0.0.0
// 就变成公开数据。拒绝回 **404** 而不是 403——探测者不该分辨得出这个端点是否存在。
func (s *server) handleStats(w http.ResponseWriter, r *http.Request) {
	if !isLoopback(peerHost(r.RemoteAddr)) {
		s.log().Info("relay: refused /stats for non-loopback peer", "peer", r.RemoteAddr)
		writeError(w, http.StatusNotFound, "not-found", "not found", nil)
		return
	}

	// 取**一次**给整份响应：同一响应里的时刻必须一致（诊断时要三侧对表）。
	now := store.NowMS()
	day := store.LocalDay()

	// 两个读库失败都不让运维面板 500：记一条日志，把对应段留空（与 Python 一致）。
	today, err := s.hub.Today(r.Context())
	if err != nil {
		s.log().Warn("relay: could not read today's usage", "error", err)
		today = store.TodayUsage{Day: day, Devices: []store.TodayDevice{},
			Accounts: []store.TodayAccount{}}
	}
	hygiene, err := s.store.DeviceHygiene(r.Context(), "")
	if err != nil {
		s.log().Warn("relay: could not count dead device records", "error", err)
		hygiene = store.Hygiene{}
	}

	agents, devices := s.hub.Load()
	payload := statsResponse{
		OK:            true,
		Version:       ProtocolVersion,
		Now:           now,
		Limits:        s.hub.Limits().Describe(),
		Load:          statsLoad{Agents: agents, Devices: devices},
		Traffic:       s.hub.Traffic(),
		ControlDrops:  s.hub.ControlDrops(),
		Snapshot:      s.hub.Snapshot(),
		DeviceRecords: hygiene,
		Today:         today,
		OpStats:       s.hub.OperationStats(),
		Stats:         s.hub.PresenceStats(),
	}
	if wantsStatsPage(r) {
		writeStatsPage(w, payload)
		return
	}
	writeJSON(w, http.StatusOK, payload)
}

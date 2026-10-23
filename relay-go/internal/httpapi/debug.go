package httpapi

import (
	"net/http"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
)

// debugConnsResponse 是 /debug/conns 的响应。
//
// 与 /stats 一样，`ok/now` 之外的部分只描述连接（不描述流量、不含令牌）。
type debugConnsResponse struct {
	OK      bool            `json:"ok"`
	Now     int64           `json:"now"`
	Agents  []hub.DebugConn `json:"agents"`
	Devices []hub.DebugConn `json:"devices"`
}

// handleDebugConns 是环回诊断快照：谁连着、什么时候连的、队列有多深、最后什么错。
//
// 与 /stats、/internal/* 用同一道守卫：只认 socket 回环来源，非回环回 404（探测者
// 不该分辨这个端点是否存在），并留一条拒绝日志。连接快照里没有令牌——hub 从不
// 持有明文令牌，这里也就没有可泄露的东西。
func (s *server) handleDebugConns(w http.ResponseWriter, r *http.Request) {
	if !isLoopback(peerHost(r.RemoteAddr)) {
		s.log().Warn("relay: refused /debug/conns for non-loopback peer",
			"requestId", reqctx.ID(r.Context()), "peer", r.RemoteAddr)
		writeError(w, http.StatusNotFound, "not-found", "not found", nil)
		return
	}
	snapshot := s.hub.DebugConns()
	writeJSON(w, http.StatusOK, debugConnsResponse{
		OK: true, Now: snapshot.Now, Agents: snapshot.Agents, Devices: snapshot.Devices,
	})
}

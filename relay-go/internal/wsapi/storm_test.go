package wsapi_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
)

// TestReconnectStormIsSuppressedAndHealthyAgentsAreUnaffected 把
// scripts/repro/repro_reconnect_storm.sh 的关键判据收编成 Go 用例，用真实
// HTTP 握手 + 真实 WebSocket 跑（不再依赖 Python 桩与 30 秒墙钟）：
//
//   - 每秒重连的未上报版本连接器被 429 抑制，拿不到新 socket（superseded=0）；
//   - 旧连接始终可用（storm 循环不能通过顶替旧连接达成）；
//   - 未验证连接器进入服务端退避（refusedUnverified 增长）；
//   - 同一账户下的另一台健康电脑不受影响（pong 正常、/stats load 正确）；
//   - /stats 的计数与日志口径一致（reconnectStorm ≥ 尝试次数）。
//
// 时间窗口压到毫秒：ActiveIdle 保持 1 小时（旧连接算活跃），WaitForOld=10ms、
// HelloTimeout=1ns、退避 1 分钟。判据与脚本相同，只是不再需要等 30 秒。
func TestReconnectStormIsSuppressedAndHealthyAgentsAreUnaffected(t *testing.T) {
	fixture := newRelayWithPresence(t, nil, presence.Options{
		ActiveIdle: time.Hour,
		WaitForOld: 10 * time.Millisecond,
		// 1ns 让"连上超过 HelloTimeout 仍未报版本"在第一次准入判定时就成立，
		// 不靠 sleep 等窗口（时间窗口的纯函数语义由 presence 包单测覆盖）。
		HelloTimeout: time.Nanosecond,
		BackoffBase:  time.Minute,
		BackoffMax:   time.Minute,
	})

	// storm：一条连上后从不报 connectorVersion/hostVersion 的连接，保持不关。
	storm := fixture.dial(fixture.agentPath(), fixture.tenant.secret)
	sendFrame(t, storm, `{"t":"ping","ts":1}`)
	if pong := readFrame(t, storm); pong.Type() != "pong" {
		t.Fatalf("storm 旧连接首帧 = %v", pong)
	}

	// healthy：同一账户下的另一台电脑，正常连上并保持 ping/pong。
	ctx := context.Background()
	healthyAgent, healthySecret, err := fixture.store.RegisterAgent(
		ctx, fixture.tenant.accountID, "healthy-mac", nil)
	if err != nil {
		t.Fatalf("RegisterAgent: %v", err)
	}
	healthy := fixture.dial("/link/agent?agentId="+healthyAgent.AgentID, healthySecret)
	sendFrame(t, healthy, `{"t":"ping","ts":1}`)
	if pong := readFrame(t, healthy); pong.Type() != "pong" {
		t.Fatalf("healthy 首帧 = %v", pong)
	}
	// 正常连接器会立刻上报两段版本；它同时决定"断开后重连是否需要退避"。
	sendFrame(t, healthy, `{"t":"hostStatus","info":{"version":"0.6.6","hostVersion":"0.2026.10"}}`)

	const attempts = 8
	reasons := map[string]int{}
	for index := 0; index < attempts; index++ {
		response := fixture.handshakeResponse(fixture.agentPath(), fixture.tenant.secret)
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil {
			t.Fatalf("读 429 响应体: %v", err)
		}
		if response.StatusCode != http.StatusTooManyRequests {
			t.Fatalf("第 %d 次风暴握手状态 = %d，期望 429（%s）",
				index, response.StatusCode, body)
		}
		if retry := response.Header.Get("Retry-After"); retry == "" {
			t.Fatalf("第 %d 次风暴握手缺 Retry-After", index)
		}
		var envelope struct {
			OK    bool `json:"ok"`
			Error struct {
				Code    string         `json:"code"`
				Message string         `json:"message"`
				Details map[string]any `json:"details"`
			} `json:"error"`
		}
		if err := json.Unmarshal(body, &envelope); err != nil {
			t.Fatalf("429 响应不是 JSON 信封：%v（%s）", err, body)
		}
		if envelope.OK || envelope.Error.Code != "presence/refused" {
			t.Fatalf("429 信封 = %s", body)
		}
		reason, _ := envelope.Error.Details["reason"].(string)
		if reason == "" {
			t.Fatalf("429 信封缺 details.reason：%s", body)
		}
		reasons[reason]++
		if milliseconds, _ := envelope.Error.Details["retryAfterMs"].(float64); milliseconds <= 0 {
			t.Fatalf("details.retryAfterMs = %v", envelope.Error.Details["retryAfterMs"])
		}
	}
	// 第一次拒绝发生在"等待旧连接退出"之后：admit 已经把它标记为未验证并给出
	// 退避时长，但拒绝原因仍按调用点写成 duplicate-active（诊断口径细节，见报告）。
	// 从第二次起一律是 unverified-backoff；两条原因都必须出现且不得串成别的。
	if reasons[presence.ReasonUnverified] < attempts-1 {
		t.Fatalf("风暴拒绝原因 = %v，期望至少 %d 次 %q",
			reasons, attempts-1, presence.ReasonUnverified)
	}
	if reasons[presence.ReasonDuplicate] > 1 {
		t.Fatalf("风暴拒绝原因 = %v，duplicate-active 最多 1 次（首次）", reasons)
	}

	// 旧连接不能被风暴伤到：它仍能收到 pong。
	sendFrame(t, storm, `{"t":"ping","ts":2}`)
	if pong := readFrame(t, storm); pong["ts"] != json.Number("2") {
		t.Fatalf("storm 旧连接在风暴后不可用：%v", pong)
	}
	// healthy 同样不受影响。
	sendFrame(t, healthy, `{"t":"ping","ts":2}`)
	if pong := readFrame(t, healthy); pong["ts"] != json.Number("2") {
		t.Fatalf("healthy 在风暴中被影响：%v", pong)
	}

	// /stats：没有顶替、风暴计数有界、退避计数增长、在线数仍是 2。
	response, err := http.Get(fixture.server.URL + "/stats")
	if err != nil {
		t.Fatalf("GET /stats: %v", err)
	}
	defer response.Body.Close()
	var stats struct {
		Superseded        int64 `json:"superseded"`
		ReconnectStorm    int64 `json:"reconnectStorm"`
		RefusedDuplicate  int64 `json:"refusedDuplicate"`
		RefusedUnverified int64 `json:"refusedUnverified"`
		UnverifiedAgents  int   `json:"unverifiedAgents"`
		Load              struct {
			Agents  int `json:"agents"`
			Devices int `json:"devices"`
		} `json:"load"`
	}
	if err := json.NewDecoder(response.Body).Decode(&stats); err != nil {
		t.Fatalf("解析 /stats: %v", err)
	}
	if stats.Superseded != 0 {
		t.Fatalf("superseded = %d，期望 0（风暴不得靠顶替旧连接达成）", stats.Superseded)
	}
	if stats.ReconnectStorm < attempts {
		t.Fatalf("reconnectStorm = %d，期望 >=%d", stats.ReconnectStorm, attempts)
	}
	if stats.RefusedUnverified < int64(attempts-1) {
		t.Fatalf("refusedUnverified = %d，期望 >=%d（reasons=%v）",
			stats.RefusedUnverified, attempts-1, reasons)
	}
	if stats.RefusedDuplicate > 1 {
		t.Fatalf("refusedDuplicate = %d，期望 <=1（首次）", stats.RefusedDuplicate)
	}
	if stats.UnverifiedAgents < 1 {
		t.Fatalf("unverifiedAgents = %d，期望 >=1", stats.UnverifiedAgents)
	}
	if stats.Load.Agents != 2 {
		t.Fatalf("load.agents = %d，期望 2（storm 1 条 + healthy 1 条）", stats.Load.Agents)
	}

	// 断连路径：上报过版本的健康连接器正常断开后立即重连，不该落进未验证退避。
	if err := healthy.Close(websocket.StatusNormalClosure, "done"); err != nil {
		t.Fatalf("关闭 healthy：%v", err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		if agents, _ := fixture.hub.Load(); agents == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("healthy 断开后 load.agents 仍不是 1")
		}
		time.Sleep(10 * time.Millisecond)
	}
	again := fixture.dial("/link/agent?agentId="+healthyAgent.AgentID, healthySecret)
	sendFrame(t, again, `{"t":"ping","ts":3}`)
	if pong := readFrame(t, again); pong["ts"] != json.Number("3") {
		t.Fatalf("healthy 重连后 pong = %v", pong)
	}
	if agents, _ := fixture.hub.Load(); agents != 2 {
		t.Fatalf("healthy 重连后 load.agents = %d，期望 2", agents)
	}
}

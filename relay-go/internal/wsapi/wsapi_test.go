// Package wsapi_test 是 /link/agent 与 /link/device 的端到端测试。
//
// 用**真实的** HTTP 服务 + 真实的 WebSocket 客户端跑完整栈（httpapi 路由 → wsapi
// 握手 → hub 队列 → 回程），因为 M2 最容易出错的恰恰是这几层之间的接缝：关闭码、
// 首帧顺序、子协议回显、配额与撤销的断开路径。
package wsapi_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/httpapi"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// readTimeout 是等一帧的上限：挂死必须表现成失败，不是把整轮时间吃掉。
const readTimeout = 2 * time.Second

// relayFixture 是一个跑在随机端口上的完整中转（临时库、独立 hub）。
type relayFixture struct {
	t      *testing.T
	server *httptest.Server
	store  *store.Store
	hub    *hub.Hub
	tenant tenant
	// tokens 是设备**明文**令牌：仓储层只存哈希，明文只在认领那一刻下发。
	tokens map[string]string
}

type tenant struct {
	accountID string
	agentID   string
	secret    string
}

func newRelay(t *testing.T, mutate func(*hub.Limits)) *relayFixture {
	t.Helper()
	return newRelayWithPresence(t, mutate, presence.Options{})
}

// newRelayWithPresence 是 newRelay 的窗口可调版本（连接生命周期用例需要毫秒级窗口）。
func newRelayWithPresence(t *testing.T, mutate func(*hub.Limits),
	windows presence.Options) *relayFixture {
	t.Helper()
	st, err := store.Open(t.TempDir() + "/state.db")
	if err != nil {
		t.Fatalf("打开临时库: %v", err)
	}
	limits := hub.DefaultLimits()
	if mutate != nil {
		mutate(&limits)
	}
	live := hub.New(hub.Options{
		Store:    st,
		Limits:   limits,
		Logger:   slog.New(slog.NewTextHandler(io.Discard, nil)),
		Presence: windows,
	})
	handler := httpapi.New(httpapi.Options{
		Store:            st,
		Hub:              live,
		Limits:           limits,
		MaxPairedDevices: 8,
	})
	server := httptest.NewServer(handler)

	ctx := context.Background()
	account, err := st.CreateAccount(ctx, "WS-mac")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	agent, secret, err := st.RegisterAgent(ctx, account.AccountID, "WS-mac", nil)
	if err != nil {
		t.Fatalf("RegisterAgent: %v", err)
	}

	fixture := &relayFixture{
		t: t, server: server, store: st, hub: live, tokens: map[string]string{},
		tenant: tenant{accountID: account.AccountID, agentID: agent.AgentID, secret: secret},
	}
	t.Cleanup(func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		live.Shutdown(shutdownCtx)
		server.Close()
		if err := st.Close(); err != nil {
			t.Errorf("关闭临时库: %v", err)
		}
	})
	return fixture
}

// pairDevice 走真实的持久码 + 认领，得到一台已配对设备。
func (f *relayFixture) pairDevice(name string) store.Device {
	f.t.Helper()
	ctx := context.Background()
	minted, err := f.store.MintPairCode(ctx, f.tenant.agentID, nil)
	if err != nil {
		f.t.Fatalf("MintPairCode: %v", err)
	}
	claimed, err := f.store.ClaimPairCode(ctx, minted.Code, store.ClaimParams{
		DeviceName: name, MaxPairedDevices: 8, TTLMS: store.DefaultDeviceTTLMS,
	})
	if err != nil {
		f.t.Fatalf("ClaimPairCode: %v", err)
	}
	f.tokens[claimed.DeviceID] = claimed.DeviceToken
	device, found, err := f.store.DeviceByID(ctx, claimed.DeviceID)
	if err != nil || !found {
		f.t.Fatalf("DeviceByID: found=%v err=%v", found, err)
	}
	return device
}

// tokenOf 返回设备的明文令牌。
func (f *relayFixture) tokenOf(device store.Device) string {
	f.t.Helper()
	token, ok := f.tokens[device.DeviceID]
	if !ok {
		f.t.Fatalf("没有记录设备 %s 的令牌", device.DeviceID)
	}
	return token
}

// wsURL 把 http:// 换成 ws://。
func (f *relayFixture) wsURL(path string) string {
	return "ws" + strings.TrimPrefix(f.server.URL, "http") + path
}

// dial 建一条 WS 连接；失败即终止用例。
func (f *relayFixture) dial(path, token string, subprotocols ...string) *websocket.Conn {
	f.t.Helper()
	header := http.Header{}
	if token != "" {
		header.Set("Authorization", "Bearer "+token)
	}
	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, f.wsURL(path), &websocket.DialOptions{
		HTTPHeader:   header,
		Subprotocols: subprotocols,
	})
	if err != nil {
		f.t.Fatalf("拨号 %s 失败：%v", path, err)
	}
	f.t.Cleanup(func() { _ = conn.CloseNow() })
	return conn
}

// handshakeResponse 发一次裸握手并返回响应（调用方负责关 Body）。
func (f *relayFixture) handshakeResponse(path, token string, subprotocols ...string) *http.Response {
	f.t.Helper()
	req, err := http.NewRequest(http.MethodGet, f.server.URL+path, nil)
	if err != nil {
		f.t.Fatalf("建请求: %v", err)
	}
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Version", "13")
	req.Header.Set("Sec-WebSocket-Key",
		base64.StdEncoding.EncodeToString([]byte("0123456789abcdef")))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if len(subprotocols) > 0 {
		req.Header.Set("Sec-WebSocket-Protocol", strings.Join(subprotocols, ", "))
	}
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		f.t.Fatalf("握手请求失败：%v", err)
	}
	return response
}

// handshakeStatus 发一次裸握手，返回 HTTP 状态码（用来断言 401/403 这类拒绝）。
func (f *relayFixture) handshakeStatus(path, token string, subprotocols ...string) int {
	f.t.Helper()
	response := f.handshakeResponse(path, token, subprotocols...)
	defer response.Body.Close()
	return response.StatusCode
}

// postJSON 发一次带令牌的 JSON 请求。
func (f *relayFixture) postJSON(path, token string, body any) (int, []byte) {
	f.t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		f.t.Fatalf("序列化请求体: %v", err)
	}
	request, err := http.NewRequest(http.MethodPost, f.server.URL+path, bytes.NewReader(raw))
	if err != nil {
		f.t.Fatalf("建请求: %v", err)
	}
	request.Header.Set("Content-Type", "application/json")
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		f.t.Fatalf("请求失败：%v", err)
	}
	defer response.Body.Close()
	payload, _ := io.ReadAll(response.Body)
	return response.StatusCode, payload
}

// putState 写一次账户状态。
func (f *relayFixture) putState(token string, entries []map[string]any) (int, []byte) {
	f.t.Helper()
	raw, err := json.Marshal(map[string]any{"entries": entries})
	if err != nil {
		f.t.Fatalf("序列化请求体: %v", err)
	}
	request, err := http.NewRequest(http.MethodPut, f.server.URL+"/account/state",
		bytes.NewReader(raw))
	if err != nil {
		f.t.Fatalf("建请求: %v", err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		f.t.Fatalf("请求失败：%v", err)
	}
	defer response.Body.Close()
	payload, _ := io.ReadAll(response.Body)
	return response.StatusCode, payload
}

// agentPath / devicePath 是两条端点的路径（带 agentId 查询参数）。
func (f *relayFixture) agentPath() string {
	return "/link/agent?agentId=" + f.tenant.agentID
}

func devicePath(device store.Device) string {
	return "/link/device?agentId=" + device.AgentID
}

// ── 帧读写 ───────────────────────────────────────────────────────────────────

func readFrame(t *testing.T, conn *websocket.Conn) dlp.Frame {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()
	messageType, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("读帧失败：%v", err)
	}
	if messageType != websocket.MessageText {
		t.Fatalf("期望文本帧，收到 %v", messageType)
	}
	frame, _, err := dlp.Parse(data)
	if err != nil {
		t.Fatalf("收到的不是合法帧：%v (%s)", err, data)
	}
	return frame
}

func readClose(t *testing.T, conn *websocket.Conn) int {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()
	for {
		_, _, err := conn.Read(ctx)
		if err == nil {
			continue // 关闭前还可能有业务帧，丢掉
		}
		status := websocket.CloseStatus(err)
		if status == -1 {
			t.Fatalf("读到错误但没有关闭码：%v", err)
		}
		return int(status)
	}
}

// readUntil 读到指定类型的帧为止（中间的控制帧丢掉）。
func readUntil(t *testing.T, conn *websocket.Conn, kind string) dlp.Frame {
	t.Helper()
	for {
		frame := readFrame(t, conn)
		if frame.Type() == kind {
			return frame
		}
	}
}

// expectSilence 断言这段时间内没有帧到达。
func expectSilence(t *testing.T, conn *websocket.Conn, window time.Duration) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), window)
	defer cancel()
	_, data, err := conn.Read(ctx)
	if err == nil {
		t.Fatalf("这段时间内不该有帧，却收到了 %s", data)
	}
	if websocket.CloseStatus(err) != -1 {
		t.Fatalf("连接被关闭了：%v", err)
	}
}

func sendFrame(t *testing.T, conn *websocket.Conn, raw string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, []byte(raw)); err != nil {
		t.Fatalf("写帧失败：%v", err)
	}
}

// ── 用例 ─────────────────────────────────────────────────────────────────────

// TestFramesTravelBothWays 是最基本的一条：设备 → 电脑盖上 deviceId，电脑 → 设备
// 摘掉它，ping 由中转自己回答。
func TestFramesTravelBothWays(t *testing.T) {
	fixture := newRelay(t, nil)
	device := fixture.pairDevice("WS-iPhone")
	agentConn := fixture.dial(fixture.agentPath(), fixture.tenant.secret)
	deviceConn := fixture.dial(devicePath(device), fixture.tokenOf(device))

	status := readFrame(t, deviceConn)
	if status.Type() != "hostStatus" || status["info"].(map[string]any)["online"] != true {
		t.Fatalf("设备首帧 = %v", status)
	}
	attach := readFrame(t, agentConn)
	if attach.Type() != "deviceAttach" || attach.DeviceID() != device.DeviceID {
		t.Fatalf("电脑首帧 = %v", attach)
	}

	sendFrame(t, deviceConn, `{"t":"req","id":"r1","method":"session/list"}`)
	forwarded := readFrame(t, agentConn)
	if forwarded.Type() != "req" || forwarded.DeviceID() != device.DeviceID {
		t.Fatalf("转发到电脑的帧 = %v", forwarded)
	}

	sendFrame(t, agentConn, `{"t":"res","id":"r1","ok":true,"deviceId":"`+device.DeviceID+`"}`)
	reply := readFrame(t, deviceConn)
	if reply.Type() != "res" || reply.ID() != "r1" {
		t.Fatalf("回到手机的帧 = %v", reply)
	}
	if _, leaked := reply["deviceId"]; leaked {
		t.Fatalf("deviceId 不该到达设备：%v", reply)
	}

	sendFrame(t, deviceConn, `{"t":"ping","ts":7}`)
	pong := readFrame(t, deviceConn)
	if pong.Type() != "pong" || pong["ts"] != json.Number("7") {
		t.Fatalf("pong = %v", pong)
	}
}

// TestStatsReflectLiveConnections 钉住 /stats 的 load/traffic/snapshot 接的是真连接
// （M1 时这三段是空壳；M2 之后运维面板必须看得见谁在线）。
func TestStatsReflectLiveConnections(t *testing.T) {
	fixture := newRelay(t, nil)
	device := fixture.pairDevice("WS-stats")
	agentConn := fixture.dial(fixture.agentPath(), fixture.tenant.secret)
	deviceConn := fixture.dial(devicePath(device), fixture.tokenOf(device))
	readFrame(t, deviceConn)
	readUntil(t, agentConn, "deviceAttach")

	response, err := http.Get(fixture.server.URL + "/stats")
	if err != nil {
		t.Fatalf("GET /stats: %v", err)
	}
	defer response.Body.Close()
	var body struct {
		Load struct {
			Agents  int `json:"agents"`
			Devices int `json:"devices"`
		} `json:"load"`
		Traffic struct {
			Devices []struct {
				DeviceID string `json:"deviceId"`
			} `json:"devices"`
		} `json:"traffic"`
		Snapshot struct {
			Agents []struct {
				AgentID string   `json:"agentId"`
				Devices []string `json:"devices"`
			} `json:"agents"`
			Devices []struct {
				DeviceID   string `json:"deviceId"`
				HostOnline bool   `json:"hostOnline"`
			} `json:"devices"`
		} `json:"snapshot"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("解析 /stats: %v", err)
	}
	if body.Load.Agents != 1 || body.Load.Devices != 1 {
		t.Fatalf("load = %+v", body.Load)
	}
	if len(body.Traffic.Devices) != 1 || body.Traffic.Devices[0].DeviceID != device.DeviceID {
		t.Fatalf("traffic = %+v", body.Traffic)
	}
	if len(body.Snapshot.Devices) != 1 || !body.Snapshot.Devices[0].HostOnline {
		t.Fatalf("snapshot.devices = %+v", body.Snapshot.Devices)
	}
	if len(body.Snapshot.Agents) != 1 || len(body.Snapshot.Agents[0].Devices) != 1 {
		t.Fatalf("snapshot.agents = %+v", body.Snapshot.Agents)
	}
}

// TestASecondAgentSocketIsRefusedWhileTheFirstIsActive 钉住 2026-10-23 的回滚形态：
// 同一 agent 的旧连接还活着时，新握手必须在**升级之前**被 429 拒绝（不是升级后
// 用 4001 顶替），旧连接继续可用；旧连接退出以后新连接立即放行。
func TestASecondAgentSocketIsRefusedWhileTheFirstIsActive(t *testing.T) {
	fixture := newRelayWithPresence(t, nil, presence.Options{
		ActiveIdle: time.Hour, // 旧连接始终算活跃
		WaitForOld: 30 * time.Millisecond,
	})
	first := fixture.dial(fixture.agentPath(), fixture.tenant.secret)
	sendFrame(t, first, `{"t":"ping","ts":1}`)
	if pong := readFrame(t, first); pong.Type() != "pong" {
		t.Fatalf("旧连接的首帧 = %v", pong)
	}

	response := fixture.handshakeResponse(fixture.agentPath(), fixture.tenant.secret)
	defer response.Body.Close()
	if response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("第二条 agent 握手状态 = %d，期望 429", response.StatusCode)
	}
	if retry := response.Header.Get("Retry-After"); retry == "" {
		t.Fatal("429 缺 Retry-After 头")
	}

	// 被拒绝的新连接不能伤到旧连接。
	sendFrame(t, first, `{"t":"ping","ts":2}`)
	if pong := readFrame(t, first); pong["ts"] != json.Number("2") {
		t.Fatalf("旧连接在拒绝新连接后不可用：%v", pong)
	}

	// /stats 的计数：没有顶替，只有一次被抑制的重复到达。
	statsResponse, err := http.Get(fixture.server.URL + "/stats")
	if err != nil {
		t.Fatalf("GET /stats: %v", err)
	}
	defer statsResponse.Body.Close()
	var stats struct {
		Superseded     int64 `json:"superseded"`
		ReconnectStorm int64 `json:"reconnectStorm"`
	}
	if err := json.NewDecoder(statsResponse.Body).Decode(&stats); err != nil {
		t.Fatalf("解析 /stats: %v", err)
	}
	if stats.Superseded != 0 || stats.ReconnectStorm != 1 {
		t.Fatalf("/stats = %+v，期望 superseded=0 reconnectStorm=1", stats)
	}

	// 旧连接正常退出后：立即允许新连接（不等抑制窗口）。
	if err := first.Close(websocket.StatusNormalClosure, "done"); err != nil {
		t.Fatalf("关闭旧连接：%v", err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		if agents, _ := fixture.hub.Load(); agents == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("旧连接退出后注册表仍有 agent")
		}
		time.Sleep(10 * time.Millisecond)
	}
	second := fixture.dial(fixture.agentPath(), fixture.tenant.secret)
	sendFrame(t, second, `{"t":"ping","ts":3}`)
	if pong := readFrame(t, second); pong["ts"] != json.Number("3") {
		t.Fatalf("重连后的 pong = %v", pong)
	}
}

// TestHandshakeIsRefusedWithoutAToken 覆盖两条端点的 401。
func TestHandshakeIsRefusedWithoutAToken(t *testing.T) {
	fixture := newRelay(t, nil)
	device := fixture.pairDevice("WS-iPhone")
	if status := fixture.handshakeStatus(fixture.agentPath(), ""); status != http.StatusUnauthorized {
		t.Fatalf("电脑侧无令牌 = %d", status)
	}
	if status := fixture.handshakeStatus(devicePath(device), ""); status != http.StatusUnauthorized {
		t.Fatalf("设备侧无令牌 = %d", status)
	}
	if status := fixture.handshakeStatus(fixture.agentPath(), "as_bogus"); status != http.StatusUnauthorized {
		t.Fatalf("电脑侧坏令牌 = %d", status)
	}
}

// TestRevokedDeviceTokenCannotOpenASocket：撤销之后同一枚令牌连不上。
func TestRevokedDeviceTokenCannotOpenASocket(t *testing.T) {
	fixture := newRelay(t, nil)
	device := fixture.pairDevice("WS-doomed")
	if err := fixture.store.RevokeDevice(context.Background(), device.DeviceID); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}
	if status := fixture.handshakeStatus(devicePath(device),
		fixture.tokenOf(device)); status != http.StatusUnauthorized {
		t.Fatalf("已撤销设备的令牌 = %d", status)
	}
}

// TestSubprotocolAuthentication 覆盖浏览器路径：dsh.device.<token> + 服务端回显。
func TestSubprotocolAuthentication(t *testing.T) {
	fixture := newRelay(t, nil)
	device := fixture.pairDevice("WS-browser")
	token := fixture.tokenOf(device)
	offered := "dsh.device." + token

	conn := fixture.dial(devicePath(device), "", offered)
	if got := conn.Subprotocol(); got != offered {
		t.Fatalf("回显的子协议 = %q，期望 %q", got, offered)
	}
	first := readFrame(t, conn)
	if first.Type() != "hostStatus" {
		t.Fatalf("首帧 = %v", first)
	}

	if status := fixture.handshakeStatus(devicePath(device), "",
		"dsh.device.dt_not-a-real-token"); status != http.StatusUnauthorized {
		t.Fatalf("坏子协议令牌 = %d", status)
	}
	if status := fixture.handshakeStatus("/link/device?agentId=agt_somebody-else", "",
		offered); status != http.StatusForbidden {
		t.Fatalf("agentId 不匹配 = %d", status)
	}
	// 头有效、子协议乱填：按头认证，不因为多带一行就拒绝。
	headerWins := fixture.dial(devicePath(device), token, "dsh.device.dt_not-a-real-token")
	if frame := readFrame(t, headerWins); frame.Type() != "hostStatus" {
		t.Fatalf("头认证优先时首帧 = %v", frame)
	}
}

// TestMalformedFramesGetErrorFrames：坏帧有错误码可依，socket 不断；二进制单独一个码。
func TestMalformedFramesGetErrorFrames(t *testing.T) {
	fixture := newRelay(t, nil)
	device := fixture.pairDevice("WS-iPhone")
	conn := fixture.dial(devicePath(device), fixture.tokenOf(device))
	readFrame(t, conn) // hostStatus

	sendFrame(t, conn, "this is not json")
	badJSON := readFrame(t, conn)
	if badJSON.Type() != "error" || badJSON["code"] != "protocol/bad-frame" {
		t.Fatalf("坏 JSON 的错误帧 = %v", badJSON)
	}

	sendFrame(t, conn, `{"t":"req"}`)
	missingID := readFrame(t, conn)
	if missingID["code"] != "protocol/bad-frame" ||
		!strings.Contains(missingID["message"].(string), "id") {
		t.Fatalf("缺 id 的错误帧 = %v", missingID)
	}

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageBinary, []byte{0, 1}); err != nil {
		t.Fatalf("写二进制帧: %v", err)
	}
	binary := readFrame(t, conn)
	if binary["code"] != "protocol/binary-unsupported" {
		t.Fatalf("二进制错误帧 = %v", binary)
	}

	// 坏帧之后链路仍然可用。
	sendFrame(t, conn, `{"t":"ping","ts":9}`)
	if pong := readFrame(t, conn); pong.Type() != "pong" {
		t.Fatalf("坏帧之后 pong = %v", pong)
	}
}

// TestTheDeviceLimitIs4021OnTheWire：满额拒连必须给 limit/devices 帧 + 4012。
func TestTheDeviceLimitIsRefusedOnTheWire(t *testing.T) {
	fixture := newRelay(t, func(limits *hub.Limits) { limits.MaxDevicesPerAgent = 1 })
	first := fixture.pairDevice("WS-first")
	second := fixture.pairDevice("WS-second")

	// 设备上限是"每台电脑"的：电脑不在线时没有名额可言，所以先连电脑。
	agentConn := fixture.dial(fixture.agentPath(), fixture.tenant.secret)
	firstConn := fixture.dial(devicePath(first), fixture.tokenOf(first))
	readFrame(t, firstConn) // hostStatus
	readUntil(t, agentConn, "deviceAttach")

	refused := fixture.dial(devicePath(second), fixture.tokenOf(second))
	refusal := readFrame(t, refused)
	if refusal.Type() != "error" || refusal["code"] != "limit/devices" {
		t.Fatalf("拒连帧 = %v", refusal)
	}
	if refusal["fatal"] != true {
		t.Fatalf("拒连应是致命错误：%v", refusal)
	}
	details, ok := refusal["details"].(map[string]any)
	if !ok || details["maxDevicesPerAgent"] != json.Number("1") {
		t.Fatalf("details = %v", refusal["details"])
	}
	if code := readClose(t, refused); code != dlp.CloseDeviceLimit {
		t.Fatalf("关闭码 = %d，期望 4012", code)
	}
}

// TestRevokingALiveDeviceClosesItAndTellsTheAgent：HTTP 撤销 → socket 1001 +
// deviceDetach reason=revoked。
func TestRevokingALiveDeviceClosesItAndTellsTheAgent(t *testing.T) {
	fixture := newRelay(t, nil)
	keeper := fixture.pairDevice("WS-keeper")
	doomed := fixture.pairDevice("WS-doomed")
	agentConn := fixture.dial(fixture.agentPath(), fixture.tenant.secret)
	deviceConn := fixture.dial(devicePath(doomed), fixture.tokenOf(doomed))
	readFrame(t, deviceConn) // hostStatus

	status, payload := fixture.postJSON("/devices/revoke",
		fixture.tokenOf(keeper), map[string]any{"deviceId": doomed.DeviceID})
	if status != http.StatusOK {
		t.Fatalf("撤销失败：%d %s", status, payload)
	}
	if code := readClose(t, deviceConn); code != dlp.CloseGoingAway {
		t.Fatalf("撤销后的关闭码 = %d，期望 1001", code)
	}
	detach := readUntil(t, agentConn, "deviceDetach")
	if detach["reason"] != "revoked" {
		t.Fatalf("撤销后的电脑通知 = %v", detach)
	}
}

// TestAccountStateIsPushedToTheOtherDevice：HTTP 写入 → 另一台设备收到 accountState，
// 写入方自己没有任何帧。
func TestAccountStateIsPushedToTheOtherDevice(t *testing.T) {
	fixture := newRelay(t, nil)
	writer := fixture.pairDevice("WS-writer")
	listener := fixture.pairDevice("WS-listener")
	writerConn := fixture.dial(devicePath(writer), fixture.tokenOf(writer))
	listenerConn := fixture.dial(devicePath(listener), fixture.tokenOf(listener))
	readFrame(t, writerConn)
	readFrame(t, listenerConn)

	status, payload := fixture.putState(fixture.tokenOf(writer),
		[]map[string]any{{
			"key": "alertPrefs", "value": map[string]any{"turnEnd": false},
			"updatedAt": time.Now().UnixMilli(),
		}})
	if status != http.StatusOK {
		t.Fatalf("写状态失败：%d %s", status, payload)
	}
	notification := readFrame(t, listenerConn)
	if notification.Type() != "accountState" {
		t.Fatalf("通知帧 = %v", notification)
	}
	keys, ok := notification["keys"].([]any)
	if !ok || len(keys) != 1 || keys[0] != "alertPrefs" {
		t.Fatalf("通知的 keys = %v", notification["keys"])
	}
	expectSilence(t, writerConn, 300*time.Millisecond)
}

// TestTheDailyQuotaClosesWith4011 在端到端层面钉住 4011（内部细节见 hub 单测）。
func TestTheDailyQuotaClosesWith4011(t *testing.T) {
	fixture := newRelay(t, func(limits *hub.Limits) { limits.DeviceDailyBytes = 200 })
	device := fixture.pairDevice("WS-quota")
	agentConn := fixture.dial(fixture.agentPath(), fixture.tenant.secret)
	deviceConn := fixture.dial(devicePath(device), fixture.tokenOf(device))
	readFrame(t, deviceConn) // hostStatus
	readUntil(t, agentConn, "deviceAttach")

	text := strings.Repeat("x", 400)
	sendFrame(t, agentConn, `{"t":"res","id":"big","deviceId":"`+device.DeviceID+
		`","value":{"text":"`+text+`"}}`)
	refusal := readFrame(t, deviceConn)
	if refusal.Type() != "error" || refusal["code"] != "quota/device-daily" {
		t.Fatalf("配额帧 = %v", refusal)
	}
	details := refusal["details"].(map[string]any)
	if details["limitBytes"] != json.Number("200") {
		t.Fatalf("details = %v", details)
	}
	if code := readClose(t, deviceConn); code != dlp.CloseQuotaExceeded {
		t.Fatalf("关闭码 = %d，期望 4011", code)
	}
	detach := readFrame(t, agentConn)
	if detach.Type() != "deviceDetach" || detach["reason"] != "daily quota" {
		t.Fatalf("配额断开的电脑通知 = %v", detach)
	}
}

package hub

// APNs 在线 notify 路径的端到端单测（DESIGN-20261023 §3.6）。
//
// 这一层要回答的问题只有三个：选谁、推什么字节、失败之后世界还转不转。
// 投递面用两种桩组合，都不碰 Apple：
//
//   - fakePusher 在 hub 的 PushSender 端口上记录调用，验证"谁被选中"；
//   - 真实 push.Sender + 注入的 HTTP 桩，验证真正发出去的 URL 与 payload
//     （尤其是"payload 不含会话内容"这条承诺）。
//
// 真实推送（admin push-test）已经单独验证过；这里绝不再发一条真推送。

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/push"
)

// ── 真实 sender + HTTP 桩 ───────────────────────────────────────────────────

// apnsStub 是注入给 push.Sender 的 HTTP 客户端：记录请求，按令牌给回答。
//
// 这里替身的是"Apple 那一端"，不是 Sender 本身——所以 URL、头、payload 与
// DeadToken 的判定都走生产代码。
type apnsStub struct {
	mu       sync.Mutex
	requests []apnsRequest
	respond  func(token string) (status int, body string)
}

type apnsRequest struct {
	url     string
	headers http.Header
	body    []byte
}

func newAPNSStub() *apnsStub { return &apnsStub{} }

func (s *apnsStub) Do(request *http.Request) (*http.Response, error) {
	body, err := io.ReadAll(request.Body)
	_ = request.Body.Close()
	if err != nil {
		return nil, err
	}
	token := ""
	if parsed, parseErr := url.Parse(request.URL.String()); parseErr == nil {
		token = filepath.Base(parsed.Path)
	}
	status, responseBody := http.StatusOK, ""
	if s.respond != nil {
		status, responseBody = s.respond(token)
	}
	s.mu.Lock()
	s.requests = append(s.requests, apnsRequest{
		url: request.URL.String(), headers: request.Header.Clone(), body: body,
	})
	s.mu.Unlock()
	header := http.Header{}
	header.Set("apns-id", "stub")
	return &http.Response{
		StatusCode: status,
		Header:     header,
		Body:       io.NopCloser(strings.NewReader(responseBody)),
	}, nil
}

// waitForRequests 等到至少 count 条请求，返回当前快照。
func (s *apnsStub) waitForRequests(t *testing.T, count int) []apnsRequest {
	t.Helper()
	waitFor(t, "APNs 桩收到请求", func() bool { return len(s.requestsCopy()) >= count })
	return s.requestsCopy()
}

func (s *apnsStub) requestsCopy() []apnsRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]apnsRequest(nil), s.requests...)
}

// newStubAPNSSender 造一个"配置完整、HTTP 已注入桩"的真实 Sender。
//
// 密钥是每次用例现生成的一次性 P-256（仓库里不允许存在私钥文件）。
func newStubAPNSSender(t *testing.T, stub push.Client) *push.Sender {
	t.Helper()
	keyPath := writeAPNSKeyForHubTest(t)
	env := map[string]string{
		"DLP_APNS_ENABLED":     "1",
		"DLP_APNS_KEY_PATH":    keyPath,
		"DLP_APNS_KEY_ID":      "TESTKEY12",
		"DLP_APNS_TEAM_ID":     "TEAMID1234",
		"DLP_APNS_TOPIC":       "com.example.app",
		"DLP_APNS_ENV_DEFAULT": "sandbox",
	}
	sender := push.FromEnv(func(name string) string { return env[name] }, stub)
	if !sender.Enabled() {
		t.Fatal("完整配置 + 已注入桩的 Sender 应当启用")
	}
	return sender
}

// decodePushPayload 解析真正发给 APNs 的正文。
func decodePushPayload(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("推送正文不是 JSON 对象：%v (%s)", err, raw)
	}
	return payload
}

func writeAPNSKeyForHubTest(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("生成测试密钥: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("编码测试密钥: %v", err)
	}
	path := filepath.Join(t.TempDir(), "AuthKey_TESTKEY12.p8")
	block := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	if err := os.WriteFile(path, block, 0o600); err != nil {
		t.Fatalf("写测试密钥: %v", err)
	}
	return path
}

// ── 选择与 payload ──────────────────────────────────────────────────────────

// TestTheOnlineNotifyPathPushesOnlyOfflineDevicesWithAContentFreePayload 是本任务的
// 主用例：一条 agent notify 只让"同账户 + 离线 + 有登记"的设备收到推送，并且真正
// 发出去的字节里没有会话内容。
func TestTheOnlineNotifyPathPushesOnlyOfflineDevicesWithAContentFreePayload(t *testing.T) {
	stub := newAPNSStub()
	sender := newStubAPNSSender(t, stub)
	f := newFixture(t, Options{Push: sender, Logger: discardLogger()})

	owner := f.newTenant("notify-owner")
	offline := f.pairDevice(owner, "iPhone-offline")
	online := f.pairDevice(owner, "iPhone-online")
	other := f.newTenant("notify-other")
	otherOffline := f.pairDevice(other, "iPhone-other")

	offlineToken := strings.Repeat("a1", 32)
	registerPushWith(t, f, offline.DeviceID, offlineToken, "sandbox", true, true)
	registerPushWith(t, f, online.DeviceID, strings.Repeat("b2", 32), "production", true, true)
	registerPushWith(t, f, otherOffline.DeviceID, strings.Repeat("c3", 32), "sandbox", true, true)

	agentLink, _ := f.attachAgent(owner)
	f.mustAttachDevice(online) // 在线设备自己弹本地通知，中转不该再推

	// 帧里夹带各种"看起来像内容"的字段：它们都不许进 APNs payload。
	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "attention", "sid": "s-attn", "eid": "e-77",
		"title": "会话标题", "body": "正文不该出现", "text": "秘密",
		"path": "/Users/nobody/secret", "host": "some-mac",
	}))

	requests := stub.waitForRequests(t, 1)
	request := requests[0]
	wantURL := push.Hosts["sandbox"] + "/3/device/" + offlineToken
	if request.url != wantURL {
		t.Fatalf("推送 URL = %q，期望 %q", request.url, wantURL)
	}
	if got := request.headers.Get("apns-topic"); got != "com.example.app" {
		t.Fatalf("apns-topic = %q", got)
	}
	if got := request.headers.Get("apns-push-type"); got != "alert" {
		t.Fatalf("apns-push-type = %q", got)
	}
	if got := request.headers.Get("apns-collapse-id"); got != "s-attn" {
		t.Fatalf("apns-collapse-id = %q", got)
	}

	payload := decodePushPayload(t, request.body)
	if len(payload) != 4 {
		t.Fatalf("payload 顶层字段 = %v，只允许 aps/kind/sid/eid", payload)
	}
	if payload["kind"] != "attention" || payload["sid"] != "s-attn" ||
		payload["eid"] != "e-77" {
		t.Fatalf("payload 标识字段 = %v", payload)
	}
	aps, ok := payload["aps"].(map[string]any)
	if !ok || len(aps) != 3 {
		t.Fatalf("aps = %v，只允许 alert/sound/thread-id", payload["aps"])
	}
	if aps["thread-id"] != "s-attn" || aps["sound"] != "default" {
		t.Fatalf("aps = %v", aps)
	}
	alert, ok := aps["alert"].(map[string]any)
	if !ok || len(alert) != 1 || alert["title-loc-key"] != "需要你确认" {
		t.Fatalf("alert = %v，只允许 title-loc-key", aps["alert"])
	}
	// 正文类字段即使出现在 notify 帧里，也不许被带进 payload。
	for _, forbidden := range []string{
		"会话标题", "正文不该出现", "秘密", "/Users/nobody/secret",
		"some-mac", "loc-args", `"body"`, `"title"`, `"text"`, `"path"`,
	} {
		if strings.Contains(string(request.body), forbidden) {
			t.Fatalf("payload 里出现了内容字段 %q：%s", forbidden, request.body)
		}
	}

	// 在线设备与别的账户都不该被推：给它们一个否定观察窗口。
	time.Sleep(200 * time.Millisecond)
	if got := len(stub.requestsCopy()); got != 1 {
		t.Fatalf("只应推离线的那一台，实际请求 %d 条", got)
	}
}

// TestOnlyTheOfflineDevicesOfTheNotifyingAccountArePushed 用 fakePusher 钉住选择
// 结果本身：同账户两台离线设备都推，在线设备与别的账户一条都不推。
func TestOnlyTheOfflineDevicesOfTheNotifyingAccountArePushed(t *testing.T) {
	sender := newFakePusher()
	f := newFixture(t, Options{Push: sender, Logger: discardLogger()})

	owner := f.newTenant("selector")
	first := f.pairDevice(owner, "iPhone-first")
	second := f.pairDevice(owner, "iPhone-second")
	online := f.pairDevice(owner, "iPhone-online")
	other := f.newTenant("selector-other")
	otherDevice := f.pairDevice(other, "iPhone-other")

	firstToken := strings.Repeat("11", 32)
	secondToken := strings.Repeat("22", 32)
	registerPushWith(t, f, first.DeviceID, firstToken, "sandbox", true, true)
	registerPushWith(t, f, second.DeviceID, secondToken, "production", true, true)
	registerPushWith(t, f, online.DeviceID, strings.Repeat("33", 32), "sandbox", true, true)
	registerPushWith(t, f, otherDevice.DeviceID, strings.Repeat("44", 32), "sandbox", true, true)

	agentLink, _ := f.attachAgent(owner)
	f.mustAttachDevice(online)

	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-select",
	}))
	call := sender.wait(t)

	want := map[string]string{
		first.DeviceID:  firstToken,
		second.DeviceID: secondToken,
	}
	if len(call.targets) != len(want) {
		t.Fatalf("targets = %+v，期望只含 %v", call.targets, want)
	}
	for _, target := range call.targets {
		token, expected := want[target.DeviceID]
		if !expected {
			t.Fatalf("不该被推的设备进了 targets：%+v", target)
		}
		if target.Token != token {
			t.Fatalf("设备 %s 的令牌 = %q，期望 %q", target.DeviceID, target.Token, token)
		}
		delete(want, target.DeviceID)
	}
	if len(want) != 0 {
		t.Fatalf("漏推了 %v", want)
	}
	if call.kind != "turnEnd" || call.sid != "s-select" || call.eid != nil {
		t.Fatalf("调用参数 = %+v", call)
	}
	time.Sleep(120 * time.Millisecond)
	if got := sender.callCount(); got != 1 {
		t.Fatalf("一条 notify 只该触发一次扇出，实际 %d 次", got)
	}
}

// ── 死令牌清理 ──────────────────────────────────────────────────────────────

// TestADeadTokenOnlyClearsTheDeviceThatReportedIt：一次扇出里只有回报死令牌的
// 设备被清登记，同账户的另一台与别的账户都不动，开关也保留。
func TestADeadTokenOnlyClearsTheDeviceThatReportedIt(t *testing.T) {
	reason := "Unregistered"
	sender := newFakePusher()
	f := newFixture(t, Options{Push: sender, Logger: discardLogger()})

	owner := f.newTenant("dead-token")
	dead := f.pairDevice(owner, "iPhone-dead")
	alive := f.pairDevice(owner, "iPhone-alive")
	other := f.newTenant("dead-token-other")
	otherAlive := f.pairDevice(other, "iPhone-other")

	registerPushWith(t, f, dead.DeviceID, strings.Repeat("d1", 32), "sandbox", true, true)
	registerPushWith(t, f, alive.DeviceID, strings.Repeat("a1", 32), "sandbox", true, false)
	registerPushWith(t, f, otherAlive.DeviceID, strings.Repeat("b1", 32), "sandbox", true, true)

	sender.setResultFor(func(target push.Target) push.Result {
		if target.DeviceID == dead.DeviceID {
			return push.Result{DeadToken: true, Reason: &reason}
		}
		return push.Result{OK: true}
	})

	agentLink, _ := f.attachAgent(owner)
	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-dead",
	}))
	sender.wait(t)

	waitFor(t, "死令牌设备的登记被清掉", func() bool {
		row, found, err := f.store.DeviceByID(context.Background(), dead.DeviceID)
		return err == nil && found && row.APNSToken == nil && row.APNSEnv == nil
	})
	// 清理只碰令牌，不动用户的两个开关。
	deadRow, _, err := f.store.DeviceByID(context.Background(), dead.DeviceID)
	if err != nil {
		t.Fatalf("DeviceByID(dead): %v", err)
	}
	if deadRow.PushTurnEnd != 1 || deadRow.PushAttention != 1 {
		t.Fatalf("清理令牌不该改开关：%d/%d", deadRow.PushTurnEnd, deadRow.PushAttention)
	}
	for _, deviceID := range []string{alive.DeviceID, otherAlive.DeviceID} {
		row, found, err := f.store.DeviceByID(context.Background(), deviceID)
		if err != nil || !found {
			t.Fatalf("DeviceByID(%s): found=%v err=%v", deviceID, found, err)
		}
		if row.APNSToken == nil || row.APNSEnv == nil {
			t.Fatalf("设备 %s 的登记被误清：token=%v env=%v",
				deviceID, row.APNSToken, row.APNSEnv)
		}
	}

	// 下一条通知只该推活着的那台：死令牌已被排除，别的账户仍不在范围内。
	sender.setResults()
	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-after-dead",
	}))
	waitFor(t, "第二次扇出", func() bool { return sender.callCount() == 2 })
	calls := sender.callsCopy()
	second := calls[1]
	if len(second.targets) != 1 || second.targets[0].DeviceID != alive.DeviceID {
		t.Fatalf("清理后的 targets = %+v，期望只剩 %s", second.targets, alive.DeviceID)
	}
	time.Sleep(120 * time.Millisecond)
	if got := sender.callCount(); got != 2 {
		t.Fatalf("不该再推别的账户，实际扇出 %d 次", got)
	}
}

// TestAnUnregisteredTokenFromAPNsOnlyClearsItsOwnRegistration 把真实 push.Sender 的
// 410 判定与 hub 的清理接在一起：Apple 说 Unregistered 的那台清登记，另一台保留。
func TestAnUnregisteredTokenFromAPNsOnlyClearsItsOwnRegistration(t *testing.T) {
	deadToken := strings.Repeat("d4", 32)
	aliveToken := strings.Repeat("e5", 32)
	stub := newAPNSStub()
	stub.respond = func(token string) (int, string) {
		if token == deadToken {
			return http.StatusGone, `{"reason":"Unregistered"}`
		}
		return http.StatusOK, ""
	}
	sender := newStubAPNSSender(t, stub)
	f := newFixture(t, Options{Push: sender, Logger: discardLogger()})

	owner := f.newTenant("apns-410")
	dead := f.pairDevice(owner, "iPhone-dead")
	alive := f.pairDevice(owner, "iPhone-alive")
	registerPushWith(t, f, dead.DeviceID, deadToken, "sandbox", true, true)
	registerPushWith(t, f, alive.DeviceID, aliveToken, "sandbox", true, true)
	agentLink, _ := f.attachAgent(owner)

	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-410",
	}))
	requests := stub.waitForRequests(t, 2)
	waitFor(t, "410 之后死令牌登记被清掉", func() bool {
		row, found, err := f.store.DeviceByID(context.Background(), dead.DeviceID)
		return err == nil && found && row.APNSToken == nil && row.APNSEnv == nil
	})
	// 另一台设备的登记必须原样保留。
	time.Sleep(120 * time.Millisecond)
	aliveRow, _, err := f.store.DeviceByID(context.Background(), alive.DeviceID)
	if err != nil {
		t.Fatalf("DeviceByID(alive): %v", err)
	}
	if aliveRow.APNSToken == nil || *aliveRow.APNSToken != aliveToken {
		t.Fatalf("活着设备的令牌被误清：%v", aliveRow.APNSToken)
	}
	deadSeen := 0
	for _, request := range requests {
		if strings.HasSuffix(request.url, deadToken) {
			deadSeen++
		}
	}
	if deadSeen != 1 {
		t.Fatalf("死令牌只该被尝试一次，实际 %d 次", deadSeen)
	}

	// 清掉之后的下一条通知只推活着的那台（先清限速，否则同设备会被跳过）。
	sender.ResetThrottle("")
	f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
		"kind": "turnEnd", "sid": "s-410-after",
	}))
	all := stub.waitForRequests(t, 3)
	last := all[len(all)-1]
	if !strings.HasSuffix(last.url, aliveToken) {
		t.Fatalf("清理后的推送 URL = %q，期望指向 %q", last.url, aliveToken)
	}
}

// ── 失败 / 禁用不影响别的路径 ───────────────────────────────────────────────

// TestPushTroubleDoesNotDisturbForwardingOrAccountState：推送没配置、被禁用或投递
// 失败时，agent→device 的转发与同账户的 accountState 通知都必须照常工作，
// 失败也不许清掉登记。
func TestPushTroubleDoesNotDisturbForwardingOrAccountState(t *testing.T) {
	status := http.StatusInternalServerError
	reason := "InternalServerError"
	cases := []struct {
		name      string
		make      func() (PushSender, *fakePusher)
		attempted bool
	}{
		{"未配置（nil）", func() (PushSender, *fakePusher) { return nil, nil }, false},
		{"禁用实例", func() (PushSender, *fakePusher) {
			pusher := newFakePusher()
			pusher.enabled = false
			return pusher, pusher
		}, false},
		{"投递失败", func() (PushSender, *fakePusher) {
			pusher := newFakePusher(push.Result{Status: &status, Reason: &reason})
			return pusher, pusher
		}, true},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			pushSender, pusher := testCase.make()
			f := newFixture(t, Options{Push: pushSender, Logger: discardLogger()})
			owner := f.newTenant("trouble")
			offline := f.pairDevice(owner, "iPhone-offline")
			online := f.pairDevice(owner, "iPhone-online")
			offlineToken := strings.Repeat("f1", 32)
			registerPushWith(t, f, offline.DeviceID, offlineToken, "sandbox", true, true)

			agentLink, _ := f.attachAgent(owner)
			_, onlineSink := f.mustAttachDevice(online)
			waitFrame(t, onlineSink, "在线设备 hostStatus", isKind("hostStatus"))

			f.hub.RouteFromAgent(agentLink, notifyWire(t, dlp.Frame{
				"kind": "turnEnd", "sid": "s-trouble",
			}))
			if testCase.attempted {
				call := pusher.wait(t)
				if call.kind != "turnEnd" || len(call.targets) != 1 ||
					call.targets[0].DeviceID != offline.DeviceID {
					t.Fatalf("推送调用 = %+v", call)
				}
			}
			// 给后台 goroutine 一点时间把失败结果处理完（日志走 discard，不碰 t）。
			time.Sleep(80 * time.Millisecond)
			if !testCase.attempted && pusher != nil && pusher.callCount() != 0 {
				t.Fatalf("禁用时不该调用投递器（%d 次）", pusher.callCount())
			}

			// 转发照常：agent 的 res 仍然到达在线设备。
			f.hub.RouteFromAgent(agentLink, wireOf(t, dlp.Frame{
				"t": "res", "id": "r-trouble", "deviceId": online.DeviceID,
				"value": map[string]any{"ok": true},
			}))
			forwarded := waitFrame(t, onlineSink, "转发 res", isKind("res"))
			if forwarded["id"] != "r-trouble" {
				t.Fatalf("转发帧 = %v", forwarded)
			}
			value, ok := forwarded["value"].(map[string]any)
			if !ok || value["ok"] != true {
				t.Fatalf("转发内容 = %v", forwarded["value"])
			}

			// 其他通知照常：accountState 仍然送给在线设备。
			if sent := f.hub.NotifyAccountState(owner.account.AccountID,
				[]string{"alertPrefs"}, ""); sent != 1 {
				t.Fatalf("accountState 送达数 = %d，期望 1", sent)
			}
			notification := waitFrame(t, onlineSink, "accountState", isKind("accountState"))
			if keys, ok := notification["keys"].([]any); !ok || len(keys) != 1 ||
				keys[0] != "alertPrefs" {
				t.Fatalf("accountState = %v", notification)
			}

			// notify 是 agent 控制帧，不该跨到设备。
			expectNoFrame(t, onlineSink, "notify 不该跨到设备", isKind("notify"))

			// 失败不是死令牌：登记必须还在。
			row, found, err := f.store.DeviceByID(context.Background(), offline.DeviceID)
			if err != nil || !found {
				t.Fatalf("DeviceByID: found=%v err=%v", found, err)
			}
			if row.APNSToken == nil || *row.APNSToken != offlineToken {
				t.Fatalf("投递失败不该清登记：%v", row.APNSToken)
			}
		})
	}
}

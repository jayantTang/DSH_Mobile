package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/feedback"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/files"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/monitor"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/wsapi"
)

// testAPI 是一套隔离的 store + handler。每个用例一个临时库、一个独立限流器。
type testAPI struct {
	t *testing.T
	// store 是具体库：用例直接用仓储方法准备数据（建账户、配对）。
	store *store.Store
	// port 是交给 handler 的仓储端口；故障注入用例在这里换成包装。
	port    Store
	handler http.Handler
}

func newTestAPI(t *testing.T) *testAPI {
	t.Helper()
	return newTestAPIWithOptions(t, Options{MaxPairedDevices: 8})
}

func newTestAPIWithOptions(t *testing.T, opts Options) *testAPI {
	t.Helper()
	return newTestAPIWithStore(t, opts, openTestStore(t))
}

// openTestStore 建一个隔离的临时库；cleanup 时关闭。
func openTestStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() {
		if err := st.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return st
}

// newTestAPIWithStore 用调用方给的库装配 handler。
//
// 故障注入用例需要把写方法换成真实 SQLite 错误（只读/busy），同时不想复制一整套
// 子 handler 装配，所以这里把"库"作为参数；正常用例走上面的封装。
func newTestAPIWithStore(t *testing.T, opts Options, st *store.Store) *testAPI {
	t.Helper()
	return newTestAPIWithPort(t, opts, st, st)
}

// newTestAPIWithPort 与 newTestAPIWithStore 相同，但交给 handler 的仓储端口可以
// 与具体库不同（故障注入用真实错误替换某一个写方法）。
func newTestAPIWithPort(t *testing.T, opts Options, st *store.Store, port Store) *testAPI {
	t.Helper()
	opts.Store = port
	if opts.Limits == (Limits{}) {
		opts.Limits = DefaultLimits()
	}
	// 子 handler 由组合根构造注入（步骤 1.4）：测试里这一层就是"组合根"。
	if opts.Hub == nil {
		opts.Hub = hub.New(hub.Options{
			Store: st, Limits: opts.Limits, Logger: opts.Logger,
			Push: opts.Push, Monitor: opts.Monitor,
		})
	}
	wsOptions := wsapi.Options{Hub: opts.Hub, Store: st, Logger: opts.Logger}
	if opts.Monitor != nil {
		wsOptions.Monitor = opts.Monitor // 不把 typed nil 塞进接口字段
	}
	opts.WS = wsapi.New(wsOptions)
	opts.Files = files.New(files.Options{Store: st, Hub: opts.Hub, Logger: opts.Logger})
	opts.Feedback = feedback.New(feedback.Options{
		Store: st, ClientID: ClientIdentifier, Logger: opts.Logger,
	})
	return &testAPI{t: t, store: st, port: port, handler: New(opts)}
}

type testTenant struct {
	accountID string
	agentID   string
	secret    string
}

// newTenant 直接经仓储层建账户与电脑（等价于 admin 的 account-create + agent-register）。
func (a *testAPI) newTenant(name string) testTenant {
	a.t.Helper()
	ctx := a.t.Context()
	account, err := a.store.CreateAccount(ctx, name)
	if err != nil {
		a.t.Fatalf("CreateAccount: %v", err)
	}
	agent, secret, err := a.store.RegisterAgent(ctx, account.AccountID, name, nil)
	if err != nil {
		a.t.Fatalf("RegisterAgent: %v", err)
	}
	return testTenant{accountID: account.AccountID, agentID: agent.AgentID, secret: secret}
}

// do 发一次 JSON 请求；RemoteAddr 默认是回环，/stats 用例需要。
func (a *testAPI) do(method, path string, body any, token string) *httptest.ResponseRecorder {
	a.t.Helper()
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			a.t.Fatalf("序列化请求体: %v", err)
		}
		reader = bytes.NewReader(raw)
	}
	req := httptest.NewRequest(method, path, reader)
	req.RemoteAddr = "127.0.0.1:51000"
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	a.handler.ServeHTTP(rec, req)
	return rec
}

// doRaw 发一次原始正文请求（用于坏 JSON 与非 JSON 探针）。
func (a *testAPI) doRaw(method, path string, body []byte, token string) *httptest.ResponseRecorder {
	a.t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	req.RemoteAddr = "127.0.0.1:51000"
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	a.handler.ServeHTTP(rec, req)
	return rec
}

func decodeJSON(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("响应不是 JSON 对象: %v (%s)", err, rec.Body.String())
	}
	return payload
}

// assertEnvelope 断言状态码与错误信封形状，返回解析后的响应体。
func assertEnvelope(t *testing.T, rec *httptest.ResponseRecorder, status int, code string) map[string]any {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("状态码 = %d, 期望 %d：%s", rec.Code, status, rec.Body.String())
	}
	payload := decodeJSON(t, rec)
	if payload["ok"] != false {
		t.Fatalf("错误响应 ok = %v", payload["ok"])
	}
	body, ok := payload["error"].(map[string]any)
	if !ok {
		t.Fatalf("缺少 error 对象: %v", payload)
	}
	if body["code"] != code {
		t.Fatalf("错误码 = %v, 期望 %s（%v）", body["code"], code, payload)
	}
	if message, ok := body["message"].(string); !ok || message == "" {
		t.Fatalf("error.message 非法: %v", body["message"])
	}
	for key := range body {
		if key != "code" && key != "message" && key != "details" {
			t.Fatalf("错误信封多出键 %q", key)
		}
	}
	return payload
}

// mintPairCode 走 HTTP 铸码，返回响应体。
func (a *testAPI) mintPairCode(token string, body any) map[string]any {
	a.t.Helper()
	rec := a.do(http.MethodPost, "/pair/code", body, token)
	if rec.Code != http.StatusOK {
		a.t.Fatalf("铸码失败: %d %s", rec.Code, rec.Body.String())
	}
	return decodeJSON(a.t, rec)
}

// pairDevice 是测试里最常用的准备步骤：铸码 → 认领。
func (a *testAPI) pairDevice(tenant testTenant, name, deviceKey string) map[string]any {
	a.t.Helper()
	minted := a.mintPairCode(tenant.secret, nil)
	payload := map[string]any{"pairCode": minted["code"], "deviceName": name}
	if deviceKey != "" {
		payload["deviceKey"] = deviceKey
	}
	rec := a.do(http.MethodPost, "/pair/claim", payload, "")
	if rec.Code != http.StatusOK {
		a.t.Fatalf("认领失败: %d %s", rec.Code, rec.Body.String())
	}
	return decodeJSON(a.t, rec)
}

func tokenOf(body map[string]any) string {
	token, _ := body["deviceToken"].(string)
	return token
}

func TestProtectedEndpointsAnswer401(t *testing.T) {
	api := newTestAPI(t)
	cases := []struct {
		method string
		path   string
		body   any
		code   string
	}{
		{http.MethodGet, "/devices", nil, "auth/invalid-token"},
		{http.MethodPost, "/devices/revoke", map[string]any{}, "auth/invalid-token"},
		{http.MethodGet, "/account/state", nil, "auth/invalid-token"},
		{http.MethodPut, "/account/state", map[string]any{}, "auth/invalid-token"},
		{http.MethodPost, "/pair/refresh", map[string]any{}, "auth/missing-token"},
		{http.MethodPost, "/pair/code", map[string]any{}, "auth/invalid-agent"},
		{http.MethodPut, "/files/up?sessionId=s&name=n&bid=b&bytes=1", map[string]any{},
			"auth/invalid-token"},
		{http.MethodGet, "/files/down?scopeId=s&path=p", nil, "auth/invalid-token"},
	}
	for _, testCase := range cases {
		rec := api.do(testCase.method, testCase.path, testCase.body, "")
		assertEnvelope(t, rec, http.StatusUnauthorized, testCase.code)
	}
}

func TestErrorEnvelopeShape(t *testing.T) {
	api := newTestAPI(t)
	rec := api.do(http.MethodPost, "/pair/claim", map[string]any{"pairCode": ""}, "")
	payload := assertEnvelope(t, rec, http.StatusBadRequest, "pair/bad-request")
	if _, ok := payload["error"]; !ok {
		t.Fatalf("响应 = %v", payload)
	}
}

func TestEnrollFlow(t *testing.T) {
	api := newTestAPI(t)
	invite, err := api.store.MintInvite(t.Context(), store.DefaultInviteTTLMS, nil,
		"ENROLL-CODE-0001")
	if err != nil {
		t.Fatalf("MintInvite: %v", err)
	}

	rec := api.do(http.MethodPost, "/agents/enroll",
		map[string]any{"inviteCode": invite.Code}, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("登记失败: %d %s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["ok"] != true {
		t.Fatalf("ok = %v", body["ok"])
	}
	agentID, _ := body["agentId"].(string)
	secret, _ := body["agentSecret"].(string)
	accountID, _ := body["accountId"].(string)
	if !strings.HasPrefix(agentID, "agt_") || !strings.HasPrefix(secret, "as_") ||
		!strings.HasPrefix(accountID, "acc_") {
		t.Fatalf("登记返回 = %v", body)
	}
	if body["agentName"] != "My computer" {
		t.Fatalf("默认电脑名 = %v", body["agentName"])
	}

	// 返回的 secret 是可用的凭据：拿它铸码。
	api.mintPairCode(secret, nil)

	// 同一枚码再兑换：已用。
	replay := api.do(http.MethodPost, "/agents/enroll",
		map[string]any{"inviteCode": invite.Code}, "")
	assertEnvelope(t, replay, http.StatusNotFound, "enroll/used")

	// 未知码。
	unknown := api.do(http.MethodPost, "/agents/enroll",
		map[string]any{"inviteCode": "ZZZZ-ZZZZ-ZZZZ-0000"}, "")
	assertEnvelope(t, unknown, http.StatusNotFound, "enroll/unknown")

	// 过期码。
	expired, err := api.store.MintInvite(t.Context(), 0, nil, "ENROLL-CODE-0002")
	if err != nil {
		t.Fatalf("MintInvite(过期): %v", err)
	}
	expiredRec := api.do(http.MethodPost, "/agents/enroll",
		map[string]any{"inviteCode": expired.Code}, "")
	assertEnvelope(t, expiredRec, http.StatusNotFound, "enroll/expired")
}

func TestEnrollRejectsMalformedRequests(t *testing.T) {
	api := newTestAPI(t)
	payloads := []any{
		map[string]any{},
		map[string]any{"inviteCode": ""},
		map[string]any{"inviteCode": "   "},
		map[string]any{"inviteCode": 5},
		map[string]any{"name": "no-code"},
	}
	for _, payload := range payloads {
		rec := api.do(http.MethodPost, "/agents/enroll", payload, "")
		assertEnvelope(t, rec, http.StatusBadRequest, "enroll/bad-request")
	}
	raw := api.doRaw(http.MethodPost, "/agents/enroll", []byte("not json"), "")
	assertEnvelope(t, raw, http.StatusBadRequest, "enroll/bad-request")
}

func TestEnrollCodeBucketFreezesAfterFiveFailures(t *testing.T) {
	api := newTestAPI(t)
	code := "BLACKBOX-FAIL-CODE-0001"
	for index := 0; index < enrollFailures; index++ {
		rec := api.do(http.MethodPost, "/agents/enroll", map[string]any{"inviteCode": code}, "")
		assertEnvelope(t, rec, http.StatusNotFound, "enroll/unknown")
	}
	frozen := api.do(http.MethodPost, "/agents/enroll", map[string]any{"inviteCode": code}, "")
	assertEnvelope(t, frozen, http.StatusTooManyRequests, "enroll/rate-limited")

	// 冻的是这个码，不是这个来源。
	fresh := api.do(http.MethodPost, "/agents/enroll",
		map[string]any{"inviteCode": "BLACKBOX-FAIL-CODE-0002"}, "")
	assertEnvelope(t, fresh, http.StatusNotFound, "enroll/unknown")

	// 来源桶只记账、不否决合法邀请码。
	invite, err := api.store.MintInvite(t.Context(), store.DefaultInviteTTLMS, nil,
		"ENROLL-AFTER-FAILURES")
	if err != nil {
		t.Fatalf("MintInvite: %v", err)
	}
	admitted := api.do(http.MethodPost, "/agents/enroll",
		map[string]any{"inviteCode": invite.Code}, "")
	if admitted.Code != http.StatusOK {
		t.Fatalf("五次失败后合法码被拒: %d %s", admitted.Code, admitted.Body.String())
	}
}

func TestPairCodeAndClaimFlow(t *testing.T) {
	api := newTestAPI(t)
	tenant := api.newTenant("配对测试")

	minted := api.mintPairCode(tenant.secret, nil)
	if minted["persistent"] != true || minted["expiresAt"] != nil {
		t.Fatalf("持久码响应 = %v", minted)
	}
	if minted["agentId"] != tenant.agentID {
		t.Fatalf("agentId = %v", minted["agentId"])
	}
	if minted["maxPairedDevices"] != float64(8) || minted["pairedDevices"] != float64(0) {
		t.Fatalf("配对计数 = %v / %v", minted["maxPairedDevices"], minted["pairedDevices"])
	}

	rec := api.do(http.MethodPost, "/pair/claim", map[string]any{
		"pairCode": minted["code"], "deviceName": "BLACKBOX-iPhone",
		"deviceModel": "iPhone17,1", "appVersion": "9.9.9",
	}, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("认领失败: %d %s", rec.Code, rec.Body.String())
	}
	claimed := decodeJSON(t, rec)
	if claimed["agentId"] != tenant.agentID || claimed["accountId"] != tenant.accountID {
		t.Fatalf("认领归属 = %v", claimed)
	}
	if claimed["reused"] != false {
		t.Fatalf("reused = %v", claimed["reused"])
	}
	if expires, ok := claimed["expiresAt"].(float64); !ok || expires <= 0 {
		t.Fatalf("expiresAt = %v", claimed["expiresAt"])
	}

	// 未知码。
	unknown := api.do(http.MethodPost, "/pair/claim",
		map[string]any{"pairCode": "ZZZZ-ZZZZ"}, "")
	assertEnvelope(t, unknown, http.StatusNotFound, "pair/invalid-code")

	// 过期码（管理面铸的 ttl=0）。
	zero := int64(0)
	expired, err := api.store.MintPairCode(t.Context(), tenant.agentID, &zero)
	if err != nil {
		t.Fatalf("铸过期码: %v", err)
	}
	expiredRec := api.do(http.MethodPost, "/pair/claim",
		map[string]any{"pairCode": expired.Code}, "")
	assertEnvelope(t, expiredRec, http.StatusNotFound, "pair/expired-code")

	// 作废码：先由管理面铸码，再点「重新生成」。
	ttl := int64(600_000)
	oldCode, err := api.store.MintPairCode(t.Context(), tenant.agentID, &ttl)
	if err != nil {
		t.Fatalf("铸限时码: %v", err)
	}
	regenerated := api.do(http.MethodPost, "/pair/code/regenerate", map[string]any{},
		tenant.secret)
	if regenerated.Code != http.StatusOK {
		t.Fatalf("重新生成失败: %d %s", regenerated.Code, regenerated.Body.String())
	}
	regeneratedBody := decodeJSON(t, regenerated)
	if revoked, ok := regeneratedBody["revoked"].(float64); !ok || revoked < 1 {
		t.Fatalf("revoked = %v", regeneratedBody["revoked"])
	}
	if regeneratedBody["persistent"] != true {
		t.Fatalf("重新生成默认应是持久码: %v", regeneratedBody)
	}
	revokedRec := api.do(http.MethodPost, "/pair/claim",
		map[string]any{"pairCode": oldCode.Code}, "")
	assertEnvelope(t, revokedRec, http.StatusNotFound, "pair/revoked-code")
}

func TestPairClaimReusesDeviceKey(t *testing.T) {
	api := newTestAPI(t)
	tenant := api.newTenant("设备复用")

	first := api.pairDevice(tenant, "BLACKBOX-one", "blackbox-key-0001")
	second := api.pairDevice(tenant, "BLACKBOX-one", "blackbox-key-0001")
	if first["deviceId"] != second["deviceId"] {
		t.Fatalf("deviceId = %v vs %v", first["deviceId"], second["deviceId"])
	}
	if second["reused"] != true {
		t.Fatalf("reused = %v", second["reused"])
	}
	if first["deviceToken"] == second["deviceToken"] {
		t.Fatal("复用没有换发新令牌")
	}
}

func TestPairClaimDeviceLimit(t *testing.T) {
	api := newTestAPIWithOptions(t, Options{MaxPairedDevices: 1})
	tenant := api.newTenant("限额")
	api.pairDevice(tenant, "第一台", "")

	minted := api.mintPairCode(tenant.secret, nil)
	rec := api.do(http.MethodPost, "/pair/claim", map[string]any{
		"pairCode": minted["code"], "deviceName": "第二台",
	}, "")
	payload := assertEnvelope(t, rec, http.StatusConflict, "limit/devices")
	details, ok := payload["error"].(map[string]any)["details"].(map[string]any)
	if !ok {
		t.Fatalf("缺少 details: %v", payload)
	}
	if details["maxPairedDevices"] != float64(1) || details["pairedDevices"] != float64(1) {
		t.Fatalf("details = %v", details)
	}
}

func TestPairRefreshRotatesToken(t *testing.T) {
	api := newTestAPI(t)
	tenant := api.newTenant("刷新")
	device := api.pairDevice(tenant, "BLACKBOX-iPhone", "")

	rec := api.do(http.MethodPost, "/pair/refresh", map[string]any{},
		tokenOf(device))
	if rec.Code != http.StatusOK {
		t.Fatalf("刷新失败: %d %s", rec.Code, rec.Body.String())
	}
	refreshed := decodeJSON(t, rec)
	if refreshed["deviceId"] != device["deviceId"] {
		t.Fatalf("deviceId = %v", refreshed["deviceId"])
	}
	newToken, _ := refreshed["deviceToken"].(string)
	if newToken == "" || newToken == tokenOf(device) {
		t.Fatalf("新令牌 = %q", newToken)
	}

	stale := api.do(http.MethodGet, "/devices", nil, tokenOf(device))
	assertEnvelope(t, stale, http.StatusUnauthorized, "auth/invalid-token")
	fresh := api.do(http.MethodGet, "/devices", nil, newToken)
	if fresh.Code != http.StatusOK {
		t.Fatalf("新令牌不可用: %d %s", fresh.Code, fresh.Body.String())
	}

	// 非法令牌与缺失正文。
	invalid := api.do(http.MethodPost, "/pair/refresh", map[string]any{}, "dt_not-a-real-token")
	assertEnvelope(t, invalid, http.StatusUnauthorized, "auth/invalid-token")
}

func TestDevicesListAndRevoke(t *testing.T) {
	api := newTestAPI(t)
	tenant := api.newTenant("设备页")
	keeper := api.pairDevice(tenant, "BLACKBOX-keeper", "")
	doomed := api.pairDevice(tenant, "BLACKBOX-doomed", "")

	listed := api.do(http.MethodGet, "/devices", nil, tokenOf(keeper))
	if listed.Code != http.StatusOK {
		t.Fatalf("列表失败: %d %s", listed.Code, listed.Body.String())
	}
	body := decodeJSON(t, listed)
	if body["currentDeviceId"] != keeper["deviceId"] {
		t.Fatalf("currentDeviceId = %v", body["currentDeviceId"])
	}
	if body["maxPairedDevices"] != float64(8) || body["pairedDevices"] != float64(2) {
		t.Fatalf("配对计数 = %v / %v", body["maxPairedDevices"], body["pairedDevices"])
	}
	rows, ok := body["devices"].([]any)
	if !ok || len(rows) != 2 {
		t.Fatalf("devices = %v", body["devices"])
	}
	found := false
	for _, raw := range rows {
		row := raw.(map[string]any)
		if row["deviceId"] == keeper["deviceId"] {
			found = true
			if row["name"] != "BLACKBOX-keeper" || row["revoked"] != false {
				t.Fatalf("设备行 = %v", row)
			}
		}
	}
	if !found {
		t.Fatalf("列表里没有自己: %v", rows)
	}

	// 未知设备 404。
	unknown := api.do(http.MethodPost, "/devices/revoke",
		map[string]any{"deviceId": "dev_does-not-exist"}, tokenOf(keeper))
	assertEnvelope(t, unknown, http.StatusNotFound, "request/unknown-device")

	// 别人的设备 403。
	other := api.newTenant("别人")
	otherDevice := api.pairDevice(other, "BLACKBOX-other", "")
	forbidden := api.do(http.MethodPost, "/devices/revoke",
		map[string]any{"deviceId": keeper["deviceId"]}, tokenOf(otherDevice))
	assertEnvelope(t, forbidden, http.StatusForbidden, "auth/agent-mismatch")

	// 撤销自己的设备：响应结构固定，旧令牌立刻失效。
	revoked := api.do(http.MethodPost, "/devices/revoke",
		map[string]any{"deviceId": doomed["deviceId"]}, tokenOf(keeper))
	if revoked.Code != http.StatusOK {
		t.Fatalf("撤销失败: %d %s", revoked.Code, revoked.Body.String())
	}
	revokedBody := decodeJSON(t, revoked)
	if revokedBody["ok"] != true || revokedBody["deviceId"] != doomed["deviceId"] {
		t.Fatalf("撤销响应 = %v", revokedBody)
	}
	stale := api.do(http.MethodGet, "/devices", nil, tokenOf(doomed))
	assertEnvelope(t, stale, http.StatusUnauthorized, "auth/invalid-token")

	// 缺少 deviceId。
	missing := api.do(http.MethodPost, "/devices/revoke", map[string]any{}, tokenOf(keeper))
	assertEnvelope(t, missing, http.StatusBadRequest, "request/device-id")
}

func TestAccountStateEndpoints(t *testing.T) {
	api := newTestAPI(t)
	tenant := api.newTenant("状态")
	device := api.pairDevice(tenant, "BLACKBOX-iPhone", "")
	token := tokenOf(device)

	written := api.do(http.MethodPut, "/account/state", map[string]any{"entries": []any{
		map[string]any{"key": "alertPrefs", "value": map[string]any{"turnEnd": false},
			"updatedAt": 1700000000000},
		map[string]any{"key": "lastSession", "value": "session-1", "updatedAt": 1700000000000},
	}}, token)
	if written.Code != http.StatusOK {
		t.Fatalf("写入失败: %d %s", written.Code, written.Body.String())
	}
	writtenBody := decodeJSON(t, written)
	applied, _ := writtenBody["applied"].([]any)
	if len(applied) != 2 || applied[0] != "alertPrefs" || applied[1] != "lastSession" {
		t.Fatalf("applied = %v", writtenBody["applied"])
	}
	entries := writtenBody["entries"].(map[string]any)
	alert := entries["alertPrefs"].(map[string]any)
	if alert["updatedAt"] != float64(1700000000000) ||
		alert["updatedByDeviceId"] != device["deviceId"] {
		t.Fatalf("写入结果 = %v", alert)
	}
	if alert["key"] != "alertPrefs" {
		t.Fatalf("写入结果缺 key: %v", alert)
	}

	read := api.do(http.MethodGet, "/account/state", nil, token)
	if read.Code != http.StatusOK {
		t.Fatalf("读取失败: %d %s", read.Code, read.Body.String())
	}
	readBody := decodeJSON(t, read)
	if readBody["accountId"] != tenant.accountID {
		t.Fatalf("accountId = %v", readBody["accountId"])
	}
	readEntries := readBody["entries"].(map[string]any)
	// 读取路径的条目没有 "key"（Python 的 GET 是按 key 索引的对象）。
	if _, hasKey := readEntries["alertPrefs"].(map[string]any)["key"]; hasKey {
		t.Fatalf("GET 条目不该有 key: %v", readEntries["alertPrefs"])
	}
	if readEntries["lastSession"].(map[string]any)["value"] != "session-1" {
		t.Fatalf("lastSession = %v", readEntries["lastSession"])
	}
	prefs := readEntries["alertPrefs"].(map[string]any)["value"].(map[string]any)
	if prefs["turnEnd"] != false {
		t.Fatalf("alertPrefs = %v", prefs)
	}

	filtered := api.do(http.MethodGet, "/account/state?keys=alertPrefs", nil, token)
	if filtered.Code != http.StatusOK {
		t.Fatalf("过滤读取失败: %d", filtered.Code)
	}
	if len(decodeJSON(t, filtered)["entries"].(map[string]any)) != 1 {
		t.Fatalf("过滤结果 = %s", filtered.Body.String())
	}

	// 更旧的时间戳：不覆盖，applied 为空，返回已存的那份。
	older := api.do(http.MethodPut, "/account/state", map[string]any{"entries": []any{
		map[string]any{"key": "alertPrefs", "value": map[string]any{"turnEnd": true},
			"updatedAt": 1600000000000},
	}}, token)
	if older.Code != http.StatusOK {
		t.Fatalf("旧时间戳失败: %d %s", older.Code, older.Body.String())
	}
	olderBody := decodeJSON(t, older)
	if applied, _ := olderBody["applied"].([]any); len(applied) != 0 {
		t.Fatalf("旧时间戳被应用: %v", applied)
	}
	if olderBody["entries"].(map[string]any)["alertPrefs"].(map[string]any)["updatedAt"] !=
		float64(1700000000000) {
		t.Fatalf("返回的已存值 = %v", olderBody["entries"])
	}
}

func TestAccountStateValidation(t *testing.T) {
	api := newTestAPI(t)
	tenant := api.newTenant("状态校验")
	token := tokenOf(api.pairDevice(tenant, "BLACKBOX-iPhone", ""))

	// 空数组。
	empty := api.do(http.MethodPut, "/account/state",
		map[string]any{"entries": []any{}}, token)
	assertEnvelope(t, empty, http.StatusBadRequest, "account-state/bad-request")

	// 超过 64 条。
	many := make([]any, 0, 65)
	for index := 0; index < 65; index++ {
		many = append(many, map[string]any{
			"key":   "k" + string(rune('a'+index%26)) + string(rune('a'+index/26)),
			"value": index, "updatedAt": 1000 + index,
		})
	}
	tooMany := api.do(http.MethodPut, "/account/state",
		map[string]any{"entries": many}, token)
	assertEnvelope(t, tooMany, http.StatusBadRequest, "account-state/bad-request")

	// 单条超过 8 KiB。
	tooLarge := api.do(http.MethodPut, "/account/state", map[string]any{"entries": []any{
		map[string]any{"key": "tooBig", "value": strings.Repeat("x", 9000),
			"updatedAt": 1700000000000},
	}}, token)
	assertEnvelope(t, tooLarge, http.StatusRequestEntityTooLarge, "account-state/too-large")

	// updatedAt 必须是正整数；浮点不是整数。
	for _, stamp := range []any{0, -1, 1.5, "1700000000000", nil} {
		rec := api.do(http.MethodPut, "/account/state", map[string]any{"entries": []any{
			map[string]any{"key": "badStamp", "value": 1, "updatedAt": stamp},
		}}, token)
		assertEnvelope(t, rec, http.StatusBadRequest, "account-state/bad-request")
	}

	// key 必须是非空字符串。
	badKey := api.do(http.MethodPut, "/account/state", map[string]any{"entries": []any{
		map[string]any{"key": "", "value": 1, "updatedAt": 1},
	}}, token)
	assertEnvelope(t, badKey, http.StatusBadRequest, "account-state/bad-request")

	// 整批校验：第二条坏掉时第一条也不写（Python 版会留下半批）。
	partial := api.do(http.MethodPut, "/account/state", map[string]any{"entries": []any{
		map[string]any{"key": "good", "value": 1, "updatedAt": 1700000000000},
		map[string]any{"key": "bad", "value": 1, "updatedAt": 0},
	}}, token)
	assertEnvelope(t, partial, http.StatusBadRequest, "account-state/bad-request")
	read := api.do(http.MethodGet, "/account/state", nil, token)
	if entries := decodeJSON(t, read)["entries"].(map[string]any); len(entries) != 0 {
		t.Fatalf("坏批留下了状态: %v", entries)
	}
}

func TestStatsLoopbackOnly(t *testing.T) {
	api := newTestAPI(t)

	rec := api.do(http.MethodGet, "/stats", nil, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("/stats = %d: %s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	for _, key := range []string{"ok", "version", "now", "limits", "load", "traffic",
		"controlDrops", "snapshot", "deviceRecords", "today",
		// 连接生命周期字段（M7 新增；旧字段一个没动）。
		"superseded", "reconnectStorm", "unverifiedAgents",
		"unverifiedTotal", "refusedDuplicate", "refusedUnverified"} {
		if _, ok := body[key]; !ok {
			t.Fatalf("/stats 缺字段 %q: %v", key, body)
		}
	}
	for _, key := range []string{"superseded", "reconnectStorm", "unverifiedAgents"} {
		if body[key] != float64(0) {
			t.Fatalf("没有连接时 %s = %v，期望 0", key, body[key])
		}
	}
	if drops := body["controlDrops"]; drops != float64(0) {
		t.Fatalf("没有连接时 controlDrops = %v，期望 0", drops)
	}
	limits := body["limits"].(map[string]any)
	if limits["maxFrameBytes"] != float64(MaxFrameBytes) {
		t.Fatalf("maxFrameBytes = %v", limits["maxFrameBytes"])
	}
	if limits["queueDepth"] != float64(512) || limits["agentQueueDepth"] != float64(4096) {
		t.Fatalf("队列默认值 = %v", limits)
	}
	for _, key := range []string{"maxDevicesPerAgent", "deviceBytesPerSecond",
		"deviceDailyBytes"} {
		if limits[key] != nil {
			t.Fatalf("默认不限的 %s 应为 null: %v", key, limits[key])
		}
	}
	if limits["deadDeviceWarnThreshold"] != float64(200) {
		t.Fatalf("deadDeviceWarnThreshold = %v", limits["deadDeviceWarnThreshold"])
	}
	load := body["load"].(map[string]any)
	if load["agents"] != float64(0) || load["devices"] != float64(0) {
		t.Fatalf("load = %v", load)
	}
	today := body["today"].(map[string]any)
	if today["day"] != float64(store.LocalDay()) || today["totalEgressBytes"] != float64(0) {
		t.Fatalf("today = %v", today)
	}
	if records, ok := body["deviceRecords"].(map[string]any); !ok || records["total"] != float64(0) {
		t.Fatalf("deviceRecords = %v", body["deviceRecords"])
	}

	// 非回环来源：404，而且也是错误信封。
	req := httptest.NewRequest(http.MethodGet, "/stats", nil)
	req.RemoteAddr = "203.0.113.9:1234"
	nonLoopback := httptest.NewRecorder()
	api.handler.ServeHTTP(nonLoopback, req)
	assertEnvelope(t, nonLoopback, http.StatusNotFound, "not-found")
}

// TestStatsReturnsHTMLWhenAsked 钉住内容协商：Accept: text/html 拿运维页，
// 其余客户端继续拿 JSON（旧读法不变）。
func TestStatsReturnsHTMLWhenAsked(t *testing.T) {
	api := newTestAPI(t)
	req := httptest.NewRequest(http.MethodGet, "/stats", nil)
	req.RemoteAddr = "127.0.0.1:51000"
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	rec := httptest.NewRecorder()
	api.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/stats (html) = %d: %s", rec.Code, rec.Body.String())
	}
	if contentType := rec.Header().Get("Content-Type"); !strings.HasPrefix(contentType, "text/html") {
		t.Fatalf("Content-Type = %q，期望 text/html", contentType)
	}
	body := rec.Body.String()
	for _, want := range []string{"DLP relay", "实时负载与流量", "每 agent 设备数", "今日用量"} {
		if !strings.Contains(body, want) {
			t.Fatalf("运维页缺 %q", want)
		}
	}
}

// TestStatsPageMatchesThePythonOperationalPage 用一份真实的 statsResponse 渲染，
// 逐项核对与 Python `_stats_page` 同口径的数字：连接数、限额、死记录、每设备流量、
// 今日用量；设备名必须转义。
func TestStatsPageMatchesThePythonOperationalPage(t *testing.T) {
	payload := statsResponse{
		OK:      true,
		Version: ProtocolVersion,
		Now:     store.NowMS(),
		Limits: hub.Limits{
			MaxFrameBytes: 32 << 20, QueueDepth: 512, AgentQueueDepth: 4096,
			QueueBytes: 8 << 20, DeadDeviceWarnThreshold: 200,
			MaxDevicesPerAgent: 8, DeviceBytesPerSecond: 102400, DeviceDailyBytes: 5 << 30,
		}.Describe(),
		Load: statsLoad{Agents: 2, Devices: 1},
		Traffic: hub.Traffic{TotalEgressBytes: 3 << 20, Devices: []hub.TrafficDevice{{
			DeviceID: "dev_1", Name: `<script>alert(1)</script>`, EgressBytes: 2 << 20,
			PacedSeconds: 1.25, QuotaRemainingBytes: 100 << 20,
		}}},
		DeviceRecords: store.Hygiene{Total: 5, Live: 3, Revoked: 1, Expired: 1, Dead: 2},
		Today: store.TodayUsage{
			Day: 20261023, TotalEgressBytes: 1 << 20,
			Devices: []store.TodayDevice{{DeviceID: "dev_1", AccountID: "acc_1",
				EgressBytes: 1 << 20, Connections: 1}},
			Accounts: []store.TodayAccount{{AccountID: "acc_1", Devices: 1, EgressBytes: 1 << 20}},
		},
		Stats: presence.Stats{Superseded: 3, ReconnectStorm: 7, UnverifiedAgents: 1},
	}

	var buffer bytes.Buffer
	if err := statsPageTemplate.Execute(&buffer, newStatsPageData(payload)); err != nil {
		t.Fatalf("渲染运维页: %v", err)
	}
	body := buffer.String()
	for _, want := range []string{
		"agent <span class=big>2</span> 个",
		"连接设备 <span class=big>1</span> 台",
		"本次启动累计出口 <span class=big>3.00 MB</span>",
		"死设备记录 <span class=big>2</span> 条",
		"已撤销 1", "已过期 1", "在用 3",
		"每 agent 设备数 8",
		"102400 B/s", "5368709120 B",
		"<td class=num>2.00 MB</td>", "<td class=num>1.2s</td>", "<td class=num>100.0 MB</td>",
		"今日用量（本地日 2026-10-23）",
		"总出口 <span class=big>1.00 MB</span>", "1 台设备",
		"acc_1",
		"顶替 3 次", "重复连接抑制 7 次", "未上报版本的在线连接 1 条",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("运维页缺 %q\n%s", want, body)
		}
	}
	if strings.Contains(body, "<script>alert(1)</script>") {
		t.Fatal("设备名没有 HTML 转义")
	}
	if !strings.Contains(body, "&lt;script&gt;alert(1)&lt;/script&gt;") {
		t.Fatalf("设备名的转义形态不对：%s", body)
	}
}

func TestCORSAndBasePath(t *testing.T) {
	api := newTestAPIWithOptions(t, Options{MaxPairedDevices: 8, BasePath: "/dsh-link"})

	preflight := api.handler
	req := httptest.NewRequest(http.MethodOptions, "/pair/claim", nil)
	rec := httptest.NewRecorder()
	preflight.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("预检状态码 = %d", rec.Code)
	}
	for header, want := range map[string]string{
		"Access-Control-Allow-Origin":  "*",
		"Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
		"Access-Control-Max-Age":       "600",
	} {
		if got := rec.Header().Get(header); got != want {
			t.Fatalf("%s = %q, 期望 %q", header, got, want)
		}
	}

	// 普通响应也带 ACAO（预检放行不等于正文可读）。
	health := api.do(http.MethodGet, "/healthz", nil, "")
	if health.Code != http.StatusOK {
		t.Fatalf("/healthz = %d", health.Code)
	}
	if got := health.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("ACAO = %q", got)
	}

	// 带前缀与去前缀两种形式都命中同一个处理器。
	prefixed := api.do(http.MethodGet, "/dsh-link/healthz", nil, "")
	if prefixed.Code != http.StatusOK {
		t.Fatalf("/dsh-link/healthz = %d", prefixed.Code)
	}
	tenant := api.newTenant("前缀")
	minted := api.mintPairCode(tenant.secret, nil)
	claimPrefixed := api.do(http.MethodPost, "/dsh-link/pair/claim", map[string]any{
		"pairCode": minted["code"],
	}, "")
	if claimPrefixed.Code != http.StatusOK {
		t.Fatalf("前缀认领失败: %d %s", claimPrefixed.Code, claimPrefixed.Body.String())
	}

	// 未知路径仍然是 404。
	unknown := api.do(http.MethodGet, "/no-such-route", nil, "")
	if unknown.Code != http.StatusNotFound {
		t.Fatalf("未知路径 = %d", unknown.Code)
	}
}

func TestAgentMismatchOnPairCode(t *testing.T) {
	api := newTestAPI(t)
	first := api.newTenant("甲")
	second := api.newTenant("乙")

	rec := api.do(http.MethodPost, "/pair/code",
		map[string]any{"agentId": second.agentID}, first.secret)
	assertEnvelope(t, rec, http.StatusForbidden, "auth/agent-mismatch")
}

func TestPairCodeTTLRules(t *testing.T) {
	api := newTestAPI(t)
	tenant := api.newTenant("TTL")

	// 显式 ttlMs：限时码。
	minted := api.mintPairCode(tenant.secret, map[string]any{"ttlMs": 60000})
	if minted["persistent"] != false || minted["ttlMs"] != float64(60000) {
		t.Fatalf("限时码 = %v", minted)
	}
	if expires, ok := minted["expiresAt"].(float64); !ok || expires <= 0 {
		t.Fatalf("expiresAt = %v", minted["expiresAt"])
	}

	// 超长 TTL 被夹到一小时。
	capped := api.mintPairCode(tenant.secret, map[string]any{"ttlMs": 999999999})
	if capped["ttlMs"] != float64(3600000) {
		t.Fatalf("TTL 上限 = %v", capped["ttlMs"])
	}

	// persistent:false 且 ttlMs 给 0（不是正数）：落到默认的 pair TTL（10 分钟）。
	defaulted := api.mintPairCode(tenant.secret,
		map[string]any{"persistent": false, "ttlMs": 0})
	if defaulted["ttlMs"] != float64(600000) || defaulted["persistent"] != false {
		t.Fatalf("默认 TTL = %v", defaulted)
	}

	// 只给 persistent:false、不带 ttlMs：Python 的 requested is None 让持久码优先。
	noTTL := api.mintPairCode(tenant.secret, map[string]any{"persistent": false})
	if noTTL["persistent"] != true {
		t.Fatalf("persistent:false 且无 ttlMs = %v", noTTL)
	}

	// persistent:true 优先于 ttlMs。
	persistent := api.mintPairCode(tenant.secret,
		map[string]any{"persistent": true, "ttlMs": 60000})
	if persistent["persistent"] != true || persistent["expiresAt"] != nil {
		t.Fatalf("持久码 = %v", persistent)
	}

	// 显式 null 与不带同义。
	explicitNull := api.mintPairCode(tenant.secret, map[string]any{"ttlMs": nil})
	if explicitNull["persistent"] != true {
		t.Fatalf("ttlMs:null = %v", explicitNull)
	}
}

func TestRecoveryMiddlewareReturnsJSONEnvelope(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := monitor.Middleware(nil, logger)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	}))
	req := httptest.NewRequest(http.MethodGet, "/boom", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	assertEnvelope(t, rec, http.StatusInternalServerError, "internal/error")
}

func TestBusyStoreErrorMapsTo503(t *testing.T) {
	s := &server{}
	req := httptest.NewRequest(http.MethodGet, "/account/state", nil)
	rec := httptest.NewRecorder()
	s.writeStoreError(rec, req, errors.New("database is locked (5) (SQLITE_BUSY)"))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("busy 状态码 = %d", rec.Code)
	}
	if retry := rec.Header().Get("Retry-After"); retry != "1" {
		t.Fatalf("Retry-After = %q", retry)
	}
	assertEnvelope(t, rec, http.StatusServiceUnavailable, "db/busy")
}

func TestClientIdentifierUsesForwardedForOnlyFromLoopback(t *testing.T) {
	loopback := httptest.NewRequest(http.MethodPost, "/agents/enroll", nil)
	loopback.RemoteAddr = "127.0.0.1:5555"
	loopback.Header.Set("X-Forwarded-For", "198.51.100.7, 10.0.0.1")
	if got := ClientIdentifier(loopback); got != "198.51.100.7" {
		t.Fatalf("回环 + XFF = %q", got)
	}

	external := httptest.NewRequest(http.MethodPost, "/agents/enroll", nil)
	external.RemoteAddr = "198.51.100.9:5555"
	external.Header.Set("X-Forwarded-For", "203.0.113.1")
	if got := ClientIdentifier(external); got != "198.51.100.9" {
		t.Fatalf("非回环必须忽略 XFF: %q", got)
	}
}

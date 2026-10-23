package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// ── 桩 ─────────────────────────────────────────────────────────────────────

// stubStep 是一次桩响应：状态码、正文、响应头，或者一个传输错误。
type stubStep struct {
	status  int
	body    string
	headers map[string]string
	err     error
}

// stubRequest 是桩收到的请求（正文已读出来，headers 已复制）。
type stubRequest struct {
	url     string
	headers http.Header
	body    []byte
}

// stubClient 记录每次请求，按队列回放响应。
type stubClient struct {
	mu      sync.Mutex
	steps   []stubStep
	records []stubRequest
}

func (s *stubClient) Do(request *http.Request) (*http.Response, error) {
	body, _ := io.ReadAll(request.Body)
	_ = request.Body.Close()
	s.mu.Lock()
	s.records = append(s.records, stubRequest{
		url: request.URL.String(), headers: request.Header.Clone(), body: body,
	})
	var step stubStep
	if len(s.steps) > 0 {
		step = s.steps[0]
		s.steps = s.steps[1:]
	} else {
		step = stubStep{status: http.StatusOK, headers: map[string]string{"apns-id": "stub"}}
	}
	s.mu.Unlock()
	if step.err != nil {
		return nil, step.err
	}
	status := step.status
	if status == 0 {
		status = http.StatusOK
	}
	header := http.Header{}
	header.Set("apns-id", "stub")
	for name, value := range step.headers {
		header.Set(name, value)
	}
	return &http.Response{
		StatusCode: status,
		Header:     header,
		Body:       io.NopCloser(strings.NewReader(step.body)),
	}, nil
}

func (s *stubClient) calls() []stubRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]stubRequest, len(s.records))
	copy(out, s.records)
	return out
}

// ── 测试夹具 ───────────────────────────────────────────────────────────────

// generatedKeyPath 在临时目录生成一张用完即弃的 P-256 私钥。
//
// 仓库里不许存在任何私钥，测试要就自己造一张（与 Python 版同一条规则）。
func generatedKeyPath(t *testing.T) (string, *ecdsa.PrivateKey) {
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
	return path, key
}

// testSender 是"已配置 + 注入桩"的投递器，时钟固定。
func testSender(t *testing.T, client Client) *Sender {
	t.Helper()
	keyPath, _ := generatedKeyPath(t)
	now := time.Unix(1_000_000, 0)
	sender := &Sender{
		keyPath: keyPath, keyID: "TESTKEY12", teamID: "TEAMID1234",
		topic: "com.example.app", defaultEnv: "sandbox",
		minGap: 60 * time.Second, enabled: true, client: client,
		now: func() time.Time { return now }, lastSent: map[string]time.Time{},
	}
	return sender
}

func envGetter(values map[string]string) func(string) string {
	return func(name string) string { return values[name] }
}

func deref(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func statusOf(result Result) int {
	if result.Status == nil {
		return 0
	}
	return *result.Status
}

func payloadOf(t *testing.T, request stubRequest) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(request.body, &payload); err != nil {
		t.Fatalf("请求正文不是 JSON: %v (%s)", err, request.body)
	}
	return payload
}

// ── payload 承诺 ───────────────────────────────────────────────────────────

func TestThePayloadContainsOnlyLocalizationKeyAndIdentifiers(t *testing.T) {
	body := payloadFor("turnEnd", "session-abc", nil)
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("编码 payload: %v", err)
	}
	var parsed map[string]any
	if err := json.Unmarshal(encoded, &parsed); err != nil {
		t.Fatalf("解析 payload: %v", err)
	}
	want := map[string]any{
		"aps": map[string]any{
			"alert":     map[string]any{"title-loc-key": "运行结束"},
			"sound":     "default",
			"thread-id": "session-abc",
		},
		"kind": "turnEnd",
		"sid":  "session-abc",
	}
	if diff := compareJSON(t, parsed, want); diff != "" {
		t.Fatalf("payload 与契约不一致：%s", diff)
	}
	attention := payloadFor("attention", "session-abc", stringPtrForTest("evt-1"))
	encoded, _ = json.Marshal(attention)
	var parsedAttention map[string]any
	_ = json.Unmarshal(encoded, &parsedAttention)
	if parsedAttention["eid"] != "evt-1" {
		t.Fatalf("attention 的 eid = %v", parsedAttention["eid"])
	}
	alert := parsedAttention["aps"].(map[string]any)["alert"].(map[string]any)
	if len(alert) != 1 || alert["title-loc-key"] != "需要你确认" {
		t.Fatalf("alert = %v", alert)
	}
}

func TestNoContentFieldCanAppearInAnyKind(t *testing.T) {
	forbidden := map[string]struct{}{
		"title": {}, "subtitle": {}, "body": {}, "loc-args": {}, "title-loc-args": {},
		"loc-key": {}, "message": {}, "text": {}, "path": {}, "host": {}, "tool": {},
		"error": {}, "sessionTitle": {},
	}
	for kind := range AlertKeys {
		body := payloadFor(kind, "sid-1", stringPtrForTest("eid-1"))
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("编码 %s: %v", kind, err)
		}
		var parsed map[string]any
		if err := json.Unmarshal(encoded, &parsed); err != nil {
			t.Fatalf("解析 %s: %v", kind, err)
		}
		for key := range parsed {
			if key != "aps" && key != "kind" && key != "sid" && key != "eid" {
				t.Fatalf("%s 的 payload 多出字段 %q", kind, key)
			}
		}
		aps := parsed["aps"].(map[string]any)
		for key := range aps {
			if key != "alert" && key != "sound" && key != "thread-id" {
				t.Fatalf("%s 的 aps 多出字段 %q", kind, key)
			}
		}
		alert := aps["alert"].(map[string]any)
		for key := range alert {
			if _, bad := forbidden[key]; bad {
				t.Fatalf("%s 的 alert 出现正文类字段 %q", kind, key)
			}
		}
		alertJSON, _ := json.Marshal(alert)
		if strings.Contains(string(alertJSON), "sid-1") ||
			strings.Contains(string(alertJSON), "eid-1") {
			t.Fatalf("%s：会话标识混进了 alert：%s", kind, alertJSON)
		}
	}
}

// ── 禁用 / 配置不全 ────────────────────────────────────────────────────────

func TestADisabledSenderNeverTouchesHTTP(t *testing.T) {
	client := &stubClient{}
	sender := FromEnv(envGetter(nil), client)
	if sender.Enabled() {
		t.Fatal("空环境应当得到禁用实例")
	}
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: strings.Repeat("aa", 32), Kind: "turnEnd", SID: "s-1",
	})
	if deref(result.Skipped) != "disabled" || result.OK {
		t.Fatalf("结果 = %+v", result)
	}
	if len(client.calls()) != 0 {
		t.Fatal("禁用实例不该发 HTTP 请求")
	}
}

func TestPartialConfigurationDisablesPushInsteadOfPanicking(t *testing.T) {
	client := &stubClient{}
	sender := FromEnv(envGetter(map[string]string{
		"DLP_APNS_ENABLED": "1", "DLP_APNS_KEY_ID": "K",
	}), client)
	if sender.Enabled() {
		t.Fatal("配置不全必须是禁用实例")
	}
	result := sender.Send(context.Background(), Request{
		DeviceID: "d", Token: "t", Kind: "turnEnd", SID: "s",
	})
	if deref(result.Skipped) != "disabled" {
		t.Fatalf("结果 = %+v", result)
	}
}

func TestAMissingKeyFileDisablesPush(t *testing.T) {
	sender := FromEnv(envGetter(map[string]string{
		"DLP_APNS_ENABLED": "1", "DLP_APNS_KEY_PATH": "/nonexistent/AuthKey_XX.p8",
		"DLP_APNS_KEY_ID": "K", "DLP_APNS_TEAM_ID": "T", "DLP_APNS_TOPIC": "com.x",
	}), &stubClient{})
	if sender.Enabled() {
		t.Fatal("密钥文件不存在必须禁用")
	}
}

func TestFullyConfiguredEnvIsEnabledAndReadsEverySetting(t *testing.T) {
	keyPath, _ := generatedKeyPath(t)
	sender := FromEnv(envGetter(map[string]string{
		"DLP_APNS_ENABLED": "1", "DLP_APNS_KEY_PATH": keyPath,
		"DLP_APNS_KEY_ID": "TESTKEY12", "DLP_APNS_TEAM_ID": "TEAM123456",
		"DLP_APNS_TOPIC": "com.jayanttang.dsh", "DLP_APNS_ENV_DEFAULT": "production",
		"DLP_APNS_MIN_INTERVAL_S": "5",
	}), &stubClient{})
	if !sender.Enabled() {
		t.Fatal("完整配置必须启用")
	}
	if sender.defaultEnv != "production" || sender.minGap != 5*time.Second {
		t.Fatalf("defaultEnv=%q minGap=%v", sender.defaultEnv, sender.minGap)
	}
	if sender.topic != "com.jayanttang.dsh" {
		t.Fatalf("topic = %q", sender.topic)
	}
}

func TestTheSwitchIsOffUnlessItSaysOtherwise(t *testing.T) {
	for _, value := range []string{"0", "", "no", "false", "off"} {
		env := map[string]string{"DLP_APNS_ENABLED": value}
		if FromEnv(envGetter(env), &stubClient{}).Enabled() {
			t.Fatalf("DLP_APNS_ENABLED=%q 应当是关闭", value)
		}
	}
	for _, value := range []string{"1", "true", "YES", "on"} {
		keyPath, _ := generatedKeyPath(t)
		env := map[string]string{
			"DLP_APNS_ENABLED": value, "DLP_APNS_KEY_PATH": keyPath,
			"DLP_APNS_KEY_ID": "K", "DLP_APNS_TEAM_ID": "T", "DLP_APNS_TOPIC": "com.x",
		}
		if !FromEnv(envGetter(env), &stubClient{}).Enabled() {
			t.Fatalf("DLP_APNS_ENABLED=%q 应当启用", value)
		}
	}
}

// ── 请求本身 ───────────────────────────────────────────────────────────────

func TestSendPostsToTheHostThatMatchesTheDeviceEnvironment(t *testing.T) {
	client := &stubClient{steps: []stubStep{{
		status: http.StatusOK, headers: map[string]string{"apns-id": "abc"},
	}}}
	sender := testSender(t, client)
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: strings.Repeat("ff", 32),
		Env: stringPtrForTest("production"), Kind: "turnEnd", SID: "s-1",
	})
	if !result.OK || statusOf(result) != 200 || deref(result.APNSID) != "abc" {
		t.Fatalf("结果 = %+v", result)
	}
	requests := client.calls()
	if len(requests) != 1 {
		t.Fatalf("请求数 = %d", len(requests))
	}
	wantURL := Hosts["production"] + "/3/device/" + strings.Repeat("ff", 32)
	if requests[0].url != wantURL {
		t.Fatalf("URL = %q", requests[0].url)
	}
	headers := requests[0].headers
	if headers.Get("apns-topic") != "com.example.app" {
		t.Fatalf("apns-topic = %q", headers.Get("apns-topic"))
	}
	if headers.Get("apns-push-type") != "alert" || headers.Get("apns-priority") != "10" {
		t.Fatalf("推送头 = %v", headers)
	}
	if headers.Get("apns-collapse-id") != "s-1" {
		t.Fatalf("collapse-id = %q", headers.Get("apns-collapse-id"))
	}
	if !strings.HasPrefix(headers.Get("authorization"), "bearer ") {
		t.Fatalf("authorization = %q", headers.Get("authorization"))
	}
	if left, right := headers.Get("apns-expiration"), "1003600"; left != right {
		t.Fatalf("apns-expiration = %q, 期望 %q", left, right)
	}
}

func TestAttentionSetsLongerExpiration(t *testing.T) {
	client := &stubClient{}
	sender := testSender(t, client)
	sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "attention", SID: "s-1",
		EID: stringPtrForTest("e-1"),
	})
	if got := client.calls()[0].headers.Get("apns-expiration"); got != "1086400" {
		t.Fatalf("attention 的 apns-expiration = %q", got)
	}
}

func TestASessionIDLongerThanApplesLimitIsTruncated(t *testing.T) {
	client := &stubClient{}
	sender := testSender(t, client)
	sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: strings.Repeat("s", 200),
	})
	if got := len(client.calls()[0].headers.Get("apns-collapse-id")); got != 64 {
		t.Fatalf("collapse-id 长度 = %d", got)
	}
}

func TestAnUnknownKindIsNotSent(t *testing.T) {
	client := &stubClient{}
	sender := testSender(t, client)
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "made-up", SID: "s",
	})
	if deref(result.Skipped) != "unsupported-kind" || len(client.calls()) != 0 {
		t.Fatalf("结果 = %+v，请求数 = %d", result, len(client.calls()))
	}
}

func TestAnUnusableEnvironmentIsNotGuessed(t *testing.T) {
	client := &stubClient{}
	sender := testSender(t, client)
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Env: stringPtrForTest("staging"),
		Kind: "turnEnd", SID: "s",
	})
	if deref(result.Skipped) != "unknown-env" || len(client.calls()) != 0 {
		t.Fatalf("结果 = %+v，请求数 = %d", result, len(client.calls()))
	}
}

// ── 签名 ───────────────────────────────────────────────────────────────────

func TestTheProviderTokenIsSignedOnceAndReused(t *testing.T) {
	keyPath, key := generatedKeyPath(t)
	client := &stubClient{}
	sender := &Sender{
		keyPath: keyPath, keyID: "TESTKEY12", teamID: "TEAM123456",
		topic: "com.x", defaultEnv: "sandbox", enabled: true, client: client,
		now:      func() time.Time { return time.Unix(1_000_000, 0) },
		lastSent: map[string]time.Time{},
	}
	first := sender.Send(context.Background(), Request{
		DeviceID: "d1", Token: "aa", Kind: "turnEnd", SID: "s1",
	})
	second := sender.Send(context.Background(), Request{
		DeviceID: "d2", Token: "bb", Kind: "turnEnd", SID: "s2",
	})
	if !first.OK || !second.OK {
		t.Fatalf("结果 = %+v / %+v", first, second)
	}
	requests := client.calls()
	authFirst := requests[0].headers.Get("authorization")
	authSecond := requests[1].headers.Get("authorization")
	if authFirst != authSecond {
		t.Fatal("同一小时内不该重签")
	}
	raw := strings.TrimPrefix(authFirst, "bearer ")
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		t.Fatalf("JWT 不是三段：%d", len(parts))
	}
	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("解 JWT 头: %v", err)
	}
	var header map[string]any
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		t.Fatalf("JWT 头不是 JSON: %v", err)
	}
	if header["alg"] != "ES256" || header["typ"] != "JWT" || header["kid"] != "TESTKEY12" {
		t.Fatalf("JWT 头 = %v", header)
	}
	claimsJSON, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var claims map[string]any
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		t.Fatalf("JWT claims: %v", err)
	}
	if claims["iss"] != "TEAM123456" || claims["iat"] != float64(1_000_000) {
		t.Fatalf("JWT claims = %v", claims)
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("解签名: %v", err)
	}
	if len(signature) != 64 {
		t.Fatalf("ES256 签名长度 = %d", len(signature))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(signature[:32])
	s := new(big.Int).SetBytes(signature[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("ES256 签名验不过")
	}
}

func TestAStaleTokenIsReSigned(t *testing.T) {
	keyPath, _ := generatedKeyPath(t)
	client := &stubClient{}
	current := time.Unix(1_000_000, 0)
	sender := &Sender{
		keyPath: keyPath, keyID: "K", teamID: "T", topic: "com.x",
		defaultEnv: "sandbox", enabled: true, client: client,
		now: func() time.Time { return current }, lastSent: map[string]time.Time{},
	}
	sender.Send(context.Background(), Request{
		DeviceID: "d1", Token: "aa", Kind: "turnEnd", SID: "s1",
	})
	current = current.Add(JWTTTL + time.Second)
	sender.Send(context.Background(), Request{
		DeviceID: "d2", Token: "bb", Kind: "turnEnd", SID: "s2",
	})
	requests := client.calls()
	if requests[0].headers.Get("authorization") == requests[1].headers.Get("authorization") {
		t.Fatal("过期后应该重签")
	}
}

// ── 拒绝 ───────────────────────────────────────────────────────────────────

func Test410AsksTheCallerToClearTheToken(t *testing.T) {
	client := &stubClient{steps: []stubStep{{
		status: http.StatusGone, body: `{"reason":"Unregistered"}`,
	}}}
	sender := testSender(t, client)
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s",
	})
	if result.OK || !result.DeadToken || statusOf(result) != 410 {
		t.Fatalf("结果 = %+v", result)
	}
	if deref(result.Reason) != "Unregistered" {
		t.Fatalf("reason = %q", deref(result.Reason))
	}
}

func TestBadDeviceTokenAsksTheCallerToClearTheToken(t *testing.T) {
	client := &stubClient{steps: []stubStep{{
		status: http.StatusBadRequest, body: `{"reason":"BadDeviceToken"}`,
	}}}
	sender := testSender(t, client)
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Env: stringPtrForTest("production"),
		Kind: "turnEnd", SID: "s",
	})
	if !result.DeadToken || deref(result.Reason) != "BadDeviceToken" {
		t.Fatalf("结果 = %+v", result)
	}
}

func TestA403ReSignsExactlyOnce(t *testing.T) {
	keyPath, _ := generatedKeyPath(t)
	client := &stubClient{steps: []stubStep{
		{status: http.StatusForbidden, body: `{"reason":"ExpiredProviderToken"}`},
		{status: http.StatusOK},
	}}
	current := time.Unix(1_000_000, 0)
	// 每次读时钟前进 1 秒：重签出来的 iat 不同，能证明确实重签过。
	sender := &Sender{
		keyPath: keyPath, keyID: "K", teamID: "T", topic: "com.x",
		defaultEnv: "sandbox", enabled: true, client: client,
		now: func() time.Time {
			current = current.Add(time.Second)
			return current
		},
		lastSent: map[string]time.Time{},
	}
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s",
	})
	if !result.OK {
		t.Fatalf("重签之后应当成功：%+v", result)
	}
	requests := client.calls()
	if len(requests) != 2 {
		t.Fatalf("403 应该重试一次，实际请求 %d 次", len(requests))
	}
	if requests[0].headers.Get("authorization") == requests[1].headers.Get("authorization") {
		t.Fatal("第二次请求必须用重签的令牌")
	}
}

func TestASecond403GivesUpWithoutLooping(t *testing.T) {
	client := &stubClient{steps: []stubStep{
		{status: http.StatusForbidden, body: `{"reason":"InvalidProviderToken"}`},
		{status: http.StatusForbidden, body: `{"reason":"InvalidProviderToken"}`},
	}}
	sender := testSender(t, client)
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s",
	})
	if result.OK || deref(result.Reason) != "InvalidProviderToken" {
		t.Fatalf("结果 = %+v", result)
	}
	if len(client.calls()) != 2 {
		t.Fatalf("重签一次之后仍失败就必须停，实际 %d 次", len(client.calls()))
	}
}

func TestATransportFailureIsReportedNotRaised(t *testing.T) {
	client := &stubClient{steps: []stubStep{{err: errors.New("connection reset")}}}
	sender := testSender(t, client)
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s",
	})
	if result.OK || !strings.Contains(deref(result.Reason), "transport") {
		t.Fatalf("结果 = %+v", result)
	}
}

func TestANonJSONErrorBodyStillYieldsAReason(t *testing.T) {
	client := &stubClient{steps: []stubStep{{
		status: http.StatusInternalServerError, body: "<html>nope</html>",
	}}}
	sender := testSender(t, client)
	result := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s",
	})
	if statusOf(result) != 500 || !strings.Contains(deref(result.Reason), "nope") {
		t.Fatalf("结果 = %+v", result)
	}
}

// ── 限速 ───────────────────────────────────────────────────────────────────

func TestASecondPushToTheSameDeviceWithinTheWindowIsSkipped(t *testing.T) {
	client := &stubClient{}
	current := time.Unix(1_000_000, 0)
	sender := testSender(t, client)
	sender.SetNow(func() time.Time { return current })
	first := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s1",
	})
	second := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s2",
	})
	if !first.OK || deref(second.Skipped) != "throttled" {
		t.Fatalf("结果 = %+v / %+v", first, second)
	}
	if len(client.calls()) != 1 {
		t.Fatalf("请求数 = %d", len(client.calls()))
	}
	other := sender.Send(context.Background(), Request{
		DeviceID: "dev_2", Token: "bb", Kind: "turnEnd", SID: "s3",
	})
	if !other.OK || len(client.calls()) != 2 {
		t.Fatalf("另一台设备不该受影响：%+v", other)
	}
	current = current.Add(61 * time.Second)
	third := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s4",
	})
	if !third.OK || len(client.calls()) != 3 {
		t.Fatalf("过了窗口应当恢复：%+v", third)
	}
}

func TestPushTestCanBypassTheThrottle(t *testing.T) {
	client := &stubClient{}
	sender := testSender(t, client)
	for index := 0; index < 3; index++ {
		sender.Send(context.Background(), Request{
			DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s",
			IgnoreThrottle: true,
		})
	}
	if len(client.calls()) != 3 {
		t.Fatalf("请求数 = %d", len(client.calls()))
	}
}

func TestAFailedPushDoesNotConsumeTheThrottleWindow(t *testing.T) {
	client := &stubClient{steps: []stubStep{{
		status: http.StatusInternalServerError, body: `{"reason":"InternalServerError"}`,
	}}}
	sender := testSender(t, client)
	sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s",
	})
	again := sender.Send(context.Background(), Request{
		DeviceID: "dev_1", Token: "aa", Kind: "turnEnd", SID: "s",
	})
	if !again.OK || len(client.calls()) != 2 {
		t.Fatalf("被拒的推送不该占掉窗口：%+v，请求数 %d", again, len(client.calls()))
	}
}

// ── 扇出 ───────────────────────────────────────────────────────────────────

func TestSendManyDeliversToEveryDeviceAndSurvivesABadRow(t *testing.T) {
	client := &stubClient{}
	sender := testSender(t, client)
	sender.minGap = 0
	targets := []Target{
		{DeviceID: "dev_1", Token: "aa", Env: stringPtrForTest("sandbox")},
		{DeviceID: "dev_2", Token: "bb", Env: stringPtrForTest("production")},
		{DeviceID: "dev_3", Token: "", Env: stringPtrForTest("sandbox")},
	}
	results := sender.SendMany(context.Background(), targets, "attention", "s-1",
		stringPtrForTest("e-1"), false)
	if len(results) != 3 {
		t.Fatalf("结果数 = %d", len(results))
	}
	if results[0].Skipped != nil || results[1].Skipped != nil ||
		deref(results[2].Skipped) != "no-token" {
		t.Fatalf("结果 = %+v", results)
	}
	requests := client.calls()
	if len(requests) != 2 {
		t.Fatalf("请求数 = %d", len(requests))
	}
	if payloadOf(t, requests[1])["eid"] != "e-1" {
		t.Fatalf("payload 少了 eid：%v", payloadOf(t, requests[1]))
	}
}

func TestAnUnreadableKeyIsReportedAsASigningFailure(t *testing.T) {
	client := &stubClient{}
	sender := &Sender{
		keyPath: filepath.Join(t.TempDir(), "nope.p8"), keyID: "K", teamID: "T",
		topic: "com.x", defaultEnv: "sandbox", enabled: true, client: client,
		now: time.Now, lastSent: map[string]time.Time{},
	}
	result := sender.Send(context.Background(), Request{
		DeviceID: "d", Token: "aa", Kind: "turnEnd", SID: "s",
	})
	if result.OK || !strings.Contains(deref(result.Reason), "signing") {
		t.Fatalf("结果 = %+v", result)
	}
	if len(client.calls()) != 0 {
		t.Fatal("签不出令牌就不该发请求")
	}
}

// ── 小工具 ─────────────────────────────────────────────────────────────────

func stringPtrForTest(value string) *string { return &value }

// compareJSON 比较两个 JSON 值，返回首个差异（空串 = 相等）。
func compareJSON(t *testing.T, got, want any) string {
	t.Helper()
	left, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("编码 got: %v", err)
	}
	right, err := json.Marshal(want)
	if err != nil {
		t.Fatalf("编码 want: %v", err)
	}
	if string(left) != string(right) {
		return fmt.Sprintf("got=%s want=%s", left, right)
	}
	return ""
}

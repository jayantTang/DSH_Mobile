package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// internalFixture 是 /internal/* 用例的隔离装置：真 store + 真 hub + 真路由。
type internalFixture struct {
	t       *testing.T
	store   *store.Store
	hub     *hub.Hub
	handler http.Handler
	device  store.Device
	token   string
}

func newInternalFixture(t *testing.T) *internalFixture {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	live := hub.New(hub.Options{
		Store: st, Limits: hub.DefaultLimits(), Logger: logger,
		RevokeReconcileInterval: -1,
	})
	ctx := context.Background()
	account, err := st.CreateAccount(ctx, "internal")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	agent, _, err := st.RegisterAgent(ctx, account.AccountID, "internal", nil)
	if err != nil {
		t.Fatalf("RegisterAgent: %v", err)
	}
	minted, err := st.MintPairCode(ctx, agent.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	claim, err := st.ClaimPairCode(ctx, minted.Code, store.ClaimParams{
		DeviceName: "internal-phone", TTLMS: store.DefaultDeviceTTLMS, MaxPairedDevices: 8,
	})
	if err != nil {
		t.Fatalf("ClaimPairCode: %v", err)
	}
	device, found, err := st.DeviceByID(ctx, claim.DeviceID)
	if err != nil || !found {
		t.Fatalf("DeviceByID: found=%v err=%v", found, err)
	}
	return &internalFixture{
		t: t, store: st, hub: live,
		handler: New(Options{Store: st, Hub: live, MaxPairedDevices: 8}),
		device:  device, token: claim.DeviceToken,
	}
}

// post 发一次 JSON 请求；remoteAddr 缺省是回环。
func (f *internalFixture) post(path string, body []byte, remoteAddr string) *httptest.ResponseRecorder {
	f.t.Helper()
	request := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	request.RemoteAddr = remoteAddr
	if remoteAddr == "" {
		request.RemoteAddr = "127.0.0.1:51000"
	}
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	f.handler.ServeHTTP(recorder, request)
	return recorder
}

func (f *internalFixture) postJSON(path string, body any) *httptest.ResponseRecorder {
	f.t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		f.t.Fatalf("序列化请求体: %v", err)
	}
	return f.post(path, raw, "")
}

// deviceSink 是专收 accountState 的设备桩。
type deviceSink struct {
	mu     sync.Mutex
	frames []dlp.Frame
	notify chan struct{}
}

func newDeviceSink() *deviceSink {
	return &deviceSink{notify: make(chan struct{}, 16)}
}

func (s *deviceSink) Write(_ context.Context, payload []byte) error {
	frame, _, err := dlp.Parse(payload)
	if err != nil {
		return nil
	}
	s.mu.Lock()
	s.frames = append(s.frames, frame)
	s.mu.Unlock()
	select {
	case s.notify <- struct{}{}:
	default:
	}
	return nil
}

func (s *deviceSink) Ping(context.Context) error { return nil }
func (s *deviceSink) Close(int, string) error    { return nil }

// nextFrame 等一条满足条件的帧；超时即失败。
func (s *deviceSink) nextFrame(t *testing.T, match func(dlp.Frame) bool) dlp.Frame {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		for _, frame := range s.frames {
			if match(frame) {
				s.mu.Unlock()
				return frame
			}
		}
		s.mu.Unlock()
		select {
		case <-s.notify:
		case <-time.After(10 * time.Millisecond):
		}
	}
	t.Fatal("没有等到期望的设备帧")
	return nil
}

func TestInternalTokenResolveReturnsTheOwnership(t *testing.T) {
	fx := newInternalFixture(t)
	recorder := fx.postJSON("/internal/tokens/resolve", map[string]any{"token": fx.token})
	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 = %d：%s", recorder.Code, recorder.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("响应不是 JSON：%v", err)
	}
	if body["deviceId"] != fx.device.DeviceID || body["accountId"] != fx.device.AccountID {
		t.Fatalf("响应 = %v", body)
	}
	expires, ok := body["expiresAt"].(float64)
	if !ok || expires <= 0 {
		t.Fatalf("expiresAt = %v", body["expiresAt"])
	}
	if len(body) != 3 {
		t.Fatalf("响应字段必须只有 deviceId/accountId/expiresAt：%v", body)
	}
}

func TestInternalTokenResolveTreatsRevokedAndUnknownAlike(t *testing.T) {
	fx := newInternalFixture(t)
	// 再造一台设备并撤销它。
	ctx := context.Background()
	minted, err := fx.store.MintPairCode(ctx, fx.device.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	doomed, err := fx.store.ClaimPairCode(ctx, minted.Code, store.ClaimParams{
		DeviceName: "doomed", TTLMS: store.DefaultDeviceTTLMS, MaxPairedDevices: 8,
	})
	if err != nil {
		t.Fatalf("ClaimPairCode: %v", err)
	}
	if err := fx.store.RevokeDevice(ctx, doomed.DeviceID); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}

	revoked := fx.postJSON("/internal/tokens/resolve",
		map[string]any{"token": doomed.DeviceToken})
	unknown := fx.postJSON("/internal/tokens/resolve",
		map[string]any{"token": "dt_never-issued"})
	assertEnvelope(t, revoked, http.StatusNotFound, "internal/not-found")
	assertEnvelope(t, unknown, http.StatusNotFound, "internal/not-found")
	if revoked.Body.String() != unknown.Body.String() {
		t.Fatalf("撤销与不存在必须逐字节相同：\n%s\n%s",
			revoked.Body.String(), unknown.Body.String())
	}
}

func TestInternalTokenResolveRejectsAMalformedBody(t *testing.T) {
	fx := newInternalFixture(t)
	for _, body := range []map[string]any{
		{}, {"token": ""}, {"token": 5}, {"token": nil},
	} {
		recorder := fx.postJSON("/internal/tokens/resolve", body)
		assertEnvelope(t, recorder, http.StatusBadRequest, "internal/bad-request")
	}
	// 非对象同样 400。
	notObject := fx.post("/internal/tokens/resolve", []byte(`["token"]`), "")
	assertEnvelope(t, notObject, http.StatusBadRequest, "internal/bad-request")

	// 纯空白不是"缺字段"：它被当成一个令牌去查，结果与未知令牌相同（404）。
	whitespace := fx.postJSON("/internal/tokens/resolve", map[string]any{"token": "  "})
	assertEnvelope(t, whitespace, http.StatusNotFound, "internal/not-found")
}

func TestInternalEndpointsAreLoopbackOnly(t *testing.T) {
	fx := newInternalFixture(t)
	for _, path := range []string{
		"/internal/tokens/resolve", "/internal/account-state/touch",
	} {
		body, _ := json.Marshal(map[string]any{
			"token": fx.token, "accountId": fx.device.AccountID,
		})
		recorder := fx.post(path, body, "10.1.2.3:4567")
		assertEnvelope(t, recorder, http.StatusNotFound, "not-found")
	}
}

func TestInternalAccountStateTouchNotifiesTheAccountsDevices(t *testing.T) {
	fx := newInternalFixture(t)
	sink := newDeviceSink()
	link, err := fx.hub.AttachDevice(context.Background(), fx.device, sink)
	if err != nil {
		t.Fatalf("AttachDevice: %v", err)
	}
	t.Cleanup(func() { fx.hub.DetachDevice(link) })
	sink.nextFrame(t, func(frame dlp.Frame) bool { return frame.Type() == "hostStatus" })

	recorder := fx.postJSON("/internal/account-state/touch", map[string]any{
		"accountId": fx.device.AccountID, "keys": []string{"feedback"},
	})
	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 = %d：%s", recorder.Code, recorder.Body.String())
	}
	if body := decodeJSON(t, recorder); body["ok"] != true || body["notified"] != float64(1) {
		t.Fatalf("响应 = %v", body)
	}
	frame := sink.nextFrame(t, func(frame dlp.Frame) bool {
		return frame.Type() == "accountState"
	})
	keys, ok := frame["keys"].([]any)
	if !ok || len(keys) != 1 || keys[0] != "feedback" {
		t.Fatalf("accountState = %v", frame)
	}

	// 缺 keys 时按 feedback 通知。
	again := fx.postJSON("/internal/account-state/touch", map[string]any{
		"accountId": fx.device.AccountID,
	})
	if body := decodeJSON(t, again); body["notified"] != float64(1) {
		t.Fatalf("缺 keys 时应当仍通知：%v", body)
	}
	frame = sink.nextFrame(t, func(frame dlp.Frame) bool {
		return frame.Type() == "accountState"
	})
	keys, _ = frame["keys"].([]any)
	if len(keys) != 1 || keys[0] != "feedback" {
		t.Fatalf("默认 keys = %v", frame["keys"])
	}
}

func TestInternalAccountStateTouchWithNoOnlineDeviceNotifiesNobody(t *testing.T) {
	fx := newInternalFixture(t)
	recorder := fx.postJSON("/internal/account-state/touch", map[string]any{
		"accountId": fx.device.AccountID, "keys": []string{"feedback"},
	})
	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 = %d", recorder.Code)
	}
	if body := decodeJSON(t, recorder); body["ok"] != true || body["notified"] != float64(0) {
		t.Fatalf("响应 = %v", body)
	}
	unknown := fx.postJSON("/internal/account-state/touch", map[string]any{
		"accountId": "acc_does-not-exist",
	})
	if body := decodeJSON(t, unknown); body["notified"] != float64(0) {
		t.Fatalf("未知账户 = %v", body)
	}
}

func TestInternalAccountStateTouchRejectsAMalformedBody(t *testing.T) {
	fx := newInternalFixture(t)
	assertEnvelope(t, fx.postJSON("/internal/account-state/touch", map[string]any{}),
		http.StatusBadRequest, "internal/bad-request")
	assertEnvelope(t, fx.postJSON("/internal/account-state/touch", map[string]any{"accountId": 5}),
		http.StatusBadRequest, "internal/bad-request")
}

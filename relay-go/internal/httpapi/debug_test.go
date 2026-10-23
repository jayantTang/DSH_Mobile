package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// debugSink 是 /debug/conns 用例里的假 socket（带对端地址）。
type debugSink struct{ addr string }

func (s debugSink) Write(context.Context, []byte) error { return nil }
func (s debugSink) Ping(context.Context) error          { return nil }
func (s debugSink) Close(int, string) error             { return nil }
func (s debugSink) RemoteAddr() string                  { return s.addr }

func TestDebugConnsIsLoopbackOnlyAndRedacted(t *testing.T) {
	logger, buffer := newLogBuffer()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	ctx := t.Context()
	account, err := st.CreateAccount(ctx, "debug account")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	agent, _, err := st.RegisterAgent(ctx, account.AccountID, "debug mac", nil)
	if err != nil {
		t.Fatalf("RegisterAgent: %v", err)
	}
	live := hub.New(hub.Options{Store: st, Logger: logger})
	ticket, refusal := live.AdmitAgent(ctx, agent)
	if refusal != nil {
		t.Fatalf("AdmitAgent: %v", refusal)
	}
	agentLink := live.AttachAgent(ctx, agent, debugSink{addr: "203.0.113.5:4444"}, ticket)
	agentLink.NoteError(errors.New("socket write boom"))
	device := store.Device{
		DeviceID: "dev_debug_1", AgentID: agent.AgentID,
		AccountID: account.AccountID, Name: "debug iPhone",
	}
	if _, err := live.AttachDevice(ctx, device, debugSink{addr: "198.51.100.8:5555"}); err != nil {
		t.Fatalf("AttachDevice: %v", err)
	}

	handler := New(Options{Store: st, Hub: live, Logger: logger, AccessLog: AccessLogErrors})

	// ① 非环回：404（不给探测者分辨端点是否存在），并留一条拒绝日志。
	request := httptest.NewRequest(http.MethodGet, "/debug/conns", nil)
	request.RemoteAddr = "198.51.100.9:1234"
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNotFound {
		t.Fatalf("非环回状态码 = %d：%s", recorder.Code, recorder.Body.String())
	}
	rejected := false
	for _, entry := range buffer.lines(t) {
		if strings.Contains(stringOf(entry["msg"]), "refused /debug/conns") {
			rejected = true
			if entry["peer"] != "198.51.100.9:1234" {
				t.Fatalf("拒绝日子的 peer = %v", entry["peer"])
			}
		}
	}
	if !rejected {
		t.Fatalf("非环回拒绝没有日志：%v", buffer.lines(t))
	}

	// ② 环回：返回快照，含 agentId/deviceId/remote/时间/队列/丢弃/版本/最后错误。
	request = httptest.NewRequest(http.MethodGet, "/debug/conns", nil)
	request.RemoteAddr = "127.0.0.1:51000"
	request.Header.Set(reqctx.Header, "trace-debug")
	recorder = httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("环回状态码 = %d：%s", recorder.Code, recorder.Body.String())
	}
	if recorder.Header().Get(reqctx.Header) != "trace-debug" {
		t.Fatalf("响应头 requestId = %q", recorder.Header().Get(reqctx.Header))
	}
	var body map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("响应不是 JSON: %v", err)
	}
	if body["ok"] != true {
		t.Fatalf("ok = %v", body["ok"])
	}
	agents, _ := body["agents"].([]any)
	devices, _ := body["devices"].([]any)
	if len(agents) != 1 || len(devices) != 1 {
		t.Fatalf("快照 = %v", body)
	}
	agentRow, _ := agents[0].(map[string]any)
	for _, key := range []string{"agentId", "remote", "connectedAt", "lastInbound",
		"queueDepth", "controlDrops", "connectorVersion", "lastError"} {
		if _, present := agentRow[key]; !present {
			t.Fatalf("agent 行缺 %q：%v", key, agentRow)
		}
	}
	if agentRow["agentId"] != agent.AgentID || agentRow["remote"] != "203.0.113.5:4444" ||
		agentRow["lastError"] != "socket write boom" {
		t.Fatalf("agent 行 = %v", agentRow)
	}
	deviceRow, _ := devices[0].(map[string]any)
	if deviceRow["deviceId"] != device.DeviceID || deviceRow["agentId"] != agent.AgentID ||
		deviceRow["remote"] != "198.51.100.8:5555" {
		t.Fatalf("device 行 = %v", deviceRow)
	}

	// ③ 脱敏：快照里没有任何令牌/Authorization/正文。
	raw := strings.ToLower(recorder.Body.String())
	for _, forbidden := range []string{"secret", "token", "authorization", "bearer"} {
		if strings.Contains(raw, forbidden) {
			t.Fatalf("快照里出现了 %q：%s", forbidden, recorder.Body.String())
		}
	}
}

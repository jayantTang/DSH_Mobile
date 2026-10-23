package wsapi_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/httpapi"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/monitor"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// newMonitoredRelay 与 newRelay 相同，但把监控接到 HTTP 处理器上，
// 用来验证"修好了一个落单代理项"这条告警真的从 WS 读循环走到了告警队列。
func newMonitoredRelay(t *testing.T) (*relayFixture, string) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("打开临时库: %v", err)
	}
	alertDir := filepath.Join(t.TempDir(), "alerts")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	monitorInstance := monitor.New(monitor.Options{AlertDir: alertDir, Logger: logger})
	limits := hub.DefaultLimits()
	live := hub.New(hub.Options{Store: st, Limits: limits, Logger: logger, Monitor: monitorInstance})
	server := httptestServer(t, httpapi.New(httpapi.Options{
		Store: st, Hub: live, Limits: limits, MaxPairedDevices: 8,
		Logger: logger, Monitor: monitorInstance,
	}))
	ctx := t.Context()
	account, err := st.CreateAccount(ctx, "WS-monitor")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	agent, secret, err := st.RegisterAgent(ctx, account.AccountID, "WS-monitor", nil)
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
	return fixture, alertDir
}

// 本文件只需要 httpapi/hub/store 三个包；httptestServer/context 的薄封装放在下面，
// 避免把主测试文件的导入表也拖进来。
func httptestServer(t *testing.T, handler http.Handler) *httptest.Server {
	t.Helper()
	return httptest.NewServer(handler)
}

func TestAnUnpairedSurrogateInAnUpstreamFrameIsQueuedAsAnAlert(t *testing.T) {
	fixture, alertDir := newMonitoredRelay(t)
	device := fixture.pairDevice("WS-surrogate")
	agentConn := fixture.dial(fixture.agentPath(), fixture.tenant.secret)
	defer agentConn.CloseNow()

	// 一条合法的 JSON 文本帧，正文里带**落单的高代理项转义**：Go 的 encoding/json
	// 会把它换成 U+FFFD，但原始字节里的 `\ud83d` 会被 ScanSurrogates 认出来。
	sendFrame(t, agentConn, `{"t":"item","id":"i1","deviceId":"`+device.DeviceID+
		`","value":{"text":"\ud83d"}}`)

	path := filepath.Join(alertDir, monitor.QueueName)
	deadline := time.Now().Add(3 * time.Second)
	var records []monitor.Record
	for time.Now().Before(deadline) {
		payload, err := os.ReadFile(path)
		if err == nil && len(payload) > 0 {
			for _, line := range strings.Split(strings.TrimSpace(string(payload)), "\n") {
				var record monitor.Record
				if err := json.Unmarshal([]byte(line), &record); err != nil {
					t.Fatalf("告警行不是 JSON: %v (%s)", err, line)
				}
				records = append(records, record)
			}
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(records) == 0 {
		t.Fatal("落单代理项没有进告警队列")
	}
	record := records[0]
	if record.Key != "surrogate:unpaired" || record.Kind != "corrupt-frame" {
		t.Fatalf("告警 = %+v", record)
	}
	if record.Details["agentId"] != fixture.tenant.agentID ||
		record.Details["deviceId"] != device.DeviceID ||
		record.Details["frameType"] != "item" {
		t.Fatalf("details = %v", record.Details)
	}
}

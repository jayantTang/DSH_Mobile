package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/presence"
)

// hubLogBuffer 收集 JSON 日志（并发安全：hub 会在后台 goroutine 里写）。
type hubLogBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *hubLogBuffer) Write(payload []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(payload)
}

func (b *hubLogBuffer) entries(t *testing.T) []map[string]any {
	t.Helper()
	b.mu.Lock()
	text := b.buf.String()
	b.mu.Unlock()
	entries := make([]map[string]any, 0, 8)
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("日志不是 JSON：%v (%s)", err, line)
		}
		entries = append(entries, entry)
	}
	return entries
}

func (b *hubLogBuffer) find(t *testing.T, message string) map[string]any {
	t.Helper()
	for _, entry := range b.entries(t) {
		if entry["msg"] == message {
			return entry
		}
	}
	t.Fatalf("没有日志 %q：%v", message, b.entries(t))
	return nil
}

func newHubLogFixture(t *testing.T, options Options) (*fixture, *hubLogBuffer) {
	t.Helper()
	buffer := &hubLogBuffer{}
	options.Logger = slog.New(slog.NewJSONHandler(buffer, &slog.HandlerOptions{
		Level: slog.LevelDebug,
	}))
	return newFixture(t, options), buffer
}

func TestAgentConnectionLifecycleLogsCarryRemoteDurationAndCloseCode(t *testing.T) {
	fixture, buffer := newHubLogFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("log-mac")
	sink := &remoteFakeSink{fakeSink: newFakeSink(), addr: "203.0.113.20:5555"}
	link := fixture.hub.AttachAgent(context.Background(), owner.agent, sink,
		fixture.admitAgent(owner))

	connected := buffer.find(t, "relay: agent connected")
	if connected["agentId"] != owner.agent.AgentID || connected["remote_ip"] != "203.0.113.20:5555" {
		t.Fatalf("connected = %v", connected)
	}
	for _, key := range []string{"connectorVersion", "hostVersion", "generation", "accountId"} {
		if _, present := connected[key]; !present {
			t.Fatalf("connected 缺 %q：%v", key, connected)
		}
	}

	fixture.hub.DetachAgent(link)
	select {
	case <-link.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("连接没有退出")
	}
	disconnected := buffer.find(t, "relay: agent disconnected")
	if disconnected["agentId"] != owner.agent.AgentID ||
		disconnected["remote_ip"] != "203.0.113.20:5555" {
		t.Fatalf("disconnected = %v", disconnected)
	}
	if disconnected["closeCode"] != float64(1001) || disconnected["reason"] == "" {
		t.Fatalf("closeCode/reason = %v/%v", disconnected["closeCode"], disconnected["reason"])
	}
	if _, present := disconnected["duration_ms"]; !present {
		t.Fatalf("disconnected 缺 duration_ms：%v", disconnected)
	}
	if _, present := disconnected["lastError"]; !present {
		t.Fatalf("disconnected 缺 lastError：%v", disconnected)
	}
}

func TestPresenceRefusalIsInfoWithWaitResult(t *testing.T) {
	fixture, buffer := newHubLogFixture(t, Options{
		Limits: DefaultLimits(),
		Presence: presence.Options{
			ActiveIdle: time.Hour, WaitForOld: 20 * time.Millisecond,
		},
	})
	owner := fixture.newTenant("refused-mac")
	first, _ := fixture.attachAgent(owner)
	first.NoteInbound()

	_, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if refusal == nil {
		t.Fatal("活跃旧连接存在时应当被拒绝")
	}

	entry := buffer.find(t, "relay: refused a duplicate agent connection")
	if entry["level"] != "INFO" {
		t.Fatalf("presence 拒绝级别 = %v（不能再是 DEBUG）", entry["level"])
	}
	if entry["reason"] != presence.ReasonDuplicate || entry["waitResult"] != "timeout" {
		t.Fatalf("原因/等待结果 = %v/%v", entry["reason"], entry["waitResult"])
	}
	if waited, _ := entry["waitedMs"].(float64); waited < 15 {
		t.Fatalf("waitedMs = %v，期望覆盖整个等待窗口", entry["waitedMs"])
	}
	if entry["unverified"] != false {
		t.Fatalf("unverified = %v", entry["unverified"])
	}
	if old, _ := entry["oldGeneration"].(float64); old < 1 {
		t.Fatalf("oldGeneration = %v", entry["oldGeneration"])
	}
	if entry["oldConnected"] != true {
		t.Fatalf("oldConnected = %v", entry["oldConnected"])
	}
	if streak, _ := entry["streak"].(float64); streak < 1 {
		t.Fatalf("streak = %v", entry["streak"])
	}
}

func TestUnverifiedRefusalIsWARN(t *testing.T) {
	fixture, buffer := newHubLogFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("unverified-mac")
	fixture.hub.noteAgentRefusal(owner.agent, &AgentRefusal{
		Reason: presence.ReasonUnverified, RetryAfter: 5 * time.Second,
		WaitResult: "not-waited", Unverified: true, Streak: 3,
	})
	entry := buffer.find(t, "relay: refused a reconnect from an agent that never reported "+
		"its versions; backing off")
	if entry["level"] != "WARN" || entry["unverified"] != true {
		t.Fatalf("未验证拒绝 = %v", entry)
	}
	if entry["retryAfterMs"] != float64(5000) {
		t.Fatalf("retryAfterMs = %v", entry["retryAfterMs"])
	}
}

func TestSupersedeLogsBothGenerationsAndLifetime(t *testing.T) {
	fixture, buffer := newHubLogFixture(t, Options{
		Limits:   DefaultLimits(),
		Presence: presence.Options{ActiveIdle: time.Millisecond},
	})
	owner := fixture.newTenant("supersede-mac")
	first, _ := fixture.attachAgent(owner)
	time.Sleep(5 * time.Millisecond)

	ticket, refusal := fixture.hub.AdmitAgent(context.Background(), owner.agent)
	if refusal != nil {
		t.Fatalf("僵死旧连接应当允许顶替：%v", refusal)
	}
	second := fixture.hub.AttachAgent(context.Background(), owner.agent, newFakeSink(), ticket)
	t.Cleanup(func() { fixture.hub.DetachAgent(second) })
	select {
	case <-first.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("旧连接没有退出")
	}

	entry := buffer.find(t, "relay: agent superseded by a new connection")
	old, _ := entry["oldGeneration"].(float64)
	newer, _ := entry["newGeneration"].(float64)
	if old < 1 || newer <= old {
		t.Fatalf("old/new generation = %v/%v", entry["oldGeneration"], entry["newGeneration"])
	}
	if _, present := entry["oldDurationMs"]; !present {
		t.Fatalf("superseded 缺 oldDurationMs：%v", entry)
	}
}

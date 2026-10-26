package hub

import (
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/quota"
)

// TestClassifyDeviceOperation 钉住协议映射：只认 prompt 与 eventResult 两条稳定键；
// 其他方法即使带同名参数也不计数。
func TestClassifyDeviceOperation(t *testing.T) {
	tests := []struct {
		name     string
		frame    string
		op       quota.Op
		relevant bool
		keyed    bool
	}{
		{
			name:     "prompt",
			frame:    `{"t":"req","id":"u1","method":"session/prompt","args":{"request":{"requestId":"req-1"}}}`,
			op:       quota.OpPrompt,
			relevant: true,
			keyed:    true,
		},
		{
			name:     "prompt missing requestId",
			frame:    `{"t":"req","id":"u1","method":"session/prompt","args":{"request":{}}}`,
			op:       quota.OpPrompt,
			relevant: true,
		},
		{
			name:     "answer",
			frame:    `{"t":"eventResult","id":"u2","result":{"clientId":"c","eventId":"evt-1"}}`,
			op:       quota.OpAnswer,
			relevant: true,
			keyed:    true,
		},
		{
			name:     "answer missing eventId",
			frame:    `{"t":"eventResult","id":"u2","result":{}}`,
			op:       quota.OpAnswer,
			relevant: true,
		},
		{
			name:  "session list",
			frame: `{"t":"req","id":"u3","method":"session/list","args":{"_request":{}}}`,
		},
		{
			name:  "hello",
			frame: `{"t":"req","id":"u4","method":"_link/hello","args":{}}`,
		},
		{
			name:  "ping",
			frame: `{"t":"ping","ts":1}`,
		},
		{
			name:  "agent response",
			frame: `{"t":"res","id":"u1","ok":true}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := classifyDeviceOperation(scanWire(t, test.frame))
			if got.op != test.op || got.relevant != test.relevant || got.keyed != test.keyed {
				t.Fatalf("classification = %+v，期望 op=%v relevant=%v keyed=%v",
					got, test.op, test.relevant, test.keyed)
			}
		})
	}
}

// TestFingerprintIsStableAndDiscriminating：同一幂等键稳定，不同键不同。
func TestFingerprintIsStableAndDiscriminating(t *testing.T) {
	first := fingerprint([]byte("6F1D0C7A-2E4B-4D6A-9C1E-8A2B7C3D4E5F"))
	if again := fingerprint([]byte("6F1D0C7A-2E4B-4D6A-9C1E-8A2B7C3D4E5F")); again != first {
		t.Fatalf("同一键指纹不稳定：%d / %d", first, again)
	}
	if other := fingerprint([]byte("00000000-0000-0000-0000-000000000000")); other == first {
		t.Fatal("不同键不应得到同一指纹")
	}
}

// promptFrame 是一条最小合法 prompt 请求。
func promptFrame(requestID string) string {
	return `{"t":"req","id":"u1","method":"session/prompt","args":{"request":{"requestId":"` +
		requestID + `","sessionId":"s1"}}}`
}

// TestPromptRetryCountsOnce 覆盖单连接重发：不同 frame id、同一 requestId 只计一次。
func TestPromptRetryCountsOnce(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("ops-mac")
	device := fixture.pairDevice(owner, "ops-phone")
	_, agentSink := fixture.attachAgent(owner)
	link, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	fixture.hub.RouteFromDevice(link, scanWire(t, promptFrame("req-1")))
	waitFrame(t, agentSink, "第一次 prompt", isKind("req"))
	fixture.hub.RouteFromDevice(link, scanWire(t, promptFrame("req-1")))
	waitFrame(t, agentSink, "重发的 prompt", isKind("req"))

	entries := fixture.hub.usage.Snapshot()
	if len(entries) != 1 || entries[0].Prompts != 1 || entries[0].Answers != 0 {
		t.Fatalf("重发后的计数 = %+v，期望 prompts=1", entries)
	}
	if stats := fixture.hub.OperationStats(); stats.Deduped != 1 || stats.Uncounted != 0 {
		t.Fatalf("opStats = %+v，期望 deduped=1 uncounted=0", stats)
	}
}

// TestAnswerRetryCountsOnce 覆盖作答重发：同一 eventId 只计一次。
func TestAnswerRetryCountsOnce(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("ops-mac")
	device := fixture.pairDevice(owner, "ops-phone")
	_, agentSink := fixture.attachAgent(owner)
	link, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	frame := `{"t":"eventResult","id":"u2","result":{"clientId":"c1","eventId":"evt-1","outcome":{"kind":"result"}}}`
	fixture.hub.RouteFromDevice(link, scanWire(t, frame))
	waitFrame(t, agentSink, "第一次作答", isKind("eventResult"))
	fixture.hub.RouteFromDevice(link, scanWire(t, frame))
	waitFrame(t, agentSink, "重发作答", isKind("eventResult"))

	entries := fixture.hub.usage.Snapshot()
	if len(entries) != 1 || entries[0].Answers != 1 || entries[0].Prompts != 0 {
		t.Fatalf("作答重发后的计数 = %+v，期望 answers=1", entries)
	}
}

// TestPromptWhileHostOfflineIsNotCounted：没有电脑侧时帧不会入队，用户操作不计；
// 上线后同 requestId 重发只计一次。
func TestPromptWhileHostOfflineIsNotCounted(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("ops-mac")
	device := fixture.pairDevice(owner, "ops-phone")
	link, _ := fixture.mustAttachDevice(device)

	fixture.hub.RouteFromDevice(link, scanWire(t, promptFrame("req-late")))
	for _, entry := range fixture.hub.usage.Snapshot() {
		if entry.Prompts != 0 || entry.Answers != 0 {
			t.Fatalf("电脑离线时不该有操作计数：%+v", entry)
		}
	}

	_, agentSink := fixture.attachAgent(owner)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	fixture.hub.RouteFromDevice(link, scanWire(t, promptFrame("req-late")))
	waitFrame(t, agentSink, "上线后的 prompt", isKind("req"))

	entries := fixture.hub.usage.Snapshot()
	if len(entries) != 1 || entries[0].Prompts != 1 {
		t.Fatalf("上线后的计数 = %+v，期望 prompts=1", entries)
	}
}

// TestPromptWithoutKeyIsUncounted：缺 requestId 时不猜键、不写计数，只记卫生指标。
func TestPromptWithoutKeyIsUncounted(t *testing.T) {
	fixture := newFixture(t, Options{Limits: DefaultLimits()})
	owner := fixture.newTenant("ops-mac")
	device := fixture.pairDevice(owner, "ops-phone")
	_, agentSink := fixture.attachAgent(owner)
	link, deviceSink := fixture.mustAttachDevice(device)
	waitFrame(t, agentSink, "deviceAttach", isKind("deviceAttach"))
	waitFrame(t, deviceSink, "hostStatus", isKind("hostStatus"))

	fixture.hub.RouteFromDevice(link, scanWire(t,
		`{"t":"req","id":"u1","method":"session/prompt","args":{"request":{}}}`))
	waitFrame(t, agentSink, "无键 prompt", isKind("req"))

	if entries := fixture.hub.usage.Snapshot(); len(entries) != 1 || entries[0].Prompts != 0 {
		t.Fatalf("无键 prompt 不该计数：%+v", entries)
	}
	if stats := fixture.hub.OperationStats(); stats.Uncounted != 1 {
		t.Fatalf("opStats = %+v，期望 uncounted=1", stats)
	}
}

// BenchmarkClassifyPrompt 记录热路径成本：4 KiB 正文、字段顺序为当前的
// t / id / method / args，分类只扫到 requestId。
func BenchmarkClassifyPrompt(b *testing.B) {
	raw := []byte(`{"t":"req","id":"u1","method":"session/prompt","args":{"request":{"requestId":"6F1D0C7A-2E4B-4D6A-9C1E-8A2B7C3D4E5F","content":[{"text":"` +
		strings.Repeat("x", 4096) + `"}]}}}`)
	wire, _, err := dlp.Scan(raw)
	if err != nil {
		b.Fatalf("Scan: %v", err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for index := 0; index < b.N; index++ {
		operation := classifyDeviceOperation(wire)
		if !operation.keyed || operation.op != quota.OpPrompt {
			b.Fatal("分类失败")
		}
	}
}

// BenchmarkNoteOpOnceDuplicate 记录重发风暴主路径：同一指纹反复命中。
func BenchmarkNoteOpOnceDuplicate(b *testing.B) {
	usage := quota.NewUsage(nil, func() int64 { return 20261026 }, discardLogger())
	ref := quota.DeviceRef{DeviceID: "dev_bench", AgentID: "agt_1", AccountID: "acc_1"}
	usage.NoteOpOnce(ref, quota.OpPrompt, 12345)
	b.ReportAllocs()
	b.ResetTimer()
	for index := 0; index < b.N; index++ {
		usage.NoteOpOnce(ref, quota.OpPrompt, 12345)
	}
}

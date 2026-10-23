package hub

import (
	"context"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// deliverFrame 把一条连接器帧经**生产路由**交给桥（不是直接调用 deliver），
// 这样用例同时覆盖 RouteFromAgent 的控制帧分流。
func deliverFrame(t *testing.T, h *Hub, agent *AgentLink, frame dlp.Frame) {
	t.Helper()
	wire := wireOf(t, frame)
	h.RouteFromAgent(agent, wire)
}

func TestPutBridgeAckThenDone(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-put")
	agent, _ := fx.attachAgent(owner)
	// 连接器还没有设备在线也能传文件：桥只认 agent。
	bridge := fx.hub.OpenPutBridge("bid-up", agent)
	defer fx.hub.CloseBridge("bid-up")

	if bridge.WaitAck(context.Background(), 20*time.Millisecond) {
		t.Fatal("没有 ack 不该通过")
	}
	deliverFrame(t, fx.hub, agent, dlp.Frame{
		"t": "fsPutAck", "bid": "bid-up", "received": 0,
	})
	if !bridge.WaitAck(context.Background(), time.Second) {
		t.Fatal("fsPutAck 之后应当通过")
	}

	deliverFrame(t, fx.hub, agent, dlp.Frame{
		"t": "fsPutDone", "bid": "bid-up", "path": "/tmp/p", "bytes": 5,
	})
	outcome, ok := bridge.WaitDone(context.Background())
	if !ok {
		t.Fatal("fsPutDone 之后应当有终局")
	}
	if outcome.Failed() {
		t.Fatalf("不该失败：%+v", outcome)
	}
	if outcome.Path == nil || *outcome.Path != "/tmp/p" {
		t.Fatalf("path = %v", outcome.Path)
	}
	if outcome.Bytes == nil || *outcome.Bytes != 5 {
		t.Fatalf("bytes = %v", outcome.Bytes)
	}
}

func TestPutBridgeFsErrIsAnAnswerNotATimeout(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-refuse")
	agent, _ := fx.attachAgent(owner)
	bridge := fx.hub.OpenPutBridge("bid-refused", agent)
	defer fx.hub.CloseBridge("bid-refused")

	deliverFrame(t, fx.hub, agent, dlp.Frame{
		"t": "fsErr", "bid": "bid-refused",
		"code": "workspace-file/too-large", "message": "no room",
	})
	// 在 begin 就拒绝的连接器不会发 ack；失败必须同时放行 ack 等待，否则调用方
	// 会白等满 5 秒，把"连接器说不行"报成"连接器太旧"。
	if !bridge.WaitAck(context.Background(), time.Second) {
		t.Fatal("fsErr 应当放行 ack 等待")
	}
	outcome, ok := bridge.WaitDone(context.Background())
	if !ok || !outcome.Failed() {
		t.Fatalf("终局 = %+v ok=%v", outcome, ok)
	}
	if outcome.ErrCode != "workspace-file/too-large" || outcome.ErrMessage != "no room" {
		t.Fatalf("连接器的错误没有被原样带回：%+v", outcome)
	}
}

func TestPutBridgeAckDeadline(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-deadline")
	agent, _ := fx.attachAgent(owner)
	bridge := fx.hub.OpenPutBridge("bid-old", agent)
	defer fx.hub.CloseBridge("bid-old")

	start := time.Now()
	if bridge.WaitAck(context.Background(), 30*time.Millisecond) {
		t.Fatal("旧连接器不该通过 ack 等待")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("ack 期限没有生效：等了 %s", elapsed)
	}
	// 迟到的 ack 仍然有效（期限只决定调用方等多久，不关闭桥）。
	deliverFrame(t, fx.hub, agent, dlp.Frame{"t": "fsPutAck", "bid": "bid-old"})
	if !bridge.WaitAck(context.Background(), time.Second) {
		t.Fatal("迟到的 ack 应当被接受")
	}
}

func TestPutBridgeFailsWhenTheAgentDisconnects(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-drop")
	agent, _ := fx.attachAgent(owner)
	bridge := fx.hub.OpenPutBridge("bid-drop", agent)
	defer fx.hub.CloseBridge("bid-drop")

	fx.hub.DetachAgent(agent)
	if !bridge.WaitAck(context.Background(), time.Second) {
		t.Fatal("agent 断线应当放行 ack 等待")
	}
	outcome, ok := bridge.WaitDone(context.Background())
	if !ok || outcome.ErrCode != "host/offline" {
		t.Fatalf("终局 = %+v ok=%v", outcome, ok)
	}
}

func TestSupersededAgentOnlyFailsItsOwnBridges(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-supersede")
	first, _ := fx.attachAgent(owner)
	firstBridge := fx.hub.OpenPutBridge("bid-first", first)
	defer fx.hub.CloseBridge("bid-first")

	second, _ := fx.attachAgent(owner) // 顶掉第一条连接
	secondBridge := fx.hub.OpenPutBridge("bid-second", second)
	defer fx.hub.CloseBridge("bid-second")

	fx.hub.DetachAgent(first) // 旧连接的读循环收尾
	outcome, ok := firstBridge.WaitDone(context.Background())
	if !ok || outcome.ErrCode != "host/offline" {
		t.Fatalf("旧连接上的桥没有被收尾：%+v ok=%v", outcome, ok)
	}
	if _, settled := secondBridge.TryOutcome(); settled {
		t.Fatal("新连接上的桥不能被旧连接的拆除误伤")
	}

	fx.hub.DetachAgent(second)
	if outcome, ok := secondBridge.WaitDone(context.Background()); !ok || !outcome.Failed() {
		t.Fatalf("新连接上的桥最终也应当收尾：%+v ok=%v", outcome, ok)
	}
}

func TestFetchBridgeMetadataChunksAndEnd(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-fetch")
	agent, _ := fx.attachAgent(owner)
	bridge := fx.hub.OpenFetchBridge("bid-down", agent)
	defer fx.hub.CloseBridge("bid-down")

	deliverFrame(t, fx.hub, agent, dlp.Frame{
		"t": "fsGetAck", "bid": "bid-down", "size": 4096, "version": "v1",
	})
	if !bridge.WaitAck(context.Background(), time.Second) {
		t.Fatal("fsGetAck 之后应当通过")
	}
	if size, ok := bridge.Size(); !ok || size != 4096 {
		t.Fatalf("size = %d ok=%v", size, ok)
	}
	if version := bridge.Version(); version != "v1" {
		t.Fatalf("version = %q", version)
	}

	deliverFrame(t, fx.hub, agent, dlp.Frame{
		"t": "fsGetChunk", "bid": "bid-down", "data": "YWJj", "eof": false,
	})
	frame, ok := bridge.NextFrame(context.Background())
	if !ok || frame.Type() != "fsGetChunk" || frame["data"] != "YWJj" {
		t.Fatalf("第一片 = %v ok=%v", frame, ok)
	}

	deliverFrame(t, fx.hub, agent, dlp.Frame{"t": "fsGetEnd", "bid": "bid-down"})
	frame, ok = bridge.NextFrame(context.Background())
	if !ok || frame["_terminal"] != true {
		t.Fatalf("终局帧 = %v ok=%v", frame, ok)
	}

	// 请求结束后登记被摘掉：迟到的窗口找不到桥，只能被丢掉（与 Python 的
	// `test_a_window_for_a_finished_bridge_is_refused` 同一口径）。
	fx.hub.CloseBridge("bid-down")
	if bridge := fx.hub.bridgeFor("bid-down"); bridge != nil {
		t.Fatalf("登记没有被摘掉：%+v", bridge)
	}
}

func TestFetchBridgeQueueFullMeansTheReaderIsGone(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-queue")
	agent, _ := fx.attachAgent(owner)
	bridge := fx.hub.OpenFetchBridge("bid-queue", agent)
	defer fx.hub.CloseBridge("bid-queue")

	for index := 0; index < FetchQueueDepth; index++ {
		if !bridge.deliver("fsGetChunk", dlp.Frame{
			"t": "fsGetChunk", "bid": "bid-queue",
			"data": "YQ==", "eof": false,
		}) {
			t.Fatalf("第 %d 片不该被拒", index)
		}
	}
	if bridge.deliver("fsGetChunk", dlp.Frame{
		"t": "fsGetChunk", "bid": "bid-queue", "data": "YQ==",
	}) {
		t.Fatal("队列满了应当报告读者已走")
	}
	if _, ok := bridge.NextFrame(context.Background()); ok {
		t.Fatal("放弃之后不该再取到窗口")
	}
}

func TestFetchBridgeFsErrIsTerminalWithTheConnectorsCode(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-fetch-err")
	agent, _ := fx.attachAgent(owner)
	bridge := fx.hub.OpenFetchBridge("bid-missing", agent)
	defer fx.hub.CloseBridge("bid-missing")

	deliverFrame(t, fx.hub, agent, dlp.Frame{
		"t": "fsErr", "bid": "bid-missing",
		"code": "workspace-file/not-found", "message": "no such file",
	})
	frame, ok := bridge.NextFrame(context.Background())
	if !ok {
		t.Fatal("应当拿到终局帧")
	}
	if frame["error"] != "workspace-file/not-found" || frame["message"] != "no such file" {
		t.Fatalf("终局帧 = %v", frame)
	}
}

func TestFetchBridgeFailsWhenTheAgentDisconnects(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-fetch-drop")
	agent, _ := fx.attachAgent(owner)
	bridge := fx.hub.OpenFetchBridge("bid-gone", agent)
	defer fx.hub.CloseBridge("bid-gone")

	fx.hub.DetachAgent(agent)
	frame, ok := bridge.NextFrame(context.Background())
	if !ok || frame["error"] != "host/offline" {
		t.Fatalf("终局帧 = %v ok=%v", frame, ok)
	}
}

func TestCancelFetchIsSentOnce(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-cancel")
	agent, sink := fx.attachAgent(owner)
	bridge := fx.hub.OpenFetchBridge("bid-cancel", agent)
	defer fx.hub.CloseBridge("bid-cancel")

	fx.hub.CancelFetch(agent, bridge)
	fx.hub.CancelFetch(agent, bridge)
	waitFor(t, "fsGetCancel 到达连接器", func() bool {
		return countFrames(sink, func(frame dlp.Frame) bool {
			return frame.Type() == "fsGetCancel" && frame["bid"] == "bid-cancel"
		}) == 1
	})
	if count := countFrames(sink, func(frame dlp.Frame) bool {
		return frame.Type() == "fsGetCancel"
	}); count != 1 {
		t.Fatalf("fsGetCancel 发了 %d 次，期望 1 次", count)
	}
}

func TestRouteBridgeFrameOnlyReachesTheMatchingBid(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-route")
	agent, _ := fx.attachAgent(owner)
	bridge := fx.hub.OpenPutBridge("bid-mine", agent)
	defer fx.hub.CloseBridge("bid-mine")

	deliverFrame(t, fx.hub, agent, dlp.Frame{
		"t": "fsPutDone", "bid": "bid-someone-else", "path": "/nope", "bytes": 1,
	})
	if _, settled := bridge.TryOutcome(); settled {
		t.Fatal("别的 bid 的终局不该落到这条桥上")
	}
	deliverFrame(t, fx.hub, agent, dlp.Frame{
		"t": "fsPutDone", "bid": "bid-mine", "path": "/ok", "bytes": 1,
	})
	if _, settled := bridge.TryOutcome(); !settled {
		t.Fatal("自己的 bid 应当被认领")
	}
}

func TestCloseBridgeRemovesTheRegistration(t *testing.T) {
	fx := newFixture(t, Options{})
	owner := fx.newTenant("bridge-close")
	agent, _ := fx.attachAgent(owner)
	fx.hub.OpenPutBridge("bid-close", agent)
	fx.hub.CloseBridge("bid-close")
	if bridge := fx.hub.bridgeFor("bid-close"); bridge != nil {
		t.Fatalf("登记没有被摘掉：%+v", bridge)
	}
}

// countFrames 统计满足条件的已写帧（不经过 t.Helper，可在轮询条件里调用）。
func countFrames(sink *fakeSink, match func(dlp.Frame) bool) int {
	sink.mu.Lock()
	defer sink.mu.Unlock()
	count := 0
	for _, payload := range sink.writes {
		frame, _, err := dlp.Parse(payload)
		if err != nil {
			continue
		}
		if match(frame) {
			count++
		}
	}
	return count
}

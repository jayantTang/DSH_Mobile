package bridge

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// 这里的用例直接驱动状态机（不经过 HTTP）。桥与连接器之间只有两件事：
// 按 bid 交进来的回帧，和调用方等待的 ack/终局。超时统一用毫秒级，
// 不真等 5 秒。

// deliver 把用例手写的帧过一遍生产解析路径（数字是 json.Number）再交给桥。
//
// 生产里帧由 hub 的 wire.Decode() 解码后送进来，桥只认 JSON 整数字面量
// （见 intValue）；直接塞一个 Go int 会得到"字段缺失"，测的就不是生产路径了。
func deliver(t *testing.T, registry *Registry, bid, kind string, raw dlp.Frame) (*FetchBridge, bool) {
	t.Helper()
	encoded, err := dlp.Encode(raw)
	if err != nil {
		t.Fatalf("Encode(%v): %v", raw, err)
	}
	frame, damage, err := dlp.Parse(encoded)
	if err != nil || damage != nil {
		t.Fatalf("Parse(%s): err=%v damage=%v", encoded, err, damage)
	}
	return registry.Deliver(bid, kind, frame)
}

func testOwner(generation uint64) Owner {
	return Owner{AgentID: "agt_0123456789abcdef", Generation: generation}
}

func TestPutBridgeAckThenDone(t *testing.T) {
	registry := NewRegistry(nil)
	put := registry.OpenPut("bid-up", testOwner(1))

	if put.WaitAck(context.Background(), 20*time.Millisecond) {
		t.Fatal("没有 ack 不该通过")
	}
	if cancel, found := deliver(t, registry, "bid-up", "fsPutAck", dlp.Frame{
		"t": "fsPutAck", "bid": "bid-up", "received": 0,
	}); !found || cancel != nil {
		t.Fatalf("fsPutAck 应当被认领：found=%v cancel=%v", found, cancel)
	}
	if !put.WaitAck(context.Background(), time.Second) {
		t.Fatal("fsPutAck 之后应当通过")
	}

	deliver(t, registry, "bid-up", "fsPutDone", dlp.Frame{
		"t": "fsPutDone", "bid": "bid-up", "path": "/tmp/p", "bytes": 5,
	})
	outcome, ok := put.WaitDone(context.Background())
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
	registry := NewRegistry(nil)
	put := registry.OpenPut("bid-refused", testOwner(1))

	deliver(t, registry, "bid-refused", "fsErr", dlp.Frame{
		"t": "fsErr", "bid": "bid-refused",
		"code": "workspace-file/too-large", "message": "no room",
	})
	// 在 begin 就拒绝的连接器不会发 ack；失败必须同时放行 ack 等待，否则调用方
	// 会白等满 5 秒，把"连接器说不行"报成"连接器太旧"。
	if !put.WaitAck(context.Background(), time.Second) {
		t.Fatal("fsErr 应当放行 ack 等待")
	}
	outcome, ok := put.WaitDone(context.Background())
	if !ok || !outcome.Failed() {
		t.Fatalf("终局 = %+v ok=%v", outcome, ok)
	}
	if outcome.ErrCode != "workspace-file/too-large" || outcome.ErrMessage != "no room" {
		t.Fatalf("连接器的错误没有被原样带回：%+v", outcome)
	}
}

func TestPutBridgeAckDeadline(t *testing.T) {
	registry := NewRegistry(nil)
	put := registry.OpenPut("bid-old", testOwner(1))

	start := time.Now()
	if put.WaitAck(context.Background(), 30*time.Millisecond) {
		t.Fatal("旧连接器不该通过 ack 等待")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("ack 期限没有生效：等了 %s", elapsed)
	}
	// 迟到的 ack 仍然有效（期限只决定调用方等多久，不关闭桥）。
	deliver(t, registry, "bid-old", "fsPutAck", dlp.Frame{"t": "fsPutAck", "bid": "bid-old"})
	if !put.WaitAck(context.Background(), time.Second) {
		t.Fatal("迟到的 ack 应当被接受")
	}
}

// 终局只落一次：先到的成功不能被后到的断线通知覆盖，反之亦然。
func TestPutBridgeKeepsTheFirstOutcome(t *testing.T) {
	registry := NewRegistry(nil)
	put := registry.OpenPut("bid-once", testOwner(1))

	deliver(t, registry, "bid-once", "fsPutDone", dlp.Frame{
		"t": "fsPutDone", "bid": "bid-once", "path": "/ok", "bytes": 9,
	})
	registry.DropOwner(testOwner(1), "the PC connector disconnected")
	deliver(t, registry, "bid-once", "fsErr", dlp.Frame{
		"t": "fsErr", "bid": "bid-once", "code": "host/offline", "message": "too late",
	})

	outcome, ok := put.WaitDone(context.Background())
	if !ok {
		t.Fatal("应当有终局")
	}
	if outcome.Failed() {
		t.Fatalf("迟到的断线/错误覆盖了成功终局：%+v", outcome)
	}
	if outcome.Path == nil || *outcome.Path != "/ok" {
		t.Fatalf("path = %v", outcome.Path)
	}

	// 反向：先失败，后到的 fsPutDone 也不能把它改成成功。
	other := registry.OpenPut("bid-once-2", testOwner(1))
	deliver(t, registry, "bid-once-2", "fsErr", dlp.Frame{
		"t": "fsErr", "bid": "bid-once-2", "code": "file/rejected", "message": "no",
	})
	deliver(t, registry, "bid-once-2", "fsPutDone", dlp.Frame{
		"t": "fsPutDone", "bid": "bid-once-2", "path": "/late", "bytes": 1,
	})
	if outcome, ok := other.WaitDone(context.Background()); !ok || outcome.ErrCode != "file/rejected" {
		t.Fatalf("迟到的成功覆盖了失败终局：%+v ok=%v", outcome, ok)
	}
}

func TestFetchBridgeMetadataChunksAndEnd(t *testing.T) {
	registry := NewRegistry(nil)
	fetch := registry.OpenFetch("bid-down", testOwner(1))

	deliver(t, registry, "bid-down", "fsGetAck", dlp.Frame{
		"t": "fsGetAck", "bid": "bid-down", "size": 4096, "version": "v1",
	})
	if !fetch.WaitAck(context.Background(), time.Second) {
		t.Fatal("fsGetAck 之后应当通过")
	}
	if size, ok := fetch.Size(); !ok || size != 4096 {
		t.Fatalf("size = %d ok=%v", size, ok)
	}
	if version := fetch.Version(); version != "v1" {
		t.Fatalf("version = %q", version)
	}

	deliver(t, registry, "bid-down", "fsGetChunk", dlp.Frame{
		"t": "fsGetChunk", "bid": "bid-down", "data": "YWJj", "eof": false,
	})
	frame, ok := fetch.NextFrame(context.Background())
	if !ok || frame.Type() != "fsGetChunk" || frame["data"] != "YWJj" {
		t.Fatalf("第一片 = %v ok=%v", frame, ok)
	}

	deliver(t, registry, "bid-down", "fsGetEnd", dlp.Frame{"t": "fsGetEnd", "bid": "bid-down"})
	frame, ok = fetch.NextFrame(context.Background())
	if !ok || frame["_terminal"] != true {
		t.Fatalf("终局帧 = %v ok=%v", frame, ok)
	}

	// 请求结束后登记被摘掉：迟到的窗口找不到桥，只能被丢掉（与 Python 的
	// `test_a_window_for_a_finished_bridge_is_refused` 同一口径）。
	registry.Close("bid-down")
	if _, found := registry.Lookup("bid-down"); found {
		t.Fatal("登记没有被摘掉")
	}
	if _, found := deliver(t, registry, "bid-down", "fsGetChunk", dlp.Frame{
		"t": "fsGetChunk", "bid": "bid-down", "data": "YQ==",
	}); found {
		t.Fatal("摘掉登记之后迟到的片不该被认领")
	}
}

func TestFetchBridgeQueueFullMeansTheReaderIsGone(t *testing.T) {
	registry := NewRegistry(nil)
	fetch := registry.OpenFetch("bid-queue", testOwner(1))
	chunk := dlp.Frame{"t": "fsGetChunk", "bid": "bid-queue", "data": "YQ==", "eof": false}

	for index := 0; index < FetchQueueDepth; index++ {
		if cancel, found := deliver(t, registry, "bid-queue", "fsGetChunk", chunk); !found || cancel != nil {
			t.Fatalf("第 %d 片不该被拒（cancel=%v found=%v）", index, cancel, found)
		}
	}
	cancel, found := deliver(t, registry, "bid-queue", "fsGetChunk", chunk)
	if !found || cancel != fetch {
		t.Fatalf("队列满了应当报告这条桥需要叫停：cancel=%v found=%v", cancel, found)
	}
	if _, ok := fetch.NextFrame(context.Background()); ok {
		t.Fatal("放弃之后不该再取到窗口")
	}
}

func TestFetchBridgeFsErrIsTerminalWithTheConnectorsCode(t *testing.T) {
	registry := NewRegistry(nil)
	fetch := registry.OpenFetch("bid-missing", testOwner(1))

	deliver(t, registry, "bid-missing", "fsErr", dlp.Frame{
		"t": "fsErr", "bid": "bid-missing",
		"code": "workspace-file/not-found", "message": "no such file",
	})
	frame, ok := fetch.NextFrame(context.Background())
	if !ok {
		t.Fatal("应当拿到终局帧")
	}
	if frame["error"] != "workspace-file/not-found" || frame["message"] != "no such file" {
		t.Fatalf("终局帧 = %v", frame)
	}
}

// §5.3：终局只落一次、fsGetCancel 最多一次。
func TestBridgeSettleAndCancelOnce(t *testing.T) {
	registry := NewRegistry(nil)

	// 终局只落一次：先来的断线把桥结束掉，之后所有回帧都不改变结果。
	put := registry.OpenPut("bid-settle", testOwner(1))
	registry.DropOwner(testOwner(1), "the PC connector disconnected")
	deliver(t, registry, "bid-settle", "fsPutDone", dlp.Frame{
		"t": "fsPutDone", "bid": "bid-settle", "path": "/late", "bytes": 1,
	})
	deliver(t, registry, "bid-settle", "fsErr", dlp.Frame{
		"t": "fsErr", "bid": "bid-settle", "code": "file/rejected", "message": "late",
	})
	outcome, ok := put.WaitDone(context.Background())
	if !ok || outcome.ErrCode != "host/offline" {
		t.Fatalf("终局 = %+v ok=%v", outcome, ok)
	}

	// fsGetCancel 最多一次：并发调用 TakeCancel 只能有一个 true。
	fetch := registry.OpenFetch("bid-cancel", testOwner(1))
	var attempts atomic.Int64
	var group sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if fetch.TakeCancel() {
				attempts.Add(1)
			}
		}()
	}
	group.Wait()
	if got := attempts.Load(); got != 1 {
		t.Fatalf("并发调用 TakeCancel 得到 %d 次 true，期望 1", got)
	}
	if fetch.TakeCancel() {
		t.Fatal("同一桥第二次 TakeCancel 不该再允许")
	}
}

// 收尾口径：断线/关停时等待中的请求立刻结束，而不是等到自己的超时。
func TestBridgeDropOwnerAndFailAll(t *testing.T) {
	registry := NewRegistry(nil)
	put := registry.OpenPut("bid-put", testOwner(1))
	fetch := registry.OpenFetch("bid-fetch", testOwner(1))

	registry.DropOwner(testOwner(1), "the PC connector disconnected")
	if outcome, ok := put.WaitDone(context.Background()); !ok ||
		outcome.ErrCode != "host/offline" || outcome.ErrMessage != "the PC connector disconnected" {
		t.Fatalf("上传终局 = %+v ok=%v", outcome, ok)
	}
	if frame, ok := fetch.NextFrame(context.Background()); !ok ||
		frame["error"] != "host/offline" || frame["message"] != "the PC connector disconnected" {
		t.Fatalf("下载终局帧 = %v ok=%v", frame, ok)
	}

	// FailAll 不区分归属：关停时所有桥都结束。
	other := registry.OpenPut("bid-other", testOwner(2))
	registry.FailAll("the relay is shutting down")
	if outcome, ok := other.WaitDone(context.Background()); !ok ||
		outcome.ErrCode != "host/offline" || outcome.ErrMessage != "the relay is shutting down" {
		t.Fatalf("FailAll 之后的上传终局 = %+v ok=%v", outcome, ok)
	}
}

package bridge

import (
	"context"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

func TestRegistryLookupAndClose(t *testing.T) {
	registry := NewRegistry(nil)
	if _, found := registry.Lookup("bid-missing"); found {
		t.Fatal("空登记表不该查到东西")
	}
	put := registry.OpenPut("bid-a", testOwner(1))
	registered, found := registry.Lookup("bid-a")
	if !found || registered != put {
		t.Fatalf("Lookup = %+v found=%v", registered, found)
	}
	if registered.Bid() != "bid-a" || registered.Owner() != testOwner(1) {
		t.Fatalf("登记的身份 = %q %+v", registered.Bid(), registered.Owner())
	}
	// 幂等：摘两次不 panic，也不影响别的登记。
	registry.Close("bid-a")
	registry.Close("bid-a")
	if _, found := registry.Lookup("bid-a"); found {
		t.Fatal("登记没有被摘掉")
	}
}

// 同名 bid 是覆盖语义（与 Python 一致）：App 带着同一个 bid 重试时，新登记顶掉旧的；
// 终局只交给新的那条，旧请求不会被迟到的回帧认领。
func TestRegistryBidConflictOverwrites(t *testing.T) {
	registry := NewRegistry(nil)
	first := registry.OpenPut("bid-same", testOwner(1))
	second := registry.OpenPut("bid-same", testOwner(1))

	registered, found := registry.Lookup("bid-same")
	if !found || registered != second {
		t.Fatalf("同名 bid 应当被新登记覆盖：%+v found=%v", registered, found)
	}
	deliver(t, registry, "bid-same", "fsPutDone", dlp.Frame{
		"t": "fsPutDone", "bid": "bid-same", "path": "/new", "bytes": 2,
	})
	if outcome, ok := second.WaitDone(context.Background()); !ok || outcome.Path == nil ||
		*outcome.Path != "/new" {
		t.Fatalf("新登记的终局 = %+v ok=%v", outcome, ok)
	}
	if _, settled := first.TryOutcome(); settled {
		t.Fatal("被覆盖的旧登记不该收到终局")
	}

	// Close 按 bid 摘除（Python 同口径）：旧请求收尾时摘掉的是当前这一条。
	registry.Close("bid-same")
	if _, found := registry.Lookup("bid-same"); found {
		t.Fatal("Close 应当按 bid 摘除当前登记")
	}
}

func TestRegistryDeliverWithoutRegistration(t *testing.T) {
	registry := NewRegistry(nil)
	if cancel, found := deliver(t, registry, "bid-none", "fsGetChunk", dlp.Frame{
		"t": "fsGetChunk", "bid": "bid-none", "data": "YQ==",
	}); found || cancel != nil {
		t.Fatalf("没有登记时不该认领：cancel=%v found=%v", cancel, found)
	}
}

// §5.3：顶替时只让旧连接自己的桥失败，新连接刚开的传输不受影响；
// 投递仍按 bid 认，不校验来源（DESIGN §3.4），迟到的回帧不改变已落的终局。
func TestBridgeOwnerIsolation(t *testing.T) {
	registry := NewRegistry(nil)
	oldOwner := Owner{AgentID: "agt_0123456789abcdef", Generation: 3}
	newOwner := Owner{AgentID: "agt_0123456789abcdef", Generation: 4}
	oldPut := registry.OpenPut("bid-old", oldOwner)
	newPut := registry.OpenPut("bid-new", newOwner)
	oldFetch := registry.OpenFetch("bid-old-fetch", oldOwner)

	// 别的代编号不是它们的归属：什么都不该结束。
	registry.DropOwner(Owner{AgentID: "agt_0123456789abcdef", Generation: 2}, "not ours")
	if _, settled := oldPut.TryOutcome(); settled {
		t.Fatal("别的代编号的收尾不该碰到这条桥")
	}

	// 旧连接退出：只有旧代的桥失败，新代还活着。
	registry.DropOwner(oldOwner, "the PC connector reconnected")
	if outcome, ok := oldPut.WaitDone(context.Background()); !ok || outcome.ErrCode != "host/offline" {
		t.Fatalf("旧连接上的桥没有被收尾：%+v ok=%v", outcome, ok)
	}
	if frame, ok := oldFetch.NextFrame(context.Background()); !ok || frame["error"] != "host/offline" {
		t.Fatalf("旧连接上的下载没有被收尾：%v ok=%v", frame, ok)
	}
	if _, settled := newPut.TryOutcome(); settled {
		t.Fatal("新连接上的桥不能被旧连接的拆除误伤")
	}

	// 投递只看 bid：旧 bid 的迟到回帧仍会交给登记表里的那条桥（其终局已定，
	// 所以不会推翻 host/offline），不会串到新 bid 上。
	deliver(t, registry, "bid-old", "fsPutDone", dlp.Frame{
		"t": "fsPutDone", "bid": "bid-old", "path": "/stale", "bytes": 1,
	})
	if _, settled := newPut.TryOutcome(); settled {
		t.Fatal("旧 bid 的迟到回帧串到了新桥上")
	}
	if outcome, _ := oldPut.TryOutcome(); outcome.ErrCode != "host/offline" {
		t.Fatalf("迟到的成功覆盖了旧桥的失败终局：%+v", outcome)
	}

	// 新连接自己的桥照常完成。
	deliver(t, registry, "bid-new", "fsPutDone", dlp.Frame{
		"t": "fsPutDone", "bid": "bid-new", "path": "/new", "bytes": 2,
	})
	if outcome, ok := newPut.WaitDone(context.Background()); !ok || outcome.Failed() {
		t.Fatalf("新桥终局 = %+v ok=%v", outcome, ok)
	}
}

// 下载方向同样按连接代编号隔离：旧连接退出只结束旧桥，新连接的下载继续。
func TestBridgeOwnerIsolationCoversDownloads(t *testing.T) {
	registry := NewRegistry(nil)
	oldOwner := testOwner(5)
	newOwner := testOwner(6)
	oldFetch := registry.OpenFetch("bid-old-down", oldOwner)
	newFetch := registry.OpenFetch("bid-new-down", newOwner)

	registry.DropOwner(oldOwner, "the PC connector reconnected")
	if frame, ok := oldFetch.NextFrame(context.Background()); !ok ||
		frame["error"] != "host/offline" {
		t.Fatalf("旧连接上的下载没有被收尾：%v ok=%v", frame, ok)
	}

	// 新连接的下载仍能完成一次正常的 ack → 片 → 终局。
	deliver(t, registry, "bid-new-down", "fsGetAck", dlp.Frame{
		"t": "fsGetAck", "bid": "bid-new-down", "size": 1,
	})
	if !newFetch.WaitAck(context.Background(), time.Second) {
		t.Fatal("新连接上的下载被旧连接的收尾误伤")
	}
	deliver(t, registry, "bid-new-down", "fsGetChunk", dlp.Frame{
		"t": "fsGetChunk", "bid": "bid-new-down", "data": "YQ==",
	})
	if frame, ok := newFetch.NextFrame(context.Background()); !ok || frame["data"] != "YQ==" {
		t.Fatalf("新连接上的片 = %v ok=%v", frame, ok)
	}
}

// 等一条被放弃的下载桥：终局帧到达之后仍按顺序可读（片在终局之前）。
func TestFetchBridgeKeepsChunkOrderBeforeTheTerminal(t *testing.T) {
	registry := NewRegistry(nil)
	fetch := registry.OpenFetch("bid-order", testOwner(1))
	for index, data := range []string{"YQ==", "YmI="} {
		cancel, found := deliver(t, registry, "bid-order", "fsGetChunk", dlp.Frame{
			"t": "fsGetChunk", "bid": "bid-order", "data": data, "seq": index,
		})
		if !found || cancel != nil {
			t.Fatalf("第 %d 片没有被接收（cancel=%v found=%v）", index, cancel, found)
		}
	}
	if cancel, found := deliver(t, registry, "bid-order", "fsGetEnd",
		dlp.Frame{"t": "fsGetEnd", "bid": "bid-order"}); !found || cancel != nil {
		t.Fatalf("终局帧没有被接收（cancel=%v found=%v）", cancel, found)
	}
	for _, want := range []any{"YQ==", "YmI=", true} {
		frame, ok := fetch.NextFrame(context.Background())
		if !ok {
			t.Fatalf("应当还能读到帧（期望 %v）", want)
		}
		if want == true {
			if frame["_terminal"] != true {
				t.Fatalf("最后一帧应当是终局：%v", frame)
			}
			continue
		}
		if frame["data"] != want {
			t.Fatalf("片顺序变了：%v", frame["data"])
		}
	}
	// 终局之后队列空了；用超时确认不会再有帧（不 sleep）。
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, ok := fetch.NextFrame(ctx); ok {
		t.Fatal("终局之后不该再有多余的帧")
	}
}

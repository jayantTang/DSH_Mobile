package hub

import (
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/bridge"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// 文件桥的编排（DESIGN-20261023 §3.4）。
//
// 状态机、bid 登记表与等待队列都在 internal/bridge；这里只接三件事：把连接器上的
// fs* 回帧按 bid 交给登记表、把发送面（SendControl/SendBridgeChunk）接给等待中的
// 请求，以及在断线/顶替/关停时按归属收尾。
//
// 桥的名字（bid）只活在一次请求里，中转不持久化任何桥状态。

// bridgeOwner 是这条连接在桥登记表里的身份。
//
// 只用 agentId 不够：连接器重连时旧连接与新连接是同一个 agentId，按 agentId 收尾
// 会误伤新连接刚开的传输（DESIGN §3.4）。
func (l *AgentLink) bridgeOwner() bridge.Owner {
	return bridge.Owner{AgentID: l.AgentID, Generation: l.generation}
}

// OpenPutBridge 登记一次上传；同名 bid 会覆盖旧的登记（与 Python 一致：App 带着
// 同一个 bid 重试，连接器那边也是覆盖语义）。
func (h *Hub) OpenPutBridge(bid string, agent *AgentLink) *bridge.PutBridge {
	return h.bridges.OpenPut(bid, agent.bridgeOwner())
}

// OpenFetchBridge 登记一次下载。
func (h *Hub) OpenFetchBridge(bid string, agent *AgentLink) *bridge.FetchBridge {
	return h.bridges.OpenFetch(bid, agent.bridgeOwner())
}

// CloseBridge 摘掉一条登记（HTTP handler 的收尾，幂等）。
func (h *Hub) CloseBridge(bid string) {
	h.bridges.Close(bid)
}

// routeBridgeFrame 把连接器的一条 fs* 回帧交给等待它的请求。
//
// 没有被认领的帧（请求已经结束、或旧 run 的迟到分片）只能丢掉——这正是"旧 run
// 的分片不许落进新桥接"的唯一实现点。返回的 cancel 非 nil 时让路由层发 fsGetCancel。
func (h *Hub) routeBridgeFrame(link *AgentLink, wire dlp.Wire) {
	frame, err := wire.Decode()
	if err != nil {
		h.log.Debug("relay: could not decode a file-bridge frame",
			"agentId", link.AgentID, "error", err)
		return
	}
	bid, _ := frame["bid"].(string)
	if bid == "" {
		h.log.Debug("relay: file-bridge frame without a bid",
			"agentId", link.AgentID, "frame", frame.Type())
		return
	}
	cancel, found := h.bridges.Deliver(bid, frame.Type(), frame)
	if !found {
		h.log.Debug("relay: no bridge waiting for a file-bridge frame",
			"agentId", link.AgentID, "frame", frame.Type(), "bid", bid)
		return
	}
	if cancel != nil {
		h.CancelFetch(link, cancel)
	}
}

// CancelFetch 告诉连接器停止为一条没人读的下载继续读文件。
//
// 每条桥最多发一次：连接器对不认识的 bid 是空操作，重复发虽然无害，但一次被顶替的
// run 会变成一串 fsGetCancel。帧走同一个连接发送队列，所以不可能越过它的
// fsGetBegin。
func (h *Hub) CancelFetch(link *AgentLink, fetch *bridge.FetchBridge) {
	if link == nil || fetch == nil {
		return
	}
	if !fetch.TakeCancel() {
		return
	}
	h.SendControl(link, dlp.FetchCancelFrame(fetch.Bid()))
	h.log.Debug("relay: cancelling a download nobody is reading", "bid", fetch.Bid())
}

// dropAgentBridges 让一条断掉（或被顶替）的连接器上的全部桥立刻结束。
//
// 没有这一步，上传请求会一直等到自己的超时、下载请求会等到 120 秒的静默上限；
// 用户看到的是"一直在传/一直在下"，而不是"失败了"。
func (h *Hub) dropAgentBridges(link *AgentLink, reason string) {
	h.bridges.DropOwner(link.bridgeOwner(), reason)
}

// failAllBridges 是进程收尾用的：所有等待中的请求都以 host/offline 结束。
func (h *Hub) failAllBridges(reason string) {
	h.bridges.FailAll(reason)
}

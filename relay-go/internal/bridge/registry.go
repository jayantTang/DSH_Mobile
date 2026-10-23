package bridge

import (
	"io"
	"log/slog"
	"sync"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// Registry 是 bid → 桥的唯一登记表。
//
// 同名 bid 是覆盖语义（与 Python 一致）：App 带着同一个 bid 重试时，新登记顶掉旧
// 登记；Close 按 bid 摘除，摘掉的是不是"自己"那一条并不区分（Python 同口径）。
//
// 它不在转发热路径上：只有 fs* 控制帧和 /files/* 的 HTTP handler 会碰它，所以一把
// 普通互斥锁就够。
type Registry struct {
	mu      sync.Mutex
	bridges map[string]Bridge
	log     *slog.Logger
}

// NewRegistry 建一个空登记表；log 为 nil 时静默（单测直接构造时用）。
func NewRegistry(log *slog.Logger) *Registry {
	if log == nil {
		log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &Registry{bridges: map[string]Bridge{}, log: log}
}

// OpenPut 登记一次上传；同名 bid 会覆盖旧的登记（与 Python 一致：App 带着同一个
// bid 重试，连接器那边也是覆盖语义）。
func (r *Registry) OpenPut(bid string, owner Owner) *PutBridge {
	put := &PutBridge{
		bid: bid, owner: owner, log: r.log,
		acked: make(chan struct{}), done: make(chan struct{}),
	}
	r.register(put)
	return put
}

// OpenFetch 登记一次下载。
func (r *Registry) OpenFetch(bid string, owner Owner) *FetchBridge {
	fetch := &FetchBridge{
		bid: bid, owner: owner, log: r.log,
		acked: make(chan struct{}), frames: make(chan dlp.Frame, FetchQueueDepth),
	}
	r.register(fetch)
	return fetch
}

// register 写入一条登记（覆盖同名）。调用方必须持有要登记的桥。
func (r *Registry) register(entry Bridge) {
	r.mu.Lock()
	r.bridges[entry.Bid()] = entry
	r.mu.Unlock()
}

// Close 摘掉一条登记（HTTP handler 的收尾，幂等）。
func (r *Registry) Close(bid string) {
	r.mu.Lock()
	delete(r.bridges, bid)
	r.mu.Unlock()
}

// Lookup 取一条登记；没有时 found=false。
func (r *Registry) Lookup(bid string) (Bridge, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	entry, found := r.bridges[bid]
	return entry, found
}

// Deliver 把连接器的一条 fs* 回帧交给 bid 对应的桥。
//
// 没有登记时 found=false：请求已经结束，或这是旧 run 的迟到分片，调用方只记日志、
// 丢掉。返回的 cancel 非 nil 表示读者已经走了，调用方应为它发一次 fsGetCancel。
//
// 这里**只按 bid 认**，不校验来源连接：回帧可能来自被顶替的旧 socket，迟到的成功
// 不能覆盖已落的终局（settle-once 在桥里），但也不该因为来源不同就被丢弃
// （DESIGN §3.4）。
func (r *Registry) Deliver(bid, kind string, frame dlp.Frame) (cancel *FetchBridge, found bool) {
	r.mu.Lock()
	entry := r.bridges[bid]
	r.mu.Unlock()
	if entry == nil {
		return nil, false
	}
	if entry.deliver(kind, frame) {
		return nil, true
	}
	fetch, _ := entry.(*FetchBridge)
	return fetch, true
}

// DropOwner 让一条断掉（或被顶替）的连接上的全部桥立刻结束。
//
// 没有这一步，上传请求会一直等到自己的超时、下载请求会等到 120 秒的静默上限；
// 用户看到的是"一直在传/一直在下"，而不是"失败了"。按 (agentId, generation) 收尾，
// 不会误伤同一台电脑上新连接刚开的传输。
func (r *Registry) DropOwner(owner Owner, reason string) {
	r.mu.Lock()
	waiting := make([]Bridge, 0, 4)
	for _, entry := range r.bridges {
		if entry.Owner() == owner {
			waiting = append(waiting, entry)
		}
	}
	r.mu.Unlock()
	for _, entry := range waiting {
		entry.fail(reason)
	}
}

// FailAll 是进程收尾用的：所有等待中的请求都以 host/offline 结束。
func (r *Registry) FailAll(reason string) {
	r.mu.Lock()
	waiting := make([]Bridge, 0, len(r.bridges))
	for _, entry := range r.bridges {
		waiting = append(waiting, entry)
	}
	r.mu.Unlock()
	for _, entry := range waiting {
		entry.fail(reason)
	}
}

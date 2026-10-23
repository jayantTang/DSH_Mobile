package hub

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// Sink 是帧最终写出去的地方：生产里是 WebSocket，单测里是内存实现。
//
// 抽出这一层是为了让 hub 的路由、队列与背压可以脱离真实 socket 测试；同时保证
// "写只发生在写循环里"这条规则只有一个执行者。
type Sink interface {
	// Write 写一条文本消息。
	Write(ctx context.Context, payload []byte) error
	// Ping 发一次心跳并等待对端回答；超时由 ctx 控制。
	Ping(ctx context.Context) error
	// Close 走关闭握手并带上应用层关闭码。
	Close(code int, reason string) error
}

// Class 决定一帧在队列满时能不能丢。
type Class int

const (
	// ClassControl 是不可丢的帧：丢一帧就等于坏一次结果，宁可断开慢连接。
	ClassControl Class = iota
	// ClassStream 是流式帧（res / item）：丢了调用方还能重试或跳过。
	ClassStream
)

// EnqueueResult 是一次入队的结果。
type EnqueueResult int

const (
	// Enqueued 表示已进队列。
	Enqueued EnqueueResult = iota
	// FrameDropped 表示流式帧因队列满被丢弃（已计数，连接可继续）。
	FrameDropped
	// Overloaded 表示控制帧没进队列，调用方应当断开这条连接。
	Overloaded
)

// outbound 是队列里的一项：要么一条待写消息，要么一次关闭请求。
//
// 队列里放的是**指针**而不是结构体本身：M2 的 `chan outbound`（每槽 48 字节）
// 在 300 档里光电脑侧队列就占 56.6 MiB（pprof：hub.newLink 占存活堆 86.4%）。
// 指针槽是 8 字节，同样的深度省下 6/7。
type outbound struct {
	payload []byte
	// owned 是这条消息读缓冲的所有者（来自帧池）；写出去之后由写循环归还。
	owned *dlp.Buffer
	// credit 是这条消息预先取得的桥字节额度；写出去（或被丢弃、随连接关闭清空）
	// 之后才归还。它与 payload 同生共死：只要帧还在队列里，内存就还是它占着。
	credit      *bridgeCredits
	creditBytes int64
	closeCode   int
	closeReason string
}

// release 归还这条消息占用的缓冲与桥额度；中继自己拼的普通帧两者都没有。
func (o *outbound) release() {
	if o.owned != nil {
		o.owned.Release()
		o.owned = nil
	}
	if o.credit != nil {
		o.credit.Release(o.creditBytes)
		o.credit = nil
		o.creditBytes = 0
	}
}

// 超时与心跳的默认值（DESIGN §5.3：服务端每 15 秒 ping 一次）。
const (
	DefaultHeartbeat        = 15 * time.Second
	DefaultHeartbeatTimeout = 10 * time.Second
	DefaultWriteTimeout     = 10 * time.Second
	// maxCloseReason 是 WebSocket 关闭原因的上限（协议规定 123 字节，留 3 字节余量）。
	maxCloseReason = 120
)

// Link 是一条连接：一个有界发送队列 + 一个写循环。
//
// 写只由写循环执行；其他 goroutine 只能 enqueue。这条规则是中转不会出现"两个
// goroutine 同时写一条 socket"的唯一保证。
type Link struct {
	label string
	sink  Sink
	log   *slog.Logger
	out   chan *outbound
	done  chan struct{}

	egress  atomic.Int64
	dropped atomic.Int64
	// queuedBytes 是队列里还没写出去的帧字节数；byteLimit 是它的上限（见 Enqueue）。
	queuedBytes atomic.Int64
	byteLimit   int64
	// credits 是**文件上行桥**的字节额度（只有连接器链路有）。它约束的是那类
	// 不可丢的 ClassControl 分片：它们绕过 byteLimit，所以必须另有一份账。
	credits *bridgeCredits

	heartbeat        time.Duration
	heartbeatTimeout time.Duration
	writeTimeout     time.Duration

	// 写超时用"一条连接一个复用计时器 + 一个可取消的写上下文"实现。
	//
	// M2 是每帧 context.WithTimeout(...)：一帧一次 timer + 三个 context 结构
	// （pprof 实测每帧约 500 B，60k 帧合计 30 MiB）。超时的语义本来就是"这条
	// 连接已经死了"，所以取消整条链路的写上下文是正确反应，不需要每帧新建一个。
	writeCtx    context.Context
	cancelWrite context.CancelFunc
	writeTimer  *time.Timer

	// pace 在写之前按设备限速等待；agent 链路为 nil。
	pace func(ctx context.Context, size int) error
	// onSent 在一条消息真正写出后调用（设备链路用来累计出口字节）。
	onSent func(size int)

	startOnce sync.Once
	started   atomic.Bool
	closing   atomic.Bool
	closeOnce sync.Once
}

// newLink 建一条连接；depth 是队列深度，byteLimit 是队列的字节上限。
func newLink(sink Sink, label string, depth int, byteLimit int64, log *slog.Logger,
	options linkOptions) *Link {
	if depth <= 0 {
		depth = 1
	}
	if byteLimit <= 0 {
		byteLimit = int64(dlp.MaxFrameBytes)
	}
	return &Link{
		label:            label,
		sink:             sink,
		log:              log,
		out:              make(chan *outbound, depth),
		byteLimit:        byteLimit,
		done:             make(chan struct{}),
		heartbeat:        options.heartbeat,
		heartbeatTimeout: options.heartbeatTimeout,
		writeTimeout:     options.writeTimeout,
	}
}

// linkOptions 是三条连接共用的心跳/超时设置。
type linkOptions struct {
	heartbeat        time.Duration
	heartbeatTimeout time.Duration
	writeTimeout     time.Duration

	// 写超时用"一条连接一个复用计时器 + 一个可取消的写上下文"实现。
	//
	// M2 是每帧 context.WithTimeout(...)：一帧一次 timer + 三个 context 结构
	// （pprof 实测每帧约 500 B，60k 帧合计 30 MiB）。超时的语义本来就是"这条
	// 连接已经死了"，所以取消整条链路的写上下文是正确反应，不需要每帧新建一个。
	writeCtx    context.Context
	cancelWrite context.CancelFunc
	writeTimer  *time.Timer
}

func (o linkOptions) withDefaults() linkOptions {
	if o.heartbeat <= 0 {
		o.heartbeat = DefaultHeartbeat
	}
	if o.heartbeatTimeout <= 0 {
		o.heartbeatTimeout = DefaultHeartbeatTimeout
	}
	if o.writeTimeout <= 0 {
		o.writeTimeout = DefaultWriteTimeout
	}
	return o
}

// Start 起写循环。必须先于任何"需要被对端看到"的帧——但排在前面的入队不会丢：
// 队列是有缓冲的，写循环一启动就会按顺序发出。
func (l *Link) Start(ctx context.Context) {
	l.startOnce.Do(func() {
		l.started.Store(true)
		if l.closing.Load() {
			// 还没开始写就被要求关闭（例如刚 attach 就触发了设备上限的兜底路径）：
			// 直接关，别留一个永远不排空的队列。
			l.closeSink(1001, "closed before start")
			l.closeCredits()
			close(l.done)
			return
		}
		go l.writeLoop(ctx)
	})
}

// Label 是日志里的连接标识（`device <id>` / `agent <id>`）。
func (l *Link) Label() string { return l.label }

// Enqueue 把一条待写消息放进队列。
//
// 队列满时按帧类型分流：流式帧丢弃并计数（DESIGN §5.1），控制帧返回 Overloaded，
// 由调用方断开这条连接——控制帧静默丢失比断线更难排查。
//
// 字节限额只约束**小帧的堆积**：比限额还大的单帧永远放行，否则一张 32 MiB 的图片
// 会被自己的体积挡在门外；真正需要防的是"几百个小帧把队列填满"和"多张大图排队"。
//
// owned 是这条消息的缓冲所有者：入队成功即转移给写循环，失败时仍归调用方。
func (l *Link) Enqueue(payload []byte, class Class, owned *dlp.Buffer) EnqueueResult {
	return l.enqueue(payload, class, owned, nil, 0)
}

// EnqueueWithCredit 与 Enqueue 同义，但这条消息带着一笔已经取得的桥字节额度。
//
// 额度的所有权**只在入队成功时转移**给写循环；失败时仍归调用方（调用方必须自己
// 归还），与 owned 的规则一致——两个"随帧归还"的资源只有一条转移路径。
func (l *Link) EnqueueWithCredit(payload []byte, class Class, credit *bridgeCredits,
	creditBytes int64) EnqueueResult {
	if credit == nil || creditBytes <= 0 {
		return l.Enqueue(payload, class, nil)
	}
	return l.enqueue(payload, class, nil, credit, creditBytes)
}

func (l *Link) enqueue(payload []byte, class Class, owned *dlp.Buffer,
	credit *bridgeCredits, creditBytes int64) EnqueueResult {
	if l.closing.Load() {
		return Overloaded
	}
	size := int64(len(payload))
	if class == ClassStream && size <= l.byteLimit {
		if used := l.queuedBytes.Load(); used > 0 && used+size > l.byteLimit {
			l.dropped.Add(1)
			return FrameDropped
		}
	}
	l.queuedBytes.Add(size)
	item := &outbound{payload: payload, owned: owned, credit: credit, creditBytes: creditBytes}
	select {
	case l.out <- item:
		return Enqueued
	default:
		l.queuedBytes.Add(-size)
		// 入队失败：payload 的所有者（owned）与额度仍归调用方，两者都由它归还。
	}
	if class == ClassStream {
		l.dropped.Add(1)
		return FrameDropped
	}
	return Overloaded
}

// AcquireBridgeBytes 取得 n 字节上行桥额度；额度不够时阻塞到有人归还。
//
// 没有启用额度的链路（设备链路、或 bridge-bytes 未配置的旧装配）直接放行。
func (l *Link) AcquireBridgeBytes(ctx context.Context, n int64) error {
	if l.credits == nil {
		return nil
	}
	return l.credits.Acquire(ctx, n)
}

// ReleaseBridgeBytes 归还一笔没交给队列的额度（发送失败、请求取消、读体出错）。
func (l *Link) ReleaseBridgeBytes(n int64) {
	if l.credits != nil {
		l.credits.Release(n)
	}
}

// BridgeBytesInUse 是这条链路已经占用的上行桥字节（/stats 与用例的诊断口）。
func (l *Link) BridgeBytesInUse() int64 {
	if l.credits == nil {
		return 0
	}
	return l.credits.InUse()
}

// BridgeBytesCapacity 是这条链路的上行桥字节上限；0 表示没有启用额度。
func (l *Link) BridgeBytesCapacity() int64 {
	if l.credits == nil {
		return 0
	}
	return l.credits.Capacity()
}

// BridgeBytesWaiting 是正卡在额度上的请求数。
func (l *Link) BridgeBytesWaiting() int {
	if l.credits == nil {
		return 0
	}
	return l.credits.Waiting()
}

// closeCredits 让还在等额度的请求立刻失败（连接器被顶替/断开时不能让它们挂着）。
func (l *Link) closeCredits() {
	if l.credits != nil {
		l.credits.Close()
	}
}

// QueuedBytes 是队列里还没写出去的帧字节数（/stats 与用例的诊断口）。
func (l *Link) QueuedBytes() int64 { return l.queuedBytes.Load() }

// RequestClose 请求以 code/reason 关闭这条连接，**立即返回**。
//
// 关闭请求走同一条队列，所以排在前面的帧一定先发出去（配额错误帧必须先于 4011
// 到达手机）；队列满时直接关，不再等。
//
// 关闭握手由写循环执行，调用方不阻塞：撤销设备的那条路径是一个 HTTP handler，
// 不能被一台不回应的手机拖住 5 秒（Python 版用 asyncio task 达到同样效果）。
func (l *Link) RequestClose(code int, reason string) {
	if code == 0 {
		code = 1001
	}
	if !l.closing.CompareAndSwap(false, true) {
		return
	}
	reason = truncateReason(reason)
	if !l.started.Load() {
		l.closeSink(code, reason)
		return
	}
	select {
	case l.out <- &outbound{closeCode: code, closeReason: reason}:
	default:
		// 队列里全是还没写出去的帧：连接已经不值得等，直接关。
		go l.closeSink(code, reason)
	}
}

// Done 在写循环退出后关闭。
func (l *Link) Done() <-chan struct{} { return l.done }

// Closed 表示这条连接已经在关闭路上（不再接受新帧）。
func (l *Link) Closed() bool { return l.closing.Load() }

// Pending 是队列里还没写出去的帧数（/stats 的 pending）。
func (l *Link) Pending() int { return len(l.out) }

// EgressBytes 是这条连接写出的字节数。
func (l *Link) EgressBytes() int64 { return l.egress.Load() }

// DroppedFrames 是流式帧因背压被丢弃的数量。
func (l *Link) DroppedFrames() int64 { return l.dropped.Load() }

// writeLoop 是唯一写 socket 的 goroutine。
func (l *Link) writeLoop(ctx context.Context) {
	defer close(l.done)
	// 写循环一退出，这条连接就不该再收新帧：否则队列会继续被填，直到某条控制帧
	// 撞上"满了"再走一次没有读者的关闭流程。标记为 closing 让入队立刻短路。
	defer l.closing.Store(true)
	// 连接关闭路径的收尾：队列里还没写出去的帧不会再写了，把它们占着的读缓冲
	// 立刻还给帧池（否则要等 GC）。同时把字节计数归零，免得 /stats 留一个幽灵队列。
	defer l.drainQueue()
	// 额度先在 drainQueue 之前关掉：还在等额度的上传请求要立刻失败，而不是等
	// 队列清空才醒。队列里已经占了额度的帧由 drainQueue 逐帧归还。
	defer l.closeCredits()
	ticker := time.NewTicker(l.heartbeat)
	defer ticker.Stop()

	l.writeCtx, l.cancelWrite = context.WithCancel(ctx)
	defer l.cancelWrite()
	l.writeTimer = time.AfterFunc(l.writeTimeout, l.cancelWrite)
	defer l.writeTimer.Stop()

	for {
		select {
		case item := <-l.out:
			// 出队即不再占队列字节；缓冲要等真正写出去才归还。
			l.queuedBytes.Add(-int64(len(item.payload)))
			if item.closeCode != 0 {
				item.release()
				l.closeSink(item.closeCode, item.closeReason)
				return
			}
			if l.pace != nil {
				if err := l.pace(ctx, len(item.payload)); err != nil {
					item.release()
					return
				}
			}
			wrote := l.write(ctx, item.payload)
			item.release()
			if !wrote {
				return
			}
		case <-ticker.C:
			// 心跳：对方还在不在，是这条连接唯一的活性证据。
			pingCtx, cancel := context.WithTimeout(ctx, l.heartbeatTimeout)
			err := l.sink.Ping(pingCtx)
			cancel()
			if err != nil {
				l.log.Info("relay: heartbeat failed, closing", "link", l.label, "error", err)
				l.closeSink(1001, "heartbeat timeout")
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

// drainQueue 把队列里剩下的帧缓冲归还给池；关停时最多被调用一次。
func (l *Link) drainQueue() {
	for {
		select {
		case item := <-l.out:
			l.queuedBytes.Add(-int64(len(item.payload)))
			item.release()
		default:
			return
		}
	}
}

// write 写一条消息；失败即认为连接已坏。
//
// 单帧写超时由写循环复用的计时器负责：计时器到点取消这条链路的写上下文，
// 于是这次 Write 立刻返回错误、连接按"写超时"收尾。计时器在写完后停掉，
// 下一帧再 Reset——每帧不再新建 context 与 timer。
func (l *Link) write(ctx context.Context, payload []byte) bool {
	if l.writeTimer != nil {
		l.writeTimer.Reset(l.writeTimeout)
	}
	err := l.sink.Write(l.writeCtxOr(ctx), payload)
	if l.writeTimer != nil && l.writeTimer.Stop() {
		// 停成功说明这次写没有超时；Stop 返回 false 时可能是计时器已经触发
		// （写上下文已被取消，下一帧会直接失败），也可能是刚好在触发边界上。
	}
	if err != nil {
		l.log.Debug("relay: write failed", "link", l.label, "error", err)
		return false
	}
	l.egress.Add(int64(len(payload)))
	if l.onSent != nil {
		l.onSent(len(payload))
	}
	return true
}

// writeCtxOr 返回这条连接复用的写上下文；写循环还没建好时退回调用方的 ctx。
func (l *Link) writeCtxOr(fallback context.Context) context.Context {
	if l.writeCtx != nil {
		return l.writeCtx
	}
	return fallback
}

// closeSink 执行一次关闭握手（幂等）。
func (l *Link) closeSink(code int, reason string) {
	l.closeOnce.Do(func() {
		if err := l.sink.Close(code, truncateReason(reason)); err != nil {
			l.log.Debug("relay: close failed", "link", l.label, "error", err)
		}
	})
}

// truncateReason 把关闭原因裁到协议允许的长度，并且不切断 UTF-8 字符。
func truncateReason(reason string) string {
	if len(reason) <= maxCloseReason {
		return reason
	}
	cut := maxCloseReason
	for cut > 0 && !utf8.RuneStart(reason[cut]) {
		cut--
	}
	return reason[:cut]
}

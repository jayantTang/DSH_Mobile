package hub

import (
	"context"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/bridge"
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

// RemoteSink 是能报告 socket 对端地址的 Sink。
//
// wsapi 的 socket 适配器实现它（生产里 /debug/conns 与连接日志的 remote_ip 由此而来）；
// 单测的桩 Sink 不实现，地址就是空串——不给 Sink 接口本身加方法，避免为了一个诊断
// 字段去改所有测试桩。
type RemoteSink interface {
	RemoteAddr() string
}

// remoteOf 取一条 Sink 的对端地址；不支持时返回空串。
func remoteOf(sink Sink) string {
	if remote, ok := sink.(RemoteSink); ok {
		return remote.RemoteAddr()
	}
	return ""
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
	credit      *bridge.Credits
	creditBytes int64
	// counted 表示这条消息的字节已经记进 queuedBytes（只有大队列里的帧会记）。
	counted     bool
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

// 超时与心跳的默认值（DESIGN §5.3：服务端每 30 秒 ping 一次，与 Python
// aiohttp 的 heartbeat=30.0 对齐）。
//
// 截止时间取 60 秒，不是 30 秒：连接器每 20 秒发一次 DLP ping，与 Python
// 的 45 秒整体容忍（30 秒空闲 + 15 秒 pong 窗口）相比，60 秒给出 3 个心跳
// 周期的余量，覆盖移动网络下实测 27–32 秒的入站抖动；连接器自身的
// pongTimeoutMs 也是 60 秒，两侧同口径。死链最迟 90 秒回收。
const (
	DefaultHeartbeat        = 30 * time.Second
	DefaultHeartbeatTimeout = 60 * time.Second
	DefaultWriteTimeout     = 10 * time.Second
	// DefaultControlQueueDepth 是中转控制帧优先队列的深度。
	//
	// 它只装不依赖数据帧顺序、且都很小的控制帧（pong/ping/hostStatus/accountState/
	// deviceAttach/deviceDetach）：一帧 32 MiB 的响应或一串流式帧不能把它们挤到
	// 后面（2026-10-23 生产回滚的直接原因）。64 槽足够覆盖一次重连要补发的
	// deviceAttach/deviceDetach。error 与 fs* 为了与数据帧保序走大队列，
	// 见 dlp.IsOrderedControl。
	DefaultControlQueueDepth = 64
	// DefaultControlWait 是必达控制帧在优先队列满时的等待上限（DESIGN §5.1）。
	// 超过就以 4008 断开：对端已经读不动了，再等只会让内存继续涨。
	DefaultControlWait = 5 * time.Second
	// maxCloseReason 是 WebSocket 关闭原因的上限（协议规定 123 字节，留 3 字节余量）。
	maxCloseReason = 120
	// streamDropAlertThreshold 是流式帧丢弃的告警窗口：一条连接累计丢满这个数
	// 才报一次（onStreamDrop），避免每帧一条日志把告警通道淹没。
	streamDropAlertThreshold = 100
)

// heartbeatKind 决定一条连接的活性证据从哪里来。
type heartbeatKind int

const (
	// heartbeatWebSocket 由 watchdog 发 WS 控制帧 ping 并等 pong（设备链路）。
	//
	// 设备侧（iOS）只实现 WS 层 ping/pong，DLP 的 ping 在它的读循环里被忽略
	// （LinkCarrier 的 "pong", "ping" 分支），所以不能拿 DLP pong 当活性证据。
	heartbeatWebSocket heartbeatKind = iota
	// heartbeatDLP 由写循环把 DLP ping 帧放进控制队列，读循环记下 pong 的时刻；
	// 连接器（plugins/mobile-link）会原样回 pong。这是连接器链路的心跳方式。
	heartbeatDLP
)

// Link 是一条连接：一个有界发送队列 + 一个写循环。
//
// 写只由写循环执行；其他 goroutine 只能 enqueue。这条规则是中转不会出现"两个
// goroutine 同时写一条 socket"的唯一保证。
type Link struct {
	label string
	sink  Sink
	log   *slog.Logger
	// out 是流式帧、业务控制帧与保序控制帧（error/fs*）的大队列；
	// control 是不依赖数据帧顺序的控制帧小优先队列。写循环永远先取 control。
	out     chan *outbound
	control chan *outbound
	done    chan struct{}

	egress  atomic.Int64
	dropped atomic.Int64
	// queuedBytes 是 out 里还没写出去的帧字节数；byteLimit 是它的上限（见 Enqueue）。
	// control 里的帧不进这份账：它由深度约束，字节都很小，而且把它们算进来会让
	// "流式帧把优先队列挤慢"重新变成可能。
	queuedBytes atomic.Int64
	byteLimit   int64

	// connectedAt 是这条连接建立（Link 构造）的时刻：断开日志的 duration 与
	// /debug/conns 的 connectedAt 都取它，不另记一份。
	connectedAt time.Time

	// remote 是 socket 对端地址（由 wsapi 在升级成功后写入；单测的桩 Sink 没有
	// 地址，读出来是空串）。lastError 是这条连接上最后一次传输错误，回答
	// "它为什么断了"；两者都由读/写循环写，诊断面只读。
	remote    atomic.Pointer[string]
	lastError atomic.Pointer[string]

	// controlDrops 是这条连接被丢弃的可丢控制帧数（/debug/conns 的逐连接计数）；
	// 进程级总数在 hub.controlDrops，两者同源：都来自 noteControlDrop。
	controlDrops atomic.Int64

	// streamDrops 是流式帧丢弃的告警窗口计数：累计到 streamDropAlertThreshold
	// 就经 onStreamDrop 报一次并重新开窗（dropped 是总量，只进计数器与 /stats，
	// 静默丢满一窗在运维上不可见——2026-10-23 故障的盲区）。
	streamDrops atomic.Int64

	// closeCode/closeReason 是这条连接被要求以什么方式关闭（第一个请求说了算），
	// 断开日志要回答"4001 还是 1001"。
	closeCode   atomic.Int32
	closeReason atomic.Pointer[string]
	// credits 是**文件上行桥**的字节额度（只有连接器链路有）。它约束的是那类
	// 不可丢的 ClassControl 分片：它们绕过 byteLimit，所以必须另有一份账。
	credits *bridge.Credits

	heartbeat        time.Duration
	heartbeatTimeout time.Duration
	writeTimeout     time.Duration
	// controlWait 是必达控制帧在 control 满时的有界等待上限。
	controlWait time.Duration
	// onControlDrop 在可丢控制帧被丢弃时调用（hub 用它累计 /stats 的 controlDrops
	// 与 monitor 的 backpressure:control 告警）。nil = 只丢不记（单测直接建 Link）。
	onControlDrop func(link *Link, frameType string)
	// onStreamDrop 在一条连接的流式帧丢弃满一个告警窗口时调用（hub 记 WARN 并经
	// monitor 记 backpressure:stream）。nil = 只丢不记。
	onStreamDrop func(link *Link, dropped int64)

	// 心跳状态。三者都是原子值：写循环写 pingOutstandingAt，读循环写 lastPongAt /
	// lastInboundAt，watchdog 只读。
	heartbeatKind heartbeatKind
	// lastPongAt 是最后一次收到 pong 的时刻（UnixNano）。
	lastPongAt atomic.Int64
	// lastInboundAt 是最后一次收到对端**任意**帧的时刻，用于兼容旧连接器：
	// 它们可能不回答中转的 DLP ping，但会照常发业务帧与自己的 ping。
	lastInboundAt atomic.Int64
	// pingOutstandingAt 是"已经入队、还在等回答"的那个 ping 的发出时刻（UnixNano）。
	// 0 表示没有待回答的 ping。
	pingOutstandingAt atomic.Int64

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
	// stopLoop 取消写循环与 watchdog 的上下文；心跳判定对端已死时由 abort 调用。
	// 它不改写 HTTP 请求自己的 ctx——读循环要自己从 socket 错误里收尾。
	stopLoop context.CancelFunc
}

// newLink 建一条连接；depth 是流式大队列的深度，byteLimit 是它的字节上限。
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
		connectedAt:      time.Now(),
		log:              log,
		out:              make(chan *outbound, depth),
		control:          make(chan *outbound, DefaultControlQueueDepth),
		byteLimit:        byteLimit,
		done:             make(chan struct{}),
		heartbeat:        options.heartbeat,
		heartbeatTimeout: options.heartbeatTimeout,
		writeTimeout:     options.writeTimeout,
		controlWait:      options.controlWait,
		onControlDrop:    options.onControlDrop,
		onStreamDrop:     options.onStreamDrop,
	}
}

// linkOptions 是全部连接共用的心跳/超时设置。
type linkOptions struct {
	heartbeat        time.Duration
	heartbeatTimeout time.Duration
	writeTimeout     time.Duration
	// controlWait 是必达控制帧在优先队列满时的等待上限；零值取 DefaultControlWait。
	controlWait time.Duration
	// onControlDrop 是可丢控制帧被丢弃时的记账回调（hub 注入）。
	onControlDrop func(link *Link, frameType string)
	// onStreamDrop 是流式帧丢弃满一个告警窗口时的回调（hub 注入）。
	onStreamDrop func(link *Link, dropped int64)
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
	if o.controlWait <= 0 {
		o.controlWait = DefaultControlWait
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
		loopCtx, stop := context.WithCancel(ctx)
		l.stopLoop = stop
		go l.writeLoop(loopCtx)
		go l.watchdog(loopCtx)
	})
}

// Label 是日志里的连接标识（`device <id>` / `agent <id>`）。
func (l *Link) Label() string { return l.label }

// Enqueue 把一条待写消息放进**流式大队列**。
//
// 队列满时按帧类型分流：流式帧丢弃并计数（DESIGN §5.1），其余帧（业务控制帧、
// 文件分片）返回 Overloaded，由调用方断开这条连接——这些帧静默丢失比断线更难排查。
//
// 中转自己发出的控制帧不要走这里，走 EnqueueControl：它们有独立的小优先队列。
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
func (l *Link) EnqueueWithCredit(payload []byte, class Class, credit *bridge.Credits,
	creditBytes int64) EnqueueResult {
	if credit == nil || creditBytes <= 0 {
		return l.Enqueue(payload, class, nil)
	}
	return l.enqueue(payload, class, nil, credit, creditBytes)
}

func (l *Link) enqueue(payload []byte, class Class, owned *dlp.Buffer,
	credit *bridge.Credits, creditBytes int64) EnqueueResult {
	if l.closing.Load() {
		return Overloaded
	}
	size := int64(len(payload))
	if class == ClassStream && size <= l.byteLimit {
		// 字节上限是硬界：先 CAS 预留再入队。读-判-加分两步会让并发入队瞬时越过
		// byteLimit（两个 goroutine 同时读到没超，各自 Add 之后总量超标）。
		for {
			used := l.queuedBytes.Load()
			if used > 0 && used+size > l.byteLimit {
				l.dropped.Add(1)
				l.noteStreamDrop()
				return FrameDropped
			}
			if l.queuedBytes.CompareAndSwap(used, used+size) {
				break
			}
		}
	} else {
		l.queuedBytes.Add(size)
	}
	item := &outbound{payload: payload, owned: owned, credit: credit, creditBytes: creditBytes,
		counted: true}
	select {
	case l.out <- item:
		return Enqueued
	default:
		// 入队失败：归还刚才记下的字节；payload 的所有者（owned）与额度仍归调用方，
		// 两者都由它归还。
		l.queuedBytes.Add(-size)
	}
	if class == ClassStream {
		l.dropped.Add(1)
		l.noteStreamDrop()
		return FrameDropped
	}
	return Overloaded
}

// EnqueueControl 把一帧**中转自己发出的控制帧**放进发送通道。
//
// 通道按帧是否依赖数据帧顺序分两类（见 dlp.IsOrderedControl）：
//   - 心跳/生命周期/状态通知（pong/ping/hostStatus/accountState/deviceAttach/
//     deviceDetach）走独立的小优先队列，写循环永远先取它：一帧 32 MiB 的响应或
//     一串流式帧不能把它们挡在后面（2026-10-23 的故障形态）。
//   - error 与文件通道 fs* 走流式大队列，与它们所属的 res/item/fsPutChunk 保持
//     入队顺序；它们同样优先于流式帧排队是做不到的，先发结束帧只会让客户端在
//     数据之前看到"结束"。但它们仍然必达：队列满时有界等待，而不是静默丢。
//
// droppable 为 true 的帧（pong/ping/hostStatus/accountState）在队列满时直接丢弃，
// 经 onControlDrop 计数并告警，连接继续用；
// droppable 为 false 的帧（deviceAttach/deviceDetach/error/fs*）在队列满时最多等
// controlWait 让写循环腾出位置，仍进不去才返回 Overloaded，由调用方以 4008 断开。
func (l *Link) EnqueueControl(payload []byte, frameType string, droppable bool) EnqueueResult {
	if l.closing.Load() {
		return Overloaded
	}
	if dlp.IsOrderedControl(frameType) {
		return l.enqueueOrderedControl(payload, frameType, droppable)
	}
	item := &outbound{payload: payload}
	select {
	case l.control <- item:
		return Enqueued
	default:
	}
	if droppable {
		l.noteControlDrop(frameType)
		return FrameDropped
	}
	timer := time.NewTimer(l.controlWait)
	defer timer.Stop()
	select {
	case l.control <- item:
		return Enqueued
	case <-l.done:
		// 写循环已经退出：不会有人再来取这帧，等满 5 秒只是拖慢收尾。
		return Overloaded
	case <-timer.C:
		return Overloaded
	}
}

// enqueueOrderedControl 把保序控制帧放进流式大队列（不计 byteLimit，但计字节）。
func (l *Link) enqueueOrderedControl(payload []byte, frameType string, droppable bool) EnqueueResult {
	size := int64(len(payload))
	l.queuedBytes.Add(size)
	item := &outbound{payload: payload, counted: true}
	if droppable {
		select {
		case l.out <- item:
			return Enqueued
		default:
			l.queuedBytes.Add(-size)
			l.noteControlDrop(frameType)
			return FrameDropped
		}
	}
	timer := time.NewTimer(l.controlWait)
	defer timer.Stop()
	select {
	case l.out <- item:
		return Enqueued
	case <-l.done:
		l.queuedBytes.Add(-size)
		return Overloaded
	case <-timer.C:
		l.queuedBytes.Add(-size)
		return Overloaded
	}
}

// noteControlDrop 记一次可丢控制帧的丢弃；回调由 hub 注入（单测里可以为 nil）。
//
// 逐连接计数先记，再交给 hub 记进程级总数：/debug/conns 与 /stats 的
// controlDrops 是同一件事的两个粒度，不是两份口径。
func (l *Link) noteControlDrop(frameType string) {
	l.controlDrops.Add(1)
	if l.onControlDrop != nil {
		l.onControlDrop(l, frameType)
	}
}

// noteStreamDrop 记一次流式帧丢弃；累计满一个告警窗口（streamDropAlertThreshold）
// 才回调一次并重新开窗，回调由 hub 注入（单测里可以为 nil）。
//
// 计数窗口只用来压告警频率，不是 /stats 的口径：总量永远是 l.dropped。
// 并发下两个 goroutine 可能同时越过阈值，CAS 保证只有抢到归零的那个负责上报。
func (l *Link) noteStreamDrop() {
	window := l.streamDrops.Add(1)
	if window < streamDropAlertThreshold {
		return
	}
	if l.streamDrops.CompareAndSwap(window, 0) && l.onStreamDrop != nil {
		l.onStreamDrop(l, window)
	}
}

// SetRemote 记下 socket 对端地址（wsapi 在升级成功后调用）。
func (l *Link) SetRemote(addr string) {
	text := strings.TrimSpace(addr)
	l.remote.Store(&text)
}

// Remote 是对端地址；没设置过时是空串。
func (l *Link) Remote() string {
	if pointer := l.remote.Load(); pointer != nil {
		return *pointer
	}
	return ""
}

// NoteError 记下这条连接上最后一次传输错误（正常关闭不是错误，不要记）。
func (l *Link) NoteError(err error) {
	if err == nil {
		return
	}
	text := err.Error()
	l.lastError.Store(&text)
}

// LastError 是最后一条传输错误的文本；没有错误时是空串。
func (l *Link) LastError() string {
	if pointer := l.lastError.Load(); pointer != nil {
		return *pointer
	}
	return ""
}

// ConnectedAt 是这条连接挂上的时刻。
func (l *Link) ConnectedAt() time.Time { return l.connectedAt }

// Lifetime 是连接存活时长（断开日志与 /debug/conns 用同一个算法）。
func (l *Link) Lifetime() time.Duration { return time.Since(l.connectedAt) }

// ControlDrops 是这条连接上被丢弃的可丢控制帧数。
func (l *Link) ControlDrops() int64 { return l.controlDrops.Load() }

// QueueDepth 是队列里还没写出去的帧数（流式 + 控制；诊断面用）。
func (l *Link) QueueDepth() int { return l.Pending() }

// CloseInfo 返回这条连接被要求的关闭码与原因；还没要求关闭时是 (0, "")。
func (l *Link) CloseInfo() (int, string) {
	reason := ""
	if pointer := l.closeReason.Load(); pointer != nil {
		reason = *pointer
	}
	return int(l.closeCode.Load()), reason
}

// LastInboundAge 是距离最后一次入站帧的时长；从未收到过时返回 0。
func (l *Link) LastInboundAge() time.Duration {
	last := l.LastInbound()
	if last.IsZero() {
		return 0
	}
	return time.Since(last)
}

// NoteInbound 由读循环在收到对端任意一帧时调用。
//
// 它只用于心跳判定"对端还活着"：旧连接的连接器可能不回答中转的 DLP ping，
// 但会照常发业务帧与自己的 ping，这类链路不该被误判为失联。
func (l *Link) NoteInbound() {
	l.lastInboundAt.Store(time.Now().UnixNano())
}

// LastInboundMS 是最后一次入站时刻的 Unix 毫秒；从未收到过时是 0。
//
// 日志与 /debug/conns 都取它：零值时刻直接 UnixMilli() 会得到负数（公元 1 年），
// 运维不该看到那个数字。
func (l *Link) LastInboundMS() int64 {
	last := l.LastInbound()
	if last.IsZero() {
		return 0
	}
	return last.UnixMilli()
}

// LastInbound 是最后一次收到对端任意一帧的时刻；从未收到过时为零值。
//
// 连接生命周期策略用它区分「还活着的旧连接」与「僵死的旧连接」：后者可以被新
// 连接顶替，前者不许（顶替一个仍在工作的连接正是重连风暴的成因）。
func (l *Link) LastInbound() time.Time {
	value := l.lastInboundAt.Load()
	if value == 0 {
		return time.Time{}
	}
	return time.Unix(0, value)
}

// NotePong 由读循环在收到 DLP pong 时调用：这是心跳最直接的活性证据。
func (l *Link) NotePong() {
	now := time.Now().UnixNano()
	l.lastPongAt.Store(now)
	l.lastInboundAt.Store(now)
	l.pingOutstandingAt.Store(0)
}

// LastPong 是最后一次收到 pong 的时刻；没有收到过时为 0（诊断用）。
func (l *Link) LastPong() time.Time {
	value := l.lastPongAt.Load()
	if value == 0 {
		return time.Time{}
	}
	return time.Unix(0, value)
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
	reason = truncateReason(reason)
	// 关闭原因属于"谁先要求关闭谁说了算"：心跳超时与顶替可能同时发生，
	// 日志要记的是先到达的那个决定，而不是最后覆盖的那个。
	l.closeCode.CompareAndSwap(0, int32(code))
	l.closeReason.CompareAndSwap(nil, &reason)
	if !l.closing.CompareAndSwap(false, true) {
		return
	}
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

// Pending 是队列里还没写出去的帧数（/stats 的 pending）：流式大队列 + 控制优先队列。
func (l *Link) Pending() int { return len(l.out) + len(l.control) }

// EgressBytes 是这条连接写出的字节数。
func (l *Link) EgressBytes() int64 { return l.egress.Load() }

// DroppedFrames 是流式帧因背压被丢弃的数量。
func (l *Link) DroppedFrames() int64 { return l.dropped.Load() }

// writeLoop 是唯一写 socket 的 goroutine。
//
// 心跳不再在这里等 pong：DLP 心跳只是"按周期把 ping 帧放进优先队列"，写一帧 ping
// 与写一帧 pong 一样是普通发送；等 pong 由 watchdog 在另一条 goroutine 里做。
// 2026-10-23 的故障就是这里调 conn.Ping 同步等 pong，最长 10 秒不消费发送队列。
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
	// 计时器只在**一次写**进行期间有效：空闲 10 秒不代表连接坏了。不在这里停掉的话，
	// 它会在连接建立 10 秒后无条件取消写上下文，下一次写（例如 20 秒时回答连接器
	// 的 ping）立刻失败，整条链路被误杀——2026-10-23 本地复现时看到的 20 秒断开
	// 就是这条路径。每次 write() 之前 Reset、之后 Stop。
	l.writeTimer.Stop()
	defer l.writeTimer.Stop()

	for {
		// 控制帧优先：先非阻塞地把优先队列取空，再进入阻塞选择。这样即使大队列
		// 里已经排着一串流式帧，下一帧被写的也一定是控制帧。
		select {
		case item := <-l.control:
			if !l.handleOutbound(item, ctx) {
				return
			}
			continue
		default:
		}
		select {
		case item := <-l.control:
			if !l.handleOutbound(item, ctx) {
				return
			}
		case item := <-l.out:
			if !l.handleOutbound(item, ctx) {
				return
			}
		case <-ticker.C:
			if l.heartbeatKind == heartbeatDLP {
				l.enqueueHeartbeatPing()
			}
		case <-ctx.Done():
			return
		}
	}
}

// handleOutbound 写一条已出队的消息；返回 false 表示写循环应当退出。
func (l *Link) handleOutbound(item *outbound, ctx context.Context) bool {
	// 出队即不再占大队列的字节；缓冲要等真正写出去才归还。
	if item.counted {
		l.queuedBytes.Add(-int64(len(item.payload)))
	}
	if item.closeCode != 0 {
		item.release()
		l.closeSink(item.closeCode, item.closeReason)
		return false
	}
	if l.pace != nil {
		if err := l.pace(ctx, len(item.payload)); err != nil {
			item.release()
			return false
		}
	}
	wrote := l.write(ctx, item.payload)
	item.release()
	return wrote
}

// enqueueHeartbeatPing 把一个 DLP ping 放进优先队列，**不等回答**。
//
// 帧的 ts 由连接器原样带回 pong，可以用来量这条链路的往返；这里只关心"发出了
// 一个还需要回答的 ping"，回答由 watchdog 检查。
func (l *Link) enqueueHeartbeatPing() {
	if l.closing.Load() {
		return
	}
	now := time.Now()
	payload, err := dlp.Encode(dlp.Ping(now.UnixMilli()))
	if err != nil {
		return
	}
	if l.EnqueueControl(payload, "ping", true) != Enqueued {
		return
	}
	// 只保留最早的那个待回答 ping：后面的 ping 覆盖截止时间会让真正的失联晚发现。
	l.pingOutstandingAt.CompareAndSwap(0, now.UnixNano())
}

// watchdog 是心跳判定，独立于写循环：写一帧大响应要 10 秒时，它仍然按周期检查
// 对端有没有回答，不会被那次写挡住。
func (l *Link) watchdog(ctx context.Context) {
	if l.heartbeatKind == heartbeatDLP {
		l.watchDLPHeartbeat(ctx)
		return
	}
	l.watchWebSocketHeartbeat(ctx)
}

// watchDLPHeartbeat 检查 DLP ping 有没有回答。
//
// 判定口径：ping 入队后 heartbeatTimeout 内既没有 pong、也没有收到对端任何一帧，
// 就认为链路已死。把"任意帧"也算作进展是为了兼容旧连接器：它们可能不回答中转的
// DLP ping，但会照常发业务帧和自己的 ping；反过来，真正断网的链路什么都收不到。
func (l *Link) watchDLPHeartbeat(ctx context.Context) {
	interval := l.heartbeatTimeout / 4
	if interval < 5*time.Millisecond {
		interval = 5 * time.Millisecond
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case now := <-ticker.C:
			sent := l.pingOutstandingAt.Load()
			if sent == 0 {
				continue
			}
			// 收到 pong，或 ping 之后对端还发过别的帧：这条链路还活着。
			if l.lastPongAt.Load() >= sent || l.lastInboundAt.Load() > sent {
				l.pingOutstandingAt.CompareAndSwap(sent, 0)
				continue
			}
			if now.Sub(time.Unix(0, sent)) < l.heartbeatTimeout {
				continue
			}
			l.log.Warn("relay: heartbeat timed out, closing",
				"link", l.label, "timeout", l.heartbeatTimeout.String(),
				"silentFor", now.Sub(time.Unix(0, sent)).String(),
				"lastInbound", l.LastInboundMS(),
				"lastInboundAge", l.LastInboundAge().String(),
				"queueDepth", l.QueueDepth())
			l.abort(dlp.CloseGoingAway, "heartbeat timeout")
			return
		case <-l.done:
			return
		case <-ctx.Done():
			return
		}
	}
}

// watchWebSocketHeartbeat 是设备链路的活性检查：WS 控制帧 ping/pong。
//
// 设备侧只实现 WS 层 ping/pong（DLP 的 ping 在 iOS 读循环里被忽略），所以这里仍走
// socket 的心跳；但它运行在 watchdog goroutine 里，写循环不参与、不被它阻塞。
func (l *Link) watchWebSocketHeartbeat(ctx context.Context) {
	ticker := time.NewTicker(l.heartbeat)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			pingCtx, cancel := context.WithTimeout(ctx, l.heartbeatTimeout)
			err := l.sink.Ping(pingCtx)
			cancel()
			if err != nil {
				l.NoteError(err)
				l.log.Warn("relay: heartbeat failed, closing", "link", l.label,
					"error", err, "timeout", l.heartbeatTimeout.String(),
					"lastInbound", l.LastInboundMS(),
					"lastInboundAge", l.LastInboundAge().String(),
					"queueDepth", l.QueueDepth())
				l.abort(dlp.CloseGoingAway, "heartbeat timeout")
				return
			}
		case <-l.done:
			return
		case <-ctx.Done():
			return
		}
	}
}

// abort 立即关闭连接：心跳已经判定对端死亡，没必要再等队列排空。
//
// 只关 socket 不够：写循环可能正停在"等下一帧"上，对 socket 关闭毫无感知。
// 这里同时取消写循环/看门狗自己的上下文，让 Done() 准时关闭，读循环随后从
// socket 错误里收尾。
func (l *Link) abort(code int, reason string) {
	l.closing.Store(true)
	if l.stopLoop != nil {
		l.stopLoop()
	}
	l.closeSink(code, reason)
}

// drainQueue 把两个队列里剩下的帧缓冲归还给池；关停时最多被调用一次。
func (l *Link) drainQueue() {
	for {
		select {
		case item := <-l.out:
			l.releaseQueued(item)
		case item := <-l.control:
			l.releaseQueued(item)
		default:
			return
		}
	}
}

// releaseQueued 归还一条没写出去的消息占的计数与缓冲。
func (l *Link) releaseQueued(item *outbound) {
	if item.counted {
		l.queuedBytes.Add(-int64(len(item.payload)))
	}
	item.release()
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
		l.NoteError(err)
		// 写超时是"对端读不动了"的直接证据；只有计时器触发（closing 还没置位）
		// 才按超时记一条 WARN，正常关停导致的写入失败保持 Debug。
		if l.writeCtx != nil && l.writeCtx.Err() != nil && !l.closing.Load() {
			l.log.Warn("relay: write timed out; closing the link",
				"link", l.label, "error", err, "timeout", l.writeTimeout.String(),
				"queueDepth", l.QueueDepth(), "queuedBytes", l.QueuedBytes(),
				"lastInboundAge", l.LastInboundAge().String())
		} else {
			l.log.Debug("relay: write failed", "link", l.label, "error", err)
		}
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

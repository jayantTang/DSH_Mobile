import DSHConnectionAPI
import DSHCore
import DSHFoundation
import DSHKit
import Foundation
import Observation
import RelayKit

/// Drives one session transcript: history, the live stream, and outbound input.
@MainActor
@Observable
public final class ChatModel {

    public init() {}

    public enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// 一次发布的会话可见状态：**开的是哪个会话**与**屏幕上那批行**是同一个值。
    ///
    /// 为什么要合成一个值：这两件事分开存、分两次发布时，界面有一次渲染机会落在
    /// "开的是 B、行还是 A"的中间态上——2026-10-16 用户报的"新建会话先闪一下旧会话"
    /// 就是它（`open()` 里 `session` 与 `timeline` 的赋值中间隔了两次磁盘等待）。
    /// 合成一个值之后，这个中间态在类型上就写不出来。
    public struct VisibleSession {
        public var summary: SessionSummary
        public var timeline: ChatTimeline

        public init(summary: SessionSummary, timeline: ChatTimeline) {
            self.summary = summary
            self.timeline = timeline
        }
    }

    /// 唯一被发布的会话可见状态。
    ///
    /// **换会话时只在这里赋值一次**，且这次赋值之前不得有 `await`（先把旧会话要落盘的
    /// 东西同步脱离出来，落盘的等待排在发布之后）。其余对时间线的改动都落在同一个
    /// `summary` 之下，因此任何一次发布都是自洽的一对。
    public private(set) var visible: VisibleSession?

    /// 现在开的是哪个会话（读 `visible`）。
    public var session: SessionSummary? { visible?.summary }

    /// 屏幕上这批行（读 `visible`）。
    ///
    /// 注意：**不要**用它判断"这些行是不是这一屏的"——判断用 `rowsFor(screen:)`。
    public private(set) var timeline: ChatTimeline {
        get { visible?.timeline ?? ChatTimeline() }
        set { visible?.timeline = newValue }
    }

    /// 这一屏该画哪些行：**只有这批行属于这一屏时才交出去**。
    ///
    /// 渲染（`ChatView`）与量具（`StaleRenderWatch`）都读这一个入口，因此
    /// "屏幕上画了什么"与"判定量到什么"永远是同一件事。换会话期间、以及任何
    /// "行属于别的会话"的时刻，这里返回空——界面不会把上一个会话的内容画出来。
    public func rowsFor(screen sessionId: String) -> [TimelineItem] {
        guard let visible, visible.summary.sessionId == sessionId else { return [] }
        return visible.timeline.items
    }

    public private(set) var phase: Phase = .idle
    /// What the agent is doing right now.
    ///
    /// This has to come from the turn events on the session's own follow
    /// stream. An earlier version listened for them on the forwarded host event
    /// feed, which never carries them — so the state latched on at send time and
    /// the stop button stayed on screen forever, even after the run finished.
    public enum Activity: Equatable {
        case idle
        /// A prompt this phone sent has been accepted, but no turn has started.
        case submitting
        /// The host reported a turn in progress.
        case running
    }

    public var activity: Activity {
        if timeline.isTurnOpen { return .running }
        if isAwaitingTurnStart { return .submitting }
        return .idle
    }

    /// True only while a turn is genuinely in flight.
    public var isRunning: Bool { activity == .running }

    /// Whether a stop control should be offered at all.
    public var isBusy: Bool { activity != .idle }

    /// The most recent completed turn, used to announce the end of a run.
    public private(set) var completion: ChatTimeline.Completion?

    /// Bumped whenever a run finishes, so the view can flash a confirmation.
    public private(set) var completionSignal: Int = 0

    /// Streaming chunks waiting to be folded into the transcript.
    private var pendingStreamFrames: [AssistantStreamFrame] = []
    private var streamFlushTask: Task<Void, Never>?

    /// How often coalesced stream frames are folded in.
    ///
    /// Eight times a second is smoother than the tokens arriving and roughly an
    /// order of magnitude cheaper than folding each one.
    private static let streamFlushInterval = Duration.milliseconds(120)

    /// A picture chosen for the next prompt, held until it is sent.
    ///
    /// The bytes are carried as base64 because that is the only door a picture
    /// has into a session: the Host promotes inline prompt images to durable
    /// attachments, and the attachment service itself is read-only.
    ///
    /// 025 阶段4b：`preview` 是**不透明句柄**（iOS 上是 `UIImage`），领域层不认识它，
    /// 也不认识 UIKit（边界契约 C2、且 `swift build` 要在 macOS 上过）。位图由界面层
    /// 在加入时造好（`ChatModel.addDraftImages(_:names:)` 在 DSHChatUI 里），
    /// 只有 `Composer` 的那一个缩略图会读它。
    public struct DraftImage: Identifiable {
        public let id = UUID()
        public let mediaType: String
        public let base64: String
        public let name: String
        public let preview: AnyObject

        public init(mediaType: String, base64: String, name: String, preview: AnyObject) {
            self.mediaType = mediaType
            self.base64 = base64
            self.name = name
            self.preview = preview
        }
    }

    /// Pictures queued in the composer, sent with the next prompt.
    public private(set) var draftImages: [DraftImage] = []

    /// Name of the file being uploaded, for the composer to show.
    public private(set) var isUploadingFile: String?

    /// Set between submitting a prompt and the host starting its turn.
    private var isAwaitingTurnStart = false
    /// The host's own view of whether it is running, from the session summary.
    private var hostReportsRunning = false
    private var awaitingTimeout: Task<Void, Never>?
    private var lastSeenCompletionAt: Date?
    /// True while older history is being fetched.
    public private(set) var isLoadingOlder = false
    /// 视图只读这两位的投影；真正的状态在 `pager` 里（FR-005/FR-038）。
    public private(set) var hasOlder = false
    /// 失败后的一次自动补试（FR-004 的"继续能恢复"）。
    ///
    /// 为什么必须有一次：失败之后读者往往就停在顶部不动了——哨兵行没有重建就不会再
    /// `onAppear`，滚动几何也没有"变化"可报（2026-10-08 用例 48 实测：失败后再怎么送
    /// 视口上去都不再重试）。只补试**一次**，不做循环：持续的坏链路交给读者点重试条。
    private var autoRetryTask: Task<Void, Never>?
    private var didAutoRetry = false
    /// 宿主权威的"还有更早"：只由快照与 pager 的观察更新，失败绝不改它（FR-003）。
    private var hostHasMore = true
    /// 最近一次取页失败的原因；顶部据此显示可点的重试条（FR-004/FR-007）。
    public private(set) var olderFailure: String?
    public private(set) var lastError: String?

    /// Model routes the host can serve.
    ///
    /// Refreshed rather than loaded once: the desktop can add a provider route
    /// (a company gateway, a second vendor) while the phone is open, and waiting
    /// for an app restart to see it made the picker look like it was missing
    /// models it could actually use.
    public private(set) var catalog: ModelCatalog?
    /// When `catalog` was last read, so opening the picker can decide to re-read.
    private var catalogFetchedAt: Date?
    /// How long a catalog stays fresh.
    private static let catalogMaxAge: TimeInterval = 300
    /// True while the "make this the default for new sessions" write is in flight.
    public private(set) var isSettingDefaultModel = false
    /// Set when that write failed, so the picker can say why.
    public private(set) var defaultModelError: String?
    public private(set) var currentSelection: ModelSelection?
    public private(set) var permissionOptions: [PermissionsProjection.Option] = []
    public private(set) var currentPermission: String?

    /// Composer state.
    public var draft: String = ""
    /// Whether the next submission queues behind the turn or steers into it.
    public var steerNext: Bool = false

    /// Bumped whenever the transcript grows, so the view can autoscroll.
    public private(set) var scrollSignal: Int = 0
    /// 搜索范围（时间线 + 搜索缓冲）变了多少次，给搜索面板当刷新信号。
    public private(set) var searchScopeVersion: Int = 0
    /// 正在往前取搜索缓冲（面板据此显示转圈）。
    public private(set) var isExtendingSearch = false
    /// 补页（在时间线**头部**插入更早的消息）完成的次数。
    ///
    /// 要这一位是因为"追上尾部"和"往前补一页"必须分开：前者该钉到底部，后者
    /// 一次都不能动视口。以前补页也发 `scrollSignal`，于是读者刚翻到上面、跟随
    /// 状态还没被判成"用户自己在滚"的时候，补回来的一页会把人拽回底部；
    /// 而新插入的内容本身又会把视口顶到"新那段的开头"（2026-09-24 用户反馈）。
    /// 现在由视图自己按 `timeline.items.first` 把位置锚回来，见 `ChatView.pumpOlder`。
    public private(set) var prependSignal: Int = 0
    /// Bumped when the user themselves adds something, which is the one case
    /// where the view should jump back to the bottom even if they had scrolled
    /// away: they are waiting to see their own message land.
    public private(set) var sendSignal: Int = 0

    /// internal(set)：ChatModel+Follow 的可见性兜底要读 client（T019）。
    public private(set) var store: (any LinkService)?
    private var hub: HostEventHub?
    /// 009 消息层（T012：MessageStore 有数据时优先用它画进会话首帧）。
    /// internal：冷启动半边在 ChatModel+ColdStart.swift（文件按职责拆分）。
    public weak var messageLayer: MessageLayer?
    /// Warm transcripts, most recently used last.
    private var cache: [String: CachedSession] = [:]

    /// 搜索时往前读进来、但**还没进时间线**的更早记录（由旧到新）。
    ///
    /// 为什么不让搜索直接调 `loadOlder()`：那会往时间线头部插内容，而读者此刻可能停在
    /// 会话中间或底部——`List` 保留的是偏移量，插进去的高度会把读者正在看的那一段整体
    /// 挪走（`anchorAfterPrepend` 只在"视口就在顶部"时锚得回来）。搜索时往前翻历史
    /// 不该动读者的位置，所以先放这里；等读者真的点了某一条，再把这段并进时间线
    /// （`commitSearchHistory`），紧接着的跳转会把视口带到那一条上。
    private var searchRecords: [SessionRecord] = []
    private var searchOldestSeq: Int?
    /// `searchItems` 的结果缓存，键是"缓冲条数 + 时间线条数"。
    private var cachedSearchItems: (key: String, items: [TimelineItem])?

    /// 转写尾部的落盘层（T027：007 `TranscriptStore` 退役，统一到 009 `MessageStore`）。
    ///
    /// 内存缓存让"再进同一个会话"很快，但 App 一冷启动就归零，于是打开会话仍然是
    /// 空白 + 转圈。落盘的是**原始记录**的尾部——和 `session/follow` 打开时给的快照
    /// 是同一种东西，所以恢复路径与合并路径都复用现成逻辑。
    /// 磁盘层缺位（建库失败）时读写一律空转，行为退化为"只有内存缓存"。
    /// 磁盘层的入口。**不再直接持 `MessageStore`**：读写都走门面（`MessageLayer`），
    /// 实现层的类型名不出现在产品路径里（spec 023 边界收敛）。
    private var messageBacking: MessageLayer? { messageLayer }
    /// 落盘尾部保留多少条（沿用 007 `SessionTranscriptCache.maxRecords` 的值）。
    private static let tailRecordLimit = 200
    /// 搜索缓冲一次从磁盘读多少条（沿用 007 `maxOlderRecords` 的值）。
    private static let searchBufferDiskLimit = 3000
    /// Writes are chained instead of fired in parallel: an actor serializes them,
    /// but *creation* order is what keeps "the newer page wins" true. Awaiting the
    /// chain is how a flush is expressed.
    private var writeChain: Task<Void, Never>?

    /// 最近的记录（尾部），落盘写的就是它。
    private var recentRecords: [SessionRecord] = []
    private var lastDiskSave = Date.distantPast
    /// 距上次落盘又攒了多少条（够了就写，不等计时器）。
    private var unsavedRecords = 0
    /// 用户刚清过缓存：在重新打开一个会话之前不要再写。
    private var persistSuspended = false

    /// 用户最后想看、但可能还没连上而没能打开的会话。
    private var pendingOpen: SessionSummary?

    /// 打开这个会话时属于哪台电脑。
    ///
    /// 不能在落盘那一刻现取 `store.scopeId`：切换/断开时 profile 已经被清掉或换成
    /// 新电脑了，旧电脑的尾部会落到 `unknown/` 或**新电脑**的目录里——两台电脑的
    /// 会话 id 本来就可能撞（fork/clone），那就是把 A 的记录当成 B 的显示。
    public private(set) var sessionScope: String?

    /// 「我问过的」按需灌库是否正在进行（面板切到该筛选时会触发一次，见 `+UserInputs`）。
    public var isBackfillingUserInputs = false

    /// 这次打开用的同步计划（快照到达时还要用它判断合并还是重来）。
    private var syncPlanRef = TranscriptSyncPlan.plan(localThrough: nil, hostCursor: 0)

    /// Half-written messages, one per session.
    ///
    /// The draft used to be a single field on this (single, app-wide) model, and
    /// switching sessions never reset it: text typed for one conversation showed
    /// up in the next one's composer, and pressing send there posted it — the
    /// host stores a prompt against the session id of the moment, so from the
    /// receiving side it looked like an instruction the user never gave.
    private var drafts: [String: Draft] = [:]

    public struct Draft {
        public var text: String = ""
        public var images: [DraftImage] = []

        /// 测试与外部构造入口（memberwise init 对 public struct 是 internal，026 补齐）。
        public init(text: String = "", images: [DraftImage] = []) {
            self.text = text
            self.images = images
        }

        public var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
        }
    }
    private var cacheOrder: [String] = []
    private static let cacheLimit = 6
    /// 内存里最多留多少行；超出的从最老端丢（记录仍在库里，可读回）。
    private static var windowLimitRows: Int {
        #if DEBUG
        if let override = ChatProbe.shared.windowRows, override > 0 { return override }
        #endif
        return 5000
    }
    /// 一次本地读回最多补多少条。
    private static let windowBackfillLimit = 60
    private var followTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// 会话代数：每次 `open` 自增，**存活的流必须带自己那一代**。
    ///
    /// 为什么要有它：流的归属原先只靠"换会话时 cancel 上一条 Task"保证，而 `open()` 中间有
    /// 多次 await——两次 open 交错时，后一次会覆盖 `followTask` 引用，前一条流从此没人 cancel，
    /// 它的帧会落进**新会话**的时间线，并且按当前会话写盘（用户看到的就是"会话末尾混进别的
    /// 会话的内容，而新载入出现在它前面"：脏行带着旧会话更大的 seq，永远排在最后）。
    private(set) var openGeneration = 0
    /// 已经被尾巴污染、做过一次自愈的会话（防抖：一个会话一次运行最多清理一次）。
    private var selfHealedSessions: Set<String> = []

    #if DEBUG
    /// 用例注入：造一帧"上一个会话迟到的帧"（`-DSHProbeStaleFollowFrame`）。
    /// 注入的帧走**同一条守卫**（带陈旧代数），所以它既能证明"守卫在"，也能在守卫被删掉时判红。
    public var staleFrameInjector: (() -> SessionFollowFrame?)?

    /// **测试挂起点**（DEBUG-only，生产恒为 nil）：`open()` 在发布新的可见状态**之前**
    /// 让出主线程一次。
    ///
    /// 为什么必须有它：换会话的两次磁盘等待在单测环境里常常不成立（没有 messageLayer 时
    /// `loadStoredTail` 立即返回，写链也可能是空的），于是"切换中途"这个状态在单测里根本
    /// 抓不到——缺陷明明在，测试却只能看到一次原子切换。有了这个挂起点，用例可以停在
    /// "`open(B)` 已开始、可见状态还是 A"的那一刻，断言渲染入口不会把 A 的行交给 B 那一屏。
    /// 它只让出主线程，不做任何取舍；生产构建里这个属性不存在，也没有任何调用点。
    public var beforeVisibleSwap: (@MainActor () async -> Void)?
    #endif
    /// 取页游标状态机：每个会话一份，是全 App 唯一的"更早历史"状态来源。
    private var pager: TranscriptPager?
    /// 009 渲染数据源桥（tasks T013）：非 nil 时，时间线由 MessagePipeline 的
    /// 快照驱动（订阅/折叠/重试全在 ChatModel+Pipeline.swift 的桥里）；
    /// nil = 回退到自有 pager/fetcher/store 路径（管道不可用时不劣于现状）。
    public var pipelineBridge: ChatPipelineBridge?
    /// 009 跟底两态（tasks T017）：判定逻辑在 ChatModel+Follow.swift，
    /// 存储只能留在主文件（扩展不能有存储属性）。
    public enum FollowState: String { case atBottom, reading }
    /// 只允许 ChatModel+Follow 的迁移入口改写（Swift 没有"跨文件只读"，
    /// 写权限按模块内纪律约束）。
    public var followState: FollowState = .atBottom
    /// reading 期间到达的新消息数（「↓ 新消息」胶囊的未读数，T018）。
    public var unreadWhileReading = 0
    /// 尾部追平（点胶囊/可见性兜底）进行中：胶囊转 spinner，兜底去重（T018/T019）。
    public var isCatchingUpTail = false
    /// 可见性兜底的幂等闩（T019）：一次只跑一轮「对 lastSeq」。
    public var tailSyncInFlight = false
    /// 本地窗口的最老 seq（投影自 pager，供搜索缓冲与落盘使用）。
    private var oldestSeq: Int? { pager?.oldestLoadedSeq }
    /// DEBUG 故障注入：让前 N 次取页失败（`-DSHProbeFailPage <n>`）。
    private let pageFailures = PageFailureInjector(remaining: ChatProbe.shared.failPageAttempts)
    /// The cut the follow stream opened at; older pages must stay below it.
    private var throughSeq: Int = 0

    public var address: SessionAddress? { session?.address }

    /// Host prompts waiting for the human on this session.
    public var pendingPrompts: [HostEventHub.Pending] {
        guard let session, let hub else { return [] }
        return hub.pendingPrompts(for: session.sessionId)
    }

    // MARK: - Lifecycle

    public func attach(store: any LinkService, hub: HostEventHub) {
        self.store = store
        self.hub = hub
    }

    /// 注入 009 消息层（冷启动首帧与预取插队用，T011/T012）。
    public func attach(messageLayer: MessageLayer) {
        self.messageLayer = messageLayer
    }

    /// Opens a session: cached transcript first, then the live stream.
    ///
    /// A session the user has already looked at renders instantly from cache and
    /// refreshes underneath; only a first visit shows a spinner. Re-entering a
    /// conversation is the single most common navigation in this app, so it must
    /// not feel like a page load.
    public func open(_ summary: SessionSummary) async {
        // 换会话的第一件事：作废上一代 + 掐断上一条流。**必须在第一个 await 之前**——
        // 放到 `close()` 里不够：`close()` 自己也要 await（写盘/清缓存），两次 open 交错时
        // 上一条流会在窗口期失去 owner，继续往新会话里写。
        openGeneration &+= 1
        followTask?.cancel()
        followTask = nil
        stopPipelineSubscription()
        // 记下"用户想看的那个会话"：如果此刻还没连上（冷启动刚进列表就点开），
        // 这一屏会停在"尚未连接"——连上之后要能自己回来，而不是让用户点重试。
        pendingOpen = summary
        guard let link = store?.link, link.isConnected else {
            phase = .failed(String(localized: "尚未连接"))
            return
        }
        // ① **同步脱离**：把上一个会话要落盘的东西（转写尾部、草稿、内存缓存）用**旧 key**
        //    取出来，并把它的写链尾巴抓在手里稍后 await。这一步从前是 `await close()` 的一部分，
        //    而 `close()` 里那次等待（等写盘）正是"新会话那一屏先画出旧会话"的成因之一：
        //    可见状态要等它做完才换。现在等待排在发布之后，见 ③。
        let outgoing = detachForSwitch()

        let key = summary.sessionId
        sessionScope = scopeId == "unknown" ? nil : scopeId
        persistSuspended = false
        // 冷进入回到跟底默认态（T017：首帧贴底纪律在 ChatModel+ColdStart/T012）。
        noteFollowResetForOpen()
        // 这次跟 host 要多少条快照：本地尾部很新（差 ≤20 条）时只要 20 条就够对齐，
        // 少拉一遍重复数据；本地落后很多或没有本地缓存时按 60 条来，避免中间留洞。
        var syncPlan = TranscriptSyncPlan.plan(localThrough: nil, hostCursor: summary.asOfSeq)
        // 记录必须按会话隔离：带着上一个会话的 recentRecords 去写这个会话的文件，
        // 就是把 A 的内容盖到 B 上（用户看到的就是"记录丢了一部分"）。
        recentRecords = []
        lastDiskSave = .distantPast
        let cached = cache[key]
        // 换会话：更早历史的搜索缓冲属于上一个会话，任何分支都要清（FR-006）。
        // 以前只在"没有本地数据"那一支清，于是命中缓存/命中落盘时会把上一个会话
        // 的更早记录带进新会话，甚至能并进它的时间线。
        clearSearchHistory()
        olderFailure = nil
        // This session's own half-written message, not the last one's.
        draft = drafts[key]?.text ?? ""
        draftImages = drafts[key]?.images ?? []
        lastError = nil
        hostReportsRunning = summary.running
        isAwaitingTurnStart = false
        currentSelection = summary.projections?.values?.modelSelection?.next
            ?? summary.projections?.values?.modelSelection?.lastUsed
        permissionOptions = summary.projections?.values?.permissions?.options ?? []
        currentPermission = summary.projections?.values?.permissions?.currentValue
        // 分页状态同样归上一个会话：在读到这个会话的尾部之前先清掉，
        // 免得"向上翻页"拿着旧 pager 的游标去问新会话（跨会话取页）。
        pager = nil
        hasOlder = false

        #if DEBUG
        // 测试挂起点（DEBUG-only，生产恒为 nil）：在**发布点之前**让出主线程，
        // 让单测能停在"open(B) 已开始、可见状态还是 A"这一刻断言不变量。
        if let beforeVisibleSwap { await beforeVisibleSwap() }
        #endif

        // ② **一次发布**：开的是哪个会话与屏幕上那批行在这里一起换。
        //    从这里往下，任何时刻读到的都是一对自洽的 (summary, timeline)——
        //    "开的是 B、行还是 A"这个中间态在类型上已经写不出来（`VisibleSession`）。
        //    注意：这一段只能用局部的 `seed`，不得碰 `timeline`——此刻写它等于往
        //    上一个会话的时间线里写新会话的用量提示。
        var seed = cached?.timeline ?? ChatTimeline()
        seed.clearStreaming()
        seed.record(usage: summary.projections?.values?.tokenUsage)
        visible = VisibleSession(summary: summary, timeline: seed)
        if let cached {
            throughSeq = max(cached.throughSeq, summary.asOfSeq)
            installPager(sessionId: key, oldest: cached.oldestSeq, newest: throughSeq,
                         hasMore: cached.hasOlder)
            phase = .ready
            scrollSignal += 1
        } else {
            throughSeq = summary.asOfSeq
            phase = .loading
        }

        // ③ **异步段**：先等上一个会话写完，再读这个会话的本地尾部。
        //    这两次等待都在发布之后，所以界面看到的永远是自洽的一对。
        await outgoing.flush()

        if let cached {
            // Restore immediately: same rows, same scroll position, no spinner.
            // 记录也要一起恢复：否则下一次落盘会把"这个会话只有刚到的这几条"
            // 写进磁盘，之前那段就被截掉了。
            if cached.records.isEmpty, let scope = sessionScope {
                recentRecords = (await loadStoredTail(scope: scope, sessionId: key))?.records ?? []
            } else {
                recentRecords = cached.records
            }
        } else if let scope = sessionScope,
                  let stored = await loadStoredTail(scope: scope, sessionId: key) {
            // 窗口按"本地落后 host 多少"来定：落后很多时要更大的窗口，否则
            // 快照接不上本地尾部，时间线中间会留一个永远补不上的洞。
            syncPlan = TranscriptSyncPlan.plan(
                localThrough: stored.newest, hostCursor: summary.asOfSeq)
            ChatProbe.shared.probeNote?("transcript.window", [
                "local": String(stored.newest ?? -1),
                "host": String(summary.asOfSeq),
                "maxMessages": String(syncPlan.maxMessages),
                "rebase": syncPlan.reBase ? "1" : "0",
            ], true)
            // 接不上（落后太多，或本地游标比 host 还大）就别画本地那段了：
            // 画出来只会先闪一下跟 host 对不上的内容，然后被快照换掉。
            // 更老的历史仍在电脑上，往前翻能取回。
            timeline = ChatTimeline()
            timeline.record(usage: summary.projections?.values?.tokenUsage)
            if syncPlan.reBase {
                recentRecords = []
                throughSeq = summary.asOfSeq
                installPager(sessionId: key, oldest: nil, newest: throughSeq, hasMore: false)
                phase = .loading
            } else {
                // 冷启动/新进程：用落盘的尾部立刻把转写画出来，**不进 loading**。
                // 随后 follow 的快照会按 seq 合并进来，只补差量。
                timeline.reset(with: stored.records)
                recentRecords = stored.records
                throughSeq = max(stored.newest ?? 0, summary.asOfSeq)
                installPager(sessionId: key, oldest: stored.oldest, newest: throughSeq,
                             hasMore: stored.hasOlder)
                phase = .ready
                scrollSignal += 1
                ChatProbe.shared.probeNote?("transcript.loaded", [
                    "session": key,
                    "records": String(stored.records.count),
                    // 诊断用：读回来的"最老一条"必须等于记录里的第一条
                    "oldest": String(stored.oldest ?? -1),
                ], true)
            }
        } else {
            installPager(sessionId: key, oldest: nil, newest: throughSeq, hasMore: false)
            phase = .loading
        }

        syncPlanRef = syncPlan
        // T011：点开的会话以 .jump 插队水合最新页进 009 磁盘层（抢占在途预取）。
        warmMessageLayer(for: summary)
        // T013：渲染数据源切到 MessagePipeline 快照（管道缺位时桥为 nil，走原路径）。
        startPipelineSubscription(for: summary)
        startFollowing(link: link, summary: summary, maxMessages: syncPlan.maxMessages,
                       generation: openGeneration)
        await restoreSearchHistory()
        pendingOpen = nil
        await loadCatalog(link: link)
        subscribeToPrompts()
        #if DEBUG
        if ChatProbe.shared.staleFollowFrame {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.injectStaleFrameForTesting()
            }
        }
        #endif
    }

    /// 换会话时从旧会话"脱离"出来的东西：它的写链尾巴。
    ///
    /// 只带这一个句柄是刻意的：转写尾部、草稿、内存缓存都在脱离时**同步**写好了，
    /// 剩下的只有"等磁盘写完"——那一步必须排在可见状态发布之后。
    private struct DetachedSwitch {
        let pendingWrites: Task<Void, Never>?

        func flush() async { await pendingWrites?.value }
    }

    /// **同步**脱离旧会话：等于把 `close()` 里除"等写盘"之外的事全部做完，且不 await。
    ///
    /// 为什么不让 `open()` 直接 `await close()`：`close()` 里的 `await flushTranscript()`
    /// 会让出主线程，而那时可见状态还没换——界面就有一次机会画出上一个会话的行
    /// （2026-10-16 用户报的"新建会话先闪旧会话"）。把同步部分与等待拆开之后，
    /// 等待发生在 `visible` 已经换成新会话之后，界面看到的任何一帧都是自洽的。
    private func detachForSwitch() -> DetachedSwitch {
        // 顺序与 `close()` 一致：先写记录与转写，再清状态。
        persistTranscriptNow()
        let pending = writeChain
        saveToCache()
        stashDraft()
        followTask?.cancel()
        followTask = nil
        eventTask?.cancel()
        eventTask = nil
        awaitingTimeout?.cancel()
        awaitingTimeout = nil
        streamFlushTask?.cancel()
        streamFlushTask = nil
        pendingStreamFrames.removeAll(keepingCapacity: false)
        isAwaitingTurnStart = false
        return DetachedSwitch(pendingWrites: pending)
    }

    /// Stops the live streams and keeps the transcript warm for a revisit.
    public func close() async {
        // 顺序要紧：先把记录和转写写下去，再清状态。
        stopPipelineSubscription()
        persistTranscriptNow()
        await flushTranscript()
        saveToCache()
        stashDraft()
        followTask?.cancel()
        followTask = nil
        eventTask?.cancel()
        eventTask = nil
        awaitingTimeout?.cancel()
        awaitingTimeout = nil
        streamFlushTask?.cancel()
        streamFlushTask = nil
        pendingStreamFrames.removeAll(keepingCapacity: false)
        isAwaitingTurnStart = false
    }

    /// Drops everything that belonged to the connection just left.
    ///
    /// Closing alone was not enough: the transcript cache is keyed by session id
    /// and the host is happy to hand out consecutive ids, so a switch to another
    /// computer could show that computer's conversation from the previous one's
    /// cache before the fresh load landed. Drafts go too — a half-written
    /// message belongs to the host it was typed for.
    public func forgetConnection() async {
        await close()
        sessionScope = nil
        // 换电脑：可见状态整体清空（会话与那批行是同一个值，一起没了才不会留下半截状态）。
        visible = nil
        cache.removeAll()
        cacheOrder.removeAll()
        drafts.removeAll()
        draft = ""
        draftImages.removeAll()
        lastError = nil
        currentSelection = nil
        permissionOptions = []
        currentPermission = nil
        pager = nil
        hasOlder = false
        olderFailure = nil
        throughSeq = 0
        pendingStreamFrames.removeAll()
        clearSearchHistory()
        phase = .idle
    }

    /// 把本地的"更早历史"读进搜索缓冲。
    ///
    /// 冷启动、换会话、从后台回来都走这里：本地有就先用本地的，**不联网**；
    /// 读者往下翻越过这段范围，`extendSearchHistory()` 才去 host 取下一页。
    /// 这正是"跟会话查看历史对话一样"的那套逻辑。
    private func restoreSearchHistory() async {
        guard let sessionId = session?.sessionId, let scope = sessionScope else { return }
        // 与尾部同库同表：这里要的是"比当前窗口最老那条还老"的一段（FR-033）。
        // 先看落盘时记下的"缓冲覆盖范围"——它比"比窗口更老"这条启发式可靠：
        // 窗口恰好覆盖了缓冲时（正常且更理想），旧启发式会什么都找不到，冷启动后
        // "只看我的提问"就只剩窗口那一段（T069 实测）。
        var usable: [SessionRecord] = []
        if let store = messageBacking,
           let raw = try? await store.meta(Self.searchRangeKey(sessionId), scope: scope),
           let range = Self.parseSearchRange(raw) {
            let stored = (try? await store.windowBefore(
                scope: scope, sessionId: sessionId, seq: range.newest + 1,
                limit: Self.searchBufferDiskLimit)) ?? []
            usable = stored.filter { $0.event.seq >= range.oldest && $0.event.seq <= range.newest }
        }
        if usable.isEmpty, let store = messageBacking {
            let windowOldest = oldestSeq ?? Int.max
            let stored = (try? await store.windowBefore(
                scope: scope, sessionId: sessionId, seq: windowOldest,
                limit: Self.searchBufferDiskLimit)) ?? []
            usable = stored.filter { $0.event.seq < windowOldest }
        }
        guard !usable.isEmpty else {
            ChatProbe.shared.probeNote?("search.restore.skipped", ["stored": "0"], false)
            return
        }
        searchRecords = usable
        searchOldestSeq = usable.first?.event.seq
        cachedSearchItems = nil
        searchScopeVersion += 1
        ChatProbe.shared.probeNote?("search.restore", [
            "records": String(usable.count),
            "oldest": String(searchOldestSeq ?? -1),
            "hasOlder": hasOlder ? "1" : "0",
        ], true)
    }

    public static func parseSearchRange(_ raw: String) -> (oldest: Int, newest: Int)? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let oldest = Int(parts[0]), let newest = Int(parts[1]),
              oldest <= newest else { return nil }
        return (oldest, newest)
    }

    /// 会话内搜索走哪条通道（spec 007 FR-010/FR-015/FR-036）。
    ///
    /// 抽成纯函数放在模型里，是为了让这条**选路规则**能单测：它原来埋在 SwiftUI 视图的
    /// `performSearch` 里，测试碰不到，于是"单字符查询仍走本地窗口"这类问题只能靠真机发现
    /// （2026-10-17 的返工就是这么来的）。
    public enum SearchChannel: String, Sendable, Equatable {
        /// 「只看我的提问」：读本机全量库（T040 起不再走连接器）。
        case localStore
        /// 关键词 ≥1 个字符且连接器能搜整个会话：交给连接器扫描。
        case connector
        /// 其余：只搜手机上已加载的那一段（老连接器的降级）。
        case localWindow
    }

    /// 选路规则：`onlyMine` 独占本机库；有关键词（≥1 个字符）且连接器有 `session-search`
    /// 才走连接器；空关键词、纯空白、或没有该能力都落本地窗口。
    ///
    /// 空关键词走本地而不是连接器，是因为连接器把"空关键词且没带 roles"当成没有范围的
    /// 全表扫描直接拒绝（`link/query-too-short`）。
    public static func searchChannel(onlyMine: Bool, query: String,
                                     connectorSearchesWholeSession: Bool) -> SearchChannel {
        if onlyMine { return .localStore }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connectorSearchesWholeSession, keyword.count >= 1 else { return .localWindow }
        return .connector
    }

    /// 还能不能再要一页搜索结果。
    ///
    /// 三种来源各有自己的"还有没有"，混用就会出 2026-10-17 的真机现象：连接器已经回报
    /// `hasMore == false`（扫描到底、游标为 nil），界面却按**本地库**的 `canExtendSearch`
    /// 继续给出「继续往下滑」——点一次就再要一次**第一页**（游标 nil），命中全被去重、
    /// 列表不长，而片数进度从 1 爬到 N 又回 1（每点一次重扫一遍）。
    ///
    /// 所以连接器那条只认"hasMore 且 游标非 nil"：只信 hasMore 会在游标为 nil 时从头再扫。
    public static func canRequestSearchPage(source: SearchChannel, cursor: String?,
                                            connectorHasMore: Bool,
                                            localCanExtend: Bool) -> Bool {
        switch source {
        case .localStore:
            return false
        case .connector:
            return connectorHasMore && cursor != nil
        case .localWindow:
            return localCanExtend
        }
    }

    /// 最近一次搜索被连接器拒绝的原因（成功、走本地、或还没搜过时为 nil）。
    ///
    /// 为什么要有它：连接器拒绝（`link/unsupported` / `link/query-too-short` / 超时）
    /// 原来被 `try?` 吞成 nil，界面把它当成"没有命中"——正是 spec 007 FR-013 要求区分开的
    /// 两件事。现在界面据此显示一条提示，而不是假装搜到了零条。
    public private(set) var searchRefusalReason: String?

    /// 连接器拒绝时给读者的一句话（原因来自连接器，这里只包一层说明）。
    public var searchRefusalNotice: String? {
        guard let reason = searchRefusalReason else { return nil }
        return String(localized: "搜索没跑起来：\(reason)")
    }

    /// 连接器能不能搜整个会话（有 `session-search` 能力）。没有时面板必须退回
    /// 本地搜索，并且如实告诉读者"只搜到手机上已有的这一段"（FR-015/FR-036）。
    public var connectorSearchesWholeSession: Bool {
        effectiveCapabilities.contains("session-search")
    }

    /// 连接器没有"搜整个会话"能力时给读者的一句话（FR-036 的硬门槛）。
    ///
    /// 说明的是**天花板**（只搜得到手机上已有的这一段），不是"不能搜"：本地搜索照常可用，
    /// 所以这是一句提示而不是一块禁用的界面。
    public var searchUpgradeNotice: String? {
        guard !connectorSearchesWholeSession else { return nil }
        return String(localized: "要搜索整个会话，需要把电脑上的连接器升级到 \(ConnectorBaseline.minVersion) 及以上")
    }

    /// 握手报上来的能力，按 DEBUG 探针要求摘掉若干条。
    ///
    /// 三处必须用同一个集合（翻阅通道选择、面板的搜索通道、搜索取数），否则会出现
    /// "界面说能搜整个会话、实际走的是本地"这种自相矛盾的状态。
    private var effectiveCapabilities: Set<String> {
        var capabilities = store?.capabilities ?? []
        #if DEBUG
        if ChatProbe.shared.noHistoryWindow { capabilities.remove("history-window") }
        if ChatProbe.shared.noSessionSearch { capabilities.remove("session-search") }
        #endif
        return capabilities
    }

    /// 一页会话内搜索结果（spec 007 P2）。
    public struct SearchPage {
        public let hits: [TranscriptSearchHit]
        public let cursor: String?
        public let hasMore: Bool
        /// `connector` = 覆盖整个会话；`local` = 只搜已加载的那一段（FR-015）。
        public let scope: String
        /// 扫描进度（只有连接器扫描来源、且连接器支持 `search-progress` 时才有）。
        public let progress: SearchProgress?

        /// 片是扫描单位：一段 `chunk`（连接器默认 2000）个 seq 从新往旧扫。
        public struct SearchProgress: Sendable, Equatable {
            public let scannedChunks: Int
            public let totalChunks: Int

            public init(scannedChunks: Int, totalChunks: Int) {
                self.scannedChunks = scannedChunks
                self.totalChunks = totalChunks
            }
        }
    }

    /// 搜索一页：能力在就问宿主要整个会话，否则退回本地（FR-010/FR-015）。
    ///
    /// 命中可能落在**还没加载**的位置：先把那一段上下文从本地库读回来（不联网），
    /// 再做 `seq → 行` 的映射，否则命中会因为"没有行可指"被丢掉（FR-011）。
    public func searchPage(query: String, onlyMine: Bool, cursor: String? = nil,
                    limit: Int = 50) async -> SearchPage? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空关键词只允许"浏览我的提问"这一种用法（连接器侧同样要求带 roles，
        // 否则一次无范围的全表扫描没有意义）。spec 008 的真机反馈修复。
        guard !needle.isEmpty || onlyMine, let client = store?.client, let address else { return nil }
        let service = TranscriptSearchService(client: client, address: address,
                                              capabilities: effectiveCapabilities)
        switch service.source {
        case .connector:
            let value: HistorySearchValue
            do {
                value = try await service.page(query: needle, onlyMine: onlyMine,
                                               cursor: cursor, limit: limit)
            } catch {
                // 拒绝 ≠ 没有结果（FR-013）：留一条原因给界面，别退化成"命中 0 条"。
                searchRefusalReason = (error as? TranscriptSearchService.Failure)?.description
                    ?? String(describing: error)
                return nil
            }
            searchRefusalReason = nil
            await loadContextForHits(value.hits)
            return SearchPage(hits: TranscriptHitLocator.attach(hits: value.hits, to: timeline.items),
                              cursor: value.cursor, hasMore: value.hasMore, scope: "connector",
                              progress: Self.progress(of: value))
        case .local:
            searchRefusalReason = nil
            let local = TranscriptSearch.hits(in: searchItems, query: needle, onlyMine: onlyMine)
            return SearchPage(hits: local, cursor: nil, hasMore: false, scope: "local",
                              progress: nil)
        }
    }

    /// 把连接器回报的片数换算成"已扫 / 共多少"。
    ///
    /// 缺字段（走索引的部署、或支持 `search-progress` 之前的连接器）就是 nil：界面宁可说
    /// "进度未知"，也不能拿 0 当"第一片"——那会让"已扫 0/N"看起来像没扫。
    static func progress(of value: HistorySearchValue) -> SearchPage.SearchProgress? {
        guard let total = value.totalChunks, total > 0,
              let remaining = value.remainingChunks else { return nil }
        // 夹在 [0, total]：连接器已经夹过一次，这里再兜一层——旧连接器给的越界数字
        // 不该让界面显示"已扫 996/2 片"。
        let scanned = min(total, max(0, total - max(0, remaining)))
        return SearchPage.SearchProgress(scannedChunks: scanned, totalChunks: total)
    }

    /// 跳到一条很久以前的命中：把时间线的**窗口整个换掉**（spec 007 FR-011）。
    ///
    /// 为什么必须是"换窗口"而不是"插一段"：时间线是连续的，命中在 seq 1685、而窗口从 2206 起，
    /// 中间隔着几百条——插段等于把整段都读进内存，既慢又推翻"按预算装一窗"的设计。
    /// 换窗口之后，更早的一端由 pager 继续补，更晚的一端读者往下滑也能回来。
    ///
    /// 只从**本地库**读（0 网络）；库里没有这一段就返回 nil，界面保持原地并留一条诊断。
    public func rebaseWindow(around seq: Int, leading: Int = 20, limit: Int = 80) async -> String? {
        // 跳转/换窗口强制置为「阅读中」（spec 009 场景 9：不重置会被下一条增量拽回底部）。
        noteJumpToReading()
        // T013：跳转 = 管道的 .jump（抢占在途低优预取，只拉目标对齐页）。
        if let bridge = pipelineBridge {
            // 先问**本机库**：命中往往就是从它里面搜出来的（「只看我的提问」读的就是
            // `record` 表），这时换窗口完全不必联网——`absorb` 并进管道就够，几百毫秒
            // 内梯子就能解析到行。库里那一段不含目标（命中在更远处）才让管道走网络。
            if await hydrateLocally(around: seq, leading: leading, limit: limit) { return nil }
            return await bridge.rebase(around: seq, leading: leading, limit: limit)
        }
        guard let sessionId = session?.sessionId, let scope = sessionScope else { return nil }
        let before = max(0, seq + leading)
        var records = (try? await messageBacking?.windowBefore(
            scope: scope, sessionId: sessionId, seq: before, limit: limit)) ?? []
        var source = "disk"
        if records.isEmpty, let fetcher = makePageFetcher(pageSize: limit),
           let page = try? await fetcher.page(before: before) {
            // 本地没有（比如刚装上、或者这段从来没读过）：跟连接器要一窗，顺手落盘，
            // 下次同一个位置就不用再联网（FR-011 的"跳过去"必须在冷启动后也能成）。
            records = page.records
            source = "host"
            if !records.isEmpty {
                enqueueAppend(scope: scope, sessionId: sessionId, records: records)
            }
        }
        guard !records.isEmpty else {
            ChatProbe.shared.probeNote?("search.rebase", ["seq": String(seq), "records": "0"], true)
            return nil
        }
        timeline.reset(with: records)
        prependSignal += 1
        let oldest = records.first?.event.seq
        let newest = records.last?.event.seq
        pager?.reset(oldestLoadedSeq: oldest, newestLoadedSeq: newest, hasMore: (oldest ?? 1) > 1)
        olderFailure = nil
        hostHasMore = (oldest ?? 1) > 1
        syncOlderState()
        let landed = TranscriptHitLocator.row(forSeq: seq, in: timeline.items)?.id
        ChatProbe.shared.probeNote?("search.rebase", [
            "seq": String(seq), "records": String(records.count), "source": source,
            "oldest": String(oldest ?? -1), "newest": String(newest ?? -1),
            "landed": landed ?? "-",
        ], true)
        return landed
    }

    /// 换窗口前先问本机库（0 网络）：把目标附近一段读回来并并进管道。
    ///
    /// 返回 true = 这一段**含目标本身**，等这次 refold 落地就够（梯子按 seq 逐枪解析），
    /// 不必联网；false = 库里没有目标（命中在更远处 / 这段从没读过），交给管道走网络。
    ///
    /// 为什么值得这一步：`pipelineActive` 之后换窗口只有"跟连接器要一窗"一条路，
    /// 而「只看我的提问」的命中就是从本机 `record` 表搜出来的——目标记录明明在手上，
    /// 却要等一次网络往返（用例 44 run 20261011-211620：点下去到断言之间只有 2 秒，
    /// 联网那一枪还没回来）。
    private func hydrateLocally(around seq: Int, leading: Int, limit: Int) async -> Bool {
        guard let sessionId = session?.sessionId, let scope = sessionScope,
              let store = messageBacking, let bridge = pipelineBridge else { return false }
        let before = max(0, seq + leading + 1)
        let records = (try? await store.windowBefore(
            scope: scope, sessionId: sessionId, seq: before, limit: limit)) ?? []
        guard !records.isEmpty else { return false }
        // 目标上面还有一段（`leading` 行）才有滚动余量；顺序按 seq 升序给管道。
        await bridge.absorb(records: records.sorted { $0.event.seq < $1.event.seq })
        let covers = records.contains { $0.event.seq == seq }
        ChatProbe.shared.probeNote?("search.rebase.local", [
            "seq": String(seq), "records": String(records.count), "covers": covers ? "1" : "0",
            "oldest": String(records.first?.event.seq ?? -1),
            "newest": String(records.last?.event.seq ?? -1),
        ], true)
        return covers
    }

    /// 按行载荷预算算出"最老端该丢几行"（spec 008 的 FR-004a）。
    ///
    /// **策略已经搬到 DSHKit**（`TranscriptWindowPlanner.rowsToDrop`，spec 023 的 S1）：
    /// 保留带怎么算、够了在哪停、等于预算算不算超，全部由那边决定，这里只做两件事——
    /// 把当前窗口折成逐行字节数，以及把预算交进去。预算本身仍是 App 的旋钮：
    /// DEBUG 探针 `-DSHProbePayloadBudgetKB` 要把真实会话的 32MB 压小，否则这条路在用例里
    /// 永远看不到。
    ///
    /// 返回 0 表示没超预算，不该丢。
    public func rowsToDropForBudget(keepLast: Int? = nil) -> Int {
        // 逐行折一次就够：搬迁前是把 `TranscriptRowPayload(item:)` 折两遍（先求和、再逐行扣），
        // 现在只折一遍，行为不变、少一倍的载荷折算。
        let sizes = timeline.items.map { TranscriptRowPayload(item: $0).payloadBytes }
        return TranscriptWindowPlanner.rowsToDrop(
            payloadBytes: sizes,
            under: TranscriptPayloadBudget(limitBytes: Self.payloadBudgetBytes),
            keepLast: keepLast
        )
    }

    /// 丢掉最老端 `count` 行（宿主那边会用同一批 id 做原子丢弃）。
    @discardableResult
    public func dropOldestRows(_ count: Int) -> Int {
        let dropped = timeline.dropOldestRows(count)
        // 管道模式：桥里的记录也要同步丢到同一界线，否则下一次 diff 重建
        // 会把刚丢的行原样补回来，预算裁剪被架空（008 FR-002）。
        if dropped > 0, let bridge = pipelineBridge,
           let newFirst = timeline.items.first(where: { item in
               if case .gap = item.kind { return false }
               return true
           })?.seq {
            bridge.dropRecords(below: newFirst)
        }
        return dropped
    }

    /// 水合的**同步内存层**：只查 `timeline.items`，不碰磁盘。
    ///
    /// 回收只是宿主侧换了载荷，正本仍在时间线里（只有预算裁剪 `dropOldestRows`
    /// 才会真的移除，而裁剪会把宿主行一起拿走），所以水合请求绝大多数在内存里
    /// 就有。调用方（ChatView 的 `onNeedRehydrate`）先走这条路**同帧**还回，
    /// 再为未命中的 seq 走 `items(forSeqs:)` 的异步磁盘兜底——否则「透明占位 +
    /// 异步水合」会让快速甩动的视口比水合先到，出现单帧白段
    /// （用例 55，run 20261011-111236 的 probe-01…08-gap）。
    public func cachedItems(forSeqs seqs: [Int]) -> [TimelineItem] {
        guard !seqs.isEmpty else { return [] }
        let wanted = Set(seqs)
        return timeline.items.filter { wanted.contains($0.seq) }
    }

    /// 按 seq 把行内容取回来（spec 008 的 US3 / SC-004：水合 1 秒内、0 网络）。
    ///
    /// **内存优先**：被回收的行只是宿主侧换了载荷，`timeline.items` 里的行还在，
    /// 按身份原样交回——不用等落库队列，也不会因「只折 wanted 子集」折错身份
    /// （用例 57：新到的页还没落盘时磁盘只能还回 7/28，可见带多白 ~1s）。
    /// 内存里没有的（窗口裁剪已丢）才落到磁盘层（T027 起为 `MessageStore`）；
    /// 绝不碰 `TranscriptPageFetcher`——水合不该产生任何请求。
    public func items(forSeqs seqs: [Int]) async -> [TimelineItem] {
        guard !seqs.isEmpty else { return [] }
        let wanted = Set(seqs)
        let inMemory = timeline.items.filter { wanted.contains($0.seq) }
        let missing = wanted.subtracting(inMemory.map(\.seq))
        guard !missing.isEmpty else { return inMemory }
        guard let sessionId = session?.sessionId, let scope = sessionScope,
              let store = messageBacking else { return inMemory }
        let newest = (missing.max() ?? 0) + 1
        let oldest = missing.min() ?? 0
        let records = (try? await store.windowBefore(
            scope: scope, sessionId: sessionId, seq: newest,
            limit: max(Self.hitContextLimit, newest - oldest + 1))) ?? []
        var folded = ChatTimeline()
        for record in records.sorted(by: { $0.event.seq < $1.event.seq }) where missing.contains(record.event.seq) {
            folded.apply(record.event)
        }
        return inMemory + folded.items
    }

    /// 把命中所在的那一段从本地库读回时间线（0 网络），这样命中才有行可指。
    private func loadContextForHits(_ hits: [HistorySearchHit]) async {
        guard let sessionId = session?.sessionId, let scope = sessionScope,
              let store = messageBacking,
              let lowest = hits.map(\.seq).min() else { return }
        let before = max(0, lowest + 1)
        guard (timeline.firstContentSeq ?? Int.max) > lowest else { return }
        let records = (try? await store.windowBefore(
            scope: scope, sessionId: sessionId, seq: before,
            limit: Self.hitContextLimit)) ?? []
        guard !records.isEmpty else { return }
        let change = timeline.prepend(older: records)
        if case .none = change {} else { prependSignal += 1 }
        // 管道是活动数据源时，这一段也必须进管道：`refold` 是
        // `timeline.reset(with: 管道 records)`，只 prepend 进时间线的行会被下一次
        // 折叠整段抹掉——跳转目标行随之消失、视口掉回尾部（2026-10-11 用例 49
        // run 20261011-210558：`list.settle anchor=reasoning-1643-0` 之后 rows 100→98）。
        // 本地库读出来的记录是"已经存在的事实"，交给管道与磁盘水合同一条理（0 网络）。
        await pipelineBridge?.absorb(records: records)
        ChatProbe.shared.probeNote?("search.context", [
            "around": String(lowest), "records": String(records.count),
            "pipeline": pipelineBridge == nil ? "0" : "1",
        ], true)
    }

    /// 把搜索缓冲写盘（读者每次往下翻一页都会走一次）。
    private func persistSearchHistory() {
        guard let sessionId = session?.sessionId, let scope = sessionScope else { return }
        guard !searchRecords.isEmpty else { return }
        enqueueAppend(scope: scope, sessionId: sessionId, records: searchRecords)
        // 顺手记下"缓冲覆盖了哪一段"：搜索缓冲和窗口同表，不记就分不出哪些是缓冲，
        // 冷启动时也就恢复不回来（T069）。
        let oldest = searchRecords.first?.event.seq ?? 0
        let newest = searchRecords.last?.event.seq ?? 0
        let key = Self.searchRangeKey(sessionId)
        let value = "\(oldest):\(newest)"
        enqueueWrite { [store = messageBacking] in
            try? await store?.setMeta(key, value, scope: scope)
        }
    }

    public static func searchRangeKey(_ sessionId: String) -> String { "search.range.\(sessionId)" }

    /// 丢掉搜索缓冲：它属于刚关掉的那个会话。
    private func clearSearchHistory() {
        searchRecords.removeAll()
        searchOldestSeq = nil
        cachedSearchItems = nil
        searchScopeVersion += 1
    }

    /// Re-opens the session on screen after the link came back.
    ///
    /// The follow stream dies with the socket, and a transcript that stopped
    /// updating looks exactly like one where nothing is happening — the worst
    /// possible failure for a client whose job is "is it still working?".
    /// Re-opening reuses the warm cache, so the rows and the reading position
    /// stay where the user left them.
    public func reopenAfterReconnect() async {
        guard store?.client != nil else { return }
        // 两种情况都要恢复：先打开再断线（session 还在），以及**没连上就打开过**
        // （session 还是 nil，只有 pendingOpen 记得用户想看谁）。
        if let current = session {
            await open(current)
        } else if let wanted = pendingOpen {
            await open(wanted)
        }
        // 可见性兜底（T019）：重连成功对一次 lastSeq，断线期间的尾部增量补齐。
        await syncTailWithHost(reason: "reconnect")
    }

    // MARK: - Warm cache

    /// A transcript kept in memory so returning to a session is instant.
    private struct CachedSession {
        public var timeline: ChatTimeline
        public var hasOlder: Bool
        public var oldestSeq: Int?
        public var throughSeq: Int
        /// 这个会话的原始记录尾部（落盘写的就是它）。
        public var records: [SessionRecord]
    }

    /// Keeps the composer's contents under the session it was typed for.
    ///
    /// Called on the way out of a session, so nothing typed is lost and nothing
    /// leaks: the next session loads its own draft (usually empty).
    private func stashDraft() {
        guard let key = session?.sessionId else { return }
        let current = Draft(text: draft, images: draftImages)
        if current.isEmpty { drafts.removeValue(forKey: key) } else { drafts[key] = current }
    }

    /// What the store knows about this session's window, or `nil` when it has none.
    /// 冷启动时最多从本地库恢复多少条。**内存上限落在这一步**，而不是运行时裁剪。
    ///
    /// 为什么不裁剪：运行时缩短 `items` 会让在飞的 `scrollTo` 目标失效并 SIGABRT
    /// （2026-10-08 run 20261008-202231）。"打开时只恢复最近一段"没有这个问题——
    /// 那是一次性的、发生在任何滚动之前；更早的部分读者往回滑时由已验过的本地读回补上
    /// （用例 47：`window.backfill` 之前没有任何 `pager.page`，即 0 网络）。
    ///
    /// 600 条 ≈ 300 行：足够填满一屏并留出上下滑动的余量，又不至于把上万条的会话一次性装进内存。
    private static let restoreRecordLimit = 600

    /// 冷启动尾部恢复（T027 起直接读 009 `MessageStore`：session_state + 最新页）。
    public func loadStoredTail(scope: String, sessionId: String) async -> StoredTail? {
        guard let store = messageBacking,
              let state = try? await store.sessionState(scope: scope, sessionId: sessionId)
        else { return nil }
        let records = (try? await store.windowBefore(
            scope: scope, sessionId: sessionId, seq: Int.max,
            limit: min(Self.tailRecordLimit, Self.restoreRecordLimit))) ?? []
        guard !records.isEmpty else { return nil }
        // `state.oldestSeq` 是"库里存的最老一条"；恢复被限流之后，时间线的最老一条
        // 可能比它新——pager 必须按**实际恢复**的那一条算，否则会以为"更早的都在手上"。
        let restoredOldest = records.first?.event.seq ?? state.oldestSeq
        return StoredTail(records: records, oldest: restoredOldest, newest: state.newestSeq,
                          hasOlder: (restoredOldest ?? 1) > 1 || state.hasMore)
    }

    /// The tail the store can hand back on a cold start.
    /// internal：ChatModel+ColdStart.swift 的 009 首帧路径复用同一形状。
    public struct StoredTail {
        public let records: [SessionRecord]
        public let oldest: Int?
        public let newest: Int?
        public let hasOlder: Bool
    }

    private func saveToCache() {
        guard let key = session?.sessionId, !timeline.items.isEmpty else { return }
        cache[key] = CachedSession(
            timeline: timeline,
            hasOlder: hasOlder,
            oldestSeq: oldestSeq,
            throughSeq: throughSeq,
            records: recentRecords
        )
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        // Bounded so a long session-hopping run cannot grow without limit.
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// Drops one session's cached transcript, e.g. after it is deleted.
    public func forget(_ sessionId: String) {
        cache.removeValue(forKey: sessionId)
        cacheOrder.removeAll { $0 == sessionId }
        let scope = sessionScope ?? scopeId
        enqueueWrite { [store = messageBacking] in try? await store?.clear(scope: scope, sessionId: sessionId) }
    }

    /// 当前会话属于哪台电脑——缓存按它分目录，换电脑不会串味。
    private var scopeId: String { store?.scopeId ?? "unknown" }

    /// 把新记录并进尾部：按 seq 去重、保持顺序、只留最新 `maxRecords` 条。
    ///
    /// 两条来源（本地已存的尾部、host 刚给的快照/事件）会在同一会话里重叠——
    /// 快照的第一条往往本地早就有了。去重是必须的，替换是错的。
    private func mergeTail(_ incoming: [SessionRecord]) {
        guard !incoming.isEmpty else { return }
        var bySeq = Dictionary(recentRecords.map { ($0.event.seq, $0) }, uniquingKeysWith: { _, new in new })
        for record in incoming { bySeq[record.event.seq] = record }
        var merged = bySeq.values.sorted { $0.event.seq < $1.event.seq }
        if merged.count > Self.tailRecordLimit {
            merged.removeFirst(merged.count - Self.tailRecordLimit)
        }
        if merged.count > recentRecords.count { unsavedRecords += merged.count - recentRecords.count }
        recentRecords = merged
    }

    /// 把尾部写盘。默认节流：流式输出时每个事件都写会把磁盘当内存用。
    private func persistIfDue(force: Bool = false) {
        guard !persistSuspended, let sessionId = session?.sessionId else { return }
        guard let scope = sessionScope else { return }
        // 会话已经不属于当前这台电脑了（用户切走了）：别再往任何地方写。
        let currentScope = scopeId
        guard currentScope == "unknown" || currentScope == scope else { return }
        let now = Date()
        // 一轮进行中也可能被杀：1 秒或攒够 20 条就写一次，尽量把丢失窗口压小。
        let due = unsavedRecords >= 20 || now.timeIntervalSince(lastDiskSave) > 1
        guard force || due else { return }
        lastDiskSave = now
        unsavedRecords = 0
        // 管道接管渲染时，下行记录已由 SessionPipeline 经 PendingWriteQueue 落进
        // 同一个 MessageStore（T027 统一落库），这里再写一遍是重复劳动，跳过。
        guard pipelineBridge == nil else { return }
        ChatProbe.shared.probeNote?("transcript.saved", [
            "session": sessionId,
            "records": String(recentRecords.count),
            "lastSeq": String(recentRecords.last?.event.seq ?? -1),
        ], true)
        // 写的是**这一段记录**：库里的游标由写入的 seq 推导，不信调用方传的值。
        enqueueAppend(scope: scope, sessionId: sessionId, records: recentRecords)
    }

    /// 立刻落盘（退到后台、离开会话时用：那些时刻之后进程可能就没了）。
    public func persistTranscriptNow() {
        persistIfDue(force: true)
    }

    /// 等所有已排队的落盘做完（离开会话、退到后台时用）。
    public func flushTranscript() async {
        await writeChain?.value
    }

    private func enqueueAppend(scope: String, sessionId: String, records: [SessionRecord]) {
        guard !records.isEmpty else { return }
        enqueueWrite { [layer = messageBacking] in
            await layer?.upsertRecords(scope: scope, sessionId: sessionId, records: records)
        }
    }

    /// Serializes store writes without blocking the caller.
    private func enqueueWrite(_ work: @escaping @Sendable () async -> Void) {
        let previous = writeChain
        writeChain = Task { await previous?.value; await work() }
    }

    /// 「清除本地缓存」被按下：把内存里的尾部也丢掉，并暂停写盘直到下次打开会话。
    ///
    /// 否则会出现"清完 1 秒又回来"的假象：屏幕上的会话仍然握着 200 条记录，
    /// 下一次节流落盘就把文件写回去了。
    public func dropPersistedTail() {
        recentRecords = []
        unsavedRecords = 0
        persistSuspended = true
    }

    private func startFollowing(link: LinkGateway, summary: SessionSummary, maxMessages: Int = 60,
                               generation: Int) {
        let expectedSessionId = summary.sessionId
        followTask = Task { [weak self] in
            guard let self else { return }
            let stream = await link.follow(
                SessionFollowRequest(address: summary.address, maxMessages: maxMessages, assistantStream: true)
            )
            do {
                for try await frame in stream {
                    if Task.isCancelled { return }
                    // 这条流属于哪一代、哪个会话，在**每一帧**上都要对：换会话之后残留的流
                    // 不许再往新会话里写一个字（032 上下文污染的根因）。
                    guard self.isCurrentGeneration(generation, sessionId: expectedSessionId) else {
                        await self.handleStaleFrame(from: expectedSessionId)
                        return
                    }
                    self.apply(frame)
                }
                // The host ended the stream; the session may have been disposed.
                if self.phase == .loading { self.phase = .ready }
            } catch {
                guard !Task.isCancelled else { return }
                if self.phase == .loading {
                    self.phase = .failed(LinkErrors.describe(error))
                } else {
                    self.lastError = LinkErrors.describe(error)
                }
            }
        }
    }

    /// 这一帧还属于当前会话吗（代数 + 会话 id 双条件）。
    func isCurrentGeneration(_ generation: Int, sessionId: String) -> Bool {
        openGeneration == generation && session?.sessionId == sessionId
    }

    /// 收到不属于当前会话的帧：丢弃 + 记账，并清理**已经被写脏**的本地尾巴。
    ///
    /// 为什么要顺手清：脏行在落盘时是按当前会话写的（`enqueueAppend` 用的是当前 sessionId），
    /// 也就是说"混进别的会话"这件事**会被持久化**，只丢内存里的帧修不好已经被写进去的那份。
    /// 清掉之后下一次快照会把这一屏重新拉回来。一个会话一次运行最多清一次，避免抖动。
    private func handleStaleFrame(from sessionId: String) async {
        let current = session?.sessionId ?? "-"
        ChatProbe.shared.probeNote?("transcript.staleDropped", [
            "from": sessionId, "now": current,
        ], true)
        guard let currentSession = session?.sessionId, let scope = sessionScope,
              selfHealedSessions.insert(currentSession).inserted else { return }
        await messageLayer?.clear(scope: scope, sessionId: currentSession)
        dropPersistedTail()
        ChatProbe.shared.probeNote?("transcript.selfHealed", ["session": currentSession], true)
    }

    #if DEBUG
    /// 用例注入：造一帧陈旧帧，走与真实迟到帧**同一条守卫**。
    ///
    /// internal 而不是 private：`DSHChatDomainTests` 要能直接调它（`@testable import`），
    /// App 侧的 `-DSHProbeStaleFollowFrame` 也走这一条。
    func injectStaleFrameForTesting() {
        guard let frame = staleFrameInjector?(), let current = session?.sessionId else { return }
        ChatProbe.shared.probeNote?("transcript.staleInjected", ["session": current], true)
        guard isCurrentGeneration(openGeneration, sessionId: current) else { return }
        // 故意用"上一代"：模拟换会话后残留的流送来的那一帧。
        guard isCurrentGeneration(openGeneration - 1, sessionId: current) else {
            ChatProbe.shared.probeNote?("transcript.staleDropped",
                                        ["from": "injected", "now": current], true)
            return
        }
        apply(frame)
    }
    #endif

    private func apply(_ frame: SessionFollowFrame) {
        switch frame {
        case .snapshot(let snapshot):
            // 这次之前本地尾部到哪（用来判断"是不是真的丢掉了一段"，冷启动没有尾部时
            // 不该记成 rebased）。
            let localLastAtSnapshot = recentRecords.last?.event.seq
            // 计划说得再好，也要看实际回来的第一条接不接得上本地尾部：
            // 接不上（中间缺一段）就只能重来，否则那个洞会写进磁盘、永远补不上。
            let needsReBase = syncPlanRef.reBase
                || TranscriptSyncPlan.stillNeedsReBase(
                    localLastSeq: recentRecords.last?.event.seq,
                    snapshotFirstSeq: snapshot.records.first?.event.seq)
            // T013：管道接管渲染时，快照不再直接折进时间线——记录喂给管道，
            // 由它的 diff 统一重建（时间线、缺口行、"已到最早"都来自同一事实来源）。
            if let bridge = pipelineBridge {
                bridge.applyDownstream(records: snapshot.records)
            } else if timeline.items.isEmpty || needsReBase {
                timeline.reset(with: snapshot.records)
                if needsReBase, !timeline.items.isEmpty, localLastAtSnapshot != nil {
                    ChatProbe.shared.probeNote?("transcript.rebased", [
                        "localLast": String(recentRecords.last?.event.seq ?? -1),
                        "snapshotFirst": String(snapshot.records.first?.event.seq ?? -1),
                    ], true)
                    recentRecords = []
                }
            } else {
                // Warm cache: update in place so the reader keeps any older
                // history they had already paged in.
                timeline.merge(snapshot: snapshot.records)
            }
            throughSeq = max(throughSeq, snapshot.cursor)
            // 本地可能已经存着比这次快照更老的一段（冷启动缓存）：取更小的那个，
            // 否则"往前翻"会从快照的第一条开始要，等于把本地已有的又拉一遍。
            if pipelineBridge == nil {
                pager?.observe(oldestSeq: snapshot.records.first?.event.seq,
                               newestSeq: snapshot.cursor,
                               hasMore: snapshot.hasMore)
                // 以 host 为准：`hasMore=false` 意味着这次快照的窗口已经退到日志开头，
                // 那就真的没有更早的了。以前写成 `|| hasOlder`，本地旧状态会把"到底了"
                // 硬说成"还能往前翻"，点下去什么也加载不出来。
                syncOlderState()
            }
            phase = .ready
            if pipelineBridge == nil { scrollSignal += 1 }
            // 快照要**并进**本地尾部，不能替换：本地可能存着 200 条，而这次的快照
            // 只有 20 条（本地很新时故意少要），直接替换等于把已落盘的历史截掉
            // ——用户看到的就是"切后台回来少了一部分记录"。
            mergeTail(snapshot.records)
            persistIfDue(force: true)

        case .event(let event):
            flushStreamFrames()
            if let bridge = pipelineBridge {
                // T013：事件进管道，由管道 diff 重建时间线（单一路径，不双写）。
                bridge.applyDownstream(event: event)
            } else {
                let change = timeline.apply(event)
                if case .none = change {} else { scrollSignal += 1 }
            }
            mergeTail([SessionRecord(event: event)])
            persistIfDue()
            // A live event proves the stream is healthy even if the summary
            // was stale when the list was fetched.
            if phase != .ready { phase = .ready }
            reactToTurnLifecycle(event)

        case .assistantStream(let streamFrame):
            if let bridge = pipelineBridge {
                // T020：管道模式下流式帧进 SessionPipeline 的 frameTick 合并
                // （spec 剩余卡顿源①的口径在管道侧），App 侧 120ms 合流退役。
                bridge.applyDownstream(stream: streamFrame)
            } else {
                // Coalesced rather than applied per token. A model emits many
                // chunks a second, and each one otherwise re-renders the whole
                // transcript; on a phone that is enough to make the UI stop
                // responding while a session is streaming.
                enqueueStreamFrame(streamFrame)
            }

        case .unknown:
            break
        }
    }

    /// Queues one streaming frame and schedules a coalesced fold.
    private func enqueueStreamFrame(_ frame: AssistantStreamFrame) {
        pendingStreamFrames.append(frame)
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.streamFlushInterval)
            guard !Task.isCancelled else { return }
            self?.flushStreamFrames()
        }
    }

    /// Folds every queued streaming frame in one go.
    ///
    /// Ordering is preserved: committed events flush first, so a message can
    /// never be folded before the deltas that preceded it.
    private func flushStreamFrames() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard !pendingStreamFrames.isEmpty else { return }
        let frames = pendingStreamFrames
        pendingStreamFrames.removeAll(keepingCapacity: true)

        var changed = false
        for frame in frames {
            if case .none = timeline.apply(frame) {} else { changed = true }
        }
        if changed { scrollSignal += 1 }
    }

    /// Turns the two lifecycle events into run state and a completion signal.
    ///
    /// Everything else in the journal is content; these two are state.
    private func reactToTurnLifecycle(_ event: SessionEvent) {
        switch event.type {
        case "turn/start":
            isAwaitingTurnStart = false
            hostReportsRunning = true
            awaitingTimeout?.cancel()
            awaitingTimeout = nil

        case "turn/end":
            isAwaitingTurnStart = false
            hostReportsRunning = false
            awaitingTimeout?.cancel()
            awaitingTimeout = nil
            // 一轮结束是天然检查点：此刻把尾部写死，进程随后没了也不丢这一轮。
            persistIfDue(force: true)
            if let finished = timeline.lastCompletion,
               finished.at != lastSeenCompletionAt {
                lastSeenCompletionAt = finished.at
                completion = finished
                completionSignal += 1
            }
            // Token usage and the running flag both move at turn boundaries.
            Task { await self.refreshSummary() }

        default:
            break
        }
    }

    /// Watches the forwarded host feed for changes worth re-reading.
    private func subscribeToPrompts() {
        eventTask?.cancel()
        guard let hub, let session else { return }
        let target = session.sessionId
        eventTask = Task { [weak self] in
            for await event in hub.events() {
                guard let self else { return }
                switch event {
                case .emit(let name, _) where name == "session/title":
                    await self.refreshSummary()
                case .ready:
                    await self.refreshSummary()
                default:
                    break
                }
                _ = target
            }
        }
    }

    /// internal：ChatModel+Follow 的尾部追平要对一次 host 的 lastSeq（T018/T019）。
    public func refreshSummary() async {
        guard let client = store?.client, let current = session else { return }
        guard let value = try? await client.sessions(),
              let updated = value.items.first(where: { $0.sessionId == current.sessionId })
        else { return }
        // 只换摘要本身（标题/运行态/权限），时间线仍属于同一个会话，所以这一处赋值
        // 依然是自洽的一对——不要在这里重发 `visible`，否则会把正在流式的时间线冲掉。
        visible?.summary = updated
        hostReportsRunning = updated.running
        currentPermission = updated.projections?.values?.permissions?.currentValue
        timeline.record(usage: updated.projections?.values?.tokenUsage)
    }

    private func loadCatalog(link: LinkGateway) async {
        guard catalog == nil else { return }
        await refreshCatalog(link: link)
    }

    /// Re-reads the host's model routes.
    ///
    /// A failure keeps the catalog already on screen: a picker that empties out
    /// because one request timed out is worse than a slightly stale list.
    public func refreshCatalog(link: LinkGateway? = nil) async {
        guard let link = link ?? store?.link else { return }
        if let fresh = try? await link.modelCatalog() {
            catalog = fresh
            catalogFetchedAt = Date()
        }
    }

    /// Re-reads the catalog when it is older than the freshness window.
    public func refreshCatalogIfStale() async {
        if let at = catalogFetchedAt, catalog != nil,
           Date().timeIntervalSince(at) < Self.catalogMaxAge {
            return
        }
        await refreshCatalog()
    }

    /// The model new sessions start with, as the host reports it.
    public var defaultSelection: ModelSelection? { catalog?.default }

    /// Makes one model the default for sessions created from now on.
    ///
    /// Deliberately separate from ``selectModel(_:)``: that one changes the
    /// session on screen, while this writes the host's `agent-default-model`
    /// setting and therefore every session started afterwards — including ones
    /// started on the desktop.
    public func setDefaultModel(_ selection: ModelSelection) async {
        guard let client = store?.client, let link = store?.link else { return }
        guard !isSettingDefaultModel else { return }
        isSettingDefaultModel = true
        defaultModelError = nil
        defer { isSettingDefaultModel = false }
        var patch: [String: JSONValue] = [
            "provider": .string(selection.provider),
            "model": .string(selection.model),
        ]
        if let effort = selection.reasoningEffort { patch["reasoningEffort"] = .string(effort) }
        do {
            try await client.updateSettings(namespace: "agent-default-model", patch: .object(patch))
            // Read it back rather than assuming: the host is the one that owns
            // the value, and the picker marks whichever model it reports.
            await refreshCatalog(link: link)
        } catch {
            defaultModelError = LinkErrors.describe(error)
        }
    }

    // MARK: - History pagination

    /// Loads one older page through the pager and prepends it.
    ///
    /// Three things this deliberately does **not** do any more (they were the bug):
    /// it never turns a failure into "no older history"; it never accepts a page
    /// that does not abut the window; and it never guesses a corrected boundary —
    /// the fetcher asks the connector for an exact window, and falls back to the
    /// published `session/page` workaround only when the connector lacks the
    /// capability (FR-002/FR-003/FR-037/FR-038).
    public func loadOlder() async {
        // T013：管道接管渲染时，"向上翻页"是向管道请求对应范围（.userVisible），
        // 缺口/重试/到头全部由管道的状态机表达（T016）。
        if let bridge = pipelineBridge {
            await bridge.loadOlder()
            return
        }
        guard !isLoadingOlder else { return }
        // 先看本地：窗口裁剪掉的、或上一次冷启动没画出来的那一段，读库就有，不联网。
        if await backfillFromStore() { return }
        guard let pager else { return }
        guard let fetcher = makePageFetcher() else {
            olderFailure = String(localized: "尚未连接")
            return
        }
        isLoadingOlder = true
        olderFailure = nil
        defer {
            isLoadingOlder = false
            syncOlderState()
        }
        let previousOldest = pager.oldestLoadedSeq ?? Int.max
        let failures = pageFailures
        let outcome = await pager.loadOlder { before in
            if failures.shouldFail() {
                throw PageFailureInjected()
            }
            return try await fetcher.page(before: before)
        }
        switch outcome {
        case .prepended:
            didAutoRetry = false
            guard let page = await pager.lastPage else { return }
            let fresh = page.records.filter { $0.event.seq < previousOldest }
            let change = timeline.prepend(older: fresh)
            // 翻过的页也要落盘（FR-033）：以前只有搜索缓冲写盘，上滑补进来的更早记录
            // 一冷启动就没了，读者得重新翻一遍。
            if let sessionId = session?.sessionId, let scope = sessionScope, !fresh.isEmpty {
                enqueueAppend(scope: scope, sessionId: sessionId, records: fresh)
            }
            ChatProbe.shared.probeNote?("pager.page", [
                "start": String(page.startSeq), "end": String(page.endSeq),
                "clamped": page.clamped ? "1" : "0",
                "fresh": String(fresh.count),
                "oldest": String(oldestSeq ?? -1),
            ], true)
            if case .none = change {} else { prependSignal += 1 }
        case .endOfLog:
            ChatProbe.shared.probeNote?("pager.end", ["oldest": String(oldestSeq ?? -1)], true)
        case .failed(let reason):
            olderFailure = reason
            ChatProbe.shared.probeNote?("pager.failed", ["reason": reason], true)
            scheduleAutoRetry()
        case .busy:
            break
        }
    }

    /// Reads the stretch between the pager's oldest seq and the topmost row out of
    /// the local store (spec 007 FR-035).
    ///
    /// This is what makes a sliding memory window affordable: dropping the oldest
    /// rows costs nothing, because coming back up is a disk read rather than a
    /// network round trip (SC-013). Returns `true` when rows came back, which also
    /// means "do not call the host".
    private func backfillFromStore() async -> Bool {
        guard let sessionId = session?.sessionId, let scope = sessionScope,
              let store = messageBacking,
              let firstRow = timeline.firstSeq,
              let from = oldestSeq, from < firstRow else { return false }
        let records = (try? await store.windowBefore(
            scope: scope, sessionId: sessionId, seq: firstRow,
            limit: Self.windowBackfillLimit)) ?? []
        let older = records.filter { $0.event.seq < firstRow }
        guard !older.isEmpty else { return false }
        let change = timeline.prepend(older: older)
        if case .none = change { return false }
        ChatProbe.shared.probeNote?("window.backfill", [
            "from": String(firstRow), "records": String(older.count),
            "oldest": String(timeline.firstSeq ?? -1),
        ], true)
        prependSignal += 1
        return true
    }

    /// Keeps the in-memory window inside its budget.
    ///
    /// Two guards, both learned the hard way (2026-10-08, run 20261008-202231):
    ///
    /// * **Only while following the live tail.** Dropping rows above a reader who is
    ///   *reading* them shifts what they see (`List` keeps offsets, not visible
    ///   content — the trap `anchorAfterPrepend` exists for).
    /// * **Off by default until the P3 anchoring redesign.** Shrinking `items` while a
    ///   programmatic `scrollTo` is in flight crashes UIKit
    ///   (`_validateScrollingTargetIndexPath` → SIGABRT): the target index path no
    ///   longer exists. The view now debounces this call until the open-pin sequence
    ///   is done, but the whole interaction belongs with T045 (anchor once, after the
    ///   content settles). Until then the only way to exercise it is the DEBUG
    ///   `-DSHProbeWindowRows` flag, which is what case 47 uses.
    public func trimWindowIfNeeded(readerIsFollowing: Bool) {
        #if DEBUG
        guard ChatProbe.shared.windowRows != nil else { return }
        #else
        return
        #endif
        guard readerIsFollowing else { return }
        // 上限策略同样在 DSHKit（`TranscriptWindowPlanner.rowsToDrop(rowCount:limit:)`）：
        // 这里只取"该丢几行"，丢的动作交给下面的 `timeline.dropOldestRows`。
        let excess = TranscriptWindowPlanner.rowsToDrop(
            rowCount: timeline.items.count, limit: Self.windowLimitRows)
        guard excess > 0 else { return }
        let dropped = timeline.dropOldestRows(excess)
        guard dropped > 0 else { return }
        ChatProbe.shared.probeNote?("window.trimmed", [
            "dropped": String(dropped), "items": String(timeline.items.count),
            "oldest": String(timeline.firstSeq ?? -1),
        ], true)
    }

    /// Retries the page the reader is still waiting for (the top retry bar).
    public func retryOlder() async {
        olderFailure = nil
        didAutoRetry = false
        await loadOlder()
    }

    /// One automatic retry a few seconds after a failure, so a transient hiccup
    /// heals without the reader having to notice the bar.
    private func scheduleAutoRetry() {
        guard !didAutoRetry else { return }
        guard let pager, pager.currentState != .end, (pager.oldestLoadedSeq ?? 0) > 1 else { return }
        didAutoRetry = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ChatProbe.shared.autoRetryMs))
            guard !Task.isCancelled, let self, self.olderFailure != nil else { return }
            ChatProbe.shared.probeNote?("older.autoRetry", [:], true)
            await self.loadOlder()
        }
    }

    /// One state machine per (session, computer): reinstalled whenever the window
    /// moves to another session, so nothing leaks across conversations (FR-006).
    private func installPager(sessionId: String, oldest: Int?, newest: Int?, hasMore: Bool) {
        pager = TranscriptPager(
            sessionId: sessionId,
            oldestLoadedSeq: oldest,
            newestLoadedSeq: newest,
            hasMore: hasMore
        )
        olderFailure = nil
        hostHasMore = hasMore
        autoRetryTask?.cancel()
        didAutoRetry = false
        syncOlderState()
    }

    // MARK: - 009 管道重建落点（tasks T013/T016；桥在 ChatModel+Pipeline.swift）

    /// 桥算好的整棵折叠结果落进时间线。在这里（而不是扩展里）落地，是因为它
    /// 要写 `timeline` / `hasOlder` / `pager` 这些 private(private(set) 成员。
    ///
    /// 在飞状态（流式气泡、发送中的乐观回声）不在下行记录里，重建时必须接回
    /// （`restoreTransient`），否则每一次快照 diff 都会把它们抹掉一帧。
    public func applyPipelineRebuild(
        _ folded: ChatTimeline, gaps: [TimelineItem],
        topExhausted: Bool, oldestSeq: Int?
    ) {
        let oldFirstSeq = timeline.items.first(where: { !Self.isGapRow($0) })?.seq
        var next = folded
        next.record(usage: timeline.lastUsage)
        next.restoreTransient(streaming: timeline.streaming, echoes: Self.pendingEchoes(in: timeline.items))
        next.setGaps(gaps)
        let newFirstSeq = next.items.first(where: { !Self.isGapRow($0) })?.seq
        timeline = next
        // 头部变老 = 补页（prependSignal，宿主锚回视口）；其余 = 内容变化。
        if let newFirstSeq, newFirstSeq != oldFirstSeq,
           oldFirstSeq == nil || newFirstSeq < (oldFirstSeq ?? .max) {
            prependSignal += 1
        } else {
            scrollSignal += 1
        }
        // T016：「已到最早」只在管道判到顶（hasMore=false / clamped）时成立。
        hostHasMore = !topExhausted
        hasOlder = !topExhausted && (oldestSeq ?? 1) > 1
        pager?.observe(oldestSeq: oldestSeq, newestSeq: nil, hasMore: !topExhausted)
        searchScopeVersion += 1
    }

    /// 只刷新缺口行（加载/失败/到头三态变化，数据行不动）。
    public func applyPipelineGaps(_ gaps: [TimelineItem]) {
        timeline.setGaps(gaps)
        scrollSignal += 1
    }

    /// T020 流式快进路落点：单行增量更新（只改写流式气泡行的文本，不整树
    /// 重折）。返回 false = 该行还没折进时间线，调用方回退整树重折。
    /// 提交走 `scrollSignal` → 宿主 reconcile（008 统一锚一次修正，T021），
    /// 阅读中不冻结渲染也不推走视口。
    @discardableResult
    public func applyStreamingRow(seq: Int, text: String, reasoning: String) -> Bool {
        guard timeline.applyStreamingUpdate(seq: seq, text: text, reasoning: reasoning) else {
            return false
        }
        scrollSignal += 1
        return true
    }

    /// 管道模式下的「向上翻页」进行中（顶部缺口行 spinner 与旧版小字共用此位）。
    public func notePipelineLoadingOlder(_ loading: Bool) {
        isLoadingOlder = loading
    }

    /// 管道模式下的取页失败（顶部缺口行转「点击重试」，绝不写成"没有更多"）。
    public func notePipelineOlderFailure(_ message: String?) {
        olderFailure = message
    }

    public static func isGapRow(_ item: TimelineItem) -> Bool {
        if case .gap = item.kind { return true }
        return false
    }

    /// 仍在等服务端确认的本地回声行（上行在飞，重建时由 restoreTransient 接回）。
    public static func pendingEchoes(in items: [TimelineItem]) -> [TimelineItem] {
        items.filter { item in
            guard case .userMessage(_, _, _, let isPending, _) = item.kind else { return false }
            return isPending
        }
    }

    /// Projects the pager's state onto the two values the view reads.
    ///
    /// `hasOlder` stays true while the state is `failed`, because that is exactly
    /// when the reader must be able to try again.
    private func syncOlderState() {
        guard let pager else {
            hasOlder = false
            return
        }
        switch pager.currentState {
        case .end: hostHasMore = false
        case .more: hostHasMore = true
        case .failed: break
        }
        hasOlder = pager.currentState != .end && (pager.oldestLoadedSeq ?? 0) > 1
    }

    /// The channel-choosing fetcher for this session, or `nil` before a connection.
    /// 一页有多大：时间线要"一屏一屏"地补（60 条），搜索缓冲要"一大段"地读。
    ///
    /// 为什么搜索缓冲必须是大的（2026-10-08 用例 44 实测）：旧 `session/page` 的"60 条"
    /// 指的是**消息**条数，实际会回 ~300 条记录；换成精确窗口之后 "60" 指的是记录条数，
    /// 同样一次调用覆盖的历史短了约 5 倍，于是"只看我的提问"往下滑能看到的老提问少了一大截。
    private enum PageSize {
        public static let timeline = 60
        public static let searchBuffer = 300
    }

    /// 搜索缓冲一次从本地读多少条。
    private static let localSearchReadLimit = 300
    /// 为一条命中补上下文时读多少条（命中要能落到某一个已加载的行上）。
    private static let hitContextLimit = 60
    /// 行载荷预算（spec 008 的契约默认值：32MB）。DEBUG 下可被探针压小，
    /// 否则真实会话永远达不到预算、"丢弃"这条路在用例里就永远看不到。
    public static var payloadBudgetBytes: Int {
        #if DEBUG
        if let kb = ChatProbe.shared.payloadBudgetKB { return kb * 1024 }
        #endif
        return 32 * 1024 * 1024
    }

    private func makePageFetcher(pageSize: Int = PageSize.timeline) -> TranscriptPageFetcher? {
        guard let client = store?.client, let address else { return nil }
        let capabilities = effectiveCapabilities
        #if DEBUG
        let shortfall = ChatProbe.shared.pageShortfall
        #else
        let shortfall = 0
        #endif
        let filter: (@Sendable (TranscriptPager.Page) -> TranscriptPager.Page)? = shortfall > 0
            ? { @Sendable page in Self.droppingNewest(shortfall, from: page) }
            : nil
        return TranscriptPageFetcher(
            client: client,
            address: address,
            throughSeq: throughSeq,
            capabilities: capabilities,
            pageSize: pageSize,
            pageFilter: filter
        )
    }

    /// Drops the newest `count` records — the DEBUG reproduction of a host that
    /// hands back a short page (test case 43).
    private nonisolated static func droppingNewest(_ count: Int, from page: TranscriptPager.Page) -> TranscriptPager.Page {
        guard page.records.count > count else { return page }
        let kept = Array(page.records.dropLast(count))
        return TranscriptPager.Page(
            records: kept,
            startSeq: kept.first?.event.seq ?? page.startSeq,
            endSeq: kept.last?.event.seq ?? page.endSeq,
            hasMore: page.hasMore,
            clamped: page.clamped
        )
    }

    // MARK: - 搜索用的"再往前那一段"

    /// 已加载 + 已读进来待用的全部可搜索行（由旧到新）。
    public var searchItems: [TimelineItem] {
        let key = "\(searchRecords.count)-\(timeline.items.count)"
        if let cached = cachedSearchItems, cached.key == key { return cached.items }
        var scratch = ChatTimeline()
        for record in searchRecords { scratch.apply(record.event) }
        // 缓冲和已加载窗口会在边界上重叠（缓冲那一页的"最新几条"往往就是窗口里已经有的），
        // 折叠出来就是同一行出现两次——列表里肉眼可见的重复（2026-09-24 实拍）。
        let existing = Set(timeline.items.map(\.id))
        let items = scratch.items.filter { !existing.contains($0.id) } + timeline.items
        cachedSearchItems = (key, items)
        return items
    }

    /// 搜索还能不能往前扩。
    ///
    /// 以前这里还有第二个"还有没有更早"（`searchHasOlder`），一次失败就被置成 false，
    /// 于是面板会显示"已经是最开头"而时间线还能继续翻。现在只问 pager（FR-005）。
    public var canExtendSearch: Bool {
        // 只问"还能不能更早"，**不问 pager 的状态**：pager 描述的是"宿主那边还有没有"，
        // 而这里要的是"本地库里还有没有"——两者不是同一件事（2026-10-08 用例 44/46 实测：
        // 某些会话的宿主日志已经被裁到快照覆盖的范围，pager 判到底，但本地库里明明存着
        // 更早的老提问，面板却被"到底了"挡住，读者再也搜不到它们）。
        searchOldestSeq ?? oldestSeq ?? 1 > 1
    }

    /// 往前取一页进**搜索缓冲**（时间线不动）。
    @discardableResult
    public func extendSearchHistory() async -> Bool {
        guard let from = searchOldestSeq ?? oldestSeq, from > 1 else { return false }
        guard !isExtendingSearch,
              let fetcher = makePageFetcher(pageSize: PageSize.searchBuffer) else { return false }
        isExtendingSearch = true
        defer { isExtendingSearch = false }
        // 先看本地：搜索缓冲要的是"更早的一段"，本地库通常就有（还能省一次往返）。
        if let scope = sessionScope, let sessionId = session?.sessionId,
           let store = messageBacking,
           let local = try? await store.windowBefore(
               scope: scope, sessionId: sessionId, seq: from,
               limit: Self.localSearchReadLimit) {
            let fresh = local.filter { $0.event.seq < from }
            if !fresh.isEmpty {
                searchRecords.insert(contentsOf: fresh, at: 0)
                searchOldestSeq = fresh.first?.event.seq
                searchScopeVersion += 1
                persistSearchHistory()
                ChatProbe.shared.probeNote?("search.extended", [
                    "from": String(from), "records": String(fresh.count),
                    "source": "disk", "searchOldest": String(searchOldestSeq ?? -1),
                ], true)
                return true
            }
        }
        // 本地没有才问宿主。取不到就是取不到：不写任何"没有更早了"的状态，读者可以再试（FR-003）。
        guard let page = try? await fetcher.page(before: from) else {
            olderFailure = String(localized: "读取更早的记录失败，点按重试")
            return false
        }
        let fresh = page.records.filter { $0.event.seq < from }
        guard !fresh.isEmpty else { return false }
        searchRecords.insert(contentsOf: fresh, at: 0)
        searchOldestSeq = fresh.first?.event.seq
        searchScopeVersion += 1
        persistSearchHistory()
        ChatProbe.shared.probeNote?("search.extended", [
            "from": String(from),
            "records": String(fresh.count),
            "searchOldest": String(searchOldestSeq ?? -1),
            "hostHasMore": page.hasMore ? "1" : "0",
        ], true)
        return true
    }

    /// 把搜索缓冲并进时间线（读者点了缓冲里的某一条时才做）。
    ///
    /// 只并"比时间线最老那条还老"的记录；并完清空缓冲，视图那边会跟着跳转。
    @discardableResult
    public func commitSearchHistory() -> Bool {
        guard !searchRecords.isEmpty, let oldest = oldestSeq else { return false }
        let fresh = searchRecords.filter { $0.event.seq < oldest }
        searchRecords.removeAll()
        searchOldestSeq = nil
        cachedSearchItems = nil
        searchScopeVersion += 1
        guard !fresh.isEmpty else { return false }
        let change = timeline.prepend(older: fresh)
        if let first = fresh.first?.event.seq {
            // 并入缓冲等于把窗口下界推到那段更早的地方；告诉 pager，而不是自己改一个字段。
            pager?.observe(oldestSeq: first, newestSeq: nil, hasMore: hasOlder)
            syncOlderState()
        }
        if case .none = change { return false }
        prependSignal += 1
        ChatProbe.shared.probeNote?("search.committed", [
            "records": String(fresh.count),
            "oldest": String(oldestSeq ?? -1),
        ], true)
        return true
    }


    // MARK: - Outbound actions

    /// Adds prepared pictures to the next prompt.
    ///
    /// 025 阶段4b：造这一批载荷要 UIImage（缩放 + JPEG 编码），所以「从 UIImage 加」
    /// 留在界面层（`DSHChatUI` 的 `ChatModel+DraftImages.swift`）；领域层只收结果。
    public func addDraftImages(_ images: [DraftImage]) {
        draftImages.append(contentsOf: images)
    }

    public func removeDraftImage(id: UUID) {
        draftImages.removeAll { $0.id == id }
    }

    public func clearDraftImages() {
        draftImages.removeAll()
    }

    /// Submits the composer's text.
    ///
    /// Steer mode interrupts the running turn instead of queueing behind it,
    /// which is how the desktop client's "steer" affordance behaves.
    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draftImages
        guard !text.isEmpty || !images.isEmpty, let client = store?.client, let session else { return }
        let owner = session.sessionId

        let mode: SessionPromptRequest.Mode = (steerNext && isRunning) ? .steer : .queue
        // T022：管道模式下纯文本走 MessagePipeline（乐观插入贴底 → 落库 pending →
        // 网络 → 下行 rpcId 确认原地替换）。带附件仍走旧路径——附件的压缩/上传与
        // echo 耦合在现有 send 里，管道化留给后续任务（本任务不接管）。
        if images.isEmpty, pipelineBridge != nil {
            await sendViaPipeline(text: text, mode: mode, owner: owner)
            return
        }
        // Which conversation this text belongs to, fixed here: the user may
        // switch away while the send is in flight, and neither the clear nor a
        // failure's restore may land on whatever happens to be on screen then.
        // Cleared optimistically so the field empties the instant you send, but
        // restored if the host refuses — losing typed text to a transient
        // failure is worse than seeing it come back.
        draft = ""
        drafts.removeValue(forKey: owner)

        // The request id is minted here because the host stores it on the
        // durable message's source; that is what lets the transcript replace
        // this optimistic row instead of showing the message twice.
        let requestId = UUID().uuidString
        timeline.echoUserPrompt(requestId: requestId, text: text)
        scrollSignal += 1
        sendSignal += 1
        // 发送自己的消息一律贴底（spec 009「跟底两态」钦定例外，tasks T017）。
        noteWantsBottom()
        isAwaitingTurnStart = true
        // If the host is already mid-turn the message sits in its queue, and
        // `timeline.isTurnOpen` already reports running; otherwise a turn
        // starts within a second. Either way this must not latch forever.
        awaitingTimeout?.cancel()
        awaitingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.isAwaitingTurnStart = false
        }

        // Cleared only once the bytes are on their way; a failed send puts the
        // pictures back alongside the text.
        draftImages.removeAll()

        do {
            try await client.prompt(
                SessionPromptRequest(
                    requestId: requestId,
                    sessionId: session.sessionId,
                    mode: mode,
                    content: Self.promptContent(text: text, images: images)
                )
            )
        } catch {
            isAwaitingTurnStart = false
            // Back to the conversation it was typed in — visible if the user is
            // still there, waiting quietly if they have moved on.
            let restored = Draft(text: text, images: images)
            drafts[owner] = restored
            // `session` was captured by the guard at the top of this function,
            // so it is this send's own session — not whatever is on screen now.
            if session.sessionId == owner {
                if draft.isEmpty { draft = text }
                if draftImages.isEmpty { draftImages = images }
            }
            lastError = LinkErrors.describe(error)
        }
    }

    /// T022 管道发送（纯文本、渲染数据源已切 009 时）：乐观插入由管道快照流
    /// 进入时间线（贴底），requestId 就是管道 clientId，确认走下行 rpcId 回流
    /// 原地替换——不经过旧的 `echoUserPrompt` 回声（身份只有一套）。
    /// 发送失败行留在时间线上可点重发，所以草稿不回填（文字没丢，行还在）。
    private func sendViaPipeline(text: String, mode: SessionPromptRequest.Mode, owner: String) async {
        guard let pipeline = messageLayer?.pipeline, let scope = sessionScope else { return }
        draft = ""
        drafts.removeValue(forKey: owner)
        scrollSignal += 1
        sendSignal += 1
        // 发送自己的消息一律贴底（spec 009「跟底两态」钦定例外，tasks T017）。
        noteWantsBottom()
        isAwaitingTurnStart = true
        awaitingTimeout?.cancel()
        awaitingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.isAwaitingTurnStart = false
        }
        let ref = MessageSessionRef(scope: scope, sessionId: owner)
        do {
            _ = try await pipeline.send(text: text, to: ref, steer: mode == .steer)
        } catch {
            // 行已由管道标 failed（可点重发）；错误同时上错误条。
            isAwaitingTurnStart = false
            lastError = LinkErrors.describe(error)
        }
    }

    /// Uploads one file and tells the agent where it landed.
    ///
    /// There is **one** route for file bytes now (the relay's HTTPS surface with
    /// a background task), and it is a *file* route: iOS only continues
    /// file-based tasks after the app is suspended, so a file has to stay a file
    /// all the way down. This entry point therefore writes the bytes to disk
    /// first and hands the URL to `sendFile(named:fileURL:)` — it is a
    /// migration shim, not a second implementation. Its remaining caller is the
    /// DEBUG automation hook `-DSHUploadFile`, which the next batch deletes
    /// together with this method.
    public func sendFile(named name: String, data: Data) async {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming-staged", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let url = scratch.appendingPathComponent(name.isEmpty ? "file" : name)
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: scratch) }
            await sendFile(named: name, fileURL: url)
        } catch {
            lastError = String(
                localized: "文件「\(name)」没发出去：\(LinkErrors.describe(error))。可以再点一次发送。"
            )
        }
    }

    /// Uploads a file the caller already has as a URL on disk.
    ///
    /// There is **one** route for file bytes (the relay's HTTPS surface with a
    /// background task); `ConnectionStore` decides whether that route exists at
    /// all from here, and a "no" is an error, not another path. This end hands
    /// over a file and, when it fails, says so in words the person can act on.
    ///
    /// **The staged copy is deleted when this returns, whichever way it went**
    /// (P-3). Only a copy this app made is deletable — `OutgoingFiles.remove`
    /// checks the path against the staging root, so the file behind
    /// `-DSHUploadFilePath` or a path the user picked in Files is never
    /// touched. Leaving it behind was a disk leak that only grew, because
    /// nothing else ever deleted one.
    public func sendFile(named name: String, fileURL: URL) async {
        guard let session, let store else { return }
        let owner = session.sessionId
        isUploadingFile = name
        defer {
            isUploadingFile = nil
            // After the await, never before: the background task reads this
            // file, and a delete that beat it would be the F-2 crash face.
            OutgoingFiles.remove(fileURL)
        }

        do {
            let staged = try await store.uploadFile(
                fileURL: fileURL,
                name: name,
                sessionId: session.sessionId
            )
            await announceStagedFile(staged, name: name, owner: owner)
        } catch {
            // 落盘日志：大文件走的是"用户看不见进度"的那条路（后台上传、中转桥接、
            // 连接器落盘），失败只会体现在输入框没动静。没有这一行时，真机上
            // 「发了没反应」与「后端没收到」无法区分。
            DSHLog.push("file send failed: \(name) "
                + "(\(FileTransferAdapter.fileSize(fileURL)) bytes) — \(LinkErrors.describe(error))")
            // 给用户的那句话：说清**哪个文件**、**为什么**、**能做什么**。
            // 不再把内部错误原文丢出去（"中转没有返回落盘路径"就是反面样本）。
            lastError = String(
                localized: "文件「\(name)」没发出去：\(LinkErrors.describe(error))。可以再点一次发送。"
            )
        }
    }

    /// Dismisses the failure notice the chat screen shows.
    ///
    /// `lastError` used to have exactly one reader (`Composer`'s prompt sheet), so
    /// a file that failed to send looked to the user like "the spinner stopped".
    /// `ChatView` now renders it, and this is how its × clears it.
    public func clearLastError() {
        lastError = nil
    }

    /// Writes the prompt that names where the file landed.
    ///
    /// The path is what makes an upload useful: without it the agent knows a file
    /// exists but not where. The prompt belongs to the session the file was staged
    /// for, which is not necessarily the one on screen by the time the upload
    /// finishes — so a late completion goes to that session's draft instead.
    /// **The wording is unchanged**: this is plumbing, not a prompt change.
    private func announceStagedFile(
        _ staged: StagedFile,
        name: String,
        owner: String
    ) async {
        let text = "我发送了一个文件，已保存到：\(staged.path)（\(staged.bytes) 字节）"
        guard session?.sessionId == owner else {
            drafts[owner] = Draft(text: text, images: [])
            return
        }
        draft = text
        await send()
    }

    /// The prompt body: the words, then one part per picture.
    private static func promptContent(text: String, images: [DraftImage]) -> [PromptContentPart] {
        var content: [PromptContentPart] = []
        if !text.isEmpty { content.append(.text(text)) }
        for image in images {
            content.append(.image(mediaType: image.mediaType, data: image.base64, name: image.name))
        }
        return content
    }

    /// Cancels the running turn.
    public func cancel() async {
        guard let client = store?.client, let session else { return }
        do {
            try await client.cancel(sessionId: session.sessionId)
            isAwaitingTurnStart = false
        } catch {
            lastError = LinkErrors.describe(error)
        }
    }

    public func rename(to title: String) async {
        guard let client = store?.client, let session else { return }
        do {
            try await client.rename(sessionId: session.sessionId, title: title)
            await refreshSummary()
        } catch {
            lastError = LinkErrors.describe(error)
        }
    }

    /// Forks the session, returning the new session's id when the host reports it.
    public func fork() async -> String? {
        guard let client = store?.client, let session else { return nil }
        do {
            let value = try await client.forkSession(sessionId: session.sessionId)
            return value["sessionId"]?.stringValue ?? value["id"]?.stringValue
        } catch {
            lastError = LinkErrors.describe(error)
            return nil
        }
    }

    public func selectModel(_ selection: ModelSelection) async {
        guard let client = store?.client, let session else { return }
        let previous = currentSelection
        currentSelection = selection
        do {
            try await client.selectModel(sessionId: session.sessionId, selection: selection)
        } catch {
            currentSelection = previous
            lastError = LinkErrors.describe(error)
        }
    }

    /// Updates the displayed permission preset.
    ///
    /// The preset is owned by the host's session, not by an RPC, so this only
    /// reflects a choice locally; the authoritative value arrives with the next
    /// session projection. It exists so the picker can show intent immediately.
    public func setPermissionLocally(_ value: String) {
        currentPermission = value
    }

    /// Answers a pending host prompt.
    ///
    /// The sheet hands over the wire answer it built (`UserQuestionsAnswer`),
    /// because the encoding has rules the caller should not have to know: free
    /// text is its own field, and a single-select answer typed in words carries
    /// no selected labels.
    public func answer(_ item: HostEventHub.Pending, answers: UserQuestionsAnswer) async {
        guard let hub else { return }
        do {
            try await hub.answer(item, with: .result(try JSONValue(from: answers)))
        } catch {
            lastError = LinkErrors.describe(error)
        }
    }

    /// Declines a prompt so the desktop client can handle it.
    public func pass(_ item: HostEventHub.Pending) async {
        await hub?.pass(item)
    }

    /// Autocomplete candidates for `@` file references.
    public func fileReferences(query: String) async -> [FileReferenceCandidate] {
        guard let client = store?.client, let session else { return [] }
        return (try? await client.fileReferences(agentId: session.sessionId, query: query)) ?? []
    }
}

public extension JSONValue {
    /// Re-encodes a value into a JSON value, used to hand typed models to the
    /// dynamic event-result channel.
    public init(from model: some Encodable) throws {
        let data = try JSONEncoder().encode(model)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

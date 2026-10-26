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

    @ObservationIgnored lazy var sendService = ChatSendService(model: self)
    @ObservationIgnored lazy var pagingService = ChatPagingService(model: self)

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
    /// 会话可见状态（visible/timeline/session）已搬到 `transcriptStore`。
    let transcriptStore = TranscriptStore()

    /// 唯一被发布的会话可见状态（存储在 `transcriptStore`）。
    public private(set) var visible: VisibleSession? {
        get { transcriptStore.visible }
        set { transcriptStore.visible = newValue }
    }

    /// 过程节点的展开状态（spec 033）。这是**会话级显示状态**，不是转写数据：
    /// 换会话/重开 App 重置；内部 setter 让 `ChatModel+ProcessFold.swift` 能改。
    public internal(set) var foldState = TranscriptFoldState()

    /// 展开预折摘要时的取详情进度，按表头 id 记录。与 `foldState` 同属会话级
    /// 显示状态：换会话清空；请求的四种结局（进行中/成功/失败/取消）都要落到这里，
    /// 界面只渲染它，不自己计时也不自己重试。
    public internal(set) var prefetchStatus: [String: PrefetchStatus] = [:]

    /// 首屏概要取数（能力 `history-fold-summary-v2`）的状态。
    ///
    /// 一次会话一屏一份：成功/失败/取消都落到这里，视图只渲染；
    /// `link/too-large` 带 `tooLarge` 标记，页级重试条据此换文案。
    public internal(set) var summaryScreenState: SummaryScreenState = .idle
    /// 首屏概要请求与重试的在飞任务（换会话/关闭时取消）。
    var summaryScreenTask: Task<Void, Never>?

    /// 宿主排队输入（`session/control`）：唯一所有者是宿主，本地只做乐观回显。
    public internal(set) var queueControlAvailable = true
    var remoteQueue: [SessionQueuedItem] = []
    var optimisticQueue: [OptimisticQueuedInput] = []
    /// 本地已撤回的 rpcId：控制帧晚到时不让它闪回来。
    var locallyWithdrawnQueuedRpcIds: Set<String> = []
    @ObservationIgnored var queueTask: Task<Void, Never>?

    /// 单条步骤正文的三态（按需取，key 是步骤行 id）。
    ///
    /// 只由 `loadProcessStepBody` 写、投影贴到步骤行上；缓存在磁盘 meta 里，
    /// 二次打开先读缓存、不再请求。
    public internal(set) var stepBodies: [String: ProcessStepBodyState] = [:]
    var stepBodyTasks: [String: Task<Void, Never>] = [:]

    /// 现在开的是哪个会话（读 `visible`）。
    public var session: SessionSummary? { transcriptStore.session }

    /// 屏幕上这批行（读 `visible`）。
    ///
    /// 注意：**不要**用它判断"这些行是不是这一屏的"——判断用 `rowsFor(screen:)`。
    public internal(set) var timeline: ChatTimeline {
        get { transcriptStore.timeline }
        set { transcriptStore.timeline = newValue }
    }

    /// 这一屏该画哪些行：**只有这批行属于这一屏时才交出去**。
    ///
    /// 渲染（`ChatView`）与量具（`StaleRenderWatch`）都读这一个入口，因此
    /// "屏幕上画了什么"与"判定量到什么"永远是同一件事。换会话期间、以及任何
    /// "行属于别的会话"的时刻，这里返回空——界面不会把上一个会话的内容画出来。
    ///
    /// 033 起这里返回的是**显示投影**：已完成轮次的过程被收进过程节点。需要原始
    /// 行（搜索、分页、长按）的调用方用 `rawRowsFor(screen:)`。
    public func rowsFor(screen sessionId: String) -> [TimelineItem] {
        displayRowsFor(screen: sessionId)
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

    /// 运行中过程区的实时状态（分组行的「正在…」与底部深度求索行共用）。
    /// 由时间线算出，不另存一份：工具一换，下一次渲染就是新的动作与命令。
    public var runningDetail: ProcessRunningDetail? {
        TranscriptProcessFold.runningDetail(
            in: timeline.items,
            isTurnOpen: timeline.isTurnOpen,
            summaries: timeline.foldSummaries.filter { $0.turn == timeline.currentTurn })
    }

    /// 快照里最后一条轮次边界是不是 `turn/start`（这一轮还在跑）。
    ///
    /// 运行行需要计时起点；快照到达时 `runningSince` 可能还是 nil（open 在快照之前
    /// 就跑了）。宿主的开始时间不可得，这里只判断"在跑"，起点由调用方取当下（下限）。
    static func snapshotEndsInOpenTurn(_ records: [SessionRecord]) -> Bool {
        for record in records.reversed() {
            switch record.event.type {
            case "turn/start": return true
            case "turn/end": return false
            default: continue
            }
        }
        return false
    }

    /// 本轮开始计时的时刻。
    ///
    /// 宿主 `turn/start` 不带时间戳，窗口里也没有更早的可信时间，所以这个计时
    /// 由这里记：看到轮次开启记一次，结束清掉。只服务「深度求索中，用时 …」。
    public internal(set) var runningSince: Date?

    /// Whether a stop control should be offered at all.
    public var isBusy: Bool { activity != .idle }

    /// The most recent completed turn, used to announce the end of a run.
    public private(set) var completion: ChatTimeline.Completion?

    /// Bumped whenever a run finishes, so the view can flash a confirmation.
    public private(set) var completionSignal: Int = 0

    /// Streaming chunks waiting to be folded into the transcript.
    private var pendingStreamFrames: [AssistantStreamFrame] = []
    /// 当前流式尝试的实时字数（正文 + 思考），只给运行中折叠行显示；与折叠解耦。
    public private(set) var liveStreamChars = 0
    public private(set) var liveStreamFrames = 0
    private var liveStreamCounter = LiveStreamCharCounter()
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
    public typealias DraftImage = ComposerDraftImage

    /// 输入区状态（草稿/图片/插入模式）。2026-10-21 从 ChatModel 拆出。
    let composer = ComposerState()
    /// 搜索缓冲状态（只在模块内使用）。
    let searchState = SearchState()

    /// Pictures queued in the composer, sent with the next prompt.
    ///
    /// 存储已搬到 `composer`；这里保留同名投影，UI 与测试调用点不变。
    public internal(set) var draftImages: [DraftImage] {
        get { composer.images }
        set { composer.images = newValue }
    }

    /// Name of the file being uploaded, for the composer to show.
    public internal(set) var isUploadingFile: String?

    /// Set between submitting a prompt and the host starting its turn.
    var isAwaitingTurnStart = false
    /// The host's own view of whether it is running, from the session summary.
    private var hostReportsRunning = false
    var awaitingTimeout: Task<Void, Never>?
    private var lastSeenCompletionAt: Date?
    /// 向上取页的唯一状态源：进行中、失败、已到最早、空闲。
    ///
    /// 以前拆成 `isLoadingOlder` 与 `olderFailure` 两个字段，界面与管道各存一份，
    /// 失败的清空与加载的结束是两个独立的写点——这正是"一直转圈"能出现的结构原因。
    /// 现在只有一个状态与一个写入口；`isLoadingOlder` / `olderFailure` 只是只读投影。
    public enum OlderPageState: Equatable, Sendable {
        case idle
        case loading
        case failed(String)
        case exhausted
    }
    public private(set) var olderState: OlderPageState = .idle
    public var isLoadingOlder: Bool { olderState == .loading }
    /// 已确认没有更早历史：顶部不再自动取页。
    public var isOlderExhausted: Bool { olderState == .exhausted }
    /// 打开会话时管道还没接好，读者已经到了顶部：先显示加载，
    /// 管道一旦启动就补发这次请求（否则这次上拉会静默丢失）。
    public internal(set) var olderPendingBeforePipeline = false
    /// 这个宿主本来就会接管道（有消息层且打开了会话）：此时 bridge 为空
    /// 表示“正在打开”，不是“不支持更早历史”。
    public var expectsPipeline: Bool { messageLayer != nil && sessionScope != nil }
    public var olderFailure: String? {
        if case .failed(let message) = olderState { return message }
        return nil
    }

    /// 唯一写入口：进行中的清理不会覆盖已经落地的失败终态。
    ///
    /// 事件也在这里发：任何一次状态迁移都必须留下一条记录，而不是只记"开始加载"。
    /// 2026-10-18 第一次读日志时 spinner 只出现 older=1、没有配对的 0，就是因为
    /// 收尾走的是另一个方法、没有发事件——诊断事件必须挂在唯一写入口上。
    private var olderWatchdog: Task<Void, Never>?

    func setOlderState(_ next: OlderPageState) {
        // 相同状态不重复发事件：启动阶段会连续多次落到 idle，重复事件既无信息，
        // 又会挤占每条来源每秒 10 条的配额，把真正的 1→0 迁移挤掉。
        guard next != olderState else { return }
        olderState = next
        DSHLog.event("list.spinner", ["older": next == .loading ? "1" : "0"])
        olderWatchdog?.cancel()
        olderWatchdog = nil
        if next == .loading {
            olderWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self, self.olderState == .loading else { return }
                DSHLog.event("anomaly.loading", ["waitedMs": "8000"])
            }
        }
    }

    /// 请求收尾：只在仍处于进行中时回到空闲，失败/到头的终态保持不变。
    func finishOlderIfLoading() {
        setOlderState(olderState.finishing())
    }
    /// 视图只读这一位的投影；更早历史的状态由管道与宿主快照给出（FR-005/FR-038）。
    public internal(set) var hasOlder = false

    /// 还有等待补上的缺口行。顶部触发不能只看 `hasOlder`：读者已经到最早时，
    /// 区间里仍可能留着上次没补完的小洞，只靠 hasOlder 会永远不再发请求。
    public var hasUnfilledGaps: Bool { pipelineBridge?.hasUnfilledGaps ?? false }
    /// 宿主权威的"还有更早"由 `hasOlder` 直接表达；失败不写它（FR-003）。
    public internal(set) var lastError: String?

    /// Model routes the host can serve.
    ///
    /// Refreshed rather than loaded once: the desktop can add a provider route
    /// (a company gateway, a second vendor) while the phone is open, and waiting
    /// for an app restart to see it made the picker look like it was missing
    /// models it could actually use.
    /// 模型目录与权限（存储在 `catalogState`，这里保留同名投影）。
    let catalogState = CatalogState()

    public var catalog: ModelCatalog? { catalogState.catalog }
    /// True while the "make this the default for new sessions" write is in flight.
    public private(set) var isSettingDefaultModel: Bool {
        get { catalogState.isSettingDefaultModel }
        set { catalogState.isSettingDefaultModel = newValue }
    }
    /// Set when that write failed, so the picker can say why.
    public private(set) var defaultModelError: String? {
        get { catalogState.defaultModelError }
        set { catalogState.defaultModelError = newValue }
    }
    public private(set) var currentSelection: ModelSelection? {
        get { catalogState.currentSelection }
        set { catalogState.currentSelection = newValue }
    }
    public private(set) var permissionOptions: [PermissionsProjection.Option] {
        get { catalogState.permissionOptions }
        set { catalogState.permissionOptions = newValue }
    }
    public private(set) var currentPermission: String? {
        get { catalogState.currentPermission }
        set { catalogState.currentPermission = newValue }
    }
    /// How long a catalog stays fresh.
    private static let catalogMaxAge: TimeInterval = 300

    /// Composer state（存储在 `composer`，这里保留同名投影）。
    public var draft: String {
        get { composer.draft }
        set { composer.draft = newValue }
    }
    /// Whether the next submission queues behind the turn or steers into it.
    public var steerNext: Bool {
        get { composer.steerNext }
        set { composer.steerNext = newValue }
    }

    /// Bumped whenever the transcript grows, so the view can autoscroll.
    public internal(set) var scrollSignal: Int = 0
    /// 搜索范围（时间线 + 搜索缓冲）变了多少次，给搜索面板当刷新信号。
    public internal(set) var searchScopeVersion: Int {
        get { searchState.scopeVersion }
        set { searchState.scopeVersion = newValue }
    }
    /// 正在往前取搜索缓冲（面板据此显示转圈）。
    public internal(set) var isExtendingSearch: Bool {
        get { searchState.isExtending }
        set { searchState.isExtending = newValue }
    }
    /// 补页（在时间线**头部**插入更早的消息）完成的次数。
    ///
    /// 要这一位是因为"追上尾部"和"往前补一页"必须分开：前者该钉到底部，后者
    /// 一次都不能动视口。以前补页也发 `scrollSignal`，于是读者刚翻到上面、跟随
    /// 状态还没被判成"用户自己在滚"的时候，补回来的一页会把人拽回底部；
    /// 而新插入的内容本身又会把视口顶到"新那段的开头"（2026-09-24 用户反馈）。
    /// 现在由视图自己按 `timeline.items.first` 把位置锚回来，见 `ChatView.pumpOlder`。
    public internal(set) var prependSignal: Int = 0
    /// Bumped when the user themselves adds something, which is the one case
    /// where the view should jump back to the bottom even if they had scrolled
    /// away: they are waiting to see their own message land.
    public internal(set) var sendSignal: Int = 0

    /// internal(set)：ChatModel+Follow 的可见性兜底要读 client（T019）。
    private(set) var store: (any LinkService)?
    private var hub: HostEventHub?
    /// 009 消息层（T012：MessageStore 有数据时优先用它画进会话首帧）。
    /// internal：冷启动半边在 ChatModel+ColdStart.swift（文件按职责拆分）。
    weak var messageLayer: MessageLayer?
    /// Warm transcripts, most recently used last.
    private let transcriptCache = TranscriptCache()

    /// 搜索缓冲（存储在 `searchState`）：往前读进来、但还没并进时间线的那一段。
    var searchRecords: [SessionRecord] {
        get { searchState.records }
        set { searchState.records = newValue }
    }
    var searchOldestSeq: Int? {
        get { searchState.oldestSeq }
        set { searchState.oldestSeq = newValue }
    }
    /// `searchItems` 的结果缓存，键是"缓冲条数 + 时间线条数"。
    var cachedSearchItems: (key: String, items: [TimelineItem])? {
        get { searchState.cachedItems }
        set { searchState.cachedItems = newValue }
    }

    /// 转写尾部的落盘层（T027：007 `TranscriptStore` 退役，统一到 009 `MessageStore`）。
    ///
    /// 内存缓存让"再进同一个会话"很快，但 App 一冷启动就归零，于是打开会话仍然是
    /// 空白 + 转圈。落盘的是**原始记录**的尾部——和 `session/follow` 打开时给的快照
    /// 是同一种东西，所以恢复路径与合并路径都复用现成逻辑。
    /// 磁盘层缺位（建库失败）时读写一律空转，行为退化为"只有内存缓存"。
    /// 磁盘层的入口。**不再直接持 `MessageStore`**：读写都走门面（`MessageLayer`），
    /// 实现层的类型名不出现在产品路径里（spec 023 边界收敛）。
    var messageBacking: MessageLayer? { messageLayer }
    /// 落盘尾部保留多少条（沿用 007 `SessionTranscriptCache.maxRecords` 的值）。
    private static let tailRecordLimit = 200
    /// 搜索缓冲一次从磁盘读多少条（沿用 007 `maxOlderRecords` 的值）。
    private static let searchBufferDiskLimit = 3000
    /// Writes are chained instead of fired in parallel: an actor serializes them,
    /// but *creation* order is what keeps "the newer page wins" true. Awaiting the
    /// chain is how a flush is expressed.
    private var writeChain: Task<Void, Never>?

    /// 最近的记录（尾部），落盘写的就是它。
    var recentRecords: [SessionRecord] = []
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
    private(set) var sessionScope: String?

    /// 「我问过的」按需灌库是否正在进行（面板切到该筛选时会触发一次，见 `+UserInputs`）。
    var isBackfillingUserInputs = false

    /// 这次打开用的同步计划（快照到达时还要用它判断合并还是重来）。
    private var syncPlanRef = TranscriptSyncPlan.plan(localThrough: nil, hostCursor: 0)

    public typealias Draft = ComposerDraft
    /// 内存里最多留多少行；超出的从最老端丢（记录仍在库里，可读回）。
    static var windowLimitRows: Int {
        #if DEBUG
        if let override = ChatProbe.shared.windowRows, override > 0 { return override }
        #endif
        return 5000
    }
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
    var beforeVisibleSwap: (@MainActor () async -> Void)?
    #endif
    /// 009 渲染数据源桥（tasks T013）：非 nil 时，时间线由 MessagePipeline 的
    /// 快照驱动（订阅/折叠/重试全在 ChatModel+Pipeline.swift 的桥里）。
    ///
    /// 2026-10-21：旧的 `TranscriptPager` 回退路径已删除；生产路径恒有桥。
    /// 桥缺位时 `loadOlder` 报可见的「尚未连接」，不再静默当到底。
    var pipelineBridge: ChatPipelineBridge?
    /// 009 跟底两态（tasks T017）：判定逻辑在 ChatModel+Follow.swift，
    /// 存储只能留在主文件（扩展不能有存储属性）。
    public enum FollowState: String { case atBottom, reading }
    /// 只允许 ChatModel+Follow 的迁移入口改写（Swift 没有"跨文件只读"，
    /// 写权限按模块内纪律约束）。
    public var followState: FollowState = .atBottom
    /// 033：读者刚点过过程节点，暂时抑制"贴底即恢复跟随"。
    /// 用模型属性而不是 View 的 @State，是因为滚动几何回调可能在
    /// SwiftUI 重建之前就到达，读到的是旧闭包里的值。
    public internal(set) var processToggleFollowHold = false
    /// reading 期间到达的新消息数（「↓ 新消息」胶囊的未读数，T018）。
    public var unreadWhileReading = 0
    /// 尾部追平（点胶囊/可见性兜底）进行中：胶囊转 spinner，兜底去重（T018/T019）。
    public var isCatchingUpTail = false
    /// 可见性兜底的幂等闩（T019）：一次只跑一轮「对 lastSeq」。
    var tailSyncInFlight = false
    /// 本地窗口最老的数据行 seq（搜索缓冲与落盘用）。
    ///
    /// 管道模式下以桥里的记录为准；其余情况取时间线里第一条非缺口、非过程节点行。
    var oldestSeq: Int? {
        if let bridge = pipelineBridge { return bridge.records.keys.min() }
        return timeline.items.first(where: { item in
            switch item.kind {
            case .gap, .processHeader, .processStep, .runningLine: return false
            default: return true
            }
        })?.seq
    }
    /// The cut the follow stream opened at; older pages must stay below it.
    private var throughSeq: Int = 0

    var address: SessionAddress? { session?.address }

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
        #if DEBUG
        if ChatProbe.shared.processFoldFixture {
            var fixture = ChatTimeline()
            _ = fixture.reset(with: ProcessFoldFixture.records)
            visible = VisibleSession(summary: summary, timeline: fixture)
            // 夹具里的运行轮也要有计时起点（与真实 open 同一条规则：用 turn/start 的时间）。
            runningSince = fixture.openTurnStartedAt
            foldState = TranscriptFoldState()
            prefetchStatus.removeAll()
            cachedSearchItems = nil
            searchScopeVersion += 1
            phase = .ready
            scrollSignal += 1
            return
        }
        #endif
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
        let cached = transcriptCache.entry(for: key)
        // 换会话：更早历史的搜索缓冲属于上一个会话，任何分支都要清（FR-006）。
        // 以前只在"没有本地数据"那一支清，于是命中缓存/命中落盘时会把上一个会话
        // 的更早记录带进新会话，甚至能并进它的时间线。
        clearSearchHistory()
        processToggleFollowHold = false
        // 同一会话的重试/重开保留读者的展开状态；只有换会话才重置。
        if visible?.summary.sessionId != key {
            stopQueueSubscription()
            foldState = TranscriptFoldState()
            prefetchStatus.removeAll()
            summaryScreenState = .idle
            summaryScreenTask?.cancel()
            summaryScreenTask = nil
            stepBodies.removeAll()
            for task in stepBodyTasks.values { task.cancel() }
            stepBodyTasks.removeAll()
        }
        setOlderState(.idle)
        // This session's own half-written message, not the last one's.
        composer.load(sessionId: key)
        lastError = nil
        hostReportsRunning = summary.running
        isAwaitingTurnStart = false
        catalogState.load(from: summary)
        // 分页状态同样归上一个会话：先清掉，等这个会话的窗口观察再置位。
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
        // 换会话就丢掉上一个会话的标题覆盖，避免把 A 的标题带到 B。
        titleOverride = nil
        visible = VisibleSession(summary: summary, timeline: seed)
        if let cached {
            throughSeq = max(cached.throughSeq, summary.asOfSeq)
            noteWindow(oldest: cached.oldestSeq, hasMore: cached.hasOlder)
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
                noteWindow(oldest: nil, hasMore: false)
                phase = .loading
            } else {
                // 冷启动/新进程：用落盘的尾部立刻把转写画出来，**不进 loading**。
                // 随后 follow 的快照会按 seq 合并进来，只补差量。
                timeline.reset(with: stored.records)
                recentRecords = stored.records
                throughSeq = max(stored.newest ?? 0, summary.asOfSeq)
                noteWindow(oldest: stored.oldest, hasMore: stored.hasOlder)
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
            noteWindow(oldest: nil, hasMore: false)
            phase = .loading
        }

        syncPlanRef = syncPlan
        // T011：点开的会话以 .jump 插队水合最新页进 009 磁盘层（抢占在途预取）。
        // v2 能力在时首屏由概要页负责（`loadSummaryScreen`），这条 v1 的"最新页
        // 水合"不再需要：再发一次只会把同一段按 v1 重取一遍。
        if store?.chatHost?.historySummaryFoldEnabled != true {
            warmMessageLayer(for: summary)
        }
        // T013：渲染数据源切到 MessagePipeline 快照（管道缺位时桥为 nil，走原路径）。
        startPipelineSubscription(for: summary)
        startFollowing(link: link, summary: summary, maxMessages: syncPlan.maxMessages,
                       generation: openGeneration)
        // 宿主排队输入：`session/control` 只取当前会话的队列（设计 §3）。
        startQueueSubscription(for: summary)
        // 首屏概要（能力 `history-fold-summary-v2`）：缓存骨架已画出来之后才发，
        // 只为"还没有概要的新轮次"发一次；失败落到页级重试条，不静默。
        summaryScreenTask?.cancel()
        summaryScreenTask = Task { [weak self] in
            await self?.loadSummaryScreen()
        }
        await restoreSearchHistory()
        // 打开一个正在跑的会话：优先用 `turn/start` 自带的时间做起点，切后台/重开不重置；
        // 窗口里确实没有这一轮的起点时（裁到轮次中间）才退回“现在”，作为下限。
        runningSince = timeline.isTurnOpen
            ? (timeline.openTurnStartedAt ?? Date())
            : nil
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
        runningSince = nil
        stopQueueSubscription()
        foldState = TranscriptFoldState()
        prefetchStatus.removeAll()
        summaryScreenTask?.cancel()
        summaryScreenTask = nil
        summaryScreenState = .idle
        stepBodies.removeAll()
        for task in stepBodyTasks.values { task.cancel() }
        stepBodyTasks.removeAll()
        processToggleFollowHold = false
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
        transcriptCache.clear()
        composer.reset()
        lastError = nil
        catalogState.reset()
        hasOlder = false
        setOlderState(.idle)
        throughSeq = 0
        pendingStreamFrames.removeAll()
        clearSearchHistory()
        foldState = TranscriptFoldState()
        prefetchStatus.removeAll()
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

    /// 搜索面板顶部统计行的口径（抽成纯函数，能单测；文案由界面层给）。
    ///
    /// 三种来源分开说，且**连接器那条要带上"其中我的提问多少条"**：全局搜索按时间倒序混着
    /// 助手/工具命中，一个人的提问会散在后面几页里（2026-10-17 实测：当前会话搜「我」共 201 条，
    /// 其中我的提问 23 条，散落在 5 页）。只给总数会让人以为"我的提问没被搜到"。
    public enum SearchSummaryKind: Equatable, Sendable {
        /// 浏览「我的提问」：只有条数。
        case browsing(count: Int)
        /// 连接器扫描：命中数 + 我的提问数 + 扫描进度（进度可能未知）。
        case connector(count: Int, mine: Int, progress: SearchPage.SearchProgress?, scanning: Bool)
        /// 本地全量库：命中数。
        case localStore(count: Int)
        /// 本地窗口：搜了多少条 + 命中多少条。
        case localWindow(searched: Int, count: Int)
    }

    public static func summaryKind(source: SearchChannel, hits: [TranscriptSearchHit],
                                   scanned: Int, progress: SearchPage.SearchProgress?,
                                   hasMore: Bool) -> SearchSummaryKind {
        switch source {
        case .localStore:
            return .localStore(count: hits.count)
        case .localWindow:
            return .localWindow(searched: scanned, count: hits.count)
        case .connector:
            let mine = hits.filter { $0.role == .me }.count
            return .connector(count: hits.count, mine: mine, progress: progress, scanning: hasMore)
        }
    }

    /// 最近一次搜索被连接器拒绝的原因（成功、走本地、或还没搜过时为 nil）。
    ///
    /// 为什么要有它：连接器拒绝（`link/unsupported` / `link/query-too-short` / 超时）
    /// 原来被 `try?` 吞成 nil，界面把它当成"没有命中"——正是 spec 007 FR-013 要求区分开的
    /// 两件事。现在界面据此显示一条提示，而不是假装搜到了零条。
    public internal(set) var searchRefusalReason: String? {
        get { searchState.refusalReason }
        set { searchState.refusalReason = newValue }
    }

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
    var effectiveCapabilities: Set<String> {
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
    func loadContextForHits(_ hits: [HistorySearchHit]) async {
        guard let lowest = hits.map(\.seq).min() else { return }
        // 概要 v2：命中的是过程正文（工具结果 / 思考），它没有独立行。展开到
        // 那一条步骤行并按需取回正文；否则搜索能搜到、跳转却永远落不到它。
        // 这一步只碰时间线/模型与单条接口，不依赖本地库，所以排在下面那个
        // guard（需要 `messageBacking`）之前。
        _ = await revealSummaryStepHit(at: lowest)
        guard let sessionId = session?.sessionId, let scope = sessionScope,
              let store = messageBacking else { return }
        // 命中落在连接器折好下发的过程段里（v1）：那一行还没取回来，先按摘要的
        // seq 段展开（普通窗口、不带 fold）。
        if store != nil, timeline.items.contains(where: { item in
            if case .processHeader(let header) = item.kind, header.isPrefetched,
               header.startSeq <= lowest, lowest <= header.endSeq { return true }
            return false
        }),
           let header = timeline.items.compactMap({ item -> TimelineProcessHeader? in
            if case .processHeader(let header) = item.kind, header.isPrefetched,
               header.startSeq <= lowest, lowest <= header.endSeq { return header }
            return nil
        }).first {
            await loadPrefetchedSummary(header, range: header.startSeq...header.endSeq,
                                        turnKey: header.id)
            // 等一次整树重建把行落进时间线，后面的命中定位才有行可指。
            for _ in 0..<3 { await Task.yield() }
        }
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

    /// 概要 v2 的搜索命中：把那一轮、那一组与那一条步骤展开，并取回该条正文。
    ///
    /// 步骤行不是日志行：它只在"轮 → 组 → 步骤"都展开后才出现在显示行里，
    /// 所以命中列表生成之前必须先展开（`loadContextForHits` 在 `attach` 之前调用）。
    @MainActor
    private func revealSummaryStepHit(at seq: Int) async -> Bool {
        let plan = processPlan()
        for turn in plan.turns {
            for group in turn.groups {
                guard let step = group.steps.first(where: {
                    $0.resultSeq == seq || $0.seq == seq
                }) else { continue }
                foldState.manualTurn[turn.key] = true
                foldState.expandedGroups.insert(group.key)
                foldState.expandedSteps.insert(step.id)
                await loadProcessStepBody(step)
                ChatProbe.shared.probeNote?("search.stepHit", [
                    "seq": String(seq), "step": step.id, "turn": turn.key,
                ], true)
                return true
            }
        }
        return false
    }

    /// 把搜索缓冲写盘（读者往下翻一页都会走一次）。
    func persistSearchHistory() {
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
        searchState.reset()
    }

    /// Re-opens the session on screen after the link came back.
    ///
    /// The follow stream dies with the socket, and a transcript that stopped
    /// updating looks exactly like one where nothing is happening — the worst
    /// possible failure for a client whose job is "is it still working?".
    /// Re-opening reuses the warm cache, so the rows and the reading position
    /// stay where the user left them.
    public func reopenAfterReconnect() async {
        guard store?.chatHost != nil else { return }
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

    /// Keeps the composer's contents under the session it was typed for.
    ///
    /// Called on the way out of a session, so nothing typed is lost and nothing
    /// leaks: the next session loads its own draft (usually empty).
    private func stashDraft() {
        guard let key = session?.sessionId else { return }
        composer.stash(sessionId: key)
    }

    /// What the store knows about this session's window, or `nil` when it has none.
    /// 冷启动时最多从本地库恢复多少条。**内存上限落在这一步**，而不是运行时裁剪。
    ///
    /// 为什么不裁剪：运行时缩短 `items` 会让在飞的 `scrollTo` 目标失效并 SIGABRT
    /// （2026-10-08 run 20261008-202231）。"打开时只恢复最近一段"没有这个问题——
    /// 那是一次性的、发生在任何滚动之前；更早的部分读者往回滑时由已验过的本地读回补上
    /// （用例 47：窗口回填之前没有任何联网取页，即 0 网络）。
    ///
    /// 600 条 ≈ 300 行：足够填满一屏并留出上下滑动的余量，又不至于把上万条的会话一次性装进内存。
    private static let restoreRecordLimit = 600

    /// 冷启动尾部恢复（T027 起直接读 009 `MessageStore`：session_state + 最新页）。
    func loadStoredTail(scope: String, sessionId: String) async -> StoredTail? {
        guard let store = messageBacking,
              let state = try? await store.sessionState(scope: scope, sessionId: sessionId)
        else { return nil }
        let records = (try? await store.windowBefore(
            scope: scope, sessionId: sessionId, seq: Int.max,
            limit: min(Self.tailRecordLimit, Self.restoreRecordLimit))) ?? []
        guard !records.isEmpty else { return nil }
        // `state.oldestSeq` 是"库里存的最老一条"；恢复被限流之后，时间线的最老一条
        // 可能比它新——窗口下界必须按**实际恢复**的那一条算，否则会以为"更早的都在手上"。
        let restoredOldest = records.first?.event.seq ?? state.oldestSeq
        return StoredTail(records: records, oldest: restoredOldest, newest: state.newestSeq,
                          hasOlder: (restoredOldest ?? 1) > 1 || state.hasMore)
    }

    /// The tail the store can hand back on a cold start.
    /// internal：ChatModel+ColdStart.swift 的 009 首帧路径复用同一形状。
    struct StoredTail {
        public let records: [SessionRecord]
        public let oldest: Int?
        public let newest: Int?
        public let hasOlder: Bool
    }

    private func saveToCache() {
        guard let key = session?.sessionId, !timeline.items.isEmpty else { return }
        transcriptCache.store(
            TranscriptCache.Entry(
                timeline: timeline,
                hasOlder: hasOlder,
                oldestSeq: oldestSeq,
                throughSeq: throughSeq,
                records: recentRecords
            ),
            for: key
        )
    }

    /// Drops one session's cached transcript, e.g. after it is deleted.
    public func forget(_ sessionId: String) {
        transcriptCache.remove(sessionId)
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

    /// 退后台/被挂起：把 009 的批量写队列（pending / confirm）立刻落盘。
    ///
    /// 旧路径的 `persistTranscriptNow` / `flushTranscript` 只管 ChatModel 自己的写链，
    /// 管道模式下它们直接 return；009 的写队列没有定时器，不显式冲就会停在内存里，
    /// 进程被杀后磁盘上只剩 pending，重启时就会被误判成"没发出去"。
    public func flushPipelineWrites() async {
        await messageLayer?.flushWrites()
    }

    func enqueueAppend(scope: String, sessionId: String, records: [SessionRecord]) {
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
                // 以 host 为准：`hasMore=false` 意味着这次快照的窗口已经退到日志开头，
                // 那就真的没有更早的了；不再叠加本地旧状态。
                hasOlder = snapshot.hasMore
                    || (snapshot.records.first?.event.seq ?? 1) > 1
            }
            phase = .ready
            if pipelineBridge == nil { scrollSignal += 1 }
            // 快照要**并进**本地尾部，不能替换：本地可能存着 200 条，而这次的快照
            // 只有 20 条（本地很新时故意少要），直接替换等于把已落盘的历史截掉
            // ——用户看到的就是"切后台回来少了一部分记录"。
            mergeTail(snapshot.records)
            // 快照里已经有一轮在跑：起点取快照里那条 `turn/start` 的时间；
            // 拿不到就保持 nil（只写「深度求索中」），不从“现在”起算。
            if runningSince == nil, Self.snapshotEndsInOpenTurn(snapshot.records) {
                runningSince = snapshot.records.reversed()
                    .first { $0.event.type == "turn/start" }?.event.date ?? Date()
            }
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
            if event.type == "session/title",
               let title = event.data["title"]?.stringValue,
               !title.isEmpty {
                titleOverride = title
                if let id = session?.sessionId { onSessionTitle?(id, title) }
            }
            mergeTail([SessionRecord(event: event)])
            persistIfDue()
            // A live event proves the stream is healthy even if the summary
            // was stale when the list was fetched.
            if phase != .ready { phase = .ready }
            reactToTurnLifecycle(event)

        case .assistantStream(let streamFrame):
            liveStreamCounter.apply(streamFrame)
            liveStreamChars = liveStreamCounter.chars
            liveStreamFrames += 1
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
            // 以这条事件自己的宿主时间为准：桥接的时间线可能是异步更新的，
            // 此刻 `openTurnStartedAt` 还停在上一条轮（新轮会把计时接在旧起点上）。
            runningSince = event.date ?? timeline.openTurnStartedAt ?? Date()
            awaitingTimeout?.cancel()
            awaitingTimeout = nil

        case "turn/end":
            isAwaitingTurnStart = false
            hostReportsRunning = false
            runningSince = nil
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

    /// 宿主为当前会话生成/修改标题时的回调（会话级归属由这里决定）。
    public var onSessionTitle: ((String, String) -> Void)?
    /// 宿主给的标题：聊天页标题优先用它，不必等 session/list。
    public private(set) var titleOverride: String?

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
        guard let client = store?.chatHost, let current = session else { return }
        guard let value = try? await client.sessions(),
              let updated = value.items.first(where: { $0.sessionId == current.sessionId })
        else { return }
        // 只换摘要本身（标题/运行态/权限），时间线仍属于同一个会话，所以这一处赋值
        // 依然是自洽的一对——不要在这里重发 `visible`，否则会把正在流式的时间线冲掉。
        visible?.summary = updated
        hostReportsRunning = updated.running
        catalogState.currentPermission = updated.projections?.values?.permissions?.currentValue
        timeline.record(usage: updated.projections?.values?.tokenUsage)
    }

    private func loadCatalog(link: LinkGateway) async {
        guard catalogState.catalog == nil else { return }
        await refreshCatalog(link: link)
    }

    /// Re-reads the host's model routes.
    ///
    /// A failure keeps the catalog already on screen: a picker that empties out
    /// because one request timed out is worse than a slightly stale list.
    public func refreshCatalog(link: LinkGateway? = nil) async {
        guard let link = link ?? store?.link else { return }
        if let fresh = try? await link.modelCatalog() {
            catalogState.adopt(fresh)
        }
    }

    /// Re-reads the catalog when it is older than the freshness window.
    public func refreshCatalogIfStale() async {
        if let at = catalogState.fetchedAt, catalogState.catalog != nil,
           Date().timeIntervalSince(at) < Self.catalogMaxAge {
            return
        }
        await refreshCatalog()
    }

    /// The model new sessions start with, as the host reports it.
    public var defaultSelection: ModelSelection? { catalogState.defaultSelection }

    /// Makes one model the default for sessions created from now on.
    ///
    /// Deliberately separate from ``selectModel(_:)``: that one changes the
    /// session on screen, while this writes the host's `agent-default-model`
    /// setting and therefore every session started afterwards — including ones
    /// started on the desktop.
    public func setDefaultModel(_ selection: ModelSelection) async {
        guard let client = store?.chatHost, let link = store?.link else { return }
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

    /// 向上翻一页更早的历史。
    ///
    /// 生产路径只有管道一条：缺口、重试、到头都由 `SessionPipeline` 的状态机表达。
    /// 桥缺位（数据层未就绪）时给出可见失败，不把"未知"静默当"到底"。
    /// 记录一次窗口观察（打开会话时来自缓存/落盘，管道建立后由重建入口接管）。
    ///
    /// 旧 `TranscriptPager` 删除后，这里只落两个视图可见的事实：最老 seq 与"还有更早"。
    private func noteWindow(oldest: Int?, hasMore: Bool) {
        hasOlder = hasMore || (oldest ?? 1) > 1
        setOlderState(.idle)
    }

    // MARK: - 009 管道重建落点（tasks T013/T016；桥在 ChatModel+Pipeline.swift）

    /// 桥算好的整棵折叠结果落进时间线。在这里（而不是扩展里）落地，是因为它
    /// 要写 `timeline` / `hasOlder` 这些 private(private(set) 成员。
    ///
    /// 在飞状态（流式气泡、发送中的乐观回声）不在下行记录里，重建时必须接回
    /// （`restoreTransient`），否则每一次快照 diff 都会把它们抹掉一帧。
    func applyPipelineRebuild(
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
        hasOlder = !topExhausted && (oldestSeq ?? 1) > 1
        searchScopeVersion += 1
        #if DEBUG
        // `-DSHProbeStaleSend`：把最后一条用户消息标成「已发送，未确认」。
        // 真实触发要宿主撤单（`MessagePipeline.markUnconfirmed`），没有用例能稳定造出来，
        // 所以留一个只改状态位的注入口给截图/UI 用例核对徽标。
        if ChatProbe.shared.staleSendState,
           let row = timeline.items.last(where: { item in
               if case .userMessage = item.kind { return true }
               return false
           }) {
            timeline.markSendStates([row.seq: .unconfirmed])
            noteWantsBottom()
        }
        #endif
    }

    /// 只刷新缺口行（加载/失败/到头三态变化，数据行不动）。
    func applyPipelineGaps(_ gaps: [TimelineItem]) {
        timeline.setGaps(gaps)
        scrollSignal += 1
    }

    /// T020 流式快进路落点：单行增量更新（只改写流式气泡行的文本，不整树
    /// 重折）。返回 false = 该行还没折进时间线，调用方回退整树重折。
    /// 提交走 `scrollSignal` → 宿主 reconcile（008 统一锚一次修正，T021），
    /// 阅读中不冻结渲染也不推走视口。
    @discardableResult
    func applyStreamingRow(seq: Int, text: String, reasoning: String) -> Bool {
        guard timeline.applyStreamingUpdate(seq: seq, text: text, reasoning: reasoning) else {
            return false
        }
        scrollSignal += 1
        return true
    }

    /// 管道模式下的「向上翻页」进行中（顶部缺口行 spinner 与旧版小字共用此位）。
    /// 管道把取页状态写进来的唯一入口（旧的两个写点已删除）。
    func notePipelineOlder(state: OlderPageState) {
        setOlderState(state)
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

    /// The channel-choosing fetcher for this session, or `nil` before a connection.
    /// 一页有多大：时间线要"一屏一屏"地补（60 条），搜索缓冲要"一大段"地读。
    ///
    /// 为什么搜索缓冲必须是大的（2026-10-08 用例 44 实测）：旧 `session/page` 的"60 条"
    /// 指的是**消息**条数，实际会回 ~300 条记录；换成精确窗口之后 "60" 指的是记录条数，
    /// 同样一次调用覆盖的历史短了约 5 倍，于是"只看我的提问"往下滑能看到的老提问少了一大截。
    enum PageSize {
        public static let timeline = 60
        static let searchBuffer = 300
    }

    /// 搜索缓冲一次从本地读多少条。
    static let localSearchReadLimit = 300
    /// 为一条命中补上下文时读多少条（命中要能落到某一个已加载的行上）。
    private static let hitContextLimit = 60
    /// 行载荷预算（spec 008 的契约默认值：32MB）。DEBUG 下可被探针压小，
    /// 否则真实会话永远达不到预算、"丢弃"这条路在用例里就永远看不到。
    static var payloadBudgetBytes: Int {
        #if DEBUG
        if let kb = ChatProbe.shared.payloadBudgetKB { return kb * 1024 }
        #endif
        return 32 * 1024 * 1024
    }

    func makePageFetcher(pageSize: Int = PageSize.timeline) -> TranscriptPageFetcher? {
        guard let client = store?.chatHost, let address else { return nil }
        let capabilities = effectiveCapabilities
        #if DEBUG
        let shortfall = ChatProbe.shared.pageShortfall
        #else
        let shortfall = 0
        #endif
        let filter: (@Sendable (TranscriptPage) -> TranscriptPage)? = shortfall > 0
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
    private nonisolated static func droppingNewest(_ count: Int, from page: TranscriptPage) -> TranscriptPage {
        guard page.records.count > count else { return page }
        let kept = Array(page.records.dropLast(count))
        return TranscriptPage(
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
    /// 于是面板会显示"已经是最开头"而时间线还能继续翻。现在只问本地窗口（FR-005）。
    public var canExtendSearch: Bool {
        // 只问"本地库里还有没有"：宿主日志可能已被裁到快照覆盖的范围，而本地库仍存着
        // 更早的老提问（2026-10-08 用例 44/46 实测）。宿主是否到底不是这里的判据。
        searchOldestSeq ?? oldestSeq ?? 1 > 1
    }

    // MARK: - Outbound actions

    /// Adds prepared pictures to the next prompt.
    ///
    /// 025 阶段4b：造这一批载荷要 UIImage（缩放 + JPEG 编码），所以「从 UIImage 加」
    /// 留在界面层（`DSHChatUI` 的 `ChatModel+DraftImages.swift`）；领域层只收结果。
    public func addDraftImages(_ images: [DraftImage]) {
        composer.images.append(contentsOf: images)
    }

    public func removeDraftImage(id: UUID) {
        composer.images.removeAll { $0.id == id }
    }

    public func clearDraftImages() {
        composer.images.removeAll()
    }

    /// Submits the composer's text.
    ///
    /// Steer mode interrupts the running turn instead of queueing behind it,
    /// which is how the desktop client's "steer" affordance behaves.
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
    func announceStagedFile(
        _ staged: StagedFile,
        name: String,
        owner: String
    ) async {
        let text = "我发送了一个文件，已保存到：\(staged.path)（\(staged.bytes) 字节）"
        guard session?.sessionId == owner else {
            composer.store(text: text, images: [], for: owner)
            return
        }
        draft = text
        await send()
    }

    /// The prompt body: the words, then one part per picture.
    static func promptContent(text: String, images: [DraftImage]) -> [PromptContentPart] {
        var content: [PromptContentPart] = []
        if !text.isEmpty { content.append(.text(text)) }
        for image in images {
            content.append(.image(mediaType: image.mediaType, data: image.base64, name: image.name))
        }
        return content
    }

    /// Cancels the running turn.
    public func cancel() async {
        guard let client = store?.chatHost, let session else { return }
        do {
            try await client.cancel(sessionId: session.sessionId)
            isAwaitingTurnStart = false
        } catch {
            lastError = LinkErrors.describe(error)
        }
    }

    public func rename(to title: String) async {
        guard let client = store?.chatHost, let session else { return }
        do {
            try await client.rename(sessionId: session.sessionId, title: title)
            await refreshSummary()
        } catch {
            lastError = LinkErrors.describe(error)
        }
    }

    /// Forks the session, returning the new session's id when the host reports it.
    public func fork() async -> String? {
        guard let client = store?.chatHost, let session else { return nil }
        do {
            let value = try await client.forkSession(sessionId: session.sessionId)
            return value["sessionId"]?.stringValue ?? value["id"]?.stringValue
        } catch {
            lastError = LinkErrors.describe(error)
            return nil
        }
    }

    public func selectModel(_ selection: ModelSelection) async {
        guard let client = store?.chatHost, let session else { return }
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
        guard let client = store?.chatHost, let session else { return [] }
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


public extension ChatModel.OlderPageState {
    /// 收尾规则：进行中回到空闲，失败与到头是终态。
    /// 单测直接断言这一条——旧实现把失败当成"加载结束"一起清掉，界面才会一直转。
    func finishing() -> Self {
        self == .loading ? .idle : self
    }
}

import Foundation
import OSLog

/// 单会话内存流水线（spec 009 架构决定 §2/§6/§7 / tasks T008）。
///
/// 一个会话的全部运行时状态都串行在这个 actor 里：有效连续区间集（RangeIndex）、
/// 热窗口（最近 500 条，超出淘汰最老）、in-flight 页表（同页合并/取消/抢占）、
/// 落库队列（按消息去重）、流式按帧合并的缓冲。
///
/// 对外只有三件事：
/// 1. `records(in:)` ——「取不到就拉」水合：区间集二分，命中走热窗口/磁盘，
///    缺口按对齐页（50 条）经注入的 fetch 拉网络，回包合并进三处
///    （热窗口 + 区间集 + 落库队列）并产出 `Diff`。
/// 2. `apply(event:)` / `apply(stream:)` —— 下行合并。流式增量先进缓冲，
///    经 `frameTick` 节拍（测试注入立即返回，产品接 CADisplayLink）合并成
///    一次状态变更，一个 tick 内多次增量只出一个 diff（spec 剩余卡顿源①）。
/// 3. `diffs()` —— 每次状态变化产出 `Diff`（insert/update 的记录、remove 的
///    seq、由区间集派生的 gap 行列表），供 MessagePipeline 组装快照。
///
/// 失败语义（spec 可见性兜底）：拉取失败重试上限 3 次，超限的缺口标
/// `failed(retryable: true)`；只有 `hasMore=false` 或 `clamped` 才允许「到头」，
/// 网络失败永远不得静默当作到底。
///
/// 淘汰语义（T028 裁定）：热窗口只是缓存，超上限缩窗**不进** `diff.removed`——被淘汰的行
/// 仍由磁盘覆盖（ranges 语义不变），回看时「取不到就拉」会水合回来；UI 侧的行裁剪由 008
/// 宿主的 reclaim/dropOldestRows 两层负责，重订阅首帧（`snapshot()`）以热窗口为准是合法的。
public actor SessionPipeline {

    // MARK: - 对外类型

    /// 网络取页的注入面（测试用内存脚本化假回包；产品侧适配 TranscriptPageFetcher）。
    public struct FetchPage: Sendable {
        public let records: [SessionRecord]
        public let hasMore: Bool
        /// 服务端日志被裁剪：允许「到头」（spec 场景 6 与 FR-038 语义沿用）。
        public let clamped: Bool

        public init(records: [SessionRecord], hasMore: Bool, clamped: Bool = false) {
            self.records = records
            self.hasMore = hasMore
            self.clamped = clamped
        }
    }

    public typealias PageFetch = @Sendable (ClosedRange<Int>, FetchPriority) async throws -> FetchPage

    /// 尾部（更新方向）探空一次后不再立刻重探：live 更新走 follow 流，
    /// 每次滚窗都重打同一页纯属浪费；任何一条新记录落地即复位。
    /// 注意只覆盖「更新方向」——更早方向拉空是异常，按 T038 计失败。
    private var tailProbeEmpty = false


    /// 拉取优先级（沿用 InFlightPageTable：prefetch < userVisible < jump）。
    public typealias FetchPriority = InFlightPageTable<Int>.Priority

    /// 缺口行（spec「缺口行的生命周期」）：身份 `gap:<start>-<end>` 由区间集派生。
    public struct GapRow: Sendable, Equatable, Identifiable {
        public enum Status: Sendable, Equatable {
            case loading
            case failed(retryable: Bool)
            /// 已到顶（hasMore=false / clamped），渲染「没有更多」。
            case exhausted
        }

        public let start: Int
        public let end: Int
        public let status: Status

        public var id: String { "gap:\(start)-\(end)" }

        public init(start: Int, end: Int, status: Status) {
            self.start = start
            self.end = end
            self.status = status
        }
    }

    /// 一次状态变化给上层的增量（MessagePipeline 据此组装 SnapshotDiff）。
    public struct Diff: Sendable {
        public var inserted: [SessionRecord] = []
        public var updated: [SessionRecord] = []
        public var removed: [Int] = []
        /// 当前窗口内全部 gap 行（派生量，每次整体给出，生灭交给 diff 消费方比对）。
        public var gaps: [GapRow] = []

        public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && removed.isEmpty }
    }

    /// 取页失败（T038 起「空页但没说到头」也算失败）。
    /// `description` 就是 App 侧探针 `pager.failed` 的 reason 口径
    /// （桥的 catch 打 `String(describing: error)`）。
    public enum FetchError: Error, Equatable, CustomStringConvertible {
        /// 该缺口已连续失败 3 次，转 retryable，不再自动拉（等用户点击重试）。
        case gapFailed
        /// 不过滤的翻页拉回 0 条且服务端没说「到头」——异常，按可重试失败处理。
        case emptyPage
        /// 取页在 `fetchTimeout` 内没有回包：回包丢失/链路挂起的兜底——真机上帧
        /// 丢了任务就永远挂着，翻页"永久静默无反应"（OTA 实测）的根治。
        case timeout

        public var description: String {
            switch self {
            case .gapFailed: return "gap-failed"
            case .emptyPage: return "empty-page"
            case .timeout: return "timeout"
            }
        }
    }

    // MARK: - 状态

    public let scope: String
    public let sessionId: String
    let pageSize: Int // internal：+Paging 扩展（页对齐工具）要用
    private let hotLimit: Int
    /// 单页取页的最长等待（秒）。超时按可重试失败计（`FetchError.timeout`）。
    let fetchTimeout: TimeInterval
    /// internal：+Hydration 扩展（磁盘水合）要用。
    let store: MessageStore?
    private let fetch: PageFetch
    let frameTick: @Sendable () async -> Void
    private let now: @Sendable () -> TimeInterval

    /// 有效连续区间集：本地（热窗口 + 磁盘）确定完整的范围。
    public private(set) var ranges = RangeIndex()
    /// 已经成功问过宿主的区间（本进程内）。
    ///
    /// 与 `ranges` 的区别：`ranges` 记的是"本地有记录"，它只能按记录逐个 seq 覆盖；
    /// 宿主的 seq 天然不连续（非记录事件也占号），所以一页 50 个 seq 只回 34 条时，
    /// 剩下的号会被当成"没取过"，生成一个永远补不上的加载行。
    /// 这里记"这一段问过、宿主答过"，空号由此归为已知无内容；**不持久化**：
    /// seq 可能被宿主重排，落盘的旧区间会与新区间对不上。
    var asked = RangeIndex() // internal：+Paging 的 currentGaps 要读

    /// 任务级单飞：同一范围只跑一次，跨入口共享（上拉/跳转/展开/预取）。
    private var jobs = FetchJobCoordinator()
    /// 搭车者等待同一个任务，不重复发请求。
    private var ensureJobs: [ClosedRange<Int>: Task<[SessionRecord], Error>] = [:]

    /// 热窗口：[seq: 记录] + 有序索引，超出 hotLimit 淘汰最老（只影响内存）。
    /// internal：流式半边（SessionPipeline+Streaming）要查行是否存在。
    var hotWindow: [Int: SessionRecord] = [:]
    private var hotOrder: [Int] = []

    private var inFlight = InFlightPageTable<Int>()
    /// 在途任务本体（页表只存代数；搭车者 await 同一个 Task，任务覆盖到合并完成）。
    private var inFlightTasks: [Int: Task<Void, Error>] = [:]
    private var writes = PendingWriteQueue<Int, MessageStore.RecordChange>()

    /// 每页连续失败次数；≥ maxRetries 的缺口转 retryable。
    /// internal：gap 派生（+Paging 扩展）要读。
    var failureCounts: [Int: Int] = [:]
    /// 已到顶：只有 hasMore=false 或 clamped（服务端明确到头），或本地窗口最老
    /// 序号已经到 1（`markEarliestReached`，T037）才置位。网络失败永不置位。
    public private(set) var topExhausted = false

    /// 落库回调：队列 drain 的批次交给 MessageStore（盘写由上层异步消费）。
    private let flushWrites: @Sendable ([MessageStore.RecordChange]) -> Void

    // 流式合并状态在 SessionPipeline+Streaming.swift（internal：同模块扩展可见，
    // 并发安全仍由本 actor 保证，沿用 MessageStore 拆文件的先例）。
    var streamBuffers: [String: StreamBuffer] = [:]
    var streamFlushScheduled = false

    // diff 广播（多订阅者：MessagePipeline 的泵 + 测试各拿一条流）。
    private var diffContinuations: [UUID: AsyncStream<Diff>.Continuation] = [:]

    static let maxRetries = 3 // internal：gap 派生（+Paging 扩展）要读

    /// seq 的可信上界（2026-10-13 崩溃回归）。真实 seq 是事件计数，量级在千到百万；
    /// 1e9 有一千倍余量。超出一律视为异常游标（host 的 `asOfSeq`，或本地聚合列被污染），
    /// 页边界计算不产页（+Paging 的 alignedPages/alignedPage）。
    static let seqCeiling = 1_000_000_000

    /// 一次缺口请求最多派生的页数：异常区间的第二道闸，防两千万页那种"不崩但拖死"的形态。
    static let maxPagesPerRequest = 512

    /// 缺页集合内的取页并发上限（017）。为什么是 2 而不是更大：一页 200–400ms 里大头是
    /// 往返与宿主读取，压到 2 路就能把"一次取 3 页"的等待从 3×往返降到约 1.5×往返；
    /// 再往上只是把一个读者的取数铺开，会挤占同一宿主上别的会话。预取与读者触发共用它。
    /// 用户可见的取页并发。实测单次往返 85–730ms、连接器侧 <200ms，瓶颈在往返；
    /// 2 会把 4–6 个窗口排成 3 轮。4 保持有界，又能让一次上拉的窗口并行。
    static let fetchConcurrency = 4
    /// 合并缺口后单个窗口最多多少个 seq。宿主按窗口读，太大则回包解码与内存都会涨。
    static let maxWindowSeq = 100

    /// 预取窗口：沿读取方向提前备好的页数（017）。读者停住时最多就是这几页，
    /// 不会把剩余历史一次拉下来。
    static let prefetchDepth = 1

    public init(
        scope: String,
        sessionId: String,
        store: MessageStore?,
        fetch: @escaping PageFetch,
        frameTick: @escaping @Sendable () async -> Void = {},
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        pageSize: Int = 50,
        hotLimit: Int = 500,
        initialRanges: RangeIndex = RangeIndex(),
        flushWrites: @escaping @Sendable ([MessageStore.RecordChange]) -> Void = { _ in },
        fetchTimeout: TimeInterval = 45
    ) {
        self.scope = scope
        self.sessionId = sessionId
        self.store = store
        self.fetch = fetch
        self.frameTick = frameTick
        self.now = now
        self.pageSize = pageSize
        self.hotLimit = hotLimit
        self.ranges = initialRanges
        self.fetchTimeout = fetchTimeout
        self.flushWrites = flushWrites
    }

    /// 采纳磁盘层持久化的区间集（冷启动预取判定，spec §6「可随会话快照持久化」）。
    /// 只增不删：持久化区间声称的是磁盘覆盖，命中段磁盘短收时仍会转网络补齐，
    /// 所以采纳是安全的（磁盘只是缓存，不是事实来源）。
    func adoptPersistedRanges(_ persisted: RangeIndex) {
        for span in persisted.spans {
            ranges.insert(span.start...span.end)
        }
    }

    // MARK: - diff 订阅

    /// 每次状态变化的增量流（多订阅者各自独立）。
    public func diffs() -> AsyncStream<Diff> {
        let id = UUID()
        return AsyncStream { continuation in
            diffContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeDiffContinuation(id) }
            }
        }
    }

    private func removeDiffContinuation(_ id: UUID) {
        diffContinuations.removeValue(forKey: id)
    }

    func emit(_ diff: Diff) {
        guard !diff.isEmpty || !diff.gaps.isEmpty else { return }
        for continuation in diffContinuations.values {
            continuation.yield(diff)
        }
    }

    // MARK: - 读（热窗口快照）

    /// 当前热窗口内某 seq 的记录（MessagePipeline 组装索引用）。
    public func record(at seq: Int) -> SessionRecord? { hotWindow[seq] }

    /// 当前快照：热窗口全部记录（升序）+ 派生 gap 行。新订阅者的首帧数据源。
    public func snapshot() -> (records: [SessionRecord], gaps: [GapRow]) {
        (hotOrder.sorted().compactMap { hotWindow[$0] }, currentGaps())
    }

    // MARK: - 水合（取不到就拉，spec §6 三分支）

    /// 用户槽位已被别的范围占用：调用方应把它当成"稍后再说"，不是失败。
    public struct FetchBusy: Error, Sendable {
        public init() {}
    }

    /// 任务级单飞入口：同一范围同一时刻只跑一次；搭车者等同一个任务。
    ///
    /// 与 `records(in:)` 的分工：`records` 负责区间判定与水合；`ensure` 负责
    /// “现在要不要发、是不是已经有人在发”。调用方只报目标范围，不再自己算批次。
    public func ensure(
        range: ClosedRange<Int>,
        priority: FetchPriority = .userVisible
    ) async throws -> [SessionRecord] {
        let slot: FetchJobMachine.Slot = priority == .prefetch ? .prefetch : .user
        switch jobs.request(range, slot: slot) {
        case .run:
            let task = Task { [weak self] () throws -> [SessionRecord] in
                guard let self else { throw CancellationError() }
                return try await self.records(in: range, priority: priority)
            }
            ensureJobs[range] = task
            do {
                let result = try await task.value
                jobs.succeed(range)
                ensureJobs[range] = nil
                return result
            } catch {
                jobs.fail(range)
                ensureJobs[range] = nil
                throw error
            }
        case .joined:
            guard let task = ensureJobs[range] else { return [] }
            return try await task.value
        case .rejectedUserBusy:
            throw FetchBusy()
        case .ignored:
            return []
        }
    }

    /// 取一个闭区间：命中部分本地直给，缺口按对齐页磁盘→网络补齐。
    /// 磁盘是纯缓存：区间声称覆盖但磁盘读不出（被淘汰/未落盘）同样转网络。
    public func records(
        in range: ClosedRange<Int>,
        priority: FetchPriority = .userVisible
    ) async throws -> [SessionRecord] {
        // 跳转抢占：取消低优先级预取，用户动作插队（spec 支撑机制 1）。
        // 跳转只抢占**预取**。以前连 userVisible 一起取消：读者刚上拉发出的
        // 几页会被紧随其后的跳转/回到底部清掉，页面永远补不齐，只能反复重发。
        if priority == .jump { _ = inFlight.cancelAll(below: .userVisible) }

        let startedAt = Date()
        // ① 区间判定三分支：算出缺口。
        var missing: [RangeIndex.Span]
        switch ranges.coverage(of: range) {
        case .full: missing = []
        case .partial(_, let spans): missing = spans
        case .none: missing = [RangeIndex.Span(range.lowerBound, range.upperBound)]
        }
        // 已经问过、宿主答过（含答得很稀疏）的区间不再重复取。
        missing = subtractingAsked(missing)

        Self.trace("fetch.plan range=\(range.lowerBound)-\(range.upperBound) missing=\(missing.count) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        // ② 命中部分：热窗口优先，缺的读盘；盘也读不出的并入缺口转网络。
        //    磁盘水合的记录必须发 diff（T026 修复 US2 遗留：淘汰后回看，
        //    区间集仍声称覆盖、读盘合并了却不广播，订阅方永远看不到——
        //        静默空白带的根因）。
        let hydrateStartedAt = Date()
        let hydrated = await hydrateCoveredSpans(of: range, missing: &missing)
        Self.trace("fetch.disk rows=\(hydrated.count) missing=\(missing.count) ms=\(Int(Date().timeIntervalSince(hydrateStartedAt) * 1000))")
        let hydratedFromDisk = !hydrated.isEmpty
        if !hydrated.isEmpty {
            var diff = Diff(inserted: hydrated)
            _ = evictIfNeeded(anchor: Self.anchor(of: range))
            diff.gaps = currentGaps()
            emit(diff)
        }

        // ③ 缺口按对齐页拉网络（含整段缺失/跳转型完全不命中）。
        if !missing.isEmpty {
            let netStartedAt = Date()
            try await fetchMissing(missing, priority: priority, direction: direction(of: range))
            Self.trace("fetch.net missing=\(missing.count) ms=\(Int(Date().timeIntervalSince(netStartedAt) * 1000))")
        }
        Self.trace("fetch.total range=\(range.lowerBound)-\(range.upperBound) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")

        // ④ 组装结果 + 预取瀑布（spec §7；017 起按方向提前 `prefetchDepth` 页）。
        //
        // 只有"这一段真是缺的"才预取：整段命中磁盘（区间集声称覆盖 + 热窗口淘汰后水合）
        // 时读者根本没碰网络，预取就成了凭空多出来的请求——既有用例
        // `testDiskHydrationAfterEvictionEmitsDiff` 钉着"全程零网络"这条。
        let result = range.compactMap { hotWindow[$0] }
        // 预取自己触发的读不再触发预取（否则自我放大）；刚做完**磁盘水合**的整段回看也不触发
        // ——那一段是缓存读、读者没在推边缘，预取只会凭空多出网络请求
        //（`testDiskHydrationAfterEvictionEmitsDiff` 钉着"全程零网络"）。
        if priority != .prefetch, !hydratedFromDisk {
            triggerPrefetch(around: range)
        }
        return result
    }

    /// 区间集声称覆盖、但热窗口已淘汰的段：读盘补回热窗口。
    /// 实现在 SessionPipeline+Hydration.swift（主文件 500 行上限）。

    /// 缺口 → 对齐页集合，按方向排序后**小并发**取回并合并（017）。某页失败不阻塞其它页。
    ///
    /// 为什么不再逐页 await：一页要等一次完整往返（实测 200–400ms），读者一次要三页时
    /// 串行就是三次等待。并发封顶在 `fetchConcurrency`，读者触发的页排在预取之前
    /// （`pageOrder` 保证），同页仍由 in-flight 页表合并成一次请求。
    /// 从缺口里扣掉"已经问过"的区间；剩下的才是真的要发请求的。
    private func subtractingAsked(_ missing: [RangeIndex.Span]) -> [RangeIndex.Span] {
        guard !asked.isEmpty, !missing.isEmpty else { return missing }
        return missing.flatMap { span -> [RangeIndex.Span] in
            switch asked.coverage(of: span.start...span.end) {
            case .full: return []
            case .none: return [span]
            case .partial(_, let spans): return spans
            }
        }
    }

    private func fetchMissing(
        _ missing: [RangeIndex.Span], priority: FetchPriority, direction: ReadingDirection
    ) async throws {
        let pages = pageOrder(for: missing, priority: priority, direction: direction)
        guard !pages.isEmpty else { return }
        Self.trace("fetch.pages count=\(pages.count) lo=\(pages.first?.lowerBound ?? 0) hi=\(pages.last?.upperBound ?? 0)")
        var firstError: Error?
        await withTaskGroup(of: Error?.self) { group in
            var next = 0
            let width = max(1, min(Self.fetchConcurrency, pages.count))
            for _ in 0..<width {
                let page = pages[next]
                next += 1
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    do { try await self.fetchPage(page, priority: priority); return nil }
                    catch { return error }
                }
            }
            while let error = await group.next() {
                if let error, firstError == nil { firstError = error }
                guard next < pages.count else { continue }
                let page = pages[next]
                next += 1
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    do { try await self.fetchPage(page, priority: priority); return nil }
                    catch { return error }
                }
            }
        }
        if let firstError { throw firstError }
    }

    /// 读者这次是往哪个方向读。由请求区间与已加载窗口的关系判定
    /// （`records(in:)` 在取数**之前**算一次，因为取完 ranges 就变了）。
    enum ReadingDirection { case older, newer, unspecified }

    private func direction(of range: ClosedRange<Int>) -> ReadingDirection {
        if let oldest = ranges.oldest, range.upperBound < oldest { return .older }
        if let newest = ranges.newest, range.lowerBound > newest { return .newer }
        return .unspecified
    }

    /// 一次取多页时的发送顺序（017）：读者眼前那一段先发，然后沿读取方向往外扩。
    ///
    /// - 更早方向：页码从大到小——紧挨已加载窗口的那一页先发；
    /// - 更新方向：页码从小到大；
    /// - 说不清方向或 `.jump`（读者点名要的区间）：保持区间顺序（左到右）。
    private func pageOrder(
        for missing: [RangeIndex.Span], priority: FetchPriority, direction: ReadingDirection
    ) -> [ClosedRange<Int>] {
        // 2026-10-18 实测：一次 150 seq 的窗口里有 8–39 个很小的缺口时，旧实现对每个
        // 缺口各自展开成对齐页，规划出 9–39 条，其中大量是同一页的重复。在飞表只
        // 合并重复的网络请求，重复条目本身仍要排队、仍会印出误导性的页数。
        // 这里保持"页对齐"的取回语义不变，只把重复页去掉：同一页只排一次。
        var pages: [ClosedRange<Int>] = []
        var seen = Set<Int>()
        for span in missing {
            for page in alignedPages(covering: span) where seen.insert(page.lowerBound).inserted {
                pages.append(page)
            }
        }
        guard priority != .jump, pages.count > 1 else { return pages }
        switch direction {
        case .older: return pages.sorted { $0.lowerBound > $1.lowerBound }
        case .newer: return pages.sorted { $0.lowerBound < $1.lowerBound }
        case .unspecified: return pages
        }
    }

    /// 单页拉取：in-flight 页表同页合并/可抢占，回包按代数核销。
    /// 单页取回的耗时证据。用 `OSLog`（notice 级，会持久化）而不是依赖上层探针：
    /// 只有在这里才看得到"网络往返 + 解码"的净耗时，与上层"整次取页"分开。
    private static let traceLog = Logger(subsystem: "com.jayanttang.dsh", category: "pipeline")

    /// 同一条证据的第二出口。系统日志在 OTA 诊断构建里没有可靠到达（实测只留下
    /// 系统框架的条目），所以由 App 在启动时接一个闭包直接进诊断环；
    /// TestFlight 里为 nil，只有一条判空。
    public nonisolated(unsafe) static var traceSink: (@Sendable (String) -> Void)?

    nonisolated static func trace(_ line: String) {
        traceSink?(line)
        traceLog.notice("\(line, privacy: .public)")
    }

    private func fetchPage(_ page: ClosedRange<Int>, priority: FetchPriority) async throws {
        let key = page.lowerBound
        let startedAt = Date()
        Self.trace("page.fetch.start lo=\(page.lowerBound) hi=\(page.upperBound) pri=\(String(describing: priority))")
        if failureCounts[key, default: 0] >= Self.maxRetries {
            emit(Diff(gaps: currentGaps()))
            throw FetchError.gapFailed
        }

        switch inFlight.begin(key, priority: priority) {
        case .joined:
            // 同页在途：搭车等待同一个任务（任务覆盖到合并完成，见下）。
            if let task = inFlightTasks[key] { try await task.value }
            Self.trace("page.fetch.joined lo=\(page.lowerBound) hi=\(page.upperBound) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            return
        case .start(let generation):
            let fetch = self.fetch
            // 任务本体包含回包合并：搭车者 await 到的一定是「合并后」。
            let task = Task<Void, Error> {
                let result: FetchPage
                do { result = try await self.withTimeout(self.fetchTimeout) { try await fetch(page, priority) } }
                catch {
                    Self.trace("page.fetch.end lo=\(page.lowerBound) hi=\(page.upperBound) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) ok=0 err=\(String(describing: type(of: error)))")
                    self.failFetch(error, key: key, generation: generation)
                    throw error
                }
                Self.trace("page.fetch.end lo=\(page.lowerBound) hi=\(page.upperBound) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) recs=\(result.records.count) ok=1")
                // T038（spec 追加修订 2「空页即异常」）：不过滤的翻页拉回 0 条且
                // 服务端没说到头 = 可重试失败，走与网络失败**同一条**计数路径
                // （failFetch）——3 次后缺口转 failed(retryable)，探针口径
                // reason=empty-page（App 侧 catch 打 String(describing: error)）。
                // 原来这里记进 knownEmptyPages 静默跳过，预取假装没事。
                //
                // 关键分界：带回填过滤（roles）的空页是**正常形态**——整页被过滤掉
                // 而已，由 T039 的 scanBoundary 处理，不走本失败路径。过滤分页用的是
                // `UserInputBackfiller` 自己的 fetch（不经 SessionPipeline），而本管道
                // 的取页闭包不带 roles（产品侧 MessageLayer 用 through: nil、无 roles
                // 的 _link/sessionWindow），所以「0 条即异常」在本路径上成立。
                guard !result.records.isEmpty
                        || Self.reachedEnd(result, requested: page)
                        || self.isNewerDirectionProbe(page)
                else {
                    self.failFetch(FetchError.emptyPage, key: key, generation: generation)
                    throw FetchError.emptyPage
                }
                self.completeFetch(result, key: key, generation: generation, requested: page)
            }
            inFlightTasks[key] = task
            try await task.value
        }
    }

    /// 空回包发生在「往更新方向探」时是正常形态：窗口尾部之上还没有新内容，
    /// 不是缺历史。只有往更早方向拉空才是异常（T038）。
    /// 判据：请求区间整体在当前热窗口最新 seq 之上。
    /// 共用判据（`isNewerDirectionProbe(pageLowerBound:hotNewest:)`）与热窗口读数
    /// 在 `+Paging` 扩展里——App 侧的空回包注入也用它，两处必须同一份。
    private func isNewerDirectionProbe(_ page: ClosedRange<Int>) -> Bool {
        Self.isNewerDirectionProbe(pageLowerBound: page.lowerBound,
                                   hotNewest: hotWindow.keys.max())
    }

    /// 回包核销 + 合并（代数不符 = 已被取消，丢弃）。
    private func completeFetch(
        _ result: FetchPage, key: Int, generation: Int, requested: ClosedRange<Int>
    ) {
        inFlightTasks.removeValue(forKey: key)
        guard inFlight.finish(key, generation: generation) else { return }
        failureCounts.removeValue(forKey: key)
        mergeFetchedPage(result, requested: requested)
    }

    /// 给一次取页加最长等待：超时按 `FetchError.timeout` 抛（走与网络失败
    /// 同一条 failFetch 计数路径）。在任务**本体内部**做，所以搭车者
    /// （inFlight.joined）最多也只等 `fetchTimeout`，不会因回包丢失永远挂着。
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw FetchError.timeout
            }
            defer { group.cancelAll() }
            // 先到先赢：取页回来或超时到了。
            guard let value = try await group.next() else { throw FetchError.timeout }
            return value
        }
    }

    /// 失败核销：计数 + 重发 gap 状态；3 次上限由 fetchPage 入口挡。
    /// 网络失败与 T038 的空页失败共用这一条路径（计数口径一致）。
    private func failFetch(_ error: Error, key: Int, generation: Int) {
        inFlightTasks.removeValue(forKey: key)
        _ = inFlight.finish(key, generation: generation)
        failureCounts[key] = failureCounts[key, default: 0] + 1
        emit(Diff(gaps: currentGaps())) // 失败次数变化可能改写 gap 状态
    }

    /// 回包合并：热窗口 + 区间集 + 落库队列三路，一次 diff 产出（spec §2 下行）。
    private func mergeFetchedPage(_ page: FetchPage, requested: ClosedRange<Int>) {
        var diff = Diff()
        let pageRecords = page.records.sorted { $0.event.seq < $1.event.seq }
        if pageRecords.isEmpty {
            // T038：非「明确到头」的空回包在 fetchPage 上游已按失败抛掉，能落到
            // 这里的空回包只有两种正常形态：①最底页 + hasMore=false/clamped
            // （真到头）；②更新方向探空（尾部之上暂时没有新内容）。
            if Self.reachedEnd(page, requested: requested) { topExhausted = true }
            if isNewerDirectionProbe(requested) { tailProbeEmpty = true }
        } else {
            tailProbeEmpty = false
            for record in pageRecords {
                if hotWindow[record.event.seq] == nil { diff.inserted.append(record) } else { diff.updated.append(record) }
                mergeIntoHotWindow(record)
            }
            ranges.insert(pageRecords.first!.event.seq...pageRecords.last!.event.seq)
            enqueueWrite(.upsertRecords(scope: scope, sessionId: sessionId, records: pageRecords),
                         key: pageRecords.last!.event.seq)
            if Self.reachedEnd(page, requested: requested) { topExhausted = true }
            _ = evictIfNeeded(anchor: Self.anchor(of: requested))
        }
        // 成功问过一段，就记下来：即使回包比请求的范围稀疏，也不该再把它当缺口。
        asked.insert(requested)
        diff.gaps = currentGaps()
        emit(diff)
    }

    /// 读者点了「加载失败，点击重试」（spec 009 失败语义 / tasks T016）：
    /// 清掉该范围覆盖对齐页的失败计数，再走一次「取不到就拉」。
    /// 除此之外没有任何路径能清零计数——失败到上限的缺口不会自己偷偷重试。
    public func retry(range: ClosedRange<Int>) async throws {
        for page in alignedPages(covering: RangeIndex.Span(range.lowerBound, range.upperBound)) {
            failureCounts.removeValue(forKey: page.lowerBound)
        }
        _ = try await records(in: range, priority: .userVisible)
    }

    // MARK: - 下行合并（WSS 推送 / 流式）

    /// 服务端提交的日志事件：直接合并（流式帧走 apply(stream:)）。
    public func apply(event: SessionEvent) {
        apply(events: [event])
    }

    /// 一批日志事件（follow 快照下行）：合并成**一次** diff——逐条 apply 会让
    /// 订阅方按条数重建（009 ChatModel 接线实测要避免的写放大）。
    public func apply(events: [SessionEvent]) {
        guard !events.isEmpty else { return }
        var diff = Diff()
        var latestKey = 0
        // 提交事件落地时作废旧流式缓冲：否则已排期的 flush 会用旧的
        // provisional 文本把刚提交的正式内容盖回去（T020）。
        discardStreamBuffers(committedAt: Set(events.compactMap {
            $0.type == "assistant/message" ? $0.seq : nil
        }))
        for event in events {
            let record = SessionRecord(event: event)
            if hotWindow[event.seq] == nil { diff.inserted.append(record) } else { diff.updated.append(record) }
            mergeIntoHotWindow(record)
            ranges.insert(event.seq)
            latestKey = max(latestKey, event.seq)
        }
        enqueueWrite(.upsertRecords(
            scope: scope, sessionId: sessionId,
            records: events.map(SessionRecord.init)), key: latestKey)
        _ = evictIfNeeded()
        diff.gaps = currentGaps()
        emit(diff)
    }

    /// 本地窗口最老序号已经到 1（T037 / spec 追加修订 1、3）：seq 从 1 编号，
    /// 没有更早的记录可拉，直接置「已到最早」——语义与 `hasMore=false` 的到头
    /// 等同（预取停手、gap 行渲染「没有更多」），只是判定来源是本地事实而不是
    /// 服务端回包。桥在 `loadOlder` 看到窗口最老 ≤ 1 时调这里，替代原来的静默
    /// return；只置位不撤销（记录只往新处增长）。
    public func markEarliestReached() {
        guard !topExhausted else { return }
        topExhausted = true
        emit(Diff(gaps: currentGaps()))
    }

    /// 流式增量在 SessionPipeline+Streaming.swift（文件按职责拆分，见该文件头注）。

    // MARK: - 上行（MessagePipeline 的 send 走这里落库排队）

    /// 乐观记录入队（pending）/ 确认替换（confirm）：不进热窗口——上行行
    /// 的身份与排序由 MessagePipeline 持有，这里只管落库队列。
    public func enqueueWrite(_ change: MessageStore.RecordChange, key: Int) {
        writes.enqueue(key, change, now: now())
        if writes.shouldFlush(now: now()) {
            flushWrites(writes.drain(now: now()).map(\.value))
        }
    }

    /// 强制落盘（测试与退后台路径用）。
    public func flushPendingWrites() {
        guard !writes.isEmpty else { return }
        flushWrites(writes.drain(now: now()).map(\.value))
    }

    // MARK: - 预取瀑布（spec §7）

    /// 窗口滑动带提前量（017：从"提前一页"改成"按方向提前 `prefetchDepth` 页"）。
    ///
    /// 为什么：读者到达边缘才补一页，就是每屏等一次往返。这里沿读取方向把接下来几页
    /// **提前**取好（并发上限由 `fetchMissing` 管），读者到达时通常已在本地。
    /// 方向由本次请求与已加载窗口的关系判定——按请求区间算，不按边缘距离算，
    /// 否则往回翻时新旧两侧同时满足条件，会把反方向的页也拖进来。
    private func triggerPrefetch(around range: ClosedRange<Int>) {
        // 基准用**热窗口**两沿（不是区间集）：follow 下行刚到的记录还没写进区间集，
        // 但窗口上沿已经抬高了，用区间集会把它当成"已经备过"而探不到新内容。
        guard let hotOldest = hotWindow.keys.min(), let hotNewest = hotWindow.keys.max() else { return }
        // 范围门槛沿用 007 的既有语义：读者靠近（或越过）某一沿才备那一侧，别在中间乱拉。
        if !topExhausted, hotOldest > 1, range.lowerBound - hotOldest < pageSize {
            prefetchOlder(cursor: hotOldest, depth: Self.prefetchDepth)
        }
        if hotNewest - range.upperBound < pageSize {
            prefetchNewer(cursor: hotNewest, depth: Self.prefetchDepth)
        }
    }

    /// 沿更早方向提前备最多 `depth` 页（017）。
    ///
    /// `cursor` 传热窗口下沿（半开）：备的第一页是含 `cursor - 1` 的那一页。
    /// 深度从 `cursor` 起算，所以"每落一页又备两页"不会发生——落下的页落在
    /// `[cursor - depth×pageSize, cursor)` 这个固定窗口里，窗口整体只随读者前进而前进
    /// （第一版没有这个基准，一个 5000 事件的会话 10 秒里预取了 43 次、扫到 seq 51）。
    private func prefetchOlder(cursor: Int, depth: Int) {
        guard depth > 0 else { return }
        var next = cursor
        for _ in 0..<depth where next > 1 {
            guard let page = alignedPage(containing: next - 1) else { return }
            prefetch(page)
            next = page.lowerBound
        }
    }

    /// 沿更新方向提前备最多 `depth` 页；`cursor` 传热窗口上沿。
    private func prefetchNewer(cursor: Int, depth: Int) {
        guard depth > 0 else { return }
        var next = cursor
        for _ in 0..<depth {
            guard let page = alignedPage(containing: next + 1) else { return }
            prefetch(page)
            next = page.upperBound
        }
    }

    private func prefetch(_ page: ClosedRange<Int>) {
        let key = page.lowerBound
        // 预取是背景动作：该页打到失败上限（maxRetries）才不再自动重打，
        // 免得瀑布反复撞死页；上限之内仍会重试，窗口预热不会因一次网络抖动
        // 就永久放弃（T038 删 knownEmptyPages 时的收紧过头，已按原语义恢复）。
        // 用户主动读取不受此限——fetchPage 入口只挡 maxRetries，点重试清零计数。
        if tailProbeEmpty, isNewerDirectionProbe(page) { return }
        guard !inFlight.isInFlight(key),
              inFlightTasks[key] == nil,
              failureCounts[key, default: 0] < Self.maxRetries
        else { return }
        switch ranges.coverage(of: page) {
        case .none, .partial:
            Task { try? await self.fetchPage(page, priority: .prefetch) }
        case .full:
            return
        }
    }

    // MARK: - 内部工具

    func mergeIntoHotWindow(_ record: SessionRecord) {
        let seq = record.event.seq
        if hotWindow[seq] == nil { hotOrder.append(seq) }
        hotWindow[seq] = record
    }

    /// 热窗口超上限淘汰（只影响内存，磁盘由落库队列负责）。
    /// 默认丢最老（尾部到达，spec「超出丢最老已读」）；给锚点（回看水合）
    /// 时丢离锚点更远的一端——回看时把正在读的段抽走会立刻触发再水合，
    /// 形成「水合→淘汰→空白」死循环（T026）。
    /// 返回被淘汰的 seq：仅内部记账/测试断言用——T028 裁定淘汰**不进**
    /// `diff.removed`（热窗口是缓存不是事实，见头注「淘汰语义」）。
    @discardableResult
    func evictIfNeeded(anchor: Int? = nil) -> [Int] {
        guard hotOrder.count > hotLimit else { return [] }
        hotOrder.sort()
        let excess = hotOrder.count - hotLimit
        let evictOldest: Bool
        if let anchor, let first = hotOrder.first, let last = hotOrder.last {
            evictOldest = anchor - first >= last - anchor
        } else {
            evictOldest = true
        }
        let evicted = evictOldest ? Array(hotOrder.prefix(excess)) : Array(hotOrder.suffix(excess))
        if evictOldest { hotOrder.removeFirst(excess) } else { hotOrder.removeLast(excess) }
        for seq in evicted { hotWindow.removeValue(forKey: seq) }
        return evicted
    }

    /// 缺口行由区间集派生（spec「缺口行的生命周期」）：窗口 = 最老…最新。
    /// 实现在 SessionPipeline+Paging.swift（主文件 500 行上限）。
}

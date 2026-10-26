import Foundation

/// 一个会话的**读写把手**（spec 023 边界收敛：数据层交给 App 的窄对象）。
///
/// ## 为什么需要它
///
/// App 侧原来直接持有 `SessionPipeline`（一个 `public actor`）来读页、应用事件、重试缺口、
/// 标"到顶了"。这让产品路径每次都得写出实现层的类型名，也让"能不能换一种实现"变成全仓库搜索。
/// 把手把**用到的那几个动作**转出来，App 只认它；`SessionPipeline` 本身将来可以换实现，
/// 只要把手背后的转发还成立。
///
/// 它**不含判定**：所有规则仍在 `SessionPipeline` 里（那边的单测覆盖），这里只转发，
/// 所以不存在"两套口径"。转发全部 `async`（actor 隔离），调用点的 `await` 写法与原来一致。
public struct SessionHandle: Sendable {

    /// 取页优先级（把手自己的词表，不把 `SessionPipeline` 的类型透出去）。
    public enum FetchPriority: Sendable {
        case prefetch
        case userVisible
        case jump

        var pipeline: SessionPipeline.FetchPriority {
            switch self {
            case .prefetch: return .prefetch
            case .userVisible: return .userVisible
            case .jump: return .jump
            }
        }
    }

    /// 用户槽位已被别的范围占用：调用方当成"稍后再说"，不是失败。
    public struct FetchBusy: Error, Sendable {
        public init() {}
    }

    private let pipeline: SessionPipeline

    /// 只在 DSHKit 内部构造：App 从 `MessageLayer` 拿把手，不自己 new。
    init(pipeline: SessionPipeline) {
        self.pipeline = pipeline
    }

    // MARK: - 读

    /// 取一段 seq 的记录（按页对齐、可能触发网络）。
    public func records(in range: ClosedRange<Int>,
                        priority: FetchPriority = .userVisible) async throws -> [SessionRecord] {
        do {
            return try await pipeline.records(in: range, priority: priority.pipeline)
        } catch is SessionPipeline.FetchBusy {
            throw FetchBusy()
        }
    }

    /// 任务级单飞入口：同一范围只跑一次，搭车者等同一批结果。
    public func ensure(in range: ClosedRange<Int>,
                       priority: FetchPriority = .userVisible) async throws -> [SessionRecord] {
        do {
            return try await pipeline.ensure(range: range, priority: priority.pipeline)
        } catch is SessionPipeline.FetchBusy {
            throw FetchBusy()
        }
    }

    /// 取页指标快照（只读，不参与判定）。
    public func fetchMetrics() async -> FetchMetrics {
        await pipeline.metricsSnapshot()
    }

    /// 采纳一页概要 v2（记录稀疏但整段已读；不生成缺口、不重取）。
    public func adoptSummaryPage(records: [SessionRecord], covered: ClosedRange<Int>,
                                 hasMore: Bool, clamped: Bool = false,
                                 knownEmpty: [[Int]] = [], revision: String? = nil) async {
        await pipeline.adoptSummaryPage(records: records, covered: covered, hasMore: hasMore,
                                        clamped: clamped, knownEmpty: knownEmpty,
                                        revision: revision)
    }

    /// 采纳对端确认的已知为空区间（带版本，版本不一致丢弃）。
    public func applyKnownEmpty(spans: [ClosedRange<Int>], revision: String) async {
        await pipeline.applyKnownEmpty(spans, revision: revision)
    }

    /// 当前覆盖版本（最新号）；对端回包的 revision 要与它一致才可用。
    public var coverageRevision: String? {
        get async { await pipeline.coverageRevision }
    }

    /// 已经取到的 seq 区间。
    public var ranges: RangeIndex {
        get async { await pipeline.ranges }
    }

    /// 已加载区间内仍未补上的空洞（`oldest` 到 1 不代表历史完整）。
    public func uncoveredSpans() async -> [ClosedRange<Int>] {
        await pipeline.uncoveredSpans()
    }

    /// 更早方向是否已经到头（顶部没有更多历史）。
    public var topExhausted: Bool {
        get async { await pipeline.topExhausted }
    }

    // MARK: - 写

    public func apply(event: SessionEvent) async {
        await pipeline.apply(event: event)
    }

    public func apply(events: [SessionEvent]) async {
        await pipeline.apply(events: events)
    }

    public func apply(stream frame: AssistantStreamFrame) async {
        await pipeline.apply(stream: frame)
    }

    /// 清掉这段区间的失败计数，让下一次读取重试它。
    public func retry(range: ClosedRange<Int>) async throws {
        try await pipeline.retry(range: range)
    }

    /// 放弃这段区间（把它直接标成失败，不再重试）。
    public func abandonGap(_ range: ClosedRange<Int>) async {
        await pipeline.abandonGap(range)
    }

    /// 标记"更早方向已经到顶"，避免反复去问。
    public func markEarliestReached() async {
        await pipeline.markEarliestReached()
    }
}

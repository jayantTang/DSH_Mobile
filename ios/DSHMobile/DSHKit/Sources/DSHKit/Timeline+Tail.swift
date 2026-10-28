import Foundation

/// 会话尾轮的边界事实（设计 `20261027-折叠抖动-方案A.md` §2.2）。
///
/// 为什么它必须在数据层：运行态与「这一轮能不能折叠」以前都靠「窗口里恰好有没有
/// `turn/start` / `turn/end`」推断，而窗口是按条数切的——长轮次必然被切开，于是
/// 被切开的尾轮既不"在跑"也不"可折叠"，投影把原始过程行整段铺开（首帧形态跳变）。
///
/// 三条事实各自只有一个写入口：
/// - `boundary`：`ChatTimeline.noteBoundary(_:)`（`Timeline+Tail.swift`），只由
///   `turn/start`、`turn/end`、流式开始、v2 概要、`reset(with:seeding:)` 调用；
/// - `showsTail`：`reset(with:seeding:showsTail:)`，`apply` / `merge` 置 true；
/// - 「读者顶部可见行」不在这里，它是 `ChatModel` 的一次性测量值。
public struct TranscriptTail: Sendable, Equatable {

    /// 尾轮的三态。`unknown` 不是「没在跑」，而是「还不知道」——它决定投影输出
    /// 一行固定高度的占位行，而不是铺开原始过程行。
    public enum Boundary: Sendable, Equatable {
        case unknown
        case open(turn: Int, startedAt: Date?)
        case closed(turn: Int, reason: String?)
    }

    public var boundary: Boundary
    /// 这个窗口的末段是不是会话尾部。
    ///
    /// 搜索跳转会把时间线重置成一个中间窗口（`ChatModel+SearchPage.swift` 的
    /// `rebaseWindow`），此时底部那段并不是尾轮：既不能标 running、也不能出占位行。
    public var showsTail: Bool

    public init(boundary: Boundary = .unknown, showsTail: Bool = true) {
        self.boundary = boundary
        self.showsTail = showsTail
    }

    /// 默认值：边界未知、窗口就是尾部。
    public static let unknown = TranscriptTail(boundary: .unknown, showsTail: true)
}

// 判定处一律用这三个只读属性，不要在各处手写 `if case`
//（一个事实一处判定，散开写就会出现「某处漏了一种」）。
public extension TranscriptTail.Boundary {
    var isOpen: Bool { if case .open = self { return true }; return false }
    var isClosed: Bool { if case .closed = self { return true }; return false }
    var isUnknown: Bool { if case .unknown = self { return true }; return false }

    /// 边界所在轮次号；`unknown` 时为 0。
    var turn: Int {
        switch self {
        case .unknown: return 0
        case .open(let turn, _): return turn
        case .closed(let turn, _): return turn
        }
    }

    /// 只有在 `.open` 时才有值：开着的这一轮从什么时候开始。
    var startedAt: Date? {
        if case .open(_, let at) = self { return at }
        return nil
    }

    /// 只有在 `.closed` 时才有值：结束原因（`completed` / `interrupted` …）。
    var endReason: String? {
        if case .closed(_, let reason) = self { return reason }
        return nil
    }
}

// MARK: - 计时起点

public extension ChatTimeline {
    /// 正在跑的那一轮的开始时刻（宿主 `turn/start` 的时间）。运行行的计时起点用它，
    /// 不拿“手机观察到的时间”代替；切后台/重开也还是同一个值。
    ///
    /// 三个粒度按强弱顺序取：边界自带的（最准，直接来自 `turn/start` 或概要）→
    /// 本窗口里那一轮的 `turn/start` 记录 → 概要里的 `startedAt`。
    var openTurnStartedAt: Date? {
        guard isTurnOpen else { return nil }
        if let start = tail.boundary.startedAt { return start }
        if let start = turnStartedAt[tail.boundary.turn] { return start }
        // 起点不在本地窗口：运行中的概要带着轮次的 startedAt（宿主时间），用它兜底。
        // 同一轮可能被讲话切成多段，每段同值；取最后一条有值的即可。
        let fromSummary = foldSummaries.last {
            $0.turn == tail.boundary.turn && $0.startedAt != nil
        }
        return fromSummary?.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

// MARK: - 唯一写入口：边界合并

extension ChatTimeline {

    /// 边界合并表（§2.2）。`T` 是轮次号，**同一轮 `closed → open` 被禁止**：
    /// 那是重连重放、重读窗口、跨设备旧记录最常见的形状，放进来就会把已结束的
    /// 轮次说成"还在跑"。
    ///
    /// | 现有 | 新证据 | 结果 |
    /// |---|---|---|
    /// | unknown | 任意 | 新证据 |
    /// | open(T) | open(T') | T' > T 取新 |
    /// | open(T) | closed(T') | T' >= T 取 closed |
    /// | closed(T) | open(T') | T' > T 取 open |
    /// | closed(T) | closed(T') | T' >= T 取新 |
    mutating func noteBoundary(_ next: TranscriptTail.Boundary) {
        let current = tail.boundary
        if current == next { return }
        let accepted: Bool
        switch (current, next) {
        case (.unknown, _):
            accepted = true
        case (.open(let old, _), .open(let new, _)):
            accepted = new > old
        case (.open(let old, _), .closed(let new, _)):
            accepted = new >= old
        case (.closed(let old, _), .open(let new, _)):
            // 同一轮已结束是终态；更高轮次的开着的一段才是新事实。
            accepted = new > old
        case (.closed(let old, _), .closed(let new, _)):
            accepted = new >= old
        case (_, .unknown):
            // `unknown` 不是一条证据（它是"没有证据"），永远不覆盖已知事实。
            accepted = false
        }
        if accepted { tail.boundary = next }
        // 被拒的证据不落状态。协议违规（同一轮又开了一次）由 `ChatModel` 在
        // 事件入口记一条 `tail.conflict` 探针——DSHKit 不依赖 App 的诊断端口。
    }

    /// 调用方补上的一条边界证据（占位行重试用）：落**同一个**唯一写入口，
    /// 合并表决定它能不能生效——旧事实不会被回退，同一轮已结束也不会被重开。
    public mutating func seedTail(_ boundary: TranscriptTail.Boundary) {
        noteBoundary(boundary)
        tail.showsTail = true
    }

    /// v2 概要采纳边界：概要是一段**真实观测**（连接器折的），但它比实时事件弱。
    ///
    /// 判据（M1）：该概要必须是当前最新一段（轮次号不落后于已采纳的边界，
    /// 或 `startSeq` 不早于已采纳边界的轮次起点），`endReason == nil` 记 open
    /// （`startedAt` 取概要里的宿主时间），否则记 closed。
    mutating func adoptBoundary(from summary: FoldSummaryV2) {
        // 落后于当前边界的旧概要不得参与：它描述的是更早的一段。
        let current = tail.boundary
        if current.turn > 0, summary.turn > 0, summary.turn < current.turn { return }
        let startedAt = summary.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        if let endReason = summary.endReason {
            noteBoundary(.closed(turn: summary.turn, reason: endReason))
        } else {
            noteBoundary(.open(turn: summary.turn, startedAt: startedAt))
        }
    }
}

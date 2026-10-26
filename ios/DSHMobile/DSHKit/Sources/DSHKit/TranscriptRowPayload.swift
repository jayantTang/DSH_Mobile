import Foundation

/// 一行在内存里的**可变部分**（spec 008 的 Row）。
///
/// 行身份（`TimelineItem.id`）与行内容分开之后，"省内存"就只是把 `payload` 换成
/// `.reclaimed`——行还在、id 还在、高度缓存还在，于是不会出现"目标行不存在"这类问题
/// （那正是 007 每次崩溃的根因）。取回内容只读本地库，不联网。
public struct TranscriptRowPayload {

    /// 内容在不在内存里。
    public enum State {
        case full(TimelineItem)
        /// 只记得它来自哪个 seq；`item` 里的重型字段已经释放。
        case reclaimed(seq: Int, kind: RowKind, height: CGFloat)
    }

    /// 回收之后仍要能画一个占位（高度必须与原来一致，否则会跳）。
    public enum RowKind: Equatable {
        case userMessage
        case assistantText
        case reasoning
        case toolCall
        case notice
        /// 缺口占位行（009）：回收只换载荷，占位高度不变。
        case gap
        /// Process node: a display-only summary row; has no heavy payload.
        case processHeader
        /// 概要 v2 的步骤元数据行：同样没有正文（正文按需单条取）。
        case processStep
        /// 末尾运行行：显示状态，没有载荷。
        case runningLine
    }

    public let id: String
    public var state: State
    /// 内容版本：每次水合 +1，用来让高度缓存的键失效（避免拿旧高度去量新内容）。
    public var contentVersion: Int
    /// 高度缓存（回收/水合前必须一致，容差 ±1pt——spec 008 的 FR-005）。
    public var height: CGFloat?

    public init(item: TimelineItem, height: CGFloat? = nil) {
        self.id = item.id
        self.state = .full(item)
        self.contentVersion = 0
        self.height = height
    }

    public var item: TimelineItem? {
        if case .full(let item) = state { return item }
        return nil
    }

    public var isReclaimed: Bool {
        if case .reclaimed = state { return true }
        return false
    }

    /// The journal sequence this row stands for, even after it was reclaimed.
    public var seq: Int? {
        if let item { return item.seq }
        if case .reclaimed(let seq, _, _) = state { return seq }
        return nil
    }

    /// 载荷字节：只算"重"的部分（可见文本），附件在磁盘上、不算。
    ///
    /// 口径写进 `specs/008-transcript-list-host/contracts/list-host.md` §4：
    /// 预算按这里累加出来的总量算，默认 32MB。
    public var payloadBytes: Int {
        guard let item else { return 0 }
        switch item.kind {
        case .userMessage(let text, _, _, _, _): return text.utf8.count
        case .assistantText(let text): return text.utf8.count
        case .reasoning(let text): return text.utf8.count
        case .toolCall(let invocation):
            return invocation.arguments.utf8.count + invocation.resultText.utf8.count
        case .notice(let text, _): return text.utf8.count
        case .processHeader, .processStep, .runningLine: return 0
        default: return 0
        }
    }

    /// 回收：留下 seq / 类型 / 高度，把内容换掉。
    public mutating func reclaim() {
        guard let item, !isReclaimed else { return }
        switch item.kind {
        case .processHeader, .processStep, .runningLine: return
        default: break
        }
        state = .reclaimed(seq: item.seq, kind: Self.kind(of: item), height: height ?? 0)
    }

    /// 水合：把记录折叠回一行（调用方负责从本地库取记录）。
    public mutating func rehydrate(with item: TimelineItem) {
        state = .full(item)
        contentVersion += 1
    }

    public static func kind(of item: TimelineItem) -> RowKind {
        switch item.kind {
        case .userMessage: return .userMessage
        case .assistantText: return .assistantText
        case .reasoning: return .reasoning
        case .toolCall: return .toolCall
        case .notice: return .notice
        case .gap: return .gap
        case .processHeader: return .processHeader
        case .processStep: return .processStep
        case .runningLine: return .runningLine
        default: return .notice
        }
    }
}

/// 窗口的载荷预算（spec 008 的 FR-004a/FR-009）。
public struct TranscriptPayloadBudget: Sendable {
    /// 默认 32MB，与契约一致。
    public static let `default` = TranscriptPayloadBudget(limitBytes: 32 * 1024 * 1024)

    public init(limitBytes: Int) { self.limitBytes = limitBytes }
    public let limitBytes: Int

    /// 该回收哪些行：离视口最远的先扔，直到回到预算内。
    ///
    /// - Parameter rows: 按时间顺序（旧 → 新）排列的行。
    /// - Parameter visible: 视口内行在 `rows` 里的下标区间。
    /// - Parameter keepDistance: 视口外多少行以内不回收（由调用方按"几屏"换算成行数）。
    public func rowsToReclaim(_ rows: [TranscriptRowPayload], visible: Range<Int>,
                              keepDistance: Int) -> [String] {
        let total = rows.reduce(0) { $0 + $1.payloadBytes }
        guard total > limitBytes else { return [] }
        let protected = max(0, visible.lowerBound - keepDistance)..<min(rows.count, visible.upperBound + keepDistance)
        var over = total - limitBytes
        var picked: [String] = []
        // 从两端（离视口最远的）往中间收。
        var lower = 0
        var upper = rows.count - 1
        while over > 0, lower < protected.lowerBound || upper >= protected.upperBound {
            let takeLower = lower < protected.lowerBound && (upper >= protected.upperBound ? lower <= rows.count - 1 - upper : true)
            let index = takeLower ? lower : upper
            let row = rows[index]
            if !row.isReclaimed, row.payloadBytes > 0 {
                picked.append(row.id)
                over -= row.payloadBytes
            }
            if takeLower { lower += 1 } else { upper -= 1 }
        }
        return picked
    }
}

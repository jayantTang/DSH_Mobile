import DSHKit
import Foundation

/// 尾轮边界相关的那一半投影：占位行、未知段的显示形状、以及轮次关闭那一刻的
/// 一次性保位判定（设计 `20261027-折叠抖动-方案A.md` M3/M4）。
///
/// 为什么单独一个文件：`TranscriptProcessFold.swift` 已经是 700+ 行的既有债，本次
/// 只许净减或等量；整块新逻辑一律进新文件（§4.3）。
extension TranscriptProcessFold {

    // MARK: - 一段的尾部事实

    /// `plan` 里"在不在跑 / 结没结束 / 边界是不是未知"的三个答案：只看边界事实
    /// 与"这一段有没有分隔行"，不看读者停在哪里、也不看上一帧的显示形状。
    struct TailFacts {
        let isRunning: Bool
        /// 这一轮确定已结束：窗口里有分隔行，或边界事实说尾轮已关闭。
        let settled: Bool
        /// 「已结束但没有分隔行」：末尾连续的回答行要留在收起态外面。
        let settledWithoutDivider: Bool
        /// 尾轮边界未知：这一段的过程要显示什么还不知道。
        let boundaryUnknown: Bool
    }

    static func tailFacts(isLast: Bool, hasDivider: Bool, tail: TranscriptTail) -> TailFacts {
        let atTail = isLast && tail.showsTail
        return TailFacts(
            isRunning: !hasDivider && atTail && tail.boundary.isOpen,
            settled: hasDivider || (atTail && tail.boundary.isClosed),
            settledWithoutDivider: !hasDivider && atTail && tail.boundary.isClosed,
            boundaryUnknown: !hasDivider && atTail && tail.boundary.isUnknown)
    }

    // MARK: - 边界未知的那一段

    /// 边界未知时的显示行：前导用户消息 + **一行**占位行 + 可安全保留的行。
    ///
    /// 可安全保留 = 不是过程细节的内容：缺口行、读者自己说的话、交付类工具
    /// （`send_image` 的成品）、尾部连续的回答行。其余过程行一条都不出——
    /// 过去「整段铺开」正是首帧行高集合不一致的成因。
    ///
    /// 没有可隐藏的过程内容时（只有讲话与回答）不插占位行：那时"未知"不改变任何东西。
    static func displayUnknown(_ turn: Turn, plan: Plan, state: TranscriptFoldState) -> [TimelineItem] {
        let trailingAnswer = trailingAnswerStart(turn, plan: plan)
        var hidden: Set<Int> = []
        for index in turn.leading.upperBound..<turn.range.upperBound {
            let item = plan.rows[index]
            if case .turnDivider = item.kind { continue }
            if case .processHeader(let header) = item.kind, header.isPrefetched { continue }
            if !isSafeRow(item, index: index, turn: turn, trailingAnswerStart: trailingAnswer) {
                hidden.insert(index)
            }
        }
        guard !hidden.isEmpty else { return spreadWithoutDivider(plan.rows[turn.range]) }

        var out: [TimelineItem] = []
        var placeholderInserted = false
        for index in turn.range {
            // 占位行插在第一个被隐藏的过程行位置上：顺序仍是"问题 → 过程（未知）→ 回答"。
            if !placeholderInserted, hidden.contains(index) {
                out.append(placeholderItem(turn: turn).item)
                placeholderInserted = true
            }
            if index < turn.leading.upperBound { out.append(plan.rows[index]); continue }
            let item = plan.rows[index]
            if case .turnDivider = item.kind { continue }
            if case .processHeader(let header) = item.kind, header.isPrefetched { continue }
            if hidden.contains(index) { continue }
            out.append(item)
        }
        if !placeholderInserted { out.append(placeholderItem(turn: turn).item) }
        return out
    }

    /// 原样铺开但不显示分隔行（职责已并入轮次行）。
    private static func spreadWithoutDivider(_ rows: ArraySlice<TimelineItem>) -> [TimelineItem] {
        rows.filter { if case .turnDivider = $0.kind { return false }; return true }
    }

    /// 边界未知时仍然可见的行（与收起态同一口径）。
    private static func isSafeRow(_ item: TimelineItem, index: Int, turn: Turn,
                                  trailingAnswerStart: Int) -> Bool {
        if turn.answerIndexes.contains(index) { return true }
        switch item.kind {
        case .gap:
            // 缺失区间在收起态也可见：藏进折叠里，读者会以为这一段历史完整。
            return true
        case .userMessage:
            // 读者自己说的话（前导或中途插话）不能被折叠收走；agent 代发的图片
            // 是回答内容，同样保留。
            return true
        case .assistantText:
            // 尾部连续的回答行是这一轮唯一的正文可见部分。
            return index >= trailingAnswerStart
        case .toolCall(let invocation):
            // 交付类工具（send_image）的图片是成品，收起态也必须可见。
            return isDeliveryToolName(invocation.name)
        default:
            return false
        }
    }

    /// 尾部连续回答行（`assistantText` / agent 代发图片）的起点下标；
    /// 没有这样的行时返回 `range.upperBound`（即"没有"）。
    private static func trailingAnswerStart(_ turn: Turn, plan: Plan) -> Int {
        var index = turn.range.upperBound - 1
        var start = turn.range.upperBound
        while index >= turn.leading.upperBound {
            let item = plan.rows[index]
            let isAnswer: Bool
            switch item.kind {
            case .assistantText: isAnswer = true
            case .userMessage(_, _, _, _, let isAgentSent): isAnswer = isAgentSent
            default: isAnswer = false
            }
            guard isAnswer else { break }
            start = index
            index -= 1
        }
        return start
    }

    /// 占位行：身份与排序键都取这一轮的起点 `seq`（重折前后稳定、参与裁剪前缀比较）。
    static func placeholderItem(turn: Turn) -> TimelineProcessPlaceholder {
        TimelineProcessPlaceholder(turn: turn.turn, startSeq: turn.startSeq)
    }

    // MARK: - 轮次关闭那一刻的一次性保位

    /// 一次保位判定的结果。`skipped` 的理由进探针 `tail.boundary.hold`，
    /// 现场据此区分"读者不在过程里"和"读者已经自己决定过"。
    public enum ReaderHold: Equatable, Sendable {
        /// 命中：保住这一轮（命中行属于某个组时一并保住那个组）。
        case applied(turnKey: String, groupKey: String?)
        /// 没命中，理由进探针，现场据此区分四件事：
        /// - `noMeasurement`：宿主还没报顶部行（还没有测量值）；
        /// - `notLocated`：测量值有，但计划里定位不到它（映射缺行）；
        /// - `notInTurn`：定位到了，但不属于刚关闭的那一轮，或它不是过程行；
        /// - `manual`：读者已经亲手决定过，不覆盖。
        case skipped(reason: String)

        /// 探针里的取值：`applied` / `skipped:<理由>`。
        public var probeValue: String {
            switch self {
            case .applied: return "applied"
            case .skipped(let reason): return "skipped:\(reason)"
            }
        }

        public var turnKey: String? {
            if case .applied(let turnKey, _) = self { return turnKey }
            return nil
        }

        public var groupKey: String? {
            if case .applied(_, let groupKey) = self { return groupKey }
            return nil
        }
    }

    /// 读者顶部行是否落在**刚关闭的那一轮的过程区**里。
    ///
    /// 判定用的是**数据行计划**（`plan` over `items`），不是上一帧的显示行：
    /// 即便形态在这一帧要变，顶部行 id 仍然能在计划里定位到——"先变形态再判定"
    /// 与"先判定再变形态"因此是同一个结果。
    ///
    /// 口径（M4）：
    /// - 顶部行属于被关闭的那一轮，且是过程行（含概要 v2 的分组行与步骤行）→ 保位整轮；
    /// - 顶部行是分组行本身 → 保位整轮 + 该组；
    /// - 回答行 / 前导用户消息 / 缺口行 / 运行行 / 占位行 → 不保位；
    /// - 顶部行属于别的轮次，或映射里没有它（例如运行行的追加 id）→ 不保位。
    public static func readerHold(topRowID: String?, plan: Plan, closedTurn: Int) -> ReaderHold {
        // 两种"没有顶部行"必须分开：`noMeasurement` 是宿主还没报（本轮等下一次），
        // `notLocated` 是报上来了却在计划里找不到（映射缺行，属缺陷）。合并成一个值
        // 会让现场分不清"没测到"和"测到了但定位失败"（设计 §8.4 欠项 6）。
        guard let topRowID, !topRowID.isEmpty else { return .skipped(reason: "noMeasurement") }
        guard let turnKey = plan.rowTurnKey[topRowID],
              let turn = plan.turnByKey[turnKey] else { return .skipped(reason: "notLocated") }
        guard turn.turn == closedTurn else { return .skipped(reason: "notInTurn") }
        if turn.groups.contains(where: { $0.key == topRowID }) {
            return .applied(turnKey: turnKey, groupKey: topRowID)
        }
        guard plan.processRowIDs.contains(topRowID) else { return .skipped(reason: "notInTurn") }
        return .applied(turnKey: turnKey, groupKey: plan.rowGroupKey[topRowID])
    }
}

import DSHKit
import Foundation

/// Display projection and disclosure rules. Kept separate from the planning
/// file so both stay under the repository's 500-line ceiling.
extension TranscriptProcessFold {
    // MARK: - Projection

    public static func displayRows(_ plan: Plan, state: TranscriptFoldState) -> [TimelineItem] {
        var out: [TimelineItem] = []
        var index = 0
        while index < plan.rows.count {
            if let turn = plan.turnStarts[index] {
                out.append(contentsOf: display(turn, plan: plan, state: state))
                index = turn.range.upperBound
            } else {
                out.append(plan.rows[index])
                index += 1
            }
        }
        return out
    }

    public static func revealTarget(rowID: String, plan: Plan) -> RevealTarget? {
        guard let turnKey = plan.rowTurnKey[rowID] else { return nil }
        return RevealTarget(turnKey: turnKey, groupKey: plan.rowGroupKey[rowID], rowID: rowID)
    }

    /// 整轮是否展开。
    ///
    /// 只有"能收起"的轮次才读状态：停止的轮次常开（桌面实拍），运行中的轮次
    /// 没有轮次行、过程区本来就铺开。
    public static func isTurnExpanded(_ turn: Turn, plan: Plan,
                                      state: TranscriptFoldState) -> Bool {
        guard turn.canCollapse else { return true }
        if let manual = state.manualTurn[turn.key] { return manual }
        guard let top = state.readerTopRowID else { return false }
        // A group header is part of the process surface: keeping the turn open
        // while the reader sits on it avoids collapsing the content under them.
        if turn.groups.contains(where: { $0.key == top }) { return true }
        guard let topTurn = plan.rowTurnKey[top],
              topTurn == turn.key,
              plan.processRowIDs.contains(top) else { return false }
        return true
    }

    /// 一条分组行是否展开：读者亲手展开过，或者读者正停在组内某一行上
    ///（同 `isTurnExpanded` 的理由：不能把读者脚下的内容收走）。
    ///
    /// 概要 v2 的组没有成员行（组内步骤是投影生成的行），所以读者停在组行本身
    /// 或某条步骤行上时，这一组也算"正被阅读"，不能收走。
    public static func isGroupExpanded(_ group: Group, plan: Plan,
                                       state: TranscriptFoldState) -> Bool {
        if state.expandedGroups.contains(group.key) { return true }
        guard let top = state.readerTopRowID else { return false }
        if top == group.key { return true }
        if group.isFromSummary { return group.steps.contains { $0.id == top } }
        return group.indexes.contains { plan.rows[$0].id == top }
    }

    // MARK: - Display internals

    /// 一轮的显示行。
    ///
    /// 三条形状，与桌面一致（设计 §3.1、§3.3）：
    /// - 运行中：没有轮次行；分组行都在、都收起，最后一条标记为运行时行；
    /// - 已结束且有过程：一行轮次行（收起时只剩它 + 回答）；
    /// - 没有过程行或尚未结束的尾段：原样铺开，但**分隔行一律不再显示**。
    ///
    /// 概要 v2（`turn.hasSummary`）走 `displaySummary`：过程行没有下发，
    /// 分组与步骤只能从概要生成。
    private static func display(_ turn: Turn, plan: Plan,
                                state: TranscriptFoldState) -> [TimelineItem] {
        if turn.hasSummary {
            guard turn.isFoldable || turn.isRunning else {
                return withoutDivider(plan.rows[turn.range])
            }
            return displaySummary(turn, plan: plan, state: state)
        }
        if turn.isRunning { return displayRunning(turn, plan: plan, state: state) }
        guard turn.isFoldable else { return withoutDivider(plan.rows[turn.range]) }
        let expanded = isTurnExpanded(turn, plan: plan, state: state)
        let header = turnHeader(turn, expanded: expanded)
        let processSet = Set(turn.processIndexes)
        var out = Array(plan.rows[turn.range.lowerBound..<turn.leading.upperBound])
        var headerInserted = false
        let groupByMember = Dictionary(uniqueKeysWithValues:
            turn.groups.flatMap { group in group.indexes.map { ($0, group) } })
        let groupByStart = Dictionary(uniqueKeysWithValues:
            turn.groups.compactMap { group in group.indexes.first.map { ($0, group) } })

        for index in turn.leading.upperBound..<turn.range.upperBound {
            if !headerInserted, processSet.contains(index) {
                out.append(header.item)
                headerInserted = true
            }
            // 预折摘要只提供表头计数，本身不再作为一行显示：收起时它和其它过程行
            // 一起被藏起来，展开时明细已由上层回取，也不需要这条摘要。
            if case .processHeader(let summary) = plan.rows[index].kind, summary.isPrefetched {
                continue
            }
            // 分隔行的职责已并入轮次行（底边 0.5pt 线），投影不再输出它。
            if case .turnDivider = plan.rows[index].kind { continue }
            if !expanded {
                if turn.answerIndexes.contains(index) {
                    out.append(plan.rows[index])
                } else if case .gap = plan.rows[index].kind {
                    // 缺失区间在收起状态下仍然可见：把它藏进折叠里，读者会以为
                    // 这一段历史完整，而实际是没取到。
                    out.append(plan.rows[index])
                } else if case .userMessage = plan.rows[index].kind {
                    // 中途输入的 user 消息是读者的内容，不是过程细节：折叠只能收
                    // 过程行，不能把读者自己说的话收进去。
                    out.append(plan.rows[index])
                }
                continue
            }
            // 展开：先一条分组行，组展开才出现组内的步骤卡。单组也显示（桌面同款）。
            if let group = groupByStart[index] {
                out.append(groupHeader(group, expanded: isGroupExpanded(group, plan: plan, state: state),
                                       isRunning: false).item)
            }
            if let group = groupByMember[index],
               !isGroupExpanded(group, plan: plan, state: state) {
                continue
            }
            out.append(plan.rows[index])
        }
        if !headerInserted { out.append(header.item) }
        return out
    }

    /// 概要 v2 的一轮显示行。
    ///
    /// 过程正文不在窗口里：收起态只剩轮次行与回答；展开后分组行来自概要的
    /// `groups`，组再展开才出现步骤元数据行（名称/预览/状态/字节数）。
    /// 中间讲话按 seq 插在组之间；图片回答（agent 代发的图片行）照常在收起态可见。
    ///
    /// 运行中的一轮没有轮次行：分组行常显、组内步骤仍要读者点开，
    /// 当前在跑的那条分组行带 `isRunning`（视图据此写「正在… · 命令」）。
    private static func displaySummary(_ turn: Turn, plan: Plan,
                                       state: TranscriptFoldState) -> [TimelineItem] {
        let expanded = turn.isRunning || isTurnExpanded(turn, plan: plan, state: state)
        let header = turnHeader(turn, expanded: expanded)

        /// 一个待排序的显示事件。`order` 决定同 seq 的先后：轮次行 → 分组行 →
        /// 步骤行 → 时间线里的行（同一条助手消息里，思考步骤先于它后面的正文）。
        struct Event {
            let seq: Int
            let order: Int
            let base: Int
            let item: TimelineItem
            let isTurnHeader: Bool
            let isProcess: Bool
            let visibleCollapsed: Bool
        }
        var events: [Event] = [
            Event(seq: turn.startSeq, order: -1, base: -1, item: header.item,
                  isTurnHeader: true, isProcess: true, visibleCollapsed: false),
        ]

        for index in turn.range {
            let item = plan.rows[index]
            // 分隔行的职责已并入轮次行（底边 0.5pt 线），预折摘要行只给表头计数：
            // 两者都不投影。
            if case .turnDivider = item.kind { continue }
            if case .processHeader(let summary) = item.kind, summary.isPrefetched { continue }
            // 概要覆盖段里的原始过程行（follow 快照留下的）不再显示：过程只由概要投影。
            if Self.isSuppressedBySummary(item, turn: turn) { continue }
            let visible: Bool
            switch item.kind {
            case .userMessage, .gap:
                visible = true
            default:
                visible = turn.answerIndexes.contains(index)
            }
            events.append(Event(seq: item.seq, order: 2, base: index, item: item,
                                isTurnHeader: false, isProcess: !visible,
                                visibleCollapsed: visible))
        }

        let activeGroupKey = turn.groups.last?.key
        for (offset, group) in turn.groups.enumerated() {
            let groupExpanded = expanded && isGroupExpanded(group, plan: plan, state: state)
            // 运行中的一轮：最后那条分组行是「正在…」的实时行（桌面同款）；
            // 概要里带 running 状态的分组也标运行态。
            let groupRunning = group.isRunning
                || (turn.isRunning && group.key == activeGroupKey)
            events.append(Event(
                seq: group.startSeq,
                order: 0,
                base: offset,
                item: groupHeader(group, expanded: groupExpanded, isRunning: groupRunning).item,
                isTurnHeader: false,
                isProcess: true,
                visibleCollapsed: false))
            guard groupExpanded else { continue }
            for (stepOffset, step) in group.steps.enumerated() {
                events.append(Event(seq: step.seq, order: 1, base: stepOffset, item: step.item,
                                    isTurnHeader: false, isProcess: true,
                                    visibleCollapsed: false))
            }
        }

        events.sort { lhs, rhs in
            if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.base < rhs.base
        }

        var out: [TimelineItem] = []
        for event in events {
            if event.isTurnHeader {
                // 运行中的一轮没有轮次行（桌面同款）。
                if !turn.isRunning { out.append(event.item) }
                continue
            }
            if !expanded && !event.visibleCollapsed { continue }
            out.append(event.item)
        }
        return out
    }

    /// 这条原始行是不是被概要覆盖（只可能是工具调用/思考行）。
    private static func isSuppressedBySummary(_ item: TimelineItem, turn: Turn) -> Bool {
        switch item.kind {
        case .toolCall, .reasoning:
            return turn.summaries.contains { summary in
                summary.groups.contains { $0.startSeq <= item.seq && item.seq <= $0.endSeq }
            }
        default:
            return false
        }
    }

    /// 运行中的一轮。
    ///
    /// 没有轮次行，也没有分隔行；每条分组行都在，默认收起（读者点开才看步骤）。
    /// 最后一条（仍在增长的那条）带 `isRunning`，视图据此写"正在<动作> · <detail>"。
    private static func displayRunning(_ turn: Turn, plan: Plan,
                                       state: TranscriptFoldState) -> [TimelineItem] {
        var out = Array(plan.rows[turn.range.lowerBound..<turn.leading.upperBound])
        let groupByMember = Dictionary(uniqueKeysWithValues:
            turn.groups.flatMap { group in group.indexes.map { ($0, group) } })
        let groupByStart = Dictionary(uniqueKeysWithValues:
            turn.groups.compactMap { group in group.indexes.first.map { ($0, group) } })
        let activeGroupKey = turn.groups.last?.key

        for index in turn.leading.upperBound..<turn.range.upperBound {
            if case .processHeader(let summary) = plan.rows[index].kind, summary.isPrefetched {
                continue
            }
            if case .turnDivider = plan.rows[index].kind { continue }
            if let group = groupByStart[index] {
                out.append(groupHeader(group, expanded: isGroupExpanded(group, plan: plan, state: state),
                                       isRunning: group.key == activeGroupKey).item)
            }
            if let group = groupByMember[index],
               !isGroupExpanded(group, plan: plan, state: state) {
                continue
            }
            out.append(plan.rows[index])
        }
        return out
    }

    private static func withoutDivider(_ rows: ArraySlice<TimelineItem>) -> [TimelineItem] {
        rows.filter { if case .turnDivider = $0.kind { return false }; return true }
    }

    private static func turnHeader(_ turn: Turn, expanded: Bool) -> TimelineProcessHeader {
        TimelineProcessHeader(
            id: turn.key,
            scope: .turn,
            turn: turn.turn,
            startSeq: turn.startSeq,
            endSeq: turn.endSeq,
            toolCount: turn.toolCount,
            reasoningCount: turn.reasoningCount,
            messageCount: turn.messageCount,
            subagentCount: turn.subagentCount,
            activityCounts: turn.activityCounts,
            isExpanded: expanded,
            // 停止的轮次常开、无箭头、不可点：`isFoldable` 在表头上就表示"能收起"。
            isFoldable: turn.canCollapse,
            isRunning: turn.isRunning,
            endReason: turn.endReason,
            duration: turn.duration,
            hasFailure: turn.hasFailure,
            isPartial: turn.isPartial)
    }

    private static func groupHeader(_ group: Group, expanded: Bool,
                                    isRunning: Bool) -> TimelineProcessHeader {
        TimelineProcessHeader(
            id: group.key,
            scope: .group,
            turn: 0,
            startSeq: group.startSeq,
            endSeq: group.endSeq,
            toolCount: group.toolCount,
            reasoningCount: group.reasoningCount,
            messageCount: 0,
            subagentCount: group.subagentCount,
            activityCounts: group.activityCounts,
            isExpanded: expanded,
            isFoldable: true,
            isRunning: isRunning,
            endReason: nil,
            duration: nil,
            hasFailure: false,
            isPartial: false)
    }
}

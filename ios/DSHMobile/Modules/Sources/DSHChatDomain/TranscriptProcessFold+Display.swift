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

    /// Whether a group is already sealed. In a running turn only the last
    /// group (the one still growing at the tail) is active; every group before
    /// it, and a last group followed by an assistant reply, is closed.
    public static func isGroupClosed(_ group: Group, in turn: Turn) -> Bool {
        guard turn.isRunning else { return true }
        guard group.key == turn.groups.last?.key else { return true }
        return group.indexes.last != turn.range.upperBound - 1
    }

    public static func isTurnExpanded(_ turn: Turn, plan: Plan,
                                      state: TranscriptFoldState) -> Bool {
        guard turn.isFoldable else { return true }
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

    // MARK: - Display internals

    private static func display(_ turn: Turn, plan: Plan,
                                state: TranscriptFoldState) -> [TimelineItem] {
        if turn.isRunning, turn.groups.count > 1 {
            return displayRunning(turn, plan: plan, state: state)
        }
        guard turn.isFoldable else { return mergedPrefetched(turn, plan: plan) }
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
            if !expanded {
                if index == turn.finalAnswerIndex || index == turn.dividerIndex {
                    out.append(plan.rows[index])
                }
                continue
            }
            if turn.groups.count > 1, let group = groupByStart[index] {
                let open = !state.collapsedGroups.contains(group.key)
                out.append(groupHeader(group, expanded: open).item)
            }
            if let group = groupByMember[index], state.collapsedGroups.contains(group.key) {
                continue
            }
            out.append(plan.rows[index])
        }
        if !headerInserted { out.append(header.item) }
        return out
    }


    /// A running turn still folds the subtrees that are already sealed: every
    /// process group followed by an intermediate reply is a completed subtree,
    /// while the last group (still growing) stays open. This mirrors the
    /// desktop client's `stepGrouping: collapsed` behaviour.
    private static func displayRunning(_ turn: Turn, plan: Plan,
                                       state: TranscriptFoldState) -> [TimelineItem] {
        var out = Array(plan.rows[turn.range.lowerBound..<turn.leading.upperBound])
        let groupByMember = Dictionary(uniqueKeysWithValues:
            turn.groups.flatMap { group in group.indexes.map { ($0, group) } })
        let groupByStart = Dictionary(uniqueKeysWithValues:
            turn.groups.compactMap { group in group.indexes.first.map { ($0, group) } })
        let lastGroupKey = turn.groups.last?.key
        let lastRow = turn.range.upperBound - 1

        func isClosed(_ group: Group) -> Bool {
            TranscriptProcessFold.isGroupClosed(group, in: turn)
        }

        for index in turn.leading.upperBound..<turn.range.upperBound {
            if let group = groupByStart[index], isClosed(group) {
                // Sealed groups default to collapsed while the turn is live.
                let open = state.expandedGroups.contains(group.key)
                out.append(groupHeader(group, expanded: open).item)
            }
            if let group = groupByMember[index], isClosed(group),
               !state.expandedGroups.contains(group.key) {
                continue
            }
            out.append(plan.rows[index])
        }
        return out
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
            isFoldable: turn.isFoldable,
            isRunning: turn.isRunning,
            endReason: turn.endReason,
            duration: turn.duration,
            hasFailure: turn.hasFailure,
            isPartial: turn.isPartial)
    }

    private static func groupHeader(_ group: Group, expanded: Bool) -> TimelineProcessHeader {
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
            isRunning: false,
            endReason: nil,
            duration: nil,
            hasFailure: false,
            isPartial: false)
    }

    /// 一轮里可能有多条连接器下发的摘要（一层跨多页，每页各自折了自己的过程段）。
    /// 显示上合并成一行：计数相加、seq 段取并、轮次与状态取第一条。展开时由上层
    /// 按合并后的区间整段回取，不需要知道原来分了几段。
    private static func mergedPrefetched(_ turn: Turn, plan: Plan) -> [TimelineItem] {
        var indexes: [Int] = []
        for index in turn.range {
            if case .processHeader(let header) = plan.rows[index].kind, header.isPrefetched {
                indexes.append(index)
            }
        }
        guard indexes.count > 1 else { return Array(plan.rows[turn.range]) }
        let headers = indexes.compactMap { index -> TimelineProcessHeader? in
            if case .processHeader(let header) = plan.rows[index].kind { return header }
            return nil
        }
        guard let first = headers.first, let last = headers.last else {
            return Array(plan.rows[turn.range])
        }
        let merged = TimelineProcessHeader(
            id: first.id,
            scope: .turn,
            turn: first.turn,
            startSeq: headers.map(\.startSeq).min() ?? first.startSeq,
            endSeq: headers.map(\.endSeq).max() ?? last.endSeq,
            toolCount: headers.reduce(0) { $0 + $1.toolCount },
            reasoningCount: headers.reduce(0) { $0 + $1.reasoningCount },
            messageCount: headers.reduce(0) { $0 + $1.messageCount },
            subagentCount: headers.reduce(0) { $0 + $1.subagentCount },
            activityCounts: [:],
            isExpanded: false,
            isFoldable: true,
            isRunning: false,
            endReason: first.endReason,
            duration: nil,
            hasFailure: false,
            isPartial: false,
            isPrefetched: true
        )
        let firstIndex = indexes[0]
        var mergedItem = plan.rows[firstIndex]
        mergedItem.kind = .processHeader(merged)
        var out: [TimelineItem] = []
        for index in turn.range {
            if index == firstIndex { out.append(mergedItem); continue }
            if indexes.contains(index) { continue }
            out.append(plan.rows[index])
        }
        return out
    }

}

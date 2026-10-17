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
        guard turn.isFoldable else { return Array(plan.rows[turn.range]) }
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
}

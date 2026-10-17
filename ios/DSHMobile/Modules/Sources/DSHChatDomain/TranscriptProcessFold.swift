import DSHKit
import Foundation

/// Reader-owned disclosure state for one session's process nodes.
///
/// This is UI state, not transcript data: switching sessions or relaunching
/// starts from the defaults. Keys are header identities, so a turn or group
/// keeps its state while its members grow.
public struct TranscriptFoldState: Sendable, Equatable {
    /// `true` = the reader expanded the turn; `false` = collapsed it.
    /// Absent means "use the default" (completed folds, live/abnormal stays open).
    public var manualTurn: [String: Bool]
    /// Groups default to expanded; only explicit collapses are stored.
    public var collapsedGroups: Set<String>
    /// A closed group inside a running turn defaults to collapsed; this is the
    /// explicit "I opened it" set. (Completed turns default to expanded.)
    public var expandedGroups: Set<String>
    /// The top fully visible row reported by the list host. Used to keep the
    /// turn the reader is currently inside from collapsing under their finger.
    public var readerTopRowID: String?

    public init(manualTurn: [String: Bool] = [:],
                collapsedGroups: Set<String> = [],
                expandedGroups: Set<String> = [],
                readerTopRowID: String? = nil) {
        self.manualTurn = manualTurn
        self.collapsedGroups = collapsedGroups
        self.expandedGroups = expandedGroups
        self.readerTopRowID = readerTopRowID
    }
}

/// A pure display projection over `ChatTimeline.items`.
///
/// The fold never deletes or rewrites a journal row. It answers two questions:
/// which maximal turn segments exist, and which rows should be visible for a
/// given disclosure state. Search, paging, trimming and long-press keep using
/// the original rows.
public enum TranscriptProcessFold {

    public struct Turn: Sendable, Identifiable {
        public let key: String
        public let turn: Int
        public let range: Range<Int>
        public let leading: Range<Int>
        /// Process rows in original order. Intermediate assistant prose is a
        /// member (and a group separator); the final answer is not.
        public let processIndexes: [Int]
        public let finalAnswerIndex: Int?
        public let dividerIndex: Int?
        public let groups: [Group]
        public let isFoldable: Bool
        public let isRunning: Bool
        public let hasFailure: Bool
        public let hasGap: Bool
        public let hasInterleavedInput: Bool
        public let isPartial: Bool
        public let endReason: String?
        public let duration: TimeInterval?
        public let toolCount: Int
        public let reasoningCount: Int
        public let messageCount: Int
        public let subagentCount: Int
        public let activityCounts: [TimelineProcessActivity: Int]
        public let startSeq: Int
        public let endSeq: Int

        public var id: String { key }
    }

    public struct Group: Sendable, Identifiable {
        public let key: String
        public let turnKey: String
        public let indexes: [Int]
        public let startSeq: Int
        public let endSeq: Int
        public let toolCount: Int
        public let reasoningCount: Int
        public let subagentCount: Int
        public let activityCounts: [TimelineProcessActivity: Int]

        public var id: String { key }
        public var range: ClosedRange<Int> { startSeq...endSeq }
    }

    public struct RevealTarget: Sendable, Equatable {
        public let turnKey: String
        public let groupKey: String?
        public let rowID: String
    }

    public struct Plan: Sendable {
        public let rows: [TimelineItem]
        public let turns: [Turn]
        public let groups: [Group]
        public let looseIndexes: [Int]
        public let rowTurnKey: [String: String]
        public let rowGroupKey: [String: String]
        public let turnByKey: [String: Turn]
        public let groupByKey: [String: Group]
        public let processRowIDs: Set<String>

        /// Internal lookup used by `displayRows`; not part of the semantic API.
        public let turnStarts: [Int: Turn]

        public init(rows: [TimelineItem], turns: [Turn], groups: [Group],
                    looseIndexes: [Int], rowTurnKey: [String: String],
                    rowGroupKey: [String: String], turnByKey: [String: Turn],
                    groupByKey: [String: Group], processRowIDs: Set<String>,
                    turnStarts: [Int: Turn]) {
            self.rows = rows
            self.turns = turns
            self.groups = groups
            self.looseIndexes = looseIndexes
            self.rowTurnKey = rowTurnKey
            self.rowGroupKey = rowGroupKey
            self.turnByKey = turnByKey
            self.groupByKey = groupByKey
            self.processRowIDs = processRowIDs
            self.turnStarts = turnStarts
        }
    }

    // MARK: - Planning

    public static func plan(items: [TimelineItem],
                            isTurnOpen: Bool,
                            currentTurn: Int = 0) -> Plan {
        var segments: [Segment] = []
        var loose: [Int] = []
        var current: Segment?

        for (index, item) in items.enumerated() {
            switch item.kind {
            case .userMessage(_, _, let isSteering, _, let isAgentSent):
                if current == nil {
                    current = Segment(start: index, end: index)
                } else if isSteering || isAgentSent {
                    current?.hasInterleavedInput = true
                    current?.end = index
                } else if current?.hasDivider == true {
                    if let finished = current { segments.append(finished) }
                    current = Segment(start: index, end: index)
                } else {
                    // A second real input inside one open turn: keep it visible
                    // and make the turn non-foldable rather than hiding it.
                    current?.hasInterleavedInput = true
                    current?.end = index
                }

            case .turnDivider(let turn, let reason, let duration):
                if current == nil { current = Segment(start: index, end: index) }
                current?.dividerIndex = index
                current?.dividerTurn = turn
                current?.endReason = reason
                current?.duration = duration
                current?.hasDivider = true
                current?.end = index
                if Self.abnormalEnd(reason) { current?.hasFailure = true }
                if let finished = current { segments.append(finished) }
                current = nil

            case .gap:
                if current == nil { loose.append(index) }
                else { current?.hasGap = true; current?.end = index }

            case .notice(_, let isError):
                if current == nil { loose.append(index) }
                else {
                    if isError { current?.hasFailure = true }
                    current?.end = index
                }

            case .toolCall, .reasoning, .assistantText:
                // A history page can start mid-turn. Those rows still form a
                // segment; only notices and gaps before a turn are loose.
                if current == nil { current = Segment(start: index, end: index) }
                else { current?.end = index }

            default:
                if current == nil { loose.append(index) }
                else { current?.end = index }
            }
        }
        if let tail = current { segments.append(tail) }

        var turns: [Turn] = []
        var allGroups: [Group] = []
        var rowTurnKey: [String: String] = [:]
        var rowGroupKey: [String: String] = [:]

        for (segmentIndex, segment) in segments.enumerated() {
            let range = segment.start..<(segment.end + 1)
            let isTail = segmentIndex == segments.count - 1
            let isRunning = !segment.hasDivider && isTail && isTurnOpen

            var leadingEnd = segment.start
            while leadingEnd <= segment.end,
                  case .userMessage = items[leadingEnd].kind {
                leadingEnd += 1
            }
            let leading = segment.start..<leadingEnd
            if leading.count > 1 { /* handled below as interleaved */ }

            let answerEnd = segment.dividerIndex ?? (segment.end + 1)
            var finalAnswer: Int?
            if segment.hasDivider {
                for index in stride(from: answerEnd - 1, through: leadingEnd, by: -1) {
                    if case .assistantText = items[index].kind {
                        finalAnswer = index
                        break
                    }
                }
            }

            var processIndexes: [Int] = []
            for index in leadingEnd..<answerEnd where index != finalAnswer {
                processIndexes.append(index)
            }

            let inferredTurn = segment.dividerTurn
                ?? Self.lastToolTurn(in: range, items: items)
                ?? (isRunning ? currentTurn : 0)
            let startSeq = processIndexes.first.map { items[$0].seq } ?? items[segment.start].seq
            let endSeq = processIndexes.last.map { items[$0].seq } ?? items[segment.end].seq
            let key: String
            if inferredTurn > 0 {
                key = "turn-process:\(inferredTurn)"
            } else {
                key = "turn-process:seq:\(startSeq)"
            }

            var groups: [Group] = []
            var builder: [Int] = []
            func closeGroup() {
                guard let first = builder.first, let last = builder.last else { return }
                let counts = Self.counts(indexes: builder, items: items)
                let groupKey: String
                if inferredTurn > 0 {
                    groupKey = "process-group:\(inferredTurn):\(items[first].seq)"
                } else {
                    groupKey = "process-group:seq:\(items[first].seq)"
                }
                let group = Group(
                    key: groupKey,
                    turnKey: key,
                    indexes: builder,
                    startSeq: items[first].seq,
                    endSeq: items[last].seq,
                    toolCount: counts.tools,
                    reasoningCount: counts.reasoning,
                    subagentCount: counts.subagents,
                    activityCounts: counts.activities)
                groups.append(group)
                allGroups.append(group)
                builder = []
            }
            for index in processIndexes {
                if case .assistantText = items[index].kind {
                    closeGroup()
                } else {
                    builder.append(index)
                }
            }
            closeGroup()

            let counts = Self.counts(indexes: processIndexes, items: items)
            let interleaved = segment.hasInterleavedInput || leading.count > 1
            let isPartial = leading.isEmpty || (segment.dividerIndex == nil && !isRunning)
            // 连接器折好下发的摘要（`isPrefetched`）本身就是要显示的那一行：
            // 这一轮不能再被折叠，否则摘要会被"由真实过程行推导出的表头"替代，
            // 而那些行根本没下发。点开摘要时由上层回取详情，之后这一轮才恢复可折。
            let hasPrefetchedSummary = processIndexes.contains { index in
                if case .processHeader(let header) = items[index].kind { return header.isPrefetched }
                return false
            }
            let foldable = segment.hasDivider
                && !isRunning
                && !segment.hasFailure
                && !segment.hasGap
                && !interleaved
                && !hasPrefetchedSummary
                && !processIndexes.isEmpty

            let turn = Turn(
                key: key,
                turn: inferredTurn,
                range: range,
                leading: leading,
                processIndexes: processIndexes,
                finalAnswerIndex: finalAnswer,
                dividerIndex: segment.dividerIndex,
                groups: groups,
                isFoldable: foldable,
                isRunning: isRunning,
                hasFailure: segment.hasFailure,
                hasGap: segment.hasGap,
                hasInterleavedInput: interleaved,
                isPartial: isPartial,
                endReason: segment.endReason,
                duration: segment.duration,
                toolCount: counts.tools,
                reasoningCount: counts.reasoning,
                messageCount: counts.messages,
                subagentCount: counts.subagents,
                activityCounts: counts.activities,
                startSeq: startSeq,
                endSeq: endSeq)
            turns.append(turn)

            for index in range {
                rowTurnKey[items[index].id] = key
            }
            for group in groups {
                for index in group.indexes {
                    rowGroupKey[items[index].id] = group.key
                }
            }
        }

        var turnStarts: [Int: Turn] = [:]
        var turnByKey: [String: Turn] = [:]
        for turn in turns {
            turnStarts[turn.range.lowerBound] = turn
            turnByKey[turn.key] = turn
        }
        var groupByKey: [String: Group] = [:]
        for group in allGroups { groupByKey[group.key] = group }
        let processIDs = Set(turns.flatMap { turn in
            turn.processIndexes.map { items[$0].id }
        })
        return Plan(rows: items, turns: turns, groups: allGroups, looseIndexes: loose,
                    rowTurnKey: rowTurnKey, rowGroupKey: rowGroupKey,
                    turnByKey: turnByKey, groupByKey: groupByKey,
                    processRowIDs: processIDs, turnStarts: turnStarts)
    }

    // MARK: - Small helpers

    private struct Segment {
        let start: Int
        var end: Int
        var hasDivider = false
        var dividerIndex: Int?
        var dividerTurn: Int?
        var endReason: String?
        var duration: TimeInterval?
        var hasGap = false
        var hasFailure = false
        var hasInterleavedInput = false
    }

    private struct Counts {
        var tools = 0
        var reasoning = 0
        var messages = 0
        var subagents = 0
        var activities: [TimelineProcessActivity: Int] = [:]
    }

    private static func counts(indexes: [Int], items: [TimelineItem]) -> Counts {
        var counts = Counts()
        for index in indexes {
            switch items[index].kind {
            case .toolCall(let invocation):
                counts.tools += 1
                let activity = TimelineProcessActivity.classify(invocation.name)
                counts.activities[activity, default: 0] += 1
                if activity == .subagents { counts.subagents += 1 }
            case .reasoning:
                counts.reasoning += 1
            case .assistantText:
                counts.messages += 1
            default:
                break
            }
        }
        return counts
    }

    private static func lastToolTurn(in range: Range<Int>, items: [TimelineItem]) -> Int? {
        for index in range.reversed() {
            if case .toolCall(let invocation) = items[index].kind, invocation.turn > 0 {
                return invocation.turn
            }
        }
        return nil
    }

    private static func abnormalEnd(_ reason: String) -> Bool {
        switch reason {
        case "cancelled", "canceled", "interrupted", "error", "failed", "aborted":
            return true
        default:
            return false
        }
    }
}

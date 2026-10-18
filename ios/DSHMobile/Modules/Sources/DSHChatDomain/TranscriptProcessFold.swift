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

    /// 一轮是否可折叠的纯判据。
    ///
    /// 不做布局、不读状态，单测直接据此钉边界：缺段（gap）与中途输入都不是
    /// "不可折"的理由——前者以轮内一行保留，后者是分组边界。
    public static func isFoldable(hasDivider: Bool, isRunning: Bool, hasFailure: Bool,
                                  hasProcessRows: Bool) -> Bool {
        hasDivider && !isRunning && !hasFailure && hasProcessRows
    }

    public struct Turn: Sendable, Identifiable {
        public let key: String
        public let turn: Int
        public let range: Range<Int>
        public let leading: Range<Int>
        /// Process rows in original order. Intermediate assistant prose is a
        /// member (and a group separator); the final answer is not.
        public let processIndexes: [Int]
        public let answerIndexes: Set<Int>
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
            // 正式回答 = 分隔线之前**末尾连续的一段回答内容**，不只是最后一条助手文本。
            // 图片型回答（agent 发送的图片消息）不是 `assistantText`；旧规则把它当过程，
            // 收起时就被一起藏掉。工具产出里的图片仍然是过程，不会被算进来。
            func isAnswerRow(_ item: TimelineItem) -> Bool {
                switch item.kind {
                case .assistantText: return true
                // agent 发送的图片消息是回答内容，不是过程；工具产出里的图片不在此列。
                case .userMessage(_, _, _, _, let isAgentSent): return isAgentSent
                default: return false
                }
            }
            var answerIndexes = Set<Int>()
            if segment.hasDivider {
                // 回答 = 最后一个回答行所在的连续段。允许它后面还有尾部过程行
                //（例如回答之后的投递工具），这些仍算过程、收起时隐藏。
                var last: Int?
                for index in stride(from: answerEnd - 1, through: leadingEnd, by: -1)
                where isAnswerRow(items[index]) {
                    last = index
                    break
                }
                if let start = last {
                    var index = start
                    while index >= leadingEnd, isAnswerRow(items[index]) {
                        answerIndexes.insert(index)
                        index -= 1
                    }
                    index = start + 1
                    while index < answerEnd, isAnswerRow(items[index]) {
                        answerIndexes.insert(index)
                        index += 1
                    }
                }
            }

            var processIndexes: [Int] = []
            for index in leadingEnd..<answerEnd where !answerIndexes.contains(index) {
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
            // 连接器预折摘要（`isPrefetched`）是这一轮**全部**过程的计数来源：
            // 明细可能还没下发，按行数会漏计；明细已下发时按行再数一遍又会重复。
            // 所以只要存在摘要，就用摘要的计数与用时，折叠表头与近期轮次同一样式。
            var summaryTools = 0, summaryReasoning = 0, summaryMessages = 0, summarySubagents = 0
            var summaryDuration: TimeInterval?
            var summaryEndReason: String?
            var summaryStart: Int?
            var summaryEnd: Int?
            var hasPrefetchedSummary = false
            for index in processIndexes {
                guard case .processHeader(let header) = items[index].kind, header.isPrefetched else { continue }
                hasPrefetchedSummary = true
                summaryTools += header.toolCount
                summaryReasoning += header.reasoningCount
                summaryMessages += header.messageCount
                summarySubagents += header.subagentCount
                if summaryDuration == nil { summaryDuration = header.duration }
                if summaryEndReason == nil { summaryEndReason = header.endReason }
                summaryStart = min(summaryStart ?? header.startSeq, header.startSeq)
                summaryEnd = max(summaryEnd ?? header.endSeq, header.endSeq)
            }
            // 折叠的判据只看"这一轮是否已结束、是否有过程行、是否可以隐藏细节"。
            // 缺失区间与中途输入不再取消整轮折叠；预折摘要也不再让整轮铺开——
            // 摘要只提供计数，折叠仍由这一轮的普通表头承担。
            let foldable = Self.isFoldable(
                hasDivider: segment.hasDivider,
                isRunning: isRunning,
                hasFailure: segment.hasFailure,
                hasProcessRows: !processIndexes.isEmpty)

            let turn = Turn(
                key: key,
                turn: inferredTurn,
                range: range,
                leading: leading,
                processIndexes: processIndexes,
                answerIndexes: answerIndexes,
                dividerIndex: segment.dividerIndex,
                groups: groups,
                isFoldable: foldable,
                isRunning: isRunning,
                hasFailure: segment.hasFailure,
                hasGap: segment.hasGap,
                hasInterleavedInput: interleaved,
                isPartial: isPartial,
                endReason: summaryEndReason ?? segment.endReason,
                duration: summaryDuration ?? segment.duration,
                toolCount: hasPrefetchedSummary ? summaryTools : counts.tools,
                reasoningCount: hasPrefetchedSummary ? summaryReasoning : counts.reasoning,
                messageCount: hasPrefetchedSummary ? summaryMessages : counts.messages,
                subagentCount: hasPrefetchedSummary ? summarySubagents : counts.subagents,
                activityCounts: counts.activities,
                startSeq: hasPrefetchedSummary ? (summaryStart ?? startSeq) : startSeq,
                endSeq: hasPrefetchedSummary ? (summaryEnd ?? endSeq) : endSeq)
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

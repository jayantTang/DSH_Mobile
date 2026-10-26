import DSHKit
import Foundation

/// Reader-owned disclosure state for one session's process nodes.
///
/// This is UI state, not transcript data: switching sessions or relaunching
/// starts from the defaults. Keys are header identities, so a turn or group
/// keeps its state while its members grow.
public struct TranscriptFoldState: Sendable, Equatable {
    /// `true` = the reader expanded the turn; `false` = collapsed it.
    /// Absent means "use the default": finished turns fold, stopped turns stay open.
    public var manualTurn: [String: Bool]
    /// 分组只有一种状态需要记：读者亲手展开的组。缺省（不在集合里）就是收起——
    /// 桌面「完成即折叠」把组也收起，运行中的组同理，所以不再另存一个"收起"集合。
    public var expandedGroups: Set<String>
    /// 读者亲手展开的**步骤卡**（概要 v2）：展开才按需取那一条正文。
    public var expandedSteps: Set<String>
    /// The top fully visible row reported by the list host. Used to keep the
    /// turn the reader is currently inside from collapsing under their finger.
    public var readerTopRowID: String?

    public init(manualTurn: [String: Bool] = [:],
                expandedGroups: Set<String> = [],
                expandedSteps: Set<String> = [],
                readerTopRowID: String? = nil) {
        self.manualTurn = manualTurn
        self.expandedGroups = expandedGroups
        self.expandedSteps = expandedSteps
        self.readerTopRowID = readerTopRowID
    }
}

/// 运行中过程区的实时状态：当前哪个工具在跑、它的一句话详情。
///
/// 分组行的「正在<动作> · <当前命令/工具>」与底部深度求索行共用这一份，
/// 所以它由一轮时间线算出来（`TranscriptProcessFold.runningDetail`），不散在视图里。
public struct ProcessRunningDetail: Sendable, Equatable {
    /// nil 表示当前没有工具在跑（模型在思考），此时只剩「正在分析请求」。
    public let activity: TimelineProcessActivity?
    /// 当前命令/工具的一句话预览；为空时标题只写动词。
    public let detail: String

    public init(activity: TimelineProcessActivity?, detail: String) {
        self.activity = activity
        self.detail = detail
    }
}

/// A pure display projection over `ChatTimeline.items`.
///
/// The fold never deletes or rewrites a journal row. It answers two questions:
/// which maximal turn segments exist, and which rows should be visible for a
/// given disclosure state. Search, paging, trimming and long-press keep using
/// the original rows.
public enum TranscriptProcessFold {

    /// 一轮是否可折叠的纯判据（= 这一轮该不该有一条轮次行）。
    ///
    /// 不做布局、不读状态，单测直接据此钉边界：缺段（gap）、中途输入、失败
    /// 都不是"不可折"的理由——缺段以轮内一行保留，中途输入是分组边界，
    /// 失败与正常完成同一套折叠（M5）。运行中的轮次没有轮次行。
    public static func isFoldable(hasDivider: Bool, isRunning: Bool, hasProcessRows: Bool) -> Bool {
        hasDivider && !isRunning && hasProcessRows
    }

    /// 当前在跑的工具：最后一个「已发出、结果还没回来」的调用。
    ///
    /// 宿主只有在轮次开着时才会有在跑的工具；没有工具在跑就是模型在思考，
    /// 返回一个 activity 为 nil 的值（视图据此写「正在分析请求」）。
    /// 轮次没开时返回 nil —— 这时本来就没有运行行。
    ///
    /// 概要 v2 没有 tool 行可以扫：当前动作从概要里最后一条 `status: "running"`
    /// 的步骤来。两条来源同一份口径，调用方不必自己判断模式。
    public static func runningDetail(in items: [TimelineItem],
                                     isTurnOpen: Bool,
                                     summaries: [FoldSummaryV2] = []) -> ProcessRunningDetail? {
        guard isTurnOpen else { return nil }
        for item in items.reversed() {
            guard case .toolCall(let invocation) = item.kind, invocation.isRunning else { continue }
            // 详情取参数预览（bash 是命令行）；没有预览就是工具名本身。
            let detail = invocation.summary.isEmpty ? invocation.name : invocation.summary
            return ProcessRunningDetail(activity: .classify(invocation.name), detail: detail)
        }
        for summary in summaries.reversed() {
            for group in summary.groups.reversed() {
                for step in group.steps.reversed() where step.isRunning {
                    let detail = step.preview.isEmpty ? step.name : step.preview
                    return ProcessRunningDetail(activity: step.activity, detail: detail)
                }
            }
        }
        return ProcessRunningDetail(activity: nil, detail: "")
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
        /// 认领到这一轮的概要 v2（按 startSeq 升序，可能不止一条）。
        public let summaries: [FoldSummaryV2]

        public var id: String { key }

        /// 这一轮的过程来自概要 v2（过程正文没有下发），分组与步骤由它投影出来。
        public var hasSummary: Bool { !summaries.isEmpty }

        /// 被停止的轮次（aborted / interrupted / cancelled）：桌面实拍是常开、
        /// 无箭头、按钮不可点，内容直接铺开。
        public var isStopped: Bool { ProcessFoldText.isStopped(endReason) }
        /// 失败的轮次（error / failed）：与正常完成同一套折叠，只是文案不同。
        public var isFailed: Bool { ProcessFoldText.isFailed(endReason) }

        /// 整轮能不能收起。停止的轮次不能；运行中的轮次根本没有轮次行。
        public var canCollapse: Bool { isFoldable && !isStopped }
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
        /// 概要 v2 的步骤元数据（普通分组为空：它的步骤是时间线里的原始行）。
        public let steps: [TimelineProcessStep]

        public var id: String { key }
        public var range: ClosedRange<Int> { startSeq...endSeq }
        /// 这一组的过程来自概要 v2，组内没有可显示的原始行。
        public var isFromSummary: Bool { !steps.isEmpty }
        /// 组里还有在跑的步骤（概要 v2）；普通分组恒 false。
        public var isRunning: Bool { steps.contains { $0.isRunning } }
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

    /// 一轮过程的时间线投影。
    ///
    /// - Parameter summaries: 概要 v2（`+link/fold` 的 `v:2`）解出的轮次元数据。
    ///   概要模式下过程正文没有下发，分组与步骤**只能**从这份数据来；缺省为空，
    ///   就是原来的 v1 路径（过程行从时间线里数）。
    public static func plan(items: [TimelineItem],
                            isTurnOpen: Bool,
                            currentTurn: Int = 0,
                            summaries: [FoldSummaryV2] = []) -> Plan {
        var segments: [Segment] = []
        var loose: [Int] = []
        var current: Segment?
        /// 已经被某个轮次认领的概要下标：一段概要只属于一个轮次。
        var claimedSummaries = Set<Int>()

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
            let inferredTurn = segment.dividerTurn
                ?? Self.lastToolTurn(in: range, items: items)
                ?? (isRunning ? currentTurn : 0)

            // 概要 v2：先按轮次号认领，缺轮次号（连接器给 null）时按 startSeq
            // 落在这一段的 seq 区间里认领。同一段概要只归一个轮次。
            var summariesForTurn: [FoldSummaryV2] = []
            if !summaries.isEmpty {
                let lowerSeq = items[segment.start].seq
                let upperSeq = items[segment.end].seq
                var claimed: [Int] = []
                for (offset, summary) in summaries.enumerated() where !claimedSummaries.contains(offset) {
                    let matches: Bool
                    if summary.turn > 0, inferredTurn > 0 {
                        matches = summary.turn == inferredTurn
                    } else {
                        matches = summary.startSeq >= lowerSeq && summary.startSeq <= upperSeq
                    }
                    if matches { claimed.append(offset) }
                }
                claimedSummaries.formUnion(claimed)
                summariesForTurn = claimed.map { summaries[$0] }.sorted { $0.startSeq < $1.startSeq }
            }
            // 概要段在 seq 空间里的起点：正式回答与中间讲话在 items 里都是
            // `assistantText`，只能用这些起点把它们切开（过程没有行可以当分隔）。
            let summaryStarts = summariesForTurn.map(\.startSeq)

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
                        // 概要 v2 的过程段不占行：中间讲话与正式回答在 items 里是
                        // 连续的回答行，必须用概要的起点把它们切开，否则收起态会把
                        // 中间讲话一起当成回答显示出来。v1（没有概要）走同一段代码、
                        // 但起点集合为空，行为与以前完全一致。
                        if index < start,
                           summaryStarts.contains(where: {
                               $0 > items[index].seq && $0 <= items[index + 1].seq
                           }) {
                            break
                        }
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

            // 概要覆盖的 seq 段里，即使窗口里还留着原始过程行（follow 快照带来的），
            // 也不再当过程显示/计数：过程的事实来源是概要，两份只留一份
            //（否则同一轮会同时出现分组行与旧工具卡）。
            //
            // 运行中的一轮例外：概要是一次请求的快照，实时行才是当前动作的真相；
            // 比概要更新的工具行必须照旧出现（概要范围里那些仍然不显示）。
            let summaryRanges = isRunning ? [] : summariesForTurn.flatMap { summary in
                summary.groups.map { $0.startSeq...$0.endSeq }
            }
            func suppressedBySummary(_ item: TimelineItem) -> Bool {
                guard !summaryRanges.isEmpty else { return false }
                switch item.kind {
                case .toolCall, .reasoning:
                    return summaryRanges.contains { $0.contains(item.seq) }
                default:
                    return false
                }
            }
            var processIndexes: [Int] = []
            for index in leadingEnd..<answerEnd where !answerIndexes.contains(index) {
                if suppressedBySummary(items[index]) { continue }
                processIndexes.append(index)
            }

            let startSeq: Int
            let endSeq: Int
            if !summariesForTurn.isEmpty {
                // 概要模式：过程的起点在概要里（可能早于第一段中间讲话），
                // 终点取到这一轮的边界，裁剪时不会把一轮切成"没有轮次行的回答"。
                let processStart = min(
                    processIndexes.first.map { items[$0].seq } ?? Int.max,
                    summariesForTurn.first?.startSeq ?? Int.max)
                startSeq = processStart == Int.max ? items[segment.start].seq : processStart
                endSeq = max(items[segment.end].seq,
                             summariesForTurn.map(\.endSeq).max() ?? items[segment.end].seq)
            } else {
                startSeq = processIndexes.first.map { items[$0].seq } ?? items[segment.start].seq
                endSeq = processIndexes.last.map { items[$0].seq } ?? items[segment.end].seq
            }
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
                    activityCounts: counts.activities,
                    steps: [])
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

            // 概要 v2 的分组：每个 wire 分组一条分组行，组内步骤变成**元数据行**。
            // 键与 v1 的行分组同一套格式（轮次 + 起始 seq），状态与折叠身份在
            // 重折前后都稳定。
            for summary in summariesForTurn {
                for wireGroup in summary.groups {
                    let groupKey: String
                    if inferredTurn > 0 {
                        groupKey = "process-group:\(inferredTurn):\(wireGroup.startSeq)"
                    } else {
                        groupKey = "process-group:seq:\(wireGroup.startSeq)"
                    }
                    let steps = wireGroup.steps.map { step in
                        // 轮次已经结束（完成/取消/中断）却还标着 running 的步骤，
                        // 就是"没回来的那个工具"：不能再当成在跑——否则分组行会被
                        // 固定成「正在分析请求」，取消之后也永远不回落。
                        let status: FoldSummaryV2.StepStatus =
                            (!isRunning && step.status == .running) ? .error : step.status
                        return TimelineProcessStep(
                            id: "process-step:\(groupKey):\(step.seq)-\(step.kind.rawValue)",
                            groupKey: groupKey,
                            turn: inferredTurn,
                            seq: step.seq,
                            kind: step.kind,
                            name: step.name,
                            preview: step.preview,
                            status: status,
                            resultSeq: step.resultSeq,
                            bytes: step.bytes)
                    }
                    let group = Group(
                        key: groupKey,
                        turnKey: key,
                        indexes: [],
                        startSeq: wireGroup.startSeq,
                        endSeq: wireGroup.endSeq,
                        toolCount: wireGroup.toolCount,
                        reasoningCount: wireGroup.reasoningCount,
                        subagentCount: wireGroup.subagentCount,
                        activityCounts: wireGroup.activities,
                        steps: steps)
                    groups.append(group)
                    allGroups.append(group)
                }
            }
            // 组的显示顺序 = seq 顺序（行分组与概要分组混在同一轮时也成立），
            // 「最后一条是运行中的实时行」这类判定就按这个序。
            groups.sort { $0.startSeq < $1.startSeq }

            let counts = Self.counts(indexes: processIndexes, items: items)
            let interleaved = segment.hasInterleavedInput || leading.count > 1
            let isPartial = leading.isEmpty || (segment.dividerIndex == nil && !isRunning)
            // 连接器预折摘要（`isPrefetched`）是这一轮**全部**过程的计数来源：
            // 明细可能还没下发，按行数会漏计；明细已下发时按行再数一遍又会重复。
            // 所以只要存在摘要，就用摘要的计数与用时，折叠表头与近期轮次同一样式。
            var prefetchedTools = 0, prefetchedReasoning = 0, prefetchedMessages = 0
            var prefetchedSubagents = 0
            var prefetchedDuration: TimeInterval?
            var prefetchedEndReason: String?
            var prefetchedStart: Int?
            var prefetchedEnd: Int?
            var hasPrefetchedSummary = false
            for index in processIndexes {
                guard case .processHeader(let header) = items[index].kind, header.isPrefetched else { continue }
                hasPrefetchedSummary = true
                prefetchedTools += header.toolCount
                prefetchedReasoning += header.reasoningCount
                prefetchedMessages += header.messageCount
                prefetchedSubagents += header.subagentCount
                if prefetchedDuration == nil { prefetchedDuration = header.duration }
                if prefetchedEndReason == nil { prefetchedEndReason = header.endReason }
                prefetchedStart = min(prefetchedStart ?? header.startSeq, header.startSeq)
                prefetchedEnd = max(prefetchedEnd ?? header.endSeq, header.endSeq)
            }
            // 概要 v2 的计数：步骤元数据是这一轮过程**唯一**的计数来源（过程行
            // 没有下发）。所以有概要时只认概要，不再把行数加一遍。
            let summaryTools = summariesForTurn.reduce(0) { $0 + $1.toolCount }
            let summaryReasoning = summariesForTurn.reduce(0) { $0 + $1.reasoningCount }
            let summarySubagents = summariesForTurn.reduce(0) { $0 + $1.subagentCount }
            let summaryDuration = summariesForTurn.compactMap(\.duration).first
            let summaryEndReason = summariesForTurn.compactMap(\.endReason).first
            var summaryActivities: [TimelineProcessActivity: Int] = [:]
            for summary in summariesForTurn {
                for (activity, count) in summary.groupedActivities {
                    summaryActivities[activity, default: 0] += count
                }
            }
            let hasSummaryV2 = !summariesForTurn.isEmpty
            // 折叠的判据只看"这一轮是否已结束、是否有过程、是否可以隐藏细节"。
            // 缺失区间与中途输入不再取消整轮折叠；摘要也不再让整轮铺开——
            // 概要本身就代表"这一段已完成"，即使窗口里没有结束分隔线也按已完成折叠。
            let foldable = Self.isFoldable(
                hasDivider: segment.hasDivider || hasPrefetchedSummary || hasSummaryV2,
                isRunning: isRunning,
                hasProcessRows: !processIndexes.isEmpty || !groups.isEmpty)

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
                endReason: summaryEndReason ?? prefetchedEndReason ?? segment.endReason,
                duration: summaryDuration ?? prefetchedDuration ?? segment.duration,
                // 计数 = 可见明细行的计数 + 摘要替它隐藏的那一段的计数。v1 的预折
                // 摘要被明细替换后（展开时吸收原事件），两者此消彼长、总数不变；
                // v2 的过程行从来不下发，所以只认概要里的计数。
                toolCount: hasSummaryV2 ? summaryTools : counts.tools + prefetchedTools,
                reasoningCount: hasSummaryV2 ? summaryReasoning : counts.reasoning + prefetchedReasoning,
                messageCount: counts.messages + prefetchedMessages,
                subagentCount: hasSummaryV2 ? summarySubagents : counts.subagents + prefetchedSubagents,
                activityCounts: hasSummaryV2 ? summaryActivities : counts.activities,
                startSeq: hasSummaryV2 ? startSeq
                    : (hasPrefetchedSummary ? (prefetchedStart ?? startSeq) : startSeq),
                endSeq: hasSummaryV2 ? endSeq
                    : (hasPrefetchedSummary ? (prefetchedEnd ?? endSeq) : endSeq),
                summaries: summariesForTurn)
            turns.append(turn)

            for index in range {
                rowTurnKey[items[index].id] = key
            }
            for group in groups {
                for index in group.indexes {
                    rowGroupKey[items[index].id] = group.key
                }
                guard group.isFromSummary else { continue }
                // 概要分组与步骤行不是时间线里的行，但读者可能停在它们上面
                //（`readerTopRowID` 来自列表宿主），所以身份映射要一并登记。
                rowTurnKey[group.key] = key
                rowGroupKey[group.key] = group.key
                for step in group.steps {
                    rowTurnKey[step.id] = key
                    rowGroupKey[step.id] = group.key
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
        var processIDs = Set(turns.flatMap { turn in
            turn.processIndexes.map { items[$0].id }
        })
        for turn in turns {
            for group in turn.groups where group.isFromSummary {
                processIDs.insert(group.key)
                for step in group.steps { processIDs.insert(step.id) }
            }
        }
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

import Foundation

/// One renderable row of a chat transcript.
public struct TimelineItem: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// A message from the human.
        ///
        /// `isPending` is true for the queued echo of a message the host has
        /// accepted but not yet promoted into the transcript.
        case userMessage(
            text: String,
            images: [ContentBlock.ImageAttachment],
            isSteering: Bool,
            isPending: Bool,
            isAgentSent: Bool
        )
        /// Assistant prose.
        case assistantText(text: String)
        /// The model's thinking, rendered collapsed.
        case reasoning(text: String)
        /// One tool invocation, with its result once it arrives.
        case toolCall(ToolInvocation)
        /// A structural marker worth surfacing: an interruption, a compaction,
        /// a failed turn.
        case notice(text: String, isError: Bool)
        /// The end of one turn, so the transcript shows where the agent stopped.
        case turnDivider(turn: Int, reason: String, duration: TimeInterval?)
        /// An event this build does not render, kept so nothing is silently lost.
        case unknown(type: String)
        /// 缺口占位行（spec 009「缺口行的生命周期」/ tasks T014）：两段已加载
        /// 区间之间、或窗口顶端之上的未水合范围。固定高度，身份 `gap:<start>-<end>`
        /// 由区间集派生；补齐时整行被数据行原子替换，不原地变高。
        case gap(start: Int, end: Int, status: GapStatus)
        /// 过程节点（spec 033）：显示投影插入的一行摘要，代表一轮或一轮内的
        /// 一段连续过程。**不是日志事件折出来的行**，只由 `DSHChatDomain` 的
        /// `TranscriptProcessFold` 产生；原始过程行仍在时间线里。
        case processHeader(TimelineProcessHeader)
        /// 概要 v2 的一行**步骤元数据**：名称、参数预览、状态、结果字节数，
        /// 没有正文。同样只由投影产生（`TranscriptProcessFold`）；概要模式下
        /// 过程正文根本没有下发，所以这里不会出现伪造的 tool/result 行。
        case processStep(TimelineProcessStep)
        /// 末尾的运行行（`深度求索中，用时 … ···`）。显示投影生成的唯一一行，
        /// 两个列表宿主都渲染它；不参与缓存/裁剪/搜索。
        case runningLine(TimelineRunningLine)

        /// 数据行（记录折叠而来），与缺口占位行相对。
        /// 窗口边界、命中归属等"内容覆盖"判定只认数据行（009 场景⑥）。
        public var isContentRow: Bool {
            if case .gap = self { return false }
            return true
        }

        /// 该缺口是否覆盖 `seq`（数据行恒 false）。命中归属判定用它识别
        /// 「数据还没到」：落在缺口覆盖区间里的 seq 不能解析成落地行。
        public func covers(seq: Int) -> Bool {
            if case .gap(let start, let end, _) = self { return seq >= start && seq <= end }
            return false
        }
    }

    /// 缺口行的三态（与 SessionPipeline.GapRow.Status 一一对应）。
    public enum GapStatus: Sendable, Equatable {
        /// 正在拉取（spinner）。
        case loading
        /// 连续失败到上限（3 次），只能由读者点击重试。
        case failed(retryable: Bool)
        /// 已到最早（hasMore=false 或 clamped），永不显示成网络失败。
        case exhausted
    }

    public let id: String
    public var kind: Kind
    /// The journal sequence that produced this row, used for ordering.
    public let seq: Int
    /// 该行李自仍在流式的 provisional 记录（spec 009 tasks T020）：渲染降级为
    /// 纯文本（代码块不高亮），消息结束后提交记录覆盖，标记消失并做一次完整解析。
    public var isStreaming: Bool = false
    /// 009 上行状态（T022）：这条用户消息没发出去（发送失败/重启恢复未发出），
    /// 行尾给「发送失败，点击重发」。只由 `markSendStates` 回标，折叠本身不产生。
    public var sendFailed: Bool = false
    /// 已受理、但确认帧永远没来（宿主撤单、轮次以错误结束）。
    /// 它不是「没发出去」（不能直接重发），也不是「等待开始」（宿主不会开始它了），
    /// 行尾给「已发送，未确认，点击核对」：核对走一次服务端查重，再决定是否重发。
    /// 只由 `markSendStates` 回标。
    public var sendUnconfirmed: Bool = false
    /// 长回答拆行后的父行 id（普通行 nil）。复制/选区/搜索仍归到父消息。
    public var parentID: String? = nil
    /// 拆行时保留整条回答的全文，供复制与选区使用；普通行 nil。
    public var fullText: String? = nil
    /// 这一行对应事件的宿主时间（`SessionEvent.time`）。用户输入与正式回答
    /// 用它显示 `HH:mm`；缺口/过程/运行行没有。
    public var at: Date? = nil

    /// 这一行是**还没进入会话历史**的上行消息。
    ///
    /// 三种形态：刚发出等确认（`isPending`）、确认没来（`sendUnconfirmed`）、
    /// 没发出去（`sendFailed`）。它们的 `seq` 是 `MessagePipeline` 的合成排序键
    /// （`Int.max` 起递减），不是会话里的位置，因此不能当搜索命中/跳转目标/对外
    /// 序号使用（见 `MessageStore.sessionContent()` 与 `TranscriptSearch.searchable`）。
    /// 长回答拆行用的显示副本：换 id、换片段正文，保留父消息与全文。
    public func asAssistantFragment(id: String, text: String,
                                    parentID: String, fullText: String) -> TimelineItem {
        TimelineItem(id: id, kind: .assistantText(text: text), seq: seq,
                     isStreaming: false, sendFailed: sendFailed,
                     sendUnconfirmed: sendUnconfirmed,
                     parentID: parentID, fullText: fullText, at: at)
    }

    public var isUnsavedInput: Bool {
        guard case .userMessage(_, _, _, let isPending, _) = kind else { return false }
        return isPending || sendFailed || sendUnconfirmed
    }
}

/// One tool invocation and its outcome.
public struct ToolInvocation: Sendable {
    public var callId: String
    public var name: String
    /// The model's raw JSON argument string.
    public var arguments: String
    /// A short human-readable form of `arguments`.
    public var summary: String
    public var resultBlocks: [ContentBlock]
    public var isError: Bool
    /// True until the matching result arrives.
    public var isRunning: Bool
    public var turn: Int
    public var step: Int

    /// The result flattened to plain text, for search and for a compact preview.
    public var resultText: String {
        resultBlocks.compactMap { block -> String? in
            switch block {
            case .text(let text): return text
            case .reasoning(let text): return text
            case .unknown(_, let raw): return raw["text"]?.stringValue
            default: return nil
            }
        }
        .joined()
    }
}

/// In-flight assistant output that has not been committed to the journal yet.
public struct StreamingAttempt: Sendable {
    public var attemptId: String
    public var turn: Int
    public var step: Int
    public var text: String = ""
    public var reasoning: String = ""

    public var isEmpty: Bool { text.isEmpty && reasoning.isEmpty }
}

/// Folds the session journal and the live assistant stream into a transcript.
///
/// The desktop client keeps a much richer conversation graph; a phone needs a
/// single flat, append-mostly list that renders fast. This type is that fold,
/// kept in the kit rather than in the view layer so it can be tested against
/// captured traffic without a running host.
public struct ChatTimeline: Sendable {
    /// What changed, so the view can avoid rebuilding or autoscrolling needlessly.
    public enum Change: Sendable, Equatable {
        case none
        /// A row was appended at the end.
        case appended
        /// An existing row changed at this index.
        case updated(Int)
        /// The transcript was replaced wholesale.
        case reloaded
    }

    /// internal(set)：同模块扩展文件（Timeline+Streaming 的单行增量更新）要改行。
    public internal(set) var items: [TimelineItem] = []

    /// In-flight assistant output, rendered as a trailing bubble.
    public private(set) var streaming: StreamingAttempt?

    /// The newest turn and step observed, for the activity header.
    public private(set) var currentTurn: Int = 0
    public private(set) var currentStep: Int = 0

    /// Whether the transcript ends with a turn that never reported completion.
    public private(set) var isTurnOpen: Bool = false

    /// 概要 v2（`+link/fold` 的 `v: 2`）解码出的轮次元数据，按 `startSeq` 升序。
    ///
    /// 它**不是行**：概要模式下过程正文没有下发，轮次行、分组行与步骤元数据行
    /// 都由 `TranscriptProcessFold` 从这份数据投影出来。一份概要一行都不占，
    /// 所以这里单独持有，而不是塞成一条 `processHeader`。
    ///
    /// 生命周期与行一致：`reset` 清空中重新折叠；旧页 `prepend` 时并入并保序；
    /// 窗口裁剪时由 `pruneFoldSummaries(before:)` 一并丢掉。
    public private(set) var foldSummaries: [FoldSummaryV2] = []

    /// Folds the last known total usage for the session.
    public private(set) var lastUsage: TokenUsageProjection?

    /// When each open turn began, so its duration can be reported when it ends.
    private var turnStartedAt: [Int: Date] = [:]

    /// 正在跑的那一轮的开始时刻（宿主 `turn/start` 的时间）。运行行的计时起点用它，
    /// 不拿“手机观察到的时间”代替；切后台/重开也还是同一个值。
    public var openTurnStartedAt: Date? {
        guard isTurnOpen else { return nil }
        if let start = turnStartedAt[currentTurn] { return start }
        // 起点不在本地窗口：运行中的概要带着轮次的 startedAt（宿主时间），用它兜底。
        // 同一轮可能被讲话切成多段，每段同值；取最后一条有值的即可。
        let fromSummary = foldSummaries.last {
            $0.turn == currentTurn && $0.startedAt != nil
        }
        return fromSummary?.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// The most recent completed turn, for the transient "done" indicator.
    public private(set) var lastCompletion: Completion?

    public struct Completion: Sendable, Equatable {
        public let turn: Int
        public let reason: String
        public let duration: TimeInterval?
        public let at: Date
    }

    private var toolIndex: [String: Int] = [:]

    public init() {}

    // MARK: - Bulk load

    /// Replaces the transcript with one history snapshot.
    /// 整份替换（冷启动落盘、re-base 用）。返回的 `Change` 目前**没有任何调用方**使用——
    /// 这些场景都是"整屏重画"，不需要增量差异；标注 `@discardableResult` 说明这一点，
    /// 顺带消掉 App 侧三处"返回值被丢弃"的编译告警。
    @discardableResult
    public mutating func reset(with records: [SessionRecord]) -> Change {
        // `isTurnOpen` 是"这一轮是不是还开着"的事实，不该被 reset 顺手丢掉再靠
        // 最后一条记录推断：窗口裁到轮次中间时（turn/start 在窗口外）推断会得到
        // "已结束"，运行行与计时随之消失。这里显式保存，回放没有轮次边界时恢复。
        let previousTurnOpen = isTurnOpen
        let settlesTurn = records.contains { record in
            record.event.type == "turn/start" || record.event.type == "turn/end"
        }
        items.removeAll(keepingCapacity: true)
        toolIndex.removeAll(keepingCapacity: true)
        foldSummaries.removeAll(keepingCapacity: true)
        streaming = nil
        currentTurn = 0
        currentStep = 0
        isTurnOpen = false

        for record in records {
            applyEvent(record.event)
        }
        // A snapshot is history, not live output: nothing is still running.
        settleRunningTools()
        if !settlesTurn { isTurnOpen = previousTurnOpen }
        return .reloaded
    }

    /// Folds a follow snapshot into a transcript that already has content.
    ///
    /// Re-opening a session returns a snapshot of the tail of the journal. When
    /// the reader had already loaded older pages, replacing the transcript with
    /// that tail would throw their history away — and because the content
    /// shrinks under a lazy stack, it could also leave the view scrolled past
    /// the end with nothing to render. Merging updates the rows the snapshot
    /// covers and leaves everything else in place.
    @discardableResult
    public mutating func merge(snapshot records: [SessionRecord]) -> Change {
        guard !records.isEmpty else { return .none }
        for record in records {
            applyEvent(record.event)
        }
        reindexTools()
        return .reloaded
    }

    /// Prepends an older page, preserving order and identity.
    public mutating func prepend(older records: [SessionRecord]) -> Change {
        guard !records.isEmpty else { return .none }
        var scratch = ChatTimeline()
        for record in records { scratch.applyEvent(record.event) }
        scratch.settleRunningTools()

        // Re-key the older rows so ids stay unique against the existing ones.
        let existing = Set(items.map(\.id))
        let older = scratch.items.filter { !existing.contains($0.id) }
        // 旧页里的概要必须一起进来（它们是轮次行/分组行的唯一来源），
        // 否则上翻一页之后，那一轮的折叠会凭空少掉过程。
        guard !older.isEmpty || !scratch.foldSummaries.isEmpty else { return .none }
        if !older.isEmpty {
            items.insert(contentsOf: older, at: 0)
        }
        for summary in scratch.foldSummaries {
            _ = upsertFoldSummary(summary)
        }
        reindexTools()
        return .reloaded
    }

    // MARK: - Live events

    /// Applies one durable journal event.
    @discardableResult
    public mutating func apply(_ event: SessionEvent) -> Change {
        let change = applyEvent(event)
        return change
    }

    /// Applies one assistant streaming frame.
    @discardableResult
    public mutating func apply(_ frame: AssistantStreamFrame) -> Change {
        switch frame {
        case .start(let attemptId, _, let turn, let step, _):
            streaming = StreamingAttempt(attemptId: attemptId, turn: turn, step: step)
            currentTurn = max(currentTurn, turn)
            currentStep = step
            isTurnOpen = true
            return .appended

        case .chunk(_, _, _, _, let chunk):
            guard streaming != nil else { return .none }
            switch chunk {
            case .textDelta(let text):
                streaming?.text += text
            case .reasoningDelta(let text):
                streaming?.reasoning += text
            case .toolCallDelta, .other:
                // Tool-call deltas surface as a committed `tool/call` event;
                // partial arguments are not worth a provisional card.
                return .none
            }
            return .updated(items.count)

        case .end:
            // The committed `assistant/message` event carries the final text, so
            // the provisional bubble is dropped rather than reconciled.
            streaming = nil
            return .none

        case .unknown:
            return .none
        }
    }

    /// Records the session's current token usage.
    public mutating func record(usage: TokenUsageProjection?) {
        lastUsage = usage
    }

    /// Drops any in-flight assistant output.
    ///
    /// A cached transcript is a snapshot of settled history, so the provisional
    /// streaming bubble belongs to a stream that is no longer open and would
    /// otherwise reappear as a stale fragment.
    public mutating func clearStreaming() {
        streaming = nil
    }

    /// Echoes a prompt the user just submitted, before the host confirms it.
    ///
    /// The identity is derived from the request id the host stores on the
    /// durable message's source, so the authoritative event *replaces* this
    /// row instead of appearing beneath it. Without that, every sent message
    /// would briefly render twice.
    @discardableResult
    public mutating func echoUserPrompt(
        requestId: String,
        text: String,
        images: [ContentBlock.ImageAttachment] = []
    ) -> Change {
        append(
            kind: .userMessage(
                text: text,
                images: images,
                isSteering: false,
                isPending: true,
                isAgentSent: false
            ),
            seq: Int.max - 1,
            identity: "user-\(requestId)"
        )
    }

    // MARK: - Internals

    /// 把连接器折好的轮次摘要插成一行过程节点（`isPrefetched`）。
    private mutating func applyFoldSummary(_ event: SessionEvent) -> Change {
        let data = event.data
        let turn = data["turn"]?.intValue ?? 0
        let startSeq = data["startSeq"]?.intValue ?? event.seq
        let endSeq = data["endSeq"]?.intValue ?? event.seq
        let durationMs = data["durationMs"]?.doubleValue
        let header = TimelineProcessHeader(
            id: "fold-\(turn)-\(startSeq)",
            scope: .turn,
            turn: turn,
            startSeq: startSeq,
            endSeq: endSeq,
            toolCount: data["toolCount"]?.intValue ?? 0,
            reasoningCount: data["reasoningCount"]?.intValue ?? 0,
            messageCount: data["messageCount"]?.intValue ?? 0,
            subagentCount: data["subagentCount"]?.intValue ?? 0,
            activityCounts: [:],
            isExpanded: false,
            isFoldable: true,
            isRunning: false,
            endReason: data["endReason"]?.stringValue,
            duration: durationMs.map { $0 / 1000 },
            hasFailure: false,
            isPartial: false,
            isPrefetched: true
        )
        return append(kind: .processHeader(header), seq: event.seq, identity: header.id)
    }

    /// 记下一条 v2 概要。同一段（`startSeq`）重放时替换而不是追加：窗口重读、
    /// 运行中刷新都会再发一次同一条，重复追加会让轮次行与分组行各出现两遍。
    private mutating func upsertFoldSummary(_ summary: FoldSummaryV2) -> Bool {
        if let index = foldSummaries.firstIndex(where: { $0.startSeq == summary.startSeq }) {
            guard foldSummaries[index] != summary else { return false }
            foldSummaries[index] = summary
            return true
        }
        let insertAt = foldSummaries.firstIndex { $0.startSeq > summary.startSeq }
            ?? foldSummaries.count
        foldSummaries.insert(summary, at: insertAt)
        return true
    }

    /// 窗口裁剪：起点在裁剪线之前的概要随行一起丢掉，不留没有行的分组键。
    ///
    /// 判据用 `startSeq`（概要覆盖的整段起点）：裁剪线是按轮次起点对齐的，
    /// 留着的那个轮次的概要不小于它，更早的整段都在它之前。
    public mutating func pruneFoldSummaries(before seq: Int) {
        foldSummaries.removeAll { $0.startSeq < seq }
    }


    private mutating func applyEvent(_ event: SessionEvent) -> Change {
        // 连接器折好下发的轮次摘要（`history-fold-summary` / `history-fold-summary-v2`）。
        // 两条路按记录里的 `v` 分：v2 是**整轮的元数据**（分组 + 步骤），解码成独立
        // 模型 `FoldSummaryV2` 存进 `foldSummaries`，一行都不占；v1 仍是老样子，
        // 插一行 `processHeader`，点开时由上层回取详情。
        if event.type == FoldSummaryV2.recordType {
            if let summary = FoldSummaryV2.decode(event) {
                return upsertFoldSummary(summary) ? .reloaded : .none
            }
            return applyFoldSummary(event)
        }
        switch ChatEventDecoder.decode(event) {
        case .userMessage(let message):
            // The host journals plugin and runtime-context messages under the
            // same event type. Only what the human typed belongs in a chat.
            guard message.isFromHuman else { return .none }

            let text = Self.joinedText(message.content)
            let images = message.content.compactMap { block -> ContentBlock.ImageAttachment? in
                if case .image(let attachment) = block { return attachment }
                return nil
            }
            guard !text.isEmpty || !images.isEmpty else { return .none }
            // Prefer the request id: it is what both the local echo and the
            // queued splice were keyed by, so this durable row replaces them
            // rather than appearing beside them.
            let identity = message.rpcId.map { "user-\($0)" } ?? "user-\(message.id)"
            return append(
                kind: .userMessage(
                    text: text,
                    images: images,
                    isSteering: message.isSteering,
                    isPending: false,
                    isAgentSent: Self.isAgentSent(rpcId: message.rpcId, images: images)
                ),
                seq: event.seq,
                identity: identity,
                at: event.date
            )

        case .assistantMessage(let message):
            // The committed message supersedes any provisional streaming bubble.
            streaming = nil
            // 009 T020 / 011：只有**本机** provisional 记录折出的行标 isStreaming
            // （渲染降级为纯文本），提交记录覆盖时标记消失。
            // 判据是本机私有标记，不是宿主字段：宿主的 `data.stream` 是原始模型块日志，
            // 拿它当判据会让每条提交记录都降级（本次故障的根因）。
            let provisional = message.isProvisional
            var change: Change = .none
            for (index, block) in message.content.enumerated() {
                switch block {
                case .text(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    change = append(
                        kind: .assistantText(text: text),
                        seq: event.seq,
                        identity: "assistant-\(event.seq)-\(index)",
                        streaming: provisional,
                        at: event.date
                    )
                case .reasoning(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    change = append(
                        kind: .reasoning(text: text),
                        seq: event.seq,
                        identity: "reasoning-\(event.seq)-\(index)",
                        streaming: provisional
                    )
                case .toolCall(let id, let name, let arguments):
                    let carried = carriedResult(for: id)
                    change = append(
                        kind: .toolCall(
                            ToolInvocation(
                                callId: id,
                                name: name,
                                arguments: arguments,
                                summary: Self.summarize(name: name, arguments: arguments),
                                resultBlocks: carried?.resultBlocks ?? [],
                                isError: carried?.isError ?? false,
                                isRunning: carried?.isRunning ?? true,
                                turn: message.turn,
                                step: message.step
                            )
                        ),
                        seq: event.seq,
                        identity: "tool-\(id.isEmpty ? "\(event.seq)-\(index)" : id)"
                    )
                    if !id.isEmpty, case .appended = change {
                        toolIndex[id] = items.count - 1
                    }
                case .image(let attachment):
                    // 概要 v2 会把助手消息里的 image 块原样带下来（只有 attachment
                    // 元数据，没有字节）。图片是正式回答的一部分，不能因为折叠就丢：
                    // 沿用「agent 发来的图片」那一种行（空正文 + 图片、靠 agent 一侧），
                    // 这样收起态它仍算回答内容。`file` 块暂时没有行模型（UI 侧没有
                    // 文件卡），元数据留在记录里，不在这里伪造一行。
                    change = append(
                        kind: .userMessage(
                            text: "",
                            images: [attachment],
                            isSteering: false,
                            isPending: false,
                            isAgentSent: true
                        ),
                        seq: event.seq,
                        identity: "assistant-image-\(event.seq)-\(index)",
                        at: event.date
                    )
                default:
                    continue
                }
            }
            return change

        case .toolCall(let call):
            let invocation = ToolInvocation(
                callId: call.callId,
                name: call.name,
                arguments: call.arguments,
                summary: call.summary,
                resultBlocks: carriedResult(for: call.callId)?.resultBlocks ?? [],
                isError: carriedResult(for: call.callId)?.isError ?? false,
                isRunning: carriedResult(for: call.callId)?.isRunning ?? true,
                turn: call.turn,
                step: call.step
            )
            let change = append(
                kind: .toolCall(invocation),
                seq: event.seq,
                identity: "tool-\(call.callId.isEmpty ? "\(event.seq)-call" : call.callId)"
            )
            if !call.callId.isEmpty, case .appended = change {
                toolIndex[call.callId] = items.count - 1
            }
            return change

        case .toolResult(let result):
            guard let index = toolIndex[result.callId] else {
                // A result without a matching call: its call is outside the
                // loaded window (a trimmed history page) — or, more often now,
                // the host re-emitted a **pruned** result during compaction.
                // 2026-09-24: that path used to become a `.notice`, and a notice
                // has no cap and no fold, so a 703-line file dump filled the
                // whole phone screen and could not be collapsed. Render it as
                // the same collapsed card every other tool result gets, keyed by
                // its call id so a real call merges into it if a page loads it.
                let text = Self.joinedText(result.content)
                guard !text.isEmpty else { return .none }
                let invocation = ToolInvocation(
                    callId: result.callId,
                    name: Self.orphanToolName(result),
                    arguments: "",
                    summary: result.metaLabel ?? text.split(separator: "\n").first.map(String.init) ?? "",
                    resultBlocks: result.content,
                    isError: result.isError,
                    isRunning: false,
                    turn: result.turn,
                    step: result.step
                )
                let identity = result.callId.isEmpty ? "orphan-result-\(event.seq)" : "tool-\(result.callId)"
                let change = append(kind: .toolCall(invocation), seq: event.seq, identity: identity)
                if !result.callId.isEmpty, case .appended = change {
                    toolIndex[result.callId] = items.count - 1
                }
                return change
            }
            guard case .toolCall(var invocation) = items[index].kind else { return .none }
            invocation.resultBlocks = result.content
            invocation.isError = result.isError
            invocation.isRunning = false
            items[index].kind = .toolCall(invocation)
            return .updated(index)

        case .turnStart(let turn):
            currentTurn = max(currentTurn, turn)
            isTurnOpen = true
            turnStartedAt[turn] = event.date ?? Date()
            return .none

        case .turnEnd(let turn, let reason):
            currentTurn = max(currentTurn, turn)
            isTurnOpen = false
            streaming = nil
            settleRunningTools()

            let started = turnStartedAt.removeValue(forKey: turn)
            let duration = started.map { (event.date ?? Date()).timeIntervalSince($0) }
            lastCompletion = Completion(
                turn: turn,
                reason: reason,
                duration: duration,
                at: event.date ?? Date()
            )

            // Every turn ends with a visible marker. Without one, a finished
            // run is indistinguishable from a stalled one — which is exactly
            // how a stuck "stop" button reads.
            return append(
                kind: .turnDivider(
                    turn: turn,
                    reason: reason,
                    duration: duration
                ),
                seq: event.seq,
                identity: "turn-end-\(turn)"
            )

        case .stepStart(_, let step):
            currentStep = step
            return .none

        case .stepEnd:
            return .none

        case .inboxSpliced(let spliced):
            // The splice that withdraws a queued item carries no content.
            guard !spliced.isRemoval else { return .none }

            // Only what a person wrote belongs in the conversation. The host
            // also splices its own notices here — approval-policy changes,
            // background-job completions — and showing them as user bubbles is
            // what made a single prompt look like it had been sent twice.
            guard spliced.isFromHuman else { return .none }

            let text = Self.joinedText(spliced.inserted)
            let images = Self.joinedImages(spliced.inserted)
            // A spliced message may carry only a picture — an image the agent
            // sent with no caption. Requiring text dropped those entirely.
            guard !text.isEmpty || !images.isEmpty else { return .none }

            // Keyed by the request id, so the durable `user/message` that the
            // queue later promotes replaces this row. Keying it by sequence
            // number instead — as this used to — is what made every message
            // sent from the phone appear twice.
            let identity = spliced.rpcId.map { "user-\($0)" } ?? "inbox-\(event.seq)"
            // 概要 v2 的页里，同一条消息可能出现两次：`user/message`（落定）与
            // `agent/inbox/spliced`（本机回声）。回声只是乐观行，已落定的那一行
            // 永远是正本——晚到的回声不能把确认过的正文/图片覆盖成它自己那份
            //（实测页内两条人发消息各带一条回声；覆盖会让图文消失或重复）。
            if let index = items.firstIndex(where: { $0.id == identity }),
               case .userMessage(_, _, _, let isPending, _) = items[index].kind,
               !isPending {
                return .none
            }
            return append(
                kind: .userMessage(
                    text: text,
                    images: images,
                    isSteering: spliced.target == "next-step",
                    isPending: true,
                    isAgentSent: Self.isAgentSent(rpcId: spliced.rpcId, images: images)
                ),
                seq: event.seq,
                identity: identity,
                at: event.date
            )

        case .titleChanged:
            return .none

        case .other(let type, let seq, _, let data):
            // Compaction, approvals, and goals are shown in dedicated panels;
            // everything else is retained so it can be surfaced later.
            if let notice = Self.notice(for: type, data: data) {
                return append(kind: notice, seq: seq, identity: "\(type)-\(seq)")
            }
            return .none
        }
    }

    private mutating func append(
        kind: TimelineItem.Kind, seq: Int, identity: String, streaming: Bool = false,
        at: Date? = nil
    ) -> Change {
        let item = TimelineItem(id: identity, kind: kind, seq: seq, isStreaming: streaming, at: at)
        // Ids are derived from the event identity so a re-delivered frame
        // updates the existing row instead of duplicating it.
        //
        // That only works while the identity is a pure function of the durable
        // record — its journal sequence, its request id, its call id. An
        // identity that also depends on fold-local state (a running counter,
        // say) is minted afresh every time the same record is folded again, and
        // re-entering a session folds its whole tail a second time. That is how
        // one reply came to be rendered five times: once per visit, with the
        // turn divider — keyed by its turn number — staying correctly single.
        if let index = items.firstIndex(where: { $0.id == identity }) {
            items[index] = item
            return .updated(index)
        }
        items.append(item)
        return .appended
    }

    /// The row a call would replace, so its result is not thrown away.
    ///
    /// Order is not guaranteed on the wire: the host re-emits a pruned result
    /// during compaction (a card gets built from the result alone), and a page
    /// loaded later can then bring the call that produced it. Without this the
    /// call's arrival would replace the card with an empty running one and the
    /// output would vanish.
    private func carriedResult(for callId: String) -> ToolInvocation? {
        guard !callId.isEmpty, let index = toolIndex[callId] else { return nil }
        guard case .toolCall(let existing) = items[index].kind else { return nil }
        return existing
    }

    /// Marks every tool row as finished, used when history is authoritative.
    private mutating func settleRunningTools() {
        for index in items.indices {
            guard case .toolCall(var invocation) = items[index].kind, invocation.isRunning else { continue }
            // A call with no result in a settled history was interrupted.
            invocation.isRunning = false
            items[index].kind = .toolCall(invocation)
        }
    }

    /// Drops the oldest rows to keep the in-memory window inside its budget.
    ///
    /// Only the **rows** go: the host's "is there older history" is untouched, and
    /// the records themselves stay in the local store, so scrolling back up reads
    /// them from disk instead of the network (spec 007 FR-035). Returns the number
    /// of rows actually dropped.
    @discardableResult
    public mutating func dropOldestRows(_ count: Int) -> Int {
        guard count > 0, !items.isEmpty else { return 0 }
        let dropped = min(count, items.count)
        items.removeFirst(dropped)
        reindexTools()
        return dropped
    }

    /// The seq of the topmost row, i.e. how far back the reader can scroll without
    /// a local read-back.
    public var firstSeq: Int? { items.first?.seq }

    /// 窗口里第一条**数据行**的 seq（跳过缺口占位行）。
    /// 顶部合成缺口行 `gap:0-0` 的 seq 是 0——拿 firstSeq 当窗口下界会让
    /// 「命中在窗口之外」的判定永远为假（009 场景⑥回归：rebase 永不触发）。
    public var firstContentSeq: Int? { items.first(where: { $0.kind.isContentRow })?.seq }

    // MARK: - 缺口行（spec 009 / tasks T013/T014）

    /// 造一行缺口占位项：身份 `gap:<start>-<end>`（与区间集派生一致，spec 009
    /// 「缺口行的生命周期」），排序键取 `start`——缺口覆盖的 seq 区间里不存在
    /// 数据行，所以不会与数据行撞键。
    public static func gapItem(start: Int, end: Int, status: TimelineItem.GapStatus) -> TimelineItem {
        TimelineItem(id: "gap:\(start)-\(end)", kind: .gap(start: start, end: end, status: status), seq: start)
    }

    /// 把「在飞」状态接回一棵刚重建的时间线（spec 009 tasks T013）：
    /// 管道快照折叠出的只有下行记录；本地乐观回声（pending 用户消息）与
    /// 流式气泡属于上行/在飞状态，重建时必须原样接回，否则每次快照 diff
    /// 都会把它们抹掉。回声按身份去重——服务端确认回流后同一 id 的正式行
    /// 已在折叠结果里，回声让位。
    public mutating func restoreTransient(streaming: StreamingAttempt?, echoes: [TimelineItem]) {
        self.streaming = streaming
        for echo in echoes where !items.contains(where: { $0.id == echo.id }) {
            items.append(echo)
        }
    }

    /// 009 上行状态回标（T022，spec 场景 11「pending→sent 原地替换」）：
    /// 管道折叠只还原文本，发送状态（pending/failed）由内存层按 seq 回标——
    /// pending 走回声样式（降透明度 + 等待提示），failed 给可点重发标记。
    /// 身份与行位置都不动，只翻状态位。
    public mutating func markSendStates(_ statuses: [Int: MessageSendStatus]) {
        for index in items.indices {
            guard let status = statuses[items[index].seq],
                  case .userMessage(let text, let images, let isSteering, _, let isAgentSent) = items[index].kind
            else { continue }
            // 三态互斥：每写一次状态位就把另外两个清掉。原来 `.sent` 只清 sendFailed，
            // 一旦出现「状态转 sent 但没重折」的路径，行就永远停在「等待开始」。
            let flags: (pending: Bool, failed: Bool, unconfirmed: Bool)
            switch status {
            case .sent: flags = (false, false, false)
            case .pending: flags = (true, false, false)
            case .failed: flags = (false, true, false)
            case .unconfirmed: flags = (false, false, true)
            }
            items[index].kind = .userMessage(
                text: text, images: images, isSteering: isSteering,
                isPending: flags.pending, isAgentSent: isAgentSent)
            items[index].sendFailed = flags.failed
            items[index].sendUnconfirmed = flags.unconfirmed
        }
    }

    /// 用一组新的缺口行替换现有缺口行（数据行不动）。
    ///
    /// 缺口是区间集的**派生量**：每次快照重建后整体重设，身份相同的行被更新
    /// （spinner → 点击重试），消失的行被移除——与 008 宿主「删缺口行 + 插数据行
    /// + 位移修正」一次事务的提交方式对齐（tasks T015）。
    public mutating func setGaps(_ gaps: [TimelineItem]) {
        items.removeAll { item in
            if case .gap = item.kind { return true }
            return false
        }
        for gap in gaps {
            let index = items.firstIndex { $0.seq > gap.seq } ?? items.count
            items.insert(gap, at: index)
        }
    }

    private mutating func reindexTools() {
        toolIndex.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            if case .toolCall(let invocation) = item.kind, !invocation.callId.isEmpty {
                toolIndex[invocation.callId] = index
            }
        }
    }

    // MARK: - Formatting helpers

    /// Prefix marking a prompt as the agent's own rather than the user's.
    ///
    /// A picture can only enter a conversation as a prompt, which the journal
    /// always attributes to the user, so the sender has to ride along with it.
    /// It rides on the request id: the Host stores that verbatim and no client
    /// renders it — unlike the caption (where an invisible character, then a
    /// camera glyph, both proved visible) or the file name (which some clients
    /// label).
    static let agentRequestPrefix = "agent-"

    /// A legacy marker kept only so already-sent images still read correctly.
    private static let legacyAgentImagePrefix = "📷"

    /// True when this message was sent by the agent rather than the user.
    public static func isAgentSent(rpcId: String?, images: [ContentBlock.ImageAttachment]) -> Bool {
        if let rpcId, rpcId.hasPrefix(agentRequestPrefix) { return true }
        return images.contains { ($0.name ?? "").hasPrefix(legacyAgentImagePrefix) }
    }

    /// The attachment name with any legacy marker removed, for display.
    public static func displayName(_ attachment: ContentBlock.ImageAttachment) -> String? {
        guard let name = attachment.name else { return nil }
        guard name.hasPrefix(legacyAgentImagePrefix) else { return name }
        return String(name.dropFirst(legacyAgentImagePrefix.count))
    }

    /// Every image carried by these blocks, in order.
    ///
    /// The splice channel is the only way a picture the agent sends reaches the
    /// transcript, and this used to be discarded on the floor: the row rendered
    /// its caption and silently dropped the picture.
    static func joinedImages(_ blocks: [ContentBlock]) -> [ContentBlock.ImageAttachment] {
        blocks.compactMap { block -> ContentBlock.ImageAttachment? in
            if case .image(let attachment) = block { return attachment }
            return nil
        }
    }

    static func joinedText(_ blocks: [ContentBlock]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .text(let text): return text
            case .unknown(_, let raw): return raw["text"]?.stringValue
            default: return nil
            }
        }
        .joined()
    }

    /// What to call a tool result whose call never loaded.
    ///
    /// The wire carries no tool name on a result, so the label comes from the
    /// metadata the host attaches: a `path` means a file was read or written, a
    /// `url` means a page was fetched, and so on. Anything else is simply "tool
    /// output" — a generic card is still better than a wall of raw text.
    static func orphanToolName(_ result: ChatEvent.ToolResult) -> String {
        switch result.metaKind {
        case "diffs": return "改动"
        case "file": return "文件内容"
        case "web": return "网页内容"
        case "files": return "文件列表"
        case "sources": return "搜索结果"
        default: return "工具输出"
        }
    }

    /// A short label for a tool call, mirroring the desktop client's summaries.
    static func summarize(name: String, arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return "" }

        func first(_ keys: [String]) -> String? {
            for key in keys {
                if let value = args[key]?.stringValue, !value.isEmpty { return value }
            }
            return nil
        }

        switch name {
        case "bash", "shell", "pwsh":
            return first(["command"]) ?? ""
        case "read", "read_file", "str_replace_editor", "edit", "write":
            return first(["path", "file_path"]) ?? ""
        case "glob", "grep", "search":
            return first(["pattern", "query"]) ?? ""
        case "web_search":
            return first(["query"]) ?? ""
        case "web_fetch":
            return first(["url"]) ?? ""
        case "subagent", "task":
            return first(["description", "prompt"]) ?? ""
        case "workflow":
            return first(["name", "description"]) ?? ""
        default:
            return first(["path", "command", "query", "description", "url", "name"]) ?? ""
        }
    }

    /// Turns a non-ordinary turn ending into a human sentence.
    static func describe(turnEndReason reason: String) -> String {
        switch reason {
        case "cancelled", "canceled": return "本轮已取消"
        case "interrupted": return "本轮被中断"
        case "error", "failed": return "本轮出错结束"
        case "max-steps": return "已达步数上限"
        default: return "本轮结束：\(reason)"
        }
    }

    /// Renders the few non-chat events that deserve a transcript row.
    static func notice(for type: String, data: JSONValue) -> TimelineItem.Kind? {
        switch type {
        case "compaction/start":
            return .notice(text: "正在压缩上下文…", isError: false)
        case "compaction/end":
            return .notice(text: "上下文压缩完成", isError: false)
        case "compaction/summary":
            let summary = data["summary"]?.stringValue ?? ""
            return .notice(text: summary.isEmpty ? "上下文已压缩" : summary, isError: false)
        case "agent/error", "error":
            let message = data["message"]?.stringValue ?? "发生错误"
            return .notice(text: message, isError: true)
        default:
            return nil
        }
    }
}

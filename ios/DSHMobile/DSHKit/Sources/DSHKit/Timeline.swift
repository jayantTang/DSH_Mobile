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
    }

    public let id: String
    public var kind: Kind
    /// The journal sequence that produced this row, used for ordering.
    public let seq: Int
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

    public private(set) var items: [TimelineItem] = []

    /// In-flight assistant output, rendered as a trailing bubble.
    public private(set) var streaming: StreamingAttempt?

    /// The newest turn and step observed, for the activity header.
    public private(set) var currentTurn: Int = 0
    public private(set) var currentStep: Int = 0

    /// Whether the transcript ends with a turn that never reported completion.
    public private(set) var isTurnOpen: Bool = false

    /// Folds the last known total usage for the session.
    public private(set) var lastUsage: TokenUsageProjection?

    /// When each open turn began, so its duration can be reported when it ends.
    private var turnStartedAt: [Int: Date] = [:]

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
    public mutating func reset(with records: [SessionRecord]) -> Change {
        items.removeAll(keepingCapacity: true)
        toolIndex.removeAll(keepingCapacity: true)
        streaming = nil
        currentTurn = 0
        currentStep = 0
        isTurnOpen = false

        for record in records {
            applyEvent(record.event)
        }
        // A snapshot is history, not live output: nothing is still running.
        settleRunningTools()
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
        guard !older.isEmpty else { return .none }

        items.insert(contentsOf: older, at: 0)
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

    private mutating func applyEvent(_ event: SessionEvent) -> Change {
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
                identity: identity
            )

        case .assistantMessage(let message):
            // The committed message supersedes any provisional streaming bubble.
            streaming = nil
            var change: Change = .none
            for (index, block) in message.content.enumerated() {
                switch block {
                case .text(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    change = append(
                        kind: .assistantText(text: text),
                        seq: event.seq,
                        identity: "assistant-\(event.seq)-\(index)"
                    )
                case .reasoning(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    change = append(
                        kind: .reasoning(text: text),
                        seq: event.seq,
                        identity: "reasoning-\(event.seq)-\(index)"
                    )
                case .toolCall(let id, let name, let arguments):
                    change = append(
                        kind: .toolCall(
                            ToolInvocation(
                                callId: id,
                                name: name,
                                arguments: arguments,
                                summary: Self.summarize(name: name, arguments: arguments),
                                resultBlocks: [],
                                isError: false,
                                isRunning: true,
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
                resultBlocks: [],
                isError: false,
                isRunning: true,
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
                // A result without a matching call (a trimmed history page):
                // still surface it rather than dropping the output.
                let text = Self.joinedText(result.content)
                guard !text.isEmpty else { return .none }
                return append(
                    kind: .notice(text: text, isError: result.isError),
                    seq: event.seq,
                    identity: "orphan-result-\(event.seq)"
                )
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
            return append(
                kind: .userMessage(
                    text: text,
                    images: images,
                    isSteering: spliced.target == "next-step",
                    isPending: true,
                    isAgentSent: Self.isAgentSent(rpcId: spliced.rpcId, images: images)
                ),
                seq: event.seq,
                identity: identity
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

    private mutating func append(kind: TimelineItem.Kind, seq: Int, identity: String) -> Change {
        let item = TimelineItem(id: identity, kind: kind, seq: seq)
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

    /// Marks every tool row as finished, used when history is authoritative.
    private mutating func settleRunningTools() {
        for index in items.indices {
            guard case .toolCall(var invocation) = items[index].kind, invocation.isRunning else { continue }
            // A call with no result in a settled history was interrupted.
            invocation.isRunning = false
            items[index].kind = .toolCall(invocation)
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
    public static let agentRequestPrefix = "agent-"

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

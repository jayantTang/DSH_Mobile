import Foundation

// MARK: - Addresses and identifiers

/// A durable address for a session or a subagent conversation.
///
/// The host advertises subagent transcripts as first-class addresses, so a
/// phone can drill into a subagent exactly like the desktop client does.
public enum SessionAddress: Sendable, Hashable, Codable {
    case session(sessionId: String)
    case subagent(parentSessionId: String, childSessionId: String, mode: SubagentMode)

    public enum SubagentMode: String, Sendable, Hashable, Codable {
        case oneShot = "one-shot"
        case continuable
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sessionId, parentSessionId, childSessionId, mode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "subagent":
            self = .subagent(
                parentSessionId: try container.decode(String.self, forKey: .parentSessionId),
                childSessionId: try container.decode(String.self, forKey: .childSessionId),
                mode: (try? container.decode(SubagentMode.self, forKey: .mode)) ?? .oneShot
            )
        default:
            self = .session(sessionId: try container.decode(String.self, forKey: .sessionId))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let sessionId):
            try container.encode("session", forKey: .kind)
            try container.encode(sessionId, forKey: .sessionId)
        case .subagent(let parent, let child, let mode):
            try container.encode("subagent", forKey: .kind)
            try container.encode(parent, forKey: .parentSessionId)
            try container.encode(child, forKey: .childSessionId)
            try container.encode(mode, forKey: .mode)
        }
    }

    /// The identity a session-list row or a follow stream is keyed by.
    public var primarySessionId: String {
        switch self {
        case .session(let sessionId): return sessionId
        case .subagent(_, let child, _): return child
        }
    }
}

// MARK: - Session list

/// One page of the session list.
public struct SessionListValue: Sendable, Decodable {
    public let items: [SessionSummary]
}

/// One row in the session list.
public struct SessionSummary: Sendable, Decodable, Identifiable, Hashable {
    public let sessionId: String
    public let updatedAt: Double
    public let running: Bool
    public let blank: Bool
    public let parentSessionId: String?
    public let origin: String?
    public let cwd: String?
    public let projections: SessionProjectionHints?

    public var id: String { sessionId }

    public var updatedAtDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    /// Display title, falling back to the working directory's last component.
    public var displayTitle: String {
        if let title = projections?.values?.title, !title.isEmpty { return title }
        if let cwd, !cwd.isEmpty {
            // A session with no turns yet has no title: the directory it was
            // started in is the only thing that identifies it, and calling it
            // "新会话" makes a fresh session findable in the list.
            return blank ? "新会话 · \(cwd as NSString).lastPathComponent"
                         : (cwd as NSString).lastPathComponent
        }
        return sessionId
    }

    public var isSubagent: Bool { origin == "subagent" }

    /// The durable address this row is read through.
    ///
    /// Subagent transcripts are not addressable by their own id: the host
    /// rejects a bare child id, and it also rejects a mode that disagrees with
    /// the transcript, so the address is reconstructed from the row and its
    /// `subagent` projection.
    public var address: SessionAddress {
        if origin == "subagent", let parentSessionId {
            return .subagent(
                parentSessionId: parentSessionId,
                childSessionId: sessionId,
                mode: projections?.values?.subagent?.mode ?? .oneShot
            )
        }
        return .session(sessionId: sessionId)
    }

    /// The most advanced sequence the host has committed for this session.
    ///
    /// History reads must not ask past this cursor; the host rejects the page.
    public var asOfSeq: Int { projections?.asOfSeq ?? 0 }
}

public struct SessionProjectionHints: Sendable, Decodable, Hashable {
    public let asOfSeq: Int
    public let values: SessionProjectionValues?
}

/// The projection fold the host caches per session.
///
/// Only the fields the phone renders are modelled; everything else stays
/// available as raw JSON so a DSH upgrade cannot break decoding.
public struct SessionProjectionValues: Sendable, Decodable, Hashable {
    public let title: String?
    public let goal: GoalProjection?
    public let tokenUsage: TokenUsageProjection?
    public let contextPressure: ContextPressureProjection?
    public let sessionStats: SessionStatsProjection?
    public let agentPreset: String?
    public let permissions: PermissionsProjection?
    public let modelSelection: ModelSelectionProjection?
    public let sessionListMetadata: SessionListMetadata?
    public let todos: JSONValue?
    public let plan: PlanProjection?
    public let subagent: SubagentProjection?
    public let subagentCatalog: JSONValue?
    public let inbox: JSONValue?
}

/// What the host knows about one subagent transcript.
///
/// The list row alone does not say whether a child is addressable as
/// one-shot or continuable, and the host rejects a mismatched mode, so this
/// projection is what makes subagent transcripts openable at all.
public struct SubagentProjection: Sendable, Decodable, Hashable {
    public let mode: SessionAddress.SubagentMode?
    public let label: String?
    public let seq: Int?
}

public struct GoalProjection: Sendable, Decodable, Hashable {
    public let goal: Goal?

    public struct Goal: Sendable, Decodable, Hashable {
        public let id: String
        public let revision: Int
        public let objective: String
        public let phase: String?
        public let roundsStarted: Int?
        public let maxGoalRounds: Int?
        /// Why the goal is blocked.
        ///
        /// The Host has sent this as a bare string and as an object with a
        /// `code` and a `message`; both have to decode, because a client that
        /// only understands one shape fails the whole session list — every
        /// screen, not just the goal.
        public let blockedReason: String?

        private enum CodingKeys: String, CodingKey {
            case id, revision, objective, phase, roundsStarted, maxGoalRounds, blockedReason
        }

        private struct Reason: Decodable {
            let code: String?
            let message: String?
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            revision = try container.decode(Int.self, forKey: .revision)
            objective = try container.decode(String.self, forKey: .objective)
            phase = try? container.decodeIfPresent(String.self, forKey: .phase)
            roundsStarted = try? container.decodeIfPresent(Int.self, forKey: .roundsStarted)
            maxGoalRounds = try? container.decodeIfPresent(Int.self, forKey: .maxGoalRounds)

            if let text = try? container.decodeIfPresent(String.self, forKey: .blockedReason) {
                blockedReason = text
            } else if let reason = try? container.decodeIfPresent(Reason.self, forKey: .blockedReason) {
                blockedReason = reason.message ?? reason.code
            } else {
                blockedReason = nil
            }
        }
    }
}

public struct TokenUsageProjection: Sendable, Decodable, Hashable {
    public let uncachedInputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?

    public var totalTokens: Int {
        (uncachedInputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0)
    }
}

public struct ContextPressureProjection: Sendable, Decodable, Hashable {
    public let pressureTokens: Int?
    public let projectedTokens: Int?
    public let contextWindow: Int?

    /// Fraction of the context window currently occupied, clamped to 0…1.
    public var fraction: Double {
        guard let contextWindow, contextWindow > 0, let pressureTokens else { return 0 }
        return min(1, max(0, Double(pressureTokens) / Double(contextWindow)))
    }
}

public struct SessionStatsProjection: Sendable, Decodable, Hashable {
    public let turns: Int?
    public let steps: Int?
    public let llmMs: Double?
    public let toolMs: Double?
}

public struct PermissionsProjection: Sendable, Decodable, Hashable {
    public let options: [Option]?
    public let currentValue: String?

    public struct Option: Sendable, Decodable, Hashable {
        public let value: String
        public let name: String
    }
}

public struct ModelSelectionProjection: Sendable, Decodable, Hashable {
    public let lastUsed: ModelSelection?
    public let next: ModelSelection?
    public let pending: ModelSelection?
}

public struct SessionListMetadata: Sendable, Decodable, Hashable {
    public let blank: Bool?
    public let lastPromptAt: Double?
}

public struct PlanProjection: Sendable, Decodable, Hashable {
    public let active: Bool?
    public let pending: Bool?
}

/// A model route the host can serve.
public struct ModelSelection: Sendable, Codable, Hashable {
    public let provider: String
    public let model: String
    public let reasoningEffort: String?

    public init(provider: String, model: String, reasoningEffort: String? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

// MARK: - History and live frames

/// One item of session history as the host journals it.
public struct SessionRecord: Sendable, Decodable {
    public let event: SessionEvent
}

/// A single durable session event.
public struct SessionEvent: Sendable, Decodable {
    public let type: String
    public let seq: Int
    public let time: Double?
    public let data: JSONValue
    public let surfaceOp: JSONValue?

    public var date: Date? {
        guard let time, time > 0 else { return nil }
        // DSH emits epoch milliseconds.
        return Date(timeIntervalSince1970: time > 1e12 ? time / 1000 : time)
    }
}

/// A page of backwards history.
public struct SessionPage: Sendable, Decodable {
    public let records: [SessionRecord]
    public let hasMore: Bool
}

/// One frame of a `session/follow` stream.
public enum SessionFollowFrame: Sendable {
    case snapshot(SessionSnapshot)
    case event(SessionEvent)
    case assistantStream(AssistantStreamFrame)
    case unknown(type: String, raw: JSONValue)

    public var event: SessionEvent? {
        if case .event(let event) = self { return event }
        return nil
    }
}

extension SessionFollowFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, frame, event
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "snapshot":
            self = .snapshot(try SessionSnapshot(from: decoder))
        case "event":
            // The journal event is *nested*: the frame is
            // `{"type":"event","event":{…,"seq":…,"data":…}}`. Decoding
            // `SessionEvent` from the outer decoder looks for `seq` and `data`
            // at the top level and always fails, which is what silently killed
            // the live stream after its opening snapshot.
            self = .event(try container.decode(SessionEvent.self, forKey: .event))
        case "assistant-stream":
            self = .assistantStream(try container.decode(AssistantStreamFrame.self, forKey: .frame))
        default:
            self = .unknown(type: type, raw: (try? JSONValue(from: decoder)) ?? .null)
        }
    }
}

/// The opening frame of a follow stream: the tail of history plus a cursor.
public struct SessionSnapshot: Sendable, Decodable {
    public let cursor: Int
    public let records: [SessionRecord]
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case cursor, records, hasMore
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = (try? container.decode(Int.self, forKey: .cursor)) ?? 0
        records = (try? container.decode([SessionRecord].self, forKey: .records)) ?? []
        hasMore = (try? container.decode(Bool.self, forKey: .hasMore)) ?? false
    }
}

/// A one-shot RPC result carrying nothing meaningful.
public struct SessionAck: Sendable, Decodable {}

// MARK: - Requests

public struct SessionPageRequest: Encodable, Sendable {
    public let address: SessionAddress
    public let throughSeq: Int
    public let beforeSeq: Int?
    public let maxMessages: Int?

    public init(address: SessionAddress, throughSeq: Int, beforeSeq: Int? = nil, maxMessages: Int? = nil) {
        self.address = address
        self.throughSeq = throughSeq
        self.beforeSeq = beforeSeq
        self.maxMessages = maxMessages
    }
}

public struct SessionFollowRequest: Encodable, Sendable {
    public let address: SessionAddress
    public let maxMessages: Int?
    /// Ask the host to include process-local assistant presentation frames,
    /// which is what makes live token streaming visible.
    public let assistantStream: Bool?

    public init(address: SessionAddress, maxMessages: Int? = nil, assistantStream: Bool? = true) {
        self.address = address
        self.maxMessages = maxMessages
        self.assistantStream = assistantStream
    }
}

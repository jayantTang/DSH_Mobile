import Foundation

// MARK: - Addresses and identifiers

/// A durable address for a session or a subagent conversation.
///
/// The host advertises subagent transcripts as first-class addresses, so a
/// phone can drill into a subagent exactly like the desktop client does.
public enum SessionAddress: Sendable, Hashable, Codable {
    case session(sessionId: String)
    case subagent(parentSessionId: String, childSessionId: String, mode: SubagentMode)

    /// 子会话的三种形态，外加"宿主没说是哪一种"。
    ///
    /// 词表是宿主的（`dsh-subagent` 的 catalog）：`one-shot` / `continuable` /
    /// `external`（桌面端显示为「外部任务」）。`unknown` 也是宿主自己的线上取值，
    /// 而且**只有它跳过 mode 校验**（`dsh-api-session-controller` 的 `validateAddress`：
    /// `address.mode !== 'unknown' && identity.mode !== address.mode` 才拒）。
    ///
    /// 所以"拿不到 mode"必须表达成 `unknown`，不能猜一个具体值：猜错就是
    /// `subagent/unauthorized`，子会话直接打不开。
    public enum SubagentMode: String, Sendable, Hashable, Codable {
        case oneShot = "one-shot"
        case continuable
        /// 外部子任务：独立会话，但没有可继续的对话。
        case external
        /// 这一版说不清是哪种（宿主没给投影，或给了不认识的名字）。
        case unknown

        /// 不认识的取值读作 `.unknown`：一行解不开就是整份 `session/list` 解不开，
        /// 而"不知道"本身是能发给宿主的合法取值。
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = SubagentMode(rawValue: raw) ?? .unknown
        }
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
                mode: (try? container.decode(SubagentMode.self, forKey: .mode)) ?? .unknown
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
public struct SessionListValue: Sendable, Codable {
    public let items: [SessionSummary]
    /// 增量响应：消失的会话 id；全量时为空。
    public let removed: [String]?
    /// 覆盖版本：下次请求带 `since` 即可只取变化。
    public let version: String?
    /// `true` = 这是一份全量（不能用增量方式合并）。
    public let full: Bool?

    public init(items: [SessionSummary], removed: [String]? = nil,
                version: String? = nil, full: Bool? = nil) {
        self.items = items
        self.removed = removed
        self.version = version
        self.full = full
    }
}

/// 会话列表的增量合并（纯函数，非 UI）。
public enum SessionDigestMerge {
    /// 把一次回包合并进当前列表：按 id 替换/追加、删除 removed、按更新时间倒序。
    public static func apply(current: [SessionSummary],
                             value: SessionListValue) -> [SessionSummary] {
        var byId: [String: SessionSummary] = [:]
        if value.full != true {
            for row in current { byId[row.sessionId] = row }
        }
        for row in value.items { byId[row.sessionId] = row }
        if value.full != true {
            for id in value.removed ?? [] { byId.removeValue(forKey: id) }
        }
        return byId.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// One row in the session list.
public struct SessionSummary: Sendable, Codable, Identifiable, Hashable {
    public let sessionId: String
    public let updatedAt: Double
    public let running: Bool
    public let blank: Bool
    public let parentSessionId: String?
    public let origin: String?
    public let cwd: String?
    public let projections: SessionProjectionHints?
    /// 宿主的这一会话是否还能起新轮次（本机实测存在，协议文档未列；缺省即未知）。
    public let agentAvailable: Bool?

    public var id: String { sessionId }

    /// 本地构造一行（新建会话占位、测试夹具）：字段与宿主行同形。
    public init(sessionId: String, updatedAt: Double, running: Bool = false,
                blank: Bool = false, parentSessionId: String? = nil, origin: String? = nil,
                cwd: String? = nil, projections: SessionProjectionHints? = nil,
                agentAvailable: Bool? = nil) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.running = running
        self.blank = blank
        self.parentSessionId = parentSessionId
        self.origin = origin
        self.cwd = cwd
        self.projections = projections
        self.agentAvailable = agentAvailable
    }

    public var updatedAtDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    public func with(projections: SessionProjectionHints?) -> SessionSummary {
        SessionSummary(sessionId: sessionId, updatedAt: updatedAt, running: running,
                       blank: blank, parentSessionId: parentSessionId,
                       origin: origin, cwd: cwd, projections: projections,
                       agentAvailable: agentAvailable)
    }

    /// 宿主实时事件（status/activity）驱动的局部更新；其余字段原样保留。
    public func with(running: Bool? = nil, updatedAt: Double? = nil) -> SessionSummary {
        SessionSummary(sessionId: sessionId,
                       updatedAt: updatedAt ?? self.updatedAt,
                       running: running ?? self.running,
                       blank: blank, parentSessionId: parentSessionId,
                       origin: origin, cwd: cwd, projections: projections,
                       agentAvailable: agentAvailable)
    }

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
    ///
    /// **没有投影时发 `unknown`，不猜 `.oneShot`**：宿主只给一部分子会话行带
    /// `subagent` 投影（本机 2026-10-19 实测 317 条子会话行里 194 条没有；嵌套
    /// 子智能体、老会话都是这样），而 `validateAddress` 拿真实 mode 与地址比对，
    /// 不符即 `subagent/unauthorized`——猜成一次性会让真身为 `continuable` 的
    /// 子会话**一开就报错**。`unknown` 在宿主那边跳过校验，是"不知道"的唯一
    /// 合法表达（`SessionAddress.SubagentMode` 的头注）。
    public var address: SessionAddress {
        if origin == "subagent", let parentSessionId {
            return .subagent(
                parentSessionId: parentSessionId,
                childSessionId: sessionId,
                mode: projections?.values?.subagent?.mode ?? .unknown
            )
        }
        return .session(sessionId: sessionId)
    }

    /// The most advanced sequence the host has committed for this session.
    ///
    /// History reads must not ask past this cursor; the host rejects the page.
    public var asOfSeq: Int { projections?.asOfSeq ?? 0 }

    /// 子会话本轮是否在跑（`data-model.md` §3：`subagentTiming.active` 非空即在跑）。
    ///
    /// **只认这个投影**。老宿主不给它时读作 false：`running` 是快照、且父会话的
    /// 轮次也会让它为真，拿它推"子智能体在跑"会把结束了的子会话一直算成活。
    public var isSubagentActive: Bool { subagentTiming?.active != nil }

    public var subagentTiming: SubagentTimingProjection? { projections?.values?.subagentTiming }

    /// 行标题用的子会话标签；缺失时视图回退会话 id（`activity-ui.md` §5）。
    public var subagentLabel: String? { projections?.values?.subagent?.label }

    /// 可持续 / 一次性；缺失时按一次性处理（不给"停止"入口）。
    public var subagentMode: SessionAddress.SubagentMode? { projections?.values?.subagent?.mode }

    /// 子会话本轮的起跑时刻（毫秒）：面板的已跑时长基准。
    public var subagentActiveSince: Double? { projections?.values?.subagentTiming?.active?.since }
}

public struct SessionProjectionHints: Sendable, Codable, Hashable {
    public let asOfSeq: Int
    public let values: SessionProjectionValues?

    public init(asOfSeq: Int = 0, values: SessionProjectionValues?) {
        self.asOfSeq = asOfSeq
        self.values = values
    }
}

/// The projection fold the host caches per session.
///
/// Only the fields the phone renders are modelled; everything else stays
/// available as raw JSON so a DSH upgrade cannot break decoding.
public struct SessionProjectionValues: Sendable, Codable, Hashable {
    public let title: String?
    let goal: GoalProjection?
    public let tokenUsage: TokenUsageProjection?
    public let contextPressure: ContextPressureProjection?
    let sessionStats: SessionStatsProjection?
    public let agentPreset: String?
    public let permissions: PermissionsProjection?
    public let modelSelection: ModelSelectionProjection?
    let sessionListMetadata: SessionListMetadata?
    let todos: JSONValue?
    public let plan: PlanProjection?
    public let subagent: SubagentProjection?
    let subagentCatalog: JSONValue?
    /// 子会话本轮的计时：`active` 存在 = 正在跑；消失 = 本轮结束。
    public let subagentTiming: SubagentTimingProjection?
    public let inbox: JSONValue?

    /// 全空的投影，用于合并第一条增量。
    public static let empty = SessionProjectionValues(
        title: nil, goal: nil, tokenUsage: nil, contextPressure: nil,
        sessionStats: nil, agentPreset: nil, permissions: nil,
        modelSelection: nil, sessionListMetadata: nil, todos: nil,
        plan: nil, subagent: nil, subagentCatalog: nil, subagentTiming: nil,
        inbox: nil)

    /// 把 `session/control` 的一条 projection 合并进来；值解不出就保留旧值。
    public func merging(key: String, value: JSONValue) -> SessionProjectionValues {
        func decoded<T: Decodable>(_ type: T.Type) -> T? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        var nextTitle = title
        var nextGoal = goal
        var nextUsage = tokenUsage
        var nextPressure = contextPressure
        var nextStats = sessionStats
        var nextPreset = agentPreset
        var nextPermissions = permissions
        var nextModel = modelSelection
        var nextMetadata = sessionListMetadata
        var nextTodos = todos
        var nextPlan = plan
        var nextSubagent = subagent
        var nextCatalog = subagentCatalog
        var nextTiming = subagentTiming
        var nextInbox = inbox
        switch key {
        case "title": if let text = value.stringValue { nextTitle = text }
        case "goal": nextGoal = decoded(GoalProjection.self)
        case "tokenUsage": nextUsage = decoded(TokenUsageProjection.self)
        case "contextPressure": nextPressure = decoded(ContextPressureProjection.self)
        case "sessionStats": nextStats = decoded(SessionStatsProjection.self)
        case "agentPreset": if let text = value.stringValue { nextPreset = text }
        case "permissions": nextPermissions = decoded(PermissionsProjection.self)
        case "modelSelection": nextModel = decoded(ModelSelectionProjection.self)
        case "sessionListMetadata": nextMetadata = decoded(SessionListMetadata.self)
        case "todos": nextTodos = value
        case "plan": nextPlan = decoded(PlanProjection.self)
        case "subagent": nextSubagent = decoded(SubagentProjection.self)
        case "subagentCatalog": nextCatalog = value
        case "subagentTiming": nextTiming = decoded(SubagentTimingProjection.self)
        case "inbox": nextInbox = value
        default: break
        }
        return SessionProjectionValues(
            title: nextTitle, goal: nextGoal, tokenUsage: nextUsage,
            contextPressure: nextPressure, sessionStats: nextStats,
            agentPreset: nextPreset, permissions: nextPermissions,
            modelSelection: nextModel, sessionListMetadata: nextMetadata,
            todos: nextTodos, plan: nextPlan, subagent: nextSubagent,
            subagentCatalog: nextCatalog, subagentTiming: nextTiming,
            inbox: nextInbox)
    }
}

/// 投影 `subagentTiming`（`host-job-surface.md` §7）。
///
/// 三个字段都是可选的：宿主在子会话还没起跑、或本轮已经结束时只给其中一部分。
public struct SubagentTimingProjection: Sendable, Codable, Hashable {
    /// 已经跑完的轮次累计毫秒。
    public let settledMs: Double?
    /// 正在进行的那一轮；`nil` = 没在跑。
    public let active: Active?
    /// 最近一轮是否已完成（面板「已结束」段的判据之一）。
    public let lastTurnCompleted: Bool?

    public struct Active: Sendable, Codable, Hashable {
        /// 起跑时刻（毫秒）：已跑时长的基准。
        public let since: Double?
        /// 已确认推进到的时刻（毫秒）；宿主用它标记心跳。
        public let through: Double?
    }
}

/// What the host knows about one subagent transcript.
///
/// The list row alone does not say whether a child is addressable as
/// one-shot or continuable, and the host rejects a mismatched mode, so this
/// projection is what makes subagent transcripts openable at all.
public struct SubagentProjection: Sendable, Codable, Hashable {
    public let mode: SessionAddress.SubagentMode?
    public let label: String?
    public let seq: Int?
}

struct GoalProjection: Sendable, Codable, Hashable {
    let goal: Goal?

    struct Goal: Sendable, Codable, Hashable {
        let id: String
        let revision: Int
        let objective: String
        let phase: String?
        let roundsStarted: Int?
        let maxGoalRounds: Int?
        /// Why the goal is blocked.
        ///
        /// The Host has sent this as a bare string and as an object with a
        /// `code` and a `message`; both have to decode, because a client that
        /// only understands one shape fails the whole session list — every
        /// screen, not just the goal.
        let blockedReason: String?

        private enum CodingKeys: String, CodingKey {
            case id, revision, objective, phase, roundsStarted, maxGoalRounds, blockedReason
        }

        private struct Reason: Decodable {
            let code: String?
            let message: String?
        }

        init(from decoder: any Decoder) throws {
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

public struct TokenUsageProjection: Sendable, Codable, Hashable {
    public let uncachedInputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    let cacheWriteTokens: Int?

    public var totalTokens: Int {
        (uncachedInputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0)
    }
}

public struct ContextPressureProjection: Sendable, Codable, Hashable {
    public let pressureTokens: Int?
    let projectedTokens: Int?
    public let contextWindow: Int?

    /// Fraction of the context window currently occupied, clamped to 0…1.
    public var fraction: Double {
        guard let contextWindow, contextWindow > 0, let pressureTokens else { return 0 }
        return min(1, max(0, Double(pressureTokens) / Double(contextWindow)))
    }
}

struct SessionStatsProjection: Sendable, Codable, Hashable {
    let turns: Int?
    let steps: Int?
    let llmMs: Double?
    let toolMs: Double?
}

public struct PermissionsProjection: Sendable, Codable, Hashable {
    public let options: [Option]?
    public let currentValue: String?

    public struct Option: Sendable, Codable, Hashable {
        public let value: String
        public let name: String
    }
}

public struct ModelSelectionProjection: Sendable, Codable, Hashable {
    public let lastUsed: ModelSelection?
    public let next: ModelSelection?
    public let pending: ModelSelection?
}

struct SessionListMetadata: Sendable, Codable, Hashable {
    let blank: Bool?
    let lastPromptAt: Double?
}

public struct PlanProjection: Sendable, Codable, Hashable {
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
public struct SessionRecord: Sendable, Codable {
    public let event: SessionEvent

    public init(event: SessionEvent) {
        self.event = event
    }
}

/// A single durable session event.
public struct SessionEvent: Sendable, Codable {
    public let type: String
    public let seq: Int
    public let time: Double?
    public let data: JSONValue
    public let surfaceOp: JSONValue?

    /// The mark this app puts on **its own** provisional (still-streaming) record,
    /// written by `SessionPipeline+Streaming` and read by the fold and the bridge.
    ///
    /// Why it exists: the host's own `assistant/message` already carries a `stream`
    /// field, but that is the raw model output log (an array of chunks) — it says
    /// nothing about whether the record is still streaming. Treating "`stream` is
    /// present" as the mark made every committed record provisional, so every
    /// answer rendered through the streaming plain-text fallback and its Markdown
    /// never appeared. This key carries a leading underscore and a name only this
    /// app uses, so the two meanings can no longer be confused. See
    /// `specs/011-transcript-markdown-render/contracts/provisional-mark.md`.
    public static let provisionalKey = "_dshMobileProvisional"

    /// Whether this record was synthesised locally and is still streaming.
    ///
    /// The single judgement: only the boolean `true` counts. A missing key, a
    /// non-boolean value, and any host field (including `stream`) all read false.
    public var isProvisional: Bool { data[Self.provisionalKey]?.boolValue == true }

    public var date: Date? {
        guard let time, time > 0 else { return nil }
        // DSH emits epoch milliseconds.
        return Date(timeIntervalSince1970: time > 1e12 ? time / 1000 : time)
    }
}

/// A page of backwards history.
public struct SessionPage: Sendable, Codable {
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
public struct SessionSnapshot: Sendable, Codable {
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
struct SessionAck: Sendable, Codable {}

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

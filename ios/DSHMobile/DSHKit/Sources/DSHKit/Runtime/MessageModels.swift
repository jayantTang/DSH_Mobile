import Foundation

// App 与 DSHKit 之间的**只读模型别名**。
//
// 这些模型原本嵌套在实现层类型里（`MessagePipeline.SessionRef`、`SessionPipeline.GapRow`、
// `MessageStore.UserInputEntry`……），App 每写一次就把实现层的名字带进产品路径。别名让
// App 用稳定的名字，实现层改内部命名时只在这里跟随一次。
//
// 纯别名：类型、成员、初始化器完全同一份，不存在两套实现，也不会漂移。
// **它们不是“单一入口”**：DSHKit 的数据能力仍由 `MessageLayer` / `SessionHandle` /
// `LinkGateway` 三个窄对象构成。2026-10-21 删除了未落地的 `SessionRuntime` 骨架
// （协议只有 `transport` 一个成员且 App 从未使用），避免再出现“名义门面”。

/// 一个会话的地址（scope + sessionId）。
public struct MessageSessionRef: Hashable, Sendable {
    public let scope: String
    public let sessionId: String

    public init(scope: String, sessionId: String) {
        self.scope = scope
        self.sessionId = sessionId
    }
}

/// 一条待发送/已发送消息的状态。
public enum MessageSendStatus: String, Sendable, Equatable {
    case sent, pending, failed
    /// 已受理、但确认帧永远没来（宿主撤单、轮次以错误结束）。
    case unconfirmed
}

/// 数据行：排版已完成的不可变快照。`id` 是稳定 UUID，状态变化不改身份。
public struct MessageRenderedMessage: Identifiable, Sendable {
    public let id: UUID
    public let seq: Int
    public let record: SessionRecord
    public let status: MessageSendStatus

    public init(id: UUID, seq: Int, record: SessionRecord, status: MessageSendStatus) {
        self.id = id
        self.seq = seq
        self.record = record
        self.status = status
    }
}

/// 时间线上的缺口行（失败的取页区间）。
public struct TranscriptGapRow: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case loading
        case failed(retryable: Bool)
        case exhausted
    }

    public let start: Int
    public let end: Int
    public let status: Status

    public var id: String { "gap:\(start)-\(end)" }

    public init(start: Int, end: Int, status: Status) {
        self.start = start
        self.end = end
        self.status = status
    }
}

/// 行：数据行或缺口行。
public enum MessageRow: Identifiable, Sendable {
    case message(MessageRenderedMessage)
    case gap(TranscriptGapRow)

    public var id: String {
        switch self {
        case .message(let message): return message.id.uuidString
        case .gap(let gap): return gap.id
        }
    }
}

/// 一次原子提交。
public struct MessageSnapshotDiff: Sendable {
    public struct Anchor: Sendable, Equatable {
        public let seq: Int
        public let offset: Double

        public init(seq: Int, offset: Double) {
            self.seq = seq
            self.offset = offset
        }
    }

    public let anchor: Anchor?
    public let changes: [Change]

    public enum Change: Sendable {
        case insert([MessageRow])
        case remove([String])
        case update([MessageRow])
    }

    public init(anchor: Anchor? = nil, changes: [Change]) {
        self.anchor = anchor
        self.changes = changes
    }
}

/// 预取目标：某个会话要预取到哪一条。
public struct MessagePrefetchTarget: Sendable, Hashable {
    public let session: MessageSessionRef
    public let newestSeq: Int

    public init(session: MessageSessionRef, newestSeq: Int) {
        self.session = session
        self.newestSeq = newestSeq
    }
}

/// 一次落库变更（上行 pending / 下行记录共用）。
public enum MessageRecordChange: Sendable {
    case upsertRecords(scope: String, sessionId: String, records: [SessionRecord])
    case upsertPending(scope: String, sessionId: String, clientId: String, record: SessionRecord)
    case confirmPending(scope: String, sessionId: String, clientId: String, record: SessionRecord)
}

/// 「我问过的」一条记录。
public struct UserInputEntry: Sendable {
    public let sessionId: String
    public let record: SessionRecord

    public init(sessionId: String, record: SessionRecord) {
        self.sessionId = sessionId
        self.record = record
    }
}

/// 列表页一行（session_state 的投影）。
public struct MessageSessionState: Sendable, Equatable {
    public let sessionId: String
    public let oldestSeq: Int?
    public let newestSeq: Int?
    public let hasMore: Bool
    public let lastSnippet: String?
    public let unreadCount: Int
    let lastOpened: Date
    public let ranges: RangeIndex
}

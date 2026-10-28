import Foundation
import GRDB

/// 尾轮边界的**持久化副本**（设计 `20261027-折叠抖动-方案A.md` M2'）。
///
/// 它只回答一件事：这台设备上一次亲眼看到的尾轮边界是什么。`open()` 用它播种，
/// 于是"进程被杀之后重进同一会话"不必再从窗口里有没有边界行去猜（那是被删掉的旧行为）。
/// 它**不得**覆盖任何实时观测：合并表在 `ChatTimeline.noteBoundary`，这里只是副本。
///
/// 三条硬约束由类型与调用点各管一半，谁都不许绕过：
/// - `.unknown` 永不落库 —— `init?` 对 `.unknown` 返回 nil，不是靠调用方记得判断；
/// - 只有"窗口落到会话尾部"的会话才写（搜索中间窗口不写，调用点判 `showsTail`）；
/// - 写失败必须 `throw`（`MessageLayer` 的门面不许用 `try?`），由调用方发
///   `tail.persist.failed` 探针——失败的唯一可见后果是"下次打开仍未知 → 占位行可重试"。
public struct StoredTailBoundary: Sendable, Equatable {

    /// 落库的两个取值。`unknown` 不在词表里（没有证据就不写）。
    ///
    /// internal：模块外只该用 `TranscriptTail.Boundary`，磁盘词表是实现细节。
    static let openValue = "open"
    static let closedValue = "closed"

    /// 模块外只读这两列（UI/Domain 判不走它们：边界事实一律用 `asBoundary`）。
    public var boundary: String
    public var turn: Int
    /// 结束原因（只有 closed 有值）。internal：只有本模块与用例读。
    var reason: String?
    /// 开着的那一轮的开始时刻（`turn/start` 的宿主时间）。internal，同上。
    var startedAt: Date?
    /// 写入时刻。internal，同上。
    var updatedAt: Date

    /// internal：唯一的构造者是 `MessageStore`（读行）与 `init?(_:)`（写行）。
    init(boundary: String, turn: Int, reason: String? = nil,
         startedAt: Date? = nil, updatedAt: Date = Date()) {
        self.boundary = boundary
        self.turn = turn
        self.reason = reason
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// 边界 → 磁盘行。`unknown`（"没有证据"）返回 nil：它不许进库。
    public init?(_ boundary: TranscriptTail.Boundary, updatedAt: Date = Date()) {
        switch boundary {
        case .unknown:
            return nil
        case .open(let turn, let startedAt):
            self.init(boundary: Self.openValue, turn: turn, startedAt: startedAt,
                      updatedAt: updatedAt)
        case .closed(let turn, let reason):
            self.init(boundary: Self.closedValue, turn: turn, reason: reason,
                      updatedAt: updatedAt)
        }
    }

    /// 磁盘行 → 边界。词表外的值按 `.unknown` 处理：宁可重新确认一次，
    /// 也不从一个认不出来的字符串编出一条事实。
    public var asBoundary: TranscriptTail.Boundary {
        switch boundary {
        case Self.openValue: return .open(turn: turn, startedAt: startedAt)
        case Self.closedValue: return .closed(turn: turn, reason: reason)
        default: return .unknown
        }
    }
}

extension MessageStore {

    /// `v5-session-tail` 的表定义（迁移登记在 `MessageStore.migrator`）。
    ///
    /// 为什么独立一张表而不是给 `session_state` 加三列：那张表有 4 个写者，每个都
    /// 用 `COALESCE` 只碰自己那几列（聚合 upsert、`ranges_json`、`has_more`、修复迁移），
    /// 加列就要改 4 处 SQL，漏一处就会静默清空边界。新表只有一个写者、一个读者，
    /// 删除路径与 `clear` 一致，回滚只需 `DROP TABLE session_tail`。
    static func createTailSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session_tail (
              scope      TEXT    NOT NULL,
              session_id TEXT    NOT NULL,
              boundary   TEXT    NOT NULL,
              turn       INTEGER NOT NULL DEFAULT 0,
              reason     TEXT,
              started_at REAL,
              updated_at REAL    NOT NULL,
              PRIMARY KEY (scope, session_id)
            );
            """)
    }

    /// 上次观测到的边界；没有行 = 从未确认（`nil`，不是 `.unknown` 行）。
    func tailBoundary(scope: String, sessionId: String) async throws -> StoredTailBoundary? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT boundary, turn, reason, started_at, updated_at
                FROM session_tail WHERE scope = ? AND session_id = ?
                """, arguments: [scope, sessionId]) else { return nil }
            let startedAt: Double? = row["started_at"]
            let updatedAt: Double = row["updated_at"]
            return StoredTailBoundary(
                boundary: row["boundary"],
                turn: row["turn"],
                reason: row["reason"],
                startedAt: startedAt.map { Date(timeIntervalSince1970: $0) },
                updatedAt: Date(timeIntervalSince1970: updatedAt))
        }
    }

    /// 写一个会话的边界（一个会话一行：`ON CONFLICT` 原地替换，不留历史行）。
    func setTailBoundary(scope: String, sessionId: String,
                         _ boundary: StoredTailBoundary) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO session_tail
                  (scope, session_id, boundary, turn, reason, started_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(scope, session_id) DO UPDATE SET
                  boundary = excluded.boundary,
                  turn = excluded.turn,
                  reason = excluded.reason,
                  started_at = excluded.started_at,
                  updated_at = excluded.updated_at
                """, arguments: [scope, sessionId, boundary.boundary, boundary.turn,
                                 boundary.reason, boundary.startedAt?.timeIntervalSince1970,
                                 boundary.updatedAt.timeIntervalSince1970])
        }
    }
}

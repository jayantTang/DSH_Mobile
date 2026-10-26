import Foundation
import GRDB

/// MessageStore 的维护半边（T027）：007 `TranscriptStore` 退役后，它身上的三个
/// 小语义迁到这里——会话级 kv（搜索缓冲覆盖范围）、按会话清除、整库清除。
/// 文件按职责拆分（沿用 `MessageStore+Records` 先例）。
extension MessageStore {

    // MARK: - 会话级 kv（007 meta 语义）

    /// kv 键在库内按 scope 隔离（旧库是"目录 + 键"，这里合成一个键，语义不变）。
    private static func scoped(_ key: String, scope: String) -> String { "\(scope)/\(key)" }

    func meta(_ key: String, scope: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?",
                                arguments: [Self.scoped(key, scope: scope)])
        }
    }

    func setMeta(_ key: String, _ value: String, scope: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                           arguments: [Self.scoped(key, scope: scope), value])
        }
    }

    // MARK: - 单个会话状态（冷启动尾部恢复用）

    func sessionState(scope: String, sessionId: String) async throws -> MessageSessionState? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT session_id, oldest_seq, newest_seq, has_more, last_opened,
                       last_snippet, unread_count, ranges_json
                FROM session_state WHERE scope = ? AND session_id = ?
                """, arguments: [scope, sessionId]) else { return nil }
            let rangesJSON: String = row["ranges_json"] ?? "[]"
            return MessageSessionState(
                sessionId: row["session_id"],
                oldestSeq: row["oldest_seq"],
                newestSeq: row["newest_seq"],
                hasMore: (row["has_more"] as Int) != 0,
                lastSnippet: row["last_snippet"],
                unreadCount: row["unread_count"],
                lastOpened: Date(timeIntervalSince1970: row["last_opened"]),
                ranges: (try? JSONDecoder().decode([RangeIndex.Span].self, from: Data(rangesJSON.utf8)))
                    .map { RangeIndex(spans: $0) } ?? RangeIndex()
            )
        }
    }

    // MARK: - 清除

    /// 删掉一个会话在本库里的全部痕迹（记录、聚合行、kv）。
    func clear(scope: String, sessionId: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM record WHERE scope = ? AND session_id = ?",
                           arguments: [scope, sessionId])
            try db.execute(sql: "DELETE FROM session_state WHERE scope = ? AND session_id = ?",
                           arguments: [scope, sessionId])
            // 会话级 kv（搜索缓冲覆盖范围、用户输入灌库账本、单条步骤正文缓存）
            // 同会话一起清。
            try db.execute(sql: "DELETE FROM meta WHERE key IN (?, ?, ?)",
                           arguments: [Self.scoped("search.range.\(sessionId)", scope: scope),
                                       Self.syncKey(scope: scope, sessionId: sessionId),
                                       Self.scoped(
                                        TranscriptLocalCacheKeys.stepBodies(sessionId: sessionId),
                                        scope: scope)])
        }
    }

    /// 整库清空（「清除本地缓存」按钮、DEBUG 探针）。表保留，只清内容。
    func clearAll() async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM record")
            try db.execute(sql: "DELETE FROM session_state")
            try db.execute(sql: "DELETE FROM meta")
        }
    }
}

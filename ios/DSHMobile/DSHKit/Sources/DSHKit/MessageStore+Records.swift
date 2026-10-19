import Foundation
import GRDB

/// MessageStore 的读写半边（文件按职责拆分，沿用 `TranscriptStore+Housekeeping` 先例）。
extension MessageStore {

    // MARK: - 会话内容判据（唯一定义）

    /// 「这一行是会话里的内容」：pending 行**不是**。
    ///
    /// 上行的乐观记录（`MessagePipeline+Send` 的 `insertOptimistic` / `restorePending`）
    /// 带的是本机合成排序键（`Int.max` 起递减），它只负责把行排在末尾，不是会话里的
    /// **位置**。会话位置只有一个所有者：服务端 seq。所以任何对外交出 seq 的读侧
    /// （聚合游标、浏览列表、关键词搜索、增量灌库锚点）都必须带上这一条，否则合成键
    /// 会被下游当成位置用：界面上印成「第 9223372036854775806 条」，灌库锚点被顶到天花板，
    /// 跳转按 `seq + leading` 算页边界时整数溢出。
    ///
    /// `alias` 是 SQL 里 `record` 表的名字（带 JOIN 时用表的别名）。
    /// 迁移 `v3-aggregate-excludes-pending` 里有一段同名条件，那是历史快照，不随这里改。
    static func sessionContent(_ alias: String = "record") -> String {
        "\(alias).status != 'pending'"
    }

    // MARK: - 写入（下行记录 / 上行 pending 共用一个入口，批量事务）

    /// 应用一批去重后的变更（内存层 PendingWriteQueue drain 的结果）。
    public func applyWrites(_ changes: [RecordChange]) async throws {
        try await pool.write { db in
            for change in changes {
                switch change {
                case .upsertRecords(let scope, let sessionId, let records):
                    try Self.insertRecords(records, scope: scope, sessionId: sessionId, status: "sent", db: db)
                    try Self.refreshState(scope: scope, sessionId: sessionId, openedAt: now(), db: db)
                case .upsertPending(let scope, let sessionId, let clientId, let record):
                    try Self.insertRecords([record], scope: scope, sessionId: sessionId,
                                      status: "pending", clientId: clientId, db: db)
                    try Self.refreshState(scope: scope, sessionId: sessionId, openedAt: now(), db: db)
                case .confirmPending(let scope, let sessionId, let clientId, let record):
                    // 服务端确认：同一 clientId 的 pending 行换成正式行。
                    try db.execute(
                        sql: "DELETE FROM record WHERE scope = ? AND session_id = ? AND client_id = ?",
                        arguments: [scope, sessionId, clientId])
                    try Self.insertRecords([record], scope: scope, sessionId: sessionId, status: "sent", db: db)
                    try Self.refreshState(scope: scope, sessionId: sessionId, openedAt: now(), db: db)
                }
            }
        }
    }

    private static func insertRecords(
        _ records: [SessionRecord], scope: String, sessionId: String,
        status: String, clientId: String? = nil, db: Database
    ) throws {
        let encoder = JSONEncoder()
        for record in records {
            let payload = try encoder.encode(record)
            // data-model v3：来源细分从事件内提取（kind 缺省 nil，由查询侧按 'user' 兼容）。
            let source = record.event.data["source"]
            try db.execute(sql: """
                INSERT OR REPLACE INTO record
                  (scope, session_id, seq, kind, role, payload, byte_size, client_id, status,
                   source_kind, source_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    scope, sessionId, record.event.seq, record.event.type,
                    Role(eventType: record.event.type).rawValue,
                    payload, payload.count, clientId, status,
                    source?["kind"]?.stringValue, source?["rpcId"]?.stringValue,
                ])
        }
    }

    /// 更新会话聚合行（列表页一次查询出全部靠的就是这些冗余列）。
    private static func refreshState(
        scope: String, sessionId: String, openedAt: Date, db: Database
    ) throws {
        // 聚合只统计会话内容（`sessionContent()`：排除 pending）。上行的乐观记录用
        // 合成 seq（`nextSyntheticSeq` 从 `Int.max` 起递减，见 MessagePipeline+Send），
        // 算进 MAX(seq) 会让 `newest_seq` 变成 9223372036854775807；冷启动预取拿它当
        // 游标算页边界，第二次 `start + pageSize - 1` 就整数溢出（TestFlight
        // 20261012.1310 的 SIGTRAP 落在 SessionPipeline+Paging.swift:12）。
        let bounds = try Row.fetchOne(db, sql: """
            SELECT MIN(seq) AS oldest, MAX(seq) AS newest, COUNT(*) AS total
            FROM record WHERE scope = ? AND session_id = ? AND \(Self.sessionContent())
            """, arguments: [scope, sessionId])
        let snippet = try Row.fetchOne(db, sql: """
            SELECT payload FROM record WHERE scope = ? AND session_id = ?
              AND \(Self.sessionContent())
            ORDER BY seq DESC LIMIT 1
            """, arguments: [scope, sessionId]).flatMap { row -> String? in
            guard let payload: Data = row["payload"] else { return nil }
            return MessageStore.snippet(of: payload)
        }
        try db.execute(sql: """
            INSERT INTO session_state (scope, session_id, oldest_seq, newest_seq, has_more,
                                       last_opened, last_snippet, unread_count, ranges_json)
            VALUES (?, ?, ?, ?, COALESCE((SELECT has_more FROM session_state
                                          WHERE scope = ? AND session_id = ?), 1),
                    ?, ?, COALESCE((SELECT unread_count FROM session_state
                                    WHERE scope = ? AND session_id = ?), 0),
                    COALESCE((SELECT ranges_json FROM session_state
                              WHERE scope = ? AND session_id = ?), '[]'))
            ON CONFLICT(scope, session_id) DO UPDATE SET
              oldest_seq = excluded.oldest_seq,
              newest_seq = excluded.newest_seq,
              last_snippet = excluded.last_snippet
            """, arguments: [
                scope, sessionId,
                bounds?["oldest"] as Int?, bounds?["newest"] as Int?,
                scope, sessionId,
                openedAt.timeIntervalSince1970, snippet,
                scope, sessionId,
                scope, sessionId,
            ])
    }

    // MARK: - 读取（区间/窗口/列表/用户输入）

    /// 读一个闭区间内的记录（升序）。区间判定命中后的水合走这里。
    public func records(
        scope: String, sessionId: String, in range: ClosedRange<Int>
    ) async throws -> [SessionRecord] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT payload FROM record
                WHERE scope = ? AND session_id = ? AND seq >= ? AND seq <= ?
                ORDER BY seq ASC
                """, arguments: [scope, sessionId, range.lowerBound, range.upperBound])
            return try Self.decode(rows)
        }
    }

    /// 未发出的上行消息（status='pending'，T022 重启恢复）：clientId + 乐观记录，
    /// 按合成 seq 升序（老→新）。崩溃前确认没落库的消息也在其中，重发前由内存层
    /// 按 clientId 对服务端查重。
    func pendingRecords(
        scope: String, sessionId: String
    ) async throws -> [(clientId: String, record: SessionRecord)] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT client_id, payload FROM record
                WHERE scope = ? AND session_id = ? AND status = 'pending' AND client_id IS NOT NULL
                ORDER BY seq ASC
                """, arguments: [scope, sessionId])
            let decoder = JSONDecoder()
            return rows.compactMap { row -> (String, SessionRecord)? in
                guard let clientId: String = row["client_id"],
                      let payload: Data = row["payload"],
                      let record = try? decoder.decode(SessionRecord.self, from: payload)
                else { return nil }
                return (clientId, record)
            }
        }
    }

    /// 按 clientId 找宿主确认过的正式记录（`source_id` 即 `data.source.rpcId`，
    /// `status != 'pending'`）。重启恢复用它判断"磁盘上这条 pending 其实已经送达"，
    /// 不再只看本地 pending 行。
    func confirmedRecord(
        scope: String, sessionId: String, clientId: String
    ) async throws -> SessionRecord? {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT payload FROM record
                WHERE scope = ? AND session_id = ? AND source_id = ? AND status != 'pending'
                ORDER BY seq DESC LIMIT 1
                """, arguments: [scope, sessionId, clientId])
            return try Self.decode(rows).first
        }
    }

    /// 某 seq 之前的一页（降序取、返回升序），向上翻页用。
    public func windowBefore(
        scope: String, sessionId: String, seq: Int, limit: Int
    ) async throws -> [SessionRecord] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT payload FROM record
                WHERE scope = ? AND session_id = ? AND seq < ?
                ORDER BY seq DESC LIMIT ?
                """, arguments: [scope, sessionId, seq, limit])
            return try Self.decode(rows).reversed()
        }
    }

    /// 列表页：一次查询出全部会话聚合（冷启动零网络的关键）。
    public func sessionStates(scope: String) async throws -> [SessionListEntry] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, oldest_seq, newest_seq, has_more, last_opened,
                       last_snippet, unread_count, ranges_json
                FROM session_state WHERE scope = ?
                ORDER BY newest_seq DESC
                """, arguments: [scope])
            return rows.map { row in
                let rangesJSON: String = row["ranges_json"] ?? "[]"
                return SessionListEntry(
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
    }

    /// 持久化某会话的区间集（冷启动预取判定用，data-model「ranges_json」）。
    public func saveRanges(scope: String, sessionId: String, ranges: RangeIndex) async throws {
        let json = String(decoding: try JSONEncoder().encode(ranges.spans), as: UTF8.self)
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE session_state SET ranges_json = ?
                WHERE scope = ? AND session_id = ?
                """, arguments: [json, scope, sessionId])
        }
    }

    /// 带版本的已知为空结论（一次写入即替换该会话其它版本）。
    public struct KnownEmptyRecord: Sendable, Equatable {
        public let revision: String
        public let spans: [ClosedRange<Int>]
        public init(revision: String, spans: [ClosedRange<Int>]) {
            self.revision = revision
            self.spans = spans
        }
    }

    public func saveKnownEmpty(scope: String, sessionId: String, revision: String,
                               spans: [ClosedRange<Int>], observedAt: TimeInterval) async throws {
        guard !spans.isEmpty else { return }
        try await pool.write { db in
            // 只保留当前版本：宿主重排号段后旧结论失效，留着只会误导。
            try db.execute(sql: """
                DELETE FROM known_empty
                WHERE scope = ? AND session_id = ? AND revision <> ?
                """, arguments: [scope, sessionId, revision])
            for span in spans {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO known_empty
                      (scope, session_id, revision, start_seq, end_seq, observed_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [scope, sessionId, revision,
                                     span.lowerBound, span.upperBound, observedAt])
            }
        }
    }

    public func knownEmpty(scope: String, sessionId: String) async throws -> [KnownEmptyRecord] {
        try await pool.read { db in
            var byRevision: [String: [ClosedRange<Int>]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT revision, start_seq, end_seq FROM known_empty
                WHERE scope = ? AND session_id = ?
                ORDER BY revision, start_seq
                """, arguments: [scope, sessionId])
            for row in rows {
                let revision: String = row["revision"]
                byRevision[revision, default: []].append(row["start_seq"]...row["end_seq"])
            }
            return byRevision.map { KnownEmptyRecord(revision: $0.key, spans: $0.value) }
        }
    }

    /// 更新「还有更早」标志（网络侧权威值；失败永不写这里，spec 007 FR-038 语义沿用）。
    func setHasMore(_ hasMore: Bool, scope: String, sessionId: String) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE session_state SET has_more = ?
                WHERE scope = ? AND session_id = ?
                """, arguments: [hasMore, scope, sessionId])
        }
    }

    // MARK: - 用户输入记录（T034：「我问过的」读侧，role='me' + 来源排除）

    /// 「我问过的」归类条件（data-model.md v3）：来源不是用户本人（plugin/system）
    /// 或代理代发（source_id 带 `agent-` 前缀）都不算；source_kind 缺省（老数据）
    /// 按 'user' 兼容。与连接器 `roleOf()` 同一口径。
    static let userInputFilter = """
        role = 'me'
          AND COALESCE(source_kind, 'user') = 'user'
          AND (source_id IS NULL OR source_id NOT LIKE 'agent-%')
        """

    /// 「我问过的」一行：SessionRecord 本体不带 sessionId，列表/搜索按会话
    /// 过滤要用，查询时一并投影出来。
    public struct UserInputEntry: Sendable {
        public let sessionId: String
        public let record: SessionRecord

        public init(sessionId: String, record: SessionRecord) {
            self.sessionId = sessionId
            self.record = record
        }
    }

    /// 用户输入全文搜索（record_fts，FTS5 trigram，本地唯一使用 FTS 的地方）。
    /// trigram 索引需要 ≥3 字符，短查询降级 LIKE 子串（用户输入量小，代价可忽略）。
    /// 返回按 seq 降序（由近及远），最多 200 条。
    public func searchUserInputRecords(scope: String, query: String) async throws -> [UserInputEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await pool.read { db in
            let rows: [Row]
            if trimmed.count >= 3 {
                rows = try Row.fetchAll(db, sql: """
                    SELECT r.session_id, r.payload FROM record_fts f
                    JOIN record r ON r.rowid = f.rowid
                    WHERE record_fts MATCH ? AND r.scope = ?
                      AND \(Self.sessionContent("r"))
                      AND COALESCE(r.source_kind, 'user') = 'user'
                      AND (r.source_id IS NULL OR r.source_id NOT LIKE 'agent-%')
                    ORDER BY r.seq DESC LIMIT 200
                    """, arguments: [trimmed, scope])
            } else {
                let pattern = "%" + trimmed
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_") + "%"
                rows = try Row.fetchAll(db, sql: """
                    SELECT session_id, payload FROM record
                    WHERE scope = ? AND \(Self.sessionContent()) AND \(Self.userInputFilter)
                      AND \(Self.ftsTextExpr("payload"))
                          LIKE ? ESCAPE '\\'
                    ORDER BY seq DESC LIMIT 200
                    """, arguments: [scope, pattern])
            }
            return Self.decodeEntries(rows)
        }
    }


    /// 「我问过的」候选记录（完整 SessionRecord），按会话、seq 升序。
    public func userInputRecords(scope: String) async throws -> [UserInputEntry] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, payload FROM record
                WHERE scope = ? AND \(Self.sessionContent()) AND \(Self.userInputFilter)
                ORDER BY session_id ASC, seq ASC
                """, arguments: [scope])
            return Self.decodeEntries(rows)
        }
    }

    // MARK: - 测试出口（internal，仅 DSHKitTests 用；不进产品面）

    /// FTS 行数（诊断用）。
    func ftsCountForTesting() async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_fts") ?? -1
        }
    }

    /// 全库表名清单（T035 迁移断言用）。
    func tableNamesForTesting() async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
    }

    func rolesForTesting(scope: String, sessionId: String) async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT role FROM record
                WHERE scope = ? AND session_id = ? ORDER BY seq ASC
                """, arguments: [scope, sessionId])
        }
    }

    /// source 列直查（T032 单测用）：(source_kind, source_id) 按 seq 升序。
    func sourcesForTesting(scope: String, sessionId: String) async throws -> [(String?, String?)] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source_kind, source_id FROM record
                WHERE scope = ? AND session_id = ? ORDER BY seq ASC
                """, arguments: [scope, sessionId]).map { row -> (String?, String?) in
                    let kind: String? = row["source_kind"]
                    let sourceId: String? = row["source_id"]
                    return (kind, sourceId)
                }
        }
    }

    // MARK: - 内部工具

    private static func decodeEntries(_ rows: [Row]) -> [UserInputEntry] {
        let decoder = JSONDecoder()
        return rows.compactMap { row -> UserInputEntry? in
            guard let sessionId: String = row["session_id"],
                  let payload: Data = row["payload"],
                  let record = try? decoder.decode(SessionRecord.self, from: payload)
            else { return nil }
            return UserInputEntry(sessionId: sessionId, record: record)
        }
    }

    private static func decode(_ rows: [Row]) throws -> [SessionRecord] {
        let decoder = JSONDecoder()
        return try rows.compactMap { row -> SessionRecord? in
            guard let payload: Data = row["payload"] else { return nil }
            return try decoder.decode(SessionRecord.self, from: payload)
        }
    }

    /// 列表摘要：从编码后的 record 里提取一行纯文本。
    /// 只读 JSONValue 的两个常见字段（text / blocks[].text），不引入 Timeline
    /// 的折叠语义——摘要不需要完整还原。
    static func snippet(of payload: Data) -> String? {
        guard
            let record = try? JSONDecoder().decode(SessionRecord.self, from: payload)
        else { return nil }
        let data = record.event.data
        if let text = data["text"]?.stringValue, !text.isEmpty {
            return String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
        }
        if let blocks = data["blocks"]?.arrayValue {
            let joined = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: " ")
            if !joined.isEmpty {
                return String(joined.replacingOccurrences(of: "\n", with: " ").prefix(120))
            }
        }
        return nil
    }
}

import Foundation
import GRDB

/// GRDB 版磁盘层（spec 009 research D1 / data-model）。
///
/// 定位：**纯缓存**，不是事实来源——崩丢由「取用失败即拉取」兜底（owner 已拍板），
/// 所以这里的写入全部来自内存层的批量队列（`PendingWriteQueue`），不追求实时。
/// 取代 007 的手写 `TranscriptStore`（T027 删除旧层）；旧库不迁移，从空库建 v2。
///
/// 并发：`DatabasePool`（WAL，多读一写）天然匹配「读多写少、单写者」；
/// 本 actor 只负责把我们自己的调用串行成一个域（宪法：层内一个串行域）。
public actor MessageStore {

    /// 一次落库变更（上行 pending / 下行记录共用）。
    public enum RecordChange: Sendable {
        /// 新到/更新的一批记录（同一 session）。
        case upsertRecords(scope: String, sessionId: String, records: [SessionRecord])
        /// 发送中的乐观记录（pending），`clientId` 是手机侧稳定身份。
        case upsertPending(scope: String, sessionId: String, clientId: String, record: SessionRecord)
        /// 服务端确认：pending 记录换成正式记录。
        case confirmPending(scope: String, sessionId: String, clientId: String, record: SessionRecord)
    }

    /// 列表页一行（session_state 的投影）。
    public struct SessionListEntry: Sendable, Equatable {
        public let sessionId: String
        public let oldestSeq: Int?
        public let newestSeq: Int?
        public let hasMore: Bool
        public let lastSnippet: String?
        public let unreadCount: Int
        public let lastOpened: Date
        /// 冷启动预取判定用的有效连续区间（spec §6），JSON 序列化存储。
        public let ranges: RangeIndex
    }

    /// 传输类型 → 三角色（映射沿用连接器 `roleOf()`，spec「用户输入全量入库」）。
    public enum Role: String, Sendable {
        case me, agent, tool, other

        public init(eventType: String) {
            switch eventType {
            case "user/message": self = .me
            case "assistant/message": self = .agent
            case "tool/call", "tool/result": self = .tool
            default: self = .other
            }
        }
    }

    // internal 而非 private：读写半边在 MessageStore+Records.swift（职责拆分，
    // 两个文件都在 500 行以内），模块外不可见。
    let pool: DatabasePool
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - path: 数据库文件路径；默认 `<caches>/message-store/messages.sqlite3`。
    ///     测试传临时目录（宪法 III：不碰真实数据）。
    public init(path: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) throws {
        let url = path ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("message-store", isDirectory: true)
            .appendingPathComponent("messages.sqlite3")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        self.now = now
        try MessageStore.migrator.migrate(pool)
    }

    // MARK: - Schema（GRDB DatabaseMigrator：v2 建表，v3 加 source 列，v3-cleanup 三表终局）

    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v2") { db in try createSchemaV2(db) }
        migrator.registerMigration("v3") { db in try migrateToV3(db) }
        migrator.registerMigration("v3-user-inputs-cleanup") { db in try migrateToV3Cleanup(db) }
        migrator.registerMigration("v3-fts-reindex") { db in try reindexRecordFts(db) }
        migrator.registerMigration("v3-fts-blocks-text") { db in try migrateToV3BlocksText(db) }
        migrator.registerMigration("v3-aggregate-excludes-pending") { db in
            try repairAggregatesExcludingPending(db)
        }
        return migrator
    }()

    /// record_fts 的正文提取式：用户消息有两种形态——旧的 `data.text` 直挂，
    /// 以及 blocks 形态 `data.content[0].text`（现行 user/message 都是后者）。
    /// ebfc76e 只修了 event 包层，仍取 `$.event.data.text`，真实数据索引全是空串。
    /// 四处（触发器 / 清理迁移回填 / 本重建 / LIKE 降级）必须共用同一式。
    /// 参数 `column` 在触发器里是 `new.payload`/`old.payload`，查询里是 `payload`。
    static func ftsTextExpr(_ column: String) -> String {
        """
        COALESCE(NULLIF(json_extract(CAST(\(column) AS TEXT), '$.event.data.text'), ''), \
        json_extract(CAST(\(column) AS TEXT), '$.event.data.content[0].text'), '')
        """
    }

    static func createSchemaV2(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS meta (
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS record (
              scope      TEXT    NOT NULL,
              session_id TEXT    NOT NULL,
              seq        INTEGER NOT NULL,
              kind       TEXT    NOT NULL,
              role       TEXT    NOT NULL,
              payload    BLOB    NOT NULL,
              byte_size  INTEGER NOT NULL,
              client_id  TEXT,
              status     TEXT    NOT NULL DEFAULT 'sent',
              PRIMARY KEY (scope, session_id, seq)
            );
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session_state (
              scope        TEXT    NOT NULL,
              session_id   TEXT    NOT NULL,
              oldest_seq   INTEGER,
              newest_seq   INTEGER,
              has_more     INTEGER NOT NULL DEFAULT 1,
              last_opened  REAL    NOT NULL,
              last_snippet TEXT,
              unread_count INTEGER NOT NULL DEFAULT 0,
              ranges_json  TEXT    NOT NULL DEFAULT '[]',
              PRIMARY KEY (scope, session_id)
            );
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS user_inputs (
              scope      TEXT    NOT NULL,
              session_id TEXT    NOT NULL,
              seq        INTEGER NOT NULL,
              snippet    TEXT    NOT NULL,
              pulled_at  REAL    NOT NULL,
              PRIMARY KEY (scope, session_id, seq)
            );
            """)
        // T024 灌库去重账本：每会话记 pulled_at 与当时见到的 last_seq，
        // 24h 内且 lastSeq 没变就跳过（UserInputBackfiller 的判定依据）。
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS user_input_state (
              scope      TEXT    NOT NULL,
              session_id TEXT    NOT NULL,
              pulled_at  REAL    NOT NULL,
              last_seq   INTEGER NOT NULL,
              PRIMARY KEY (scope, session_id)
            );
            """)
        // trigram：unicode61 不会切中文（整段当一个词），子串搜索会全空。
        // trigram 需要查询 ≥3 字符，短查询在读取侧降级 LIKE（见 searchUserInputs）。
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS user_inputs_fts
            USING fts5(snippet, content=user_inputs, content_rowid=rowid, tokenize='trigram');
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS user_inputs_ai AFTER INSERT ON user_inputs BEGIN
              INSERT INTO user_inputs_fts(rowid, snippet) VALUES (new.rowid, new.snippet);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS user_inputs_ad AFTER DELETE ON user_inputs BEGIN
              INSERT INTO user_inputs_fts(user_inputs_fts, rowid, snippet)
              VALUES ('delete', old.rowid, old.snippet);
            END;
            """)
    }

    /// v3（data-model.md v3 / tasks T032）：`record` 加 `source_kind`/`source_id`。
    /// 老行回填：payload 里 `data.source.kind` 能解析按解析值，解析不出或缺省按 `'user'`
    ///（与连接器侧同一兼容口径）；`source_id` 取 `data.source.rpcId`，缺省留空。
    static func migrateToV3(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE record ADD COLUMN source_kind TEXT")
        try db.execute(sql: "ALTER TABLE record ADD COLUMN source_id TEXT")
        let rows = try Row.fetchAll(db, sql: "SELECT rowid, payload FROM record")
        let decoder = JSONDecoder()
        for row in rows {
            guard let payload: Data = row["payload"],
                  let record = try? decoder.decode(SessionRecord.self, from: payload)
            else { continue }  // 解析不出的行留给下面的兜底 UPDATE 置 'user'
            let source = record.event.data["source"]
            try db.execute(
                sql: "UPDATE record SET source_kind = ?, source_id = ? WHERE rowid = ?",
                arguments: [source?["kind"]?.stringValue, source?["rpcId"]?.stringValue, row["rowid"]])
        }
        try db.execute(sql: "UPDATE record SET source_kind = 'user' WHERE source_kind IS NULL")
    }

    /// v3 终局清理（data-model.md v3 / tasks T034/T035）：
    /// 1. `session_state` 加 `user_inputs_synced_at`（用户输入子集灌全的完整性标记）；
    /// 2. 旧 `user_inputs` / `user_inputs_fts` / `user_input_state` 三表**直接弃置删表**
    ///    ——摘要行没有 source，是纯缓存，并入 record 就是脏数据（owner 2026-10-11 定稿），
    ///    回填任务会按新模型重拉；
    /// 3. `record_fts`（FTS5 trigram）挂 `record`，触发器只索引 `role='me'` 的行
    ///    （用户输入的本地搜索；助手/工具内容不进索引，控制体积），存量行同步回填。
    static func migrateToV3Cleanup(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE session_state ADD COLUMN user_inputs_synced_at REAL")
        try db.execute(sql: "DROP TABLE IF EXISTS user_inputs_fts")
        try db.execute(sql: "DROP TABLE IF EXISTS user_inputs")
        try db.execute(sql: "DROP TABLE IF EXISTS user_input_state")
        // trigram：unicode61 不会切中文（整段当一个词）。索引文本从 payload 里
        // 就地提取（两种正文形态见 ftsTextExpr）；写入侧保证 payload 恒为合法
        // JSON，json_extract 不会失败。
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS record_fts
            USING fts5(text, tokenize='trigram');
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS record_fts_ai AFTER INSERT ON record
            WHEN new.role = 'me' BEGIN
              INSERT INTO record_fts(rowid, text) VALUES (
                new.rowid, \(ftsTextExpr("new.payload")));
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS record_fts_ad AFTER DELETE ON record
            WHEN old.role = 'me' BEGIN
              DELETE FROM record_fts WHERE rowid = old.rowid;
            END;
            """)
        // 存量 me 行回填索引（迁移前写入的 record 不会触发上面的 INSERT 触发器）。
        try db.execute(sql: """
            INSERT INTO record_fts(rowid, text)
            SELECT rowid, \(ftsTextExpr("payload"))
            FROM record WHERE role = 'me' AND json_valid(CAST(payload AS TEXT));
            """)
    }

    /// v3-fts-reindex：v3-cleanup 首版的 JSON 路径写错（$.data.text，payload 实际
    /// 是 {"event": {...}}），已迁移过的库里索引全是空串。整表清掉按正确路径重建。
    static func reindexRecordFts(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM record_fts")
        try db.execute(sql: """
            INSERT INTO record_fts(rowid, text)
            SELECT rowid, \(ftsTextExpr("payload"))
            FROM record WHERE role = 'me' AND json_valid(CAST(payload AS TEXT));
            """)
    }

    /// v3-fts-blocks-text：真实 user/message 的正文在 `data.content[0].text`
    /// （blocks 形态），`$.event.data.text` 只对旧形态有值——前两步迁移建出来的
    /// 触发器与索引对真实数据仍全是空串（T036 慢闸在仿真器真库里抓出）。
    /// 已应用过旧迁移的库：换触发器定义 + 整表再重建。
    static func migrateToV3BlocksText(_ db: Database) throws {
        try db.execute(sql: "DROP TRIGGER IF EXISTS record_fts_ai")
        try db.execute(sql: """
            CREATE TRIGGER record_fts_ai AFTER INSERT ON record
            WHEN new.role = 'me' BEGIN
              INSERT INTO record_fts(rowid, text) VALUES (
                new.rowid, \(ftsTextExpr("new.payload")));
            END;
            """)
        try reindexRecordFts(db)
    }

    /// v3-aggregate-excludes-pending：修**已经写坏**的聚合列。
    ///
    /// 写入侧原来把 pending 行一起算进 MIN/MAX(seq)，而 pending 的 seq 是
    /// `MessagePipeline` 的合成游标（从 `Int.max` 起递减）。任何一次"发出去但没等到
    /// 确认"（App 被杀、断网、确认丢失）都会把 `session_state.newest_seq` 留成
    /// 9223372036854775807，下一次冷启动预取拿它算页边界就整数溢出崩溃
    ///（TestFlight 20261012.1310）。改了写入侧只保证新写的对，老库里那行还在，
    /// 所以这里按"排除 pending"的口径把两个边界列重算一遍。一次性、幂等。
    static func repairAggregatesExcludingPending(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE session_state SET
              oldest_seq = (SELECT MIN(seq) FROM record
                            WHERE record.scope = session_state.scope
                              AND record.session_id = session_state.session_id
                              AND record.status != 'pending'),
              newest_seq = (SELECT MAX(seq) FROM record
                            WHERE record.scope = session_state.scope
                              AND record.session_id = session_state.session_id
                              AND record.status != 'pending')
            """)
    }
}

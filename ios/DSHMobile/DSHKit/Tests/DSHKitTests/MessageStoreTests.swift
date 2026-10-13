@testable import DSHKit
import GRDB
import XCTest

/// GRDB 磁盘层（spec 009 data-model / tasks T004/T005）：
/// 建库、区间读写、角色映射、pending 确认替换、列表聚合、用户输入 FTS。
final class MessageStoreTests: XCTestCase {

    private var directory: URL!
    private var store: MessageStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-store-tests-\(UUID().uuidString)")
        store = try MessageStore(path: directory.appendingPathComponent("test.sqlite3"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ seq: Int, type: String = "assistant/message",
                        text: String = "hello", source: String? = nil) -> SessionRecord {
        // SessionEvent 的 memberwise init 是 internal（models 按解码入口设计），
        // 测试沿用 007 的做法：从 JSON 解码构造。
        let sourceJSON = source.map { ",\"source\":\($0)" } ?? ""
        let json = #"{"type":"\#(type)","seq":\#(seq),"time":1789276358732,"data":{"text":"\#(text)"\#(sourceJSON)}}"#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    private func upsert(_ records: [SessionRecord], session: String = "s1") async throws {
        try await store.applyWrites([
            .upsertRecords(scope: "mac", sessionId: session, records: records)
        ])
    }

    func testRoundTripByRange() async throws {
        try await upsert([record(1), record(2), record(3), record(4)])
        let records = try await store.records(scope: "mac", sessionId: "s1", in: 2...3)
        XCTAssertEqual(records.map(\.event.seq), [2, 3])
    }

    func testWindowBeforeReturnsAscending() async throws {
        try await upsert((1...10).map { record($0) })
        let page = try await store.windowBefore(scope: "mac", sessionId: "s1", seq: 8, limit: 3)
        XCTAssertEqual(page.map(\.event.seq), [5, 6, 7])
    }

    func testRoleMappingFollowsConnector() async throws {
        try await upsert([
            record(1, type: "user/message"),
            record(2, type: "assistant/message"),
            record(3, type: "tool/call"),
        ])
        // role 列本身不进投影，用 user_inputs 之外的校验方式：直接查库。
        let roles = try await store.rolesForTesting(scope: "mac", sessionId: "s1")
        XCTAssertEqual(roles, ["me", "agent", "tool"])
    }

    /// 发送链路（spec US5）：pending 先入，确认后原地替换，库里只剩一条 sent。
    func testPendingConfirmReplacesInPlace() async throws {
        try await store.applyWrites([
            .upsertPending(scope: "mac", sessionId: "s1", clientId: "c-1", record: record(5, type: "user/message")),
        ])
        try await store.applyWrites([
            .confirmPending(scope: "mac", sessionId: "s1", clientId: "c-1", record: record(5, type: "user/message")),
        ])
        let records = try await store.records(scope: "mac", sessionId: "s1", in: 1...10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.event.seq, 5)
    }

    func testSessionStatesAggregateForColdStart() async throws {
        try await upsert([record(1, text: "first"), record(2, text: "second")], session: "s1")
        try await upsert([record(1, text: "other")], session: "s2")
        let states = try await store.sessionStates(scope: "mac")
        XCTAssertEqual(states.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(states[0].newestSeq, 2)
        XCTAssertEqual(states[0].lastSnippet, "second")
        XCTAssertEqual(states[0].hasMore, true)  // 默认 true：失败永不写 hasMore
    }

    /// 自愈迁移（`v3-aggregate-excludes-pending`）：老库里被 pending 合成 seq 抬高的
    /// 聚合列，要按"排除 pending"的口径重算。这里造一个"迁移前就写坏"的库来验
    ///（TestFlight 20261012.1310 的崩溃根因之一，见 UntrustedCursorTests 头注）。
    func testMigrationRepairsAggregateRaisedByPendingSyntheticSeq() async throws {
        let path = directory.appendingPathComponent("legacy.sqlite3")
        let pool = try DatabasePool(path: path.path)
        // 只跑到自愈之前那一步，模拟旧版本的库。
        try MessageStore.migrator.migrate(pool, upTo: "v3-fts-blocks-text")
        let sent = record(5)
        let pending = record(Int.max, type: "user/message")
        try await pool.write { db in
            let encoder = JSONEncoder()
            func insertRecord(_ record: SessionRecord, status: String, clientId: String?) throws {
                let payload = try encoder.encode(record)
                try db.execute(sql: """
                    INSERT INTO record (scope, session_id, seq, kind, role, payload, byte_size,
                                        client_id, status, source_kind, source_id)
                    VALUES ('mac', 's1', ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                    """, arguments: [
                        record.event.seq, record.event.type,
                        MessageStore.Role(eventType: record.event.type).rawValue,
                        payload, payload.count, clientId, status,
                    ])
            }
            try insertRecord(sent, status: "sent", clientId: nil)
            try insertRecord(pending, status: "pending", clientId: "c-1")
            // 老版本的聚合行：MAX(seq) 把 pending 的合成 seq 算了进来。
            try db.execute(sql: """
                INSERT INTO session_state (scope, session_id, oldest_seq, newest_seq, has_more,
                                           last_opened, last_snippet, unread_count, ranges_json)
                VALUES ('mac', 's1', 5, ?, 1, 0, '', 0, '[]')
                """, arguments: [Int.max])
        }
        // 跑剩下的迁移，然后按正常路径读聚合。
        try MessageStore.migrator.migrate(pool)
        let reopened = try MessageStore(path: path)
        let states = try await reopened.sessionStates(scope: "mac")
        XCTAssertEqual(states.first?.newestSeq, 5, "自愈后游标必须回到真实最大 seq")
        XCTAssertEqual(states.first?.oldestSeq, 5)
    }

    /// 区间集随会话持久化（data-model ranges_json）：冷启动预取判定靠它。
    func testRangesRoundTrip() async throws {
        try await upsert([record(1)])
        var ranges = RangeIndex()
        ranges.insert(100...200)
        ranges.insert(400...450)
        try await store.saveRanges(scope: "mac", sessionId: "s1", ranges: ranges)
        let states = try await store.sessionStates(scope: "mac")
        XCTAssertEqual(states.first?.ranges.spans, [.init(100, 200), .init(400, 450)])
    }

    /// T034：「我问过的」读 record 本体——浏览全量、FTS（≥3 字符）与 LIKE（短词）搜索。
    func testUserInputRecordsBrowseAndSearch() async throws {
        try await upsert([
            record(10, type: "user/message", text: "怎么部署到服务器"),
            record(20, type: "user/message", text: "写个单元测试"),
        ], session: "s1")
        try await upsert([
            record(5, type: "user/message", text: "部署文档在哪"),
        ], session: "s2")
        let all = try await store.userInputRecords(scope: "mac")
        XCTAssertEqual(all.map { $0.record.event.seq }, [10, 20, 5])
        XCTAssertEqual(all.map(\.sessionId), ["s1", "s1", "s2"])
        // trigram（≥3 字符走 FTS5，子串命中）。
        let hits = try await store.searchUserInputRecords(scope: "mac", query: "部署到")
        XCTAssertEqual(hits.map { $0.record.event.seq }, [10])
        // 短查询（<3 字符）降级 LIKE。
        let short = try await store.searchUserInputRecords(scope: "mac", query: "测试")
        XCTAssertEqual(short.map { $0.record.event.seq }, [20])
    }

    /// record_fts 只索引 role='me' 的行：助手消息不进索引（data-model v3）。
    func testRecordFtsIndexesOnlyMe() async throws {
        try await upsert([
            record(1, type: "user/message", text: "共同关键词甲乙丙"),
            record(2, type: "assistant/message", text: "共同关键词甲乙丙的回答"),
        ])
        let hits = try await store.searchUserInputRecords(scope: "mac", query: "甲乙丙")
        XCTAssertEqual(hits.map { $0.record.event.seq }, [1])
    }

    /// blocks 形态（真实 user/message：正文在 data.content[0].text，没有 data.text）：
    /// FTS（≥3 字符）与 LIKE 降级（短词）都要命中——线上库曾因此整索引空串（T036）。
    func testRecordFtsExtractsBlocksFormContent() async throws {
        let json = #"{"type":"user/message","seq":9,"time":1789276358732,"data":{"content":[{"type":"text","text":"整理下今天的推特热闻"}],"source":{"kind":"user","rpcId":"r-1"}}}"#
        let event = try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        try await upsert([SessionRecord(event: event)])
        let hits = try await store.searchUserInputRecords(scope: "mac", query: "推特热")
        XCTAssertEqual(hits.map { $0.record.event.seq }, [9])
        let short = try await store.searchUserInputRecords(scope: "mac", query: "推特")
        XCTAssertEqual(short.map { $0.record.event.seq }, [9])
        // 直挂 data.text 的旧形态仍可用（fixture 的 record() 就是这条路径，上面已覆盖）。
    }

    // MARK: - T032：source 列

    /// 写入路径从 data.source 提取 source_kind/source_id；缺省（老数据形态）留空，
    /// 查询侧按 'user' 兼容（data-model.md v3）。
    func testSourceColumnsWrittenOnInsert() async throws {
        try await upsert([
            record(1, type: "user/message", source: #"{"kind":"plugin","rpcId":"rpc-9"}"#),
            record(2, type: "user/message", source: #"{"kind":"user","rpcId":"rpc-1"}"#),
            record(3, type: "user/message"),  // 缺省：无 source 字段
        ])
        let sources = try await store.sourcesForTesting(scope: "mac", sessionId: "s1")
        XCTAssertEqual(sources.map(\.0), ["plugin", "user", nil])
        XCTAssertEqual(sources.map(\.1), ["rpc-9", "rpc-1", nil])
    }

    /// 「我问过的」归类边界（T035）：只要用户本人发的；plugin/system 注入、
    /// agent- 前缀的代理代发都排除；source 缺省（老数据）按 'user' 兼容——
    /// 与连接器 `roleOf()` 同一口径。
    func testUserInputRecordsExcludePluginAndAgentRelay() async throws {
        try await upsert([
            record(1, type: "user/message", source: #"{"kind":"plugin","rpcId":"rpc-9"}"#),
            record(2, type: "user/message", source: #"{"kind":"user","rpcId":"agent-42"}"#),
            record(3, type: "user/message", source: #"{"kind":"user","rpcId":"rpc-1"}"#),
            record(4, type: "user/message"),  // 缺省按 'user'
            record(5, type: "assistant/message"),
            record(6, type: "user/message", source: #"{"kind":"system"}"#),
            record(7, type: "user/message", source: #"{"kind":"user"}"#),  // 无 rpcId 也算本人
        ])
        let records = try await store.userInputRecords(scope: "mac")
        XCTAssertEqual(records.map { $0.record.event.seq }, [3, 4, 7])
        // FTS 搜索同口径：注入行即使被索引也不在结果里。
        let hits = try await store.searchUserInputRecords(scope: "mac", query: "hello")
        XCTAssertEqual(hits.map { $0.record.event.seq }, [7, 4, 3])
    }

    /// v2→v3 迁移：老行按 payload 回填，解析不出/缺 source 的按 'user'。
    func testMigrationBackfillsSourceOnOldRows() async throws {
        let url = directory.appendingPathComponent("old.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldPool = try DatabasePool(path: url.path)
        // 预先构造好 payload（write 闭包是 @Sendable，不抓 self）。
        let payloads = try (1...2).map { seq -> Data in
            let source = seq == 1 ? #"{"kind":"plugin","rpcId":"rpc-7"}"# : nil
            return try JSONEncoder().encode(self.record(seq, type: "user/message", source: source))
        }
        try await oldPool.write { db in
            try db.execute(sql: """
                CREATE TABLE record (
                  scope TEXT NOT NULL, session_id TEXT NOT NULL, seq INTEGER NOT NULL,
                  kind TEXT NOT NULL, role TEXT NOT NULL, payload BLOB NOT NULL,
                  byte_size INTEGER NOT NULL, client_id TEXT,
                  status TEXT NOT NULL DEFAULT 'sent',
                  PRIMARY KEY (scope, session_id, seq));
                """)
            for (index, payload) in payloads.enumerated() {
                try db.execute(sql: """
                    INSERT INTO record (scope, session_id, seq, kind, role, payload, byte_size, status)
                    VALUES ('mac', 's1', ?, 'user/message', 'me', ?, ?, 'sent')
                    """, arguments: [index + 1, payload, payload.count])
            }
            // 解析不出的脏 payload：回填必须兜底 'user'。
            try db.execute(sql: """
                INSERT INTO record (scope, session_id, seq, kind, role, payload, byte_size, status)
                VALUES ('mac', 's1', 3, 'user/message', 'me', X'DEAD', 2, 'sent')
                """)
        }
        try await oldPool.close()

        let migrated = try MessageStore(path: url)
        let sources = try await migrated.sourcesForTesting(scope: "mac", sessionId: "s1")
        XCTAssertEqual(sources.map(\.0), ["plugin", "user", "user"])
        XCTAssertEqual(sources.map(\.1), ["rpc-7", nil, nil])
    }

    // MARK: - T035：v2→v3 终局清理

    /// 旧 `user_inputs` 摘要数据**不并入** record（没有 source 的摘要行是脏数据来源，
    /// 纯缓存弃置删表，回填会按新模型重拉）；三表删除；synced 列补上。
    func testMigrationDropsUserInputTablesWithoutMerging() async throws {
        let url = directory.appendingPathComponent("legacy.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldPool = try DatabasePool(path: url.path)
        try await oldPool.write { db in
            // v2 形态的脏数据：一条 plugin 注入的摘要（混进「我问过的」的来源）。
            try db.execute(sql: """
                CREATE TABLE user_inputs (
                  scope TEXT NOT NULL, session_id TEXT NOT NULL, seq INTEGER NOT NULL,
                  snippet TEXT NOT NULL, pulled_at REAL NOT NULL,
                  PRIMARY KEY (scope, session_id, seq));
                """)
            try db.execute(sql: """
                INSERT INTO user_inputs VALUES ('mac', 's1', 7, '插件注入的假提问', 0)
                """)
            try db.execute(sql: """
                CREATE TABLE user_input_state (
                  scope TEXT NOT NULL, session_id TEXT NOT NULL,
                  pulled_at REAL NOT NULL, last_seq INTEGER NOT NULL,
                  PRIMARY KEY (scope, session_id));
                """)
            try db.execute(sql: """
                INSERT INTO user_input_state VALUES ('mac', 's1', 0, 7)
                """)
        }
        try await oldPool.close()

        let migrated = try MessageStore(path: url)
        // 三表已删。
        let tables = try await migrated.tableNamesForTesting()
        XCTAssertFalse(tables.contains("user_inputs"), "user_inputs 必须删表")
        XCTAssertFalse(tables.contains("user_inputs_fts"))
        XCTAssertFalse(tables.contains("user_input_state"))
        // 脏摘要没有混进 record。
        let records = try await migrated.records(scope: "mac", sessionId: "s1", in: 1...100)
        XCTAssertTrue(records.isEmpty, "旧 user_inputs 数据不得并入 record")
        // synced 列存在（能读 nil 而不是报错）。
        let synced = try await migrated.userInputsSyncedAt(scope: "mac", sessionId: "s1")
        XCTAssertNil(synced)
        // 新账本在 meta 键值表里能读写。
        try await migrated.saveUserInputSyncState(
            scope: "mac", sessionId: "s1",
            state: .init(pulledAt: Date(timeIntervalSince1970: 1_800_000_000), lastSeq: 42))
        let state = try await migrated.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.lastSeq, 42)
    }
}

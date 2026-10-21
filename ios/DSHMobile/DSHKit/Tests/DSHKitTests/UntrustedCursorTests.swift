@testable import DSHKit
import XCTest

/// 外部游标的极端值防御（2026-10-13 TestFlight 崩溃回归）。
///
/// 事故链：本地乐观上行用合成 seq（`nextSyntheticSeq` 从 `Int.max` 起递减）→ 落库为
/// `status='pending'` → 会话聚合列 `MAX(seq)` 把它算进 `session_state.newest_seq` →
/// 冷启动预取拿这个游标算页边界 → `start + pageSize - 1` 整数溢出 SIGTRAP
///（build 20261012.1310，`SessionPipeline+Paging.swift:12`）。
///
/// 这个文件钉住三层：聚合列不含 pending、页边界对离谱游标不产页（不 trap）、
/// 整条"磁盘聚合 → 预取"的接缝按真实游标走。Swift 的溢出是 trap 不是异常：
/// 真的越界了，测试进程会直接死掉，也就是红。
final class UntrustedCursorTests: XCTestCase {

    private var directory: URL!
    private var store: MessageStore!
    private let session = MessageSessionRef(scope: "mac", sessionId: "s1")

    /// 记录取页请求的取页器（预取是 fire-and-forget，用 actor 收）。
    private actor RequestLog {
        private(set) var ranges: [ClosedRange<Int>] = []
        func note(_ range: ClosedRange<Int>) { ranges.append(range) }
        func all() -> [ClosedRange<Int>] { ranges }
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("untrusted-cursor-tests-\(UUID().uuidString)")
        store = try MessageStore(path: directory.appendingPathComponent("test.sqlite3"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ seq: Int, type: String = "assistant/message") -> SessionRecord {
        let json = #"{"type":"\#(type)","seq":\#(seq),"time":1789276358732,"data":{"text":"hi"}}"#
        return SessionRecord(event: try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8)))
    }

    private func makePipeline(log: RequestLog) -> SessionPipeline {
        SessionPipeline(
            scope: "mac", sessionId: "s1", store: nil,
            fetch: { range, _ in
                await log.note(range)
                return SessionPipeline.FetchPage(records: [], hasMore: true, clamped: false)
            })
    }

    // MARK: - 数据层：聚合列不含 pending

    /// 聚合列只认 sent 行：pending 的合成 seq（Int.max）不许抬高新游标。
    func testAggregateCursorIgnoresPendingSyntheticSeq() async throws {
        try await store.applyWrites([.upsertRecords(
            scope: "mac", sessionId: "s1", records: [record(1), record(2)])])
        try await store.applyWrites([.upsertPending(
            scope: "mac", sessionId: "s1", clientId: UUID().uuidString,
            record: record(Int.max, type: "user/message"))])

        let states = try await store.sessionStates(scope: "mac")
        let entry = try XCTUnwrap(states.first)
        XCTAssertEqual(entry.newestSeq, 2, "pending 的合成 seq 不能进 newest_seq")
        XCTAssertEqual(entry.oldestSeq, 1)
    }

    /// 只有 pending 的会话（host 内容一条都没落库）：游标为空，
    /// 让冷启动回退到 host 的 asOfSeq，而不是拿合成 seq 当最新位置。
    func testSessionWithOnlyPendingHasNoCursor() async throws {
        try await store.applyWrites([.upsertPending(
            scope: "mac", sessionId: "s1", clientId: UUID().uuidString,
            record: record(Int.max, type: "user/message"))])
        let states = try await store.sessionStates(scope: "mac")
        let entry = try XCTUnwrap(states.first)
        XCTAssertNil(entry.newestSeq)
        XCTAssertNil(entry.oldestSeq)
    }

    // MARK: - 外部数值：host 下发的 JSON 数字

    /// `Double → Int` 不许 trap：1e30 / NaN / 无穷都按"不是整数"返回 nil。
    /// （原来是 `Int(value)`，这些输入是进程级 SIGTRAP。）
    func testHugeJSONNumberDoesNotTrap() {
        XCTAssertEqual(JSONValue.double(42.0).intValue, 42)
        XCTAssertNil(JSONValue.double(42.5).intValue)
        XCTAssertNil(JSONValue.double(1e30).intValue)
        XCTAssertNil(JSONValue.double(-1e30).intValue)
        XCTAssertNil(JSONValue.double(.nan).intValue)
        XCTAssertNil(JSONValue.double(.infinity).intValue)
        XCTAssertEqual(JSONValue.int(7).intValue, 7)
        // 走真实解码路径（host 回包就是这么进来的）。
        let decoded = try? JSONDecoder().decode(JSONValue.self,
                                                from: Data(#"{"size": 1e30}"#.utf8))
        XCTAssertNil(decoded?["size"]?.intValue)
    }

    // MARK: - 外部输入：磁盘上的 ranges_json

    /// 坏区间 JSON 当解码失败处理：区间集是纯缓存，退化成空集重拉即可，不许 trap。
    func testCorruptRangesJSONDoesNotTrap() async throws {
        XCTAssertThrowsError(try JSONDecoder().decode(
            [RangeIndex.Span].self, from: Data(#"[{"start":9,"end":1}]"#.utf8)))
        XCTAssertNoThrow(try JSONDecoder().decode(
            [RangeIndex.Span].self, from: Data(#"[{"start":1,"end":9}]"#.utf8)))

        try await store.applyWrites([.upsertRecords(
            scope: "mac", sessionId: "s1", records: [record(1)])])
        // 模拟磁盘上被写坏的持久化区间（跨版本、手工改过都算）。
        try await store.pool.write { db in
            try db.execute(sql: """
                UPDATE session_state SET ranges_json = ?
                WHERE scope = 'mac' AND session_id = 's1'
                """, arguments: [#"[{"start":9,"end":1}]"#])
        }
        let states = try await store.sessionStates(scope: "mac")
        let entry = try XCTUnwrap(states.first)
        XCTAssertTrue(entry.ranges.isEmpty, "坏区间按空集处理")
        XCTAssertEqual(entry.newestSeq, 1, "聚合列不受影响")
    }

    // MARK: - 页边界：离谱游标不产页

    /// 崩溃现场的区间（Int.max 附近）与整段离谱区间都不产页；正常游标不受影响。
    /// 这条用例只要跑完就是过：真溢出的话进程已经死了。
    func testPagingRejectsImpossibleCursors() async {
        let log = RequestLog()
        let pipeline = makePipeline(log: log)

        let poisoned = await pipeline.alignedPages(
            covering: RangeIndex.Span(Int.max - 49, Int.max))
        XCTAssertTrue(poisoned.isEmpty)
        let poisonedWhole = await pipeline.alignedPages(covering: RangeIndex.Span(1, Int.max))
        XCTAssertTrue(poisonedWhole.isEmpty)
        let poisonedSingle = await pipeline.alignedPage(containing: Int.max)
        XCTAssertNil(poisonedSingle)
        // 下界沿用原语义：0/负数钳到第 1 页，不当异常值处理。
        let clamped = await pipeline.alignedPage(containing: 0)
        XCTAssertEqual(clamped, 1...50)

        let normal = await pipeline.alignedPages(covering: RangeIndex.Span(51, 120))
        XCTAssertEqual(normal, [51...100, 101...150])
        // 区间下端是合成值 0（顶部合成行）时保持原语义：钳到第 1 页。
        let fromZero = await pipeline.alignedPages(covering: RangeIndex.Span(0, 5))
        XCTAssertEqual(fromZero, [1...50])
        let normalSingle = await pipeline.alignedPage(containing: 7)
        XCTAssertEqual(normalSingle, 1...50)
    }

    /// 一次请求派生的页数有上限：`seqCeiling` 之内的超宽区间也只派 maxPagesPerRequest 页。
    func testPagingCapsPageCount() async {
        let log = RequestLog()
        let pipeline = makePipeline(log: log)
        let pages = await pipeline.alignedPages(
            covering: RangeIndex.Span(1, SessionPipeline.seqCeiling))
        XCTAssertEqual(pages.count, SessionPipeline.maxPagesPerRequest)
        XCTAssertEqual(pages.first, 1...50)
        XCTAssertEqual(pages.last, 25_551...25_600)
    }

    /// 被污染的游标走完整条"取数"路径：返回空、零网络、不 trap。
    func testRecordsWithPoisonedCursorFetchesNothing() async throws {
        let log = RequestLog()
        let pipeline = makePipeline(log: log)
        let records = try await pipeline.records(in: (Int.max - 49)...Int.max, priority: .jump)
        XCTAssertTrue(records.isEmpty)
        let requested = await log.all()
        XCTAssertTrue(requested.isEmpty, "异常游标不该发任何取页请求")
    }

    // MARK: - 接缝：磁盘聚合列 → 冷启动预取

    /// 原来这条缝没人测：写库那层有用 `Int.max` 的用例，消费者那层没有。
    func testColdStartPrefetchUsesRealCursorNotPendingSeq() async throws {
        try await store.applyWrites([.upsertRecords(
            scope: "mac", sessionId: "s1", records: [record(1), record(2)])])
        try await store.applyWrites([.upsertPending(
            scope: "mac", sessionId: "s1", clientId: UUID().uuidString,
            record: record(Int.max, type: "user/message"))])
        let states = try await store.sessionStates(scope: "mac")
        let entry = try XCTUnwrap(states.first)
        let cursor = try XCTUnwrap(entry.newestSeq)
        XCTAssertEqual(cursor, 2)

        let log = RequestLog()
        let pipeline = MessagePipeline(
            store: store,
            fetchFactory: { _ in { range, _ in
                await log.note(range)
                return SessionPipeline.FetchPage(records: [], hasMore: false, clamped: true)
            } },
            sender: { _, _, _, _ in nil },
            now: { 1000 })
        await pipeline.prefetchLatestPages(
            [.init(session: session, newestSeq: cursor)], limit: 1, concurrency: 1)

        let requested = await log.all()
        XCTAssertEqual(requested.count, 1)
        // 取页器拿到的是**对齐页**（1...50），不是请求区间（1...2）；关键是没有被
        // 合成 seq 带到 Int.max 附近去。
        XCTAssertEqual(requested.first, 1...50)
    }

    /// 目标游标本身是 Int.max（老版本写坏的库、或 host 下发离谱值）：
    /// 预取退化为什么都不做，不崩、不发请求。
    func testPrefetchWithPoisonedTargetIsANoOp() async throws {
        let log = RequestLog()
        let pipeline = MessagePipeline(
            store: store,
            fetchFactory: { _ in { range, _ in
                await log.note(range)
                return SessionPipeline.FetchPage(records: [], hasMore: false, clamped: false)
            } },
            sender: { _, _, _, _ in nil },
            now: { 1000 })
        await pipeline.prefetchLatestPages(
            [.init(session: session, newestSeq: Int.max)], limit: 1, concurrency: 1, priority: .jump)
        let requested = await log.all()
        XCTAssertTrue(requested.isEmpty)
    }
}

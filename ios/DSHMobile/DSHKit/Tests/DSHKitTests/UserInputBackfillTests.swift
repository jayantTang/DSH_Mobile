@testable import DSHKit
import XCTest

/// 测试用可拨动时钟（`@Sendable` 闭包捕获需要 Sendable；测试串行执行，无竞争）。
private final class MutableClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

/// 造一条完整记录（与 MessageStoreTests 同一 JSON 解码构造法）。
private func makeRecord(_ seq: Int, text: String? = nil, source: String? = nil) -> SessionRecord {
    let sourceJSON = source.map { ",\"source\":\($0)" } ?? ""
    let body = text ?? "问题\(seq)"
    let json = #"{"type":"user/message","seq":\#(seq),"time":1789276358732,"data":{"text":"\#(body)"\#(sourceJSON)}}"#
    let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
    return SessionRecord(event: event)
}

/// 造一页窗口结果：records 升序（与连接器一致），startSeq 取页内最老。
/// `scanBoundary` 默认 nil = 老连接器（没有 T039 的扫描边界字段）。
private func window(_ records: [SessionRecord], hasMore: Bool,
                    scanBoundary: Int? = nil) -> HistoryWindowValue {
    HistoryWindowValue(
        records: records,
        startSeq: records.first?.event.seq,
        endSeq: records.last?.event.seq,
        hasMore: hasMore,
        scanBoundary: scanBoundary)
}

/// T033 用户输入灌库（三表终局，spec 009 data-model v3）：
/// 完整记录落 record 表、24h 去重跳过、lastSeq 变大后的增量补拉（遇已知 seq 即停）、
/// 账本并入 meta、灌全置 synced 标记、连接器缺能力时跳过且不写任何东西。
final class UserInputBackfillTests: XCTestCase {

    private var directory: URL!
    private var store: MessageStore!
    private var clock: MutableClock!
    private var backfiller: UserInputBackfiller!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-input-backfill-tests-\(UUID().uuidString)")
        store = try MessageStore(path: directory.appendingPathComponent("test.sqlite3"))
        clock = MutableClock()
        let clockRef = clock!
        backfiller = UserInputBackfiller(store: store, now: { clockRef.date })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 首灌拉完整记录落 record 表（同一幂等写入路径），灌全置完整性标记。
    func testFirstBackfillWritesFullRecords() async throws {
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { before in
            if before == nil {
                return window([makeRecord(98), makeRecord(100)], hasMore: true)
            }
            XCTAssertEqual(before, 98, "第二页从上一页最老 seq 续拉")
            return window([makeRecord(40), makeRecord(50)], hasMore: false)
        }
        XCTAssertEqual(outcome, .pulled(pages: 2, rows: 4))
        // 落的是 record 表本体（payload 完整可解码），不是摘要。
        let stored = try await store.records(scope: "mac", sessionId: "s1", in: 1...200)
        XCTAssertEqual(stored.map(\.event.seq), [40, 50, 98, 100])
        let state = try await store.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.lastSeq, 100)
        XCTAssertNil(state?.resumeCursor, "灌全了不留续拉锚点")
        let synced = try await store.userInputsSyncedAt(scope: "mac", sessionId: "s1")
        XCTAssertNotNil(synced, "灌全要置 session_state.user_inputs_synced_at")
    }

    func testSkipsWhenFreshAndLastSeqUnchanged() async throws {
        _ = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            window([makeRecord(100)], hasMore: false)
        }
        clock.date = clock.date.addingTimeInterval(3600) // 1h 后，仍在 24h 新鲜窗口内
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            XCTFail("24h 内且 lastSeq 没变，不该发请求")
            return window([], hasMore: false)
        }
        XCTAssertEqual(outcome, .skippedFresh)
    }

    func testRepullsWhenStale() async throws {
        _ = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            window([makeRecord(100)], hasMore: false)
        }
        clock.date = clock.date.addingTimeInterval(25 * 3600) // 超过 24h：即使 lastSeq 没变也重灌
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            window([makeRecord(100)], hasMore: false)
        }
        XCTAssertEqual(outcome, .pulled(pages: 1, rows: 1))
    }

    func testIncrementalStopsAtKnownSeq() async throws {
        _ = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            window([makeRecord(80), makeRecord(90), makeRecord(100)], hasMore: false)
        }
        clock.date = clock.date.addingTimeInterval(25 * 3600)
        // lastSeq 涨到 130：只补 130/120/110，页里碰到已入库的 100 就停（不再翻页）。
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 130) { before in
            XCTAssertNil(before, "增量补拉一页就该停，不该继续翻")
            return window(
                [makeRecord(100), makeRecord(110), makeRecord(120), makeRecord(130)],
                hasMore: true)
        }
        XCTAssertEqual(outcome, .pulled(pages: 1, rows: 4))
        let stored = try await store.records(scope: "mac", sessionId: "s1", in: 1...200)
        XCTAssertEqual(stored.map(\.event.seq), [80, 90, 100, 110, 120, 130])
        let state = try await store.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.lastSeq, 130)
    }

    func testFailureLeavesStateUntouched() async throws {
        struct Boom: Error {}
        _ = try? await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            throw Boom()
        }
        let state = try await store.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertNil(state, "失败的灌库不记账，下次冷启动还会重试")
    }

    /// 降级（T033）：连接器没有 history-role-filter 时整体跳过——不回退浏览模式
    /// 写摘要（没有 source 的摘要进 record 就是脏数据），record 必须保持为空。
    func testUnsupportedConnectorSkipsWithoutWriting() async throws {
        let clockRef = clock!
        let degraded = UserInputBackfiller(
            store: store, now: { clockRef.date }, roleFilterSupported: false)
        let outcome = try await degraded.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            XCTFail("缺能力的连接器不该发任何请求")
            return window([], hasMore: false)
        }
        XCTAssertEqual(outcome, .unsupported)
        let stored = try await store.records(scope: "mac", sessionId: "s1", in: 1...200)
        XCTAssertTrue(stored.isEmpty, "降级路径不许写 record")
        let state = try await store.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertNil(state, "降级不记账")
        let synced = try await store.userInputsSyncedAt(scope: "mac", sessionId: "s1")
        XCTAssertNil(synced)
    }

    /// 页数打满没灌完：账本里留下续拉锚点，不置完整性标记；下次从锚点继续。
    func testIncompleteBackfillKeepsResumeCursor() async throws {
        let clockRef = clock!
        let limited = UserInputBackfiller(
            store: store, now: { clockRef.date }, maxPages: 1)
        let outcome = try await limited.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            window([makeRecord(90), makeRecord(100)], hasMore: true)
        }
        XCTAssertEqual(outcome, .pulled(pages: 1, rows: 2))
        let state = try await store.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.resumeCursor, 90, "没灌完要留下一页的 before 锚点")
        let synced = try await store.userInputsSyncedAt(scope: "mac", sessionId: "s1")
        XCTAssertNil(synced, "没灌全不置完整性标记")
        // 下次（过新鲜窗口后）从锚点续拉。
        clock.date = clock.date.addingTimeInterval(25 * 3600)
        let second = try await limited.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { before in
            XCTAssertEqual(before, 90)
            return window([makeRecord(10)], hasMore: false)
        }
        XCTAssertEqual(second, .pulled(pages: 1, rows: 1))
        let syncedAfter = try await store.userInputsSyncedAt(scope: "mac", sessionId: "s1")
        XCTAssertNotNil(syncedAfter)
    }

    /// 上一轮因页数预算停在半截：24h 新鲜窗口内再次打开面板，也必须从锚点继续，
    /// 不能把「同步中…」当成已完成而跳过。
    func testIncompleteBackfillResumesWithinFreshWindow() async throws {
        let limited = UserInputBackfiller(store: store, now: { [clock] in clock!.date }, maxPages: 1)
        _ = try await limited.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            window([makeRecord(90), makeRecord(100)], hasMore: true)
        }
        let state = try await store.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertNotNil(state?.resumeCursor)

        let outcome = try await limited.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { before in
            XCTAssertEqual(before, 90, "新鲜窗口内必须从续拉锚点继续")
            return window([makeRecord(10)], hasMore: false)
        }
        XCTAssertEqual(outcome, .pulled(pages: 1, rows: 1))
        let synced = try await store.userInputsSyncedAt(scope: "mac", sessionId: "s1")
        XCTAssertNotNil(synced)
    }

    /// 完整性标记的读侧契约（T036：「我问过的」本地路径按它判回退）：
    /// 从未灌过的会话（含灌库进行中、降级跳过）读出来是 nil → 调用方回退
    /// 连接器路径；灌全置标记 → 走本地零网络。
    func testSyncMarkerGatesLocalReadPath() async throws {
        let store = self.store!
        // 从未灌过：nil（回退）。
        var marker = try await store.userInputsSyncedAt(scope: "mac", sessionId: "s1")
        XCTAssertNil(marker)
        // 有数据但没灌全标记（例如灌库进行中的半成品）：仍是 nil。
        try await store.applyWrites([
            .upsertRecords(scope: "mac", sessionId: "s1", records: [makeRecord(10)]),
        ])
        marker = try await store.userInputsSyncedAt(scope: "mac", sessionId: "s1")
        XCTAssertNil(marker)
        // 灌全置标记：非 nil（走本地）。
        try await store.setUserInputsSyncedAt(scope: "mac", sessionId: "s1", at: Date())
        marker = try await store.userInputsSyncedAt(scope: "mac", sessionId: "s1")
        XCTAssertNotNil(marker)
    }

    // MARK: - T039 扫描边界（scanBoundary）

    private func syncedAt() async throws -> Date? {
        try await store.userInputsSyncedAt(scope: "mac", sessionId: "s1")
    }

    /// T039：整页被 roles 滤空时游标按扫描边界前进，不再原地重拉同一段。
    func testEmptyFilteredPageAdvancesCursor() async throws {
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 1000) { before in
            if before == nil {
                return window([], hasMore: true, scanBoundary: 500)
            }
            XCTAssertEqual(before, 500, "空页也要把 before 推到扫描边界（扫到 500 以下才算没扫过）")
            return window([makeRecord(40), makeRecord(50)], hasMore: false, scanBoundary: 0)
        }
        XCTAssertEqual(outcome, .pulled(pages: 2, rows: 2))
        let state = try await store.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertNil(state?.resumeCursor, "第二页 hasMore=false：灌全，不留续拉锚点")
        let synced = try await syncedAt()
        XCTAssertNotNil(synced, "扫到日志开头才置完整性标记")
    }

    /// T039：连接器缺 `scanBoundary`（老连接器）时退回旧口径——最老返回记录续拉。
    func testFallsBackToOldestReturnedSeqWithoutScanBoundary() async throws {
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { before in
            if before == nil {
                return window([makeRecord(90), makeRecord(100)], hasMore: true)
            }
            XCTAssertEqual(before, 90, "没有扫描边界就退回最老返回记录的 seq")
            return window([makeRecord(10)], hasMore: false)
        }
        XCTAssertEqual(outcome, .pulled(pages: 2, rows: 3))
    }

    /// T039：完整性标记只在真的扫到日志开头时置。浏览路径先写下的半截记录
    /// （有数据、无标记）不许让灌库"碰到已知 seq 就宣布完整"。
    func testMarkerOnlyWhenScanReachedLogStart() async throws {
        // 浏览路径留下一族 me 记录，但从没灌全过（无标记）。
        try await store.applyWrites([
            .upsertRecords(scope: "mac", sessionId: "s1", records: [makeRecord(100)]),
        ])
        let markerBefore = try await syncedAt()
        XCTAssertNil(markerBefore)
        let clockRef = clock!
        let limited = UserInputBackfiller(store: store, now: { clockRef.date }, maxPages: 1)
        let first = try await limited.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { before in
            XCTAssertNil(before)
            // 页里就有已入库的 100：没灌全时不许停；页数打满，本轮到此为止。
            return window([makeRecord(100), makeRecord(50)], hasMore: true, scanBoundary: 50)
        }
        XCTAssertEqual(first, .pulled(pages: 1, rows: 2))
        let markerAfterFirst = try await syncedAt()
        XCTAssertNil(markerAfterFirst, "碰到已入库的 seq 不等于扫到开头，不许置完整性标记")
        let state = try await store.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.resumeCursor, 50, "续拉锚点按扫描边界推进（原地不动就永远灌不完）")

        clock.date = clock.date.addingTimeInterval(25 * 3600)
        let second = try await limited.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { before in
            XCTAssertEqual(before, 50, "从扫描边界续拉")
            return window([makeRecord(10)], hasMore: false, scanBoundary: 0)
        }
        XCTAssertEqual(second, .pulled(pages: 1, rows: 1))
        let markerAfterSecond = try await syncedAt()
        XCTAssertNotNil(markerAfterSecond, "真的扫到日志开头才置标记")
    }

    /// T039：已灌全过的会话仍走增量捷径（碰到已入库 seq 即停），标记保持、
    /// 续拉锚点清空（下次冷启动还是从最新开始补，而不是从头重扫）。
    func testIncrementalStopKeepsMarkerAndClearsCursor() async throws {
        _ = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 100) { _ in
            window([makeRecord(80), makeRecord(100)], hasMore: false)
        }
        let marker = try await syncedAt()
        XCTAssertNotNil(marker)
        clock.date = clock.date.addingTimeInterval(25 * 3600)
        let outcome = try await backfiller.backfill(scope: "mac", sessionId: "s1", lastSeq: 130) { before in
            XCTAssertNil(before, "已灌全的会话从最新开始增量补拉")
            return window([makeRecord(100), makeRecord(120), makeRecord(130)], hasMore: true)
        }
        XCTAssertEqual(outcome, .pulled(pages: 1, rows: 3))
        let state = try await store.userInputSyncState(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.lastSeq, 130)
        XCTAssertNil(state?.resumeCursor, "本轮没有更多要拉，不留续拉锚点")
        let markerAfter = try await syncedAt()
        XCTAssertNotNil(markerAfter, "增量补拉不清掉已有的完整性标记")
    }
}

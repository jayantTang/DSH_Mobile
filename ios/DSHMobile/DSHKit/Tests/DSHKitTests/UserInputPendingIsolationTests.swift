@testable import DSHKit
import XCTest

/// 「我问过的」（`record` 表里的 me 子集）只包含**已经进入会话历史**的用户消息。
///
/// 2026-10-19 现象：会话内搜索面板「只看我的提问」里，最近一两条显示成
/// 「第 9223372036854775806 条」。那个数字不是会话里的位置，而是
/// `MessagePipeline` 给未确认消息分配的合成排序键（`Int.max` 起递减，见
/// MessagePipeline+Send.swift 的 `insertOptimistic` / `restorePending`）。
///
/// 泄漏路径有两段：
///   1. 数据层：`upsertPending` 把带合成键的记录写进 `record`（`status='pending'`），
///      而 `userInputRecords` / `searchUserInputRecords` / `maxUserInputSeq` 只按
///      「role='me' + 来源是用户本人」过滤，**没有排除 pending**，于是合成键被当成
///      「会话里的位置」交出去；
///   2. 展示层：搜索面板把 `hit.seq` 直接写成「第 N 条」（TranscriptSearchSheet.row），
///      合键因此在界面上现形。
///
/// 同一族缺陷已经修过一次（`v3-aggregate-excludes-pending`：`session_state.newest_seq`
/// 被 pending 抬到 Int.max，冷启动预取按它算页边界时整数溢出；见 MessageStoreTests
/// 的 `testMigrationRepairsAggregateRaisedByPendingSyntheticSeq`）。这里是同一份合成键
/// 从另外三个读侧漏出来。
///
/// 断言口径是「用户可见的位置」：列表/搜索只能给出会话里真实存在的 seq。
/// 修法未定（从读侧排除 pending，或让面板不把未入历史的行编成「第 N 条」），
/// 用例只钉住结果，不钉住实现。
final class UserInputPendingIsolationTests: XCTestCase {

    private var directory: URL!
    private var store: MessageStore!

    /// 已进入会话历史的两条用户输入：会话位置 2 与 5。
    private static let confirmedSeqs = [2, 5]
    /// 未确认消息的合成排序键：与 `MessagePipeline` 同一条规则（`Int.max` 起递减）。
    private static let unsavedSeq = Int.max - 1
    private static let restoredSeq = Int.max - 2

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-input-pending-tests-\(UUID().uuidString)")
        store = try MessageStore(path: directory.appendingPathComponent("test.sqlite3"))
        try await store.applyWrites([
            .upsertRecords(scope: "mac", sessionId: "s1", records: [
                userMessage(2, text: "上一轮问过的问题"),
                userMessage(5, text: "这一轮问过的问题"),
            ]),
        ])
        // 两条没等到确认的上行消息：一条是本进程刚发的，一条是重启后恢复的。
        // 二者在库里都带合成键（`status='pending'`），与真实发送路径一致。
        try await store.applyWrites([
            .upsertPending(scope: "mac", sessionId: "s1", clientId: "c-live",
                           record: userMessage(Self.unsavedSeq, text: "刚发出还没确认")),
            .upsertPending(scope: "mac", sessionId: "s1", clientId: "c-restored",
                           record: userMessage(Self.restoredSeq, text: "重启前没发出去")),
        ])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 「只看我的提问」浏览列表

    /// 未确认消息不进浏览列表：它不是会话里的位置，面板却把 seq 当「第 N 条」印出来。
    func testBrowsingListOnlyCarriesRealSessionPositions() async throws {
        let entries = try await store.userInputRecords(scope: "mac")
        XCTAssertEqual(entries.map { $0.record.event.seq }, Self.confirmedSeqs,
                       "browsing must list only messages the session has numbered; "
                       + "the pending rows carry MessagePipeline's synthetic sort key")
    }

    // MARK: - 关键词搜索（两条查法）

    /// ≥3 字符走 FTS5；未确认消息的任务是把合成键挡在用户可见的位置之外。
    func testFTSMatchDoesNotSurfaceUnsavedMessages() async throws {
        let hits = try await store.searchUserInputRecords(scope: "mac", query: "还没确认")
        XCTAssertTrue(hits.isEmpty,
                      "an unsaved prompt has no session position to report: \(hits.map { $0.record.event.seq })")
    }

    /// <3 字符降级 LIKE；与 FTS 同一口径。
    func testShortQueryMatchDoesNotSurfaceUnsavedMessages() async throws {
        let hits = try await store.searchUserInputRecords(scope: "mac", query: "刚发")
        XCTAssertTrue(hits.isEmpty,
                      "the LIKE fallback must agree with FTS about unsaved prompts: \(hits.map { $0.record.event.seq })")
    }

    /// 已确认的消息不能被顺手一起过滤掉（排除 pending 不等于排除用户输入）。
    func testConfirmedMessagesStaySearchable() async throws {
        let hits = try await store.searchUserInputRecords(scope: "mac", query: "问过的问题")
        XCTAssertEqual(hits.map { $0.record.event.seq }, [5, 2],
                       "both confirmed prompts must survive the pending filter")
    }

    // MARK: - 增量灌库的锚点

    /// 增量补拉的锚点是「本地已灌的最大 seq」。拿到合成键会让补拉提前停下
    /// （`UserInputBackfiller.collect` 见任何 `seq <= knownMax` 即认为接上了上次的地盘），
    /// 后面的历史就再也灌不进来。
    func testIncrementalAnchorIgnoresUnsavedMessages() async throws {
        let anchor = try await store.maxUserInputSeq(scope: "mac", sessionId: "s1")
        XCTAssertEqual(anchor, 5,
                       "the backfill anchor must be the newest confirmed seq, not the synthetic key")
    }

    // MARK: - 修复不许把未发出消息弄丢

    /// 未确认消息仍要留给「重启恢复」那条路：它没进历史，但不能从库里消失。
    func testUnsavedMessagesRemainReadableForRestore() async throws {
        let pending = try await store.pendingRecords(scope: "mac", sessionId: "s1")
        XCTAssertEqual(Set(pending.map(\.clientId)), ["c-live", "c-restored"],
                       "the unsent prompts must stay in the record table (status='pending')")
    }

    /// 确认之后换正式 seq：同一条消息只剩一行，且是会话里的位置。
    func testConfirmationReplacesTheSyntheticPosition() async throws {
        try await store.applyWrites([
            .confirmPending(scope: "mac", sessionId: "s1", clientId: "c-live",
                            record: userMessage(6, text: "刚发出还没确认")),
        ])
        let entries = try await store.userInputRecords(scope: "mac")
        XCTAssertEqual(entries.filter { $0.record.event.seq == 6 }.count, 1,
                       "the confirmed prompt lands at its session position, exactly once")
        XCTAssertFalse(entries.contains { $0.record.event.seq == Self.unsavedSeq },
                       "the row that carried the synthetic key must be gone after confirmation")
    }

    // MARK: - 夹具

    /// 与真实上行记录同形：正文在 `data.text`，来源是用户本人，rpcId 即 clientId。
    private func userMessage(_ seq: Int, text: String) -> SessionRecord {
        let json = #"""
        {"type":"user/message","seq":\#(seq),"time":1789276358732,"data":{"text":"\#(text)","source":{"kind":"user","rpcId":"r-\#(seq)"}}}
        """#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }
}

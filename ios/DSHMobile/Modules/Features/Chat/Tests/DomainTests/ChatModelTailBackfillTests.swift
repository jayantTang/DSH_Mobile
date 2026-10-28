@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
@testable import DSHKit
import DSHTestingSupport
import XCTest

/// 首帧窗口按轮次切齐（设计 `20261027-折叠抖动-方案A.md` M5'）。
///
/// 用真库（临时目录）灌记录，0 网络：补读是**纯本地**动作，这里钉的就是那一条。
/// 每种结局都要能在界面上见到（占位行三态），所以断言落在 `BackfillOutcome` 与
/// 占位行状态的映射上，而不是"函数返回了"。
@MainActor
final class ChatModelTailBackfillTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!
    private var fake: FakeLinkService!
    private var layer: MessageLayer?
    private var directory: URL?

    private var scope: String { fake.scopeId ?? "unknown" }
    private let sessionId = "s-1"

    override func setUp() async throws {
        try await super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        model = ChatModel()
        fake = FakeLinkService(profiles: [TestFixtures.relayProfile()],
                               state: .connected(hostHome: "/Users/tester"))
        fake.activeProfile = try XCTUnwrap(fake.profiles.first)
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        carrier.registerLiveStream("session/follow")
        model.attach(store: fake, hub: hub)
    }

    override func tearDown() async throws {
        ChatProbe.shared.probeNote = nil
        await model.close()
        hub.stop()
        model = nil
        hub = nil
        fake = nil
        carrier = nil
        layer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    // MARK: - 夹具

    private func attachLayer() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-tail-backfill-tests-\(UUID().uuidString)")
        directory = dir
        let messageLayer = MessageLayer()
        let client = HostClientFactory.make(carrier: carrier)
        fake.clientOverride = client
        messageLayer.attach(client: { client },
                            storePath: dir.appendingPathComponent("messages.sqlite3"))
        guard messageLayer.isReady else {
            throw XCTSkip("MessageLayer could not open its message store in this environment")
        }
        layer = messageLayer
        model.attach(messageLayer: messageLayer)
    }

    private func record(_ object: [String: JSONValue]) throws -> SessionRecord {
        let data = try JSONEncoder().encode(JSONValue.object(object))
        return SessionRecord(event: try JSONDecoder().decode(SessionEvent.self, from: data))
    }

    private func toolCall(seq: Int) -> [String: JSONValue] {
        ["type": .string("tool/call"), "seq": .int(seq),
         "data": .object(["turn": .int(1), "step": .int(1), "callId": .string("c-\(seq)"),
                          "name": .string("bash"), "arguments": .string("{}")])]
    }

    /// 灌一段记录进本地库（只走 `record` 表，0 网络）。
    private func seed(_ events: [[String: JSONValue]]) async throws {
        guard let layer else { throw XCTSkip("no layer") }
        let records = try events.map { try record($0) }
        await layer.upsertRecords(scope: scope, sessionId: sessionId, records: records)
    }

    /// 把覆盖区间写进 `session_state`（产品里由管道的最新页水合回写）。
    /// 补读的"下方有没有洞"就靠它，所以用例必须能直接摆出来。
    private func seedCoverage(_ spans: [RangeIndex.Span]) async throws {
        guard let layer else { throw XCTSkip("no layer") }
        try await layer.saveRanges(scope: scope, sessionId: sessionId,
                                   ranges: RangeIndex(spans: spans))
    }

    private func filler(_ range: ClosedRange<Int>) -> [[String: JSONValue]] {
        range.map { toolCall(seq: $0) }
    }

    /// 只读回窗口的最后 `count` 条（模拟"按条数切开"的窗口）。
    private func window(last count: Int) async throws -> ChatModel.StoredTail {
        guard let layer else { throw XCTSkip("no layer") }
        let records = try await layer.windowBefore(scope: scope, sessionId: sessionId,
                                                   seq: Int.max, limit: count)
        return ChatModel.StoredTail(records: records,
                                    oldest: records.first?.event.seq,
                                    newest: records.last?.event.seq,
                                    hasOlder: false)
    }

    // MARK: - 结局映射（M5'-1）

    func test_placeholder_state_mapping_covers_all_outcomes() {
        typealias State = TimelineProcessPlaceholder.State
        XCTAssertEqual(ChatModel.placeholderState(for: .notNeeded), State.unresolved)
        XCTAssertEqual(ChatModel.placeholderState(for: .aligned(added: 3)), State.unresolved)
        XCTAssertEqual(ChatModel.placeholderState(for: .earliest), State.unresolved,
                       "到最早没有\"读失败\"的事实：静置可重试，不撒谎")
        XCTAssertEqual(ChatModel.placeholderState(for: .capped(limit: 200)), State.unresolved)
        XCTAssertEqual(ChatModel.placeholderState(for: .hole), State.failed(.hole))
        XCTAssertEqual(ChatModel.placeholderState(for: .failed("read")), State.failed(.read))
        XCTAssertEqual(ChatModel.placeholderState(for: .failed("timeout")), State.failed(.timeout))
    }

    func test_backfill_probe_fields_are_stable() {
        let fields = ChatModel.backfillFields(.aligned(added: 12), phase: "open",
                                              added: 12, oldest: 7, hole: false)
        XCTAssertEqual(fields, [
            "phase": "open", "outcome": "aligned", "added": "12",
            "oldest": "7", "hole": "0",
        ])
        let hole = ChatModel.backfillFields(.hole, phase: "retry", added: 0, oldest: nil, hole: true)
        XCTAssertEqual(hole["outcome"], "hole")
        XCTAssertEqual(hole["phase"], "retry")
        XCTAssertNil(hole["oldest"], "没有最老一条时不写这个键")
        XCTAssertEqual(ChatModel.backfillName(.capped(limit: 200)), "capped")
        XCTAssertEqual(ChatModel.backfillName(.failed("timeout")), "failed:timeout")
    }

    func test_stored_tail_defaults_to_not_needed() {
        let stored = ChatModel.StoredTail(records: [], oldest: nil, newest: nil, hasOlder: false)
        XCTAssertEqual(stored.backfill, .notNeeded)
    }

    // MARK: - 补读（M5'-2）

    func test_backfill_aligns_window_down_to_turn_start() async throws {
        try attachLayer()
        try await seed(filler(1...50) + [ProcessFoldFixtures.turnStart(seq: 51, turn: 7)]
                       + filler(52...250))
        try await seedCoverage([.init(1, 250)])
        let stored = try await window(last: 50)
        XCTAssertFalse(stored.records.contains { ChatModel.isTailBoundaryRow($0) },
                       "前置：窗口里没有边界行")

        let aligned = await model.alignTail(stored, scope: scope, sessionId: sessionId)

        XCTAssertEqual(aligned.outcome, .aligned(added: aligned.prefix.count))
        XCTAssertEqual(aligned.prefix.last?.event.seq, 51, "补到边界行，并且含这一条")
        XCTAssertEqual(ChatModel.tailBoundary(in: aligned.prefix + stored.records),
                       .open(turn: 7, startedAt: nil), "边界来自补回来的那一行")
    }

    func test_backfill_stops_at_a_turn_end() async throws {
        try attachLayer()
        try await seed(filler(1...50) + [ProcessFoldFixtures.turnEnd(seq: 51, turn: 7)]
                       + filler(52...250))
        try await seedCoverage([.init(1, 250)])
        let stored = try await window(last: 50)

        let aligned = await model.alignTail(stored, scope: scope, sessionId: sessionId)

        XCTAssertEqual(aligned.prefix.last?.event.seq, 51)
        XCTAssertEqual(ChatModel.tailBoundary(in: aligned.prefix + stored.records),
                       .closed(turn: 7, reason: "completed"),
                       "窗口从一个 turn/end 之后开始也算切齐")
    }

    func test_backfill_reports_earliest_when_the_store_starts_later() async throws {
        try attachLayer()
        try await seed(filler(100...250))
        try await seedCoverage([.init(100, 250)])
        let stored = try await window(last: 50)

        let aligned = await model.alignTail(stored, scope: scope, sessionId: sessionId)

        XCTAssertEqual(aligned.outcome, .earliest)
        XCTAssertEqual(aligned.prefix.count, 101, "库里有更老的就全拿回来（100..200），仍没有边界")
    }

    /// 空区间集 = "从没记录过覆盖"，**不是**"已知有洞"：照常补读。
    ///
    /// 反证在同一用例里：区间集有内容且确实缺一段时，必须落 `.hole`（不猜、不联网）。
    /// 这两半放一起是为了防止有人把"有洞"的条件放宽成"区间集不是 .full"——那会让
    /// 从没走过最新页水合的会话永远停在「过程区缺一段记录」，点了也修不好。
    func test_backfill_continues_when_no_coverage_was_ever_recorded() async throws {
        try attachLayer()
        try await seed(filler(1...50) + [ProcessFoldFixtures.turnStart(seq: 51, turn: 7)]
                       + filler(52...250))
        // 故意不写区间集。
        let stored = try await window(last: 50)

        let aligned = await model.alignTail(stored, scope: scope, sessionId: sessionId)

        XCTAssertEqual(aligned.outcome, .aligned(added: aligned.prefix.count),
                       "没有覆盖信息不等于有洞：照常补读到边界")
        XCTAssertEqual(aligned.prefix.last?.event.seq, 51)
        XCTAssertEqual(ChatModel.tailBoundary(in: aligned.prefix + stored.records),
                       .open(turn: 7, startedAt: nil))

        // 反证：区间集有内容且缺 101…200 → `.hole`。
        try await seedCoverage([.init(1, 100), .init(201, 250)])
        let holed = await model.alignTail(stored, scope: scope, sessionId: sessionId)
        XCTAssertEqual(holed.outcome, .hole, "已知有缺口就不猜")
        XCTAssertTrue(holed.prefix.isEmpty)
    }

    func test_backfill_reports_hole_and_does_not_guess() async throws {
        try attachLayer()
        // 中间挖掉 101…200：区间集在下方不是 `.full`。
        try await seed(filler(1...100))
        try await seed(filler(201...250))
        try await seedCoverage([.init(1, 100), .init(201, 250)])
        let stored = try await window(last: 50)

        let aligned = await model.alignTail(stored, scope: scope, sessionId: sessionId)

        XCTAssertEqual(aligned.outcome, .hole, "有洞就不猜、不联网")
        XCTAssertTrue(aligned.prefix.isEmpty)
        XCTAssertEqual(ChatModel.placeholderState(for: aligned.outcome), .failed(.hole))
    }

    func test_backfill_reports_read_failure_as_failed_read() async throws {
        // 没有磁盘层 = 读不出来（真实失败形态），必须是 `.failed("read")` 而不是"没事"。
        let stored = ChatModel.StoredTail(
            records: [try record(toolCall(seq: 3))], oldest: 3, newest: 3, hasOlder: false)

        let aligned = await model.alignTail(stored, scope: scope, sessionId: sessionId)

        XCTAssertEqual(aligned.outcome, .failed("read"))
        XCTAssertEqual(ChatModel.placeholderState(for: aligned.outcome), .failed(.read))
    }

    func test_backfill_is_capped_at_the_window_budget() async throws {
        try attachLayer()
        // 400 条里没有边界行：一页读满 200 条仍无边界 → 上限结局，不再继续读。
        try await seed(filler(1...400))
        try await seedCoverage([.init(1, 400)])
        let stored = try await window(last: 200)

        let aligned = await model.alignTail(stored, scope: scope, sessionId: sessionId)

        XCTAssertEqual(aligned.outcome, .capped(limit: ChatModel.tailBackfillMaxRecords))
        XCTAssertEqual(aligned.prefix.count, ChatModel.tailBackfillMaxRecords,
                       "最多一页（200 条）：不可能读过第二页")
        XCTAssertEqual(ChatModel.placeholderState(for: aligned.outcome), .unresolved)
    }

    func test_backfill_does_not_run_when_the_plan_rebases() async throws {
        try attachLayer()
        try await seed(filler(1...50) + [ProcessFoldFixtures.turnStart(seq: 51, turn: 7)]
                       + filler(52...250))
        let stored = try await window(last: 50)
        // 本地游标比 host 还大：窗口会被整段替换，补读出来的前缀没有意义。
        let rebase = TranscriptSyncPlan.plan(localThrough: 250, hostCursor: 50)
        XCTAssertTrue(rebase.reBase, "前置：这份计划就是重建")

        let prefix = await model.openStoredTail(
            stored, scope: scope, sessionId: sessionId, syncPlan: rebase,
            seeding: .unknown, hostSeq: 50)

        XCTAssertTrue(prefix.isEmpty, "重建分支不补读")
        XCTAssertEqual(model.tailBoundaryAttempt, .unresolved)
    }

    // MARK: - 前缀进管道（M5'-3）

    func test_backfill_prefix_is_absorbed_into_the_pipeline() async throws {
        try attachLayer()
        try await seed(filler(1...50) + [ProcessFoldFixtures.turnStart(seq: 51, turn: 7)]
                       + filler(52...300))
        try await seedCoverage([.init(1, 300)])

        await model.open(try ChatSeam.summary(id: sessionId, asOfSeq: 300))
        await carrier.waitForLiveStream("session/follow")

        guard case .open(let turn, _) = model.timeline.tail.boundary, turn == 7 else {
            return XCTFail("补读到 turn/start 之后首帧边界就是已知的：\(model.timeline.tail.boundary)")
        }
        let bridge = try XCTUnwrap(model.pipelineBridge)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !(bridge.records.keys.contains(51)) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(bridge.records.keys.contains(51),
                      "补回来的前缀必须进管道，否则第二帧会把首帧的行抹掉")
    }
}

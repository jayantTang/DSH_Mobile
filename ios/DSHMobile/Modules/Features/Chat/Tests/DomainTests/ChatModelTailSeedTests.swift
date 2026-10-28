@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
@testable import DSHKit
import DSHTestingSupport
import XCTest

/// 首帧边界播种（设计 `20261027-折叠抖动-方案A.md` M2'-3）：
/// 同进程缓存 → 磁盘 `session_tail` → 宿主 `running` → `.unknown`。
///
/// 这一层钉的是"打开会话时那条决定从哪来"，不是在钉存储格式（那在
/// `MessageStoreTests`）。用真库（临时目录）+ 假链路，0 网络。
@MainActor
final class ChatModelTailSeedTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!
    private var fake: FakeLinkService!
    private var layer: MessageLayer!
    private var directory: URL!
    private var probeEvents: [(kind: String, fields: [String: String])] = []

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
        let client = HostClientFactory.make(carrier: carrier)
        fake.clientOverride = client
        carrier.registerLiveStream("session/follow")
        model.attach(store: fake, hub: hub)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-tail-seed-tests-\(UUID().uuidString)")
        layer = MessageLayer()
        layer.attach(client: { client },
                     storePath: directory.appendingPathComponent("messages.sqlite3"))
        guard layer.isReady else { throw XCTSkip("MessageLayer could not open its store") }
        model.attach(messageLayer: layer)
        probeEvents = []
        ChatProbe.shared.probeNote = { [weak self] kind, fields, _ in
            self?.probeEvents.append((kind, fields))
        }
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
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try await super.tearDown()
    }

    private func open(running: Bool = false) async throws {
        await model.open(try ChatSeam.summary(id: sessionId, asOfSeq: 4, running: running))
        await carrier.waitForLiveStream("session/follow")
    }

    private func cachedEntry(_ boundary: TranscriptTail.Boundary) -> TranscriptCache.Entry {
        var timeline = ChatTimeline()
        timeline.seedTail(boundary)
        return TranscriptCache.Entry(timeline: timeline, hasOlder: false, oldestSeq: nil,
                                     throughSeq: 0, records: [])
    }

    // MARK: - 优先级

    func test_seed_prefers_the_cached_timeline_over_the_persisted_row() async throws {
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        let cached = cachedEntry(.open(turn: 4, startedAt: started))
        model.transcriptCache.store(cached, for: sessionId)
        try await layer.setTailBoundary(
            scope: scope, sessionId: sessionId,
            try XCTUnwrap(StoredTailBoundary(.closed(turn: 7, reason: "completed"))))

        try await open()

        XCTAssertEqual(model.timeline.tail.boundary, .open(turn: 4, startedAt: started),
                       "同进程缓存来自实时事件，比磁盘旧值强")
    }

    func test_seed_uses_the_persisted_row_when_nothing_is_cached() async throws {
        try await layer.setTailBoundary(
            scope: scope, sessionId: sessionId,
            try XCTUnwrap(StoredTailBoundary(.closed(turn: 7, reason: nil))))

        try await open()

        XCTAssertEqual(model.timeline.tail.boundary, .closed(turn: 7, reason: nil),
                       "没有缓存时，磁盘行是上次亲身观测到的最后一个事实")
    }

    func test_host_running_overrides_a_persisted_closed_tail() async throws {
        try await layer.setTailBoundary(
            scope: scope, sessionId: sessionId,
            try XCTUnwrap(StoredTailBoundary(.closed(turn: 3, reason: "completed"))))

        try await open(running: true)

        guard case .open = model.timeline.tail.boundary else {
            return XCTFail("宿主说在跑时不许停在旧的 closed：\(model.timeline.tail.boundary)")
        }
    }

    func test_seed_falls_back_to_unknown_without_any_evidence() async throws {
        try await open()

        XCTAssertEqual(model.timeline.tail.boundary, .unknown,
                       "没有缓存、没有磁盘行、宿主也没说在跑 → 未知（占位行可重试）")
        XCTAssertEqual(model.tailBoundaryAttempt, .unresolved)
    }

    /// rebase 重建必须带着**已经算出来的**磁盘种子，不能把边界丢回 `unknown`
    /// （ARCH-REVIEW 3 R1：实测 `from=open → to=unknown` 之后跟尾快照 1.41 s 才回来，
    /// 期间界面是一帧"没有行"；而 rebase 只留 20 条快照，切在长轮次中段时运行行
    /// 根本不会自己回来）。
    func test_rebase_rebuild_keeps_the_persisted_boundary_instead_of_dropping_to_unknown() async throws {
        try await layer.setTailBoundary(
            scope: scope, sessionId: sessionId,
            try XCTUnwrap(StoredTailBoundary(.open(turn: 3, startedAt: nil))))
        // 本地游标（20）比宿主游标（4）还大 → `TranscriptSyncPlan` 判重建。
        await layer.upsertRecords(scope: scope, sessionId: sessionId, records: [
            SessionRecord(event: try decode(toolCall(seq: 20))),
        ])

        try await open()   // asOfSeq: 4

        XCTAssertEqual(model.timeline.tail.boundary, .open(turn: 3, startedAt: nil),
                       "重建把磁盘种子丢了：rebase 分支既不走 openStoredTail 也没有 reset")
        XCTAssertTrue(model.rowsFor(screen: sessionId).contains { item in
            if case .runningLine = item.kind { return true }
            return false
        }, "边界还在 open：底部运行行必须交到两个列表宿主")
        let unknownMoves = probeEvents
            .filter { $0.kind == "tail.boundary" && $0.fields["to"] == "unknown" }
        XCTAssertTrue(unknownMoves.isEmpty,
                      "这次赋值与前一次发布用的是同一个种子，不该再发 to=unknown：\(unknownMoves)")
    }

    private func toolCall(seq: Int) -> JSONValue {
        .object(["type": .string("tool/call"), "seq": .int(seq),
                 "data": .object(["turn": .int(3), "step": .int(1),
                                  "callId": .string("c-\(seq)"), "name": .string("bash"),
                                  "arguments": .string("{}")])])
    }

    private func decode(_ json: JSONValue) throws -> SessionEvent {
        let data = try JSONEncoder().encode(json)
        return try JSONDecoder().decode(SessionEvent.self, from: data)
    }

    /// 播种只在 `open()` 里算一次：它**不写**磁盘行（写点只有边界迁移那一处）。
    func test_seed_is_computed_once_per_open() async throws {
        let stamp = Date(timeIntervalSince1970: 1_760_000_123)
        try await layer.setTailBoundary(
            scope: scope, sessionId: sessionId,
            try XCTUnwrap(StoredTailBoundary(.closed(turn: 5, reason: nil), updatedAt: stamp)))

        try await open()

        let row = try await layer.tailBoundary(scope: scope, sessionId: sessionId)
        XCTAssertEqual(row?.updatedAt, stamp, "播种不许改写磁盘行")
        XCTAssertEqual(row?.turn, 5)
        XCTAssertEqual(model.timeline.tail.boundary, .closed(turn: 5, reason: nil))
    }
}

@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
@testable import DSHKit
import DSHTestingSupport
import XCTest

/// 边界落库（设计 `20261027-折叠抖动-方案A.md` M2'-4 / M8'-2）。
///
/// 三条硬约束与"失败不许静默"是这一层的全部内容：
/// 边界只写一次（迁移点）、`.unknown` 与搜索中间窗口永不落库、写失败必须留探针。
@MainActor
final class ChatModelTailPersistTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!
    private var fake: FakeLinkService!
    private var layer: MessageLayer?
    private var brokenLayer: MessageLayer?
    private var directory: URL?
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
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        carrier.registerLiveStream("session/follow")
        model.attach(store: fake, hub: hub)
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
        brokenLayer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func attachLayer() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-tail-persist-tests-\(UUID().uuidString)")
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

    private func open() async throws {
        await model.open(try ChatSeam.summary(id: sessionId, asOfSeq: 4))
        await carrier.waitForLiveStream("session/follow")
    }

    private func boundaryProbes() -> [[String: String]] {
        probeEvents.filter { $0.kind == "tail.boundary" }.map(\.fields)
    }

    private func persistedRow() async throws -> StoredTailBoundary? {
        try await layer?.tailBoundary(scope: scope, sessionId: sessionId)
    }

    // MARK: - 写一次、写什么

    func test_boundary_transition_persists_once_per_change() async throws {
        try attachLayer()
        try await open()
        // 两次边界迁移（unknown → open → closed），每次一条写。
        model.timeline.reset(with: [], seeding: .open(turn: 1, startedAt: nil), showsTail: true)
        model.timeline.reset(with: [], seeding: .closed(turn: 1, reason: "completed"),
                             showsTail: true)
        await model.flushTranscript()

        let row = try await persistedRow()
        XCTAssertEqual(row?.asBoundary, .closed(turn: 1, reason: "completed"),
                       "最后一条边界必须真的落到磁盘")
        let written = boundaryProbes().filter { $0["persisted"] == "1" }
        XCTAssertEqual(written.count, 2, "每次边界变化写一次：\(boundaryProbes())")
        XCTAssertEqual(written.last?["to"], "closed")
    }

    func test_unknown_boundary_is_never_persisted() async throws {
        try attachLayer()
        try await open()
        // 冷启动的瞬时未知（`timeline = ChatTimeline()` 与未知种子）不许写盘。
        model.timeline.reset(with: [], seeding: .unknown, showsTail: true)
        await model.flushTranscript()

        let unknownRow = try await persistedRow()
        XCTAssertNil(unknownRow, "`.unknown` 不是证据，永不落库")
        XCTAssertTrue(boundaryProbes().allSatisfy { $0["to"] != "unknown" },
                      "连探针都不该出现 to=unknown 的迁移：\(boundaryProbes())")
    }

    func test_detached_search_window_is_not_persisted() async throws {
        try attachLayer()
        try await open()
        // 搜索换窗口的形状：窗口不在尾部（M1 调用点表）。
        model.timeline.reset(with: [], seeding: .closed(turn: 4, reason: "completed"),
                             showsTail: false)
        await model.flushTranscript()

        let detachedRow = try await persistedRow()
        XCTAssertNil(detachedRow, "搜索中间窗口不落库")
        XCTAssertEqual(boundaryProbes().last?["persisted"], "0")
        XCTAssertEqual(boundaryProbes().last?["to"], "closed", "边界事实本身照样存在")
    }

    func test_duplicate_turn_end_writes_once() async throws {
        try attachLayer()
        try await open()
        model.timeline.reset(with: [], seeding: .closed(turn: 1, reason: "completed"),
                             showsTail: true)
        await model.flushTranscript()
        let first = try await persistedRow()
        let probes = boundaryProbes().count

        // 同一条边界再投一次：状态没变 → 不迁移、不写盘、不记探针。
        model.timeline.reset(with: [], seeding: .closed(turn: 1, reason: "completed"),
                             showsTail: true)
        await model.flushTranscript()
        let second = try await persistedRow()

        XCTAssertEqual(second?.updatedAt, first?.updatedAt, "重复的 turn/end 不许再写一次")
        XCTAssertEqual(boundaryProbes().count, probes)
    }

    // MARK: - 失败不许静默（M2'-4 的硬纪律）

    func test_persist_failure_emits_a_probe_and_leaves_the_next_open_unknown() async throws {
        // 真实的失败形态：磁盘层接不上（`MessageLayer.attach` 建库失败时 store 为 nil）。
        // 写入于是抛 `noAddress`，走的是与生产同一条 catch 路径。
        // 注意 `ChatModel.messageLayer` 是 weak：这里必须自己握住它，否则立刻释放，
        // 连 try 都不会发生（那就不是在测失败，而是在测"没有层"）。
        let broken = MessageLayer()
        brokenLayer = broken
        model.attach(messageLayer: broken)
        try await open()
        model.timeline.reset(with: [], seeding: .open(turn: 3, startedAt: nil), showsTail: true)
        await model.flushTranscript()

        let failed = probeEvents.filter { $0.kind == "tail.persist.failed" }.map(\.fields)
        XCTAssertEqual(failed.count, 1, "写失败必须发探针：\(probeEvents.map(\.kind))")
        XCTAssertEqual(failed.first?["turn"], "3")
        XCTAssertEqual(failed.first?["to"], "open")
        XCTAssertEqual(boundaryProbes().last?["persisted"], "1",
                       "persisted=1 只代表已交给写链，不保证落盘")
        XCTAssertEqual(model.tailBoundaryAttempt, .unresolved,
                       "失败不新增状态字段：界面上的表达是下次打开的占位行")

        // 可见后果：重开这一会话时边界仍是未知（没有磁盘行可播种）。
        model.transcriptCache.remove(sessionId)
        model.timeline.reset(with: [], seeding: .unknown, showsTail: true)
        try await open()
        XCTAssertEqual(model.timeline.tail.boundary, .unknown,
                       "没有落盘 → 下次打开 unknown → 占位行可重试")
    }

    // MARK: - 宿主重放（M8'-2）

    func test_replayed_turn_start_records_a_conflict_without_changing_the_boundary() async throws {
        try attachLayer()
        try await open()
        model.timeline.reset(with: [], seeding: .closed(turn: 5, reason: "completed"),
                             showsTail: true)
        // 重放一条旧轮次的 turn/start（轮次号 ≤ 已关闭轮次号）。
        carrier.liveStreams["session/follow"]?.yield(
            ChatSeam.eventFrame(ChatSeam.turnStart(seq: 90, turn: 5)))

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              !probeEvents.contains(where: { $0.kind == "tail.conflict" }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let conflicts = probeEvents.filter { $0.kind == "tail.conflict" }.map(\.fields)
        XCTAssertEqual(conflicts.count, 1, "重放只记一条：\(probeEvents.map(\.kind))")
        XCTAssertEqual(conflicts.first?["turn"], "5")
        XCTAssertEqual(conflicts.first?["closed"], "5")
        XCTAssertEqual(model.timeline.tail.boundary, .closed(turn: 5, reason: "completed"),
                       "探针只记录，不改变合并表的结果")
    }
}

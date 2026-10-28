@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
@testable import DSHKit
import DSHTestingSupport
import XCTest

/// 占位行的「点击重试」（设计 `20261027-折叠抖动-方案A.md` M5'-5）。
///
/// 这里钉两件事：本地补读能单独解决问题（0 网络），以及**任何分支都不许停在
/// `.resolving`**——那条状态看起来"在工作"，是最容易被当成功能正常的一种假象。
@MainActor
final class ChatModelTailRetryTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!
    private var fake: FakeLinkService!
    private var layer: MessageLayer?
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
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    // MARK: - 夹具

    private func attachLayer(v2: Bool = false) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-tail-retry-tests-\(UUID().uuidString)")
        directory = dir
        let capabilities: Set<String> = v2
            ? ["history-window", "history-fold-summary-v2"] : []
        let client = HostClientFactory.make(carrier: carrier, capabilities: capabilities)
        fake.clientOverride = client
        let messageLayer = MessageLayer()
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

    private func seed(_ events: [[String: JSONValue]]) async throws {
        guard let layer else { throw XCTSkip("no layer") }
        await layer.upsertRecords(scope: scope, sessionId: sessionId,
                                  records: try events.map { try record($0) })
    }

    private func open() async throws {
        await model.open(try ChatSeam.summary(id: sessionId, asOfSeq: 300))
        await carrier.waitForLiveStream("session/follow")
    }

    private func retryProbes() -> [[String: String]] {
        probeEvents.filter { $0.kind == "process.unknown.retry" }.map(\.fields)
    }

    // MARK: - 本地补读就够（0 网络）

    func test_retry_reads_the_local_window_and_resolves_without_network() async throws {
        try attachLayer()
        // 打开时库是空的：首帧边界未知（占位行）。
        try await open()
        XCTAssertEqual(model.timeline.tail.boundary, .unknown)
        // 之后本地已有这一段（例如管道刚落库），此时重试应当只读本地库。
        try await seed([ProcessFoldFixtures.turnStart(seq: 51, turn: 7),
                        ProcessFoldFixtures.user(seq: 52, text: "q")])
        let before = (carrier.calls(to: "history/window").count,
                      carrier.calls(to: "session/list").count)

        await model.retryTailBoundary()

        XCTAssertEqual(model.timeline.tail.boundary, .open(turn: 7, startedAt: nil),
                       "本地补读到 turn/start 就够了")
        XCTAssertEqual(model.tailBoundaryAttempt, .unresolved, "边界已知 → 占位行消失")
        XCTAssertEqual(carrier.calls(to: "history/window").count, before.0,
                       "本地补读不联网")
        XCTAssertEqual(carrier.calls(to: "session/list").count, before.1,
                       "本地就解决时不问宿主摘要")
        let probes = retryProbes()
        XCTAssertEqual(probes.last?["state"], "unresolved")
        XCTAssertNotEqual(probes.last?["state"], "resolving", "探针只记终态")
    }

    // MARK: - 概要页兜底只发一次

    func test_retry_falls_back_to_the_summary_page_exactly_once() async throws {
        try attachLayer(v2: true)
        try await open()
        // 等首屏概要这一发自己结束，再量"重试多发了几次"。
        try await Task.sleep(for: .milliseconds(200))
        let before = carrier.calls(to: "_link/sessionWindow").count

        await model.retryTailBoundary()

        XCTAssertEqual(carrier.calls(to: "_link/sessionWindow").count, before + 1,
                       "复用既有概要页通路，且只发一次")
        XCTAssertNotEqual(model.tailBoundaryAttempt, .resolving)
    }

    // MARK: - 失败结局各一条

    func test_retry_reports_hole_as_failed_hole() async throws {
        try attachLayer()
        // 先打开（打开时的最新页水合会回写区间集，先写完再开等于被它覆盖），
        // 再摆出"窗口下方有洞"的本地现场。
        try await open()
        try await seed([toolCall(seq: 1)])
        try await seed((201...500).map { toolCall(seq: $0) })
        try await layer?.saveRanges(scope: scope, sessionId: sessionId,
                                    ranges: RangeIndex(spans: [.init(1, 1), .init(201, 500)]))
        // 前置：本地补读当下就给出"洞"这个结论（不是重试才凭空出现的）。
        let stored = await model.loadStoredTail(scope: scope, sessionId: sessionId)
        let window = try XCTUnwrap(stored)
        let aligned = await model.alignTail(window, scope: scope, sessionId: sessionId)
        let state = try await layer?.sessionState(scope: scope, sessionId: sessionId)
        XCTAssertEqual(aligned.outcome, .hole,
                       "前置：窗口下方有洞；window=\(window.records.first?.event.seq ?? -1)..\(window.records.last?.event.seq ?? -1) count=\(window.records.count) oldest=\(state?.oldestSeq ?? -1) spans=\(state?.ranges.spans ?? [])")

        await model.retryTailBoundary()

        XCTAssertEqual(model.tailBoundaryAttempt, .failed(.hole),
                       "有洞不猜：落到可见的失败态（可再试）")
        XCTAssertNotEqual(model.tailBoundaryAttempt, .resolving)
    }

    func test_retry_times_out_into_failed_timeout() async throws {
        try attachLayer()
        try await open()
        // DEBUG 挂起点：让主路径一直不返回，超时分支才能被真实跑到。
        model.tailRetryHold = { try? await Task.sleep(for: .seconds(30)) }
        let started = Date()

        await model.retryTailBoundary(timeout: .milliseconds(20))

        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "超时必须真的到点")
        XCTAssertEqual(model.tailBoundaryAttempt, .failed(.timeout))
        XCTAssertNotEqual(model.tailBoundaryAttempt, .resolving, "不许停在看起来还在加载")
        XCTAssertEqual(retryProbes().last?["state"], "failed:timeout")
    }

    func test_retry_never_leaves_the_row_resolving() async throws {
        // 没有会话（模型从未打开）：最容易"卡住"的形态。
        await model.retryTailBoundary(timeout: .milliseconds(50))
        XCTAssertNotEqual(model.tailBoundaryAttempt, .resolving)
    }
}

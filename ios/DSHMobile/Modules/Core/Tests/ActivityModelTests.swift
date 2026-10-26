import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 018 覆盖率缺口 G16 / G17（`specs/018-mobile-activity-visibility/test-coverage.md` §2）：
/// `ActivityModel` 这一层只做适配，判定口径在 DSHKit 的 `ActivityStore` 里。所以这里
/// 不重算任何 `isBusy` / 计数，只钉四件事：
///
/// - attach 后用 `_link/jobRoster` 的**首答**喂 store（G16）；
/// - 断线把 `connection(false)` 喂下去，名单按最后一份保留（G16）；
/// - `HostEventHub` 收到的 `link/jobs` 推帧确实进了 store，计数随之变化（G16）；
/// - 重连后重新问名单、reseed 覆盖上一份（G16）；
/// - 输出面板的订阅生命周期：展开订阅、换一条先退上一条、收起退订（G17）。
///
/// 夹具走 `DSHTestingSupport` 的 `FakeCarrier` 驱动真实 `DSHClient`：帧按线上形状解码，
/// `$events` 与 `job/follow` 都是可手工推进的活流。不跑仿真器，不碰真实连接器。
@MainActor
final class ActivityModelTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var service: FakeLinkService!
    private var hub: HostEventHub!
    private var model: ActivityModel!

    override func setUp() async throws {
        try await super.setUp()
        carrier = FakeCarrier()
        carrier.registerLiveStream("$events")
        let client = HostClientFactory.make(carrier: carrier)
        // `FakeLinkService` 起步是未连接，与 App 的时序一致：`RootView` 先
        // `activity.attach(service:hub:)`，再在连接态变化时喂 `setConnected(isConnected)`。
        // 这里不直接构造 `ConnectionState.connected`（本测试目标没声明 DSHConnectionAPI 依赖）。
        service = FakeLinkService(capabilities: [LinkHandshake.Capability.jobsRoster])
        service.clientOverride = client
        hub = HostEventHub()
        hub.start(link: LinkGateway(clientProvider: { client }))
        await carrier.waitForLiveStream("$events")
        model = ActivityModel()
    }

    override func tearDown() async throws {
        model?.closeOutput()
        hub?.stop()
        model = nil
        hub = nil
        service = nil
        carrier = nil
        try await super.tearDown()
    }

    func test_a_roster_answer_enables_activity_when_the_handshake_lost_capabilities() async throws {
        // 现场：relay 建连时 `service.capabilities` 为空，但连接器其实能回答名单。
        // 能力位只能是提示；成功回答本身要能把活动界面打开。
        service.capabilities = []
        model = ActivityModel()
        try await stubRoster(at: 1, [("s1", ["j1"], 0)])
        model.attach(service: service, hub: hub)
        model.setConnected(true)
        await eventually("roster enables activity") {
            self.model.isAvailable && self.model.counts(sessionId: "s1").jobs == 1
        }
        XCTAssertTrue(model.isAvailable)
        XCTAssertEqual(model.counts(sessionId: "s1").jobs, 1)
    }

    func test_a_settle_frame_clears_the_list_row_counts() async throws {
        service.capabilities = [LinkHandshake.Capability.jobsRoster]
        model = ActivityModel()
        model.attach(service: service, hub: hub)
        model.setConnected(true)
        await carrier.waitForLiveStream("$events")
        try await stubRoster(at: 1, [("s1", ["j1"], 0)])
        await model.refresh()
        await eventually("job shows") { self.model.counts(sessionId: "s1").jobs == 1 }

        try pushJobsFrame(at: 2, sessionId: "s1", jobs: [], settled: 1)
        await eventually("settle clears the cell") { self.model.counts(sessionId: "s1").jobs == 0 }
        XCTAssertEqual(model.settledCount(sessionId: "s1"), 1)
    }

    // MARK: - Fixtures

    /// 一行的宿主 `JobView`（只带本特性用到的字段）。
    private func jobRows(_ ids: [String], sessionId: String? = nil) -> String {
        ids.map { id in
            let owner = sessionId.map { ",\"owner\":\"\($0)\"" } ?? ""
            return """
            {"id":"\(id)","kind":"bash","label":"\(id)","status":"running","startedAt":1,"outputTotal":0\(owner)}
            """
        }.joined(separator: ",")
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// `_link/jobRoster` 的下一次回答（连接器本地方法的 `value`）。
    private func stubRoster(at: Int, _ cells: [(id: String, jobs: [String], settled: Int)]) throws {
        let body = cells.map { cell in
            "\"\(cell.id)\":{\"running\":[\(jobRows(cell.jobs, sessionId: cell.id))],\"settled\":\(cell.settled)}"
        }.joined(separator: ",")
        carrier.unaryResponses[HostClientFactory.jobsRosterMethod] = .success(
            try json("{\"at\":\(at),\"sessions\":{\(body)}}")
        )
    }

    /// 从 hub 的 `$events` 活流里推一帧 `link/jobs`（连接器推帧的线上形状）。
    private func pushJobsFrame(at: Int, sessionId: String, jobs: [String], settled: Int) throws {
        let frame = """
        {"type":"link/jobs","value":{"at":\(at),"sessionId":"\(sessionId)",
         "running":[\(jobRows(jobs, sessionId: sessionId))],"settled":\(settled)}}
        """
        let continuation = try XCTUnwrap(carrier.liveStreams["$events"], "hub has not subscribed to $events yet")
        switch continuation.yield(try json(frame)) {
        case .enqueued:
            break
        case .dropped:
            XCTFail("push frame dropped: the hub observer is not reading")
        case .terminated:
            XCTFail("$events stream ended; the frame cannot be delivered")
        @unknown default:
            XCTFail("unexpected yield result")
        }
    }

    /// 流是否已被消费方退订（`yield` 返回 `.terminated` 即流已终止）。
    ///
    /// 探针本身是一帧 `.null`：流没终止时它会进队列，但此时消费方已经走了，
    /// 不会影响任何断言。
    private func isTerminated(_ continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation) -> Bool {
        if case .terminated = continuation.yield(.null) { return true }
        return false
    }

    /// 让主 actor 跑到 `condition` 成立；超时即失败（与 `HostEventHubTests` 同一写法）。
    private func eventually(
        _ description: String,
        deadline: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)")
    }

    // MARK: - G16：attach seed / 断线 / 推帧 / 重连 reseed

    func testG16_attach_seeds_disconnect_freezes_push_applies_and_reconnect_reseeds() async throws {
        try stubRoster(at: 1_000, [("s1", ["bash-1"], 2)])

        model.attach(service: service, hub: hub)
        model.setConnected(true)

        await eventually("first roster after attach") { self.model.counts(sessionId: "s1").jobs == 1 }
        XCTAssertTrue(model.isAvailable)
        XCTAssertFalse(model.lastKnown)
        XCTAssertEqual(model.settledCount(sessionId: "s1"), 2, "settled count comes from the roster's first answer")
        XCTAssertEqual(carrier.calls(to: HostClientFactory.jobsRosterMethod).count, 1, "attach asks the roster only once")

        // 断线：标志翻成"上次已知"，名单保留（不闪成 0）。
        model.setConnected(false)
        XCTAssertTrue(model.lastKnown)
        XCTAssertEqual(model.counts(sessionId: "s1").jobs, 1, "a disconnect must not blank the list to zero")

        // 重连：重新问一次名单，reseed 覆盖上一份。
        try stubRoster(at: 2_000, [("s1", ["bash-1", "bash-2"], 3)])
        model.setConnected(true)

        await eventually("roster after reconnect") {
            self.carrier.calls(to: HostClientFactory.jobsRosterMethod).count == 2
                && self.model.counts(sessionId: "s1").jobs == 2
        }
        XCTAssertFalse(model.lastKnown, "no longer last-known once a new roster arrives")
        XCTAssertEqual(model.settledCount(sessionId: "s1"), 3)

        // hub 收到 `link/jobs` 推帧：整格替换，计数跟着变。
        try pushJobsFrame(at: 3_000, sessionId: "s1", jobs: ["bash-9"], settled: 4)
        await eventually("the push replaces that cell") {
            self.model.liveJobs(sessionId: "s1").map(\.id) == ["bash-9"]
        }
        XCTAssertEqual(model.counts(sessionId: "s1").jobs, 1)
        XCTAssertEqual(model.settledCount(sessionId: "s1"), 4, "settled from the push must reach the store")
    }

    // MARK: - G17：输出面板的订阅

    func testG17_openOutput_subscribes_once_and_closing_unsubscribes() async throws {
        carrier.registerLiveStream("job/follow")
        try stubRoster(at: 1_000, [("s1", ["bash-1", "bash-2"], 0)])
        model.attach(service: service, hub: hub)
        model.setConnected(true)
        await eventually("first roster") { self.model.counts(sessionId: "s1").jobs == 2 }

        let firstJob = try XCTUnwrap(model.liveJobs(sessionId: "s1").first)
        let secondJob = try XCTUnwrap(model.liveJobs(sessionId: "s1").last)

        // 展开第一条：订阅 `job/follow`，请求体点名那个任务与会话。
        model.openOutput(sessionId: "s1", job: firstJob)
        await eventually("first job/follow subscription") {
            self.carrier.calls(to: "job/follow").count == 1
        }
        XCTAssertEqual(model.outputFeed?.id, firstJob.id)
        let firstCall = try XCTUnwrap(carrier.calls(to: "job/follow").first)
        let firstRequest = try XCTUnwrap(firstCall.args?["request"]?.objectValue)
        XCTAssertEqual(firstRequest["jobId"]?.stringValue, firstJob.id)
        XCTAssertEqual(firstRequest["sessionId"]?.stringValue, "s1")
        let firstStream = try XCTUnwrap(carrier.liveStreams["job/follow"])

        // 展开第二条：先退上一条，同一时刻只有一个流。
        model.openOutput(sessionId: "s1", job: secondJob)
        await eventually("second job/follow subscription") {
            self.carrier.calls(to: "job/follow").count == 2
        }
        XCTAssertEqual(model.outputFeed?.id, secondJob.id, "the output panel keeps only the last expanded job")
        await eventually("the old stream is cancelled") { self.isTerminated(firstStream) }

        // 新的流照常把输出喂进面板。
        let secondStream = try XCTUnwrap(carrier.liveStreams["job/follow"])
        switch secondStream.yield(try json(
            #"{"type":"output","chunks":[{"at":0,"text":"hello\n","channel":"stdout"}],"next":6}"#
        )) {
        case .enqueued: break
        case .dropped: XCTFail("output frame dropped")
        case .terminated: XCTFail("the second stream has terminated")
        @unknown default: XCTFail("unexpected yield result")
        }
        await eventually("output reaches the panel") { self.model.outputFeed?.chunks.map(\.text) == ["hello\n"] }

        // 收起即退订：面板清空，流终止，迟到的帧不会再回来。
        model.closeOutput()
        XCTAssertNil(model.outputFeed)
        await eventually("the stream is cancelled after collapsing") { self.isTerminated(secondStream) }
    }
}

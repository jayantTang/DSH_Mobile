import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHSessionsDomain
import DSHTestingSupport
import XCTest

/// 会话列表 ↔ 活动层的接缝（设计 §8.2 用例 j–l）。
///
/// 症状一住在这里：`SessionListModel.refresh()` 拿到的是**增量**回包（`value.items`
/// 只含变化项），而 `ActivityStore` 的 `.sessions` 输入是**整份替换**语义。把增量
/// 喂下去，等于每次都把活动层的会话行缓存替换成"这次变化的那几行"，通常为 0 行——
/// 列表行右侧的「N 智能体」与面板里的子会话行因此随每次刷新熄掉。
///
/// 这三条用例只钉一条口径：**活动层永远收到整份会话行**。增量合并只属于
/// `SessionListModel` 内部。
@MainActor
final class SessionListDigestActivityTests: SessionsDomainTestCase {

    private var activity: ActivityModel!
    private var gated: GatedCarrier!
    private var staging: DigestStaging!

    override func setUp() {
        super.setUp()
        // 闭包只捕获这两个局部值：`hold` 是 `@Sendable`，捕 `self` 会把用例
        // 的主 actor 状态带进传输层线程。
        let staging = DigestStaging()
        self.staging = staging
        gated = GatedCarrier()
        let inner = gated.inner
        carrier = inner
        // 每次 `_link/sessionDigest` 之前把下一份预置回包放进假传输：一条用例要
        // 「先全量、再增量」两段，而 `FakeCarrier` 一个方法只存一份应答。
        gated.hold = { method in
            guard method == "_link/sessionDigest", let next = staging.next() else { return }
            inner.unaryResponses["_link/sessionDigest"] = .success(next)
        }
        // 列表必须声明 `session-digest`，否则 `LinkGateway` 直接走旧通道，
        // 这条接缝根本不会发生。
        fake.clientOverride = HostClientFactory.make(
            carrier: gated,
            capabilities: [HostClientFactory.sessionDigestCapability]
        )
        stubWorkspaces([Wire.workspace("w1", path: "/Users/me/proj", title: "proj", sessions: ["s1"])])
    }

    override func tearDown() async throws {
        activity = nil
        staging = nil
        gated = nil
        try await super.tearDown()
    }

    // MARK: - 用例 j / k：增量回包不清空活动层

    /// j：首次全量回包（父行 + 两个活跃子会话），第二次只回父行一条变化
    /// → 活动层的子会话计数必须还是 2。
    func test_j_an_incremental_digest_keeps_the_child_counts() async {
        staging.push(digest(items: [
            row("s1", updatedAt: 4_000),
            subagent("sub-a", parent: "s1", updatedAt: 3_000, activeSince: 1_000),
            subagent("sub-b", parent: "s1", updatedAt: 2_500, activeSince: 1_500),
        ], version: "v1", full: true))
        staging.push(digest(items: [row("s1", updatedAt: 4_100, running: true)], version: "v2", full: false))
        await prepareActivity()

        await model.refresh()
        XCTAssertEqual(carrier.calls(to: "_link/sessionDigest").count, 1)
        XCTAssertEqual(sessionIds(model.allSessions).sorted(), ["s1", "sub-a", "sub-b"])
        XCTAssertEqual(activity.counts(sessionId: "s1").agents, 2, "全量回包后两路都在跑")

        await model.refresh()
        XCTAssertEqual(carrier.calls(to: "_link/sessionDigest").count, 2)
        XCTAssertEqual(activity.counts(sessionId: "s1").agents, 2,
                       "增量回包只带一条变化，活动层的子会话计数不能被清成 0")
    }

    /// k：第二次回一个**空**增量（连接器无变化时的正常回包）→ 计数同样不变。
    func test_k_an_empty_delta_keeps_the_child_counts() async {
        staging.push(digest(items: [
            row("s1", updatedAt: 4_000),
            subagent("sub-a", parent: "s1", updatedAt: 3_000, activeSince: 1_000),
            subagent("sub-b", parent: "s1", updatedAt: 2_500, activeSince: 1_500),
        ], version: "v1", full: true))
        staging.push(digest(items: [], version: "v2", full: false))
        await prepareActivity()

        await model.refresh()
        XCTAssertEqual(activity.counts(sessionId: "s1").agents, 2)

        await model.refresh()
        XCTAssertEqual(activity.counts(sessionId: "s1").agents, 2,
                       "空增量不能把已经知道的会话行抹掉")
    }

    // MARK: - 用例 l：面板不丢行

    /// l：同一段流程之后，面板要用的两个入口（单行查询与「已结束的子智能体」）
    /// 仍然查得到——它们读的是同一份会话行，不是列表页缓存。
    func test_l_the_activity_panel_keeps_its_rows_after_a_delta() async {
        staging.push(digest(items: [
            row("s1", updatedAt: 4_000),
            subagent("sub-a", parent: "s1", updatedAt: 3_000, activeSince: 1_000),
            finishedSubagent("sub-c", parent: "s1", updatedAt: 2_000, settledMs: 1_200),
        ], version: "v1", full: true))
        staging.push(digest(items: [row("s1", updatedAt: 4_100)], version: "v2", full: false))
        await prepareActivity()

        await model.refresh()
        XCTAssertEqual(activity.summary(sessionId: "sub-a")?.sessionId, "sub-a")
        XCTAssertEqual(sessionIds(activity.finishedChildren(parentSessionId: "s1")), ["sub-c"])

        await model.refresh()
        XCTAssertEqual(activity.summary(sessionId: "sub-a")?.sessionId, "sub-a",
                       "活动层的会话行不能被增量回包替换掉")
        XCTAssertEqual(sessionIds(activity.finishedChildren(parentSessionId: "s1")), ["sub-c"],
                       "已结束的子智能体仍要留在面板里")
    }

    // MARK: - 装配

    /// 活动层必须真的可用（`counts` 在不可用时恒为 0，那样这些用例就只是在
    /// 断言"整块不可用"，测不到增量这件事）。
    private func prepareActivity() async {
        stubActivityRoster()
        let service = FakeLinkService(capabilities: [LinkHandshake.Capability.jobsRoster])
        service.clientOverride = HostClientFactory.make(carrier: gated)
        activity = ActivityModel()
        activity.attach(service: service, hub: hub)
        activity.setConnected(true)
        model.activityModel = activity
        await eventually("活动层可用") { self.activity.isAvailable }
    }

    /// 活动层的名单兜底轮询会自己发一次 `_link/jobRoster`：给一份空名单，
    /// 让它不去干扰用例关心的会话行。
    private func stubActivityRoster() {
        carrier.unaryResponses[HostClientFactory.jobsRosterMethod] = .success(
            .object(["at": .int(1), "sessions": .object([:])])
        )
    }

    // MARK: - 线上形状

    /// `_link/sessionDigest` 的信封（`identity` 编码：不必压缩就能走通同一条解码路径）。
    private func digest(items: [JSONValue], version: String, full: Bool, removed: [String] = []) -> JSONValue {
        .object([
            "encoding": .string("identity"),
            "value": .object([
                "items": .array(items),
                "removed": .array(removed.map { .string($0) }),
                "version": .string(version),
                "full": .bool(full),
            ]),
        ])
    }

    /// 一行普通会话。
    private func row(
        _ id: String,
        updatedAt: Double,
        running: Bool = false,
        parent: String? = nil,
        origin: String? = nil
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "sessionId": .string(id),
            "updatedAt": .double(updatedAt),
            "running": .bool(running),
            "blank": .bool(false),
            "cwd": .string("/Users/me/proj"),
            "projections": .object(["asOfSeq": .int(0)]),
        ]
        if let parent { value["parentSessionId"] = .string(parent) }
        if let origin { value["origin"] = .string(origin) }
        return .object(value)
    }

    /// 一个**正在跑**的子会话行（`subagentTiming.active` 非空）。
    private func subagent(_ id: String, parent: String, updatedAt: Double, activeSince: Double) -> JSONValue {
        subagentRow(id, parent: parent, updatedAt: updatedAt, timing: .object([
            "active": .object(["since": .double(activeSince)]),
            "lastTurnCompleted": .bool(false),
        ]))
    }

    /// 一个**本轮已结束**的子会话行（面板「已结束」段的判据）。
    private func finishedSubagent(
        _ id: String,
        parent: String,
        updatedAt: Double,
        settledMs: Double
    ) -> JSONValue {
        subagentRow(id, parent: parent, updatedAt: updatedAt, timing: .object([
            "settledMs": .double(settledMs),
            "lastTurnCompleted": .bool(true),
        ]))
    }

    private func subagentRow(
        _ id: String,
        parent: String,
        updatedAt: Double,
        timing: JSONValue
    ) -> JSONValue {
        .object([
            "sessionId": .string(id),
            "updatedAt": .double(updatedAt),
            "running": .bool(false),
            "blank": .bool(false),
            "parentSessionId": .string(parent),
            "origin": .string("subagent"),
            "cwd": .string("/Users/me/proj"),
            "projections": .object([
                "asOfSeq": .int(0),
                "values": .object([
                    "subagent": .object(["mode": .string("continuable"), "label": .string(id)]),
                    "subagentTiming": timing,
                ]),
            ]),
        ])
    }

    // MARK: - 小工具

    /// 预置回包队列：跨线程取一次、少一次。
    private final class DigestStaging: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [JSONValue] = []

        func push(_ value: JSONValue) {
            lock.lock()
            pending.append(value)
            lock.unlock()
        }

        func next() -> JSONValue? {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else { return nil }
            return pending.removeFirst()
        }
    }

    /// 让主 actor 跑到 `condition` 成立；超时即失败（与 `ActivityModelTests` 同一写法）。
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
}

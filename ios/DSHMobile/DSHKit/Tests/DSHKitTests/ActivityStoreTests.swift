import Foundation
import XCTest

@testable import DSHKit

/// 018 T021：`ActivityStore` 的判定口径。
///
/// 每条用例对应 `specs/018-mobile-activity-visibility/data-model.md` §6 的一条不变式
/// （编号写在方法名前的注释里），另加两组：回放 `link-job-roster.md` 的样例帧序列、
/// 以及夹具快照与 `contracts/activity-ui.md` §8 一致。
final class ActivityStoreTests: XCTestCase {

    // MARK: - Builders

    private var withRoster: Set<String> { [LinkHandshake.Capability.jobsRoster] }
    private var withoutRoster: Set<String> { [LinkHandshake.Capability.git] }

    private func job(
        _ id: String,
        _ status: JobStatus = .running,
        startedAt: Double = 1_000,
        label: String = "cmd"
    ) -> Job {
        Job(id: id, kind: "bash", label: label, status: status, startedAt: startedAt)
    }

    private func frame(
        at: Double,
        sessionId: String,
        running: [Job],
        settled: Int = 0
    ) -> LinkJobsFrame {
        LinkJobsFrame(at: at, sessionId: sessionId, running: running, settled: settled)
    }

    private func roster(
        at: Double,
        _ cells: [String: ActivityRoster.SessionCell]
    ) -> ActivityRoster {
        ActivityRoster(at: at, sessions: cells)
    }

    private func cell(_ jobs: [Job], settled: Int = 0) -> ActivityRoster.SessionCell {
        ActivityRoster.SessionCell(running: jobs, settled: settled)
    }

    /// 造一个会话行（子会话或普通会话），走真实的 Decoder，避免手搓 memberwise init。
    private func session(
        _ sessionId: String,
        parent: String? = nil,
        mode: String = "continuable",
        active: Bool = true,
        since: Double = 5_000
    ) throws -> SessionSummary {
        let timing = active ? #"{"active":{"since":\#(Int(since))}}"# : "{}"
        let parentKey = parent.map { #""parentSessionId":"\#($0)","origin":"subagent","# } ?? ""
        let json = """
        {"sessionId":"\(sessionId)","updatedAt":1,"running":\(active),"blank":false,
         \(parentKey)
         "projections":{"asOfSeq":1,"values":{
           "subagent":{"mode":"\(mode)","label":"\(sessionId)"},
           "subagentTiming":\(timing)}}}
        """
        return try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
    }

    private func makeStore(
        capabilities: Set<String>,
        inputs: [ActivityStore.Input] = []
    ) -> ActivityStore {
        var store = ActivityStore()
        store.apply(.capabilities(capabilities))
        store.apply(inputs)
        return store
    }

    // MARK: - 不变式 1：乱序帧丢弃

    func testInvariant1_OutOfOrderFrameIsDropped() {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([job("bash-1")])])),
        ])
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-1"])

        // 比已持有值更小的 at：整帧丢弃，屏幕不倒退。
        store.apply(.frame(frame(at: 900, sessionId: "s1", running: [job("bash-old")], settled: 9)))
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-1"])
        XCTAssertEqual(store.settledCount(sessionId: "s1"), 0, "被丢弃的帧连 settled 也不许写")

        // 更大的 at：照常整格替换。
        store.apply(.frame(frame(at: 1_100, sessionId: "s1", running: [job("bash-2")], settled: 1)))
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-2"])
        XCTAssertEqual(store.sampledAt, 1_100)
    }

    // MARK: - 不变式 2：终态永不进 liveJobs

    func testInvariant2_TerminalJobsNeverAppearAsLive() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([])])),
        ])

        // 名单里混进终态（连接器不该这么发，但手机不能把终态当活）。
        store.apply(.frame(frame(at: 1_100, sessionId: "s1", running: [
            job("bash-done", .completed),
            job("bash-killed", .killed),
            job("bash-failed", .failed),
            job("bash-live", .running),
        ], settled: 3)))

        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-live"])

        // 从 running 走到 killed：行消失，计数落到 settled。
        store.apply(.frame(frame(at: 1_200, sessionId: "s1", running: [job("bash-live", .killed)], settled: 4)))
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs, [])
        XCTAssertFalse(store.snapshot(sessionId: "s1")?.isBusy ?? true, "没有轮次也没有子会话时行不再「运行中」")
        XCTAssertEqual(store.settledCount(sessionId: "s1"), 4)
    }

    // MARK: - 不变式 3：能力位缺失即整块不可用

    func testInvariant3_MissingCapabilityMakesCountsZero() {
        var store = ActivityStore()
        store.apply(.capabilities(withoutRoster))
        // 即便应用层误喂了名单，计数也必须是 0：不能把降级显示成"0 个任务"。
        store.apply(.roster(roster(at: 1_000, ["s1": cell([job("bash-1")])])))
        store.apply(.turnOpen("s1", true))

        XCTAssertFalse(store.isAvailable)
        let counts = store.counts(sessionId: "s1")
        XCTAssertEqual(counts.agents, 0)
        XCTAssertEqual(counts.jobs, 0)
        XCTAssertEqual(store.activeCount, 0)
        XCTAssertEqual(store.settledCount(sessionId: "s1"), 0)
    }

    // MARK: - 不变式 4：断线后不再由本地推断更新

    func testInvariant4_DisconnectFreezesLocalInference() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([job("bash-1")])])),
            .sessions([try session("sub-1", parent: "s1")]),
            .turnOpen("s1", false),
        ])
        XCTAssertFalse(store.lastKnown)
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.isBusy, true)

        store.apply(.connection(false))
        XCTAssertTrue(store.lastKnown, "断线后界面标注「上次已知」")
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-1"], "名单保留，不闪成 0")

        // 断线期间到达的任何东西都不许改动推断结果。
        store.apply(.frame(frame(at: 2_000, sessionId: "s1", running: [], settled: 5)))
        store.apply(.frame(frame(at: 2_100, sessionId: "s2", running: [job("bash-2")], settled: 0)))
        store.apply(.sessions([]))
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-1"])
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveChildCount, 1)
        XCTAssertNil(store.snapshot(sessionId: "s2"), "断线期间的新会话不许凭空出现")

        // 重连后帧恢复生效，标志随新名单回落。
        store.apply(.connection(true))
        XCTAssertTrue(store.lastKnown, "还没拿到新名单前仍算「上次已知」")
        store.apply(.frame(frame(at: 2_200, sessionId: "s1", running: [job("bash-3")], settled: 5)))
        XCTAssertFalse(store.lastKnown)
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-3"])
    }

    // MARK: - 不变式 5：换连接（能力重协商）清空名单

    func testInvariant5_CapabilityRenegotiationClearsTheRoster() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([job("bash-1")], settled: 2)])),
            .sessions([try session("sub-1", parent: "s1")]),
        ])
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1)
        XCTAssertEqual(store.generation, 1)
        XCTAssertEqual(store.sampledAt, 1_000)

        // 新一代连接：能力集合变了 → 上一代名单作废。
        store.apply(.capabilities([LinkHandshake.Capability.jobsRoster, LinkHandshake.Capability.git]))

        XCTAssertEqual(store.generation, 2)
        XCTAssertNil(store.sampledAt)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 0)
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 0)
        XCTAssertEqual(store.settledCount(sessionId: "s1"), 0)
        XCTAssertEqual(store.liveJobs(sessionId: "s1"), [], "换代后上一代名单一律作废")
        XCTAssertNil(store.snapshot(sessionId: "s1"), "没有名单就没有「已知」可言")
        XCTAssertEqual(store.rows.map(\.sessionId), ["sub-1"], "会话行不属于活动名单，换代不丢")

        // 同一份能力重复喂不算换代（一次连接里两次握手不该清掉刚拿到的名单）。
        store.apply(.roster(roster(at: 1_100, ["s1": cell([job("bash-2")])])))
        store.apply(.capabilities([LinkHandshake.Capability.jobsRoster, LinkHandshake.Capability.git]))
        XCTAssertEqual(store.generation, 2)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1)
    }

    // MARK: - 不变式 6：sessions 只影响子会话

    func testInvariant6_SessionsUpdateKeepsTheJobRoster() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([job("bash-1")])])),
        ])

        store.apply(.sessions([try session("sub-1", parent: "s1"), try session("sub-2", parent: "s1")]))
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 2)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1, "会话行更新不清空任务名单")
        XCTAssertEqual(store.children(of: "s1").map(\.sessionId), ["sub-1", "sub-2"])
        XCTAssertEqual(store.rows.map(\.sessionId).sorted(), ["sub-1", "sub-2"])

        // 子会话本轮结束（subagentTiming.active 消失）→ 只剩一个。
        // 会话行**不筛活跃**：结束的子会话仍要在 `rows` 里（面板的"已结束"读它）。
        store.apply(.sessions([try session("sub-1", parent: "s1", active: false)]))
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 0)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1)
        XCTAssertFalse(store.row("sub-1")?.isSubagentActive ?? true)

        // 会话行整份替换：上一批子会话不堆积。
        store.apply(.sessions([try session("sub-3", parent: "s1")]))
        XCTAssertEqual(store.children(of: "s1").map(\.sessionId), ["sub-3"])
        XCTAssertEqual(store.rows.map(\.sessionId).sorted(), ["sub-3"], "rows 与 children 同一次整份替换")
    }

    // MARK: - 用例 a–c：子会话任务归到它所属的列表行（修改项 3）

    /// a：父行 `running=false`、子会话本轮已结束（`subagentTiming.active` 缺失）、
    /// 名单里**子会话那一格**有 1 条活任务 → 父行忙、父行 1 个任务，子格仍是 1。
    ///
    /// 这是"稳定停在完成态"的最小复现：今天的实现只看本格，父行三个来源全空。
    func testA_DescendantJobsCountAsWorkOnTheParentRow() throws {
        let store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["sub-1": cell([job("bash-child")])])),
            .sessions([
                try session("s1", active: false),
                try session("sub-1", parent: "s1", active: false),
            ]),
            .turnOpen("s1", false),
        ])

        let parent = try XCTUnwrap(store.snapshot(sessionId: "s1"))
        XCTAssertFalse(parent.turnOpen, "本轮已结束")
        XCTAssertEqual(parent.liveChildCount, 0, "子会话本轮已结束，不算活跃子会话")
        XCTAssertEqual(parent.liveJobs.map(\.id), ["bash-child"])
        XCTAssertTrue(parent.isBusy, "子会话起的任务还在跑，父行不能显示完成态")
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1)
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 0)
        XCTAssertEqual(store.counts(sessionId: "sub-1").jobs, 1, "子自己的格不变：面板打开子会话仍能看到")
    }

    /// b：同一个 `job.id` 同时出现在父格与子格（连接器把无主任务放进每一格）→ 只计 1。
    func testB_TheSameJobInTwoCellsCountsOnce() throws {
        let store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, [
                "s1": cell([job("bash-shared")]),
                "sub-1": cell([job("bash-shared")]),
            ])),
            .sessions([
                try session("s1", active: false),
                try session("sub-1", parent: "s1", active: false),
            ]),
            .turnOpen("s1", false),
        ])

        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1, "父子两格里的同一件任务只算一次")
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-shared"])
        XCTAssertEqual(store.counts(sessionId: "sub-1").jobs, 1)
    }

    /// c：嵌套——孙会话起的任务归到最外层正式会话行；别的树的同名任务不许串进来。
    func testC_NestedDescendantJobsRollUpToTheOutermostRow() throws {
        let store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, [
                "grand-1": cell([job("bash-deep")]),
                "other": cell([job("bash-other")]),
            ])),
            .sessions([
                try session("s1", active: false),
                try session("sub-1", parent: "s1", active: false),
                try session("grand-1", parent: "sub-1", active: false),
                try session("other", active: false),
            ]),
            .turnOpen("s1", false),
        ])

        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1, "孙会话的任务归到最外层")
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-deep"])
        XCTAssertTrue(store.snapshot(sessionId: "s1")?.isBusy ?? false)
        XCTAssertEqual(store.counts(sessionId: "sub-1").jobs, 1, "中间那一层也看得到自己的后代")
        XCTAssertEqual(store.counts(sessionId: "grand-1").jobs, 1)
        XCTAssertEqual(store.counts(sessionId: "other").jobs, 1, "另一棵树的任务不许串进来")
        XCTAssertEqual(store.snapshot(sessionId: "other")?.liveJobs.map(\.id), ["bash-other"])
    }

    // MARK: - 会话行归入状态机（修改项 2）

    /// d：`.sessions` 是**整份替换**，`childrenByParent` 与 `rows` 同一次写入。
    ///
    /// 活动层只承认整份：第二份里没有的会话就是没有行，不能拿上一份补齐。
    func testD_SessionsReplaceChildrenAndRowsInOneGo() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .sessions([
                try session("s1", active: false),
                try session("sub-1", parent: "s1"),
            ]),
        ])
        XCTAssertEqual(store.children(of: "s1").map(\.sessionId), ["sub-1"])
        XCTAssertEqual(store.rows.map(\.sessionId).sorted(), ["s1", "sub-1"])
        XCTAssertEqual(store.row("sub-1")?.parentSessionId, "s1")

        // 第二份整份里没有 sub-1：两个派生集合同时不含它。
        store.apply(.sessions([
            try session("s1", active: false),
            try session("sub-2", parent: "s1"),
        ]))
        XCTAssertEqual(store.children(of: "s1").map(\.sessionId), ["sub-2"])
        XCTAssertEqual(store.rows.map(\.sessionId).sorted(), ["s1", "sub-2"])
        XCTAssertNil(store.row("sub-1"), "整份替换后上一份的行不准留下来")
    }

    /// e：可用性单调。同一份能力集重复喂不给换代，名单与计数保持原样。
    ///
    /// 这一条是"轮到轮询只读数据、不改档位"的状态机半边：适配层不再每轮喂能力位
    /// 之后，状态机这里必须保证"同一份集合重复喂"是幂等的。
    func testE_RepeatingTheSameCapabilitiesNeverStartsANewGeneration() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([job("bash-1")])])),
        ])
        let generation = store.generation
        XCTAssertTrue(store.isAvailable)

        store.apply(.capabilities(withRoster))

        XCTAssertEqual(store.generation, generation, "同一份能力集不许再换代")
        XCTAssertTrue(store.isAvailable)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1, "名单不被重喂清掉")
        XCTAssertEqual(store.sampledAt, 1_000)
    }

    /// f：重连只切连接态（不变式 4：不清数据）；换代清任务与子会话，**会话行保留**。
    ///
    /// 会话行是 `session/list` 的事实，不属于活动名单：能力重协商只作废"谁在跑"，
    /// 不作废"有哪些会话"。否则面板会在换代后连子会话标签都读不到。
    func testF_ReconnectKeepsRowsAndANewGenerationOnlyClearsTheRoster() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([job("bash-1")])])),
            .sessions([try session("s1", active: false), try session("sub-1", parent: "s1")]),
        ])

        store.apply(.connection(false))
        XCTAssertTrue(store.lastKnown)
        store.apply(.connection(true))
        XCTAssertEqual(store.children(of: "s1").map(\.sessionId), ["sub-1"], "重连不清子会话")
        XCTAssertEqual(store.rows.map(\.sessionId).sorted(), ["s1", "sub-1"], "重连不清会话行")

        // 新一代连接（能力重协商）：任务与子会话作废，会话行保留。
        store.apply(.capabilities(withRoster.union([LinkHandshake.Capability.git])))

        XCTAssertEqual(store.generation, 2)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 0)
        XCTAssertTrue(store.children(of: "s1").isEmpty)
        XCTAssertEqual(store.rows.map(\.sessionId).sorted(), ["s1", "sub-1"],
                       "换代不丢会话行")
        XCTAssertFalse(store.lastKnown, "换代后不再展示上一代的「上次已知」")
    }

    // MARK: - 回放：link-job-roster.md 的样例帧序列

    func testReplayOfRosterSamples() throws {
        var store = ActivityStore()
        store.apply(.capabilities(withRoster))

        let rosterJSON = """
        {"at":1791815149814,
         "sessions":{"session-c026df05-1111-2222-3333-444455556666":{
           "running":[{"id":"bash-2955","kind":"bash",
                       "label":"cd relay && .venv/bin/python -m pytest -q 2>&1 | tail -6",
                       "status":"running","startedAt":1791815149814,"outputTotal":0,
                       "owner":"session-c026df05-1111-2222-3333-444455556666"}],
           "settled":3}}}
        """
        store.apply(.roster(try JSONDecoder().decode(ActivityRoster.self, from: Data(rosterJSON.utf8))))

        let sid = "session-c026df05-1111-2222-3333-444455556666"
        XCTAssertEqual(store.counts(sessionId: sid).jobs, 1)
        XCTAssertEqual(store.settledCount(sessionId: sid), 3)
        XCTAssertEqual(store.snapshot(sessionId: sid)?.liveJobs.first?.kind, "bash")
        XCTAssertEqual(store.sampledAt, 1_791_815_149_814)

        // 注册：第二个任务出现（整格替换，不是增量）。
        store.apply(.frame(frame(at: 1_791_815_150_000, sessionId: sid, running: [
            job("bash-2955", .running, startedAt: 1_791_815_149_814),
            job("bash-2956", .running, startedAt: 1_791_815_150_000),
        ], settled: 3)))
        XCTAssertEqual(store.snapshot(sessionId: sid)?.liveJobs.map(\.id), ["bash-2955", "bash-2956"])

        // 进入 stopping：仍然算在跑。
        store.apply(.frame(frame(at: 1_791_815_160_000, sessionId: sid, running: [
            job("bash-2955", .stopping, startedAt: 1_791_815_149_814),
            job("bash-2956", .running, startedAt: 1_791_815_150_000),
        ], settled: 3)))
        XCTAssertEqual(store.snapshot(sessionId: sid)?.liveJobs.map(\.status), [.stopping, .running])

        // 结算：那一格清空，计数落到 settled。
        store.apply(.frame(frame(at: 1_791_815_180_000, sessionId: sid, running: [], settled: 5)))
        XCTAssertEqual(store.snapshot(sessionId: sid)?.liveJobs, [])
        XCTAssertEqual(store.settledCount(sessionId: sid), 5)
        XCTAssertEqual(store.sampledAt, 1_791_815_180_000)
    }

    // MARK: - 夹具（contracts/activity-ui.md §8）

    func testCannedFixtureMatchesTheUIContract() throws {
        let fixture = ActivityFixture.canned(startedAt: 1_700_000_000_000, at: 1_700_000_060_000)
        XCTAssertEqual(fixture.sessions.count, 3, "父会话 + 两个子会话")
        XCTAssertFalse(fixture.roster.sessions.isEmpty, "夹具名单必须解得出来")

        let store = fixture.applied()
        let parent = ActivityFixture.parentSessionId
        let other = ActivityFixture.otherSessionId

        XCTAssertTrue(store.isAvailable)
        XCTAssertEqual(store.counts(sessionId: parent).jobs, 1)
        XCTAssertEqual(store.counts(sessionId: parent).agents, 2)
        XCTAssertEqual(store.counts(sessionId: other).jobs, 1)
        XCTAssertEqual(store.counts(sessionId: other).agents, 0)

        let parentJobs = try XCTUnwrap(store.snapshot(sessionId: parent)?.liveJobs)
        XCTAssertEqual(parentJobs.map(\.id), [ActivityFixture.jobId])
        XCTAssertEqual(parentJobs[0].label, "npm run lane:l1 -- run --scenario smoke")
        XCTAssertEqual(parentJobs[0].status, .running)
        XCTAssertEqual(parentJobs[0].startedAt, 1_700_000_000_000)
        XCTAssertEqual(store.settledCount(sessionId: parent), ActivityFixture.settledCount)
        XCTAssertEqual(store.settledCount(sessionId: other), 0)

        XCTAssertEqual(store.snapshot(sessionId: other)?.liveJobs.map(\.id), [ActivityFixture.otherJobId])
        XCTAssertTrue(store.snapshot(sessionId: parent)?.isBusy ?? false)

        let children = store.children(of: parent).sorted { $0.sessionId < $1.sessionId }
        XCTAssertEqual(children.map(\.sessionId), [
            ActivityFixture.continuableChildId,
            ActivityFixture.oneShotChildId,
        ].sorted())
        XCTAssertEqual(children.map(\.subagentMode), [.continuable, .oneShot])
        XCTAssertTrue(children.allSatisfy(\.isSubagentActive))

        XCTAssertEqual(fixture.output.count, 3, "输出夹具三段")
        XCTAssertEqual(fixture.output.filter { $0.gapBefore == true }.count, 1, "恰好一次丢段提示")

        // 「没有活」的会话：计数为 0、快照为 nil（视图因此不渲染任何计数）。
        let idle = store.counts(sessionId: "session-nobody")
        XCTAssertEqual(idle.agents, 0)
        XCTAssertEqual(idle.jobs, 0)
        XCTAssertNil(store.snapshot(sessionId: "session-nobody"))
    }

    // MARK: - 工具栏计数与轮次

    func testActiveCountCoversTheCurrentSessionOnly() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, [
                "s1": cell([job("bash-1"), job("bash-2")]),
                "s2": cell([job("bash-3")]),
            ])),
            .sessions([
                try session("sub-1", parent: "s1"),
                try session("sub-2", parent: "s2"),
            ]),
        ])

        store.apply(.turnOpen("s1", false))
        XCTAssertEqual(store.currentSessionId, "s1")
        XCTAssertEqual(store.activeCount, 3, "s1：2 个任务 + 1 个子智能体")

        store.apply(.turnOpen("s2", false))
        XCTAssertEqual(store.activeCount, 2, "切到 s2：1 个任务 + 1 个子智能体")

        store.setCurrentSession("s1")
        XCTAssertEqual(store.activeCount, 3)
        store.setCurrentSession(nil)
        XCTAssertEqual(store.activeCount, 0)
    }

    /// 工具栏计数（`activeCount`）读同一个派生：当前会话设成父行、任务在子格 → 也算 1。
    ///
    /// 评审盲区（设计 §13.6 第 3 条）：`activeCount` 现在也含整棵子树的在跑件数，
    /// 但没有用例；以后改 `counts` 容易忘了它，所以在这里钉一条。
    func testActiveCountIncludesDescendantJobsOfTheCurrentSession() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["sub-1": cell([job("bash-child")])])),
            .sessions([
                try session("s1", active: false),
                try session("sub-1", parent: "s1", active: false),
            ]),
        ])

        store.setCurrentSession("s1")
        XCTAssertEqual(store.activeCount, 1, "父行没有任何本格任务，但子树里有 1 条")

        store.setCurrentSession("sub-1")
        XCTAssertEqual(store.activeCount, 1, "子会话自己的格照旧可读")
    }

    /// 无主任务（`owner` 为空）会被连接器放进**每一格**：去重只挡同一棵树内的重复，
    /// **挡不掉跨树重复**——两行各算 1。
    ///
    /// 这是连接器的既有口径（设计 §10.4 记账），本改动不修；写出来是为了别把
    /// "按 `job.id` 去重"误读成"全局只算一次"。
    func testUnownedJobStillCountsOncePerUnrelatedRow() throws {
        let store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, [
                "s1": cell([job("bash-unowned")]),
                "s2": cell([job("bash-unowned")]),
            ])),
            .sessions([try session("s1", active: false), try session("s2", active: false)]),
        ])

        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1)
        XCTAssertEqual(store.counts(sessionId: "s2").jobs, 1,
                       "跨树重复照旧各算一次：连接器既有的建格口径，不在本改动范围")
    }

    func testTurnOpenAloneMakesTheSessionBusy() {
        let store = makeStore(capabilities: withRoster, inputs: [.turnOpen("s1", true)])
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.isBusy, true)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 0)
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 0)
    }

    func testRosterReplacesWholesaleAndKeepsOlderFramesFromRollingBack() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([job("bash-1")]), "s2": cell([job("bash-2")])])),
        ])
        XCTAssertEqual(store.counts(sessionId: "s2").jobs, 1)

        // 一份只有 s1 的新名单：缺席的 s2 就是"没有活"，不是"未知"。
        store.apply(.roster(roster(at: 1_200, ["s1": cell([job("bash-3")])])))
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1)
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-3"])
        XCTAssertEqual(store.counts(sessionId: "s2").jobs, 0)

        // 名单比某格的推帧旧：那一格保留推帧结果，不许倒退。
        store.apply(.frame(frame(at: 1_400, sessionId: "s1", running: [job("bash-4")], settled: 1)))
        store.apply(.roster(roster(at: 1_300, ["s1": cell([job("bash-stale")], settled: 0)])))
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-4"])
    }

    // MARK: - 覆盖率缺口 G10–G15（`test-coverage.md` §2）

    /// G10：没有任务、轮次也结束，只有子智能体在跑 —— 仍然是"忙"。
    /// `isBusy` 是三个来源的并集，少算子会话会让列表行在子智能体工作时看起来空闲。
    func testG10_OnlyARunningChildMakesTheSessionBusy() throws {
        let store = makeStore(capabilities: withRoster, inputs: [
            .turnOpen("s1", false),
            .sessions([try session("sub-1", parent: "s1")]),
        ])

        let snapshot = try XCTUnwrap(store.snapshot(sessionId: "s1"))
        XCTAssertFalse(snapshot.turnOpen)
        XCTAssertTrue(snapshot.liveJobs.isEmpty, "没有后台任务")
        XCTAssertEqual(snapshot.liveChildCount, 1)
        XCTAssertTrue(snapshot.isBusy, "只有子智能体在跑也算忙")
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 1)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 0)
        XCTAssertEqual(store.activeCount, 1, "工具栏计数把子智能体算进去")
    }

    /// G11：子会话的 `subagentTiming.active` 消失（不在下一份 `sessions` 的活名单里）
    /// → 计数回落；只剩别的子会话。
    func testG11_ChildCountDropsWhenAnActiveChildDisappears() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .sessions([
                try session("sub-1", parent: "s1"),
                try session("sub-2", parent: "s1"),
            ]),
        ])
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 2)

        // sub-1 的 active 消失：它不再进活名单，sub-2 仍在跑。
        store.apply(.sessions([
            try session("sub-1", parent: "s1", active: false),
            try session("sub-2", parent: "s1"),
        ]))
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 1)
        XCTAssertEqual(store.children(of: "s1").map(\.sessionId), ["sub-2"])
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveChildCount, 1)
        XCTAssertEqual(store.rows.map(\.sessionId).sorted(), ["sub-1", "sub-2"],
                       "活名单收窄，会话行照旧是整份")

        // 下一份里一个活的都没有 → 计数归零，且没有任务/轮次时该会话不再有痕迹。
        store.apply(.sessions([try session("sub-2", parent: "s1", active: false)]))
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 0)
        XCTAssertNil(store.snapshot(sessionId: "s1"))
        XCTAssertEqual(store.rows.map(\.sessionId), ["sub-2"], "rows 仍保留这一行（只是不再活跃）")
    }

    /// G12：名单里有、`session/list` 里没有这一行 —— 任务计数照样要给。
    /// 两份输入各自独立；缺了会话行不等于任务没了。
    func testG12_SessionMissingFromTheSessionListKeepsItsJobCounts() throws {
        let store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, [
                "s1": cell([job("bash-1"), job("bash-2")], settled: 1),
            ])),
            // 这一份 session/list 里没有 s1（只有 s2 的子会话）。
            .sessions([try session("sub-1", parent: "s2")]),
        ])

        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 2, "缺会话行不许把任务丢掉")
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 0)
        XCTAssertEqual(store.liveJobs(sessionId: "s1").map(\.id), ["bash-1", "bash-2"])
        XCTAssertEqual(store.settledCount(sessionId: "s1"), 1)
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.isBusy, true)
        // 反过来：会话行里的子会话也照常计入 s2。
        XCTAssertEqual(store.counts(sessionId: "s2").agents, 1)
    }

    /// G13：重连后 reseed 的新名单里没有旧会话 → 旧会话不再显示有活。
    /// 重连本身不清数据（断线期间按最后一份名单显示），清的是那份新名单。
    func testG13_ReconnectReseedDropsSessionsMissingFromTheNewRoster() {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, [
                "s1": cell([job("bash-1")]),
                "s2": cell([job("bash-2")]),
            ])),
        ])
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1)

        store.apply(.connection(false))
        store.apply(.connection(true))
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1, "新名单到达前仍按最后一份显示")

        store.apply(.roster(roster(at: 2_000, ["s2": cell([job("bash-2")])])))
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 0, "旧会话从新名单里消失 = 没有活")
        XCTAssertNil(store.snapshot(sessionId: "s1"))
        XCTAssertEqual(store.counts(sessionId: "s2").jobs, 1, "新名单里的会话照常显示")
    }

    /// G14：运行中能力位从有到无（连接器升级/回退）→ 整块降级：名单清空、
    /// `isAvailable == false`、计数归零，面板与入口都不该再出现。
    func testG14_LosingTheCapabilityClearsTheRosterAndHidesEverything() throws {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([job("bash-1")], settled: 2)])),
            .sessions([try session("sub-1", parent: "s1")]),
            .turnOpen("s1", false),
        ])
        XCTAssertTrue(store.isAvailable)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 1)
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 1)
        XCTAssertEqual(store.generation, 1)

        store.apply(.capabilities(withoutRoster))

        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(store.generation, 2, "能力集合变化即换代")
        XCTAssertNil(store.sampledAt)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 0)
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 0)
        XCTAssertEqual(store.settledCount(sessionId: "s1"), 0)
        XCTAssertEqual(store.activeCount, 0)
        XCTAssertTrue(store.liveJobs(sessionId: "s1").isEmpty)
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs, [])
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveChildCount, 0)
        XCTAssertEqual(store.rows.map(\.sessionId).sorted(), ["sub-1"],
                       "降档清的是活动名单，不是会话行")
    }

    /// G15：`lastKnown` 的迁移。断线置 true（继续按最后一份名单显示）；
    /// 重连只是链路回来，**新名单到达前展示的仍是上次已知**，所以标志仍为 true，
    /// 由 reseed 的那份名单清回 false（`data-model.md` §6 不变式 4）。
    /// 能力位缺失时，不只是计数为 0：`snapshot` / `liveJobs` / `children` 也必须是空的。
    /// 否则面板与工具栏会在"读不到名单"的通道上渲染出内容（模拟器核对时实际发生过）。
    func testG18_WithoutCapabilityEveryDerivedOutputIsEmpty() throws {
        var store = ActivityStore()
        store.apply(.capabilities(withoutRoster))
        store.apply(.roster(roster(at: 10, ["s1": cell([job("bash-1")], settled: 2)])))
        store.apply(.sessions([try session("c1", parent: "s1")]))
        store.apply(.turnOpen("s1", true))

        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(store.counts(sessionId: "s1").agents, 0)
        XCTAssertEqual(store.counts(sessionId: "s1").jobs, 0)
        XCTAssertEqual(store.activeCount, 0)
        XCTAssertEqual(store.settledCount(sessionId: "s1"), 0)
        XCTAssertTrue(store.liveJobs(sessionId: "s1").isEmpty)
        XCTAssertTrue(store.children(of: "s1").isEmpty)
        XCTAssertEqual(store.rows.map(\.sessionId), ["c1"], "会话行不吃能力位：它由 .sessions 写")

        let snapshot = try XCTUnwrap(store.snapshot(sessionId: "s1"), "轮次仍在时 snapshot 不该为 nil")
        XCTAssertTrue(snapshot.turnOpen, "轮次口径不依赖能力位")
        XCTAssertTrue(snapshot.liveJobs.isEmpty)
        XCTAssertEqual(snapshot.liveChildCount, 0)
    }

    func testG15_LastKnownRisesOnDisconnectAndClearsOnTheReseed() {
        var store = makeStore(capabilities: withRoster, inputs: [
            .roster(roster(at: 1_000, ["s1": cell([job("bash-1")])])),
        ])
        XCTAssertFalse(store.lastKnown)

        store.apply(.connection(false))
        XCTAssertTrue(store.lastKnown)
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-1"], "断线不清名单")

        store.apply(.connection(true))
        XCTAssertTrue(store.lastKnown, "链路回来但名单还是旧的，仍在展示上次已知")

        store.apply(.roster(roster(at: 2_000, ["s1": cell([job("bash-2")])])))
        XCTAssertFalse(store.lastKnown, "新名单到达后回到实时")
        XCTAssertEqual(store.snapshot(sessionId: "s1")?.liveJobs.map(\.id), ["bash-2"])
    }
}

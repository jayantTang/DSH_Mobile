import DSHConnectionAPI
import DSHKit
import DSHSessionsDomain
import DSHTestingSupport
import XCTest

/// 027 — 列表的分桶：workspace / 折叠桶（loose）/ 已归档，以及"这台电脑还在干什么"。
///
/// 这一组决定"用户在列表上看到哪些行、按什么顺序"。错一条就是"某个会话不见了"，
/// 而列表长得都一样——所以它只能靠断言，不能靠看。
@MainActor
final class SessionListGroupingTests: SessionsDomainTestCase {

    /// 三桶划分：workspace 里的、没有 workspace 的、被归档的。
    func testGroupingFillsWorkspaceLooseAndArchivedBuckets() async throws {
        stubSessions([
            Wire.session("s7", updatedAt: 6_000, cwd: "/Users/me/proj", asOfSeq: 100),
            Wire.session("s1", updatedAt: 5_000, cwd: "/Users/me/proj", asOfSeq: 100),
            Wire.session("s2", updatedAt: 4_000, cwd: "/Users/me/proj", asOfSeq: 90),
            Wire.session("s3", updatedAt: 3_000, cwd: "/Users/me/other", asOfSeq: 80),
            Wire.session("s4", updatedAt: 2_500, cwd: "/tmp/scratch"),
            Wire.session("s5", updatedAt: 2_000, blank: true, cwd: "/Users/me/proj"),
            Wire.session("s6", updatedAt: 1_000, cwd: "/Users/me/proj", origin: "subagent", parent: "s1"),
        ])
        stubWorkspaces([
            Wire.workspace("w1", path: "/Users/me/proj", title: "proj", sessions: ["s1", "s2", "s7"]),
            Wire.workspace("w2", path: "/Users/me/other", title: "other", sessions: ["s3"]),
        ], archived: ["s3"])
        await model.refresh()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.isUsingFallbackGrouping)
        // w2 唯一的那条被归档了：不能因此留下一个空组。
        XCTAssertEqual(model.groups.map(\.id), ["w1"])
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s7", "s1", "s2"],
                       "inside a group the newest activity comes first")
        XCTAssertEqual(sessionIds(model.groups[0].children["s1"] ?? []), ["s6"],
                       "a subagent transcript hangs under the session that spawned it")
        XCTAssertEqual(sessionIds(model.loose), ["s4"], "a session no workspace accounts for goes to the loose bucket")
        XCTAssertEqual(sessionIds(model.archivedSessions), ["s3"])
        XCTAssertEqual(model.allSessions.count, 7)
        XCTAssertFalse(model.isEmpty)
        XCTAssertNotNil(model.session(withId: "s3"), "an archived session must stay reachable by id")

        // blank 会话默认不上列表；它成为当前会话时至少要能看见（它没归档进 workspace，落在折叠桶）。
        XCTAssertFalse(sessionIds(model.loose).contains("s5"))
        model.currentSessionId = "s5"
        XCTAssertTrue(sessionIds(model.loose).contains("s5"),
                      "the session the app just opened must be reachable even before it has a turn")
    }

    /// 工作区计数：在等用户回答的不能算"运行中"。
    func testLiveWorkspaceSplitsRunningFromWaiting() async throws {
        stubSessions([
            Wire.session("s1", updatedAt: 3_000, running: true, cwd: "/Users/me/proj", asOfSeq: 100),
            Wire.session("s2", updatedAt: 2_500, running: true, cwd: "/Users/me/proj", asOfSeq: 90),
            Wire.session("s3", updatedAt: 2_000, cwd: "/Users/me/proj", asOfSeq: 80),
            Wire.session("s4", updatedAt: 99_000, cwd: "/Users/me/idle", asOfSeq: 70),
            Wire.session("s5", updatedAt: 1_000, blank: true, cwd: "/Users/me/blank"),
        ])
        stubWorkspaces([
            Wire.workspace("w1", path: "/Users/me/proj", title: "proj", sessions: ["s1", "s2", "s3"]),
            Wire.workspace("w2", path: "/Users/me/idle", title: "idle", sessions: ["s4"]),
            Wire.workspace("w3", path: "/Users/me/blank", title: "blank", sessions: ["s5"]),
        ])
        // 视图从 hub 的待答集合填它；这里直接给。
        model.waitingSessionIds = ["s2"]
        await model.refresh()

        let live = model.liveWorkspaces
        XCTAssertEqual(live.map(\.id), ["w1", "w2"],
                       "work in flight sorts first, and a workspace with nothing live disappears")
        XCTAssertEqual(live[0].runningCount, 1, "a session waiting for an answer is not 'running'")
        XCTAssertEqual(live[0].waitingCount, 1)
        XCTAssertEqual(live[0].latestActivity, 3_000)
        XCTAssertEqual(live[1].runningCount, 0)
        XCTAssertEqual(live[1].waitingCount, 0)

        XCTAssertEqual(model.runningCount, 1)
        XCTAssertEqual(model.waitingCount, 1)
        let s1 = try XCTUnwrap(model.allSessions.first { $0.sessionId == "s1" })
        let s2 = try XCTUnwrap(model.allSessions.first { $0.sessionId == "s2" })
        XCTAssertTrue(model.isReallyRunning(s1))
        XCTAssertFalse(model.isReallyRunning(s2), "the host keeps running=true while a question waits")

        // 折叠桶里的运行中会话单独计数，不能被当成"没有"。
        XCTAssertEqual(model.ungroupedRunningCount, 0)
        XCTAssertEqual(model.ungroupedWaitingCount, 0)
    }

    /// 读不到 workspace 列表时按目录兜底，并且**说出来**。
    func testMissingWorkspaceListFallsBackToDirectoryGrouping() async throws {
        stubSessions([
            Wire.session("s1", updatedAt: 3_000, cwd: "/Users/me/proj", asOfSeq: 100),
            Wire.session("s2", updatedAt: 2_000, cwd: "/Users/me/proj", asOfSeq: 90),
            Wire.session("s3", updatedAt: 1_000, cwd: nil, asOfSeq: 80),
        ])
        // 故意不给 workspace/follow 的基线：宿主这次读不到，重试后放弃。
        await model.refresh()

        XCTAssertTrue(model.isUsingFallbackGrouping, "a silent fallback looks exactly like correct grouping")
        XCTAssertEqual(Set(model.groups.map(\.id)), ["/Users/me/proj", "__none__"])
        let directory = try XCTUnwrap(model.groups.first { $0.id == "/Users/me/proj" })
        XCTAssertEqual(directory.title, "proj")
        XCTAssertEqual(sessionIds(directory.sessions), ["s1", "s2"])
        XCTAssertFalse(try XCTUnwrap(model.groups.first { $0.id == "__none__" }).title.isEmpty,
                       "the group with no directory carries the 'unfiled' wording")

        // pin（已知问题，本次不改产品代码）：兜底路径下 DSHKit 的 partition 把每一行都算进
        // 折叠桶（`assigned` 只由 workspace 填），而装配层无条件渲染折叠桶 → 同一行在目录分组
        // 里出现一次、在"未分组"里又一次。这里钉现状，缺口记在汇报里。
        XCTAssertEqual(sessionIds(model.loose).sorted(), ["s1", "s2", "s3"])
        XCTAssertEqual(model.ungroupedRunningCount, 0)
    }
}

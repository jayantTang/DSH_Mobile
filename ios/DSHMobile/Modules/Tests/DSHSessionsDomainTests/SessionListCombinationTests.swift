import DSHConnectionAPI
import DSHKit
import DSHSessionsDomain
import DSHTestingSupport
import XCTest

/// 027 — 两个状态变化挤在同一个窗口里时，`SessionListModel` 怎么收场。
///
/// 单个动作的用例在隔壁（`SessionListArchiveTests`、`SessionListSnapshotTests`）；
/// 这一份钉的是"第一个还没落地、第二个就来了"——生产里由防抖事件与右滑手势
/// 各自制造出来的那种交错。
@MainActor
final class SessionListCombinationTests: SessionsDomainTestCase {

    /// refresh 重入：`refresh()` 没有单飞闸门，第二个 refresh 会真的再发一次；
    /// 但两次跑完之后屏幕上必须是宿主的那一份列表，而不是两次结果的叠加。
    func test_two_overlapping_refreshes_both_go_out_and_leave_one_consistent_list() async {
        let gate = TestGate()
        let entered = LockedCounter()
        let gated = GatedCarrier()
        carrier = gated.inner
        stubStandardList()
        fake.clientOverride = DSHClient(carrier: gated)
        gated.hold = { method in
            guard method == "session/list" else { return }
            entered.bump()
            await gate.wait()
        }

        let first = Task { await model.refresh() }
        let second = Task { await model.refresh() }
        let bothOnTheWire = await waitUntil { entered.value == 2 }
        XCTAssertTrue(bothOnTheWire,
                      "the second refresh never reached the carrier: refresh() would be single-flight")
        // 被拦住的调用还没落到记录里（GatedCarrier 在转发之前停），所以这里只能
        // 从模型自己的状态看：两次都停在 loading，一行都还没画。
        XCTAssertEqual(carrier.calls(to: "session/list").count, 0,
                       "a held call is recorded only once it is forwarded")
        XCTAssertEqual(model.phase, .loading)
        XCTAssertTrue(model.groups.isEmpty, "no row may appear before the host answers")

        await gate.open()
        await first.value
        await second.value

        XCTAssertEqual(carrier.calls(to: "session/list").count, 2,
                       "each refresh sends its own list request")
        XCTAssertEqual(carrier.calls(to: "workspace/follow").count, 2)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s1", "s2"],
                       "two identical answers must not double the rows")
        XCTAssertEqual(model.allSessions.count, 2)
        XCTAssertTrue(model.archivedSessions.isEmpty)
        XCTAssertFalse(model.isShowingSnapshot)
        XCTAssertNotNil(model.lastRefreshed)
        // 同样一份内容只落一次盘：重复的请求不该变成重复的写盘。
        XCTAssertEqual(notes("snapshot.saved").count, 1)
        XCTAssertEqual(notes("snapshot.unchanged").count, 1)
    }

    /// 归档正在打开的那个会话：行照常离开列表，但会话本身还在——仍在"已归档"里、
    /// 仍能按 id 找到，model 也不会替用户把它悄悄关掉。
    func test_archiving_the_session_that_is_open_drops_the_row_but_not_the_session() async {
        stubSessions([
            Wire.session("s1", updatedAt: 3_000, running: true, asOfSeq: 100),
            Wire.session("s2", updatedAt: 2_000, asOfSeq: 90),
        ])
        stubWorkspaces([Wire.workspace("w1", path: "/Users/me/proj", title: "proj", sessions: ["s1", "s2"])])
        await model.refresh()
        model.currentSessionId = "s1"
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s1", "s2"])
        XCTAssertEqual(model.runningCount, 1)

        carrier.unaryResponses["workspace/archiveSession"] = .success(Wire.archivedSet(["s1"]))
        let accepted = await model.setArchived(true, sessionId: "s1")

        XCTAssertTrue(accepted)
        XCTAssertNil(model.archiveError)
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s2"],
                       "the row of the open session leaves the list like any other row")
        XCTAssertEqual(sessionIds(model.archivedSessions), ["s1"],
                       "it stays reachable in the archived section")
        XCTAssertEqual(model.allSessions.count, 2,
                       "archiving hides a row; it must not drop the session")
        XCTAssertNotNil(model.session(withId: "s1"),
                        "navigation must still resolve an archived session by id")
        XCTAssertEqual(model.currentSessionId, "s1",
                       "the model does not close the session the app has open")
        XCTAssertEqual(model.runningCount, 0,
                       "the badge counts the rows on screen, and that row is gone")
        XCTAssertEqual(model.ungroupedRunningCount, 0)
        XCTAssertFalse(model.isEmpty, "the other row is still on screen")
        XCTAssertEqual(carrier.calls(to: "workspace/archiveSession").count, 1)
    }

    /// 归档撤销组合：归档之后**立刻**撤销（中间没有任何刷新），行按宿主返回的
    /// 归档集合回到列表里，两个方向的请求都带对。
    func test_archiving_then_undoing_immediately_restores_the_row() async {
        stubStandardList()
        await model.refresh()

        carrier.unaryResponses["workspace/archiveSession"] = .success(Wire.archivedSet(["s1"]))
        let archived = await model.setArchived(true, sessionId: "s1")
        XCTAssertTrue(archived)
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s2"])

        // 宿主返回的集合里没有这个 id 了：撤销。
        carrier.unaryResponses["workspace/archiveSession"] = .success(Wire.archivedSet([]))
        let undone = await model.setArchived(false, sessionId: "s1")

        XCTAssertTrue(undone)
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(model.archivedSessions.isEmpty)
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s1", "s2"],
                       "the row comes back without waiting for a refresh")

        let calls = carrier.calls(to: "workspace/archiveSession")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].args?["request"]?["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(calls[0].args?["request"]?["archived"]?.boolValue, true)
        XCTAssertEqual(calls[1].args?["request"]?["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(calls[1].args?["request"]?["archived"]?.boolValue, false,
                       "the undo must be sent as archived: false")
    }

    /// 今天这台宿主的归档集合是**单向**的：`archived: false` 它照样回原来那份集合。
    /// 客户端不假装撤销成功——列表跟着宿主返回的集合走，行留在已归档里，也不报错。
    func test_an_undo_the_host_ignores_leaves_the_row_archived_and_reports_no_error() async {
        stubStandardList()
        await model.refresh()

        // This host answers every archive request with the same one-way set.
        carrier.unaryResponses["workspace/archiveSession"] = .success(Wire.archivedSet(["s1"]))
        let archived = await model.setArchived(true, sessionId: "s1")
        XCTAssertTrue(archived)

        let undone = await model.setArchived(false, sessionId: "s1")

        XCTAssertTrue(undone,
                      "the request was accepted; the set it answered with is what decides the list")
        XCTAssertNil(model.archiveError)
        XCTAssertEqual(sessionIds(model.archivedSessions), ["s1"],
                       "the host's archived set is one-way, so the row is still there")
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s2"])

        let calls = carrier.calls(to: "workspace/archiveSession")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].args?["request"]?["archived"]?.boolValue, false,
                       "the client still asks, so a host that supports the undo starts working unchanged")
    }
}

/// 给 hold 闭包用的计数（闭包是 `@Sendable`，会在别的执行器上被调用）。
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// 在主 actor 上轮询到 `condition` 成立，或超过 `deadline` 放弃。
@MainActor
private func waitUntil(deadline: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

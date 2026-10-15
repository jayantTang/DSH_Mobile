import XCTest

@testable import DSHKit

/// 会话列表切分的用例（spec 023 / S3c，T041）。
///
/// 这段判定原来在 `SessionListModel.regroup()` 里、**一条测试都没有**，而它决定"用户在列表上
/// 看到哪些行"：归档的不上、没跑过一轮的不上、子代理挂在父会话下、没归档进 workspace 的进折叠桶。
/// 每一条错都表现为"某个会话不见了"，所以每条都要有断言。
final class SessionGroupingTests: XCTestCase {

    // MARK: - 夹具

    /// 夹具走 JSON 解码：这些类型是宿主报文的 DTO（Codingable），
    /// 用解码构造既省去逐字段拼 memberwise init，也更接近真实输入。
    private func summary(
        _ id: String,
        updatedAt: Double = 1_000,
        running: Bool = false,
        blank: Bool = false,
        parent: String? = nil,
        origin: String? = nil,
        cwd: String? = "/Users/x/project",
        title: String? = nil,
        objective: String? = nil
    ) -> SessionSummary {
        var object: [String: Any] = ["sessionId": id, "updatedAt": updatedAt,
                                     "running": running, "blank": blank]
        if let parent { object["parentSessionId"] = parent }
        if let origin { object["origin"] = origin }
        if let cwd { object["cwd"] = cwd }
        var values: [String: Any] = [:]
        if let title { values["title"] = title }
        if let objective {
            values["goal"] = ["goal": ["id": "g", "revision": 1, "objective": objective]]
        }
        if !values.isEmpty { object["projections"] = ["asOfSeq": 0, "values": values] }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: object)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SessionSummary.self, from: data)
    }

    private func partition(_ sessions: [SessionSummary],
                           archived: Set<String> = [],
                           workspaces: [Workspace] = [],
                           query: String = "",
                           current: String? = nil,
                           lastCreated: String? = nil) -> SessionGrouping.Partition {
        SessionGrouping.partition(sessions: sessions, archivedIds: archived, workspaces: workspaces,
                                  query: query, currentSessionId: current, lastCreatedSessionId: lastCreated)
    }

    /// 会在列表上出现的行 = loose + 目录兜底组（028：口径互斥后的合集断言）。
    private func visibleIds(_ result: SessionGrouping.Partition) -> [String] {
        result.loose.map(\.sessionId) + result.directoryGroups.flatMap(\.sessions).map(\.sessionId)
    }

    // MARK: - 谁上列表

    func testArchivedSessionsAreHidden() {
        let result = partition([summary("a"), summary("b")], archived: ["a"])
        XCTAssertEqual(visibleIds(result), ["b"])
    }

    func testBlankSessionsAreHiddenExceptCurrentAndJustCreated() {
        let sessions = [summary("blank", blank: true), summary("current", blank: true), summary("created", blank: true)]
        let result = partition(sessions, current: "current", lastCreated: "created")
        XCTAssertEqual(Set(visibleIds(result)), ["current", "created"])
    }

    func testShowsInListIsTheOneSharedPredicate() {
        let blank = summary("b", blank: true)
        XCTAssertFalse(SessionGrouping.showsInList(blank, currentSessionId: nil, lastCreatedSessionId: nil))
        XCTAssertTrue(SessionGrouping.showsInList(blank, currentSessionId: "b", lastCreatedSessionId: nil))
        XCTAssertTrue(SessionGrouping.showsInList(blank, currentSessionId: nil, lastCreatedSessionId: "b"))
        let normal = summary("n")
        XCTAssertTrue(SessionGrouping.showsInList(normal, currentSessionId: nil, lastCreatedSessionId: nil))
    }

    // MARK: - 搜索

    func testSearchMatchesTitleCwdAndGoalObjective() {
        let sessions = [
            summary("t", cwd: "/a", title: "修登录"),
            summary("c", cwd: "/Users/x/支付服务"),
            summary("g", cwd: "/b", objective: "把结算跑通"),
            summary("n", cwd: "/c", title: "无关"),
        ]
        XCTAssertEqual(visibleIds(partition(sessions, query: "登录")), ["t"])
        XCTAssertEqual(visibleIds(partition(sessions, query: "支付")), ["c"])
        XCTAssertEqual(visibleIds(partition(sessions, query: "结算")), ["g"])
    }

    func testSearchIsTrimmedAndCaseInsensitive() {
        let sessions = [summary("t", cwd: "/a", title: "Fix Login")]
        XCTAssertEqual(visibleIds(partition(sessions, query: "  fix LOGIN  ")), ["t"])
        XCTAssertTrue(visibleIds(partition(sessions, query: "   ")).count == 1, "全是空白等于不过滤")
    }

    // MARK: - 目录兜底口径（028 缺陷5）

    /// 没有 workspace 列表时，所有顶层会话归目录组，loose 里只剩孤儿子代理；
    /// 不允许同一行既在目录组又在 loose（界面上双行）。
    func testFallbackModePutsTopLevelRowsInDirectoryGroupsAndLooseHoldsOnlyOrphans() {
        let sessions = [summary("a", cwd: "/x"), summary("b", cwd: "/x"),
                        summary("child", parent: "ghost", origin: "subagent")]
        let result = partition(sessions)
        let directoryIds = Set(result.directoryGroups.flatMap(\.sessions).map(\.sessionId))
        XCTAssertEqual(directoryIds, ["a", "b"])
        XCTAssertEqual(result.loose.map(\.sessionId), ["child"])
        XCTAssertTrue(directoryIds.isDisjoint(with: result.loose.map(\.sessionId)),
                      "a row must not appear in both a directory group and loose")
    }

    // MARK: - 子代理

    func testSubagentsRideUnderTheirParentAndDoNotTakeARow() {
        let sessions = [summary("p"), summary("child", parent: "p", origin: "subagent")]
        let result = partition(sessions)
        XCTAssertEqual(visibleIds(result), ["p"], "子代理不单独占行")
        XCTAssertFalse(visibleIds(result).isEmpty)
    }

    func testOrphanSubagentFallsIntoTheLooseBucket() {
        // 父会话不在这一批里（被归档、被过滤、或还没同步到）：子代理不能就这么消失。
        let sessions = [summary("child", parent: "gone", origin: "subagent")]
        XCTAssertEqual(partition(sessions).loose.map(\.sessionId), ["child"])
    }

    // MARK: - workspace 分配

    private func workspace(_ id: String, path: String, title: String, sessions: [String]) -> Workspace {
        Workspace(workspaceId: id, path: path, title: title, sessionIds: sessions)
    }

    func testGroupsFollowTheHostWorkspaceListAndTheUsersOrder() {
        let sessions = [summary("a"), summary("b"), summary("c")]
        let spaces = [workspace("w1", path: "/p1", title: "一", sessions: ["b", "a"]),
                      workspace("w2", path: "/p2", title: "二", sessions: ["c"])]
        let result = partition(sessions, workspaces: spaces)
        XCTAssertTrue(result.hasWorkspaces)
        XCTAssertEqual(result.workspaceGroups.map(\.id), ["w1", "w2"])
        XCTAssertEqual(result.workspaceGroups[0].sessions.map(\.sessionId), ["b", "a"], "成员顺序是用户的顺序")
        XCTAssertEqual(result.workspaceGroups[1].sessions.map(\.sessionId), ["c"])
        XCTAssertTrue(result.loose.isEmpty)
    }

    func testSessionsNotFiledIntoAnyWorkspaceGoLoose() {
        let sessions = [summary("a"), summary("unfiled")]
        let result = partition(sessions, workspaces: [workspace("w1", path: "/p", title: "一", sessions: ["a"])])
        XCTAssertEqual(result.workspaceGroups.count, 1)
        XCTAssertEqual(result.loose.map(\.sessionId), ["unfiled"])
    }

    func testWorkspacesWithNoVisibleMembersAreSkipped() {
        let sessions = [summary("a")]
        let spaces = [workspace("empty", path: "/p", title: "空", sessions: ["gone"]),
                      workspace("w1", path: "/q", title: "有", sessions: ["a"])]
        let result = partition(sessions, workspaces: spaces)
        XCTAssertEqual(result.workspaceGroups.map(\.id), ["w1"], "空分组不占一行（桌面端也这样）")
    }

    func testArchivedMemberIsNotCountedIntoItsWorkspace() {
        let sessions = [summary("a"), summary("b")]
        let spaces = [workspace("w1", path: "/p", title: "一", sessions: ["a", "b"])]
        let result = partition(sessions, archived: ["a"], workspaces: spaces)
        XCTAssertEqual(result.workspaceGroups.first?.sessions.map(\.sessionId), ["b"])
    }

    // MARK: - 目录兜底

    func testWithoutWorkspacesItFallsBackToDirectories() {
        let sessions = [summary("a", cwd: "/Users/x/proj"), summary("b", cwd: "/Users/x/proj"),
                        summary("c", cwd: "/Users/x/other"), summary("none", cwd: nil)]
        let result = partition(sessions)
        XCTAssertFalse(result.hasWorkspaces)
        let ids = Set(result.directoryGroups.map(\.id))
        XCTAssertEqual(ids, ["/Users/x/proj", "/Users/x/other", "__none__"])
        let ungrouped = result.directoryGroups.first { $0.id == "__none__" }
        XCTAssertEqual(ungrouped?.title, "", "空目录名那一组不带文案——文案归 App")
        XCTAssertEqual(ungrouped?.sessions.map(\.sessionId), ["none"])
        let proj = result.directoryGroups.first { $0.id == "/Users/x/proj" }
        XCTAssertEqual(proj?.title, "proj", "目录分组标题取最后一段")
    }

    func testPartitionDoesNotSort() {
        // 排序是 `SessionListOrder` 的事；这里返回**原样的输入顺序**，谁排序谁负责。
        let sessions = [summary("a", updatedAt: 1), summary("b", updatedAt: 999)]
        XCTAssertEqual(visibleIds(partition(sessions)), ["a", "b"])
    }
}

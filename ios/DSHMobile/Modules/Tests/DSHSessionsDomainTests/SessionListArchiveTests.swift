import DSHConnectionAPI
import DSHKit
import DSHSessionsDomain
import DSHTestingSupport
import XCTest

/// 027 — 归档动作（列表右滑那一项）的状态迁移。
///
/// 归档是这份列表上唯一的破坏性动作，所以它有三件事必须成立：宿主确认后**当场**把行
/// 挪进"已归档"（等下一次刷新会让用户以为没生效）、宿主拒绝时行**不消失**、
/// 而且失败要有一句给人看的话。
@MainActor
final class SessionListArchiveTests: SessionsDomainTestCase {

    /// 成功路径：行挪进已归档桶，请求带对了会话与方向。
    func testArchivingMovesTheRowIntoTheArchivedBucket() async throws {
        stubStandardList()
        await model.refresh()
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s1", "s2"])

        carrier.unaryResponses["workspace/archiveSession"] = .success(Wire.archivedSet(["s1"]))
        let accepted = await model.setArchived(true, sessionId: "s1")

        XCTAssertTrue(accepted)
        XCTAssertNil(model.archiveError)
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s2"],
                       "the row must leave the list without waiting for the next refresh")
        XCTAssertEqual(sessionIds(model.archivedSessions), ["s1"])
        XCTAssertEqual(model.ungroupedRunningCount, 0)

        // 宿主返回整份归档集合，列表照它改；请求本身要带 sessionId + archived。
        let call = try XCTUnwrap(carrier.calls(to: "workspace/archiveSession").first)
        XCTAssertEqual(call.args?["request"]?["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(call.args?["request"]?["archived"]?.boolValue, true)
        XCTAssertEqual(carrier.calls(to: "workspace/archiveSession").count, 1)
    }

    /// 失败路径：行留在原地，并留下一句用户能看到的错误。
    func testArchiveFailureKeepsTheRowAndSurfacesAnError() async throws {
        stubStandardList()
        await model.refresh()

        let refusal = DSHRPCFailure(code: "workspace/archive-refused", message: "the host refused the archive")
        carrier.unaryResponses["workspace/archiveSession"] = .failure(refusal)
        let accepted = await model.setArchived(true, sessionId: "s1")

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.archiveError, refusal.localizedDescription)
        XCTAssertFalse(model.archiveError?.isEmpty ?? true, "a failed swipe must have something to show")
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s1", "s2"],
                       "a failed swipe must not drop the row")
        XCTAssertTrue(model.archivedSessions.isEmpty)

        // 归档集合没变，第二次尝试仍要重发（不能因为失败就把请求状态记成"已归档"）。
        carrier.unaryResponses["workspace/archiveSession"] = .success(Wire.archivedSet(["s1"]))
        let second = await model.setArchived(true, sessionId: "s1")
        XCTAssertTrue(second)
        XCTAssertEqual(carrier.calls(to: "workspace/archiveSession").count, 2)
    }

    /// 没连上：不发请求。请求发不出去就不可能成功，谎报成功更糟。
    func testArchiveWithoutALinkSendsNothing() async throws {
        stubStandardList()
        await model.refresh()
        fake.clientOverride = nil

        let accepted = await model.setArchived(true, sessionId: "s1")

        XCTAssertFalse(accepted)
        XCTAssertTrue(carrier.calls(to: "workspace/archiveSession").isEmpty)
        XCTAssertEqual(sessionIds(model.groups[0].sessions), ["s1", "s2"])
        // 028 缺陷4已修：未连接也必须给出原因，否则右滑看起来毫无反应。
        XCTAssertEqual(model.archiveError, "尚未连接")
    }
}

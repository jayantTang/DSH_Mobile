import XCTest
@testable import DSHSessionsDomain
import DSHKit
import DSHConnectionAPI

/// 035：新建会话后列表可见。
///
/// 钉住四件事：创建成功立刻有一行；宿主确认后只剩一行；宿主不确认时如实标未同步；
/// 创建失败不留下残留。
@MainActor
final class SessionListCreateVisibilityTests: SessionsDomainTestCase {

    private func stubCreate(id: String) {
        carrier.unaryResponses["workspace/create"] = .success(.object([
            "workspace": Wire.workspace("w-new", path: "/tmp/proj", title: "proj", sessions: []),
            "created": .bool(true),
        ]))
        carrier.unaryResponses["session/create"] = .success(.object(["sessionId": .string(id)]))
    }

    private func rows(withId id: String) -> [SessionSummary] {
        let grouped = model.groups.flatMap { group in
            group.sessions + group.children.values.flatMap { $0 }
        }
        return (grouped + model.loose).filter { $0.sessionId == id }
    }

    func test_created_session_is_visible_before_the_host_lists_it() async throws {
        stubStandardList()
        stubCreate(id: "new")
        let id = try await model.startSession(directory: "/tmp/proj")
        XCTAssertEqual(id, "new")
        XCTAssertEqual(rows(withId: "new").count, 1, "创建成功后列表必须立刻有这一行")
        XCTAssertEqual(model.pendingState(for: "new"), .syncing)
    }

    func test_host_confirmation_replaces_the_placeholder_without_duplicates() async throws {
        stubStandardList()
        stubCreate(id: "new")
        _ = try await model.startSession(directory: "/tmp/proj")

        stubSessions([
            Wire.session("new", updatedAt: 4_000, blank: true, cwd: "/tmp/proj"),
            Wire.session("s1", updatedAt: 3_000, asOfSeq: 100),
            Wire.session("s2", updatedAt: 2_000, asOfSeq: 90),
        ])
        await model.refresh()

        XCTAssertNil(model.pendingState(for: "new"), "宿主确认后占位必须退场")
        XCTAssertEqual(rows(withId: "new").count, 1, "同一 id 不能出现两行")
        XCTAssertEqual(rows(withId: "new").first?.updatedAt, 4_000, "内容以宿主为准")
    }

    func test_placeholder_is_marked_unsynced_after_the_window() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        model.now = { clock }
        stubStandardList()
        stubCreate(id: "new")
        _ = try await model.startSession(directory: "/tmp/proj")

        clock = clock.addingTimeInterval(SessionListModel.pendingSyncWindow + 1)
        await model.refresh()

        XCTAssertEqual(model.pendingState(for: "new"), .unsynced)
        XCTAssertEqual(rows(withId: "new").count, 1, "未同步也仍然可见、可打开")
    }

    func test_host_title_event_updates_the_placeholder_and_clears_unsynced() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        model.now = { clock }
        stubStandardList()
        stubCreate(id: "new")
        _ = try await model.startSession(directory: "/tmp/proj")
        clock = clock.addingTimeInterval(SessionListModel.pendingSyncWindow + 1)
        await model.refresh()
        XCTAssertEqual(model.pendingState(for: "new"), .unsynced)

        model.noteSessionTitle(id: "new", title: "发送今日日报")

        XCTAssertEqual(model.pendingTitle(for: "new"), "发送今日日报")
        XCTAssertEqual(model.pendingState(for: "new"), .syncing, "宿主已给标题，不再标未同步")
    }

    func test_title_for_an_unknown_session_is_ignored() {
        model.noteSessionTitle(id: "ghost", title: "别人的标题")
        XCTAssertNil(model.pendingTitle(for: "ghost"))
    }

    func test_failed_create_leaves_no_placeholder() async throws {
        stubStandardList()
        carrier.unaryResponses["workspace/create"] = .success(.object([
            "workspace": Wire.workspace("w-new", path: "/tmp/proj", title: "proj", sessions: []),
            "created": .bool(true),
        ]))
        carrier.unaryResponses["session/create"] = .failure(
            DSHRPCFailure(code: "session/conflict", message: "refused"))

        do {
            _ = try await model.startSession(directory: "/tmp/proj")
            XCTFail("失败必须抛错")
        } catch {
            // expected
        }
        XCTAssertTrue(model.pendingCreated.isEmpty, "失败不留下占位")
        XCTAssertNil(model.session(withId: "new"))
    }
}

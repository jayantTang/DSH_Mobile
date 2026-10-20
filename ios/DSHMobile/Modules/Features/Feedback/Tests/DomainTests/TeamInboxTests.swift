import DSHFeedbackDomain
import DSHKit
import DSHTestingSupport
import RelayKit
import XCTest

/// 030 二期（团队收件箱 App 侧）：解析、视角与回信的 Domain 层用例。
/// 断言消息全 ASCII。
@MainActor
final class TeamInboxTests: FeedbackCenterTestCase {

    // MARK: - FR-1 解析

    /// 新负载（source/teamUnread/teamPerspective 齐全）解析正确。
    func test_new_payload_fields_decode() async throws {
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(#"""
        {"ok":true,"teamPerspective":true,"unreadCount":1,
         "threads":[{"threadId":"th_1","subject":"s","status":"open","createdAt":1760000000000,
                     "lastMessageAt":1760000001000,"unread":0,"teamUnread":1,
                     "source":{"kind":"device","deviceModel":"iPhone15,4","appVersion":"1.0",
                               "systemVersion":"26.0","accountHint":"acc_ab12","teamBound":true},
                     "messages":[]}],"notices":[]}
        """#))
        let c = center(store: makeRoot("team-new").store(), interval: 0)
        await c.refreshInbox(force: true)

        XCTAssertTrue(c.teamPerspective, "teamPerspective must reach the model")
        XCTAssertEqual(c.threads.count, 1)
        XCTAssertEqual(c.threads[0].teamUnread, 1)
        XCTAssertEqual(c.threads[0].source?.accountHint, "acc_ab12")
        XCTAssertEqual(c.threads[0].source?.displayLine, "iPhone15,4 · acc_ab12")
    }

    /// 老负载（无新字段）解析成功且全退默认——老服务端照常工作。
    func test_legacy_payload_without_new_fields_decodes() async throws {
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(#"""
        {"ok":true,"unreadCount":0,
         "threads":[{"threadId":"th_1","status":"open","createdAt":1760000000000,
                     "lastMessageAt":1760000001000,"unread":0,"messages":[]}],"notices":[]}
        """#))
        let c = center(store: makeRoot("team-legacy").store(), interval: 0)
        await c.refreshInbox(force: true)

        XCTAssertFalse(c.teamPerspective)
        XCTAssertEqual(c.threads[0].teamUnread, 0)
        XCTAssertNil(c.threads[0].source)
    }

    /// 匿名来信的首行是确定文案。
    func test_anonymous_source_has_a_deterministic_display_line() async throws {
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(#"""
        {"ok":true,"teamPerspective":true,"unreadCount":1,
         "threads":[{"threadId":"th_a","status":"open","createdAt":1760000000000,
                     "lastMessageAt":1760000001000,"unread":0,"teamUnread":1,
                     "source":{"kind":"anonymous","teamBound":true},"messages":[]}],"notices":[]}
        """#))
        let c = center(store: makeRoot("team-anon").store(), interval: 0)
        await c.refreshInbox(force: true)

        XCTAssertEqual(c.threads[0].source?.displayLine, "匿名来信")
    }

    /// source 只有机型、没有账号：仍然给出确定文案（不吞掉机型）。
    func test_source_with_only_a_model_still_reads() async throws {
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(#"""
        {"ok":true,"teamPerspective":true,"unreadCount":0,
         "threads":[{"threadId":"th_m","status":"open","createdAt":1760000000000,
                     "lastMessageAt":1760000001000,"unread":0,"teamUnread":0,
                     "source":{"kind":"device","deviceModel":"iPhone15,4"},"messages":[]}],"notices":[]}
        """#))
        let c = center(store: makeRoot("team-model-only").store(), interval: 0)
        await c.refreshInbox(force: true)

        XCTAssertEqual(c.threads[0].source?.displayLine, "iPhone15,4")
    }

    // MARK: - FR-4 离线视角

    /// 拉取后视角随镜像落盘；另开一个 store 读到同一视角（离线冷启动依据）。
    func test_perspective_persists_across_a_relaunch() async throws {
        let root = makeRoot("team-persist")
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(#"{"ok":true,"teamPerspective":true,"unreadCount":0,"threads":[],"notices":[]}"#))
        let c = center(store: root.store(), interval: 0)
        await c.refreshInbox(force: true)

        XCTAssertTrue(c.teamPerspective)
        XCTAssertTrue(root.store().mirror().teamPerspective, "the mirror must remember the perspective offline")
    }

    // MARK: - FR-5 回信

    /// 团队回信：调 /feedback/append 且**不带** ticketKey，成功后刷新。
    func test_reply_posts_without_a_ticket_and_refreshes() async throws {
        let stub = try makeStub()
        stub.on("/feedback/append", answer: .json(#"{"ok":true,"threadId":"th_1","messageId":"fm_1","createdAt":1760000002000}"#))
        stub.on("/feedback/inbox", answer: .json(#"{"ok":true,"unreadCount":0,"threads":[],"notices":[]}"#))
        let c = center(store: makeRoot("team-reply").store(), interval: 0)

        try await c.reply(to: "th_1", text: "fixed in 0.6.5")

        let appends = stub.requests("/feedback/append")
        XCTAssertEqual(appends.count, 1)
        let body = try XCTUnwrap(appends[0].json)
        XCTAssertEqual(body["threadId"] as? String, "th_1")
        XCTAssertNil(body["ticketKey"] as? String, "a team reply must not carry a ticketKey")
        XCTAssertEqual(body["text"] as? String, "fixed in 0.6.5")
        XCTAssertEqual(stub.count("/feedback/inbox"), 1, "a successful reply refreshes the inbox once")
    }

    /// 回信失败：错误分类抛出，不吞；且不触发刷新。
    func test_reply_failure_is_reported() async throws {
        let stub = try makeStub()
        stub.on("/feedback/append", answer: .json(
            #"{"ok":false,"error":{"code":"feedback/not-found","message":"gone"}}"#, status: 404))
        let c = center(store: makeRoot("team-reply-fail").store(), interval: 0)

        do {
            try await c.reply(to: "th_gone", text: "hi")
            XCTFail("a rejected append must surface as an error")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
        XCTAssertEqual(stub.count("/feedback/inbox"), 0, "a failed reply must not refresh")
    }
}

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

    // MARK: - Per-thread side (v2)

    /// v2 负载的 `mySide` 逐线程到达模型；两栏方向、未读归属、回信入口只看它。
    func test_v2_payload_carries_my_side_per_thread() async throws {
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(#"""
        {"ok":true,"inboxVersion":2,"teamPerspective":true,"unreadCount":1,
         "threads":[
           {"threadId":"th_in","status":"open","createdAt":1760000000000,"lastMessageAt":1760000001000,
            "unread":1,"mySide":"owner",
            "messages":[{"messageId":"u_1","author":"user","body":"help","createdAt":1760000001000},
                        {"messageId":"o_1","author":"owner","body":"answer","createdAt":1760000001500}]},
           {"threadId":"th_own","status":"open","createdAt":1760000002000,"lastMessageAt":1760000002000,
            "unread":0,"mySide":"user",
            "messages":[{"messageId":"u_2","author":"user","body":"mine","createdAt":1760000002000}]}],
         "notices":[]}
        """#))
        let c = center(store: makeRoot("team-v2-side").store(), interval: 0)
        await c.refreshInbox(force: true)

        let incoming = try XCTUnwrap(c.thread("th_in"))
        XCTAssertEqual(incoming.mySide, .owner)
        XCTAssertEqual(incoming.incomingAuthor, .user)
        XCTAssertNotNil(incoming.incomingLetter)
        XCTAssertNotNil(incoming.myLetter)
        XCTAssertTrue(incoming.canReply)
        XCTAssertTrue(c.isUnread(messageId: "u_1"), "one unread user letter on the team side")

        let own = try XCTUnwrap(c.thread("th_own"))
        XCTAssertEqual(own.mySide, .user, "a team account's own letter is on the user side")
        XCTAssertNil(own.incomingLetter, "it must not show up in the inbox")
        XCTAssertNotNil(own.myLetter, "it shows up in sent")
        XCTAssertFalse(own.canReply, "no reply entry for my own letter")
        XCTAssertFalse(c.isUnread(messageId: "u_2"))
        XCTAssertEqual(c.unreadCount, 1, "the badge is the server's number, own letters not counted")
    }

    /// 旧服务端（v1）没有 mySide：团队账号按 teamPerspective 推导一次，仍是团队侧。
    func test_v1_payload_derives_my_side_from_the_account_perspective() async throws {
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(#"""
        {"ok":true,"teamPerspective":true,"unreadCount":1,
         "threads":[{"threadId":"th_1","status":"open","createdAt":1760000000000,
                     "lastMessageAt":1760000001000,"unread":0,"teamUnread":1,
                     "source":{"kind":"device","deviceModel":"iPhone15,4","accountHint":"acc_ab12"},
                     "messages":[{"messageId":"u_1","author":"user","body":"q","createdAt":1760000001000}]}],
         "notices":[]}
        """#))
        let c = center(store: makeRoot("team-v1-side").store(), interval: 0)
        await c.refreshInbox(force: true)

        XCTAssertEqual(c.threads[0].mySide, .owner)
        XCTAssertEqual(c.threads[0].incomingLetter?.author, .user)
        XCTAssertTrue(c.threads[0].canReply)
        XCTAssertTrue(c.isUnread(messageId: "u_1"), "v1 team side reads teamUnread")
    }

    /// 老服务端 + 老镜像：用户侧逐像素不变（mySide 推导为 user，回信入口不出现）。
    func test_v1_payload_without_a_team_perspective_stays_on_the_user_side() async throws {
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(#"""
        {"ok":true,"unreadCount":1,
         "threads":[{"threadId":"th_1","status":"replied","createdAt":1760000000000,
                     "lastMessageAt":1760000001000,"unread":1,
                     "messages":[{"messageId":"m_1","author":"owner","body":"answer","createdAt":1760000001000}]}],
         "notices":[]}
        """#))
        let c = center(store: makeRoot("user-v1-side").store(), interval: 0)
        await c.refreshInbox(force: true)

        XCTAssertEqual(c.threads[0].mySide, .user)
        XCTAssertEqual(c.threads[0].incomingLetter?.author, .owner)
        XCTAssertFalse(c.threads[0].canReply)
        XCTAssertEqual(c.threads[0].counterpartyLine, "DSH Mobile 团队")
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

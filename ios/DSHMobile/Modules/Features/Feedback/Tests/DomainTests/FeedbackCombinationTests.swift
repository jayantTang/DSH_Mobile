@testable import DSHFeedbackDomain
import DSHFoundation
import DSHTestingSupport
import Foundation
import RelayKit
import XCTest

/// `FeedbackCenter` 的状态组合用例：一次提交或一次打开**刚好**落在另一次拉取的
/// 窗口里时，本机的事实（已读、凭据、角标）会不会被冲掉。
///
/// 与隔壁两份的分工：`FeedbackCenterTests` 钉单次调用的出口与节流窗口，
/// `FeedbackLocalStoreTests` 钉镜像的合并语义；这里只钉交错。
@MainActor
final class FeedbackCombinationTests: FeedbackCenterTestCase {

    /// 提交之后立刻拉取：服务端还没把新线程列出来。本地已读不许因此复活，
    /// 凭据不许丢；内容那半以服务端为准（下一次拉取自己把行带回来）。
    func test_a_pull_inside_the_window_after_a_submit_keeps_the_read_state_and_the_ticket() async throws {
        let root = makeRoot("submit-window")
        let tickets = TicketBox()
        // 不碰真实钥匙串：凭据读写都走这个内存实现。
        let store = FeedbackLocalStore(
            root: root.url,
            ticketReader: { _ in tickets.text },
            ticketWriter: { _, text in tickets.write(text) }
        )
        try store.save(unreadMirror())

        let stub = try makeStub()
        let threadOne = wireThreadJSON(
            "th_1", subject: Zh.threadSubject, unread: 1, lastMessageAt: 2_000,
            messages: [wireMessageJSON("m_u1", author: "user", body: Zh.openSpins, at: 1_000),
                       wireMessageJSON("m_1", body: Zh.ownerReply, at: 2_000)]
        )
        stub.on("/feedback/inbox", answer: .json(inboxJSON(threads: [threadOne], unreadCount: 1)))
        stub.on("/feedback/read", answer: .json(markReadJSON(unreadCount: 0)))
        stub.on("/feedback/submit", answer: .json(
            #"{"ok":true,"threadId":"th_new","ticketKey":"tk_new","createdAt":9000}"#))

        let center = center(store: store, token: "dt_test")
        await center.recordsAppeared()
        XCTAssertEqual(center.threads.map(\.threadId), ["th_1"])
        XCTAssertEqual(center.unreadCount, 1)

        // 用户打开过那封回信：服务端确认之后才算读过。
        await center.openThread("th_1")
        XCTAssertFalse(center.isUnread(messageId: "m_1"))
        XCTAssertEqual(center.unreadCount, 0)

        let sent = try await center.submit(text: Zh.userBody, subject: Zh.newThread)
        XCTAssertEqual(sent.threadId, "th_new")
        XCTAssertEqual(sent.ticketKey, "tk_new")
        XCTAssertEqual(center.threads.map(\.threadId), ["th_new", "th_1"],
                       "the new thread is on screen before any pull")
        XCTAssertEqual(center.storedTicketCount, 1)

        // 窗口期：中转还没有把新线程列出来（顶层未读已归零，线程级的 unread 还停在 1）。
        stub.on("/feedback/inbox", answer: .json(inboxJSON(threads: [threadOne], unreadCount: 0)))
        await center.applicationBecameActive()

        XCTAssertNil(center.lastError)
        XCTAssertEqual(stub.count("/feedback/inbox"), 2)
        XCTAssertFalse(center.isUnread(messageId: "m_1"),
                       "a pull must not bring back a reply the user has read")
        XCTAssertEqual(store.mirror().readOwnerMessageIds, ["m_1"])
        XCTAssertEqual(center.unreadCount, 0, "the badge must not climb back on a pull")
        XCTAssertEqual(center.threads.first(where: { $0.threadId == "th_1" })?.unread, 0,
                       "the host's per-thread count is seeding-only; the local read set wins")
        XCTAssertTrue(stub.requests("/feedback/inbox").last?.bodyText.contains("th_new") == true,
                      "the pull must ask about the new thread through its ticket")
        XCTAssertEqual(center.storedTicketCount, 1,
                       "the credential is what makes the thread recoverable")
        XCTAssertNil(center.thread("th_new"),
                     "thread content follows the relay, which has not listed it yet")

        // 服务端知道了这条线程：下一次拉取把行带回来，已读仍然不复活。
        stub.on("/feedback/inbox", answer: .json(inboxJSON(
            threads: [threadOne, wireThreadJSON("th_new", status: "open", lastMessageAt: 9_000, messages: [])],
            unreadCount: 0
        )))
        await center.applicationBecameActive()
        XCTAssertNotNil(center.thread("th_new"))
        XCTAssertFalse(center.isUnread(messageId: "m_1"))
        XCTAssertEqual(center.unreadCount, 0)
    }

    /// 打开一条服务端已经删掉的线程：给一个明确的 not-found，本机已读、角标、
    /// 屏幕上的行都不动，而且不重试。失败时"什么都不动"是既定口径（FR-012）。
    func test_opening_a_thread_the_relay_no_longer_has_fails_loudly_and_moves_nothing() async throws {
        let root = makeRoot("gone-thread")
        let store = root.store()
        try store.save(unreadMirror())

        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(inboxJSON(
            threads: [wireThreadJSON(
                "th_1", subject: Zh.threadSubject, unread: 2, lastMessageAt: 2_000,
                messages: [wireMessageJSON("m_u1", author: "user", body: Zh.openSpins, at: 1_000),
                           wireMessageJSON("m_1", body: Zh.ownerReply, at: 2_000)]
            )],
            unreadCount: 2
        )))
        stub.on("/feedback/read", answer: .json(
            #"{"ok":false,"error":{"code":"feedback/not-found","message":"no thread with that ticket"}}"#,
            status: 404))

        let center = center(store: store, token: "dt_test")
        await center.recordsAppeared()
        XCTAssertEqual(center.unreadCount, 2)

        await center.openThread("th_1")

        XCTAssertEqual(center.lastError, .notFound,
                       "a thread the relay no longer has must read as gone, not as a network failure")
        XCTAssertEqual(stub.count("/feedback/read"), 1, "a 404 is final; there is nothing to retry")
        XCTAssertEqual(center.unreadCount, 2, "it must not clear the badge")
        XCTAssertTrue(center.isUnread(messageId: "m_1"), "and it must not be marked read locally")
        XCTAssertEqual(store.mirror().readOwnerMessageIds, [])
        XCTAssertEqual(center.threads.map(\.threadId), ["th_1"],
                       "the row the user tapped stays on screen")
        XCTAssertTrue(stub.requests("/feedback/read").last?.bodyText.contains(#""threadIds":["th_1"]"#) == true,
                      "the request must name the thread the answer is about")
    }

    /// 真并发刷新：前台恢复与打开记录页同刻到达，只发一次请求。
    ///
    /// 节流关掉（`interval: 0`）之后仍然只发一次，说明挡住第二次的是"已经有一次
    /// 在飞"，不是那 15 秒窗口；两次真的错开了的话，这里会看到两次请求。
    func test_foreground_and_records_appeared_at_the_same_moment_send_one_request() async throws {
        let root = makeRoot("overlap")
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(inboxJSON(unreadCount: 3)))
        let center = center(store: root.store(), interval: 0)

        let foreground = Task { await center.applicationBecameActive() }
        let records = Task { await center.recordsAppeared() }
        await foreground.value
        await records.value

        XCTAssertEqual(stub.count("/feedback/inbox"), 1,
                       "the second entry point must join the pull already in flight")
        XCTAssertNil(center.lastError)
        XCTAssertNotNil(center.lastRefreshedAt)
        XCTAssertFalse(center.isRefreshing)
        XCTAssertEqual(center.unreadCount, 3)
    }
}

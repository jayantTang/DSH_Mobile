@testable import DSHFeedbackDomain
import DSHFoundation
import DSHTestingSupport
import Foundation
import RelayKit
import XCTest

/// 通知正文按需取与四态（设计 §M6.4）：加载中 / 正文 / 需要联网 + 重试 / 已不存在。
///
/// 这一组最关键的一条：**取正文失败不标已读**。
@MainActor
final class FeedbackNoticeTests: FeedbackCenterTestCase {

    private func summaryInbox(unread: Int = 1) -> String {
        inboxJSON(notices: [wireNoticeJSON("nt_1", subject: "weekly", format: "text", read: false, at: 5_000)],
                  unreadCount: unread, inboxVersion: 2,
                  threadsPage: #"{"more":false}"#, noticesPage: #"{"more":false}"#)
    }

    private func bodyAnswer() -> String {
        #"{"ok":true,"notice":{"noticeId":"nt_1","subject":"weekly","body":"REPORT BODY","format":"text","createdAt":5000,"read":false}}"#
    }

    /// 正文失败 → 需要联网 + 重试，且**不发**已读请求；重试成功 → 正文 + 标已读 + 落盘。
    func test_a_failed_body_fetch_does_not_mark_the_notice_read_and_retry_succeeds() async throws {
        let root = makeRoot("notice-retry")
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(summaryInbox()))
        stub.enqueue([
            .json(#"{"ok":false,"error":{"code":"feedback/store-error","message":"boom"}}"#, status: 500),
            .json(bodyAnswer())
        ], for: "/feedback/notice")
        stub.on("/feedback/read", answer: .json(markReadJSON(unreadCount: 0)))

        let center = center(store: root.store(), interval: 0)
        await center.refreshInbox(force: true)
        XCTAssertNil(center.notice("nt_1")?.body, "a v2 summary carries no body")

        let detail = FeedbackNoticeDetail(noticeId: "nt_1", center: center)
        await detail.load()

        XCTAssertEqual(detail.phase, .needsNetwork)
        XCTAssertEqual(stub.count("/feedback/read"), 0, "a failed fetch must not eat the unread")
        XCTAssertTrue(center.isUnread(noticeId: "nt_1"))
        XCTAssertNil(center.notice("nt_1")?.body)
        XCTAssertEqual(center.unreadCount, 1)

        // 重试：同一个入口。
        await detail.load()

        XCTAssertEqual(detail.phase, .ready)
        XCTAssertEqual(center.notice("nt_1")?.body, "REPORT BODY")
        XCTAssertEqual(stub.count("/feedback/read"), 1, "a successful body fetch marks it read")
        XCTAssertFalse(center.isUnread(noticeId: "nt_1"))
        XCTAssertEqual(center.unreadCount, 0)
        XCTAssertTrue(root.store().mirror().notices.first?.bodyCached == true, "the body is cached on disk")
        XCTAssertEqual(root.store().mirror().serverUnreadCount, 0)
    }

    /// 服务端说这条不存在（或不属于这个账号）：显示"已不存在"，不标已读、不重试。
    func test_a_notice_the_server_no_longer_has_reads_as_gone_and_stays_unread() async throws {
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(summaryInbox()))
        stub.on("/feedback/notice", answer: .json(
            #"{"ok":false,"error":{"code":"feedback/not-found","message":"gone"}}"#, status: 404))

        let center = center(store: makeRoot("notice-gone").store(), interval: 0)
        await center.refreshInbox(force: true)

        let detail = FeedbackNoticeDetail(noticeId: "nt_1", center: center)
        await detail.load()

        XCTAssertEqual(detail.phase, .gone)
        XCTAssertEqual(stub.count("/feedback/read"), 0)
        XCTAssertTrue(center.isUnread(noticeId: "nt_1"))
    }

    /// 正文已在镜像里：断网冷启动也能读，不会再发 `/feedback/notice`。
    func test_a_cached_body_opens_offline_without_another_fetch() async throws {
        let root = makeRoot("notice-cache")
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(summaryInbox()))
        stub.on("/feedback/notice", answer: .json(bodyAnswer()))
        stub.on("/feedback/read", answer: .json(markReadJSON(unreadCount: 0)))

        let center = center(store: root.store(), interval: 0)
        await center.refreshInbox(force: true)
        let first = FeedbackNoticeDetail(noticeId: "nt_1", center: center)
        await first.load()
        XCTAssertEqual(first.phase, .ready)
        let fetches = stub.count("/feedback/notice")
        XCTAssertEqual(fetches, 1)

        // 断网：另开一个"冷启动"的中心（同一份镜像），正文已缓存 → 直接可读。
        stub.stop()
        let cold = FeedbackCenter(store: root.store(), minimumRefreshInterval: 0,
                                  endpointProvider: { nil })
        XCTAssertNotNil(cold.cachedNoticeBody("nt_1"))
        let reopened = FeedbackNoticeDetail(noticeId: "nt_1", center: cold)
        await reopened.load()
        XCTAssertEqual(reopened.phase, .ready)
    }

    /// 正文取回来之后：列表里仍是摘要，详情读的是缓存正文；`body` 字段在镜像里是字符串
    /// （旧构建能解码），未取过时是空串 + `bodyCached = false`。
    func test_the_mirror_keeps_a_string_body_for_old_builds() async throws {
        let root = makeRoot("notice-mirror-shape")
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(summaryInbox(unread: 0)))
        stub.on("/feedback/notice", answer: .json(bodyAnswer()))

        let center = center(store: root.store(), interval: 0)
        await center.refreshInbox(force: true)

        let text = try root.mirrorText()
        XCTAssertTrue(text.contains(#""body":"""#), text)
        XCTAssertTrue(text.contains(#""bodyCached":false"#), text)

        let detail = FeedbackNoticeDetail(noticeId: "nt_1", center: center)
        await detail.load()
        XCTAssertEqual(detail.phase, .ready)

        let cached = try root.mirrorText()
        XCTAssertTrue(cached.contains("REPORT BODY"), cached)
        XCTAssertTrue(cached.contains(#""bodyCached":true"#), cached)
    }

    /// F7：详情路由没带正文是契约异常，按失败处理——不缓存成空信、不标已读。
    func test_a_body_less_detail_is_a_failure_and_is_not_cached() async throws {
        let root = makeRoot("notice-no-body")
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(summaryInbox()))
        stub.on("/feedback/notice", answer: .json(
            #"{"ok":true,"notice":{"noticeId":"nt_1","subject":"weekly","format":"text","createdAt":5000,"read":false}}"#))

        let center = center(store: root.store(), interval: 0)
        await center.refreshInbox(force: true)
        XCTAssertNil(center.notice("nt_1")?.body)

        do {
            _ = try await center.fetchNotice("nt_1")
            XCTFail("a body-less notice answer must fail instead of caching an empty letter")
        } catch let error as FeedbackClientError {
            guard case .decoding = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
        }

        XCTAssertNil(center.cachedNoticeBody("nt_1"))
        XCTAssertFalse(root.store().mirror().notices.first?.bodyCached ?? true,
                       "nothing is written as cached")
        XCTAssertEqual(stub.count("/feedback/read"), 0)

        let detail = FeedbackNoticeDetail(noticeId: "nt_1", center: center)
        await detail.load()
        XCTAssertEqual(detail.phase, .needsNetwork)
        XCTAssertTrue(center.isUnread(noticeId: "nt_1"))
        XCTAssertEqual(stub.count("/feedback/read"), 0, "a failed body must not be marked read")
    }
}

@testable import DSHFeedbackDomain
import DSHFoundation
import DSHTestingSupport
import Foundation
import RelayKit
import XCTest

/// 两条列表的分页（设计 §M6）：首页与已加载的更早页合并、去重、无缺口；
/// 底部"加载更早"是**同一个入口**服务两栏，按已加载边界决定推进哪一路。
@MainActor
final class FeedbackPagingTests: FeedbackCenterTestCase {

    // MARK: - Fixtures

    private func threadRow(_ id: String, at millis: Int) -> String {
        wireThreadJSON(id, status: "open", mySide: "user", lastMessageAt: millis,
                       messages: [wireMessageJSON("m_\(id)", body: Zh.ownerReply, at: millis)])
    }

    private func noticeRow(_ id: String, at millis: Int) -> String {
        wireNoticeJSON(id, subject: "s", format: "text", read: false, at: millis)
    }

    private var emptyPage: String { #"{"more":false}"# }

    private func threadsPage(beforeAt millis: Int, threadId: String) -> String {
        #"{"more":true,"nextBefore":{"lastMessageAt":\#(millis),"threadId":"\#(threadId)"}}"#
    }

    private func noticesPage(beforeAt millis: Int, noticeId: String) -> String {
        #"{"more":true,"nextBefore":{"createdAt":\#(millis),"noticeId":"\#(noticeId)"}}"#
    }

    private func inbox(threads: [String] = [], notices: [String] = [],
                       threadsPage: String, noticesPage: String) -> String {
        inboxJSON(threads: threads, notices: notices, unreadCount: 0, inboxVersion: 2,
                  threadsPage: threadsPage, noticesPage: noticesPage)
    }

    // MARK: - Threads

    /// 30/页往回翻：并集 60、无重复、无缺口；到尽头后按钮消失，刷新不会把更早页丢掉。
    func test_thread_pages_merge_without_duplicates_or_gaps_and_survive_a_refresh() async throws {
        let stub = try makeStub()
        let firstPage = (0..<30).map { threadRow("th_\(100 - $0)", at: 3_000_000 - $0 * 1_000) }
        let secondPage = (0..<30).map { threadRow("th_\(70 - $0)", at: 2_400_000 - $0 * 1_000) }

        let first = inbox(threads: firstPage,
                          threadsPage: threadsPage(beforeAt: 2_971_000, threadId: "th_71"),
                          noticesPage: emptyPage)
        let second = inbox(threads: secondPage, threadsPage: emptyPage, noticesPage: emptyPage)
        stub.enqueue([.json(first), .json(second)], for: "/feedback/inbox")

        let center = center(store: makeRoot("paging-threads").store(), interval: 0)
        await center.refreshInbox(force: true)
        XCTAssertEqual(center.threads.count, 30)
        XCTAssertTrue(center.hasEarlier)

        await center.loadEarlier()

        XCTAssertEqual(center.threads.count, 60)
        XCTAssertEqual(Set(center.threads.map(\.threadId)).count, 60, "no duplicates")
        XCTAssertEqual(Set(center.threads.map(\.threadId)), Set((0..<60).map { "th_\(100 - $0)" }),
                       "no gap between the two pages")
        XCTAssertEqual(center.threads.first?.threadId, "th_100", "newest first")
        XCTAssertEqual(center.threads.last?.threadId, "th_41")
        XCTAssertFalse(center.hasEarlier, "the server said there is no older page")
        XCTAssertEqual(center.limits.textChars, 4000)
        XCTAssertEqual(center.limits.textBytes, 12000)

        // 第二页请求带的是第一页的游标，且只推进线程那一路。
        let body = try XCTUnwrap(stub.requests("/feedback/inbox").last?.json)
        let page = try XCTUnwrap(body["threadsPage"] as? [String: Any])
        let before = try XCTUnwrap(page["before"] as? [String: Any])
        XCTAssertEqual(before["lastMessageAt"] as? Int, 2_971_000)
        XCTAssertEqual(before["threadId"] as? String, "th_71")
        XCTAssertNil(body["noticePage"], "the notice path stays put")
        XCTAssertEqual(body["notices"] as? Bool, true,
                       "F10：每页都带两路首页（协议口径），不再用 notices:false 省略通知")

        // 到尽头之后再点不发请求。
        let requests = stub.count("/feedback/inbox")
        await center.loadEarlier()
        XCTAssertEqual(stub.count("/feedback/inbox"), requests)

        // 刷新（只拿到第一页）不能把已加载的更早页丢掉，按钮也不会重新出现。
        stub.enqueue([.json(first)], for: "/feedback/inbox")
        await center.refreshInbox(force: true)
        XCTAssertEqual(center.threads.count, 60, "the cached earlier page is kept")
        XCTAssertFalse(center.hasEarlier)
    }

    // MARK: - Notices

    /// 40/页往回翻：并集 80、无重复；v2 摘要不带正文，正文按需取。
    func test_notice_pages_merge_and_store_summaries_without_a_body() async throws {
        let stub = try makeStub()
        let firstPage = (0..<40).map { noticeRow("nt_\(200 - $0)", at: 2_500_000 - $0 * 1_000) }
        let secondPage = (0..<40).map { noticeRow("nt_\(160 - $0)", at: 1_900_000 - $0 * 1_000) }

        let first = inbox(notices: firstPage,
                          threadsPage: emptyPage,
                          noticesPage: noticesPage(beforeAt: 2_461_000, noticeId: "nt_161"))
        let second = inbox(notices: secondPage, threadsPage: emptyPage, noticesPage: emptyPage)
        stub.enqueue([.json(first), .json(second)], for: "/feedback/inbox")

        let center = center(store: makeRoot("paging-notices").store(), interval: 0)
        await center.refreshInbox(force: true)
        XCTAssertEqual(center.notices.count, 40)
        XCTAssertNil(center.notices.first?.body, "a v2 summary carries no body")
        XCTAssertTrue(center.hasEarlier)

        await center.loadEarlier()

        XCTAssertEqual(center.notices.count, 80)
        XCTAssertEqual(Set(center.notices.map(\.noticeId)).count, 80)
        XCTAssertEqual(Set(center.notices.map(\.noticeId)),
                       Set((0..<80).map { "nt_\(200 - $0)" }))
        XCTAssertEqual(center.notices.first?.noticeId, "nt_200")
        XCTAssertFalse(center.hasEarlier)

        let body = try XCTUnwrap(stub.requests("/feedback/inbox").last?.json)
        let page = try XCTUnwrap(body["noticePage"] as? [String: Any])
        let before = try XCTUnwrap(page["before"] as? [String: Any])
        XCTAssertEqual(before["createdAt"] as? Int, 2_461_000)
        XCTAssertEqual(before["noticeId"] as? String, "nt_161")
        XCTAssertNil(body["threadsPage"], "the thread path stays put")
        XCTAssertEqual(body["notices"] as? Bool, true,
                       "翻通知那一路同样按协议取两路首页")
    }

    // MARK: - Both paths

    /// 两路都有下一页时，先推"已加载边界更靠后（更新）"的那一路；再推另一路；
    /// 两路 `more` 都为 false 时入口消失。
    func test_load_earlier_advances_the_list_whose_loaded_boundary_is_newer() async throws {
        let stub = try makeStub()
        let first = inbox(
            threads: [threadRow("th_100", at: 3_000_000)],
            notices: [noticeRow("nt_200", at: 2_500_000)],
            threadsPage: threadsPage(beforeAt: 2_971_000, threadId: "th_71"),
            noticesPage: noticesPage(beforeAt: 2_461_000, noticeId: "nt_161")
        )
        let threadsSecond = inbox(
            threads: [threadRow("th_70", at: 2_371_000)],
            threadsPage: emptyPage,
            noticesPage: noticesPage(beforeAt: 2_461_000, noticeId: "nt_161")
        )
        let noticesSecond = inbox(
            notices: [noticeRow("nt_160", at: 1_900_000)],
            threadsPage: emptyPage,
            noticesPage: emptyPage
        )
        stub.enqueue([.json(first), .json(threadsSecond), .json(noticesSecond)],
                     for: "/feedback/inbox")

        let center = center(store: makeRoot("paging-both").store(), interval: 0)
        await center.refreshInbox(force: true)
        XCTAssertTrue(center.hasEarlier)

        // 线程边界（2_971_000）比通知边界（2_461_000）更新：先推线程。
        await center.loadEarlier()
        var body = try XCTUnwrap(stub.requests("/feedback/inbox").last?.json)
        XCTAssertNotNil(body["threadsPage"])
        XCTAssertNil(body["noticePage"])
        XCTAssertTrue(center.hasEarlier, "the notices still have an older page")

        // 线程翻到底后，剩下的那一路被推。
        await center.loadEarlier()
        body = try XCTUnwrap(stub.requests("/feedback/inbox").last?.json)
        XCTAssertNotNil(body["noticePage"])
        XCTAssertNil(body["threadsPage"])
        XCTAssertFalse(center.hasEarlier)

        let requests = stub.count("/feedback/inbox")
        await center.loadEarlier()
        XCTAssertEqual(stub.count("/feedback/inbox"), requests, "nothing left to load")
    }

    // MARK: - F1 行数上限与触顶终止态

    /// 注入小上限（5/5）、造 12 条摘要：本机装满后底部是**终止态**（`earlierCapped`），
    /// 不再可点、不再发请求；留下的那 5 条按时间倒序、窗口内无缺口（每条都可见）。
    ///
    /// 12 条里有 7 条在注入的上限之外——这正是要证明的：截断发生在**看得见的上限**上，
    /// 而不是静默丢行；真实上限 5000 下一条不丢由下一条用例（350 条）证明。
    func test_a_reached_row_limit_is_a_visible_terminal_state_not_a_dead_button() async throws {
        let stub = try makeStub()
        let page1 = inbox(notices: (0..<3).map { noticeRow("nt_\(12 - $0)", at: 2_000_000 - $0) },
                          threadsPage: emptyPage,
                          noticesPage: noticesPage(beforeAt: 1_999_998, noticeId: "nt_10"))
        let page2 = inbox(
            notices: [noticeRow("nt_9", at: 1_999_997),
                      noticeRow("nt_8", at: 1_999_996),
                      noticeRow("nt_7", at: 1_999_995)],
            threadsPage: emptyPage,
            noticesPage: noticesPage(beforeAt: 1_999_995, noticeId: "nt_7")
        )
        // 服务端还有第 3、4 页（12 条里的最后 6 条），但本机在上限处就该停。
        stub.enqueue([.json(page1), .json(page2)], for: "/feedback/inbox")

        let center = center(store: makeRoot("paging-cap").store(), interval: 0,
                            rowLimits: FeedbackMirrorLimits(threads: 5, notices: 5))
        await center.refreshInbox(force: true)
        XCTAssertEqual(center.notices.count, 3)
        XCTAssertTrue(center.hasEarlier)

        await center.loadEarlier()

        XCTAssertEqual(center.notices.map(\.noticeId), ["nt_12", "nt_11", "nt_10", "nt_9", "nt_8"],
                       "the retained window is contiguous, newest first")
        XCTAssertEqual(center.notices.count, 5)
        XCTAssertEqual(center.notices.compactMap(\.createdAt),
                       center.notices.compactMap(\.createdAt).sorted(by: >))
        XCTAssertFalse(center.hasEarlier, "no dead button")
        XCTAssertTrue(center.earlierCapped, "the cap shows as a terminal state")

        let requests = stub.count("/feedback/inbox")
        await center.loadEarlier()
        XCTAssertEqual(stub.count("/feedback/inbox"), requests,
                       "a capped list must not keep asking the server")
    }

    /// 默认上限（通知 5000）下造 350 条摘要：翻到底全部可见，不丢一条。
    func test_three_hundred_and_fifty_notices_are_all_reachable_at_the_default_limit() async throws {
        let stub = try makeStub()
        let total = 350
        let pageSize = 40
        var answers: [LoopbackHTTPStub.Answer] = []
        var highest = total
        while highest > 0 {
            let count = min(pageSize, highest)
            let ids = (0..<count).map { highest - $0 }
            let rows = ids.map { noticeRow("nt_\($0)", at: 3_000_000 + $0) }
            let oldest = ids.last!
            let more = oldest > 1
            let page = more
                ? noticesPage(beforeAt: 3_000_000 + oldest, noticeId: "nt_\(oldest)")
                : emptyPage
            answers.append(.json(inbox(notices: rows, threadsPage: emptyPage, noticesPage: page)))
            highest -= count
        }
        stub.enqueue(answers, for: "/feedback/inbox")

        let center = center(store: makeRoot("paging-350").store(), interval: 0)
        await center.refreshInbox(force: true)
        XCTAssertEqual(center.notices.count, pageSize)

        var rounds = 0
        while center.hasEarlier && rounds < 20 {
            rounds += 1
            await center.loadEarlier()
        }

        XCTAssertEqual(center.notices.count, total, "every page is reachable at the default cap")
        XCTAssertEqual(Set(center.notices.map(\.noticeId)).count, total, "no duplicates")
        XCTAssertEqual(center.notices.first?.noticeId, "nt_350")
        XCTAssertEqual(center.notices.last?.noticeId, "nt_1")
        XCTAssertFalse(center.hasEarlier)
        XCTAssertFalse(center.earlierCapped)
        XCTAssertEqual(stub.count("/feedback/inbox"), answers.count)
    }

    // MARK: - F3 加载更早的失败结局

    /// 失败→行变可重试且 `hasEarlier` 仍真；再点成功、失败标记清除。
    func test_a_failed_load_earlier_is_retryable_and_keeps_the_button() async throws {
        let stub = try makeStub()
        let page1 = inbox(notices: (0..<3).map { noticeRow("nt_\(12 - $0)", at: 2_000_000 - $0) },
                          threadsPage: emptyPage,
                          noticesPage: noticesPage(beforeAt: 1_999_998, noticeId: "nt_10"))
        let page2 = inbox(notices: [noticeRow("nt_9", at: 1_999_997),
                                    noticeRow("nt_8", at: 1_999_996)],
                          threadsPage: emptyPage, noticesPage: emptyPage)
        stub.enqueue([
            .json(page1),
            .json(#"{"ok":false,"error":{"code":"feedback/store-error","message":"boom"}}"#, status: 500),
            .json(page2),
        ], for: "/feedback/inbox")

        let center = center(store: makeRoot("paging-fail").store(), interval: 0)
        await center.refreshInbox(force: true)
        XCTAssertTrue(center.hasEarlier)

        await center.loadEarlier()

        XCTAssertTrue(center.loadEarlierFailed)
        XCTAssertTrue(center.hasEarlier, "the row stays, as a retry")
        XCTAssertEqual(center.lastError, .server(status: 500, code: "feedback/store-error"))
        XCTAssertEqual(center.notices.count, 3, "a failed page adds nothing")

        await center.loadEarlier()

        XCTAssertFalse(center.loadEarlierFailed, "a successful retry clears the failure")
        XCTAssertFalse(center.hasEarlier)
        XCTAssertEqual(center.notices.count, 5)
        XCTAssertEqual(stub.count("/feedback/inbox"), 3)
    }

    // MARK: - F5 同毫秒排序

    /// 客户端两处 `threadOrder`（wire 与镜像）与通知排序都按 `(时间 DESC, id DESC)`；
    /// 这里用同毫秒数据钉住 tie-break。
    func test_same_millisecond_rows_break_ties_by_id_descending() {
        let sorted = FeedbackInbox(
            threads: [
                wireThread(threadId: "th_a", lastMessageAt: date(1_000), unread: 0, messages: []),
                wireThread(threadId: "th_b", lastMessageAt: date(1_000), unread: 0, messages: []),
                wireThread(threadId: "th_c", lastMessageAt: date(2_000), unread: 0, messages: []),
            ],
            notices: [
                wireNotice("nt_a", body: nil, createdAt: date(1_000), read: false),
                wireNotice("nt_b", body: nil, createdAt: date(1_000), read: false),
            ],
            unreadCount: 0
        )
        XCTAssertEqual(sorted.threads.map(\.threadId), ["th_c", "th_b", "th_a"])
        XCTAssertEqual(sorted.notices.map(\.noticeId), ["nt_b", "nt_a"])

        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread("th_a", lastMessageAt: 1_000, messages: []),
                          mirrorThread("th_b", lastMessageAt: 1_000, messages: []),
                          mirrorThread("th_c", lastMessageAt: 2_000, messages: [])]
        mirror.notices = [mirrorNotice("nt_a", at: 1_000), mirrorNotice("nt_b", at: 1_000)]
        XCTAssertEqual(mirror.displayThreads.map(\.threadId), ["th_c", "th_b", "th_a"],
                       "the mirror's threadOrder breaks ties the same way")
        XCTAssertEqual(mirror.displayNotices.map(\.noticeId), ["nt_b", "nt_a"])
    }

    // MARK: - F10 分页请求不能改写另一路的游标

    /// 翻线程一页之后：通知那一路的 `more` 与游标都不能被改写，之后仍能翻通知。
    ///
    /// 桩在这里返回的正是旧 bug 的形状——线程翻页的响应里**缺通知页**
    /// （`noticesPage{more:false, nextBefore:null}`，`notices:false` 时服务端就这么回）。
    /// 去掉 `covering` 这条守卫时，这条会红在"通知游标变成到底"。
    func test_advancing_threads_never_clobbers_the_notice_cursor() async throws {
        let stub = try makeStub()
        let page1 = inbox(
            threads: [threadRow("th_a", at: 2_000_000), threadRow("th_b", at: 1_999_990)],
            notices: [noticeRow("nt_10", at: 1_999_980),
                      noticeRow("nt_9", at: 1_999_970),
                      noticeRow("nt_8", at: 1_999_960)],
            threadsPage: threadsPage(beforeAt: 1_999_990, threadId: "th_b"),
            noticesPage: noticesPage(beforeAt: 1_999_960, noticeId: "nt_8")
        )
        let threadsSecond = inbox(
            threads: [threadRow("th_c", at: 1_999_000), threadRow("th_d", at: 1_998_990)],
            threadsPage: emptyPage,
            noticesPage: #"{"more":false,"nextBefore":null}"#
        )
        let noticesSecond = inbox(
            notices: [noticeRow("nt_7", at: 1_999_950), noticeRow("nt_6", at: 1_999_940)],
            threadsPage: emptyPage,
            noticesPage: emptyPage
        )
        stub.enqueue([.json(page1), .json(threadsSecond), .json(noticesSecond)],
                     for: "/feedback/inbox")

        let center = center(store: makeRoot("paging-f10-cursor").store(), interval: 0)
        await center.refreshInbox(force: true)
        XCTAssertEqual(center.notices.count, 3)
        XCTAssertTrue(center.hasEarlier)

        await center.loadEarlier()   // 线程那一路（边界更新）

        XCTAssertEqual(center.threads.count, 4)
        XCTAssertTrue(center.hasEarlier, "the notice path still has a page")
        XCTAssertFalse(center.earlierCapped)
        let body = try XCTUnwrap(stub.requests("/feedback/inbox").last?.json)
        XCTAssertEqual(body["notices"] as? Bool, true,
                       "the request asks for both pages again (protocol), not notices:false")
        XCTAssertNotNil(body["threadsPage"])

        await center.loadEarlier()   // 通知那一路没有被上一次响应带到底

        XCTAssertEqual(center.notices.count, 5, "the notice cursor survived the thread page")
        XCTAssertEqual(stub.count("/feedback/inbox"), 3)
    }

    /// 线程翻完、通知还有下一页时，底部那行仍在、点得动（`hasEarlier` 为真）。
    func test_the_more_row_survives_when_threads_are_exhausted_but_notices_are_not() async throws {
        let stub = try makeStub()
        let page1 = inbox(
            threads: [threadRow("th_a", at: 2_000_000), threadRow("th_b", at: 1_999_990)],
            notices: [noticeRow("nt_10", at: 1_999_980),
                      noticeRow("nt_9", at: 1_999_970),
                      noticeRow("nt_8", at: 1_999_960)],
            threadsPage: threadsPage(beforeAt: 1_999_990, threadId: "th_b"),
            noticesPage: noticesPage(beforeAt: 1_999_960, noticeId: "nt_8")
        )
        let threadsLast = inbox(
            threads: [threadRow("th_c", at: 1_999_000)],
            threadsPage: emptyPage,
            noticesPage: #"{"more":false,"nextBefore":null}"#
        )
        let noticesSecond = inbox(
            notices: [noticeRow("nt_7", at: 1_999_950)],
            threadsPage: emptyPage,
            noticesPage: emptyPage
        )
        stub.enqueue([.json(page1), .json(threadsLast), .json(noticesSecond)],
                     for: "/feedback/inbox")

        let center = center(store: makeRoot("paging-f10-row").store(), interval: 0)
        await center.refreshInbox(force: true)

        await center.loadEarlier()   // 线程翻到尽头

        XCTAssertEqual(center.threads.count, 3)
        XCTAssertTrue(center.hasEarlier, "the row must remain: notices still have an older page")
        XCTAssertFalse(center.earlierCapped)

        await center.loadEarlier()   // 行是能点的

        XCTAssertEqual(center.notices.count, 4)
        XCTAssertFalse(center.hasEarlier)
        let body = try XCTUnwrap(stub.requests("/feedback/inbox").last?.json)
        XCTAssertNotNil(body["noticePage"], "the last tap advanced the notice path")
    }

    // MARK: - F11 v1 回滚时的游标

    /// 先 v2（两路 more=true），再收到 v1 形状（无 inboxVersion、无页字段）：
    /// 两路游标被清掉、`hasEarlier == false`、底部行消失；再切回 v2 时游标按新响应重建。
    func test_a_v1_fallback_clears_the_v2_page_cursors_until_v2_returns() async throws {
        let stub = try makeStub()
        let v2 = inbox(
            threads: [threadRow("th_a", at: 2_000_000)],
            notices: [noticeRow("nt_10", at: 1_999_990)],
            threadsPage: threadsPage(beforeAt: 2_000_000, threadId: "th_a"),
            noticesPage: noticesPage(beforeAt: 1_999_990, noticeId: "nt_10")
        )
        // 旧服务端 / 服务端回滚：形状里没有 inboxVersion，也没有 threadsPage / noticesPage。
        let v1 = inboxJSON(threads: [wireThreadJSON("th_a", status: "open", lastMessageAt: 2_000_000,
                                                     messages: [])],
                           notices: [wireNoticeJSON("nt_10", subject: "s", format: "text",
                                                    read: false, at: 1_999_990)],
                           unreadCount: 1)
        let v2Again = inbox(
            threads: [threadRow("th_a", at: 2_000_000)],
            notices: [noticeRow("nt_10", at: 1_999_990)],
            threadsPage: threadsPage(beforeAt: 2_000_000, threadId: "th_a"),
            noticesPage: noticesPage(beforeAt: 1_999_990, noticeId: "nt_10")
        )
        stub.enqueue([.json(v2), .json(v1), .json(v2Again)], for: "/feedback/inbox")

        let center = center(store: makeRoot("paging-f11").store(), interval: 0)
        await center.refreshInbox(force: true)
        XCTAssertTrue(center.hasEarlier)

        await center.refreshInbox(force: true)   // 服务端回滚到 v1

        XCTAssertFalse(center.hasEarlier, "a v1 answer must not leave a dead 'load earlier'")
        XCTAssertFalse(center.earlierCapped)
        // 只清游标：内容照旧在（v1 的内联正文也能解），不是把镜像清空。
        XCTAssertFalse(center.threads.isEmpty)
        XCTAssertFalse(center.notices.isEmpty)

        await center.refreshInbox(force: true)   // 再切回 v2

        XCTAssertTrue(center.hasEarlier, "the cursors are rebuilt from the new v2 answer")
        let requests = stub.count("/feedback/inbox")
        await center.loadEarlier()
        XCTAssertEqual(stub.count("/feedback/inbox"), requests + 1,
                       "the rebuilt cursors are usable again")
    }

    // MARK: - v1 fallback

    /// 旧服务端没有 `threadsPage` / `noticesPage`：不显示"加载更早"，点了也不发请求。
    func test_a_v1_answer_offers_no_paging_at_all() async throws {
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(inboxJSON(unreadCount: 1)))
        let center = center(store: makeRoot("paging-v1").store(), interval: 0)

        await center.refreshInbox(force: true)

        XCTAssertFalse(center.hasEarlier)
        let requests = stub.count("/feedback/inbox")
        await center.loadEarlier()
        XCTAssertEqual(stub.count("/feedback/inbox"), requests)
        XCTAssertEqual(center.limits, .fallback, "a v1 answer carries no limits: use the compile-time default")
    }
}

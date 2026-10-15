@testable import DSHFeedbackDomain
import DSHFoundation
import DSHTestingSupport
import Foundation
import RelayKit
import XCTest

/// `FeedbackCenter`: when it pulls, what a pull is allowed to change, what a
/// failure is allowed to change (nothing), and the three technical facts a
/// submit carries.
///
/// The centre is driven over a **real** loopback HTTP endpoint
/// (`LoopbackHTTPStub`), because `FeedbackCenter` builds its own
/// `RelayFeedbackClient` from a relay URL and never hands it a session: there is
/// no fake to inject, and `URLProtocol.registerClass` does not reach a session
/// created from a private `URLSessionConfiguration.ephemeral`. Answering over a
/// socket is what makes the request count observable, which is what the throttle
/// case needs.
///
/// Not covered here, deliberately:
///
/// * the window's *expired* side. `refreshInbox` reads `Date()` directly and the
///   clock is not injectable, so "waited long enough" cannot be tested without
///   sleeping; `minimumRefreshInterval: 0` stands in for "always allowed".
/// * `submit` succeeding. It writes the pickup credential straight to the real
///   keychain and `FeedbackLocalStore.save(_ ticket:)` has no injection seam —
///   a unit test would leave `feedback.tickets` on the developer's machine. The
///   failure path (no endpoint) is covered instead; the success path stays with
///   the simulator lanes.
@MainActor
final class FeedbackCenterTests: XCTestCase {

    private var stub: LoopbackHTTPStub!
    /// Every case gets its own mirror root; they are all removed in `tearDown`,
    /// so no case leaves a directory behind even if it fails halfway.
    private var roots: [TempFeedbackRoot] = []

    override func tearDown() {
        stub?.stop()
        stub = nil
        for root in roots { root.remove() }
        roots = []
        super.tearDown()
    }

    private func makeRoot(_ label: String) -> TempFeedbackRoot {
        let root = TempFeedbackRoot(label: label)
        roots.append(root)
        return root
    }

    private func makeStub() throws -> LoopbackHTTPStub {
        let stub = try LoopbackHTTPStub()
        self.stub = stub
        return stub
    }

    /// A center pointed at one loopback endpoint; `interval` is the throttle.
    private func center(
        store: FeedbackLocalStore,
        interval: TimeInterval = 0,
        url: URL? = nil,
        token: String? = nil
    ) -> FeedbackCenter {
        let target = url ?? stub.baseURL
        return FeedbackCenter(store: store, minimumRefreshInterval: interval, endpointProvider: {
            FeedbackCenter.Endpoint(url: target, deviceToken: token)
        })
    }

    /// A mirror with one owner reply it has not read and one unread notice.
    private func unreadMirror() -> FeedbackMirror {
        var mirror = FeedbackMirror()
        mirror.threads = [mirrorThread("th_1", subject: Zh.threadSubject, lastMessageAt: 2_000,
                                       messages: [mirrorUserMessage("m_u1", at: 1_000),
                                                  mirrorOwnerMessage("m_1", at: 2_000)])]
        mirror.notices = [mirrorNotice("n_1", body: Zh.noticeBody, at: 3_000)]
        return mirror
    }

    // MARK: - Offline

    /// A failed pull changes nothing: the badge keeps its value, nothing is
    /// marked read, and the failure is reported rather than swallowed. An
    /// answered failure is a different case from an unreachable relay.
    func test_an_offline_refresh_marks_nothing_and_reports_a_network_failure() async throws {
        let root = makeRoot("offline")
        let store = root.store()
        try store.save(unreadMirror())

        let dead = try makeStub()
        let offline = center(store: store)
        XCTAssertEqual(offline.unreadCount, 2)
        XCTAssertNil(offline.lastError)

        dead.stop()
        await offline.applicationBecameActive()

        if case .network = offline.lastError {} else {
            XCTFail("expected a network failure, got \(String(describing: offline.lastError))")
        }
        XCTAssertEqual(offline.unreadCount, 2)
        XCTAssertTrue(offline.isUnread(messageId: "m_1"))
        XCTAssertTrue(offline.isUnread(noticeId: "n_1"))
        XCTAssertEqual(store.mirror().readOwnerMessageIds, [])

        // Opening a thread while offline is not enough either: the mark waits for
        // the server, so the local read set stays empty.
        await offline.openThread("th_1")
        XCTAssertTrue(offline.isUnread(messageId: "m_1"))
        XCTAssertEqual(store.mirror().readOwnerMessageIds, [])

        // The relay answering with something other than its envelope is a server
        // failure, not a decoding panic and not a silent success.
        let broken = try makeStub()
        broken.on("/feedback/inbox", answer: .json(notTheEnvelope, status: 500))
        let failing = center(store: store)
        await failing.refreshInbox(force: true)
        XCTAssertEqual(failing.lastError, .server(status: 500, code: nil))

        // No endpoint at all (a phone that never paired and has no built-in
        // relay): a submit fails loudly and inserts no thread.
        let bare = FeedbackCenter(store: makeRoot("bare").store(),
                                  minimumRefreshInterval: 0, endpointProvider: { nil })
        do {
            _ = try await bare.submit(text: Zh.userBody)
            XCTFail("expected submit to fail without an endpoint")
        } catch let error as FeedbackClientError {
            XCTAssertEqual(error, .network("no-relay-endpoint"))
        }
        XCTAssertTrue(bare.threads.isEmpty)
    }

    // MARK: - A pull that succeeds

    /// What a successful pull is allowed to take from the server: the unread
    /// total, the content, and the account-level notice read state — but not the
    /// thread read state, which only opening something may change.
    func test_a_successful_pull_takes_the_server_unread_and_notice_read_state() async throws {
        let root = makeRoot("pull")
        let store = root.store()
        try store.save(unreadMirror())

        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(inboxJSON(
            threads: [wireThreadJSON("th_1", subject: Zh.threadSubject, unread: 2, lastMessageAt: 5_000,
                                     messages: [wireMessageJSON("m_u1", author: "user", body: Zh.openSpins, at: 1_000),
                                                wireMessageJSON("m_1", body: Zh.ownerReply, at: 2_000),
                                                wireMessageJSON("m_9", body: Zh.fixedReply, format: "html", at: 5_000)])],
            notices: [wireNoticeJSON("n_1", body: Zh.noticeBody, read: true, at: 3_000),
                      wireNoticeJSON("n_2", body: Zh.noticeBody2, read: false, at: 4_000)],
            unreadCount: 5
        )))

        let center = center(store: store, interval: 3_600, token: "dt_test")
        await center.applicationBecameActive()

        XCTAssertNil(center.lastError)
        XCTAssertNotNil(center.lastRefreshedAt)

        // What actually went out: a POST under the loopback origin, carrying this
        // phone's token and an empty ticket list (anonymous pull).
        let sent = try XCTUnwrap(stub.requests("/feedback/inbox").first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["authorization"], "Bearer dt_test")
        XCTAssertEqual(sent.headers["content-type"], "application/json")
        XCTAssertTrue(sent.bodyText.contains(#""tickets":[]"#), sent.bodyText)

        // The server's total wins when it is the larger of the two.
        XCTAssertEqual(center.unreadCount, 5)
        XCTAssertEqual(center.threads.map(\.threadId), ["th_1"])
        XCTAssertEqual(center.threads[0].messages.count, 3)
        XCTAssertEqual(center.threads[0].messages[2].bodyFormat, .html)
        // Two owner replies, neither opened on this phone.
        XCTAssertEqual(center.threads[0].unread, 2)
        XCTAssertTrue(center.isUnread(messageId: "m_9"))
        // The notice was read on another device under the same account, so its
        // dot is gone here too; the other one stays.
        XCTAssertFalse(center.isUnread(noticeId: "n_1"))
        XCTAssertTrue(center.isUnread(noticeId: "n_2"))

        // And it is on disk: a fresh center over the same root reads the same.
        let reopened = FeedbackCenter(store: store, minimumRefreshInterval: 3_600, endpointProvider: { nil })
        XCTAssertEqual(reopened.threads.map(\.threadId), ["th_1"])
        XCTAssertTrue(reopened.isUnread(messageId: "m_9"))
        XCTAssertFalse(reopened.isUnread(noticeId: "n_1"))
    }

    // MARK: - Throttle

    /// The two entry points share one window: a second pull inside it sends no
    /// request and does not even move the timestamp; `force` bypasses it, and an
    /// interval of zero disables it.
    func test_records_appeared_and_foreground_share_one_throttle_window() async throws {
        let root = makeRoot("throttle")
        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(inboxJSON(unreadCount: 1)))

        let throttled = center(store: root.store(), interval: 3_600)
        await throttled.applicationBecameActive()
        XCTAssertEqual(stub.count("/feedback/inbox"), 1)
        let firstStamp = try XCTUnwrap(throttled.lastRefreshedAt)

        await throttled.recordsAppeared()
        XCTAssertEqual(stub.count("/feedback/inbox"), 1)
        XCTAssertEqual(throttled.lastRefreshedAt, firstStamp)

        await throttled.applicationBecameActive()
        XCTAssertEqual(stub.count("/feedback/inbox"), 1)

        // `force` is the escape hatch the pull-everything paths use.
        await throttled.refreshInbox(force: true)
        XCTAssertEqual(stub.count("/feedback/inbox"), 2)

        // Interval zero: every call goes out, even back to back.
        let eager = center(store: makeRoot("eager").store(), interval: 0)
        await eager.applicationBecameActive()
        await eager.recordsAppeared()
        XCTAssertEqual(stub.count("/feedback/inbox"), 4)

        // The unanswered branch: when the relay never answers, the failure is
        // recorded and the window did not open (the timestamp only moves on a
        // successful pull).
        let silent = try LoopbackHTTPStub()
        defer { silent.stop() }
        let unanswered = center(store: makeRoot("unanswered").store(), url: silent.baseURL)
        silent.stop()
        await unanswered.applicationBecameActive()
        XCTAssertNil(unanswered.lastRefreshedAt)
        XCTAssertNotNil(unanswered.lastError)
    }

    // MARK: - Marking read

    /// Opening a thread or a notice marks it read only after the server confirms;
    /// the answer's `unreadCount` is what the badge shows, and the mark survives
    /// into the next launch.
    func test_opening_a_thread_marks_read_only_after_the_server_confirms() async throws {
        let root = makeRoot("open")
        let store = root.store()
        try store.save(unreadMirror())

        let stub = try makeStub()
        stub.on("/feedback/inbox", answer: .json(inboxJSON(
            threads: [wireThreadJSON("th_1", subject: Zh.threadSubject, unread: 1, lastMessageAt: 2_000,
                                     messages: [wireMessageJSON("m_u1", author: "user", body: Zh.openSpins, at: 1_000),
                                                wireMessageJSON("m_1", body: Zh.ownerReply, at: 2_000)])],
            notices: [wireNoticeJSON("n_1", body: Zh.noticeBody, read: false, at: 3_000)],
            unreadCount: 2
        )))
        stub.enqueue([.json(markReadJSON(unreadCount: 1)), .json(markReadJSON(unreadCount: 0))],
                     for: "/feedback/read")

        let center = center(store: store, token: "dt_test")
        await center.recordsAppeared()
        XCTAssertEqual(center.threads[0].unread, 1)
        XCTAssertEqual(center.unreadCount, 2)

        await center.openThread("th_1")

        XCTAssertEqual(center.threads[0].unread, 0)
        XCTAssertFalse(center.isUnread(messageId: "m_1"))
        // The server's remaining total is what the badge shows.
        XCTAssertEqual(center.unreadCount, 1)
        let read = try XCTUnwrap(stub.requests("/feedback/read").first)
        XCTAssertTrue(read.bodyText.contains(#""threadIds":["th_1"]"#), read.bodyText)
        XCTAssertTrue(read.bodyText.contains(#""noticeIds":[]"#), read.bodyText)
        XCTAssertEqual(store.mirror().readOwnerMessageIds, ["m_1"])

        await center.openNotice("n_1")

        XCTAssertFalse(center.isUnread(noticeId: "n_1"))
        XCTAssertEqual(center.unreadCount, 0)
        let noticeRead = try XCTUnwrap(stub.requests("/feedback/read").last)
        XCTAssertTrue(noticeRead.bodyText.contains(#""noticeIds":["n_1"]"#), noticeRead.bodyText)

        // Read state is local fact, so the next launch still knows.
        let reopened = FeedbackCenter(store: store, minimumRefreshInterval: 0, endpointProvider: { nil })
        XCTAssertEqual(reopened.threads[0].unread, 0)
        XCTAssertFalse(reopened.isUnread(noticeId: "n_1"))
        XCTAssertEqual(reopened.unreadCount, 0)
    }

    // MARK: - Technical info

    /// The three facts shown in the composer are the same three sent with the
    /// draft; both come from `DeviceInfo`, so they cannot drift.
    func test_technical_info_is_the_platform_facts_a_submit_would_send() {
        let info = FeedbackCenter.technicalInfo

        XCTAssertEqual(info.appVersion, DeviceInfo.appVersion)
        XCTAssertEqual(info.deviceModel, DeviceInfo.deviceModel)
        XCTAssertEqual(info.systemVersion, DeviceInfo.systemVersion)
        XCTAssertEqual(FeedbackCenter.systemVersion, DeviceInfo.systemVersion)

        XCTAssertFalse(info.appVersion.isEmpty)
        XCTAssertFalse(info.deviceModel.isEmpty)
        XCTAssertFalse(info.systemVersion.isEmpty)
        // Placeholders or a missing bundle would show up as an empty or odd value.
        XCTAssertNotEqual(info.appVersion, " ()")
        XCTAssertTrue(info.appVersion.contains("("), info.appVersion)
        XCTAssertTrue(info.appVersion.contains(")"), info.appVersion)
        XCTAssertTrue(info.deviceModel.allSatisfy { $0.isASCII }, info.deviceModel)
        // `systemVersion` is asserted as "one line, not blank" rather than ASCII:
        // iOS answers `UIDevice.systemVersion` ("26.6"), while the macOS branch is
        // `ProcessInfo.operatingSystemVersionString`, which is **localized**
        // ("版本26.6.2（版号25G83）" on a Chinese-locale Mac). Pinning ASCII here
        // would fail on the host this suite runs on, and pinning the macOS text
        // would fail on iOS.
        XCTAssertFalse(info.systemVersion.contains("\n"), info.systemVersion)
        XCTAssertLessThan(info.systemVersion.count, 100, info.systemVersion)
    }
}

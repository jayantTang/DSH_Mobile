@testable import DSHFeedbackDomain
import DSHFoundation
import DSHTestingSupport
import RelayKit
import XCTest

/// 030c：崩溃报告经反馈通道投递（一次一封、失败留队、不重复发）。
/// 断言消息全 ASCII。
@MainActor
final class CrashReportFlushTests: FeedbackCenterTestCase {

    private func archive(_ root: TempFeedbackRoot) -> CrashReportArchive {
        CrashReportArchive(root: root.url)
    }

    private func report(_ id: String, at seconds: TimeInterval = 1_760_000_000) -> CrashReport {
        CrashReport(id: id, exceptionType: "EXC_BAD_ACCESS", signal: "SIGSEGV", scene: .unknown,
                    frames: ["DSHMobile @0x1a2b"], appVersion: "1.0",
                    buildVersion: "20261013.2236", systemVersion: "26.6.2",
                    deviceModel: "iPhone12,1", occurredAt: Date(timeIntervalSince1970: seconds))
    }

    private func center(_ root: TempFeedbackRoot, archive: CrashReportArchive) -> FeedbackCenter {
        FeedbackCenter(store: root.store(), minimumRefreshInterval: 0,
                       endpointProvider: { FeedbackCenter.Endpoint(url: self.stub.baseURL, deviceToken: nil) },
                       crashArchive: archive)
    }

    /// One queued crash becomes one letter, and the queue is emptied.
    func test_a_queued_crash_becomes_one_letter() async throws {
        let stub = try makeStub()
        stub.on("/feedback/submit", answer: .json(#"{"ok":true,"threadId":"th_c","ticketKey":"fk_1","createdAt":1760000000000}"#))
        let root = makeRoot("crash-send")
        let archive = archive(root)
        archive.append(report("sig-1"))
        let c = center(root, archive: archive)

        let sent = await c.flushCrashReports()

        XCTAssertEqual(sent, 1)
        XCTAssertEqual(stub.count("/feedback/submit"), 1)
        let body = try XCTUnwrap(stub.requests("/feedback/submit").first?.json)
        XCTAssertEqual(body["subject"] as? String, "崩溃报告：EXC_BAD_ACCESS (SIGSEGV)")
        let text = try XCTUnwrap(body["text"] as? String)
        XCTAssertTrue(text.contains("20261013.2236"), text)
        XCTAssertTrue(text.contains("DSHMobile @0x1a2b"), text)
        XCTAssertEqual(body["clientRef"] as? String, "sig-1", "the signature is the idempotency key")
        XCTAssertTrue(archive.pending().isEmpty, "a delivered report leaves the queue")
    }

    /// Flushing twice sends nothing the second time: the same crash is one letter.
    func test_a_second_flush_sends_nothing() async throws {
        let stub = try makeStub()
        stub.on("/feedback/submit", answer: .json(#"{"ok":true,"threadId":"th_c","ticketKey":"fk_1","createdAt":1760000000000}"#))
        let root = makeRoot("crash-once")
        let archive = archive(root)
        archive.append(report("sig-1"))
        let c = center(root, archive: archive)

        let first = await c.flushCrashReports()
        let second = await c.flushCrashReports()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(stub.count("/feedback/submit"), 1)
    }

    /// Two different crashes are two letters, oldest first.
    func test_two_crashes_are_two_letters_oldest_first() async throws {
        let stub = try makeStub()
        stub.on("/feedback/submit", answer: .json(#"{"ok":true,"threadId":"th_c","ticketKey":"fk_1","createdAt":1760000000000}"#))
        let root = makeRoot("crash-two")
        let archive = archive(root)
        archive.append(report("newer", at: 1_760_000_900))
        archive.append(report("older", at: 1_760_000_000))
        let c = center(root, archive: archive)

        let sent = await c.flushCrashReports()
        XCTAssertEqual(sent, 2)
        let refs = stub.requests("/feedback/submit").compactMap { $0.json?["clientRef"] as? String }
        XCTAssertEqual(refs, ["older", "newer"], "the queue drains oldest first")
    }

    /// Offline: nothing is sent, nothing is lost, and no retry storm starts.
    func test_an_unreachable_relay_keeps_the_report_queued() async throws {
        let stub = try makeStub()
        stub.stop()
        let root = makeRoot("crash-offline")
        let archive = archive(root)
        archive.append(report("sig-1"))
        let c = center(root, archive: archive)

        let sent = await c.flushCrashReports()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(archive.pending().count, 1, "the report waits for a reachable relay")
        XCTAssertEqual(stub.count("/feedback/submit"), 0)
    }

    /// A rejected submission (server said no) keeps it queued as well — the same
    /// rule as offline, so nothing is silently dropped.
    func test_a_rejected_submission_keeps_the_report_queued() async throws {
        let stub = try makeStub()
        stub.on("/feedback/submit", answer: .json(#"{"ok":false,"error":{"code":"feedback/rate-limited"}}"#, status: 429))
        let root = makeRoot("crash-rejected")
        let archive = archive(root)
        archive.append(report("sig-1"))
        let c = center(root, archive: archive)

        let sent = await c.flushCrashReports()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(archive.pending().count, 1)
    }

    /// No relay endpoint configured at all: stay quiet rather than spin.
    func test_without_an_endpoint_nothing_is_attempted() async throws {
        let root = makeRoot("crash-no-endpoint")
        let archive = archive(root)
        archive.append(report("sig-1"))
        let c = FeedbackCenter(store: root.store(), minimumRefreshInterval: 0,
                               endpointProvider: { nil }, crashArchive: archive)
        let sent = await c.flushCrashReports()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(archive.pending().count, 1)
    }

    /// The foreground hook drains the queue, so a crash captured at launch is
    /// delivered by the next `applicationBecameActive()`.
    func test_becoming_active_flushes_the_queue() async throws {
        let stub = try makeStub()
        stub.on("/feedback/submit", answer: .json(#"{"ok":true,"threadId":"th_c","ticketKey":"fk_1","createdAt":1760000000000}"#))
        stub.on("/feedback/inbox", answer: .json(#"{"ok":true,"unreadCount":0,"threads":[],"notices":[]}"#))
        let root = makeRoot("crash-active")
        let archive = archive(root)
        archive.append(report("sig-1"))
        let c = center(root, archive: archive)

        await c.applicationBecameActive()

        XCTAssertEqual(stub.count("/feedback/submit"), 1)
        XCTAssertTrue(archive.pending().isEmpty)
    }
}

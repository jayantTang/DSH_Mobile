import DSHFoundation
import XCTest

/// 030c：崩溃报告的本地存档（有界、去重、待发队列）。
/// 断言消息全 ASCII；这里只测纯逻辑，MetricKit 的转换在 App target 内无法单测。
final class CrashReportTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-crash-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func report(id: String = "sig-1", build: String = "20261013.2233",
                        exception: String = "EXC_BAD_ACCESS", frame: String = "DSHMobile @0x1a2b",
                        at: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> CrashReport {
        CrashReport(id: id, exceptionType: exception, signal: "SIGSEGV", scene: .unknown,
                    frames: [frame, "libswiftCore.dylib @0x9"], appVersion: "1.0",
                    buildVersion: build, systemVersion: "26.6.2", deviceModel: "iPhone12,1",
                    occurredAt: at)
    }

    /// A fresh archive has nothing queued and does not create a file.
    func test_an_empty_archive_has_no_pending_reports() {
        let archive = CrashReportArchive(root: root)
        XCTAssertTrue(archive.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CrashReportArchive.fileURL(root: root).path))
    }

    /// A captured crash survives a reload (that is the whole point: the capture
    /// happens on the crash's next launch, the delivery may be much later).
    func test_a_report_survives_a_reload() {
        CrashReportArchive(root: root).append(report())
        let reloaded = CrashReportArchive(root: root).pending()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(reloaded.first?.frames.first, "DSHMobile @0x1a2b")
    }

    /// The same crash twice is one entry, and the earlier timestamp wins: the
    /// report should say when the bug first bit.
    func test_the_same_signature_is_merged_not_duplicated() {
        let archive = CrashReportArchive(root: root)
        archive.append(report(at: Date(timeIntervalSince1970: 1_760_000_500)))
        archive.append(report(at: Date(timeIntervalSince1970: 1_760_000_000)))
        let pending = archive.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.occurredAt, Date(timeIntervalSince1970: 1_760_000_000))
    }

    /// A different top frame on the same build is a different bug.
    func test_a_different_top_frame_is_a_different_report() {
        let archive = CrashReportArchive(root: root)
        archive.append(report(id: "a", frame: "DSHMobile @0x1a2b"))
        archive.append(report(id: "b", frame: "DSHMobile @0x99ff"))
        XCTAssertEqual(archive.pending().count, 2)
    }

    /// The archive is bounded: an app that crashes on every launch must not grow
    /// a file forever.
    func test_the_archive_keeps_only_the_newest_reports() {
        let archive = CrashReportArchive(root: root)
        for index in 0..<(CrashReportArchive.limit + 5) {
            archive.append(report(id: "sig-\(index)", frame: "frame-\(index)",
                                  at: Date(timeIntervalSince1970: 1_760_000_000 + Double(index))))
        }
        let stored = archive.reports()
        XCTAssertEqual(stored.count, CrashReportArchive.limit)
        XCTAssertEqual(stored.first?.id, "sig-\(CrashReportArchive.limit + 4)", "newest first")
    }

    /// A delivered report leaves the queue and does not come back after a reload.
    func test_marking_sent_removes_it_from_the_queue() {
        let archive = CrashReportArchive(root: root)
        archive.append(report())
        archive.markSent(id: "sig-1")
        XCTAssertTrue(archive.pending().isEmpty)
        XCTAssertNotNil(CrashReportArchive(root: root).reports().first?.sentAt)
    }

    /// A merge must not resurrect a delivered crash: the report was already read.
    func test_a_delivered_report_is_not_requeued_by_a_merge() {
        let archive = CrashReportArchive(root: root)
        archive.append(report())
        archive.markSent(id: "sig-1")
        archive.append(report(at: Date(timeIntervalSince1970: 1_760_000_900)))
        XCTAssertTrue(archive.pending().isEmpty)
    }

    /// A corrupt file reads as "nothing queued" rather than crashing the launch.
    func test_a_corrupt_file_reads_as_empty() throws {
        try Data("not json".utf8).write(to: CrashReportArchive.fileURL(root: root))
        let archive = CrashReportArchive(root: root)
        XCTAssertTrue(archive.reports().isEmpty)
        archive.append(report())
        XCTAssertEqual(archive.pending().count, 1, "the next append rewrites the file")
    }

    /// The signature ignores addresses after `+` but keeps the symbol, and the
    /// offset form used by the MetricKit converter stays distinguishable.
    func test_signature_normalization() {
        XCTAssertEqual(
            CrashReport.signature(build: "b", exceptionType: "EXC_CRASH",
                                 topFrame: "DSHMobile + 1234"),
            CrashReport.signature(build: "b", exceptionType: "EXC_CRASH",
                                 topFrame: "DSHMobile + 9999"))
        XCTAssertNotEqual(
            CrashReport.signature(build: "b", exceptionType: "EXC_CRASH", topFrame: "DSHMobile @0x1a"),
            CrashReport.signature(build: "b", exceptionType: "EXC_CRASH", topFrame: "DSHMobile @0x2b"))
        XCTAssertNotEqual(
            CrashReport.signature(build: "b1", exceptionType: "EXC_CRASH", topFrame: "X"),
            CrashReport.signature(build: "b2", exceptionType: "EXC_CRASH", topFrame: "X"))
    }

    /// The letter says which build, what crashed and where; it never mentions a
    /// session, a message or a file path (privacy contract, docs/PRIVACY.md).
    func test_the_digest_names_the_build_and_the_frames() {
        let subject = CrashReportDigest.subject(for: report())
        XCTAssertTrue(subject.contains("EXC_BAD_ACCESS"), subject)
        XCTAssertTrue(subject.contains("SIGSEGV"), subject)

        let body = CrashReportDigest.body(for: report())
        XCTAssertTrue(body.contains("20261013.2233"), body)
        XCTAssertTrue(body.contains("iPhone12,1"), body)
        XCTAssertTrue(body.contains("DSHMobile @0x1a2b"), body)
        XCTAssertTrue(body.contains("不含会话内容"), body)
    }

    /// A long stack is capped, and the note says how many frames were dropped.
    func test_the_digest_caps_a_long_stack() {
        var long = report()
        long.frames = (0..<30).map { "frame-\($0)" }
        let body = CrashReportDigest.body(for: long, frameLimit: 12)
        XCTAssertTrue(body.contains("frame-11"), body)
        XCTAssertFalse(body.contains("frame-12"), body)
        XCTAssertTrue(body.contains("另有 18 帧"), body)
    }

    /// A report with no frames at all still reads as a report.
    func test_the_digest_handles_a_missing_stack() {
        var empty = report()
        empty.frames = []
        XCTAssertTrue(CrashReportDigest.body(for: empty).contains("没有提供符号化的栈"))
    }
}

// MARK: - 032：deviceKey（重装复用同一台设备）

extension CrashReportTests {
    /// 生成的 key 必须落在中转接受的形状里（8–128 字符、字母数字与 `-`/`_`）。
    func test_a_generated_device_key_is_accepted_by_the_relay() {
        let key = DeviceKey.generate()
        XCTAssertTrue(DeviceKey.isValid(key), key)
        XCTAssertTrue(key.hasPrefix("dk_"))
        XCTAssertNotEqual(DeviceKey.generate(), key, "每次都要不一样")
    }

    /// 中转那侧的形状规则（`relay-go/internal/store` 的 `ValidateDeviceKey`）逐条对齐。
    func test_the_device_key_shape_matches_the_relay_rules() {
        XCTAssertFalse(DeviceKey.isValid("short"), "太短")
        XCTAssertFalse(DeviceKey.isValid(String(repeating: "a", count: 129)), "太长")
        XCTAssertFalse(DeviceKey.isValid("has space 1234"), "空格不接受")
        XCTAssertFalse(DeviceKey.isValid("emoji🙂12345"), "非 ASCII 不接受")
        XCTAssertTrue(DeviceKey.isValid("dk_0123456789abcdef"))
        XCTAssertTrue(DeviceKey.isValid("ABCD-1234_efgh"))
    }

    /// 第一次取会生成并存下来；第二次取必须拿到同一枚（重装复用靠它）。
    func test_the_same_scope_gets_the_same_key() throws {
        let box = KeyBox()
        let scope = DeviceKey.scope(relayURL: URL(string: "https://relay.test/dsh-link")!,
                                    agentId: "agt_1")
        let first = DeviceKey.current(for: scope, keychain: box.storage)
        let second = DeviceKey.current(for: scope, keychain: box.storage)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(box.writes.count, 1, "只有第一次写")
    }

    /// 不同电脑（不同 agentId）是不同的身份，不会互相顶掉。
    func test_different_hosts_get_different_scopes() {
        let box = KeyBox()
        let relay = URL(string: "https://relay.test/dsh-link")!
        let one = DeviceKey.current(for: DeviceKey.scope(relayURL: relay, agentId: "agt_1"),
                                    keychain: box.storage)
        let two = DeviceKey.current(for: DeviceKey.scope(relayURL: relay, agentId: "agt_2"),
                                    keychain: box.storage)
        XCTAssertNotNil(one)
        XCTAssertNotNil(two)
        XCTAssertNotEqual(one, two)
    }

    /// 钥匙串里存着一枚坏值（被截断、含空格）时重新生成，而不是把它发上去。
    func test_a_corrupt_stored_key_is_replaced() {
        let box = KeyBox(seed: "bad key")
        let scope = "deviceKey.x|y"
        let key = DeviceKey.current(for: scope, keychain: box.storage)
        XCTAssertNotEqual(key, "bad key")
        XCTAssertTrue(DeviceKey.isValid(key ?? ""))
    }

    /// 写不进去（钥匙串不可用）时返回 nil，让认领按"新设备"继续，而不是让整次配对失败。
    func test_a_failing_keychain_yields_nil_instead_of_throwing() {
        let box = KeyBox(failWrites: true)
        XCTAssertNil(DeviceKey.current(for: "deviceKey.x|y", keychain: box.storage))
    }

    /// 用例用的钥匙串替身：记录读写，不碰真钥匙串（iOS 单测宿主没有签名身份）。
    final class KeyBox: @unchecked Sendable {
        private let lock = NSLock()
        /// 按 scope 存（真钥匙串就是这么工作的：不同 scope 是不同条目）。
        private var values: [String: String] = [:]
        private(set) var writes: [String] = []
        private let failWrites: Bool

        init(seed: String? = nil, scope: String = "deviceKey.x|y", failWrites: Bool = false) {
            if let seed { values[scope] = seed }
            self.failWrites = failWrites
        }

        var storage: DeviceKeyStorage {
            DeviceKeyStorage(
                read: { [self] scope in
                    lock.lock(); defer { lock.unlock() }
                    return values[scope]
                },
                write: { [self] newValue, scope in
                    if failWrites { throw NSError(domain: "keychain", code: -34018) }
                    lock.lock(); defer { lock.unlock() }
                    values[scope] = newValue
                    writes.append(newValue)
                }
            )
        }
    }
}

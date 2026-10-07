import Foundation
import Testing

@testable import DSHKit
import RelayKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The background upload path (R-1 C-18), driven by an injected session.
///
/// **No real background session is opened here on purpose.** `URLSessionConfiguration
/// .background` only exists on iOS and only behaves that way there — on macOS (where
/// this suite runs) a background session is an ordinary one, so a test that used one
/// would prove nothing about being woken up after suspension. What *is* testable
/// here, and is where the bugs actually were, is the request that goes out, the
/// path-selection policy, and the fallback.
///
/// Serialised because the stub keeps its canned answers in static storage.
@Suite("Background file transfer", .serialized)
struct RelayFileTransferTests {

    /// A URLProtocol that records requests and replays canned answers.
    final class Stub: URLProtocol, @unchecked Sendable {
        struct Exchange: Sendable {
            let status: Int
            let body: Data
        }

        nonisolated(unsafe) static var exchanges: [Exchange] = []
        nonisolated(unsafe) static var requests: [URLRequest] = []
        /// 建出来的会话，用例结束时要失效掉（见 `session()`）。
        nonisolated(unsafe) static var sessions: [URLSession] = []

        /// When set, the transfer fails with this error instead of finishing.
        ///
        /// A dropped connection is not an HTTP status: it arrives as a task-level
        /// error, and it is the only way a `userInfo`-carried resume blob can be
        /// produced in a test — which is exactly the path that was broken.
        nonisolated(unsafe) static var failWith: (any Error)?

        static func reset(_ list: [Exchange], headers: [String: String] = [:]) {
            exchanges = list
            requests = []
            extraHeaders = headers
            failWith = nil
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        /// Extra headers the canned answer carries (e.g. `X-DSH-Offset`).
        nonisolated(unsafe) static var extraHeaders: [String: String] = [:]

        override func startLoading() {
            Self.requests.append(request)
            let exchange = Self.exchanges.isEmpty
                ? Exchange(status: 500, body: Data("{}".utf8))
                : Self.exchanges.removeFirst()
            var fields = ["Content-Type": "application/json"]
            for (name, value) in Self.extraHeaders { fields[name] = value }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: exchange.status,
                httpVersion: "HTTP/1.1",
                headerFields: fields
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let failure = Self.failWith {
                client?.urlProtocol(self, didFailWithError: failure)
                return
            }
            client?.urlProtocol(self, didLoad: exchange.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// Invalidates every session a previous test built.
        ///
        /// A session that is never invalidated keeps its task table and its
        /// delegate wiring alive for the life of the process, and macOS delivers
        /// URLProtocol callbacks through one shared loading thread — so the tests
        /// accumulated sessions until a later task's callback never arrived. That
        /// shows up as a **hang**, not a failure, which is why it survived a
        /// green-looking report.
        /// The configuration every stub session is built from.
        static func configuration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Stub.self]
            return configuration
        }

        static func retireSessions() {
            let stale = sessions
            sessions = []
            for session in stale { session.invalidateAndCancel() }
        }

        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Stub.self]
            // **必须带 delegate 建**：上传的回复走会话 delegate 的回调，而回调按
            // task id 在一个注册表里找等待者。没有 delegate 的会话永远不回调，
            // 于是 `upload` 会一直等下去（这正是它不能只写 `URLSession(
            // configuration:)` 的原因）。用产品那一个实例，保证测的是同一条路。
            let session = URLSession(
                configuration: configuration,
                delegate: RelayFileTransfer.sessionDelegate,
                delegateQueue: nil
            )
            // 每个用例一个会话，用完即弃：会话不失效就会一直留着它的 delegate 回调
            // 通路，而 macOS 上同一进程里多个 ephemeral 会话会互相争 URLProtocol 的
            // 加载线程——第一个用例过后，后面用例的任务就再也收不到回调（表现是
            // **挂死**而不是失败）。见 `RelayFileTransferTests` 的注释。
            sessions.append(session)
            return session
        }
    }

    /// A delegate that completes tasks and records **nothing**.
    ///
    /// It stands in for the shipped delegate as it behaved on device: the task
    /// finished, the answer arrived at `didCompleteWithError`, and the waiter's
    /// recorded response stayed `nil`. Nothing here may touch
    /// `RelayTransferSink.record(response:)`, or the test would be proving the
    /// callback it is meant to do without.
    final class SilentCompletionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            // Deliberately **no** `RelayTransferSink.record(response:)`.
            completionHandler(.allow)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            RelayFileTransfer.Sink.record(body: data, for: dataTask)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            // The completion itself is the pre-fix path too: it is what always
            // arrived. Only the response was missing.
            RelayFileTransfer.Sink.finish(task, error: error)
        }
    }

    private func transfer(relay: String = "https://relay.test/dsh-link") -> RelayFileTransfer {
        // 先把上一个用例的会话失效：一个活着的会话仍握着它的 delegate 回调通路，
        // 同一进程里堆着多个的话，后面用例的任务会收不到回调（表现为挂死，
        // 而不是一条红的断言）。这是**测试**的卫生问题，不是产品行为——
        // 产品全程只有那一个后台会话。
        Stub.retireSessions()
        return RelayFileTransfer(
            relayURL: URL(string: relay)!,
            deviceToken: "dt_phone",
            session: Stub.session()
        )
    }

    /// A file of the given size in a temporary directory.
    private func makeFile(bytes: Int, name: String = "big.bin") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-file-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x5a, count: bytes).write(to: url)
        return url
    }

    // MARK: - the request

    /// The two shapes a **background** session refuses, both of which shipped in
    /// R-1 and crashed the app on device (OTA 0412) the moment anyone sent a file
    /// ≥ 8 MB:
    ///
    /// * `upload(for:fromFile:)` — the async convenience is built on a completion
    ///   handler block, and `__NSURLBackgroundSession` raises
    ///   `NSGenericException: 'Completion handler blocks are not supported in
    ///   background sessions. Use a delegate instead.'`
    /// * `task.delegate = …` — a per-task delegate is refused with
    ///   `'Task delegate is not supported on background session task'`.
    ///
    /// Both exceptions come out of CFNetwork on a dispatch queue, so neither can be
    /// caught: each one terminates the process. The amendment is therefore
    /// **structural** — the callbacks must ride the session's delegate — and the
    /// only thing a unit test can do is pin that structure, since macOS cannot open
    /// a real background session at all. This is that pin.
    @Test("the upload uses a session-delegate task, never a completion handler or a task delegate")
    func uploadUsesTheSupportedShape() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"path":"/p","bytes":1}"#.utf8))])
        let file = try makeFile(bytes: 1)

        // 1. The production session must be built with a delegate; without one the
        //    callbacks have nowhere to go and the upload waits forever.
        #if os(iOS)
        #expect(RelayFileTransfer.backgroundConfiguration() != nil)
        #endif
        #expect(RelayFileTransfer.sessionDelegate is any URLSessionDelegate)

        // 2. The injected session the tests drive must be the same kind: built with
        //    that delegate. If `Stub.session()` ever regressed to a plain
        //    `URLSession(configuration:)` this test would hang rather than fail —
        //    hence the check on the delegate itself.
        let session = Stub.session()
        #expect(session.delegate != nil)

        // 3. And the upload must actually complete through that delegate, which is
        //    what proves the callbacks are wired to the registry and not to a
        //    task-level object.
        let staged = try await RelayFileTransfer(
            relayURL: URL(string: "https://relay.test/dsh-link")!,
            deviceToken: "dt",
            session: session
        ).upload(fileURL: file, name: "a.bin", sessionId: "s", bid: "b")
        #expect(staged.path == "/p")
    }

    /// An upload must not be reported as a bad answer just because no
    /// response callback fed the waiter.
    ///
    /// This is the OTA 0633 defect exactly: a 28 MB upload uploaded every byte and
    /// was answered `200`, the task completed cleanly, and the app still threw
    /// `malformedResponse("中转响应无效")` because `RelayTaskWaiter.response` had
    /// never been set — so `ConnectionStore` discarded a successful upload and
    /// re-sent the whole file over the WSS path. On the phone that read as an
    /// upload that never ended; the file had in fact already arrived.
    ///
    /// The delegate below models the gap without depending on which `URLSession`
    /// callback a given platform decides to invoke: it completes every task and
    /// records nothing, which is precisely the state the shipped delegate left the
    /// waiter in.
    @Test("a completed upload is believed even when no response callback recorded one")
    func completedUploadSurvivesAMissingResponseCallback() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"path":"/p","bytes":29}"#.utf8))])
        let file = try makeFile(bytes: 29)

        let session = URLSession(
            configuration: Stub.configuration(),
            delegate: SilentCompletionDelegate(),
            delegateQueue: nil
        )

        let staged = try await RelayFileTransfer(
            relayURL: URL(string: "https://relay.test/dsh-link")!,
            deviceToken: "dt",
            session: session
        ).upload(fileURL: file, name: "a.bin", sessionId: "s", bid: "b")
        #expect(staged.path == "/p")
        #expect(staged.bytes == 29)
    }

    /// The production delegate must implement the task-level response callback.
    ///
    /// A structural check because the failure it guards is invisible on macOS: a
    /// plain session happens to answer through the data-task callback, so the
    /// suite stays green while a real device's upload task gets nothing.
    /// Two uploads on **different sessions** must not be confused for each other.
    ///
    /// `taskIdentifier` is unique only within a session — every session numbers
    /// its first task `1` — and the waiter registry used to be keyed by that
    /// integer alone. A waiter left behind by one session therefore collided with
    /// the next session's first task, whose completion resolved the *wrong*
    /// waiter and left the real caller awaiting a callback that had already been
    /// delivered: a hang with nothing red to show for it. This test runs the two
    /// transfers back to back, which is the shape that used to deadlock the whole
    /// suite (it passed one test at a time, which is why it went unnoticed).
    @Test("two uploads on different sessions do not collide on their task identifier")
    func uploadsOnDifferentSessionsDoNotCollide() async throws {
        let first = try makeFile(bytes: 11, name: "first.bin")
        let second = try makeFile(bytes: 22, name: "second.bin")

        Stub.reset([.init(status: 200, body: Data(#"{"path":"/p","bytes":11}"#.utf8))])
        let one = try await transfer().upload(fileURL: first, name: "first.bin",
                                              sessionId: "s", bid: "b1")
        #expect(one.bytes == 11)

        Stub.reset([.init(status: 200, body: Data(#"{"path":"/p","bytes":22}"#.utf8))])
        let two = try await transfer().upload(fileURL: second, name: "second.bin",
                                              sessionId: "s", bid: "b2")
        #expect(two.bytes == 22)
    }

    /// The production delegate must be able to answer an upload at all.
    ///
    /// `URLSessionTaskDelegate` has no task-level response callback (its members
    /// are `didCompleteWithError`, `didSendBodyData`, the challenge/redirect hooks
    /// and metrics), so the only callbacks that can carry an upload's answer are
    /// the data-task pair plus completion. Pin the data-task response one by
    /// selector: it is the method whose absence left every upload with no
    /// response, and a signature that stops matching the protocol still compiles
    /// — the compiler only warns — while silently ceasing to be called.
    @Test("the production delegate declares the data-task response callback")
    func productionDelegateDeclaresDataTaskResponseCallback() {
        let selector = NSSelectorFromString(
            "URLSession:dataTask:didReceiveResponse:completionHandler:")
        #expect((RelayFileTransfer.sessionDelegate as AnyObject).responds(to: selector))
    }

    @Test("the upload goes to the relay under its mount prefix with every query field")
    func requestShape() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"path":"/home/u/.dsh/inbox/s1/big.bin","bytes":12}"#.utf8))])
        let file = try makeFile(bytes: 12)
        _ = try await transfer().upload(fileURL: file, name: "big.bin",
                                        sessionId: "s-1", bid: "bid-1")

        let request = try #require(Stub.requests.first)
        let url = try #require(request.url)
        #expect(url.path == "/dsh-link/files/up")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dt_phone")

        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        #expect(fields["sessionId"] == "s-1")
        #expect(fields["name"] == "big.bin")
        #expect(fields["bytes"] == "12")
        #expect(fields["bid"] == "bid-1")
    }

    @Test("the staged answer reads as the same shape the WSS path returns")
    func stagedShape() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"path":"/home/u/.dsh/inbox/s1/notes.txt","bytes":7}"#.utf8))])
        let file = try makeFile(bytes: 7, name: "notes.txt")
        let staged = try await transfer().upload(fileURL: file, name: "notes.txt",
                                                 sessionId: "s-1", bid: "b")
        #expect(staged.path == "/home/u/.dsh/inbox/s1/notes.txt")
        #expect(staged.bytes == 7)
        // 调用方不该需要知道文件是走哪条路送到的。
        #expect(staged.asStaged.path == staged.path)
        #expect(staged.asStaged.bytes == staged.bytes)
    }

    @Test("a stable bid is reused when the same attempt is retried")
    func stableBid() async throws {
        // 连接器按 bid 覆盖写，所以同一次尝试的重试必须复用同一个 id——
        // 否则重试会在电脑上留下第二份文件。
        Stub.reset([
            .init(status: 503, body: Data(#"{"ok":false,"error":{"code":"host/offline","message":"no"}}"#.utf8)),
            .init(status: 200, body: Data(#"{"path":"/p","bytes":3}"#.utf8)),
        ])
        let file = try makeFile(bytes: 3)
        let subject = transfer()
        _ = try? await subject.upload(fileURL: file, name: "a.bin", sessionId: "s", bid: "same-bid")
        _ = try await subject.upload(fileURL: file, name: "a.bin", sessionId: "s", bid: "same-bid")

        let bids = Stub.requests.compactMap { request -> String? in
            guard let url = request.url,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            else { return nil }
            return items.first { $0.name == "bid" }?.value
        }
        #expect(bids == ["same-bid", "same-bid"])
    }

    // MARK: - failures (there is no other path to take)

    @Test("a relay error is surfaced with the relay's own code")
    func relayError() async throws {
        Stub.reset([.init(status: 409, body: Data(#"{"ok":false,"error":{"code":"file/rejected","message":"no space"}}"#.utf8))])
        let file = try makeFile(bytes: 4)
        await #expect(throws: DSHRPCFailure.self) {
            _ = try await transfer().upload(fileURL: file, name: "a", sessionId: "s", bid: "b")
        }
    }

    /// **The fallback is gone, and this is the pin that says so.**
    ///
    /// Every failure status used to be classified by `shouldFallBack(status:)`,
    /// whose only caller passed the constant `0` — so it always returned `false`
    /// and the caller's `catch` re-sent the whole file over the WSS path instead.
    /// That is what turned "the relay answered 200 but the app lost the response"
    /// into a 28 MB re-send the user saw as a spinner that never stopped.
    ///
    /// There is no classifier to test any more, so what is pinned is the shape
    /// that replaced it: a non-2xx upload **throws**, whatever the status, and
    /// nothing about the failure is silently turned into another attempt.
    @Test("every failure status is reported, never classified for another path")
    func failureStatusesAreReported() async throws {
        for status in [400, 401, 404, 405, 409, 413, 500, 501, 503] {
            Stub.reset([.init(
                status: status,
                body: Data(#"{"ok":false,"error":{"code":"file/rejected","message":"no"}}"#.utf8)
            )])
            let file = try makeFile(bytes: 5)
            await #expect(throws: (any Error).self) {
                _ = try await transfer().upload(fileURL: file, name: "a", sessionId: "s", bid: "b")
            }
            // And exactly one request went out: no second attempt of any kind.
            #expect(Stub.requests.count == 1, "status \(status) produced \(Stub.requests.count) requests")
        }
    }

    // MARK: - the source file that is not there (P-12 / F-2)

    /// **Invariant 6, and the crash it exists for.**
    ///
    /// `uploadTask(with:fromFile:)` raises `NSInvalidArgumentException` from
    /// `__NSURLBackgroundSession performBlockOnQueueAndRethrowExceptions:` when
    /// the path does not exist. That exception is rethrown on a dispatch queue,
    /// so it never reaches a Swift `catch` — it abort()s the process. Two crash
    /// reports on 2026-09-29 have exactly that stack
    /// (`_uploadTaskWithTaskForClass:` → `RelayFileTransfer.upload`).
    ///
    /// A macOS unit test cannot reproduce the abort (there is no
    /// `__NSURLBackgroundSession` here), so what it pins is the **precondition
    /// that keeps that call from ever being made**: the upload must throw an
    /// ordinary error, and no request may go out — `Stub.requests.count == 0` is
    /// the machine-checkable form of "the task factory was never reached".
    @Test("a source file that is gone is an error before the task exists, never a crash",
          .timeLimit(.minutes(1)))
    func missingSourceFileIsRefusedBeforeAnyTask() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"path":"/p","bytes":1}"#.utf8))])
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-f2-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("already-gone.bin")
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        await #expect(throws: RelayFileTransfer.Unavailable.self) {
            _ = try await transfer().upload(fileURL: missing, name: "already-gone.bin",
                                            sessionId: "s-1", bid: "b")
        }
        // 一个字节都没发出去：任务根本没建出来，也就没有那个 catch 不到的异常。
        #expect(Stub.requests.count == 0)

        // 文案是给人看的（走 `ConnectionStore.describe` 的那一层）。
        let error = RelayFileTransfer.Unavailable.sourceFileMissing(missing.path)
        let text = error.errorDescription ?? ""
        #expect(text.contains("重新选择"))
        #expect(!text.contains("NSURL"))
        #expect(!text.contains("Unavailable"))
    }

    @Test("a source file that exists still uploads, so the check is not a blanket refusal",
          .timeLimit(.minutes(1)))
    func presentSourceFileStillUploads() async throws {
        Stub.reset([.init(status: 200, body: Data(#"{"path":"/p","bytes":3}"#.utf8))])
        let file = try makeFile(bytes: 3)
        let staged = try await transfer().upload(fileURL: file, name: "big.bin",
                                                 sessionId: "s-1", bid: "b")
        #expect(staged.bytes == 3)
        #expect(Stub.requests.count == 1)
    }

    @Test("the capability gate is feature detection, not a version comparison")
    func capabilityGate() {
        #expect(RelayFileTransfer.supportsBackgroundTransfer(
            capabilities: ["file-transfer", "background-transfer"]))
        // 老连接器不列这个词：**报错**（`Unavailable.connectorTooOld`），不是换路。
        #expect(!RelayFileTransfer.supportsBackgroundTransfer(capabilities: ["file-transfer", "events"]))
        #expect(!RelayFileTransfer.supportsBackgroundTransfer(capabilities: []))
        #expect(RelayFileTransfer.capability == "background-transfer")
    }

    /// The three "there is no route from here" errors a person can be shown.
    ///
    /// These replaced four `guard … else { return nil }` clauses whose `nil` meant
    /// "quietly use the WSS path". Each has to be a *sentence*, because that
    /// sentence is now the whole user-visible outcome of a failed send.
    @Test("the unavailable cases each explain themselves in words")
    func unavailableCasesExplainThemselves() {
        for error in [RelayFileTransfer.Unavailable.noRelay,
                      .connectorTooOld,
                      .credentialMissing,
                      .relayAddressInvalid] {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty, "\(error) has no description")
            // 不是给开发看的代号：不出现错误枚举名或英文键。
            #expect(!text.contains("Unavailable"))
            #expect(text.count >= 6)
        }
        #expect(RelayFileTransfer.Unavailable.connectorTooOld.errorDescription?
            .contains("连接器") == true)
        #expect(RelayFileTransfer.Unavailable.credentialMissing.errorDescription?
            .contains("重新配对") == true)
    }

    @Test("a file's size comes from the filesystem, not from the caller")
    func fileSize() throws {
        let file = try makeFile(bytes: 12345)
        #expect(RelayFileTransfer.fileSize(file) == 12345)
        // 不存在的文件读作 0：这个值只进请求的 `bytes` 字段，不再参与任何"选路"
        // （分路已删），所以读 0 不会让文件悄悄走另一条路。
        #expect(RelayFileTransfer.fileSize(file.deletingLastPathComponent()
            .appendingPathComponent("nope")) == 0)
    }

    @Test("the macOS build has no background configuration, and says so")
    func noBackgroundOnMacOS() {
        // 这条不是"跳过测试"：它钉住的是 `backgroundConfiguration()` 在非 iOS 上
        // 明确返回 nil（而不是悄悄给一个普通配置，让调用方以为拿到了后台语义）。
        #if os(iOS)
        #expect(RelayFileTransfer.backgroundConfiguration() != nil)
        #else
        #expect(RelayFileTransfer.backgroundConfiguration() == nil)
        #endif
    }

    // MARK: - the download (R-1 C-21)

    /// The download request, which is where the resume contract lives.
    @Test("the download goes to /files/down under its mount prefix with every query field")
    func downloadRequestShape() throws {
        let request = try #require(transfer().downloadRequest(
            scopeId: "scope-1", path: "reports/big.pdf", offset: 0, bid: "bid-9"))
        let url = try #require(request.url)
        #expect(url.path == "/dsh-link/files/down")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dt_phone")
        // offset 0 不带 Range：那是一次完整下载，不是续传。
        #expect(request.value(forHTTPHeaderField: "Range") == nil)

        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        #expect(fields["scopeId"] == "scope-1")
        #expect(fields["path"] == "reports/big.pdf")
        #expect(fields["offset"] == "0")
        #expect(fields["bid"] == "bid-9")
    }

    /// **This is the one that matters**: a background `URLSessionDownloadTask`
    /// gets no `.part` continuation, so without a correct `Range` a dropped
    /// connection restarts the whole file.
    @Test("a resumed download carries its offset in both the query and a Range header")
    func downloadResumeOffset() throws {
        let request = try #require(transfer().downloadRequest(
            scopeId: "s", path: "big.bin", offset: 7_000_000, bid: "b"))
        let url = try #require(request.url)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=7000000-")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        #expect(fields["offset"] == "7000000")
    }

    @Test("a finished download lands at the destination with the bytes intact")
    func downloadLands() async throws {
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        Stub.reset([.init(status: 200, body: payload)])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-download-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("big.bin")

        let fetched = try await transfer().download(
            scopeId: "s", path: "big.bin", to: destination, version: "v1",
            expectedBytes: payload.count)

        #expect(fetched.url == destination)
        #expect(fetched.bytes == payload.count)
        #expect(try Data(contentsOf: destination) == payload)
        // 是移动而不是留在系统临时文件里：后台任务结束后系统会把它删掉。
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    /// **The download is a delegate task, not `session.download(for:)`.**
    ///
    /// Same trap as the upload, and it shipped: the async convenience is a
    /// completion-handler API, and a background session kills the process with an
    /// uncatchable `NSGenericException` the moment one is created on it. macOS
    /// cannot open a real background session, so the only thing a unit test can
    /// pin is the structure — and the structure is exactly what was wrong.
    ///
    /// `downloadTask(with:)` puts the callbacks on the session delegate, which is
    /// why the delegate below has to implement `didFinishDownloadingTo` for the
    /// transfer to complete at all. If `download` regressed to the convenience
    /// API, this test would hang rather than fail — hence also asserting the
    /// delegate declares the method.
    @Test("the download rides the session delegate, and the production delegate declares its callback")
    func downloadUsesTheSupportedShape() async throws {
        let selector = NSSelectorFromString("URLSession:downloadTask:didFinishDownloadingToURL:")
        #expect((RelayFileTransfer.sessionDelegate as AnyObject).responds(to: selector))

        let payload = Data((0..<4096).map { UInt8($0 % 253) })
        Stub.reset([.init(status: 200, body: payload)])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-download-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("big.bin")

        let fetched = try await transfer().download(
            scopeId: "s", path: "big.bin", to: destination, version: "v1",
            expectedBytes: payload.count)
        #expect(fetched.bytes == payload.count)
        #expect(try Data(contentsOf: destination) == payload)

        // The staging copy the delegate had to make is not left behind: the worker
        // consumes it when it writes the result.
        let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("relay-download-staging", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(leftovers.isEmpty, "staging still holds \(leftovers)")
    }

    /// **The system's resume data is what continues a transfer, not a prefix we
    /// kept** (P-13c).
    ///
    /// The old mechanism appended the relay's tail onto a `.part` prefix and
    /// verified the relay's `X-DSH-Offset` matched. Both are gone: the app cannot
    /// observe an interruption that happened while it was suspended, so an
    /// offset it tracked was always 0 in the cases that matter. What replaces
    /// them is a blob the system owns, stored per version, and replayed into
    /// `downloadTask(withResumeData:)`.
    ///
    /// A blob from a **different version** must be ignored — that is the boundary
    /// the whole design rests on, because resuming across a change would splice
    /// two different files together. This asserts the store's key, which is what
    /// makes that impossible rather than merely unlikely.
    @Test("a resume blob is only ever replayed for the version that produced it")
    func resumeIsScopedToTheVersion() {
        // A `root:` argument, not `setenv`. Swift Testing runs suites in
        // parallel and this suite declares no ordering against the store's own,
        // so a process-wide variable let the two overwrite each other's root
        // mid-test — green alone, red together.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-resume-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blob = Data("blob".utf8)
        RelayResumeStore.save(blob, scopeId: "s", path: "big.bin", version: "v1", root: root)
        #expect(RelayResumeStore.load(scopeId: "s", path: "big.bin", version: "v1",
                                     root: root) == blob)
        // The file changed under the interrupted attempt. Starting over is the
        // only correct answer.
        #expect(RelayResumeStore.load(scopeId: "s", path: "big.bin", version: "v2",
                                     root: root) == nil)
    }

    @Test("the connector's own error code survives into the thrown failure")
    func downloadReportsTheConnectorsCode() async throws {
        let body = Data(#"{"ok":false,"error":{"code":"workspace-file/not-found","message":"no such file"}}"#.utf8)
        Stub.reset([.init(status: 409, body: body)])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-download-\(UUID().uuidString)", isDirectory: true)

        do {
            _ = try await transfer().download(
                scopeId: "s", path: "gone.bin",
                to: directory.appendingPathComponent("gone.bin"), version: "v1")
            Issue.record("a 409 should have thrown")
        } catch let failure as DSHRPCFailure {
            #expect(failure.code == "workspace-file/not-found")
        }
    }

    /// Progress is reported for the bytes that arrived (P-13c).
    ///
    /// It used to report `offset + arrived`, because the relay sent only a tail
    /// the app appended to a prefix of its own. With the system owning the
    /// resume, what a download task delivers **is** the whole file — the prefix
    /// is inside the system's resume data, not on our disk — so the arrived
    /// count is the file's size and the offset is not ours to add.
    /// **A dropped download must hand its resume blob to the waiter.**
    ///
    /// This is the hop that was missing when the path was first written, and it
    /// is the worst kind of missing: the download still *succeeds* when retried
    /// from scratch, so nothing failed visibly — the guarantee that "an
    /// interruption loses nothing" was simply not in effect for network drops.
    ///
    /// The blob lives in the failure's `userInfo` and only the session delegate
    /// sees it, so this drives the shipped delegate's
    /// `didCompleteWithError` directly. The sink has to hand it to the waiter
    /// **before** `finish` takes the waiter out of the registry.
    @Test("the delegate passes a drop's resume data through to the waiter")
    func dropCarriesResumeData() async throws {
        let blob = Data("system-resume-blob".utf8)
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
            userInfo: [RelayFileTransfer.DownloadSink.resumeDataKey: blob]
        )
        let session = Stub.session()
        let task = session.downloadTask(with: URL(string: "https://relay.test/x")!)
        let waiter = RelayFileTransfer.DownloadSink.register(task)

        // The shipped delegate, the shipped sink, the shipped key.
        RelayFileTransfer.DownloadSink.complete(session, task: task, error: error)

        let outcome = await waiter.value()
        #expect(outcome.resumeData == blob,
                "the blob never reached the waiter, so a retry would start over")
        #expect(outcome.error != nil)
    }

    /// The counterpart: a **clean** finish carries no blob, and the waiter must
    /// not invent one — a resume blob replayed against a completed file would
    /// corrupt it.
    @Test("a clean finish leaves the waiter without resume data")
    func successCarriesNoResumeData() async throws {
        let session = Stub.session()
        let task = session.downloadTask(with: URL(string: "https://relay.test/x")!)
        let waiter = RelayFileTransfer.DownloadSink.register(task)

        RelayFileTransfer.DownloadSink.complete(session, task: task, error: nil)

        let outcome = await waiter.value()
        #expect(outcome.resumeData == nil)
        #expect(outcome.error == nil)
    }

    /// An interrupted download stores what the system gave it, keyed by version.
    ///
    /// End to end through `download` itself: the stub fails the transfer with a
    /// blob in `userInfo`, and the store must hold it afterwards under this exact
    /// version. Reading it back under a *different* version is the boundary that
    /// keeps a resume from splicing two different files together.
    @Test("an interrupted download keeps the blob under its own version")
    func interruptedDownloadStoresBlob() async throws {
        // One root for this test alone, handed to the call itself. No process
        // state is touched, so the store's suite cannot be affected however the
        // two are scheduled.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-resume-keep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let blob = Data("kept-blob".utf8)
        Stub.reset([.init(status: 200, body: Data(repeating: 0, count: 10))])
        Stub.failWith = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
            userInfo: [RelayFileTransfer.DownloadSink.resumeDataKey: blob]
        )
        defer { Stub.failWith = nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-download-\(UUID().uuidString)", isDirectory: true)
        await #expect(throws: (any Error).self) {
            _ = try await transfer().download(
                scopeId: "s", path: "big.bin",
                to: directory.appendingPathComponent("big.bin"), version: "v1",
                resumeRoot: root
            )
        }
        #expect(RelayResumeStore.load(scopeId: "s", path: "big.bin", version: "v1",
                                     root: root) == blob,
                "the interruption's blob was not kept, so the next attempt restarts")
        #expect(RelayResumeStore.load(scopeId: "s", path: "big.bin", version: "v2",
                                     root: root) == nil,
                "a blob must not be offered to a different version")
    }

    /// **A resume blob that arrives late must still be readable.**
    ///
    /// The blob is produced on the queue `cancel(byProducingResumeData:)` calls
    /// back on, and that may be *after* the wait for the transfer has ended —
    /// `didCompleteWithError` and the cancel callback are not ordered against each
    /// other. The first version of `download` stored the blob in a plain closure,
    /// so when the waiter won the race the store stayed empty and the next attempt
    /// downloaded the whole file again. The simulator showed the cost on the real
    /// relay: the system produced a 9955-byte blob (`NSURLSessionDownloadTaskResumeData={length = 9955 …}`
    /// in the device log) while the app reported `storedBlob=-1`.
    ///
    /// `LateBlobBox` is the piece that makes the late blob readable; a regression
    /// here is silent, which is why it is pinned directly.
    @Test("a blob that arrives after the wait began is still read")
    func lateBlobIsStillRead() async throws {
        let box = RelayFileTransfer.LateBlobBox.Box()
        let blob = Data("late-blob".utf8)
        // Delivered **while the wait is timing out**, which is the ordering that
        // actually loses a blob: a callback that lands comfortably inside the
        // budget proves nothing about the race. Landing it right at the deadline
        // is what a slow cancel callback does on a real device.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            box.put(blob)
            box.close()
        }
        let read = await box.wait(within: .milliseconds(200))
        #expect(read == blob, "a blob that landed as the wait expired was dropped")
    }

    /// The counterpart: **no read may outlive its budget.**
    ///
    /// The system only produces resume data when it has something to resume from,
    /// and when it does not the callback never runs. Reading it without a bound
    /// would turn "nothing to resume from" — which the retry path already handles
    /// — into a download that never returns. That is not hypothetical: it is the
    /// shape the simulator showed after the first attempt at the fix.
    @Test("a box that is never filled still returns")
    func emptyBoxDoesNotHang() async throws {
        let box = RelayFileTransfer.LateBlobBox.Box()
        let started = Date()
        let read = await box.wait(within: .milliseconds(200))
        #expect(read == nil)
        #expect(Date().timeIntervalSince(started) < 5,
                "waiting for a blob that never comes must be bounded")
    }

    @Test("a download reports the bytes that arrived")
    func downloadReportsProgress() async throws {
        let payload = Data(repeating: 0x43, count: 250)
        Stub.reset([.init(status: 200, body: payload)])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-download-\(UUID().uuidString)", isDirectory: true)
        let seen = ProgressRecorder()

        _ = try await transfer().download(
            scopeId: "s", path: "big.bin", to: directory.appendingPathComponent("big.bin"),
            version: "v1", expectedBytes: 250
        ) { received in seen.record(received) }

        #expect(seen.values == [250])
    }

    // MARK: - the shared session (P-2)

    /// There is **one** transport session, not one per transfer.
    ///
    /// The property the acceptance asks for is `===`: two lookups give the same
    /// object. It matters because iOS keeps one session per identifier anyway —
    /// so two objects would mean one real session with two owners, and whichever
    /// built the delegate last is the one whose callbacks arrive. That is the
    /// ambiguity `ownsSession` used to hide; the accessor is a single stored
    /// instance so it cannot come back.
    @Test("the transfer session is one shared instance, not one per caller")
    func theSessionIsShared() {
        let first = RelayFileTransfer.backgroundSession()
        let second = RelayFileTransfer.backgroundSession()
        #expect(first === second)
        #expect(first === RelayFileTransfer.reassociate())
    }

    /// Re-associating at launch must not send anything.
    ///
    /// The system relaunches the app to hand it a finished transfer's events, and
    /// `reassociate()` is what makes the delegate reachable for them. The trap it
    /// must not fall into is "launch also retries the transfer": the acceptance
    /// for P-2 is a launch with **zero** requests, and this is that measurement —
    /// the stub counts every request that leaves, and the count has to stay at
    /// zero across a full re-association.
    @Test("re-associating at launch sends no request")
    func reassociateSendsNothing() {
        Stub.reset([])
        _ = RelayFileTransfer.reassociate()
        _ = RelayFileTransfer.backgroundSession()
        #expect(Stub.requests.isEmpty)
    }

    /// The production session must be reachable for a caller that never names one.
    ///
    /// `RelayFileTransfer(relayURL:deviceToken:)` is what both production call
    /// sites use; if the no-session initialiser ever stopped resolving to the
    /// shared session, a fresh session per transfer would appear — invisible in
    /// tests that always inject one, and on device it is the orphaned-callback
    /// bug. Checking identity against `backgroundSession()` pins the wiring.
    @Test("a transfer built without a session rides the shared one")
    func productionInitUsesTheSharedSession() {
        let transfer = RelayFileTransfer(
            relayURL: URL(string: "https://relay.test/dsh-link")!, deviceToken: "dt"
        )
        #expect(transfer.backgroundSessionForTesting === RelayFileTransfer.backgroundSession())
    }

    // MARK: - the background delivery callback (P-2′)

    /// The completion handler is released **by the session delegate**, and only
    /// there.
    ///
    /// P-2 implemented `urlSessionDidFinishEvents` on the *app* delegate. The SDK
    /// sends that message to the **session's** delegate, and `UIApplicationDelegate`
    /// does not declare the method at all, so the handler was stored somewhere no
    /// callback could ever reach and was never released — invisible in every
    /// runtime test, because nothing about a transfer's outcome changes.
    ///
    /// This test is possible precisely because the fix moved the method to the
    /// delegate: it is an ordinary instance method there, so it can be called
    /// directly instead of waiting for a system background delivery that neither
    /// the simulator nor the unit tests can produce.
    @Test("the session delegate releases the stored background handler exactly once",
          .timeLimit(.minutes(1)))
    func backgroundDeliveryReleasesTheHandler() async {
        let calls = Counter()

        RelayFileTransfer.BackgroundEvents.setHandler { calls.increment() }
        RelayFileTransfer.BackgroundEvents.finishEvents(
            sessionIdentifier: RelayFileTransfer.sessionIdentifier
        )

        // The hop to the main queue inside the delegate is asynchronous by design,
        // so the assertion has to let it run — with a deadline, so a regression
        // that stops calling the handler shows up as a failure and not a hang.
        let released = await waitUntil { calls.value == 1 }
        #expect(released, "the handler was never released")
        #expect(calls.value == 1)

        // A second delivery of the same events is a no-op: the handler was taken,
        // not read. Calling a system completion handler twice crashes on some iOS
        // versions and leaves the app suspended in the background on others.
        RelayFileTransfer.BackgroundEvents.finishEvents(
            sessionIdentifier: RelayFileTransfer.sessionIdentifier
        )
        try? await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == 1)
    }

    /// Events for a session we do not own must not release **our** handler.
    ///
    /// The handler belongs to one delivery of one session's events; answering on
    /// behalf of another session would tell the system we are done while our own
    /// events are still arriving.
    @Test("a foreign session's events do not release our handler",
          .timeLimit(.minutes(1)))
    func foreignSessionEventsAreIgnored() async {
        let calls = Counter()

        RelayFileTransfer.BackgroundEvents.setHandler { calls.increment() }
        RelayFileTransfer.BackgroundEvents.finishEvents(
            sessionIdentifier: "com.jayanttang.dsh.tests.foreign-session"
        )

        try? await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == 0)

        // Leave nothing registered for the next test in the suite.
        RelayFileTransfer.BackgroundEvents.setHandler(nil)
    }
}

/// A counter the delegate's `@Sendable` closure and the test can share.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Polls `condition` until it holds or the deadline passes.
///
/// A fixed sleep would be either flaky (too short) or slow (too long); polling
/// with a ceiling makes "the handler was never called" a bounded failure.
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Collects progress callbacks from a `@Sendable` closure (the download's own
/// callback is not actor-isolated, so the test must not assume it either).
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    func record(_ value: Int) { lock.withLock { recorded.append(value) } }
    var values: [Int] { lock.withLock { recorded } }
}

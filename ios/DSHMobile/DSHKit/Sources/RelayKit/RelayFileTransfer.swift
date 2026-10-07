import CryptoKit
import Foundation
import DSHKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends a file to (and fetches one from) the relay with a **background** URL
/// session.
///
/// **This is the only route for file bytes, in both directions.** There used to
/// be a second, chunked implementation over the WebSocket, selected by size and
/// used as a fallback whenever this one failed; it is gone. Two reasons, both
/// paid for: a background session is the only transport the system keeps working
/// after the app is suspended (a `URLSessionWebSocketTask` cannot ride one at
/// all), and the fallback turned a successful upload into a silent 28 MB re-send
/// — the phone showed a transfer that never ended for a file the computer already
/// had.
///
/// The relay is the endpoint because the phone cannot reach the computer (the
/// connector dials out and listens on loopback only). The relay writes nothing:
/// it pumps the bytes straight out over the connector's socket, and the connector
/// stages the file where the agent can read it.
///
/// Three rules this type is built around:
///
/// * the task is **file-based** (`uploadTask(with:fromFile:)`,
///   `downloadTask(with:)`), because only a file task is continued in the
///   background. Callers hand over a URL in the app's own container, never `Data`.
/// * the callbacks ride the **session delegate**, never a completion handler and
///   never a per-task delegate — a background session refuses both with an
///   uncatchable `NSGenericException` (a hard crash, twice on device).
/// * `isDiscretionary` stays **false**. Left true the system batches transfers
///   for "a good moment" (typically charging, on Wi-Fi) and the user concludes
///   the app simply did not send anything.
public struct RelayFileTransfer: Sendable {

    /// Relay origin in HTTP form, including any mount prefix.
    public let relayURL: URL
    /// This phone's device credential.
    public let deviceToken: String

    private let session: URLSession

    /// The background session identifier.
    ///
    /// Fixed rather than per-call: iOS keeps one session per identifier for the
    /// life of the app, and a fresh identifier per upload would leak a session
    /// each time (and orphan its tasks across launches).
    public static let sessionIdentifier = "com.jayanttang.dsh.relay-file-transfer"

    /// The delegate a caller-supplied session must be built with.
    ///
    /// A **background** session may not use completion-handler APIs and may not
    /// carry a per-task delegate, so every answer arrives at the session's own
    /// delegate — which must therefore be this one. Exposed because a test that
    /// injects its own session has to build it the same way: without the delegate
    /// the callbacks have nowhere to go and the upload waits forever rather than
    /// failing, which is a hang, not a red test.
    public static var sessionDelegate: any URLSessionDelegate { RelaySessionDelegate.shared }

    /// The session delegate's release-the-system callback, for tests.
    ///
    /// The architect's fix for P-2 requires a test that calls
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` **directly** — it is
    /// an ordinary method on the delegate, so no real background delivery is
    /// needed to exercise it. `RelaySessionDelegate` is internal to this package,
    /// and the test target imports it non-`@testable` (the same reason
    /// `sessionDelegate` above exists), so the two pieces a test needs are
    /// published here rather than making the whole delegate public.
    ///
    /// Deliberately **not** a way to bypass the callback: a test that calls this
    /// to release a handler is testing nothing, and the API shape makes that
    /// obvious by naming the delegate it belongs to.
    /// The download bookkeeping a test needs to drive, published for the same
    /// reason `Sink` is: `RelayDownloadSink` and `RelayDownloadWaiter` are
    /// internal, and the test target imports this package without `@testable`.
    ///
    /// What this exists for is the **interruption** path — a blob in a failure's
    /// `userInfo` reaching the waiter that stores it. That hop is invisible from
    /// outside (the download still succeeds on retry, just from zero), so it
    /// needs a test that can stand exactly where the delegate stands.
    public enum DownloadSink {
        /// `NSURLSessionDownloadTaskResumeData`, the key the system uses.
        public static var resumeDataKey: String { RelayDownloadWaiter.resumeDataKey }

        /// Register a waiter for `task`, as `download` does before it resumes.
        public static func register(_ task: URLSessionTask) -> RelayDownloadWaiter {
            RelayDownloadSink.register(task)
        }

        /// Deliver a task's completion to the **shipped** delegate.
        ///
        /// This is the whole point of the seam: the blob only ever appears inside
        /// `didCompleteWithError`, and whether it reaches the waiter is a property
        /// of *this* delegate (`RelaySessionDelegate` is internal). Driving it
        /// from a test is the only way to catch the hop going missing — the
        /// download still succeeds without it, so nothing else notices.
        public static func complete(_ session: URLSession, task: URLSessionTask,
                                    error: (any Error)?) {
            RelaySessionDelegate.shared.urlSession(session, task: task,
                                                   didCompleteWithError: error)
        }
    }

    public enum BackgroundEvents {
        /// Register the action the session delegate runs when delivery finishes.
        ///
        /// This is the **product** entry point as well as the test one: the app's
        /// `handleEventsForBackgroundURLSession` calls it with the system's
        /// handler, because the delegate that will run it is internal to this
        /// package. Pass `nil` to clear it (what a test's teardown does).
        public static func setHandler(_ action: (() -> Void)?) {
            RelaySessionDelegate.setDidFinishEvents(action)
        }

        /// Point the session delegate's log lines at the app's logger.
        ///
        /// `RelayKit` has no logger of its own on purpose (see `reassociate()`);
        /// the app injects one at launch. Left unset the delegate is silent.
        public static func setLogger(_ sink: (@Sendable (String) -> Void)?) {
            RelaySessionDelegate.log = sink
        }

        /// Deliver "every event for this session has arrived" to the delegate.
        ///
        /// `identifier` defaults to the product background session; a test can
        /// pass another to check that a foreign session's events are ignored.
        public static func finishEvents(sessionIdentifier identifier: String) {
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            let session = URLSession(configuration: configuration)
            RelaySessionDelegate.shared.urlSessionDidFinishEvents(
                forBackgroundURLSession: session
            )
            session.invalidateAndCancel()
        }
    }

    /// The sink's two task hooks, for a delegate a test supplies itself.
    ///
    /// `RelayTransferSink` is internal, and a test that wants to stand in for the
    /// real delegate has to be able to drive the same two things it does: record
    /// the bytes, and finish the task. Exposing them keeps that test from having
    /// to recreate the registry — or, worse, from quietly not exercising it.
    public enum Sink {
        /// Records a body chunk against the task's waiter.
        public static func record(body: Data, for task: URLSessionTask) {
            RelayTransferSink.waiter(for: task)?.record(body: body)
        }

        /// Finishes the task's waiter with the outcome the delegate saw.
        public static func finish(_ task: URLSessionTask, error: (any Error)? = nil) {
            RelayTransferSink.finish(task, error: error)
        }
    }

    /// A background configuration, or `nil` where there is no such thing.
    ///
    /// `URLSessionConfiguration.background` does not exist on macOS, and the
    /// package builds for both (the test suite runs on macOS). Callers that need
    /// the real thing must be on iOS; on macOS this reads as "cannot".
    public static func backgroundConfiguration() -> URLSessionConfiguration? {
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        // The system relaunches the app into the background when the transfer
        // finishes; without this the delegate is never told and the completion
        // handler never runs.
        configuration.sessionSendsLaunchEvents = true
        // Deliberately default (false): see the note on the type.
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = false
        return configuration
        #else
        return nil
        #endif
    }

    /// - Parameter session: injected for tests. Production callers pass `nil` and
    ///   get **the one shared background session**; the unit tests must not open
    ///   one (macOS cannot exercise iOS background semantics, so a test that
    ///   opened one would be proving nothing about the real behaviour).
    public init(relayURL: URL, deviceToken: String, session: URLSession? = nil) {
        self.relayURL = relayURL
        self.deviceToken = deviceToken
        self.session = session ?? Self.backgroundSession()
    }

    /// The one background session this process uses for file bytes.
    ///
    /// **One instance, held for the life of the app.** iOS keeps exactly one
    /// session per identifier, so building a second `URLSession` with the same
    /// identifier does not give a second session — it returns (effectively) the
    /// same one, and the *last* delegate a caller installs is the one whose
    /// callbacks arrive. Two objects each believing they owned "their" session
    /// therefore end up sharing a delegate and neither owns the lifetime; that
    /// ambiguity is what `ownsSession` used to paper over, and it is why the
    /// accessor is a single stored instance rather than a factory.
    ///
    /// `reassociate()` is what makes this correct across a **cold start**: the
    /// system relaunches the app to deliver a finished transfer, and a session
    /// that nobody built would never hand those events to the delegate. It is
    /// deliberately built at launch, before (and without) any transfer.
    private static let shared = SharedSession()

    /// Holds the session strongly so it is not deallocated between transfers.
    ///
    /// A `URLSession` with no strong reference goes away along with its pending
    /// callbacks, which is precisely the state a background launch starts in.
    private final class SharedSession: @unchecked Sendable {
        private let lock = NSLock()
        private var session: URLSession?

        /// The session, built on first use — on macOS this is the plain fallback
        /// below, and on iOS the real background one.
        func current() -> URLSession {
            lock.lock()
            defer { lock.unlock() }
            if let session { return session }
            let built = Self.build()
            session = built
            return built
        }

        /// Builds the session for this platform.
        ///
        /// 后台会话**必须**带自己的 delegate 建出来：一个后台任务不接受
        /// per-task 的 `task.delegate`（`NSGenericException: 'Task delegate is
        /// not supported on background session task'`），回调只走会话的
        /// delegate。见 `RelaySessionDelegate`。
        private static func build() -> URLSession {
            if let configuration = RelayFileTransfer.backgroundConfiguration() {
                configuration.sessionSendsLaunchEvents = true
                return URLSession(
                    configuration: configuration,
                    delegate: RelaySessionDelegate.shared,
                    delegateQueue: nil
                )
            }
            // 仅 macOS 单测可达，不是产品回落：macOS 上没有后台会话
            // （`backgroundConfiguration()` 返回 nil），而单测跑在 macOS。普通会话
            // 一样能把请求做对，只是它不会在 App 被挂起后继续。
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            return URLSession(configuration: configuration)
        }
    }

    /// The production session, for a caller that only needs the transport.
    public static func backgroundSession() -> URLSession { shared.current() }

    /// The session this value will use, for the tests that pin session identity.
    ///
    /// Public only because the test target imports `RelayKit` (not `@testable` —
    /// it is a separate module from the app's own code). The name says what it is
    /// for; the only question it answers is "did a transfer built without an
    /// injected session attach itself to the one shared instance?".
    public var backgroundSessionForTesting: URLSession { session }

    /// Rebuilds (or re-reaches) the background session at **launch**, and holds it.
    ///
    /// Why this exists: `sessionSendsLaunchEvents` is true, so iOS relaunches the
    /// app in the background to deliver the outcome of a transfer that finished
    /// while it was away. Those events are delivered to the **session's delegate**
    /// — and the app has just started, so no session exists yet. Without this,
    /// the system's launch event reaches nobody: the transfer completes, the app
    /// is woken into the background, and nothing is recorded, which is the shape
    /// of "I thought I had sent it and it never arrived".
    ///
    /// Answering the question a reader will have: **reaching the session for an
    /// identifier that already exists does not create a second one.** iOS keeps
    /// one session per identifier for the life of the process; what this call
    /// guarantees is that the object is alive (and so its delegate is reachable)
    /// before any event can be routed to it. It is idempotent and safe to call
    /// on every launch. It is **not** a transfer and must never start one — the
    /// acceptance for P-2 includes "a launch makes no requests".
    ///
    /// No logging here on purpose: `DSHLog` lives in the app target and this
    /// package has no opinion about it. The caller (`APNSRegistrar`) writes the
    /// "background session re-associated" line.
    @discardableResult
    public static func reassociate() -> URLSession {
        shared.current()
    }

    /// The connector capability that turns this path on.
    ///
    /// Feature detection, not a version comparison: an older connector simply
    /// does not list the word, and the app then reports "too old" instead of
    /// silently sending the file a second way.
    public static let capability = "background-transfer"

    /// Why a file transfer cannot happen here at all.
    ///
    /// **This is the replacement for "fall back to the WSS path".** There is one
    /// route for file bytes — the relay's HTTP surface with a background task —
    /// so a failure to *reach* that route is a failure to send the file, and the
    /// person is told which of the three things is wrong. Nothing here is a
    /// choice between transports; each case is a statement that the one transport
    /// is not available.
    public enum Unavailable: LocalizedError, Sendable {
        /// The connection is not through the relay (`dsh://direct`, a DEBUG-only
        /// test channel). The channel itself stays usable; file transfer does not.
        case noRelay
        /// The connector is older than the bridge frames (it does not announce
        /// `background-transfer`).
        case connectorTooOld
        /// The stored credential for this connection is gone.
        case credentialMissing
        /// The relay address on this profile is not a usable HTTP origin.
        case relayAddressInvalid
        /// The file to upload is no longer where the caller said it was.
        ///
        /// Not a preference and not another route: `uploadTask(with:fromFile:)`
        /// raises an uncatchable ObjC exception for a path that does not exist
        /// (invariant 6), so this case exists to turn that crash into an
        /// ordinary failure the chat screen can report.
        case sourceFileMissing(String)
        /// The file is there but this process may not read it — same crash face
        /// as `sourceFileMissing`, same treatment.
        case sourceFileUnreadable(String)

        public var errorDescription: String? {
            switch self {
            case .noRelay:
                return String(localized: "这条连接方式不支持发送文件")
            case .connectorTooOld:
                return String(localized: "电脑上的连接器版本过旧，请更新后重发")
            case .credentialMissing:
                return String(localized: "此连接的凭据已丢失，请重新配对。")
            case .relayAddressInvalid:
                return String(localized: "这条连接的中转地址无效，请重新配对。")
            case .sourceFileMissing:
                return String(localized: "文件已经不在了，请重新选择一次再发")
            case .sourceFileUnreadable:
                return String(localized: "读不到这个文件，请重新选择一次再发")
            }
        }
    }

    /// Where one upload landed.
    ///
    /// This is the **relay's answer shape**, decoded straight from `/files/up`;
    /// `asStaged` maps it onto the transport-neutral `StagedFile` the app passes
    /// around, so no caller has to know which transport carried the bytes.
    public struct Staged: Decodable, Sendable {
        public let path: String
        public let bytes: Int

        public var asStaged: StagedFile {
            StagedFile(path: path, bytes: bytes)
        }
    }

    private struct ErrorEnvelope: Decodable {
        let ok: Bool?
        let error: DSHRPCFailure?
    }

    /// The upload's request, built but not started (tests inspect it; the caller
    /// hands it to the session).
    ///
    /// `bid` is the relay's correlation id and is **stable across retries** of the
    /// same attempt: the connector overwrites by `bid`, so a retried upload is
    /// idempotent instead of leaving a second file behind.
    public func request(fileURL: URL, name: String, sessionId: String, bid: String) -> URLRequest? {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        components?.path = LinkConfiguration.appending(path: "/files/up", to: relayURL)
        components?.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "bytes", value: String(Self.fileSize(fileURL))),
            URLQueryItem(name: "bid", value: bid),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Downloading

    /// Where one download may land, as far as the *transport* is concerned.
    ///
    /// Deliberately just the destination: the cache semantics (which version
    /// lives in which directory, when a copy is stale) belong to
    /// `WorkspaceFileCache`, and this type is not allowed an opinion about them.
    public struct Fetched: Sendable {
        public let url: URL
        public let bytes: Int
    }

    /// The download's request, built but not started.
    ///
    /// `offset` is the resume point and is sent **twice, in both forms on
    /// purpose**: as the `offset` query field (which the relay reads) and as
    /// `Range: bytes=N-` (which is what a standard HTTP cache or proxy in front
    /// of the relay understands). The design calls `Range` required, not
    /// optional: a background `URLSessionDownloadTask` gets none of the `.part`
    /// continuation the WSS path relies on, so without it one dropped connection
    /// restarts a 300 MB file from zero — worse than the behaviour it replaces.
    public func downloadRequest(scopeId: String, path: String, offset: Int = 0,
                                bid: String) -> URLRequest? {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        components?.path = LinkConfiguration.appending(path: "/files/down", to: relayURL)
        components?.queryItems = [
            URLQueryItem(name: "scopeId", value: scopeId),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "bid", value: bid),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    /// Downloads `destination`, continuing from the system's own resume data
    /// when there is any for this version.
    ///
    /// **This is plan A.** The bytes an interruption saved are not tracked by the
    /// app at all: the system keeps them, hands back a `resumeData` blob, and
    /// `downloadTask(withResumeData:)` picks them up. That is what makes the
    /// guarantee hold even when the app was suspended or killed through the
    /// interruption — there is no app-side bookkeeping that could have missed it,
    /// which is exactly why the old `.part` + offset mechanism could not deliver
    /// it (the offset was always 0 in the cases that mattered).
    ///
    /// The blob is stored per `(scopeId, path, version)`. The version is the
    /// file's freshness token, so a blob from before a change can never be
    /// resumed into the changed file; if the version moved, this simply starts
    /// over, which is the correct answer rather than a compromise.
    ///
    /// `expectedBytes` is checked when the host declared a size: a short transfer
    /// must fail here rather than be published as the document.
    public func download(
        scopeId: String,
        path: String,
        to destination: URL,
        version: String,
        expectedBytes: Int? = nil,
        bid: String = UUID().uuidString,
        onProgress: (@Sendable (Int) -> Void)? = nil,
        resumeRoot: URL? = nil
    ) async throws -> Fetched {
        try await download(scopeId: scopeId, path: path, to: destination, version: version,
                           expectedBytes: expectedBytes, bid: bid, onProgress: onProgress,
                           cancelStandIn: nil, resumeRoot: resumeRoot)
    }

    /// `download`, with the task's cancel replaced by a stand-in.
    ///
    /// Exists for one test: whether a resume blob delivered **after** the waiter
    /// has already finished still reaches the store. That ordering is the whole
    /// bug (`p13c…storedBlob=-1` on the simulator), and it cannot be produced
    /// through `URLProtocol` — the suite's stub — because a resume blob only ever
    /// comes from a real download task. Injecting the callback is the only way to
    /// hold the timing still and assert on it.
    ///
    /// `public` for the same reason `DownloadSink` is: the test target imports
    /// this package without `@testable`. Shipping code has no reason to call it —
    /// the name says so, and `download` below is what it delegates to.
    public func downloadForTesting(
        scopeId: String,
        path: String,
        to destination: URL,
        version: String,
        expectedBytes: Int? = nil,
        bid: String = UUID().uuidString,
        lateBlob: Data?,
        lateBlobDelay: Duration,
        resumeRoot: URL? = nil
    ) async throws -> Fetched {
        try await download(scopeId: scopeId, path: path, to: destination, version: version,
                           expectedBytes: expectedBytes, bid: bid, onProgress: nil,
                           cancelStandIn: (blob: lateBlob, delay: lateBlobDelay),
                           resumeRoot: resumeRoot)
    }

    private func download(
        scopeId: String,
        path: String,
        to destination: URL,
        version: String,
        expectedBytes: Int?,
        bid: String,
        onProgress: (@Sendable (Int) -> Void)?,
        cancelStandIn: (blob: Data?, delay: Duration)?,
        resumeRoot: URL? = nil
    ) async throws -> Fetched {
        // `resumeRoot` exists so a test can point the store at its own
        // directory without touching the process-wide environment variable that
        // two parallel suites would otherwise race on (see the note on
        // `RelayResumeStore.root`). Production passes `nil`, which is exactly
        // the shipping behaviour.
        let stored = RelayResumeStore.load(scopeId: scopeId, path: path, version: version,
                                           root: resumeRoot)
        let task: URLSessionDownloadTask
        if let resumeData = stored {
            // The bid inside the blob is frozen from the interrupted attempt. That
            // is deliberate and safe: the connector cancels a superseded run when
            // the same bid reappears (`files-out.js`), and `expectedBytes` is the
            // final judge if a stale window ever slipped through.
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            guard let request = downloadRequest(scopeId: scopeId, path: path, offset: 0, bid: bid)
            else { throw DSHTransportError.unreachable("中转地址无效") }
            task = session.downloadTask(with: request)
        }
        let waiter = RelayDownloadSink.register(task)
        // Where a `cancel(byProducingResumeData:)` callback leaves its blob.
        //
        // It cannot be a plain `save` inside the closure: the system is free to
        // run that callback **after** `didCompleteWithError` has already released
        // the waiter, and `download` used to throw the moment the waiter finished.
        // The blob then arrived at a closure whose work had already been skipped,
        // the store stayed empty, and the next attempt downloaded the whole file
        // again — silently, because a retry from zero still succeeds.
        //
        // A box rather than an `AsyncStream` on purpose: the stream's only writer
        // lived in `onCancel`, so a cancellation the handler did not observe meant
        // no blob could ever be produced, and the reader below then saw an empty
        // stream and concluded "nothing to resume from". The box is written by
        // whichever path actually produces a blob, and read afterwards.
        let lateBlob = BlobBox()
        task.resume()

        let outcome = await withTaskCancellationHandler {
            // Waited without a clock, exactly as before this fix. The
            // simulator proved this always resolves — `didCompleteWithError`
            // fires for a cancel as well as for a drop — and putting a clock on
            // it would fail slow-but-fine downloads.
            //
            // An earlier attempt raced this against a cancellation signal and
            // hung every ordinary transfer: the signal branch parks on a
            // `CheckedContinuation`, which `TaskGroup.cancelAll()` cannot end, so
            // the group's scope never closed. The bound belongs where the
            // cancellation is, not around the healthy wait — see `onCancel`.
            await waiter.value()
        } onCancel: {
            // Cancelling must **ask for the resume data**, not just drop the
            // task: a plain `cancel()` throws away every byte the system had
            // already fetched, which is precisely the loss this path exists to
            // prevent.
            //
            // Nothing here finishes the waiter. An earlier version did
            // (`waiter.finish(error: CancellationError())`) to guarantee the wait
            // ended — and that is the worst possible place for it: the *real*
            // failure, which is the one carrying the resume blob in its
            // `userInfo`, then arrives at a waiter that has already been finished
            // and is discarded. The simulator showed it exactly:
            // `NSURLSessionDownloadTaskResumeData={length = 9955 …}` in the log
            // while the app reported `storedBlob=-1`.
            if let cancelStandIn {
                // Test-only: deliver the blob late, the way the real callback
                // does. See `downloadForTesting`.
                Task {
                    try? await Task.sleep(for: cancelStandIn.delay)
                    if let blob = cancelStandIn.blob, !blob.isEmpty {
                        lateBlob.put(blob)
                    }
                    lateBlob.close()
                }
                return
            }
            task.cancel(byProducingResumeData: { data in
                if let data, !data.isEmpty { lateBlob.put(data) }
                lateBlob.close()
            })
        }

        if let error = outcome.error {
            // An interrupted attempt is not a failure to report and forget: the
            // blob is what makes the next attempt cost only the difference. Two
            // sources, and either can be the only one that fires — the waiter's
            // `userInfo` (a network drop) or the cancel callback (a deliberate
            // cancel). Waiting on the box closes the race where the waiter
            // finished first and the blob was still on its way.
            //
            // **Bounded**, because the callback is not promised: when the system
            // has nothing to resume from it never calls back, and waiting forever
            // would turn "no resume data" — which the retry path already handles —
            // into a download that never returns. A second is far longer than the
            // callback takes when it does come.
            var blob = outcome.resumeData
            if blob == nil {
                blob = await lateBlob.wait(within: .seconds(1))
            }
            if let blob {
                RelayResumeStore.save(blob, scopeId: scopeId, path: path, version: version,
                                      root: resumeRoot)
            }
            throw error
        }
        guard let http = outcome.response as? HTTPURLResponse else {
            throw DSHTransportError.malformedResponse("中转响应无效")
        }
        guard let temporary = outcome.temporaryURL else {
            throw DSHTransportError.malformedResponse("中转响应无效")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The body of a failed download is small JSON (the relay answers
            // errors before it starts streaming), so reading it here costs
            // nothing and keeps the failure the connector's own code.
            let body = (try? Data(contentsOf: temporary)) ?? Data()
            try? FileManager.default.removeItem(at: temporary)
            throw Self.failure(status: http.statusCode, body: body)
        }

        let arrived = Self.fileSize(temporary)
        onProgress?(arrived)
        if let expectedBytes, arrived != expectedBytes {
            try? FileManager.default.removeItem(at: temporary)
            throw DSHTransportError.malformedResponse(
                "文件没有完整传完（应有 \(expectedBytes) 字节，收到 \(arrived) 字节）"
            )
        }

        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: temporary, to: destination)
        // The download is over, so its blob is worthless: keeping it would let a
        // later attempt "resume" into a file that already exists.
        RelayResumeStore.discard(scopeId: scopeId, path: path, version: version, root: resumeRoot)
        return Fetched(url: destination, bytes: arrived)
    }


    /// The seam a test needs to drive `BlobBox`, published for the same reason
    /// `DownloadSink` is: the test target imports this package without
    /// `@testable`.
    ///
    /// What it exists for is the **timing** the resume blob depends on. The blob
    /// is produced on another queue and may land after the wait for the transfer
    /// has ended; the box is what makes "read it anyway" possible, and a
    /// regression shows up only as a download that silently restarts from zero —
    /// which is why it needs a test that can hold the timing still.
    public enum LateBlobBox {
        public final class Box: @unchecked Sendable {
            private let box = BlobBox()
            public init() {}
            public func put(_ data: Data) { box.put(data) }
            public func close() { box.close() }
            public func wait(within timeout: Duration) async -> Data? {
                await box.wait(within: timeout)
            }
        }
    }

    /// Where a resume blob lands when it is produced on another queue.
    ///
    /// The cancel callback and the delegate's `didCompleteWithError` run on
    /// queues the caller does not control, and either may arrive after the wait
    /// for the task has already ended. A box that can be **polled with a
    /// deadline** lets `download` ask "did a blob turn up" without depending on
    /// the callback landing before some other event — which is exactly the
    /// dependency that lost the blob in the first version.
    ///
    /// A plain lock and a continuation rather than an `AsyncStream`: the writer
    /// must be callable from a non-async callback (`cancel(byProducingResumeData:)`
    /// takes a plain closure), and the reader must be able to give up.
    final class BlobBox: @unchecked Sendable {
        private let lock = NSLock()
        private var blob: Data?
        private var closed = false
        private var waiting: CheckedContinuation<Data?, Never>?

        func put(_ data: Data) {
            lock.lock()
            if blob == nil { blob = data }
            let continuation = waiting
            waiting = nil
            lock.unlock()
            continuation?.resume(returning: data)
        }

        /// No further blob will arrive; a waiter should stop early.
        func close() {
            lock.lock()
            closed = true
            let continuation = waiting
            waiting = nil
            lock.unlock()
            continuation?.resume(returning: blob)
        }

        /// The blob, or `nil` once it is closed or `timeout` passes.
        ///
        /// The timeout has to **release the waiter**, not merely stop observing
        /// it: a `CheckedContinuation` parked in `waiting` cannot be cancelled, so
        /// a task group that simply stops waiting leaves the box holding a
        /// continuation nobody will ever resume — and the next caller's `put`
        /// would resume a dead one. Taking the continuation out under the lock and
        /// resuming it with `nil` is what makes the bound real.
        func wait(within timeout: Duration) async -> Data? {
            await withTaskGroup(of: Data?.self) { group in
                group.addTask { await self.take() }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                self.abandon()
                // A blob that landed while the timeout branch was returning is
                // still read here, so the race cannot lose it.
                return self.settled() ?? first
            }
        }

        /// Releases a parked waiter with `nil` — the timeout's half of `put`.
        private func abandon() {
            lock.lock()
            let continuation = waiting
            waiting = nil
            lock.unlock()
            continuation?.resume(returning: nil)
        }

        private func take() async -> Data? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let blob {
                    lock.unlock()
                    continuation.resume(returning: blob)
                    return
                }
                if closed {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiting = continuation
                lock.unlock()
            }
        }

        private func settled() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return blob
        }
    }

    /// Starts an upload and returns a task the caller can await.
    ///
    /// **Delegate-based, not the `upload(for:fromFile:)` convenience.** That
    /// convenience is built on a completion-handler block, and a background
    /// session refuses those outright — `__NSURLBackgroundSession` raises
    /// `NSGenericException: 'Completion handler blocks are not supported in
    /// background sessions. Use a delegate instead.'` The exception is raised
    /// inside CFNetwork on a dispatch queue and is not catchable, so it is a
    /// hard crash of the whole app, which is exactly what a ≥ 8 MB send did on
    /// device (R-1 真机 0412). The task below hands the file over and lets a
    /// `URLSessionTaskDelegate` report the answer instead.
    ///
    /// Throws before anything is sent when the request cannot be built, or when
    /// the source file is not there to send — the caller treats either the same
    /// way as any other failure, and nothing is sent a second way.
    ///
    /// **不变量 6：会抛「catch 不到的 ObjC 异常」的 API，调用前必须有前置检查。**
    /// `uploadTask(with:fromFile:)` 就是这样一个 API：路径不存在时，
    /// `__NSURLBackgroundSession` 在
    /// `performBlockOnQueueAndRethrowExceptions:` 里把
    /// `NSInvalidArgumentException`（`NSURLSessionUploadTask` 要求的文件不存在）
    /// 重新抛到队列上，异常绕开 Swift 的 `catch`，直接 SIGABRT 杀掉整个 App
    /// （2026-09-29 两份崩溃报告，栈上是
    /// `_uploadTaskWithTaskForClass:` → `RelayFileTransfer.upload`）。
    /// 「失败即告警」对这类异常接不住 —— 它们不走 `catch`。
    /// 所以建任务之前先看文件在不在、读不读得到，不满足就抛成普通错误，
    /// 由上传的失败出口（聊天页提示条）照常告诉用户。
    ///
    /// 真实触发面：`tmp/outgoing-files/` 里的暂存件在后台任务启动前被系统清掉
    /// （iOS 对 `tmp/` 无保活承诺），或 Files 选择器给的 iCloud 占位文件还没落地。
    public func upload(
        fileURL: URL,
        name: String,
        sessionId: String,
        bid: String = UUID().uuidString
    ) async throws -> Staged {
        // Precondition for invariant 6 (see the doc comment above): check the
        // source file *before* handing the path to the task factory.
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            throw Unavailable.sourceFileMissing(fileURL.path)
        }
        guard manager.isReadableFile(atPath: fileURL.path) else {
            throw Unavailable.sourceFileUnreadable(fileURL.path)
        }
        guard let request = request(fileURL: fileURL, name: name, sessionId: sessionId, bid: bid) else {
            throw DSHTransportError.unreachable("中转地址无效")
        }
        let task = session.uploadTask(with: request, fromFile: fileURL)
        // **不要把 delegate 挂在 task 上。** 后台会话拒绝 per-task delegate
        // （`NSGenericException: 'Task delegate is not supported on background
        // session task'`，真机 OTA 0412 就崩在这里），回调只能由会话的 delegate
        // 收——所以这里只登记等待者，真正的回调在 `RelaySessionDelegate` 里。
        let waiter = RelayTransferSink.register(task)
        task.resume()

        let outcome = await withTaskCancellationHandler {
            await waiter.value()
        } onCancel: {
            task.cancel()
        }

        // A transport-level failure (offline, dropped, cancelled) has no HTTP
        // answer at all, and it is that failure. Reading it as a malformed
        // response would hide a real cause behind a message about the relay —
        // and nothing here re-sends the file another way, because there is no
        // other way.
        if let error = outcome.error { throw error }
        guard let http = outcome.response as? HTTPURLResponse else {
            throw DSHTransportError.malformedResponse("中转响应无效")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, body: outcome.body)
        }
        do {
            return try JSONDecoder().decode(Staged.self, from: outcome.body)
        } catch {
            throw DSHTransportError.malformedResponse("中转没有返回落盘路径")
        }
    }

    /// Whether the connector can serve this path at all.
    ///
    /// Feature detection, not a version comparison: a connector that lacks the
    /// capability does not list it, and an older app that does not know the word
    /// simply never asks.
    ///
    /// **This is the only remaining "which path" question, and it is not a path
    /// choice**: there is one route for file bytes, so "no" here means the send
    /// fails with `Unavailable.connectorTooOld` rather than taking another route.
    public static func supportsBackgroundTransfer(capabilities: [String]) -> Bool {
        capabilities.contains("background-transfer")
    }

    public static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func failure(status: Int, body: Data) -> any Error {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
           let failure = envelope.error {
            return failure
        }
        return DSHTransportError.httpStatus(status, body: String(data: body, encoding: .utf8))
    }
}

/// The registry of task waiters, shared by every transfer session.
///
/// Why the waiters live **outside** the transfer: a background session's
/// callbacks are delivered to the session's delegate, which is created **once**
/// per session identifier and outlives any single `RelayFileTransfer` value (iOS
/// keeps exactly one session per identifier for the life of the app, and
/// re-delivers after a relaunch). A waiter stored on the transfer would therefore
/// be unreachable from the callback for exactly the transfers this path exists to
/// survive. So the transfer registers a waiter here, and the delegate — whichever
/// session it belongs to — looks it up by its key.
///
/// **The key is a token carried on the task itself, not `taskIdentifier`.** That
/// integer is unique only *within one session* — every session numbers its first
/// task `1` — so a registry keyed by it cannot tell two sessions' tasks apart.
/// The mistake is invisible in production (one long-lived session) and fatal in
/// tests, which build a fresh session per case: a waiter left behind by an
/// earlier session collided with the next session's task 1, whose completion then
/// resolved the wrong one and left the real caller awaiting a callback that had
/// already been delivered — a hang, with nothing red to show for it.
///
/// `taskDescription` is the carrier because it is the one per-task slot
/// `URLSession` keeps that survives into the delegate callbacks and is not used
/// by anything else here. It is set in `register` and read in `waiter(for:)`.
enum RelayTransferSink {
    /// The prefix that marks a `taskDescription` as ours.
    private static let tokenPrefix = "dsh-transfer:"

    /// The registry, behind an immutable handle.
    ///
    /// A `static var` here is rejected by strict concurrency (mutable global
    /// state); the storage lives in a `let`-bound object whose own lock is what
    /// makes the mutation safe, which is the shape the compiler asks for.
    private static let registry = Registry()

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [String: RelayTaskWaiter] = [:]

        func insert(_ waiter: RelayTaskWaiter, for key: String) {
            lock.lock()
            waiters[key] = waiter
            lock.unlock()
        }

        func waiter(for key: String) -> RelayTaskWaiter? {
            lock.lock()
            defer { lock.unlock() }
            return waiters[key]
        }

        func take(for key: String) -> RelayTaskWaiter? {
            lock.lock()
            defer { lock.unlock() }
            return waiters.removeValue(forKey: key)
        }
    }

    /// The key of a task, or `nil` when it is not one of ours.
    ///
    /// A task this registry never registered (a session's own bookkeeping task,
    /// or one whose description was overwritten) has no waiter, and every lookup
    /// below then does nothing — which is what keeps an unknown task from
    /// stealing a real transfer's answer.
    private static func key(of task: URLSessionTask) -> String? {
        guard let description = task.taskDescription,
              description.hasPrefix(tokenPrefix) else { return nil }
        return description
    }

    static func register(_ task: URLSessionTask) -> RelayTaskWaiter {
        let waiter = RelayTaskWaiter()
        let key = tokenPrefix + UUID().uuidString
        task.taskDescription = key
        registry.insert(waiter, for: key)
        return waiter
    }

    static func waiter(for task: URLSessionTask) -> RelayTaskWaiter? {
        guard let key = key(of: task) else { return nil }
        return registry.waiter(for: key)
    }

    /// Finishes the task's waiter, taking the response off the task when the
    /// delegate never recorded one.
    ///
    /// **The backstop lives here rather than in the delegate on purpose.** The
    /// response of an upload is only ever delivered by a callback, and a delegate
    /// that does not implement the one this platform uses leaves the waiter with
    /// nothing — which is exactly what shipped in OTA 0633: every byte uploaded,
    /// `200` returned, and the app threw `malformedResponse` and re-sent the file
    /// over WSS. Putting the fallback at the single point every delegate must
    /// reach makes "completed but no recorded response" unrepresentable, whatever
    /// the callback coverage looks like.
    static func finish(_ task: URLSessionTask, error: (any Error)?) {
        guard let key = key(of: task) else { return }
        let waiter = registry.take(for: key)
        waiter?.record(responseFromTask: task.response)
        waiter?.finish(error: error)
    }
}

/// One task's answer, bridged from delegate callbacks into an awaitable value.
///
/// `finish` is guarded so the continuation is resumed **exactly once**:
/// `didCompleteWithError` can arrive after a response or a body chunk has already
/// been recorded, and resuming twice traps.
final class RelayTaskWaiter: @unchecked Sendable {
    struct Outcome: @unchecked Sendable {
        let response: URLResponse?
        let body: Data
        let error: (any Error)?
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var response: URLResponse?
    private var body = Data()
    private var finished: Outcome?

    public func value() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let finished {
                lock.unlock()
                continuation.resume(returning: finished)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func record(response: URLResponse) {
        lock.lock()
        self.response = response
        lock.unlock()
    }

    /// Records the response carried by the task itself, at completion.
    ///
    /// Only fills a gap: a response already recorded from a delegate callback
    /// wins, because that one arrived first and is the same object. This exists so
    /// that "no delegate callback ever fired" cannot turn a completed, answered
    /// transfer into "the relay sent an unreadable answer".
    func record(responseFromTask taskResponse: URLResponse?) {
        guard let taskResponse else { return }
        lock.lock()
        if response == nil { response = taskResponse }
        lock.unlock()
    }

    func record(body chunk: Data) {
        lock.lock()
        body.append(chunk)
        lock.unlock()
    }

    func finish(error: (any Error)?) {
        lock.lock()
        guard finished == nil else { lock.unlock(); return }
        let outcome = Outcome(response: response, body: body, error: error)
        finished = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: outcome)
    }
}

/// The registry of **download** waiters, keyed exactly like the upload one.
///
/// Separate from `RelayTransferSink` because the two carry different things: an
/// upload's answer is "response + body" (`RelayTaskWaiter`), a download's is
/// "the temporary file the system wrote, plus the response". A download's
/// temporary file is only valid **until the delegate callback returns**, so the
/// delegate moves it aside first and the waiter receives that stable copy —
/// see `RelaySessionDelegate.urlSession(_:downloadTask:didFinishDownloadingTo:)`.
enum RelayDownloadSink {
    private static let tokenPrefix = "dsh-download:"

    private static let registry = Registry()

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [String: RelayDownloadWaiter] = [:]

        func insert(_ waiter: RelayDownloadWaiter, for key: String) {
            lock.lock()
            waiters[key] = waiter
            lock.unlock()
        }

        func waiter(for key: String) -> RelayDownloadWaiter? {
            lock.lock()
            defer { lock.unlock() }
            return waiters[key]
        }

        func take(for key: String) -> RelayDownloadWaiter? {
            lock.lock()
            defer { lock.unlock() }
            return waiters.removeValue(forKey: key)
        }
    }

    private static func key(of task: URLSessionTask) -> String? {
        guard let description = task.taskDescription,
              description.hasPrefix(tokenPrefix) else { return nil }
        return description
    }

    static func register(_ task: URLSessionTask) -> RelayDownloadWaiter {
        let waiter = RelayDownloadWaiter()
        let key = tokenPrefix + UUID().uuidString
        task.taskDescription = key
        registry.insert(waiter, for: key)
        return waiter
    }

    static func waiter(for task: URLSessionTask) -> RelayDownloadWaiter? {
        guard let key = key(of: task) else { return nil }
        return registry.waiter(for: key)
    }

    /// Hands the moved temp file to the task's waiter.
    static func record(temporaryURL: URL, for task: URLSessionTask) {
        guard let key = key(of: task) else { return }
        registry.waiter(for: key)?.record(temporaryURL: temporaryURL)
    }

    /// Ends the task's waiter, taking the response off the task when the delegate
    /// never recorded one (the same backstop the upload side has, and for the same
    /// reason: a transfer that completed must never read as "no answer").
    static func finish(_ task: URLSessionTask, error: (any Error)?) {
        guard let key = key(of: task) else { return }
        let waiter = registry.take(for: key)
        waiter?.record(responseFromTask: task.response)
        waiter?.finish(error: error)
    }
}

/// One download task's answer, bridged from delegate callbacks into an awaitable
/// value.
///
/// `finish` is guarded so the continuation is resumed **exactly once**:
/// `didCompleteWithError` arrives after `didFinishDownloadingTo`, and resuming
/// twice traps.
public final class RelayDownloadWaiter: @unchecked Sendable {
    public struct Outcome: @unchecked Sendable {
        public let temporaryURL: URL?
        public let response: URLResponse?
        public let error: (any Error)?
        /// The system's resume blob, when this attempt ended in a way that
        /// produced one.
        ///
        /// Read off `didCompleteWithError`'s `userInfo` — the second of the two
        /// places it appears, and the one a *network drop* uses (a deliberate
        /// cancel delivers it to the `cancel(byProducingResumeData:)` callback
        /// instead). A caller that only watched one of them would conclude "the
        /// system gave nothing" from a callback that simply is not the one this
        /// failure used.
        public let resumeData: Data?
    }

    /// `NSURLSessionDownloadTaskResumeData` by its literal name.
    ///
    /// Spelled out rather than referenced through a constant: the SDK exposes no
    /// Swift symbol for it, and the string is the documented contract (it is what
    /// appears in the failure's `userInfo`). A typo here would silently disable
    /// every network-drop resume, so it is stated once, in one place.
    public static let resumeDataKey = "NSURLSessionDownloadTaskResumeData"

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var response: URLResponse?
    private var temporaryURL: URL?
    private var resumeData: Data?
    private var finished: Outcome?

    public func value() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let finished {
                lock.unlock()
                continuation.resume(returning: finished)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func record(temporaryURL url: URL) {
        lock.lock()
        self.temporaryURL = url
        lock.unlock()
    }

    func record(responseFromTask taskResponse: URLResponse?) {
        guard let taskResponse else { return }
        lock.lock()
        if response == nil { response = taskResponse }
        lock.unlock()
    }

    /// Keep the blob the system handed back, when it handed one over.
    func record(resumeData data: Data?) {
        guard let data, !data.isEmpty else { return }
        lock.lock()
        // First one wins: only one failure ends the transfer, and a later
        // `finish` must not overwrite what that failure already produced.
        if resumeData == nil { resumeData = data }
        lock.unlock()
    }

    func finish(error: (any Error)?) {
        lock.lock()
        guard finished == nil else { lock.unlock(); return }
        // The error's `userInfo` is the other source, and for a network drop it
        // is the *only* one. Read here rather than in the delegate so both paths
        // converge on one stored value.
        var blob = resumeData
        if blob == nil, let error,
           let fromError = (error as NSError).userInfo[Self.resumeDataKey] as? Data {
            blob = fromError
        }
        let outcome = Outcome(temporaryURL: temporaryURL, response: response, error: error,
                              resumeData: blob)
        finished = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: outcome)
    }
}

/// The delegate for the background transfer session.
///
/// It is a **session** delegate because a background session allows nothing else:
/// it refuses completion-handler block APIs (`upload(for:fromFile:)`) and it
/// refuses a per-task delegate (`task.delegate = …`) — both raise an
/// `NSGenericException` from inside CFNetwork that no `catch` can see, so each one
/// is a hard crash (R-1 真机 OTA 0412 hit both). Only
/// `URLSession(configuration:delegate:delegateQueue:)` with the callbacks on the
/// delegate works, which is what this is.
/// Where the system's resume data for an interrupted download is kept.
///
/// **This is the whole of plan A's persistence.** A background
/// `URLSessionDownloadTask` that is cancelled or dropped can hand back a
/// `resumeData` blob; feeding it to `downloadTask(withResumeData:)` lets the
/// system continue from the bytes it already has, without the app tracking an
/// offset or keeping a `.part` prefix of its own. That is what makes "an
/// interruption loses nothing" true even when the app was never running to
/// observe it.
///
/// Keyed by `(scopeId, path, version)`, exactly like the file cache, and for the
/// same reason: the version is the file's freshness token, so a blob written for
/// the previous contents can never be resumed into the current ones. A resume
/// that crossed a version change would splice two different files together —
/// which is why the version is part of the key rather than something checked
/// afterwards.
///
/// On disk under `Caches` (the same reclamable, un-backed-up area the file cache
/// uses); nothing here is worth keeping the way a document is.
public enum RelayResumeStore {
    /// `#if DEBUG`-only relocation, compiled out of shipping builds — the same
    /// isolation hook `OutgoingFiles` and `WorkspaceFileCache` have, so a test on
    /// macOS cannot write into the developer's real `~/Library/Caches`.
    ///
    /// **Prefer the `root:` parameter on the calls below when testing.** This
    /// environment hook is process-global, and Swift Testing runs suites in
    /// parallel: two suites that each `setenv` a different root race on a value
    /// `root` reads fresh every time, so a `save` and the `load` that should see
    /// it can land on different directories. That is not a product defect (no
    /// shipping build has the variable) but it made "single suite green, whole
    /// run red" the normal outcome. A parameter cannot race.
    public static var root: URL {
        defaultRoot
    }

    /// The root used when a caller passes none: the environment override, or
    /// `Caches/relay-resume`.
    static var defaultRoot: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["DSH_RELAY_RESUME_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("relay-resume", isDirectory: true)
    }

    /// A filename that identifies one file's one version without leaking the
    /// path into the directory tree.
    ///
    /// Hashed rather than nested: a workspace path contains slashes and can be
    /// arbitrarily deep, and mirroring it here would mean creating (and later
    /// pruning) a tree for a single blob.
    public static func key(scopeId: String, path: String, version: String) -> String {
        var hasher = SHA256()
        for piece in [scopeId, path, version] {
            hasher.update(data: Data(piece.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func url(scopeId: String, path: String, version: String,
                           root: URL? = nil) -> URL {
        (root ?? defaultRoot)
            .appendingPathComponent(key(scopeId: scopeId, path: path, version: version))
    }

    /// Keep a blob the system handed back, replacing any earlier one for the
    /// same version.
    ///
    /// The **newest blob wins**: a later interruption knows about more bytes than
    /// an earlier one, and keeping both would mean choosing on read with no way
    /// to tell which is which.
    public static func save(_ data: Data, scopeId: String, path: String, version: String,
                            root: URL? = nil) {
        let base = root ?? defaultRoot
        let target = url(scopeId: scopeId, path: path, version: version, root: base)
        let manager = FileManager.default
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
        try? manager.removeItem(at: target)
        try? data.write(to: target, options: .atomic)
    }

    /// The blob for this exact version, if one was kept.
    public static func load(scopeId: String, path: String, version: String,
                            root: URL? = nil) -> Data? {
        try? Data(contentsOf: url(scopeId: scopeId, path: path, version: version, root: root))
    }

    /// Forget one file's blob — called once the file is complete, because a blob
    /// that outlived its download would be resumed into a file that already
    /// exists.
    public static func discard(scopeId: String, path: String, version: String,
                               root: URL? = nil) {
        try? FileManager.default.removeItem(
            at: url(scopeId: scopeId, path: path, version: version, root: root)
        )
    }

    /// Drop blobs older than `age`, swept at launch.
    ///
    /// Same bargain as the outgoing-file staging area: a download abandoned
    /// mid-interruption leaves a blob nothing will ever claim, and the system
    /// cannot know that. Age rather than "unreferenced" because the blob's owner
    /// (the file cache entry) may itself have been trimmed.
    @discardableResult
    public static func sweep(olderThan age: TimeInterval = 24 * 60 * 60,
                             now: Date = Date(), root: URL? = nil) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root ?? defaultRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        var removed = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}

final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate,
                                  URLSessionDownloadDelegate, URLSessionDelegate, @unchecked Sendable {
    static let shared = RelaySessionDelegate()

    /// What to run when the system says every background event for our session
    /// has been delivered.
    ///
    /// **This is the shell the app hands its completion handler to.** The system
    /// sends `urlSessionDidFinishEvents(forBackgroundURLSession:)` to the
    /// **session's delegate**, never to the app delegate — so a handler stored on
    /// the app delegate is stored in a place the callback will never reach, and
    /// is therefore never released (`UIApplicationDelegate` has no such method to
    /// be called through). Keeping the closure here, next to the callback that
    /// invokes it, is what makes the two impossible to separate again: the
    /// delegate has no way to hold a handler it cannot release.
    ///
    /// Set by the app layer at launch (`APNSRegistrar`) and taken when it fires:
    /// the callback nils it out before running it, so a duplicate delivery is a
    /// no-op rather than a second call to a system handler that must run exactly
    /// once.
    ///
    /// Not `@Sendable`: the closure is the **system's own** completion handler
    /// (`handleEventsForBackgroundURLSession`), which UIKit does not declare as
    /// sendable. The mutable storage is guarded by `didFinishLock` and the value
    /// is only ever invoked on the main queue, which is what the type system
    /// would otherwise be standing in for.
    nonisolated(unsafe) static var onDidFinishEvents: (() -> Void)?

    /// Where the delegate's lines go, if the app wants them.
    ///
    /// A closure rather than a call into `DSHLog`: this package deliberately has
    /// no opinion about logging (see `reassociate()`), and linking the app's
    /// logger in would make the package depend on the app. The app sets this at
    /// launch; left unset, the delegate is silent.
    nonisolated(unsafe) static var log: (@Sendable (String) -> Void)?

    /// The lock around `onDidFinishEvents`.
    ///
    /// The callback arrives on the delegate queue (not the main thread), while
    /// registration happens at launch on the main thread; an unsynchronised
    /// read-modify-write across those two is exactly the kind of race that shows
    /// up once in a thousand background wakes and never in a test.
    private static let didFinishLock = NSLock()

    /// Register the action to run when background delivery finishes.
    ///
    /// Idempotent: registering twice replaces the previous action, which is what
    /// a relaunch wants (the old process's closure would reference a dead
    /// handler). Passing `nil` clears it.
    static func setDidFinishEvents(_ action: (() -> Void)?) {
        didFinishLock.lock()
        onDidFinishEvents = action
        didFinishLock.unlock()
    }

    /// Take the registered action, leaving nothing behind.
    ///
    /// **Take, not read**: the system's completion handler must be called exactly
    /// once — calling it twice crashes on some iOS versions and leaves the app
    /// suspended in the background on others. Clearing before returning makes a
    /// repeated delivery structurally inert instead of relying on the caller to
    /// remember.
    static func takeDidFinishEvents() -> (() -> Void)? {
        didFinishLock.lock()
        defer { didFinishLock.unlock() }
        let action = onDidFinishEvents
        onDidFinishEvents = nil
        return action
    }

    /// The sink a given session's callbacks should land in.
    ///
    /// The shared delegate is what production sessions are built with. A caller
    /// that injects its own session must give that session a delegate too — the
    /// unit tests construct theirs with `RelayFileTransfer.sessionDelegate` —
    /// because a session with **no** delegate never calls back, and the upload
    /// would simply wait forever.
    static func sink(for session: URLSession) -> RelaySessionDelegate {
        (session.delegate as? RelaySessionDelegate) ?? shared
    }

    /// Every background event for our session has been delivered — release the
    /// system.
    ///
    /// **This is the only place the app's stored completion handler is
    /// released**, and the reason this method lives here rather than on the app
    /// delegate: the SDK's own header says "the session delegate will receive
    /// this message" (`NSURLSession.h`), and `UIApplicationDelegate` does not
    /// declare it at all. Implementing it on the app delegate compiled — because
    /// it is a plain method once a `URLSessionDelegate` conformance is added —
    /// but the system never sent it there and the handler was never called.
    ///
    /// The `identifier` check is deliberate: answering on behalf of a session we
    /// do not own would cut someone else's delivery short. Today there is one
    /// background session, but a second one would otherwise silently release the
    /// wrong handler — the check costs a string compare and removes that.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier
        guard identifier == RelayFileTransfer.sessionIdentifier else {
            Self.log?("didFinishEvents ignored for a foreign session: \(identifier ?? "(none)")")
            return
        }
        // Taken inside the static helper, under the same lock registration uses:
        // a duplicate delivery finds `nil` and does nothing.
        guard let action = Self.takeDidFinishEvents() else { return }
        Self.log?("urlSessionDidFinishEventsForBackgroundURLSession")
        // The system's handler is a main-queue callback (UIKit's rule for it), and
        // the delegate queue is not the main queue, so hop before calling.
        //
        // `assumeIsolated` rather than a plain `async`: the hop is already the
        // guarantee (both this call and the handler's own contract are
        // main-thread), and passing the handler across a `@Sendable` boundary
        // would demand a conformance UIKit does not give it. The jump is real
        // either way — this only states what is already true at the destination.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { action() }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        // `didCompleteWithError` is the one callback guaranteed to arrive, and for
        // an **upload** task it is the only one that carries the response in
        // practice: URLSession routes an upload's response to the
        // `URLSessionTaskDelegate` variant below, not to the
        // `URLSessionDataDelegate` one. When the data-task variant was the sole
        // implementation, `RelayTaskWaiter.response` stayed nil for every upload,
        // and a transfer that had uploaded every byte and been answered `200` was
        // thrown away as `malformedResponse` — the app re-sent the whole file over
        // the WSS path, so the phone showed an upload that never ended for a file
        // the computer had already received (R-1 真机 OTA 0633).
        //
        // Reading the response off the task here is the backstop that makes that
        // mistake unrepeatable rather than merely fixed: an upload's own answer
        // always reaches its waiter.
        // 回复与中断留下的 resume data 都由 `finish` 兜底补上（见那里的注释），
        // 这里只负责结束这一步。
        RelayTransferSink.finish(task, error: error)
        RelayDownloadSink.finish(task, error: error)
    }

    /// Where a finished download's bytes are, moved out of the system's
    /// temporary file **before this method returns**.
    ///
    /// Apple's rule for `URLSessionDownloadTask`: the file the system hands back
    /// "is deleted ... as soon as this method returns", so a caller that only
    /// remembers the URL (as the old completion-handler code did) is racing the
    /// deletion. This moves it into the app's own container and gives the waiter
    /// that path; the worker then decides what the bytes are worth (append onto a
    /// `.part`, or take the destination's place) and deletes the copy.
    ///
    /// The name is unique per task so two downloads can finish at once, and it
    /// lives under `Caches` — the same directory the file cache itself uses —
    /// which is what makes the move a rename rather than a 300 MB copy.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("relay-download-staging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let landed = staging.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.removeItem(at: landed)
            try FileManager.default.moveItem(at: location, to: landed)
            RelayDownloadSink.record(temporaryURL: landed, for: downloadTask)
        } catch {
            // Could not get the bytes out in time: fail the transfer rather than
            // let `download()` read a path the system is about to delete.
            RelayDownloadSink.finish(downloadTask, error: error)
            return
        }
        // `didCompleteWithError` follows and calls `finish`; nothing else here.
    }

    /// The response callback an **upload** task actually invokes.
    ///
    /// `uploadTask(with:fromFile:)` produces a `URLSessionUploadTask`, which is a
    /// `URLSessionDataTask` subclass, so this is the data-task method below —
    /// there is no separate task-level response callback on
    /// `URLSessionTaskDelegate` (its members are `didCompleteWithError`,
    /// `didSendBodyData`, the challenge/redirect hooks and metrics). The gap that
    /// shipped in OTA 0633 was therefore not "the wrong variant of the right
    /// method" but "the delegate was never asked": the response never reached the
    /// waiter at all, and the completion below is what now guarantees it does.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        RelayTransferSink.waiter(for: dataTask)?.record(body: data)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        RelayTransferSink.waiter(for: dataTask)?.record(response: response)
        completionHandler(.allow)
    }
}

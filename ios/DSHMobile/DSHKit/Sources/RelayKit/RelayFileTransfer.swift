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
    private let ownsSession: Bool

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
    ///   get the background session; the unit tests must not open one (macOS can
    ///   not exercise iOS background semantics, so a test that opened one would
    ///   be proving nothing about the real behaviour).
    public init(relayURL: URL, deviceToken: String, session: URLSession? = nil) {
        self.relayURL = relayURL
        self.deviceToken = deviceToken
        if let session {
            self.session = session
            self.ownsSession = false
        } else if let configuration = Self.backgroundConfiguration() {
            // 后台会话**必须**带自己的 delegate 建出来：一个后台任务不接受
            // per-task 的 `task.delegate`（`NSGenericException: 'Task delegate is
            // not supported on background session task'`），回调只走会话的
            // delegate。见 `RelaySessionDelegate`。
            self.session = URLSession(
                configuration: configuration,
                delegate: RelaySessionDelegate.shared,
                delegateQueue: nil
            )
            self.ownsSession = true
        } else {
            // 仅 macOS 单测可达，不是产品回落：macOS 上没有后台会话
            // （`backgroundConfiguration()` 返回 nil），而单测跑在 macOS。普通会话
            // 一样能把请求做对，只是它不会在 App 被挂起后继续。
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
            self.ownsSession = true
        }
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

    /// Why a resumed download cannot be trusted.
    ///
    /// The relay answers a `Range` request with the offset it actually started
    /// from in `X-DSH-Offset`. When that disagrees with the offset the caller
    /// asked for, the bytes on the wire are **not** the continuation of the
    /// prefix on disk: appending them would publish a file with a hole in it, so
    /// the transfer stops instead.
    public struct ResumeMismatch: LocalizedError, Sendable {
        /// The offset the caller asked for (= bytes already on disk).
        public let expected: Int
        /// The offset the relay reported, or `nil` when it reported none.
        public let reported: Int?

        public init(expected: Int, reported: Int?) {
            self.expected = expected
            self.reported = reported
        }

        public var errorDescription: String? {
            guard let reported else {
                return String(localized: "中转没有从预期的位置续传（期望第 \(expected) 字节起）")
            }
            return String(localized: "中转没有从预期的位置续传（期望第 \(expected) 字节起，实际第 \(reported) 字节起）")
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

    /// The relay's answer to a `Range` request: the byte it actually started at.
    ///
    /// The relay answers 200 rather than 206 and puts the start offset in
    /// `X-DSH-Offset`, because it streams from the connector rather than from a
    /// file it can seek in. A caller that assumed 206 would have to guess; this
    /// reads what the relay actually says.
    ///
    /// **Read by `download` on every resumed transfer** — it is the check that
    /// turns "the relay ignored my `Range`" from a silently corrupt file into a
    /// loud failure. Nothing else may depend on it.
    public static func resumedOffset(status: Int, headers: [AnyHashable: Any]) -> Int? {
        _ = status
        guard let raw = headers["X-DSH-Offset"] as? String else { return nil }
        return Int(raw)
    }

    /// Downloads the file and leaves it at `destination`, resuming from `offset`.
    ///
    /// The move is the whole point of using a `downloadTask`: the system hands
    /// back a temporary file it wrote **while the app was suspended**, and that
    /// file has to be moved before the delegate callback returns or the system
    /// deletes it. Production callers therefore pass the cache's own **`.part`**
    /// path (`WorkspaceFileCache.partial`), never the final name — a resumed
    /// transfer concatenates onto the prefix there, and `publish()` is what turns
    /// the finished `.part` into the file.
    ///
    /// The resumed prefix is *not* re-verified against `expectedBytes` here: the
    /// caller (the cache, keyed by the host's version token) is the one that knows
    /// whether those bytes belong to this file. What this does check is
    ///   1. that the relay's own `X-DSH-Offset` agrees with `offset` — otherwise
    ///      the reply is a different window than the caller asked for, and
    ///   2. that `offset + arrived == expectedBytes` when the host declared a size
    ///      — a truncated transfer must not be published as whole.
    public func download(
        scopeId: String,
        path: String,
        to destination: URL,
        offset: Int = 0,
        expectedBytes: Int? = nil,
        bid: String = UUID().uuidString,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Fetched {
        guard let request = downloadRequest(scopeId: scopeId, path: path, offset: offset, bid: bid)
        else {
            throw DSHTransportError.unreachable("中转地址无效")
        }

        // **Delegate task, not `session.download(for:)`.** The async convenience is
        // built on a completion-handler block, and a background session refuses
        // those outright: `NSGenericException: 'Completion handler blocks are not
        // supported in background sessions. Use a delegate instead.'` — raised
        // inside CFNetwork on a dispatch queue, so no `catch` can see it and the
        // whole app dies. That is exactly what a ≥ 8 MB download did on device;
        // the upload half had already crashed the same way (OTA 0412) and was
        // moved to a delegate. The task below hands the file to the system and
        // lets `RelaySessionDelegate` report where it landed.
        let task = session.downloadTask(with: request)
        let waiter = RelayDownloadSink.register(task)
        task.resume()

        let outcome = await withTaskCancellationHandler {
            await waiter.value()
        } onCancel: {
            // 与上传同形：取消只取消这一个 task。**不用**
            // `cancel(byProducingResumeData:)`——续传由我们自己的 `.part` +
            // offset 负责，resumeData 是另一套语义，混用就是第二条路。
            task.cancel()
        }

        if let error = outcome.error { throw error }
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

        // **The resume check.** `offset > 0` means the caller has a prefix on disk
        // and asked the relay to continue from it. If the relay says it started
        // somewhere else — it ignored the `Range` (a proxy rewrote it), or it
        // answered a fresh full body — the bytes in hand are not the continuation
        // of that prefix. Appending them would publish a file with a hole in it,
        // and the size check below would not catch it (it measures the *tail*).
        if offset > 0, let reported = Self.resumedOffset(
            status: http.statusCode, headers: http.allHeaderFields
        ), reported != offset {
            try? FileManager.default.removeItem(at: temporary)
            throw ResumeMismatch(expected: offset, reported: reported)
        }

        let arrived = Self.fileSize(temporary)
        onProgress?(offset + arrived)
        if let expectedBytes, offset + arrived != expectedBytes {
            try? FileManager.default.removeItem(at: temporary)
            throw DSHTransportError.malformedResponse(
                "文件没有完整传完（应有 \(expectedBytes) 字节，收到 \(offset + arrived) 字节）"
            )
        }

        let manager = FileManager.default
        let complete = destination
        try manager.createDirectory(at: complete.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)

        // A resumed transfer appends the tail onto the prefix already at
        // `destination`; a fresh one simply takes the temp file's place. Doing
        // this through one handle keeps a 300 MB resume from ever holding the
        // whole file in memory.
        if offset > 0 {
            try Self.append(temporary, to: complete)
            try? manager.removeItem(at: temporary)
        } else {
            try? manager.removeItem(at: complete)
            try manager.moveItem(at: temporary, to: complete)
        }
        return Fetched(url: complete, bytes: offset + arrived)
    }

    /// Appends `source`'s bytes onto `destination`, creating it when absent.
    ///
    /// Streamed in chunks rather than `Data(contentsOf:) + write`: the file is
    /// by definition a large one (that is why it is on this path), and building
    /// it in memory to concatenate would undo the point of a background task.
    private static func append(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: destination.path) {
            manager.createFile(atPath: destination.path, contents: nil)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.seekToEnd()
        while true {
            let chunk = try input.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
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

    func value() async -> Outcome {
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
final class RelayDownloadWaiter: @unchecked Sendable {
    struct Outcome: @unchecked Sendable {
        let temporaryURL: URL?
        let response: URLResponse?
        let error: (any Error)?
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var response: URLResponse?
    private var temporaryURL: URL?
    private var finished: Outcome?

    func value() async -> Outcome {
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

    func finish(error: (any Error)?) {
        lock.lock()
        guard finished == nil else { lock.unlock(); return }
        let outcome = Outcome(temporaryURL: temporaryURL, response: response, error: error)
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
final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate,
                                  URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = RelaySessionDelegate()

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
        // 回复由 `finish` 兜底补上（见那里的注释），这里只负责结束这一步。
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

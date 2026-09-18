import Foundation

/// Pulls a whole workspace file down to the phone, one bounded window at a time,
/// resumable and retrying.
///
/// The Host has no download endpoint: `workspaceFiles/readBytes` answers with one
/// window of raw bytes, base64 in a JSON field, and refuses a window larger than
/// its `maxBytes` rather than shortening it. Three things about the link decide
/// the shape of this type:
///
/// - **Windows are the unit of failure.** The link is a phone on a mobile
///   network through a relay that paces per device and drops a device whose
///   socket stalls. A transfer that throws everything away when one window
///   fails turns a 10-second download into "retry three or four times" — which
///   is what the first version of this did.
/// - **Bytes already written are kept.** The loop appends to the destination and
///   resumes from the file's current size, so a retry costs one window, not the
///   whole file. The caller owns the file and decides when it is complete.
/// - **The window adapts.** A window that takes longer than the transport's
///   deadline is worse than useless: it fails *and* wastes the wait. Windows
///   shrink after a slow or refused one and grow back after a run of quick ones,
///   so a congested link settles on a size it can actually carry.
///
/// Bytes are appended as they arrive rather than collected in memory: a 300 MB
/// file costs one window of RAM. The gap between windows is deliberate — the
/// session list, the transcript and the agent's own output share this one link,
/// and a download that queues window after window back-to-back is what would
/// make a turn feel stuck.
public struct WorkspaceFileDownloader: Sendable {

    /// The window a download starts with: the Host's own `maxBytes`.
    ///
    /// The relay writes a frame this large as several WebSocket messages when the
    /// device is over its rate, which `FrameAssembler` on the carrier puts back
    /// together; a slow link shrinks the window from here.
    public static let windowBytes = 2 * 1024 * 1024

    /// The floor for the adaptive window.
    public static let minimumWindowBytes = 32 * 1024

    /// How many times one window is retried before the transfer gives up.
    public static let windowRetries = 4

    private let client: DSHClient
    private let pacing: Duration
    private let retries: Int
    /// Injected so tests do not sleep through a backoff schedule.
    private let backoff: @Sendable (Int) -> Duration

    /// - Parameters:
    ///   - pacing: idle time between windows. Zero in tests; the app leaves the
    ///     default so a large file yields the link between windows.
    ///   - retries: attempts per window beyond the first.
    ///   - backoff: delay before attempt `n` (0-based). Default is 0.5s doubling.
    public init(
        client: DSHClient,
        pacing: Duration = .milliseconds(50),
        retries: Int = WorkspaceFileDownloader.windowRetries,
        backoff: @escaping @Sendable (Int) -> Duration = { attempt in
            let seconds = 0.5 * pow(2, Double(max(0, attempt)))
            return .milliseconds(Int(seconds * 1000))
        }
    ) {
        self.client = client
        self.pacing = pacing
        self.retries = max(0, retries)
        self.backoff = backoff
    }

    // MARK: - Types

    /// Identity and size of the file, before any of its bytes move.
    public struct Info: Sendable, Hashable {
        public let absolutePath: String
        /// Opaque freshness token; used to key the phone's cache, never parsed.
        public let version: String
        /// The complete size, when the backend reports it.
        public let bytes: Int?
    }

    public struct Progress: Sendable, Hashable {
        public let received: Int
        public let total: Int?

        public init(received: Int, total: Int?) {
            self.received = received
            self.total = total
        }

        /// 0…1 when the total is known; nil when it is not, so the UI shows a
        /// spinner rather than a bar pretending to know where it is.
        public var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(received) / Double(total))
        }
    }

    public struct Fetched: Sendable, Hashable {
        public let url: URL
        /// Bytes in the file now — the resumed prefix included.
        public let bytes: Int
        public let version: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// The window's `data` was not base64, so the stream cannot be trusted.
        case malformedWindow(offset: Int)
        /// A window came back empty without `eof`: paging any further would spin.
        case stalled(offset: Int)
        /// The assembled file is not the size the host reported. Raised rather
        /// than handed on, because a truncated picture or archive fails later in
        /// a way that looks like the file's own fault.
        case sizeMismatch(expected: Int, received: Int)
        /// A whole-file read hit its caller's cap.
        case overCap(limit: Int, bytes: Int?)
        /// Every attempt at one window failed. `saved` is what is already on
        /// disk, which is what a resume continues from.
        case interrupted(offset: Int, saved: Int, reason: String)

        public var errorDescription: String? {
            switch self {
            case .malformedWindow:
                return "主机返回的文件内容无法解析，读取已中止。"
            case .stalled:
                return "读取中断：主机没有返回更多内容。"
            case .sizeMismatch(let expected, let received):
                return "文件没有完整传完（应有 \(expected) 字节，收到 \(received) 字节）。"
            case .overCap:
                return "文件超过这个页面能在手机上打开的大小，请在电脑上查看。"
            case .interrupted(_, let saved, let reason):
                return "下载中断（已保存 \(saved) 字节）：\(reason)"
            }
        }

        /// Whether resuming from what is already on disk is worth offering.
        public var isResumable: Bool {
            switch self {
            case .interrupted, .malformedWindow, .stalled: return true
            case .sizeMismatch, .overCap: return false
            }
        }
    }

    // MARK: - Reading

    /// One `stat`: the file's identity, version and size, without content.
    public func info(scopeId: String, path: String) async throws -> Info {
        let raw = try await client.workspaceFileStat(scopeId: scopeId, path: path)
        return Info(
            absolutePath: raw["absolutePath"]?.stringValue ?? path,
            version: raw["version"]?.stringValue ?? "",
            bytes: raw["bytes"]?.intValue
        )
    }

    /// Fetches the file into `destination`, continuing from `offset` bytes.
    ///
    /// The destination's parent directory is created. Bytes already in the file
    /// are trusted and appended to — the caller is responsible for having checked
    /// that they belong to this version of the file. Nothing is deleted on
    /// failure: the bytes that arrived are the point of the next attempt.
    ///
    /// - Parameter offset: how many leading bytes of `destination` are already
    ///   correct. `0` replaces the file.
    public func fetch(
        scopeId: String,
        path: String,
        to destination: URL,
        from offset: Int = 0,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Fetched {
        let info = try await info(scopeId: scopeId, path: path)
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var received = 0
        if offset > 0 {
            // Trust-but-verify: a partial longer than the file itself belongs to
            // something else, and starting mid-file from it would corrupt.
            let existing = (try? manager.attributesOfItem(atPath: destination.path))?[.size] as? Int
            guard let existing, existing <= (info.bytes ?? Int.max) else {
                try manager.createFile(atPath: destination.path, contents: nil)
                return try await fetch(scopeId: scopeId, path: path, to: destination, onProgress: onProgress)
            }
            received = min(existing, offset)
            if let total = info.bytes, received == total {
                onProgress?(Progress(received: received, total: total))
                return Fetched(url: destination, bytes: received, version: info.version)
            }
        } else {
            manager.createFile(atPath: destination.path, contents: nil)
        }

        guard let handle = FileHandle(forWritingAtPath: destination.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try handle.seekToEnd()

        var sizer = WindowSizer()
        do {
            while true {
                try Task.checkCancellation()
                let window = try await nextWindow(
                    scopeId: scopeId,
                    path: path,
                    offset: received,
                    sizer: &sizer
                )
                if !window.piece.isEmpty {
                    try handle.write(contentsOf: window.piece)
                    received += window.piece.count
                    onProgress?(Progress(received: received, total: info.bytes))
                    if let total = info.bytes, received > total {
                        throw Failure.sizeMismatch(expected: total, received: received)
                    }
                }
                if window.eof { break }
                if pacing > .zero { try await Task.sleep(for: pacing) }
            }
            try handle.close()
        } catch {
            // The bytes stay: that is what a resume continues from. Only the
            // handle goes away.
            try? handle.close()
            throw error
        }

        if let total = info.bytes, total != received {
            throw Failure.sizeMismatch(expected: total, received: received)
        }
        return Fetched(url: destination, bytes: received, version: info.version)
    }

    /// A whole small file in memory, for the callers that are about to render it
    /// anyway — the web preview and the files it refers to.
    ///
    /// - Parameter cap: refuse anything larger instead of paying for it. A page
    ///   or picture past the cap is one the phone should not be rendering.
    public func data(
        scopeId: String,
        path: String,
        cap: Int? = nil,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Data {
        let info = try await info(scopeId: scopeId, path: path)
        if let cap, let total = info.bytes, total > cap { throw Failure.overCap(limit: cap, bytes: total) }

        var collected = Data()
        var sizer = WindowSizer()
        if let total = info.bytes { collected.reserveCapacity(min(total, cap ?? total)) }
        while true {
            try Task.checkCancellation()
            let window = try await nextWindow(
                scopeId: scopeId,
                path: path,
                offset: collected.count,
                sizer: &sizer
            )
            if !window.piece.isEmpty {
                collected.append(window.piece)
                onProgress?(Progress(received: collected.count, total: info.bytes))
                if let cap, collected.count > cap { throw Failure.overCap(limit: cap, bytes: info.bytes) }
            }
            if window.eof { break }
            if pacing > .zero { try await Task.sleep(for: pacing) }
        }
        return collected
    }

    // MARK: - The window loop

    /// One usable window, retried, with the size adapted to the link.
    ///
    /// The same offset is asked again after any failure worth retrying — a
    /// timeout, a dropped socket, a reply that would not decode, or a window that
    /// came back empty without `eof` — so no bytes are ever skipped and nothing
    /// already on disk is paid for twice. A `too-large` refusal means the
    /// deployment caps below what this build asks for, which is answered by
    /// shrinking the window rather than failing the transfer.
    private func nextWindow(
        scopeId: String,
        path: String,
        offset: Int,
        sizer: inout WindowSizer
    ) async throws -> (piece: Data, eof: Bool) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            do {
                let window = try await self.window(
                    scopeId: scopeId,
                    path: path,
                    offset: offset,
                    length: sizer.bytes
                )
                guard let piece = Data(base64Encoded: window.data) else {
                    throw Failure.malformedWindow(offset: offset)
                }
                // Empty before `eof` means the host has nothing more at this
                // offset; asking again is the only thing that could change it.
                if piece.isEmpty, !window.eof { throw Failure.stalled(offset: offset) }
                sizer.note(.success(seconds: started.duration(to: .now).seconds))
                return (piece, window.eof)
            } catch let failure as DSHRPCFailure where failure.code == "workspace-file/too-large" {
                guard sizer.shrink() else { throw failure }
            } catch {
                if error is CancellationError { throw error }
                if !Self.isRetryable(error) { throw error }
                sizer.note(.failure)
                guard attempt < retries else {
                    throw Failure.interrupted(
                        offset: offset,
                        saved: offset,
                        reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    )
                }
                let delay = backoff(attempt)
                attempt += 1
                if delay > .zero { try await Task.sleep(for: delay) }
            }
        }
    }

    /// Whether another attempt at the same window could plausibly succeed.
    ///
    /// A missing file, a refused path or a size that does not add up will answer
    /// the same way every time; a timeout, a dropped socket or a relay that just
    /// went quiet may not.
    private static func isRetryable(_ error: any Error) -> Bool {
        if let failure = error as? Failure {
            switch failure {
            case .interrupted, .malformedWindow, .stalled: return true
            case .sizeMismatch, .overCap: return false
            }
        }
        if let failure = error as? DSHRPCFailure {
            switch failure.code {
            case "workspace-file/not-found", "workspace-file/outside-workspace",
                 "workspace-file/not-regular-file", "workspace-file/not-directory",
                 "workspace-file/unknown-workspace", "gateway/lookup-not-found",
                 "gateway/bad-request":
                return false
            default:
                return true
            }
        }
        return true
    }

    // MARK: - Wire

    /// One `readBytes` window, already unwrapped to the fields that matter.
    private struct Window {
        let data: String
        let eof: Bool
    }

    private func window(scopeId: String, path: String, offset: Int, length: Int) async throws -> Window {
        let raw = try await client.workspaceFileReadBytes(
            scopeId: scopeId,
            path: path,
            offset: offset,
            length: length
        )
        return Window(
            data: raw["data"]?.stringValue ?? "",
            eof: raw["eof"]?.boolValue ?? false
        )
    }

    /// The window size in flight, adapting to what the link can carry.
    ///
    /// The cap belongs to the deployment and the deadline to the transport, and
    /// neither is knowable from here — so the size is discovered: shrink on a
    /// refusal or a slow window, grow back after a run of quick ones. A window
    /// that used most of the deadline is one that would fail outright the next
    /// time the network hiccups.
    private struct WindowSizer {
        enum Observation {
            /// A window that took this long to arrive, in seconds.
            case success(seconds: Double)
            /// A window that needed another attempt.
            case failure
        }

        private(set) var bytes = WorkspaceFileDownloader.windowBytes
        private var quick = 0

        /// A window may not use more than this share of the transport's deadline
        /// (60s) before the next one is asked for smaller.
        private static let slowSeconds = 12.0
        /// A window this quick, several times in a row, means there is headroom.
        private static let quickSeconds = 2.0
        private static let quickRun = 4

        mutating func note(_ observation: Observation) {
            switch observation {
            case .failure:
                shrink()
            case .success(let seconds):
                if seconds > Self.slowSeconds {
                    shrink()
                } else if seconds < Self.quickSeconds {
                    quick += 1
                    if quick >= Self.quickRun { grow(); quick = 0 }
                } else {
                    quick = 0
                }
            }
        }

        /// - Returns: false at the floor, where a refusal cannot be about size.
        @discardableResult
        mutating func shrink() -> Bool {
            quick = 0
            guard bytes > WorkspaceFileDownloader.minimumWindowBytes else { return false }
            bytes = max(WorkspaceFileDownloader.minimumWindowBytes, bytes / 2)
            return true
        }

        private mutating func grow() {
            guard bytes < WorkspaceFileDownloader.windowBytes else { return }
            bytes = min(WorkspaceFileDownloader.windowBytes, bytes * 2)
        }
    }
}

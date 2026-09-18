import Foundation

/// Pulls a whole workspace file down to the phone, one bounded window at a time.
///
/// The Host has no download endpoint. `workspaceFiles/readBytes` answers with one
/// window of raw bytes, base64 in a JSON field, and it *refuses* a window larger
/// than its own `maxBytes` instead of shortening it. So the loop here advances by
/// the bytes it actually received, stops on `eof`, and halves its window if a
/// deployment turns out to cap lower than this build asks for — asking for more
/// than the cap and trusting the request is what would turn a large document into
/// a failed download.
///
/// Bytes are appended to the destination file as they arrive instead of being
/// collected in memory: a 300 MB file costs one window of RAM. The gap between
/// windows is deliberate — the session list, the transcript and the agent's own
/// output share this one link, and a download that queues window after window
/// back-to-back is what would make a turn feel stuck.
public struct WorkspaceFileDownloader: Sendable {

    /// The window every request asks for.
    ///
    /// Sized so the **response** stays inside one WebSocket message. The relay
    /// does not split at the WebSocket level: once a device is over its rate, a
    /// device-bound frame larger than 512 KB of JSON is written as several
    /// WebSocket *messages*, and a client reading one message per frame never
    /// sees the rest of it — the request simply never answers. 192 KiB of bytes
    /// becomes about 256 KB of base64, inside that ceiling with room for the
    /// envelope, and it is the same chunk the upload path has carried in one
    /// message since it was written.
    ///
    /// Asking for less only adds round trips. Asking for more is what made a 3 MB
    /// download hang with its first window already in flight.
    public static let windowBytes = 192 * 1024

    /// How small a window may shrink to before a `too-large` refusal is treated
    /// as something other than the window size.
    private static let minimumWindowBytes = 32 * 1024

    private let client: DSHClient
    private let pacing: Duration

    /// - Parameter pacing: idle time between windows. Zero in tests; the app
    ///   leaves the default so a large file yields the link between windows.
    public init(client: DSHClient, pacing: Duration = .milliseconds(50)) {
        self.client = client
        self.pacing = pacing
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
        /// A whole-file read hit its caller's cap. `bytes` is the file's real
        /// size when the host reported it, so the copy can name it.
        case overCap(limit: Int, bytes: Int?)

        public var errorDescription: String? {
            switch self {
            case .malformedWindow:
                return "主机返回的文件内容无法解析，读取已中止。"
            case .stalled:
                return "读取中断：主机没有返回更多内容。"
            case .sizeMismatch(let expected, let received):
                return "文件没有完整传完（应有 \(expected) 字节，收到 \(received) 字节），已丢弃。"
            case .overCap:
                return "文件超过这个页面能在手机上打开的大小，请在电脑上查看。"
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

    /// Fetches the entire file into `destination`, replacing whatever was there.
    ///
    /// The destination's parent directory is created. A failed or cancelled
    /// fetch removes the partial file, so a half-arrived document can never be
    /// opened as if it were complete.
    public func fetch(
        scopeId: String,
        path: String,
        to destination: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Fetched {
        let info = try await info(scopeId: scopeId, path: path)
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        manager.createFile(atPath: destination.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: destination.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        var received = 0
        var sizer = WindowSizer()
        do {
            while true {
                try Task.checkCancellation()
                let window: Window
                do {
                    window = try await self.window(
                        scopeId: scopeId, path: path, offset: received, length: sizer.bytes
                    )
                } catch let failure as DSHRPCFailure
                    where failure.code == "workspace-file/too-large" && sizer.shrink() {
                    // A deployment whose cap is smaller than the one we ask for.
                    // Retry the same offset with a window it accepts.
                    continue
                }
                guard let piece = Data(base64Encoded: window.data) else {
                    throw Failure.malformedWindow(offset: received)
                }
                if piece.isEmpty {
                    // Empty before `eof` means the host has nothing more at this
                    // offset; looping would ask forever.
                    guard window.eof else { throw Failure.stalled(offset: received) }
                } else {
                    try handle.write(contentsOf: piece)
                    received += piece.count
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
            try? handle.close()
            try? manager.removeItem(at: destination)
            throw error
        }

        if let total = info.bytes, total != received {
            try? manager.removeItem(at: destination)
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
            let window: Window
            do {
                window = try await self.window(
                    scopeId: scopeId, path: path, offset: collected.count, length: sizer.bytes
                )
            } catch let failure as DSHRPCFailure
                where failure.code == "workspace-file/too-large" && sizer.shrink() {
                continue
            }
            guard let piece = Data(base64Encoded: window.data) else {
                throw Failure.malformedWindow(offset: collected.count)
            }
            if piece.isEmpty {
                guard window.eof else { throw Failure.stalled(offset: collected.count) }
            } else {
                collected.append(piece)
                onProgress?(Progress(received: collected.count, total: info.bytes))
                if let cap, collected.count > cap { throw Failure.overCap(limit: cap, bytes: info.bytes) }
            }
            if window.eof { break }
            if pacing > .zero { try await Task.sleep(for: pacing) }
        }
        return collected
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

    /// The window size in flight, and the one adaptation this loop needs.
    ///
    /// The cap belongs to the deployment, not to this build: `maxBytes` is
    /// configurable, and a host that caps below what we ask for refuses the
    /// request instead of trimming it. Halving on that refusal is what keeps a
    /// download working against a deployment this build has never met.
    private struct WindowSizer {
        private(set) var bytes = WorkspaceFileDownloader.windowBytes

        /// - Returns: false at the floor, where the refusal cannot be about size.
        mutating func shrink() -> Bool {
            guard bytes > WorkspaceFileDownloader.minimumWindowBytes else { return false }
            bytes = max(WorkspaceFileDownloader.minimumWindowBytes, bytes / 2)
            return true
        }
    }
}

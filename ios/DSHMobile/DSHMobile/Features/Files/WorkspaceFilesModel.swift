import DSHKit
import Foundation
import Observation

/// Drives the workspace file browser: directory listing, file reads, search,
/// and the working-tree change feed.
///
/// All three states the screen can be in are explicit, so the view never has to
/// guess whether an empty list means "empty directory" or "not loaded yet".
@MainActor
@Observable
final class WorkspaceFilesModel {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case browse
        case changes

        var id: String { rawValue }

        var label: String {
            switch self {
            case .browse: return "浏览"
            case .changes: return "变更"
            }
        }
    }

    /// How many lines one `workspaceFiles/read` page asks for. The host caps a
    /// page at its configured `maxLines` (5000 by default); a smaller page keeps
    /// the first paint fast on a large file.
    static let pageLines = 300

    let scope: WorkspaceFileScope

    private(set) var phase: Phase = .idle
    private(set) var listing: WorkspaceDirectoryListing?
    /// The listed directory as a workspace path; empty at the root.
    private(set) var browsingPath: String = ""

    private(set) var filePhase: Phase = .idle
    private(set) var file: WorkspaceFileText?
    /// True when the host refused the open file as non-text.
    ///
    /// The browser guesses an extension; the host is the one that knows. This is
    /// the signal the reader reroutes on, which is why a file whose name says
    /// nothing is still tried as text first.
    private(set) var fileRefusedAsText = false

    /// One file's trip from the computer to the phone.
    enum TransferPhase: Equatable {
        case idle
        case running(received: Int, total: Int?)
        /// Downloading stopped with bytes on disk. Not a failure: the next
        /// attempt continues from `bytes` instead of starting again, which is
        /// why it carries the reason rather than a verdict.
        case paused(bytes: Int, total: Int?, reason: String?)
        case ready(bytes: Int, url: URL)
        case failed(String)

        /// How much is on disk (or in flight) right now.
        var receivedBytes: Int? {
            switch self {
            case .running(let received, _): return received
            case .paused(let bytes, _, _): return bytes
            case .ready(let bytes, _): return bytes
            case .idle, .failed: return nil
            }
        }

        var totalBytes: Int? {
            switch self {
            case .running(_, let total), .paused(_, let total, _): return total
            case .ready(let bytes, _): return bytes
            case .idle, .failed: return nil
            }
        }

        /// Whether anything is on disk to continue from.
        var resumable: Bool {
            if case .paused = self { return true }
            return false
        }
    }

    /// Downloads by workspace path, so two sheets looking at one file agree.
    private(set) var transfers: [String: TransferPhase] = [:]
    private var transferTasks: [String: Task<URL?, Never>] = [:]
    /// Throughput per transfer, in MB/s, smoothed over the last few windows.
    ///
    /// Shown because "slow" is otherwise unfalsifiable: the number says whether
    /// the link is the limit or the app is, and it is what makes a change to the
    /// relay's pacing measurable from the phone.
    private var transferRates: [String: Double] = [:]
    private var transferStarted: [String: Date] = [:]
    private var lastSample: [String: (at: Date, bytes: Int)] = [:]

    private(set) var changesPhase: Phase = .idle
    private(set) var changes: [WorkspaceChange] = []
    private(set) var changeSet = WorkspaceChangeSet()

    var mode: Mode = .browse {
        didSet {
            guard mode != oldValue else { return }
            if mode == .changes { Task { await loadChanges() } }
        }
    }

    var searchText: String = ""

    private weak var store: ConnectionStore?

    /// The live client, for the views that fetch their own content — the web
    /// preview pulls a page and its pictures, and has no business knowing how
    /// the connection is stored.
    var client: DSHClient? { store?.client }
    private var feedTask: Task<Void, Never>?
    private var feedOpen = false

    init(scope: WorkspaceFileScope, initialPath: String = "") {
        self.scope = scope
        self.browsingPath = initialPath
        #if DEBUG
        // `-DSHForgetDownloadedFiles`: a run that means to exercise the download
        // itself — an interrupted transfer, a resume — cannot start from the
        // copy the previous run left in the cache. Without this the file is
        // already here, no window is ever fetched, and the test passes while
        // proving nothing.
        if ProcessInfo.processInfo.arguments.contains("-DSHForgetDownloadedFiles") {
            WorkspaceFileCache.clear()
        }
        #endif
    }

    convenience init(summary: SessionSummary, hostHome: String?) {
        self.init(scope: WorkspaceFileScope(summary: summary, hostHome: hostHome))
    }

    // MARK: - Lifecycle

    func attach(to store: ConnectionStore) {
        self.store = store
    }

    func start() async {
        await loadDirectory(browsingPath)
    }

    func stop() {
        feedTask?.cancel()
        feedTask = nil
        feedOpen = false
    }

    func refresh() async {
        switch mode {
        case .browse:
            await loadDirectory(browsingPath)
        case .changes:
            feedTask?.cancel()
            feedTask = nil
            feedOpen = false
            await loadChanges()
        }
    }

    // MARK: - Browsing

    /// The current directory's children, directories first, filtered by search.
    var visibleEntries: [WorkspaceDirectoryEntry] {
        let entries = listing?.entries ?? []
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty
            ? entries
            : entries.filter { $0.name.lowercased().contains(query) }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var breadcrumbs: [String] {
        browsingPath.isEmpty ? [] : browsingPath.split(separator: "/").map(String.init)
    }

    var directoryPathLabel: String {
        browsingPath.isEmpty ? (scope.workspaceRoot ?? "/") : browsingPath
    }

    /// Loads one directory. `path` is a workspace path, empty for the root.
    ///
    /// The host refuses an empty `path` (`gateway/bad-request: path is required`),
    /// and `.` is what it accepts for the workspace root — verified against a live
    /// DSH, where `.`, `./`, and the absolute root all answer with the root
    /// listing while `/` is refused as outside the workspace.
    func loadDirectory(_ path: String) async {
        guard let client = store?.client else {
            phase = .failed("尚未连接")
            return
        }
        if listing == nil { phase = .loading }
        do {
            let raw = try await client.workspaceFiles(scopeId: scope.sessionId, path: path.isEmpty ? "." : path)
            guard let listing = WorkspaceDirectoryListing(json: raw) else {
                phase = .failed("主机返回的目录结构无法解析。")
                return
            }
            self.listing = listing
            // The host echoes the listed directory; trust it so a relative or
            // absolute request converges on the same breadcrumb.
            self.browsingPath = Self.relative(listing.path, root: scope.workspaceRoot)
            self.phase = .loaded
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// The host may answer with an absolute path; the browser works in
    /// workspace-relative paths so the breadcrumb stays short.
    private static func relative(_ path: String, root: String?) -> String {
        guard let root, !root.isEmpty, path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func open(_ entry: WorkspaceDirectoryEntry) async {
        guard entry.isDirectory else { return }
        await loadDirectory(entry.path(in: browsingPath))
    }

    func goUp() async {
        guard !browsingPath.isEmpty else { return }
        let parent = browsingPath.split(separator: "/").dropLast().joined(separator: "/")
        await loadDirectory(parent)
    }

    /// Jump to a breadcrumb component: 0 is the root, and the index is
    /// inclusive of that component.
    func jump(to index: Int) async {
        let parts = breadcrumbs
        let end = min(index + 1, parts.count)
        guard end > 0 else {
            await loadDirectory("")
            return
        }
        await loadDirectory(parts[0 ..< end].joined(separator: "/"))
    }

    // MARK: - Reading a file

    /// Opens `path` (workspace-relative) at its first page.
    func openFile(path: String) async {
        filePhase = .loading
        file = nil
        fileRefusedAsText = false
        await loadFilePage(path: path, offset: 1)
    }

    /// Fetches the next page of the open file.
    func loadMore() async {
        guard let file, !file.eof else { return }
        await loadFilePage(path: file.absolutePath, offset: file.offset + file.lines)
    }

    private func loadFilePage(path: String, offset: Int) async {
        guard let client = store?.client else {
            filePhase = .failed("尚未连接")
            return
        }
        do {
            let range: JSONValue = .object(["offset": .int(offset), "limit": .int(Self.pageLines)])
            let raw = try await client.workspaceFileRead(scopeId: scope.sessionId, path: path, range: range)
            guard let page = WorkspaceFileText(json: raw) else {
                filePhase = .failed("主机返回的文件内容无法解析。")
                return
            }
            if offset > 1, var existing = file, existing.absolutePath == page.absolutePath {
                // Append the next page, keeping the first page's absolute path.
                existing = WorkspaceFileText(
                    absolutePath: page.absolutePath,
                    version: page.version,
                    bytes: page.bytes,
                    offset: existing.offset,
                    text: existing.text + "\n" + page.text,
                    lines: existing.lines + page.lines,
                    eof: page.eof
                )
                file = existing
            } else {
                file = page
            }
            filePhase = .loaded
        } catch {
            if (error as? DSHRPCFailure)?.code == "workspace-file/not-text" {
                fileRefusedAsText = true
            }
            filePhase = .failed(Self.describe(error))
        }
    }

    // MARK: - Getting a file onto the phone

    /// What the browser opens a path with.
    static func kind(for path: String) -> WorkspaceFileKind { WorkspaceFileKind.of(path: path) }

    func transferPhase(for path: String) -> TransferPhase {
        transfers[Self.cacheKey(path, root: scope.workspaceRoot)] ?? .idle
    }

    /// The local copy, once the whole file is on the phone.
    func localCopy(for path: String) -> URL? {
        if case .ready(_, let url) = transferPhase(for: path) { return url }
        return nil
    }

    /// Current throughput, in MB/s, or nil before the first window lands.
    func transferSpeed(for path: String) -> Double? {
        transferRates[Self.cacheKey(path, root: scope.workspaceRoot)]
    }

    /// How long this transfer has been running, or took in total.
    func transferSeconds(for path: String) -> TimeInterval? {
        transferStarted[Self.cacheKey(path, root: scope.workspaceRoot)].map { -$0.timeIntervalSinceNow }
    }

    /// One window's worth of progress: bytes now, and how fast they arrived.
    private func noteProgress(key: String, received: Int, at now: Date = Date()) {
        if transferStarted[key] == nil { transferStarted[key] = now }
        guard let previous = lastSample[key] else {
            lastSample[key] = (now, received)
            return
        }
        let seconds = now.timeIntervalSince(previous.at)
        let bytes = received - previous.bytes
        // A sample shorter than a blink divides by ~0 and reports a spike.
        guard seconds > 0.15, bytes > 0 else { return }
        let instant = Double(bytes) / seconds / 1_048_576
        // Smoothed, because a single window's jitter is not a speed.
        let smoothed = transferRates[key].map { $0 * 0.6 + instant * 0.4 } ?? instant
        transferRates[key] = smoothed
        lastSample[key] = (now, received)
    }

    /// Fetches the whole file, once per version, resuming what is already here.
    ///
    /// Returns the local copy and publishes progress in `transfers` while it
    /// runs, so the view showing the download does not have to own the task —
    /// two screens looking at the same file share one transfer instead of
    /// pulling it twice. A finished cache hit costs a `stat` and nothing else.
    ///
    /// A link that drops mid-transfer is the normal case on a phone, not an
    /// exception: the attempt is retried a couple of times on its own, and when
    /// it still cannot finish the phase becomes `paused` with the bytes kept, so
    /// the next tap continues instead of starting over.
    @discardableResult
    func download(path: String) async -> URL? {
        let key = Self.cacheKey(path, root: scope.workspaceRoot)
        if let running = transferTasks[key] { return await running.value }
        guard let client = store?.client else {
            transfers[key] = .failed("尚未连接")
            return nil
        }

        transfers[key] = .running(received: transfers[key]?.receivedBytes ?? 0, total: nil)
        // A resumed download starts its clock over: the average of "half of it
        // yesterday plus the rest now" would be a lie.
        transferStarted[key] = Date()
        lastSample[key] = nil
        let scopeId = scope.sessionId
        let downloader = WorkspaceFileDownloader(client: client)
        let task = Task<URL?, Never> { [weak self] in
            var attempt = 0
            while true {
                do {
                    return try await self?.attemptDownload(
                        downloader: downloader, scopeId: scopeId, key: key, path: path
                    )
                } catch is CancellationError {
                    self?.pause(key: key, reason: nil)
                    return nil
                } catch {
                    // Two unasked-for attempts: a dropped socket reconnects in
                    // about a second, and the resume costs one window. After
                    // that the person decides — with the bytes still on disk.
                    if attempt < Self.automaticResumeAttempts, Self.isWorthResuming(error) {
                        attempt += 1
                        try? await Task.sleep(for: .milliseconds(1500 * attempt))
                        continue
                    }
                    if Self.isWorthResuming(error) {
                        self?.pause(key: key, reason: Self.describe(error))
                    } else {
                        self?.transfers[key] = .failed(Self.describe(error))
                    }
                    return nil
                }
            }
        }
        transferTasks[key] = task
        let url = await task.value
        transferTasks[key] = nil
        return url
    }

    /// One pass at the file, from whatever is already on disk.
    private func attemptDownload(
        downloader: WorkspaceFileDownloader,
        scopeId: String,
        key: String,
        path: String
    ) async throws -> URL? {
        let info = try await downloader.info(scopeId: scopeId, path: path)
        if let cached = WorkspaceFileCache.existing(
            scopeId: scopeId, path: key, version: info.version, bytes: info.bytes
        ) {
            transfers[key] = .ready(bytes: cached.bytes, url: cached.url)
            return cached.url
        }

        // The version is part of the directory name, so a file the agent has
        // rewritten since the last attempt lands somewhere else entirely and
        // yesterday's half-download can never be resumed as today's content.
        let offset = WorkspaceFileCache.partialBytes(
            scopeId: scopeId, path: key, version: info.version
        ) ?? 0
        transfers[key] = .running(received: offset, total: info.bytes)

        let fetched = try await downloader.fetch(
            scopeId: scopeId,
            path: path,
            to: WorkspaceFileCache.partial(scopeId: scopeId, path: key, version: info.version),
            from: offset
        ) { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.interruptForAutomationIfAsked(key: key, received: progress.received)
                // Only ever updates a running transfer: a paused one must not be
                // dragged back to life by a late window.
                guard case .running = self.transfers[key] else { return }
                self.transfers[key] = .running(received: progress.received, total: progress.total)
                self.noteProgress(key: key, received: progress.received)
            }
        }

        let complete = try WorkspaceFileCache.publish(
            scopeId: scopeId, path: key, version: info.version
        )
        // The average the person actually experienced, frozen for the ready line.
        if let started = transferStarted[key], fetched.bytes > 0 {
            let seconds = max(0.001, Date().timeIntervalSince(started))
            transferRates[key] = Double(fetched.bytes) / seconds / 1_048_576
        }
        WorkspaceFileCache.trim()
        transfers[key] = .ready(bytes: fetched.bytes, url: complete)
        return complete
    }

    /// Stops a transfer in flight, keeping the bytes for the next attempt.
    func pauseDownload(path: String) {
        cancelTransferTask(path: path)
        pause(key: Self.cacheKey(path, root: scope.workspaceRoot), reason: nil)
    }

    /// Throws away a partial download, for the "give up on this file" action.
    func discardDownload(path: String) async {
        let key = Self.cacheKey(path, root: scope.workspaceRoot)
        cancelTransferTask(path: path)
        if let client = store?.client {
            let downloader = WorkspaceFileDownloader(client: client)
            if let info = try? await downloader.info(scopeId: scope.sessionId, path: path) {
                WorkspaceFileCache.discardPartial(
                    scopeId: scope.sessionId, path: key, version: info.version
                )
            }
        }
        transfers[key] = .idle
    }

    private func cancelTransferTask(path: String) {
        let key = Self.cacheKey(path, root: scope.workspaceRoot)
        transferTasks[key]?.cancel()
        transferTasks[key] = nil
    }

    /// Moves a transfer to `paused`, keeping what arrived for the next attempt.
    ///
    /// The byte count is the last one reported rather than a fresh `stat` of the
    /// file: the difference is at most one window, and that window is simply
    /// asked for again.
    private func pause(key: String, reason: String?) {
        lastSample[key] = nil
        let phase = transfers[key]
        transfers[key] = .paused(
            bytes: phase?.receivedBytes ?? 0,
            total: phase?.totalBytes,
            reason: reason
        )
    }

    /// How many times a dropped transfer is resumed without asking.
    private static let automaticResumeAttempts = 2

    /// A run can ask for the first attempt to be cut short.
    ///
    /// Resuming is the one behaviour that cannot be tested by waiting: a real
    /// interruption needs the relay to drop the device mid-file, which no case
    /// can schedule. `-DSHInterruptDownload <bytes>` stops the first attempt at
    /// that many bytes, so the next step can press 继续 and prove the bytes
    /// already on disk were kept.
    private static var automationInterruptBytes: Int? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHInterruptDownload"),
              index + 1 < arguments.count,
              let bytes = Int(arguments[index + 1]), bytes > 0
        else { return nil }
        return bytes
        #else
        return nil
        #endif
    }

    private var didInterruptForAutomation = false

    private func interruptForAutomationIfAsked(key: String, received: Int) {
        guard let limit = Self.automationInterruptBytes,
              !didInterruptForAutomation,
              received >= limit
        else { return }
        didInterruptForAutomation = true
        transferTasks[key]?.cancel()
    }

    /// Whether the bytes on disk are worth continuing from.
    private static func isWorthResuming(_ error: any Error) -> Bool {
        if let failure = error as? WorkspaceFileDownloader.Failure { return failure.isResumable }
        if let failure = error as? DSHRPCFailure {
            switch failure.code {
            case "workspace-file/not-found", "workspace-file/outside-workspace",
                 "workspace-file/not-regular-file", "workspace-file/not-directory",
                 "workspace-file/unknown-workspace", "gateway/lookup-not-found":
                return false
            default:
                return true
            }
        }
        return true
    }

    /// One key per file: the change list names a file absolutely and the browser
    /// names it relative to the same root, and both are the same document.
    private static func cacheKey(_ path: String, root: String?) -> String {
        relative(path, root: root)
    }

    var fileTitle: String {
        guard let file else { return "" }
        if let root = scope.workspaceRoot, file.absolutePath.hasPrefix(root) {
            return String(file.absolutePath.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return (file.absolutePath as NSString).lastPathComponent
    }

    // MARK: - Change feed

    /// The observed change set, filtered by the search field.
    var visibleChanges: [WorkspaceChange] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return changes }
        return changes.filter { scope.displayPath($0.absolutePath).lowercased().contains(query) }
    }

    /// Loads the change set.
    ///
    /// `workspaceFiles/changes` is declared as a **stream** Remote, so the host
    /// serves it on the mux carrier and refuses a unary call with
    /// `gateway/signature-invalid`. The kit models it as a stream for exactly
    /// that reason; this opens it and feeds the tolerant ingest.
    func loadChanges() async {
        guard let client = store?.client else {
            changesPhase = .failed("尚未连接")
            return
        }
        if changes.isEmpty { changesPhase = .loading }
        openFeed(client: client)
    }

    private func openFeed(client: DSHClient) {
        guard !feedOpen else {
            if changesPhase == .loading { changesPhase = .loaded }
            return
        }
        feedOpen = true
        feedTask?.cancel()
        feedTask = Task { [weak self] in
            guard let self else { return }
            let stream = await client.workspaceChanges(scopeId: self.scope.sessionId)
            do {
                for try await value in stream {
                    guard !Task.isCancelled else { return }
                    self.ingestFrame(value)
                    if self.changesPhase == .loading { self.changesPhase = .loaded }
                }
                if self.changesPhase == .loading { self.changesPhase = .loaded }
            } catch {
                if self.changes.isEmpty {
                    self.changesPhase = .failed(Self.describe(error))
                }
            }
        }
    }

    /// Ingests one unary answer. Returns whether it carried usable content.
    @discardableResult
    private func ingest(_ raw: JSONValue) -> Bool {
        var consumed = false
        // A stream capture shape: {"frames":[…],"errors":[],"opened":true}
        if let frames = raw["frames"]?.arrayValue {
            for frame in frames {
                ingestFrame(frame["value"] ?? frame)
                consumed = true
            }
        }
        if let entries = WorkspaceChangeSet(json: raw), !entries.entries.isEmpty {
            changeSet = entries
            consumed = true
        }
        if raw["kind"] != nil {
            ingestFrame(raw)
            consumed = true
        }
        return consumed
    }

    private func ingestFrame(_ json: JSONValue) {
        switch WorkspaceChangeFrame(json: json) {
        case .ready:
            if changesPhase == .loading { changesPhase = .loaded }
        case .change(let change):
            merge(change)
            changesPhase = .loaded
        case .other:
            // A frame this build does not model: keep the feed alive.
            if changesPhase == .loading { changesPhase = .loaded }
        }
    }

    /// The feed reports observations, not deltas, so the latest observation of a
    /// path wins.
    private func merge(_ change: WorkspaceChange) {
        if let index = changes.firstIndex(where: { $0.absolutePath == change.absolutePath }) {
            changes[index] = change
        } else {
            changes.append(change)
        }
        changes.sort { $0.absolutePath.localizedStandardCompare($1.absolutePath) == .orderedAscending }
    }

    // MARK: - Failure copy

    /// The desktop client's wording for each workspace-file failure code.
    static func describe(_ error: any Error) -> String {
        guard let failure = error as? DSHRPCFailure else {
            return ConnectionStore.describe(error)
        }
        switch failure.code {
        case "workspace-file/not-found":
            if let path = failure.details["path"]?.stringValue {
                return "这个路径不在了：\(path)"
            }
            return "这个路径不在了。可能已被移动或删除。"
        case "workspace-file/outside-workspace":
            return "这个目录在工作区之外，客户端不会读取它。"
        case "workspace-file/not-directory":
            return "这不是一个目录。"
        case "workspace-file/not-regular-file":
            return "这不是文件或目录，没法打开。"
        case "workspace-file/not-text":
            return "这不是一个 UTF-8 文本文件，无法在这里预览。"
        case "workspace-file/too-large":
            return "内容超过主机允许的单次读取上限。"
        case "workspace-file/unknown-workspace", "gateway/lookup-not-found":
            return "主机无法解析这个会话的工作区。"
        default:
            return failure.message
        }
    }
}

/// Arguments for the `workspaceFiles/changes` stream Remote.
///
/// The kit types `workspaceChanges(_:)` as a unary call, so this feature opens
/// the stream itself through the public carrier; the wire field is the scope id.
private struct WorkspaceChangeFeedArgs: Encodable, Sendable {
    let workspaceFileScopeId: String
}

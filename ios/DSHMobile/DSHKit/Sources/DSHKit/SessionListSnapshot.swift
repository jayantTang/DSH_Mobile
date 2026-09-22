import Foundation

/// What the session list looked like the last time the phone could reach its
/// computer.
///
/// The phone keeps no database: the list is fetched on every launch, and until
/// that fetch returns the screen has nothing to draw — a cold start, or a launch
/// with a flaky network, showed an empty list and a spinner. Keeping the last
/// answer on disk turns that into "show the rows we already had, then reconcile
/// them with what the host says now", which is what makes reopening the app feel
/// like reopening a chat app rather than loading a page.
///
/// Scope: this is metadata only (titles, times, running flags, usage numbers) —
/// no transcript content. Transcript caching is a separate decision.
public struct SessionListSnapshot: Codable, Sendable {
    /// 结构版本：字段变了就加一，旧文件据此作废。
    public static let schemaVersion = 1
    public let schema: Int
    /// 这份列表属于哪台电脑（agent id，未登记时是 profile 的 UUID）。
    public let scope: String
    public let savedAt: Date
    public let items: [SessionSummary]
    public let workspaces: [Workspace]
    public let archivedSessionIds: [String]

    /// What this snapshot's *content* is, ignoring when it was saved.
    ///
    /// The list is refetched every time the host says something changed, and the
    /// answer is almost always identical — writing a fresh 150 KB file each time
    /// is pure disk churn during heavy work. Comparing fingerprints lets the
    /// caller skip the write when nothing moved.
    public var contentFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items {
            hasher.combine(item.sessionId)
            hasher.combine(item.updatedAt)
            hasher.combine(item.running)
            hasher.combine(item.blank)
        }
        hasher.combine(workspaces.count)
        for workspace in workspaces {
            hasher.combine(workspace.workspaceId)
            hasher.combine(workspace.sessionIds)
        }
        hasher.combine(archivedSessionIds.count)
        return hasher.finalize()
    }

    public init(
        scope: String,
        savedAt: Date,
        items: [SessionSummary],
        workspaces: [Workspace],
        archivedSessionIds: [String],
        schema: Int = SessionListSnapshot.schemaVersion
    ) {
        self.schema = schema
        self.scope = scope
        self.savedAt = savedAt
        self.items = items
        self.workspaces = workspaces
        self.archivedSessionIds = archivedSessionIds
    }
}

/// Reads and writes that snapshot under `Caches`.
///
/// `Caches` on purpose, like the workspace file cache: the computer still has the
/// truth, iOS may reclaim this under pressure, and it never goes into a backup.
/// A snapshot older than ``maxAge`` is treated as absent *and deleted* — the
/// rolling window is what keeps an old snapshot from being shown as if it were
/// today's work.
public struct SessionListSnapshotStore {

    /// How long a snapshot may still be shown.
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private let directory: URL
    private let now: () -> Date

    /// - Parameters:
    ///   - directory: overridable so tests get a temporary directory; the app
    ///     uses `Caches/session-list-<scope>.json`.
    ///   - now: injectable clock, for the same reason.
    public init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = base
        self.now = now
    }

    /// 一台电脑一份。以前是全局单文件，换电脑之后冷启动会把上一台的列表当成
    /// "上次数据"画出来——两台电脑的会话 id 本来就可能撞（fork/clone）。
    private func url(scope: String) -> URL {
        let name = "session-list-\(SessionTranscriptCache.slug(scope)).json"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// This computer's snapshot, or `nil` when there is none, it is unreadable,
    /// it is stale, or it belongs to a different computer.
    public func load(scope: String) -> SessionListSnapshot? {
        let url = url(scope: scope)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(SessionListSnapshot.self, from: data) else {
            // A snapshot we cannot read is worse than none: it would be shown
            // forever. Drop it and let the next refresh write a fresh one.
            clear(scope: scope)
            return nil
        }
        guard snapshot.schema == SessionListSnapshot.schemaVersion,
              snapshot.scope == scope,
              now().timeIntervalSince(snapshot.savedAt) <= Self.maxAge
        else {
            clear(scope: scope)
            return nil
        }
        return snapshot
    }

    /// Writes atomically: a half-written snapshot must never be readable.
    public func save(_ snapshot: SessionListSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = url(scope: snapshot.scope)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Forgets one computer's snapshot — the settings switch and corrupt files.
    public func clear(scope: String) {
        try? FileManager.default.removeItem(at: url(scope: scope))
    }

    /// Forgets every computer's snapshot — including the unscoped
    /// `session-list.json` an earlier build wrote, which nothing reads any more.
    public func clearAll() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("session-list-") && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("session-list.json", isDirectory: false))
    }
}

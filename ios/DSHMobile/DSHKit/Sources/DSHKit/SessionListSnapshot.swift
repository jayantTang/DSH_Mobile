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
        savedAt: Date,
        items: [SessionSummary],
        workspaces: [Workspace],
        archivedSessionIds: [String],
        schema: Int = SessionListSnapshot.schemaVersion
    ) {
        self.schema = schema
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

    private let url: URL
    private let now: () -> Date

    /// - Parameters:
    ///   - directory: overridable so tests get a temporary directory; the app
    ///     uses `Caches/session-list.json`.
    ///   - now: injectable clock, for the same reason.
    public init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.url = base.appendingPathComponent("session-list.json", isDirectory: false)
        self.now = now
    }

    /// The snapshot, or `nil` when there is none, it is unreadable, or it is stale.
    public func load() -> SessionListSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(SessionListSnapshot.self, from: data) else {
            // A snapshot we cannot read is worse than none: it would be shown
            // forever. Drop it and let the next refresh write a fresh one.
            clear()
            return nil
        }
        guard snapshot.schema == SessionListSnapshot.schemaVersion else {
            clear()
            return nil
        }
        guard now().timeIntervalSince(snapshot.savedAt) <= Self.maxAge else {
            clear()
            return nil
        }
        return snapshot
    }

    /// Writes atomically: a half-written snapshot must never be readable.
    public func save(_ snapshot: SessionListSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Forgets it now — used by the settings switch and when a snapshot is corrupt.
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

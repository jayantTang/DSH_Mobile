import Foundation

/// The tail of one session's transcript, as it was the last time this phone saw it.
///
/// Why the raw records and not the rendered rows: a snapshot of the tail is
/// exactly what `session/follow` hands back on open, and the app already knows
/// how to fold that into a transcript it has content for (`ChatTimeline.merge`).
/// Storing the same thing means a cold start can build the same screen the
/// follow snapshot would have built — without inventing a second representation
/// that could drift from the wire model.
public struct SessionTranscriptSnapshot: Codable, Sendable {
    public let savedAt: Date
    public let records: [SessionRecord]
    public let oldestSeq: Int?
    public let throughSeq: Int
    public let hasOlder: Bool

    public init(
        savedAt: Date,
        records: [SessionRecord],
        oldestSeq: Int?,
        throughSeq: Int,
        hasOlder: Bool
    ) {
        self.savedAt = savedAt
        self.records = records
        self.oldestSeq = oldestSeq
        self.throughSeq = throughSeq
        self.hasOlder = hasOlder
    }
}

/// Keeps those tails on disk, one file per (computer, session).
///
/// Scope is part of the path on purpose: two computers can both have a session
/// called `session-1234…`, and showing one's transcript under the other's name
/// would be worse than showing nothing. Files live in `Caches` — plaintext, not
/// backed up, reclaimable by iOS — and are subject to both a rolling window and
/// a byte budget, because a chat client that caches every session forever is a
/// chat client that eats the phone.
public struct SessionTranscriptCache {

    /// How long a tail may be shown after it was written.
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// How many records of the tail are kept. The live view opens with a 60-record
    /// snapshot, so 200 covers "what was on screen" plus a screen of history.
    public static let maxRecords = 200

    /// What all transcripts together may occupy before the oldest files go.
    public static let budgetBytes = 40 * 1024 * 1024

    private let root: URL
    private let now: () -> Date
    private let fileManager: FileManager
    private let budgetBytes: Int

    public init(
        root: URL? = nil,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        budgetBytes: Int = SessionTranscriptCache.budgetBytes
    ) {
        let base = root ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.root = base.appendingPathComponent("transcripts", isDirectory: true)
        self.now = now
        self.fileManager = fileManager
        self.budgetBytes = budgetBytes
    }

    /// Where one session's tail lives. Ids are host-chosen, so they are reduced
    /// to characters that cannot escape the directory or collide with a path.
    private func url(scope: String, sessionId: String) -> URL {
        root
            .appendingPathComponent(Self.slug(scope), isDirectory: true)
            .appendingPathComponent("\(Self.slug(sessionId)).json", isDirectory: false)
    }

    public static func slug(_ value: String) -> String {
        let allowed = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "_"
        }
        let text = String(allowed)
        return text.isEmpty ? "unknown" : String(text.prefix(120))
    }

    // MARK: - Reading and writing

    /// The stored tail, or `nil` when there is none, it is stale, or it is corrupt.
    public func load(scope: String, sessionId: String) -> SessionTranscriptSnapshot? {
        let file = url(scope: scope, sessionId: sessionId)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(SessionTranscriptSnapshot.self, from: data) else {
            // Unreadable is worse than absent: it would be retried on every open.
            try? fileManager.removeItem(at: file)
            return nil
        }
        guard now().timeIntervalSince(snapshot.savedAt) <= Self.maxAge else {
            try? fileManager.removeItem(at: file)
            return nil
        }
        return snapshot
    }

    /// Stores the tail, keeping only the newest ``maxRecords`` records.
    public func save(_ snapshot: SessionTranscriptSnapshot, scope: String, sessionId: String) {
        var trimmed = snapshot
        if snapshot.records.count > Self.maxRecords {
            trimmed = SessionTranscriptSnapshot(
                savedAt: snapshot.savedAt,
                records: Array(snapshot.records.suffix(Self.maxRecords)),
                oldestSeq: snapshot.records.suffix(Self.maxRecords).first?.event.seq,
                throughSeq: snapshot.throughSeq,
                hasOlder: true
            )
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        let file = url(scope: scope, sessionId: sessionId)
        try? fileManager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public func clear(scope: String, sessionId: String) {
        try? fileManager.removeItem(at: url(scope: scope, sessionId: sessionId))
    }

    /// Forgets every computer's transcripts (the settings switch).
    public func clearAll() {
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Housekeeping

    /// Drops what is too old and what no longer fits the budget.
    ///
    /// Oldest-first by modification time: the sessions someone actually uses are
    /// the ones that get rewritten, so they are the ones that survive a pruning.
    @discardableResult
    public func prune() -> Int {
        var files: [(url: URL, size: Int, modified: Date)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return 0
        }
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            files.append((
                url: file,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast
            ))
        }

        var removed = 0
        let deadline = now().addingTimeInterval(-Self.maxAge)
        for file in files where file.modified < deadline {
            try? fileManager.removeItem(at: file.url)
            removed += 1
        }

        var survivors = files
            .filter { $0.modified >= deadline }
            .sorted { $0.modified > $1.modified }
        var total = survivors.reduce(0) { $0 + $1.size }
        while total > budgetBytes, let oldest = survivors.popLast() {
            try? fileManager.removeItem(at: oldest.url)
            total -= oldest.size
            removed += 1
        }
        return removed
    }

    /// What the cache currently occupies, for the settings screen.
    public func sizeOnDisk() -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }
}

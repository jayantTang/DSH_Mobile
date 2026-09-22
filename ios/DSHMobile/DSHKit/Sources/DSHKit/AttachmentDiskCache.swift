import Foundation

/// Pictures the phone has already downloaded, kept on disk.
///
/// The in-memory buckets make scrolling back through a conversation cheap, but
/// they die with the process — so a cold start re-downloads every picture, and
/// on a phone that is both slow and (over a relay) expensive. This stores the
/// bytes instead: same `Caches` rules as the transcript cache (plaintext, not
/// backed up, reclaimable), keyed by computer and attachment id so two hosts
/// cannot hand each other the wrong picture.
public struct AttachmentDiskCache {

    /// How long a downloaded picture may be reused.
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// What all pictures together may occupy before the oldest go.
    public static let budgetBytes = 100 * 1024 * 1024

    private let root: URL
    private let now: () -> Date
    private let fileManager: FileManager
    private let budgetBytes: Int

    public init(
        root: URL? = nil,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        budgetBytes: Int = AttachmentDiskCache.budgetBytes
    ) {
        let base = root ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.root = base.appendingPathComponent("attachments", isDirectory: true)
        self.now = now
        self.fileManager = fileManager
        self.budgetBytes = budgetBytes
    }

    private func url(scope: String, attachmentId: String) -> URL {
        root
            .appendingPathComponent(SessionTranscriptCache.slug(scope), isDirectory: true)
            .appendingPathComponent(SessionTranscriptCache.slug(attachmentId), isDirectory: false)
    }

    /// The stored bytes, or `nil` when there are none, they are stale, or unreadable.
    public func load(scope: String, attachmentId: String) -> Data? {
        let file = url(scope: scope, attachmentId: attachmentId)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        guard now().timeIntervalSince(modified) <= Self.maxAge else {
            try? fileManager.removeItem(at: file)
            return nil
        }
        return data
    }

    public func save(_ data: Data, scope: String, attachmentId: String) {
        guard !data.isEmpty else { return }
        let file = url(scope: scope, attachmentId: attachmentId)
        try? fileManager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public func clearAll() {
        try? fileManager.removeItem(at: root)
    }

    /// Drops stale pictures and then the oldest ones until the budget fits.
    @discardableResult
    public func prune() -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return 0
        }
        var files: [(url: URL, size: Int, modified: Date)] = []
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
}

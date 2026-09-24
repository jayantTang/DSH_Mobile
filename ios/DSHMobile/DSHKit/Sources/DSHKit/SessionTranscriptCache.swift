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
    /// 结构版本：字段/语义变了就加一，旧文件据此作废（而不是解出半个东西）。
    public static let schemaVersion = 1
    public let schema: Int
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
        hasOlder: Bool,
        schema: Int = SessionTranscriptSnapshot.schemaVersion
    ) {
        self.schema = schema
        self.savedAt = savedAt
        self.records = records
        self.oldestSeq = oldestSeq
        self.throughSeq = throughSeq
        self.hasOlder = hasOlder
    }
}

/// 「搜索时往前读到的那段更早的历史」，同样按会话落盘。
///
/// 与尾部快照分开存：尾部是"打开会话就显示"的 200 条，这段是读者为了搜索往上翻出来的
/// 更早记录（可以到几千条）。分开的理由是两者的淘汰节奏完全不同——尾部每次会话都被
/// 重写，这段只在读者往下翻的时候长大。
///
/// 为什么值得落盘：不落的话，每次冷启动/换会话再打开搜索面板，都要把同样那几十页
/// 从 host 重新读一遍（长会话一页 ~300 条），既慢又费流量。存下来之后，
/// "本地有就直接用，越过本地范围才走网络"。
public struct SessionOlderSnapshot: Codable, Sendable {
    public static let schemaVersion = 1
    public let schema: Int
    public let savedAt: Date
    /// 由旧到新；总是紧挨着尾部窗口的下界（`oldestSeq` 是这段里最老的一条）。
    public let records: [SessionRecord]
    public let oldestSeq: Int?
    /// 这段最老的一条之前，host 那边还有没有更早的。
    public let hasOlder: Bool

    public init(savedAt: Date, records: [SessionRecord], oldestSeq: Int?, hasOlder: Bool,
                schema: Int = SessionOlderSnapshot.schemaVersion) {
        self.schema = schema
        self.savedAt = savedAt
        self.records = records
        self.oldestSeq = oldestSeq
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

    /// 每个会话最多留多少条"搜索往前读"的记录。按 ~300 条/页算，3000 条约等于
    /// 十页；再往前的就不留了（那是磁盘预算问题，不是功能问题——越过本地范围的
    /// 部分照样能现取）。淘汰时丢**最老**的那头，保住紧挨窗口的这一段连续区间。
    public static let maxOlderRecords = 3000

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

    /// 搜索用的更早历史存哪儿：同一个 scope 目录下的另一个文件。
    ///
    /// 放同一个目录是故意的：`prune()`（30 天 + 40MB 预算）与 `sizeOnDisk()`
    /// （设置页的"占用多少"）都在目录上走，多一种文件不用再写第二套清理逻辑。
    private func olderURL(scope: String, sessionId: String) -> URL {
        root
            .appendingPathComponent(Self.slug(scope), isDirectory: true)
            .appendingPathComponent("\(Self.slug(sessionId)).older.json", isDirectory: false)
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
        guard snapshot.schema == SessionTranscriptSnapshot.schemaVersion else {
            // 旧结构：宁可重下一遍，也不要按新语义解释老字段。
            try? fileManager.removeItem(at: file)
            return nil
        }
        guard now().timeIntervalSince(snapshot.savedAt) <= Self.maxAge else {
            try? fileManager.removeItem(at: file)
            return nil
        }
        // 读侧同样按记录推导 `oldestSeq`：旧版本可能写过"游标比记录老"的一对
        // （翻过旧页之后），照着它往前翻会在中间留一段永远补不上的空白。
        // 让不变量在读出时就成立，而不是指望下一次写盘修好。
        return SessionTranscriptSnapshot(
            savedAt: snapshot.savedAt,
            records: snapshot.records,
            oldestSeq: snapshot.records.first?.event.seq,
            throughSeq: snapshot.throughSeq,
            hasOlder: snapshot.hasOlder,
            schema: snapshot.schema
        )
    }

    /// Stores the tail, keeping only the newest ``maxRecords`` records.
    ///
    /// `oldestSeq` is **derived from the records that are actually written**, not
    /// taken from the caller. A live session's "oldest row" moves further back
    /// every time the reader pages up, while the tail this file keeps does not —
    /// persisting the live value would tell the next cold start to page older from
    /// a seq the file no longer holds, and the transcript would come back with a
    /// gap between what was paged in and what was stored.
    public func save(_ snapshot: SessionTranscriptSnapshot, scope: String, sessionId: String) {
        let kept = snapshot.records.count > Self.maxRecords
            ? Array(snapshot.records.suffix(Self.maxRecords))
            : snapshot.records
        let trimmed = SessionTranscriptSnapshot(
            savedAt: snapshot.savedAt,
            records: kept,
            // 与本文件里真正存下的记录对齐（见上面的说明）。
            oldestSeq: kept.first?.event.seq,
            throughSeq: snapshot.throughSeq,
            hasOlder: snapshot.hasOlder || kept.count < snapshot.records.count
        )
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        let file = url(scope: scope, sessionId: sessionId)
        try? fileManager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public func clear(scope: String, sessionId: String) {
        try? fileManager.removeItem(at: url(scope: scope, sessionId: sessionId))
        try? fileManager.removeItem(at: olderURL(scope: scope, sessionId: sessionId))
    }

    // MARK: - 搜索用的更早历史

    /// 读回那段更早的历史；没有、过期或结构不对都返回 nil（并把坏文件删掉）。
    public func loadOlder(scope: String, sessionId: String) -> SessionOlderSnapshot? {
        let file = olderURL(scope: scope, sessionId: sessionId)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(SessionOlderSnapshot.self, from: data),
              snapshot.schema == SessionOlderSnapshot.schemaVersion,
              now().timeIntervalSince(snapshot.savedAt) <= Self.maxAge
        else {
            try? fileManager.removeItem(at: file)
            return nil
        }
        guard !snapshot.records.isEmpty else { return nil }
        // `oldestSeq` 一律按真正存下的记录推，不信调用方写进去的值（与尾部快照同一条规矩）。
        return SessionOlderSnapshot(
            savedAt: snapshot.savedAt,
            records: snapshot.records,
            oldestSeq: snapshot.records.first?.event.seq,
            hasOlder: snapshot.hasOlder
        )
    }

    /// 写入那段更早的历史，只留最新的 ``maxOlderRecords`` 条。
    public func saveOlder(records: [SessionRecord], hasOlder: Bool,
                          scope: String, sessionId: String) {
        guard !records.isEmpty else { return }
        let kept = records.count > Self.maxOlderRecords
            ? Array(records.suffix(Self.maxOlderRecords))
            : records
        let snapshot = SessionOlderSnapshot(
            savedAt: now(),
            records: kept,
            oldestSeq: kept.first?.event.seq,
            hasOlder: hasOlder
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let file = olderURL(scope: scope, sessionId: sessionId)
        try? fileManager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
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

        // 刚写出来的文件（10 秒内）不参与裁剪：prune 在启动时后台跑，
        // 别跟"打开会话时正在写的那份"撞上。
        let settled = now().addingTimeInterval(-10)

        var removed = 0
        let deadline = now().addingTimeInterval(-Self.maxAge)
        for file in files where file.modified < deadline {
            try? fileManager.removeItem(at: file.url)
            removed += 1
        }

        var survivors = files
            .filter { $0.modified >= deadline && $0.modified <= settled }
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

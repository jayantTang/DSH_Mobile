import Foundation

/// Where a file fetched from the computer lives on the phone.
///
/// `Caches` on purpose: everything here is a copy of something the computer
/// still has, so iOS is welcome to reclaim it under pressure, and it is never
/// backed up. The directory is keyed by *version* as well as by path, which is
/// what makes the cache self-invalidating: a file the agent rewrote has a new
/// version, lands in a new directory, and the copy from yesterday can never be
/// shown as today's content.
///
/// `#if DEBUG`-only directory override: the batch-4 unit tests for the resume
/// path run on **macOS**, where `Caches` resolves to the developer's own
/// `~/Library/Caches` — writing fixtures into the real one would be the same
/// class of mistake as pointing a test at the real `~/.dsh`. The override is
/// compiled out of every shipping configuration, so the product path cannot be
/// moved by an environment variable.
enum WorkspaceFileCache {

    /// What the whole cache may occupy before the oldest files are dropped.
    ///
    /// There is no per-file cap — fetching a 500 MB file is a legitimate thing to
    /// ask for — so the bound is on the cache instead, which is the part that
    /// would otherwise grow without anyone noticing.
    static let budgetBytes = 256 * 1024 * 1024

    private static var root: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["DSH_WORKSPACE_CACHE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspace-files", isDirectory: true)
    }

    /// Where one version of one file belongs, whether or not it is there yet.
    static func destination(scopeId: String, path: String, version: String) -> URL {
        directory(scopeId: scopeId, path: path, version: version)
            .appendingPathComponent(name(for: path))
    }

    /// Where a download lands before it is the file.
    ///
    /// A half-arrived file is not the file: it gets its own name so nothing can
    /// open it as if it were complete. What it is **not** any more is a resume
    /// point — since P-13c the system owns the partially-fetched bytes as opaque
    /// `resumeData`, and this file is replaced outright on each attempt rather
    /// than appended to. The name is kept because "complete is a rename" is still
    /// what makes publishing atomic.
    static func partial(scopeId: String, path: String, version: String) -> URL {
        let complete = destination(scopeId: scopeId, path: path, version: version)
        return complete.appendingPathExtension("part")
    }

    /// Publishes a finished partial as the file itself.
    ///
    /// The rename is what makes "complete" atomic: a `.part` is never mistaken
    /// for a whole document, however the process dies.
    static func publish(scopeId: String, path: String, version: String) throws -> URL {
        let partial = partial(scopeId: scopeId, path: path, version: version)
        let complete = destination(scopeId: scopeId, path: path, version: version)
        let manager = FileManager.default
        try? manager.removeItem(at: complete)
        try manager.moveItem(at: partial, to: complete)
        return complete
    }

    /// Throws away one file's copy of one version, together with its partial.
    ///
    /// Called when the host reports a newer version: the old copy is not the
    /// file any more, and leaving a superseded video behind costs tens of
    /// megabytes until the cache trims itself.
    static func discard(scopeId: String, path: String, version: String) {
        try? FileManager.default.removeItem(
            at: directory(scopeId: scopeId, path: path, version: version)
        )
    }

    /// Throws away a partial, for the "give up on this download" action.
    static func discardPartial(scopeId: String, path: String, version: String) {
        try? FileManager.default.removeItem(at: partial(scopeId: scopeId, path: path, version: version))
    }

    private static func directory(scopeId: String, path: String, version: String) -> URL {
        root.appendingPathComponent("\(digest("\(scopeId)~\(path)"))-\(digest(version))", isDirectory: true)
    }

    /// The cached copy of exactly this version, when it is complete.
    ///
    /// A file whose size disagrees with what the host reports is not a cache hit
    /// — it is debris from an interrupted write — so it is dropped here rather
    /// than opened as if it were the document.
    static func existing(
        scopeId: String,
        path: String,
        version: String,
        bytes: Int?
    ) -> (url: URL, bytes: Int)? {
        let url = destination(scopeId: scopeId, path: path, version: version)
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int
        else { return nil }
        if let bytes, size != bytes {
            try? manager.removeItem(at: url)
            return nil
        }
        return (url, size)
    }

    /// A file path inside the workspace, reduced to a safe last component.
    static func name(for path: String) -> String {
        let base = (path as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(120))
    }

    /// Drops the oldest files until the cache is back inside its budget.
    ///
    /// Called after a download rather than on a timer: the only moment the cache
    /// grows is the moment it is worth checking.
    ///
    /// **`.part` files are skipped.** A `.part` is a download someone is in the
    /// middle of — possibly a second file the browser is fetching at the same
    /// time as the one that just finished. Trimming it deleted a live prefix, and
    /// the next `publish()` then failed because the `.part` it was about to
    /// rename was gone. Left out of both the total and the delete list, so a
    /// half-arrived file is never the reason a complete one survives either.
    static func trim(budget: Int = budgetBytes) {
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        var files: [(url: URL, size: Int, modified: Date)] = []
        for directory in directories {
            let contents = (try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? []
            for file in contents where file.pathExtension != "part" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append((file, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
            }
        }

        var total = files.reduce(0) { $0 + $1.size }
        guard total > budget else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > budget else { break }
            try? manager.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// Empties the cache, for the settings screen's "clear" affordance.
    static func clear() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A stable fold of a string into hex.
    ///
    /// Deliberately not `hashValue`: that one changes between launches, which
    /// would orphan yesterday's cache directory on every start.
    private static func digest(_ value: String) -> String {
        let folded = value.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return String(folded, radix: 16)
    }
}

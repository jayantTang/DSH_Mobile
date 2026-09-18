import Foundation

/// Where a file fetched from the computer lives on the phone.
///
/// `Caches` on purpose: everything here is a copy of something the computer
/// still has, so iOS is welcome to reclaim it under pressure, and it is never
/// backed up. The directory is keyed by *version* as well as by path, which is
/// what makes the cache self-invalidating: a file the agent rewrote has a new
/// version, lands in a new directory, and the copy from yesterday can never be
/// shown as today's content.
enum WorkspaceFileCache {

    /// What the whole cache may occupy before the oldest files are dropped.
    ///
    /// There is no per-file cap — fetching a 500 MB file is a legitimate thing to
    /// ask for — so the bound is on the cache instead, which is the part that
    /// would otherwise grow without anyone noticing.
    static let budgetBytes = 256 * 1024 * 1024

    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspace-files", isDirectory: true)
    }

    /// Where one version of one file belongs, whether or not it is there yet.
    static func destination(scopeId: String, path: String, version: String) -> URL {
        root
            .appendingPathComponent("\(digest("\(scopeId)~\(path)"))-\(digest(version))", isDirectory: true)
            .appendingPathComponent(name(for: path))
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
            for file in contents {
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

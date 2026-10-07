import Foundation

/// The app's own staging area for files on their way out.
///
/// **Not `tmp/`.** A background upload needs its source file to still be there
/// when the system reads the bytes, which can be long after the app was
/// suspended — and iOS makes no promise that anything under `tmp/` survives
/// (it is, by definition, "data that does not need to persist"). The staging
/// area therefore lives under `Caches/`, the same choice `WorkspaceFileCache`
/// makes and for the same reason.
///
/// The second job is hygiene. Until this type existed nothing ever deleted a
/// staged copy: every send left its bytes behind forever, which is a leak that
/// only grows. Now a send deletes its own copy when it is done with it (see
/// `remove(url:)`), and a launch sweeps whatever an interrupted send left
/// behind (`sweep(olderThan:)`).
public enum OutgoingFiles {

    /// How old a leftover copy has to be before a launch sweeps it.
    ///
    /// Twenty-four hours, not "anything not mine": the sweep runs while a
    /// transfer from a previous launch may still be a live task the system is
    /// about to resume, and a day is comfortably longer than any of those takes.
    public static let sweepAge: TimeInterval = 24 * 60 * 60

    /// The root of the staging area: `Caches/outgoing-files`.
    public static var root: URL {
        #if DEBUG
        // 单测跑在 macOS 上，`Caches` 会落到开发者真实的 `~/Library/Caches`；
        // 与 `WorkspaceFileCache` 同样的隔离钩子，Release 下编译掉。
        if let override = ProcessInfo.processInfo.environment["DSH_OUTGOING_FILES_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("outgoing-files", isDirectory: true)
    }

    /// A fresh directory for one outgoing file, and the path it should take.
    ///
    /// One directory per send, so two files with the same name cannot collide
    /// and deleting one send's copy can never delete another's.
    public static func directory() -> URL {
        root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Copies `url` into a fresh staging directory.
    ///
    /// Returns `nil` when it cannot be read — a file provider that vanished, a
    /// format iOS will not open. Letting the throw out of here would only be
    /// reported the same way, one layer further from the reason.
    public static func stage(_ url: URL) -> URL? {
        let directory = directory()
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    /// Deletes a staged copy, **and only a staged copy**.
    ///
    /// The guard is the point: `-DSHUploadFilePath` and a path the user picked
    /// in Files are files that belong to someone else — deleting one of those
    /// because a transfer finished would be destroying the user's data. So the
    /// path is checked against the staging root before anything is removed, and
    /// a path outside it is left alone.
    public static func remove(_ url: URL) {
        guard isStaged(url) else { return }
        // The file's own directory is the per-send one, so the whole directory
        // goes: leaving an empty `<uuid>/` behind is the same leak in miniature.
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Whether this path is a copy this app made, rather than the user's file.
    public static func isStaged(_ url: URL) -> Bool {
        let staged = root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(staged + "/")
    }

    /// Deletes leftovers from sends that never finished.
    ///
    /// Covers exactly one case: the app was killed mid-upload, so nothing ran
    /// the per-send delete. Age is measured on the file, and only whole
    /// per-send directories older than `age` are removed.
    @discardableResult
    public static func sweep(olderThan age: TimeInterval = sweepAge) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: entry)
            removed += 1
        }
        return removed
    }
}

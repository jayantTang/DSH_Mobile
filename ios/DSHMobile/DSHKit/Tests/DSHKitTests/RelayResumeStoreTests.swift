import Foundation
import Testing

@testable import DSHKit
import RelayKit

/// The persisted resume data for interrupted downloads (P-13c, plan A).
///
/// The property that matters is not "a blob round-trips" — it is that a blob can
/// only ever be resumed into **the same version of the same file**. If that were
/// not true, an interruption spanning a change would splice the old contents and
/// the new ones into a file that never existed, and the result would look like a
/// successful download. Everything here is about that boundary.
///
/// **Every test passes its own root.** The store takes an explicit `root:`
/// parameter rather than reaching for `DSH_RELAY_RESUME_DIR`, because that
/// variable is process-global and Swift Testing runs suites in parallel: this
/// suite and the transfer suite both used to `setenv` it, so a `save` here could
/// land on the root that suite had just installed and the `load` that should have
/// seen it read `nil`. The failure was real and reproducible — "single suite
/// green, whole run red" — and a parameter cannot race.
@Suite("Relay resume store", .serialized)
struct RelayResumeStoreTests {

    /// A fresh directory per test, removed afterwards. No process state is
    /// touched, so nothing here can affect a suite running concurrently.
    private func withRoot(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-resume-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test("a blob saved for one version is not offered to another")
    func versionIsPartOfTheKey() {
        withRoot { root in
            let blob = Data("resume-blob".utf8)
            RelayResumeStore.save(blob, scopeId: "s1", path: "/w/big.bin", version: "v1",
                                  root: root)

            #expect(RelayResumeStore.load(scopeId: "s1", path: "/w/big.bin", version: "v1",
                                         root: root) == blob)
            // The file changed under the interrupted attempt: the bytes that blob
            // describes are not the bytes of this version, so it must not be
            // offered. Starting over is the correct answer, not a fallback.
            #expect(RelayResumeStore.load(scopeId: "s1", path: "/w/big.bin", version: "v2",
                                          root: root) == nil)
        }
    }

    @Test("a blob saved for one file is not offered to another")
    func pathIsPartOfTheKey() {
        withRoot { root in
            RelayResumeStore.save(Data("a".utf8), scopeId: "s1", path: "/w/a.bin", version: "v1",
                                  root: root)
            #expect(RelayResumeStore.load(scopeId: "s1", path: "/w/a.bin", version: "v1",
                                          root: root) != nil)
            #expect(RelayResumeStore.load(scopeId: "s1", path: "/w/b.bin", version: "v1",
                                          root: root) == nil)
            #expect(RelayResumeStore.load(scopeId: "s2", path: "/w/a.bin", version: "v1",
                                          root: root) == nil)
        }
    }

    @Test("a later blob for the same version replaces the earlier one")
    func newestBlobWins() {
        withRoot { root in
            RelayResumeStore.save(Data("first".utf8), scopeId: "s1", path: "p", version: "v1",
                                  root: root)
            RelayResumeStore.save(Data("second".utf8), scopeId: "s1", path: "p", version: "v1",
                                  root: root)
            // The later interruption knows about more bytes; keeping both would
            // mean choosing with no way to tell which is which.
            #expect(RelayResumeStore.load(scopeId: "s1", path: "p", version: "v1", root: root)
                == Data("second".utf8))
        }
    }

    @Test("discarding removes it, so a finished download cannot be resumed again")
    func discardIsFinal() {
        withRoot { root in
            RelayResumeStore.save(Data("x".utf8), scopeId: "s1", path: "p", version: "v1",
                                  root: root)
            RelayResumeStore.discard(scopeId: "s1", path: "p", version: "v1", root: root)
            #expect(RelayResumeStore.load(scopeId: "s1", path: "p", version: "v1", root: root) == nil)
        }
    }

    @Test("the sweep drops stale blobs and keeps fresh ones")
    func sweepUsesAge() {
        withRoot { root in
            let manager = FileManager.default
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)

            RelayResumeStore.save(Data("fresh".utf8), scopeId: "s", path: "fresh", version: "v",
                                  root: root)
            RelayResumeStore.save(Data("stale".utf8), scopeId: "s", path: "stale", version: "v",
                                  root: root)
            // Age the stale one by two days.
            let stale = RelayResumeStore.url(scopeId: "s", path: "stale", version: "v", root: root)
            let old = Date().addingTimeInterval(-2 * 24 * 60 * 60)
            try? manager.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)

            let removed = RelayResumeStore.sweep(root: root)
            #expect(removed == 1)
            #expect(RelayResumeStore.load(scopeId: "s", path: "fresh", version: "v", root: root) != nil)
            #expect(RelayResumeStore.load(scopeId: "s", path: "stale", version: "v", root: root) == nil)
        }
    }

    @Test("the sweep is a no-op when nothing was ever saved")
    func sweepWithoutARoot() {
        withRoot { root in
            #expect(RelayResumeStore.sweep(root: root) == 0)
        }
    }

    @Test("two roots never see each other's blobs")
    func rootsAreIndependent() {
        // The property the old environment-based isolation was supposed to have
        // and did not: a blob written under one root must be invisible under any
        // other. With a shared process variable the second root could win the
        // race and the *same* lookup returned whichever directory happened to be
        // installed at read time.
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-resume-a-\(UUID().uuidString)", isDirectory: true)
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-resume-b-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        RelayResumeStore.save(Data("one".utf8), scopeId: "s", path: "p", version: "v", root: first)
        #expect(RelayResumeStore.load(scopeId: "s", path: "p", version: "v", root: first) != nil)
        #expect(RelayResumeStore.load(scopeId: "s", path: "p", version: "v", root: second) == nil,
                "两个根互相看得见——隔离没生效")
    }

    @Test("the key is a fixed-width digest, not the path itself")
    func keyIsHashed() {
        // A path can be deep and contain slashes; mirroring it into the directory
        // tree would mean creating a tree per blob. The digest keeps one flat
        // name, and pins that two different files never collide.
        let first = RelayResumeStore.key(scopeId: "s1", path: "/a/b.bin", version: "v1")
        let second = RelayResumeStore.key(scopeId: "s1", path: "/a/b.bin", version: "v2")
        #expect(first != second)
        #expect(!first.contains("/"))
        #expect(first.count == 64, "not a sha256 hex digest: \(first)")
        // Field boundaries survive: without the separator, ("ab","c") and
        // ("a","bc") would hash the same and collide.
        #expect(RelayResumeStore.key(scopeId: "ab", path: "c", version: "v")
            != RelayResumeStore.key(scopeId: "a", path: "bc", version: "v"))
    }
}

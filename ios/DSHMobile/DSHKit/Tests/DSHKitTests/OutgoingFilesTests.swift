import Foundation
import Testing

@testable import DSHKit

/// The staging area for outgoing files (P-3).
///
/// Three things have to hold, and each one has a way of going wrong that no
/// other test would catch: a staged copy has to land somewhere a background
/// task can still read after a suspension, a finished send has to delete its
/// own copy (nothing else ever did — it was a leak that only grew), and the
/// delete has to be **incapable** of touching a file this app did not make.
@Suite("Outgoing files", .serialized)
struct OutgoingFilesTests {

    /// Points both the code under test and the assertion at one temp directory.
    ///
    /// `OutgoingFiles.root` is a computed property read fresh each time, so the
    /// environment override is what makes the test hermetic: without it the
    /// macOS run would stage into the developer's real `~/Library/Caches`.
    private func withRoot(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("outgoing-tests-\(UUID().uuidString)", isDirectory: true)
        let previous = ProcessInfo.processInfo.environment["DSH_OUTGOING_FILES_DIR"]
        setenv("DSH_OUTGOING_FILES_DIR", root.path, 1)
        defer {
            if let previous { setenv("DSH_OUTGOING_FILES_DIR", previous, 1) }
            else { unsetenv("DSH_OUTGOING_FILES_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    private func sourceFile(named name: String, bytes: Int = 32) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("outgoing-source-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    @Test("a staged file lands under the staging root, not in tmp")
    func stagingLandsUnderTheRoot() throws {
        try withRoot { root in
            let source = try sourceFile(named: "clip.mp4")
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

            let staged = try #require(OutgoingFiles.stage(source))
            #expect(staged.lastPathComponent == "clip.mp4")
            #expect(OutgoingFiles.isStaged(staged))
            #expect(staged.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
            // The bytes are a copy, and they are the bytes.
            #expect(try Data(contentsOf: staged) == (try Data(contentsOf: source)))
            // The source file is untouched.
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test("finishing a send deletes the staged copy, directory and all")
    func removeDeletesTheStagedCopy() throws {
        try withRoot { root in
            let source = try sourceFile(named: "report.pdf")
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            let staged = try #require(OutgoingFiles.stage(source))

            OutgoingFiles.remove(staged)

            #expect(!FileManager.default.fileExists(atPath: staged.path))
            // The per-send directory goes too — an empty one is the same leak.
            #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
            // Nothing else in the staging root was collateral damage.
            let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            #expect(left.isEmpty)
        }
    }

    @Test("a file the app did not stage is never deleted")
    func removeRefusesAFileItDidNotMake() throws {
        try withRoot { _ in
            // This is the `-DSHUploadFilePath` case: a real workspace file the
            // run handed to the app. Deleting it would destroy the user's data.
            let foreign = try sourceFile(named: "workspace-real.txt", bytes: 11)
            defer { try? FileManager.default.removeItem(at: foreign.deletingLastPathComponent()) }

            #expect(!OutgoingFiles.isStaged(foreign))
            OutgoingFiles.remove(foreign)
            #expect(FileManager.default.fileExists(atPath: foreign.path))
            #expect(try Data(contentsOf: foreign).count == 11)
        }
    }

    @Test("a path that merely shares the prefix is not staged")
    func prefixIsCheckedAtAPathBoundary() throws {
        try withRoot { root in
            // `<root>-sibling` starts with the same characters as `<root>`; a
            // naive `hasPrefix` on the string would call it ours and delete it.
            let sibling = URL(fileURLWithPath: root.path + "-sibling", isDirectory: true)
                .appendingPathComponent("keep.txt")
            try FileManager.default.createDirectory(at: sibling.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: sibling)
            defer { try? FileManager.default.removeItem(at: sibling.deletingLastPathComponent()) }

            #expect(!OutgoingFiles.isStaged(sibling))
            OutgoingFiles.remove(sibling)
            #expect(FileManager.default.fileExists(atPath: sibling.path))
        }
    }

    @Test("the launch sweep drops old leftovers and keeps fresh ones")
    func sweepUsesAge() throws {
        try withRoot { root in
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

            let old = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fresh = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            for directory in [old, fresh] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: directory.appendingPathComponent("f.bin"))
            }
            // Two days old: the shape an upload killed mid-flight leaves behind.
            try fileManager.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-48 * 60 * 60)],
                ofItemAtPath: old.path
            )

            #expect(OutgoingFiles.sweep() == 1)
            #expect(!fileManager.fileExists(atPath: old.path))
            #expect(fileManager.fileExists(atPath: fresh.path))
        }
    }

    @Test("the sweep is a no-op when the staging root does not exist")
    func sweepOnAnEmptyInstall() throws {
        try withRoot { _ in
            // A fresh install has never staged anything, and a launch must not
            // treat that as an error worth reporting.
            #expect(OutgoingFiles.sweep() == 0)
        }
    }

    @Test("two sends of the same name cannot collide")
    func eachStageGetsItsOwnDirectory() throws {
        try withRoot { _ in
            let first = try sourceFile(named: "same.bin", bytes: 3)
            let second = try sourceFile(named: "same.bin", bytes: 7)
            defer {
                try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
            }

            let a = try #require(OutgoingFiles.stage(first))
            let b = try #require(OutgoingFiles.stage(second))
            #expect(a != b)
            // Deleting one send's copy leaves the other's alone.
            OutgoingFiles.remove(a)
            #expect(try Data(contentsOf: b).count == 7)
        }
    }
}

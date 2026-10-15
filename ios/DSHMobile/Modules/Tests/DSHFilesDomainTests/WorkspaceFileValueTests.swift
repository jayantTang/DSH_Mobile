import DSHFilesDomain
import DSHKit
import DSHTestingSupport
import XCTest

/// 027 — the pure folds of the workspace-file values: byte sizes, how a name
/// picks an opener, and how a page or a directory row is read back.
///
/// These have no transport and no state, which is exactly why they are worth
/// pinning at the boundaries: an off-by-one in `ByteFormat.compact` or in
/// `lastLine` reads as a wrong number on screen and as nothing at all in a log.
@MainActor
final class WorkspaceFileValueTests: XCTestCase {

    /// Held for the life of the case: `WorkspaceFilesModel` keeps its store
    /// weakly, so a link built inline would be gone before the first call.
    private var link: FakeLinkService!

    override func tearDown() {
        link = nil
        super.tearDown()
    }

    func test_value_folds_stay_on_the_right_side_of_every_boundary() async {
        // MARK: ByteFormat.compact

        XCTAssertEqual(ByteFormat.compact(0), "0 B")
        XCTAssertEqual(ByteFormat.compact(1), "1 B")
        XCTAssertEqual(ByteFormat.compact(1023), "1023 B", "the last byte below 1 KB is still bytes")
        XCTAssertEqual(ByteFormat.compact(1024), "1.0 KB")
        XCTAssertEqual(ByteFormat.compact(1536), "1.5 KB")
        XCTAssertEqual(ByteFormat.compact(1024 * 1024 - 1), "1024.0 KB", "just below the MB line, KB still holds")
        XCTAssertEqual(ByteFormat.compact(1024 * 1024), "1.0 MB")
        XCTAssertEqual(ByteFormat.compact(3 * 1024 * 1024 / 2), "1.5 MB")
        XCTAssertEqual(ByteFormat.compact(1024 * 1024 * 1024 - 1), "1024.0 MB")
        XCTAssertEqual(ByteFormat.compact(1024 * 1024 * 1024), "1.0 GB")
        XCTAssertEqual(ByteFormat.compact(5 * 1024 * 1024 * 1024 / 2), "2.5 GB")
        XCTAssertEqual(ByteFormat.compact(Int.max),
                       String(format: "%.1f GB", Double(Int.max) / Double(1024 * 1024 * 1024)),
                       "there is no unit above GB, so a huge size keeps counting in GB")
        XCTAssertEqual(ByteFormat.compact(-1), "-1 B", "a negative never reaches the wire, but it must not trap")

        // MARK: WorkspaceFileKind.of

        XCTAssertEqual(WorkspaceFileKind.of(path: "ios/App.swift"), .text)
        XCTAssertEqual(WorkspaceFileKind.of(path: "report/index.HTML"), .web, "the extension is matched case-insensitively")
        XCTAssertEqual(WorkspaceFileKind.of(path: "shot.PNG"), .image)
        XCTAssertEqual(WorkspaceFileKind.of(path: "report.pdf"), .preview)
        XCTAssertEqual(WorkspaceFileKind.of(path: "bundle.zip"), .binary,
                       "the system preview draws nothing for a zip, so the app shows its own card")
        XCTAssertEqual(WorkspaceFileKind.of(path: "Makefile"), .text,
                       "an unknown suffix is tried as text: that read is the one that fails informatively")
        XCTAssertEqual(WorkspaceFilesModel.kind(for: "notes"), WorkspaceFileKind.of(path: "notes"),
                       "the model's entry point has to be the same rule, not a second one")

        // MARK: a page's lines

        let carrier = FakeCarrier()
        let model = WorkspaceFilesModel(scope: FilesSeam.scope())
        link = FilesSeam.link(carrier)
        model.attach(to: link)

        carrier.unaryResponses["workspaceFiles/read"] = .success(FilesSeam.page(
            absolutePath: FilesSeam.workRoot + "/x.txt", offset: 5, text: "a\nb", lines: 2, eof: true
        ))
        await model.openFile(path: "x.txt")
        XCTAssertEqual(model.file?.contentLines, ["a", "b"], "a page is \\n-separated with no trailing terminator")
        XCTAssertEqual(model.file?.lastLine, 6, "a page starting at line 5 that holds 2 lines ends at 6")

        carrier.unaryResponses["workspaceFiles/read"] = .success(FilesSeam.page(
            absolutePath: FilesSeam.workRoot + "/x.txt", offset: 1, text: "", lines: 0, eof: true
        ))
        await model.openFile(path: "x.txt")
        XCTAssertEqual(model.file?.contentLines, [], "zero lines is no lines, past the last one")
        XCTAssertEqual(model.file?.lastLine, 1)

        carrier.unaryResponses["workspaceFiles/read"] = .success(FilesSeam.page(
            absolutePath: FilesSeam.workRoot + "/x.txt", offset: 3, text: "", lines: 1, eof: true
        ))
        await model.openFile(path: "x.txt")
        XCTAssertEqual(model.file?.contentLines, [""], "one empty line is a line, not nothing")

        // MARK: a directory row

        carrier.unaryResponses["workspaceFiles/list"] = .success(FilesSeam.listing(
            path: FilesSeam.workRoot,
            entries: [
                FilesSeam.entry("src", type: "directory"),
                FilesSeam.entry("empty.txt", type: "file", size: 0),
                FilesSeam.entry("notes.txt", type: "file", size: 1024),
            ]
        ))
        await model.loadDirectory("")
        let entries = model.visibleEntries
        XCTAssertEqual(entries.map(\.id), ["src", "empty.txt", "notes.txt"], "a row is keyed by its name")
        guard entries.count == 3 else { return }
        XCTAssertEqual(entries.map { $0.path(in: "") }, ["src", "empty.txt", "notes.txt"])
        XCTAssertEqual(entries[0].path(in: "src/lib"), "src/lib/src", "a child's path is the parent's plus its name")
        XCTAssertEqual(entries[1].sizeText, "0 B", "a zero-byte file is not the same as a directory with no size")
        XCTAssertEqual(entries[2].sizeText, "1.0 KB")
    }
}

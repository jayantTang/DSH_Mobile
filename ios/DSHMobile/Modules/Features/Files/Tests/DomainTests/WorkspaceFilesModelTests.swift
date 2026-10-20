import DSHConnectionAPI
import DSHFilesDomain
import DSHKit
import DSHTestingSupport
import XCTest

/// 027 — `WorkspaceFilesModel`: the directory listing, navigation inside the
/// scope, line paging, and what a failure turns into.
///
/// Every case drives the model over `FakeCarrier`, so what is asserted is the
/// envelope the host would receive (method, scope id, path, range) and the state
/// the screen renders afterwards — not just the fold.
///
/// Out of scope here: the download path (`download`/`freshCopy`), which needs a
/// relay transfer target the fake link refuses by design, and the web preview.
@MainActor
final class WorkspaceFilesModelTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var link: FakeLinkService!

    override func setUp() {
        super.setUp()
        carrier = FakeCarrier()
    }

    override func tearDown() {
        carrier = nil
        link = nil
        super.tearDown()
    }

    /// A browser on a connected fake link, scoped to `FilesSeam.workRoot`.
    private func browser(initialPath: String = "") -> WorkspaceFilesModel {
        let model = WorkspaceFilesModel(scope: FilesSeam.scope(), initialPath: initialPath)
        link = FilesSeam.link(carrier)
        model.attach(to: link)
        return model
    }

    // MARK: - Listing

    func test_the_root_listing_asks_for_dot_and_orders_and_filters_what_came_back() async {
        carrier.unaryResponses["workspaceFiles/list"] = .success(FilesSeam.listing(
            path: FilesSeam.workRoot,
            entries: [
                FilesSeam.entry("notes.txt", type: "file", size: 2048),
                FilesSeam.entry("src", type: "directory"),
                FilesSeam.entry("pipe", type: "fifo"),
            ],
            truncated: true
        ))
        let model = browser()
        await model.loadDirectory("")

        let calls = carrier.calls(to: "workspaceFiles/list")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].args?["workspaceFileScopeId"]?.stringValue, FilesSeam.sessionId,
                       "the host resolves this field as a session id")
        XCTAssertEqual(calls[0].args?["path"]?.stringValue, ".",
                       "the host refuses an empty path and accepts `.` for the workspace root")
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.browsingPath.isEmpty, "the echoed root is the empty workspace path")
        XCTAssertTrue(model.breadcrumbs.isEmpty)
        XCTAssertEqual(model.directoryPathLabel, FilesSeam.workRoot, "with no breadcrumb the label is the root")
        XCTAssertEqual(model.listing?.truncated, true, "the host's entry cap has to reach the view")

        // Directories first, then names; a type the app does not model is still a
        // row rather than a dropped entry.
        let entries = model.visibleEntries
        XCTAssertEqual(entries.map(\.name), ["src", "notes.txt", "pipe"])
        guard entries.count == 3 else { return }
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertFalse(entries[0].isFile)
        XCTAssertEqual(entries[1].kind, .file)
        XCTAssertEqual(entries[2].kind, .other)
        XCTAssertNil(entries[0].sizeText, "a directory carries no size on the wire")
        XCTAssertEqual(entries[1].sizeText, "2.0 KB")
        XCTAssertEqual(entries[1].path(in: ""), "notes.txt")
        XCTAssertEqual(entries[1].path(in: "src"), "src/notes.txt")

        // Search is by name, case-insensitively, on trimmed input.
        model.searchText = "PIPE"
        XCTAssertEqual(model.visibleEntries.map(\.name), ["pipe"])
        model.searchText = "   "
        XCTAssertEqual(model.visibleEntries.count, 3, "whitespace is not a query")
    }

    // MARK: - Navigating inside the scope

    func test_navigating_keeps_the_browse_path_relative_to_the_scope() async throws {
        let srcListing = FilesSeam.listing(
            path: FilesSeam.workRoot + "/src",
            entries: [FilesSeam.entry("main.swift", type: "file", size: 1)]
        )
        let rootListing = FilesSeam.listing(path: FilesSeam.workRoot, entries: [
            FilesSeam.entry("src", type: "directory"),
            FilesSeam.entry("notes.txt", type: "file", size: 10),
        ])

        carrier.unaryResponses["workspaceFiles/list"] = .success(rootListing)
        let model = browser()
        await model.loadDirectory("")

        // Opening a directory asks for the child and takes the browser's path
        // from the host's echo, which comes back absolute.
        carrier.unaryResponses["workspaceFiles/list"] = .success(srcListing)
        let src = try XCTUnwrap(model.visibleEntries.first { $0.isDirectory })
        await model.open(src)
        XCTAssertEqual(model.browsingPath, "src", "an absolute echo converges on the same relative path")
        XCTAssertEqual(model.breadcrumbs, ["src"])
        XCTAssertEqual(model.directoryPathLabel, "src")
        XCTAssertEqual(carrier.calls(to: "workspaceFiles/list").count, 2)

        // A file row is not a directory: opening it must not re-list anything.
        let file = try XCTUnwrap(model.visibleEntries.first { $0.isFile })
        await model.open(file)
        XCTAssertEqual(carrier.calls(to: "workspaceFiles/list").count, 2)

        // Up one level; the parent of the root is the root, so the second call
        // asks for nothing at all.
        carrier.unaryResponses["workspaceFiles/list"] = .success(rootListing)
        await model.goUp()
        XCTAssertTrue(model.browsingPath.isEmpty)
        XCTAssertTrue(model.breadcrumbs.isEmpty)
        let upCalls = carrier.calls(to: "workspaceFiles/list")
        XCTAssertEqual(upCalls.count, 3)
        XCTAssertEqual(upCalls.last?.args?["path"]?.stringValue, ".")
        await model.goUp()
        XCTAssertEqual(carrier.calls(to: "workspaceFiles/list").count, 3, "the root has no parent")

        // Jump is inclusive of the indexed component.
        carrier.unaryResponses["workspaceFiles/list"] = .success(srcListing)
        await model.open(src)
        XCTAssertEqual(model.breadcrumbs, ["src"])
        await model.jump(to: 0)
        XCTAssertEqual(carrier.calls(to: "workspaceFiles/list").last?.args?["path"]?.stringValue, "src",
                       "index 0 is the first component, not the root")
        XCTAssertEqual(model.browsingPath, "src")
        await model.jump(to: 99)
        XCTAssertEqual(model.browsingPath, "src", "an index past the end is the deepest component")
        XCTAssertEqual(carrier.calls(to: "workspaceFiles/list").last?.args?["path"]?.stringValue, "src")

        // No components at all: the same jump lands on the root.
        carrier.unaryResponses["workspaceFiles/list"] = .success(rootListing)
        await model.goUp()
        XCTAssertTrue(model.browsingPath.isEmpty)
        await model.jump(to: 0)
        XCTAssertEqual(carrier.calls(to: "workspaceFiles/list").last?.args?["path"]?.stringValue, ".")

        // A browser opened at a path starts there instead of at the root.
        carrier.unaryResponses["workspaceFiles/list"] = .success(srcListing)
        let deep = browser(initialPath: "src")
        await deep.start()
        XCTAssertEqual(carrier.calls(to: "workspaceFiles/list").last?.args?["path"]?.stringValue, "src")
        XCTAssertEqual(deep.browsingPath, "src")
        XCTAssertEqual(deep.phase, .loaded)
    }

    // MARK: - Reading a file

    func test_a_file_reads_page_by_page_and_load_more_advances_the_cursor() async throws {
        let model = browser()

        // Nothing open: there is no page to ask for.
        await model.loadMore()
        XCTAssertTrue(carrier.calls.isEmpty)

        let path = FilesSeam.workRoot + "/notes.txt"
        carrier.unaryResponses["workspaceFiles/read"] = .success(FilesSeam.page(
            absolutePath: path, offset: 1, text: "one\ntwo", lines: 2, eof: false, version: "v1", bytes: 40
        ))
        await model.openFile(path: "notes.txt")

        XCTAssertEqual(model.filePhase, .loaded)
        XCTAssertFalse(model.fileRefusedAsText)
        XCTAssertEqual(model.file?.absolutePath, path)
        XCTAssertEqual(model.file?.offset, 1)
        XCTAssertEqual(model.file?.lines, 2)
        XCTAssertEqual(model.file?.bytes, 40)
        XCTAssertEqual(model.file?.text, "one\ntwo")
        XCTAssertEqual(model.fileTitle, "notes.txt", "the title is the path relative to the session's root")

        // The next page starts at the first line this page does not hold, and it
        // is appended rather than replacing.
        carrier.unaryResponses["workspaceFiles/read"] = .success(FilesSeam.page(
            absolutePath: path, offset: 3, text: "three", lines: 1, eof: false, version: "v2"
        ))
        await model.loadMore()
        XCTAssertEqual(model.file?.text, "one\ntwo\nthree")
        XCTAssertEqual(model.file?.lines, 3)
        XCTAssertEqual(model.file?.offset, 1, "the merged page keeps the first page's origin")

        carrier.unaryResponses["workspaceFiles/read"] = .success(FilesSeam.page(
            absolutePath: path, offset: 4, text: "four", lines: 1, eof: false, version: "v3"
        ))
        await model.loadMore()
        XCTAssertEqual(model.file?.text, "one\ntwo\nthree\nfour")
        XCTAssertEqual(model.file?.lines, 4)
        XCTAssertEqual(model.file?.version, "v3", "the newest page's version token is the one kept")
        XCTAssertEqual(model.file?.eof, false)

        var reads = carrier.calls(to: "workspaceFiles/read")
        XCTAssertEqual(reads.map { $0.args?["range"]?["offset"]?.intValue }, [1, 3, 4],
                       "the cursor is offset + lines of the page the model holds")
        XCTAssertEqual(reads.map { $0.args?["range"]?["limit"]?.intValue },
                       [WorkspaceFilesModel.pageLines, WorkspaceFilesModel.pageLines, WorkspaceFilesModel.pageLines])
        XCTAssertEqual(reads.map { $0.args?["workspaceFileScopeId"]?.stringValue },
                       [FilesSeam.sessionId, FilesSeam.sessionId, FilesSeam.sessionId])
        XCTAssertEqual(reads.map { $0.args?["path"]?.stringValue }, ["notes.txt", path, path],
                       "the first page is asked for by the browser's path, later ones by the host's absolute echo")

        // A page that belongs to another file replaces the open one instead of
        // being glued onto it.
        let other = FilesSeam.workRoot + "/renamed.txt"
        carrier.unaryResponses["workspaceFiles/read"] = .success(FilesSeam.page(
            absolutePath: other, offset: 9, text: "swapped", lines: 1, eof: true, version: "v9"
        ))
        await model.loadMore()
        XCTAssertEqual(model.file?.absolutePath, other)
        XCTAssertEqual(model.file?.text, "swapped")
        XCTAssertEqual(model.file?.offset, 9)
        XCTAssertEqual(model.file?.lines, 1)
        XCTAssertEqual(model.fileTitle, "renamed.txt")

        // Past the last page there is nothing left to ask for.
        reads = carrier.calls(to: "workspaceFiles/read")
        await model.loadMore()
        XCTAssertEqual(carrier.calls(to: "workspaceFiles/read").count, reads.count)
    }

    func test_a_refused_non_text_file_is_flagged_and_a_page_that_cannot_be_read_is_an_error() async {
        let model = browser()
        let refusal = DSHRPCFailure(code: "workspace-file/not-text", message: "not a text file")
        carrier.unaryResponses["workspaceFiles/read"] = .failure(refusal)

        await model.openFile(path: "blob.bin")
        XCTAssertTrue(model.fileRefusedAsText,
                      "this is the signal the reader reroutes on, so it must not be lost in the failure")
        XCTAssertEqual(model.filePhase, .failed(LinkErrors.describe(refusal)))
        XCTAssertNil(model.file)

        // A payload that is not a page object at all.
        carrier.unaryResponses["workspaceFiles/read"] = .success(.string("nope"))
        await model.openFile(path: "notes.txt")
        XCTAssertEqual(model.filePhase, .failed("主机返回的文件内容无法解析。"))
        XCTAssertFalse(model.fileRefusedAsText, "opening a file clears the previous refusal")
        XCTAssertNil(model.file)

        // A different failure is not a refusal.
        carrier.unaryResponses["workspaceFiles/read"] = .failure(
            DSHRPCFailure(code: "workspace-file/not-found", message: "gone")
        )
        await model.openFile(path: "notes.txt")
        XCTAssertFalse(model.fileRefusedAsText)
        if case .failed = model.filePhase {} else {
            XCTFail("a refused read must leave the reader in a failed phase")
        }
    }

    // MARK: - Failure states and their copy

    func test_a_failure_becomes_a_phase_and_the_code_table_gives_it_words() async {
        // Nothing attached: the browser says so instead of calling.
        let detached = WorkspaceFilesModel(scope: FilesSeam.scope())
        await detached.loadDirectory("")
        XCTAssertEqual(detached.phase, .failed("尚未连接"))
        await detached.openFile(path: "notes.txt")
        XCTAssertEqual(detached.filePhase, .failed("尚未连接"))
        XCTAssertTrue(carrier.calls.isEmpty, "no link, nothing to ask")

        // Attached to a link whose client is gone: same state, same silence.
        let offline = WorkspaceFilesModel(scope: FilesSeam.scope())
        offline.attach(to: FakeLinkService(state: .disconnected))
        await offline.loadDirectory("")
        XCTAssertEqual(offline.phase, .failed("尚未连接"))
        XCTAssertTrue(carrier.calls.isEmpty)

        // A listening host that refuses the listing.
        let model = browser()
        let refusal = DSHRPCFailure(code: "workspace-file/not-directory", message: "host said no")
        carrier.unaryResponses["workspaceFiles/list"] = .failure(refusal)
        await model.loadDirectory("src")
        XCTAssertEqual(model.phase, .failed(LinkErrors.describe(refusal)))
        XCTAssertTrue(model.browsingPath.isEmpty, "a failed load must not move the browser")
        XCTAssertNil(model.listing)

        // A listing that is not a directory object.
        carrier.unaryResponses["workspaceFiles/list"] = .success(.string("nope"))
        await model.loadDirectory("src")
        XCTAssertEqual(model.phase, .failed("主机返回的目录结构无法解析。"))

        // The host's own numbering, one sentence each.
        let withPath = DSHRPCFailure(
            code: "workspace-file/not-found", message: "host said no",
            details: .object(["path": .string(FilesSeam.workRoot + "/gone.txt")])
        )
        XCTAssertTrue(WorkspaceFilesModel.describe(withPath).contains(FilesSeam.workRoot + "/gone.txt"),
                      "the host's path is the actionable part of the message")
        XCTAssertNotEqual(
            WorkspaceFilesModel.describe(withPath),
            WorkspaceFilesModel.describe(DSHRPCFailure(code: "workspace-file/not-found", message: "host said no")),
            "a not-found without a path needs its own wording"
        )

        let numbered = [
            "workspace-file/outside-workspace",
            "workspace-file/not-directory",
            "workspace-file/not-regular-file",
            "workspace-file/not-text",
            "workspace-file/too-large",
            "workspace-file/unknown-workspace",
        ]
        let messages = numbered.map { WorkspaceFilesModel.describe(DSHRPCFailure(code: $0, message: "host said no")) }
        XCTAssertEqual(Set(messages).count, numbered.count,
                       "two codes sharing one sentence is how a user stops being able to tell them apart")
        XCTAssertFalse(messages.contains("host said no"), "a numbered code must not fall through to the host's text")
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        // The one pair that does share a sentence shares it on purpose: for a
        // user, "the host has no workspace for this session" is one situation,
        // however it was numbered.
        XCTAssertEqual(
            WorkspaceFilesModel.describe(DSHRPCFailure(code: "gateway/lookup-not-found", message: "host said no")),
            WorkspaceFilesModel.describe(DSHRPCFailure(code: "workspace-file/unknown-workspace", message: "host said no"))
        )

        // Anything else keeps the host's message, and a transport failure is not
        // dressed up as a file problem.
        XCTAssertEqual(
            WorkspaceFilesModel.describe(DSHRPCFailure(code: "workspace-file/who-knows", message: "host said no")),
            "host said no"
        )
        let transport = URLError(.timedOut)
        XCTAssertEqual(WorkspaceFilesModel.describe(transport), LinkErrors.describe(transport))
    }
}

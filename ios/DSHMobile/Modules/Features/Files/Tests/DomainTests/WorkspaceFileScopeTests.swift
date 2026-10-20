import DSHFilesDomain
import DSHKit
import XCTest

/// 027 — `WorkspaceFileScope`: which session a browser is looking at, and how a
/// path is shortened for display.
///
/// The point of the scope type is that the host resolves
/// `workspaceFileScopeId` as a **Session id** (see the type's own note), so the
/// cases here pin that a scope always carries a session, that a subagent row
/// carries its *own* transcript id rather than the parent's, and where path
/// shortening draws the line.
@MainActor
final class WorkspaceFileScopeTests: XCTestCase {

    func test_scope_identity_is_the_session_plus_the_root() {
        let scoped = WorkspaceFileScope(
            sessionId: "s-1", workspaceRoot: FilesSeam.workRoot, hostHome: FilesSeam.hostHome
        )

        XCTAssertEqual(scoped.sessionId, "s-1")
        XCTAssertEqual(scoped.workspaceRoot, FilesSeam.workRoot)
        XCTAssertEqual(scoped.id, "s-1|/Users/tester/work", "sheet(item:) keys on this")
        XCTAssertEqual(scoped.id, FilesSeam.scope(sessionId: "s-1").id)

        // A session whose summary carried no working directory still has an
        // identity, and it must not collide with the rooted one.
        let rootless = WorkspaceFileScope(sessionId: "s-1", hostHome: nil)
        XCTAssertNil(rootless.workspaceRoot)
        XCTAssertEqual(rootless.id, "s-1|")
        XCTAssertNotEqual(rootless.id, scoped.id)

        // Two scopes for one session and root are interchangeable references;
        // the host home is presentation, and it is part of the identity too.
        XCTAssertEqual(scoped, WorkspaceFileScope(
            sessionId: "s-1", workspaceRoot: FilesSeam.workRoot, hostHome: FilesSeam.hostHome
        ))
        XCTAssertNotEqual(scoped, WorkspaceFileScope(sessionId: "s-1", workspaceRoot: FilesSeam.workRoot, hostHome: nil))
        XCTAssertNotEqual(scoped, WorkspaceFileScope(sessionId: "s-2", workspaceRoot: FilesSeam.workRoot))
        // The convenience initialiser that carries no root has to agree with the
        // full one, since both are reachable from the app's call sites.
        XCTAssertEqual(rootless, WorkspaceFileScope(sessionId: "s-1", workspaceRoot: nil, hostHome: nil))
    }

    func test_a_subagent_row_scopes_to_its_own_child_session() throws {
        // A subagent transcript is addressed by its row, and the row's own
        // sessionId is the child's — which is what the host resolves to a
        // workspace root. Addressing the parent would browse the wrong tree.
        let child = try FilesSeam.summary(
            sessionId: "child-9", cwd: FilesSeam.workRoot, parentSessionId: "parent-1", origin: "subagent"
        )
        let childScope = WorkspaceFileScope(summary: child, hostHome: FilesSeam.hostHome)
        XCTAssertEqual(childScope.sessionId, "child-9")
        XCTAssertEqual(childScope.workspaceRoot, FilesSeam.workRoot)
        XCTAssertEqual(childScope.id, "child-9|/Users/tester/work")

        // The browser, the git pane and the reader all read the scope off the
        // summary, so the convenience initialiser has to agree with the row.
        XCTAssertEqual(GitModel(summary: child, hostHome: FilesSeam.hostHome).scope.sessionId, "child-9")
        XCTAssertEqual(
            WorkspaceFilesModel(summary: child, hostHome: FilesSeam.hostHome).scope.workspaceRoot,
            FilesSeam.workRoot
        )

        // A plain row addresses itself, and a row with no cwd carries no root
        // rather than inventing one.
        let plain = try FilesSeam.summary(sessionId: "s-2", cwd: "/Users/tester/other")
        XCTAssertEqual(WorkspaceFileScope(summary: plain, hostHome: nil).sessionId, "s-2")
        XCTAssertNil(WorkspaceFileScope(summary: plain, hostHome: nil).hostHome)
        XCTAssertNil(WorkspaceFileScope(summary: try FilesSeam.summary(sessionId: "s-3", cwd: nil), hostHome: nil).workspaceRoot)
    }

    func test_display_path_shortens_against_the_root_and_then_the_host_home() {
        let scoped = FilesSeam.scope()

        // Inside the root: relative to the root, which is what the breadcrumb and
        // the file rows show.
        XCTAssertEqual(scoped.displayPath("/Users/tester/work/src/app.js"), "src/app.js")
        XCTAssertEqual(scoped.displayPath("/Users/tester/work"), "work", "the root itself shows its own name")
        XCTAssertEqual(scoped.displayPath("/Users/tester/work/"), "work", "a trailing slash trims to the same name")

        // Outside the root: the host home still shortens it, and a path that is
        // neither is shown whole.
        XCTAssertEqual(scoped.displayPath("/Users/tester/notes.txt"), "~/notes.txt")
        XCTAssertEqual(scoped.displayPath("/tmp/out.log"), "/tmp/out.log")

        // Boundary — `hasPrefix` is a string test, not a path test, so a sibling
        // directory that merely starts with the root counts as "inside" it.
        // Pinned as the current behaviour, not endorsed: the fix belongs in
        // `displayPath`, not in a test.
        XCTAssertEqual(scoped.displayPath("/Users/tester/workshop/notes.txt"), "shop/notes.txt")

        // An empty root is not a root: the home shortening takes over.
        let emptyRoot = WorkspaceFileScope(sessionId: "s-1", workspaceRoot: "", hostHome: FilesSeam.hostHome)
        XCTAssertEqual(emptyRoot.displayPath("/Users/tester/notes.txt"), "~/notes.txt")

        // No workspace root at all: the home is the only shortening there is.
        let rootless = WorkspaceFileScope(sessionId: "s-1", hostHome: FilesSeam.hostHome)
        XCTAssertEqual(rootless.displayPath("/Users/tester/notes.txt"), "~/notes.txt")
        XCTAssertEqual(rootless.displayPath("/Users/tester"), "~", "the home itself is one tilde")
        XCTAssertEqual(rootless.displayPath("/opt/data/x"), "/opt/data/x")
        // 028 缺陷3已修：按路径分量比较，前缀相同的兄弟路径不再被误缩。
        XCTAssertEqual(rootless.displayPath("/Users/tester2/notes.txt"), "/Users/tester2/notes.txt")

        // No home either: nothing is shortened, and nothing is trimmed.
        XCTAssertEqual(WorkspaceFileScope(sessionId: "s-1", hostHome: nil).displayPath("/Users/tester/notes.txt"),
                       "/Users/tester/notes.txt")
    }
}

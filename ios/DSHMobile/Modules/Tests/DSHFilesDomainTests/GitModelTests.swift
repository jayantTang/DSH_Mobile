import DSHConnectionAPI
import DSHFilesDomain
import DSHKit
import DSHTestingSupport
import XCTest

/// 027 — `GitModel`: the capability gate, the state a status or a log page lands
/// in, and the wording a failure gets.
///
/// The gate is the interesting one. The git bridge lives in the *connector*, not
/// in the host, so a connector that predates it has to be asked about itself
/// first — otherwise the user gets a 404 dressed up as a broken repository.
///
/// Out of scope here: `diff`/`show`/`file`, which are one-line forwards to
/// `GitClient` and are pinned in DSHKit's own `GitClientTests`.
@MainActor
final class GitModelTests: XCTestCase {

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

    /// A git pane attached to a fake link that advertises `capabilities`.
    private func pane(
        capabilities: Set<String> = [LinkHandshake.Capability.git],
        scope: WorkspaceFileScope = FilesSeam.scope()
    ) -> GitModel {
        let model = GitModel(scope: scope)
        link = FilesSeam.link(carrier, capabilities: capabilities)
        model.attach(to: link)
        return model
    }

    func test_the_git_capability_decides_whether_anything_reaches_the_wire() async throws {
        // A connector that predates the bridge: say so, and do not hand it a call
        // it would answer with a 404.
        let model = pane(capabilities: [])
        await model.start()
        XCTAssertEqual(model.phase, .unsupported)
        XCTAssertNil(model.status)
        await model.loadLog()
        XCTAssertEqual(model.logPhase, .unsupported)
        XCTAssertTrue(carrier.calls.isEmpty,
                      "the app's job here is to say the connector is old, not to fire the call anyway")

        // The connector is upgraded mid-session; refresh is what re-asks.
        link.capabilities = [LinkHandshake.Capability.git]
        carrier.unaryResponses["_link/gitStatus"] = .success(FilesSeam.gitStatus(
            root: FilesSeam.workRoot,
            files: [
                FilesSeam.change("README.md"),
                FilesSeam.change("docs/z.md"),
                FilesSeam.change("docs/a.md"),
                FilesSeam.change("ios/App.swift", kind: "added"),
            ]
        ))
        await model.refresh()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.status?.root, FilesSeam.workRoot)
        XCTAssertEqual(model.root, FilesSeam.workRoot)
        XCTAssertEqual(model.status?.branch.label, "main")
        let status = try XCTUnwrap(carrier.calls(to: "_link/gitStatus").first)
        XCTAssertEqual(status.args?["cwd"]?.stringValue, FilesSeam.workRoot,
                       "git resolves the repository from the session's own directory")
        XCTAssertTrue(carrier.calls(to: "_link/gitLog").isEmpty,
                      "no history was ever loaded, so refreshing must not ask for one")

        // What the change list shows is derived from that status.
        XCTAssertEqual(model.visibleFiles.count, 4)
        model.searchText = "DOCS/"
        XCTAssertEqual(model.visibleFiles.map(\.path), ["docs/z.md", "docs/a.md"],
                       "search is case-insensitive and keeps the host's order")
        model.searchText = "  "
        XCTAssertEqual(model.visibleFiles.count, 4, "whitespace is not a query")
        XCTAssertEqual(model.directoryGroups.map(\.directory), ["", "docs", "ios"],
                       "the repository root comes first, then directories by name")
        guard model.directoryGroups.count == 3 else { return }
        XCTAssertEqual(model.directoryGroups.first?.files.map(\.name), ["README.md"])
        XCTAssertEqual(model.directoryGroups[1].files.map(\.name), ["a.md", "z.md"],
                       "inside one directory the rows are sorted by name")

        // Once a history is loaded, a refresh reloads its first page.
        carrier.unaryResponses["_link/gitLog"] = .success(FilesSeam.gitLog(
            commits: [FilesSeam.commit("sha-1")], hasMore: false, skip: 0
        ))
        await model.loadLog()
        await model.refresh()
        let logs = carrier.calls(to: "_link/gitLog")
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs.last?.args?["skip"]?.intValue, 0, "a refresh restarts the list instead of paging it")
        XCTAssertEqual(model.commits.map(\.sha), ["sha-1"])
    }

    func test_the_log_pages_by_skip_and_reset_replaces_the_list() async {
        let model = pane()
        carrier.unaryResponses["_link/gitLog"] = .success(FilesSeam.gitLog(
            commits: [FilesSeam.commit("sha-1"), FilesSeam.commit("sha-2")], hasMore: true, skip: 0
        ))
        await model.loadLog()

        XCTAssertEqual(model.logPhase, .loaded)
        XCTAssertEqual(model.commits.map(\.sha), ["sha-1", "sha-2"])
        XCTAssertTrue(model.logHasMore)
        var calls = carrier.calls(to: "_link/gitLog")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].args?["skip"]?.intValue, 0, "the first page starts at the head")
        XCTAssertEqual(calls[0].args?["cwd"]?.stringValue, FilesSeam.workRoot)

        // The next page continues where the list ends.
        carrier.unaryResponses["_link/gitLog"] = .success(FilesSeam.gitLog(
            commits: [FilesSeam.commit("sha-3")], hasMore: false, skip: 2
        ))
        await model.loadLog()
        XCTAssertEqual(model.commits.map(\.sha), ["sha-1", "sha-2", "sha-3"], "a continuation appends")
        XCTAssertFalse(model.logHasMore)
        calls = carrier.calls(to: "_link/gitLog")
        XCTAssertEqual(calls.count, 2)
        guard calls.count == 2 else { return }
        XCTAssertEqual(calls[1].args?["skip"]?.intValue, 2, "the cursor is how many commits the list already holds")

        // A reset starts over and replaces, rather than appending a second head.
        carrier.unaryResponses["_link/gitLog"] = .success(FilesSeam.gitLog(
            commits: [FilesSeam.commit("sha-4")], hasMore: true, skip: 0
        ))
        await model.loadLog(reset: true)
        XCTAssertEqual(model.commits.map(\.sha), ["sha-4"])
        XCTAssertTrue(model.logHasMore)
        calls = carrier.calls(to: "_link/gitLog")
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.last?.args?["skip"]?.intValue, 0)

        // An empty repository is an empty list, not a broken pane. The reset is
        // what makes this worth pinning: the list is cleared first, so a mapping
        // that read `git/no-commits` as a failure would show the pane broken.
        carrier.unaryResponses["_link/gitLog"] = .failure(
            DSHRPCFailure(code: "git/no-commits", message: "host said no")
        )
        await model.loadLog(reset: true)
        XCTAssertEqual(model.logPhase, .loaded)
        XCTAssertTrue(model.commits.isEmpty)
        XCTAssertFalse(model.logHasMore)
    }

    func test_git_failures_become_states_and_copy() async {
        let model = pane()

        // Not a repository is a normal state, not an error.
        let notARepository = DSHRPCFailure(code: "git/not-a-repo", message: "host said no")
        carrier.unaryResponses["_link/gitStatus"] = .failure(notARepository)
        await model.loadStatus()
        XCTAssertEqual(model.phase, .notARepository)
        XCTAssertNil(model.status)

        // A computer that does not answer must not be dressed up as "not a
        // repository" — the two have nothing in common for the user.
        let transport = URLError(.cannotConnectToHost)
        carrier.unaryResponses["_link/gitStatus"] = .failure(transport)
        await model.loadStatus()
        XCTAssertEqual(model.phase, .failed(LinkErrors.describe(transport)))

        // The pane's own wording, per state.
        XCTAssertEqual(GitModel.describe(notARepository), "这个目录不在 git 仓库里。")
        XCTAssertEqual(
            GitModel.describe(DSHRPCFailure(code: "gateway/unknown-method", message: "no such method")),
            "电脑上的连接器版本较旧，还不支持查看 git。",
            "a connector that never heard of git/* needs an update, and that is what the screen must say"
        )
        let failures = ["git/unavailable", "git/too-large", "git/timed-out"]
            .map { GitModel.describe(DSHRPCFailure(code: $0, message: "host said no")) }
        XCTAssertEqual(Set(failures).count, failures.count, "each git failure has its own sentence")
        XCTAssertFalse(failures.contains("host said no"), "a known code must not fall through to the host's text")

        // An unknown code keeps the host's message, and describe() agrees with
        // the transport wording for anything that is not a git/* code.
        XCTAssertEqual(GitModel.describe(DSHRPCFailure(code: "git/not-found", message: "no such revision")),
                       "no such revision")
        XCTAssertEqual(GitModel.describe(transport), LinkErrors.describe(transport))

        // Detached: a state, not a crash, and nothing on the wire.
        let before = carrier.calls.count
        let detached = GitModel(scope: FilesSeam.scope())
        await detached.start()
        XCTAssertEqual(detached.phase, .failed("尚未连接"))
        await detached.loadLog()
        XCTAssertEqual(detached.logPhase, .idle, "with no link there is no log phase to report")
        XCTAssertEqual(carrier.calls.count, before)

        // A link that advertises the capability but has no client behind it is
        // the same state as no link at all.
        let offline = GitModel(scope: FilesSeam.scope())
        link = FakeLinkService(state: .disconnected, capabilities: [LinkHandshake.Capability.git])
        offline.attach(to: link)
        await offline.loadStatus()
        XCTAssertEqual(offline.phase, .failed("尚未连接"))
        XCTAssertEqual(carrier.calls.count, before)
    }
}

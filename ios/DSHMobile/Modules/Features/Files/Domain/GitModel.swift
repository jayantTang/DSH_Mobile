import DSHConnectionAPI
import DSHCore
import DSHKit
import Foundation
import Observation

/// The Git pane: what changed in the working tree, and what the recent commits
/// were.
///
/// This replaces the Host's change *observations* — a feed of paths and version
/// tokens with no baseline, which could say that a file was touched but never
/// what changed or whether it differed from anything. Git has the baseline, so
/// this screen can show the actual patch, the branch state and the history.
///
/// Everything here is read-only, and every call goes to the connector's own git
/// bridge (see `plugins/mobile-link/lib/git.js`): the Host has no endpoint that
/// runs a command.
@MainActor
@Observable
public final class GitModel {

    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// `resumable`: whether retrying could plausibly help.
        case failed(String)
        /// The workspace is not a git repository — a normal state, not an error.
        case notARepository
        /// The connector on the computer is older than this screen.
        case unsupported
    }

    public let scope: WorkspaceFileScope

    public private(set) var phase: Phase = .idle
    public private(set) var status: GitStatus?

    public private(set) var logPhase: Phase = .idle
    public private(set) var commits: [GitCommit] = []
    public private(set) var logHasMore = false

    public var searchText: String = ""

    private weak var store: (any ConnectionStatus)?

    public init(scope: WorkspaceFileScope) {
        self.scope = scope
    }

    public convenience init(summary: SessionSummary, hostHome: String?) {
        self.init(scope: WorkspaceFileScope(summary: summary, hostHome: hostHome))
    }

    public func attach(to store: any ConnectionStatus) {
        self.store = store
    }

    // MARK: - Loading

    /// The repository root, once a status has been read.
    public var root: String? { status?.root }

    public func start() async {
        await loadStatus()
    }

    public func refresh() async {
        switch phase {
        case .loaded, .notARepository, .unsupported:
            await loadStatus()
        default:
            break
        }
        if !commits.isEmpty || logPhase == .loaded { await loadLog(reset: true) }
    }

    public func loadStatus() async {
        guard let store, let client = store.gitHost else {
            phase = .failed("尚未连接")
            return
        }
        // Ask before calling: a connector that predates the git bridge does not
        // advertise the capability (`_link/hello`), and the app's job then is to
        // say so rather than to fire a call the Host answers with a 404.
        guard store.supports(LinkHandshake.Capability.git) else {
            phase = .unsupported
            return
        }
        if status == nil { phase = .loading }
        do {
            let value = try await client.status(cwd: workingDirectory)
            status = value
            phase = .loaded
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// The first page, or the next one.
    public func loadLog(reset: Bool = false) async {
        guard let store, let client = store.gitHost else { return }
        guard store.supports(LinkHandshake.Capability.git) else {
            logPhase = .unsupported
            return
        }
        if reset {
            commits = []
            logHasMore = false
        }
        if commits.isEmpty { logPhase = .loading }
        do {
            // 跳过多少、怎么合并：两条规则在 DSHKit（`GitLogPaging`）里成对存在，
            // 分开写迟早会出现"跳过头但没换页"这种半套改动。
            let page = try await client.log(
                cwd: workingDirectory,
                skip: GitLogPaging.skip(existing: commits, reset: reset))
            commits = GitLogPaging.merge(commits, page: page.commits, reset: reset)
            logHasMore = page.hasMore
            logPhase = .loaded
        } catch {
            let mapped = Self.phase(for: error)
            // An empty repository is not a broken history list; say so on the
            // list itself rather than replacing the whole pane.
            logPhase = mapped == .notARepository ? .loaded : mapped
        }
    }

    // MARK: - Per-file reads, for the views that ask as they open

    public func diff(path: String, staged: Bool) async throws -> GitPatch {
        guard let client = store?.gitHost else { throw DSHTransportError.notConnected }
        return try await client.diff(cwd: workingDirectory, path: path, staged: staged)
    }

    public func commit(sha: String) async throws -> GitCommitDetail {
        guard let client = store?.gitHost else { throw DSHTransportError.notConnected }
        return try await client.show(cwd: workingDirectory, sha: sha)
    }

    public func commitPatch(sha: String, path: String) async throws -> GitPatch {
        guard let client = store?.gitHost else { throw DSHTransportError.notConnected }
        return try await client.show(cwd: workingDirectory, sha: sha, path: path)
    }

    public func file(rev: String, path: String) async throws -> GitFileAtRevision {
        guard let client = store?.gitHost else { throw DSHTransportError.notConnected }
        return try await client.file(cwd: workingDirectory, rev: rev, path: path)
    }

    /// The session's directory. Git resolves the repository root from here, so a
    /// session that sits in a subdirectory still works.
    private var workingDirectory: String {
        scope.workspaceRoot ?? ""
    }

    // MARK: - Search

    public var visibleFiles: [GitFileChange] {
        let files = status?.files ?? []
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return files }
        return files.filter { $0.path.lowercased().contains(query) }
    }

    /// Changed files grouped by their directory, shallowest first.
    ///
    /// Grouped because that is how a person reviews a change set — "everything
    /// under `ios/DSHMobile`" is one thought, not seven — and because the phone
    /// has no room for a full path on every row.
    public var directoryGroups: [(directory: String, files: [GitFileChange])] {
        let grouped = Dictionary(grouping: visibleFiles) { $0.directory }
        return grouped
            .map { (directory: $0.key, files: $0.value.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                // Root first, then alphabetical by depth-then-name.
                if lhs.directory.isEmpty != rhs.directory.isEmpty { return lhs.directory.isEmpty }
                return lhs.directory.localizedStandardCompare(rhs.directory) == .orderedAscending
            }
    }

    // MARK: - Failure copy

    /// Maps one failure to the state the pane should show.
    ///
    /// `git/*` codes come from the connector's bridge; anything else is the
    /// transport, and "the computer does not answer" must not be dressed up as
    /// "not a repository".
    static func phase(for error: any Error) -> Phase {
        // 语义分类在 DSHKit（`GitFailureClassifier`，带单测）；这里只把**语义**翻成界面状态、
        // 并给每一种配上话术——话术属于界面，`check:i18n` 管着它们。
        guard let kind = GitFailureClassifier.classify(error) else {
            // 传输类失败（电脑不应答）：不许被装扮成"不是仓库"。
            return .failed(LinkErrors.describe(error))
        }
        switch kind {
        case .notARepository: return .notARepository
        case .emptyRepository: return .loaded
        case .unsupported: return .unsupported
        case .gitUnavailable: return .failed("这台电脑上没有找到 git。")
        case .tooLarge: return .failed("这个改动太大，手机上不展开。在电脑上看更合适。")
        case .timedOut: return .failed("git 命令超时了。仓库很大时会发生，稍后再试。")
        case .message(let text): return .failed(text)
        }
    }

    /// Copy for the diff sheet's own failures.
    public static func describe(_ error: any Error) -> String {
        switch phase(for: error) {
        case .notARepository: return "这个目录不在 git 仓库里。"
        case .unsupported: return "电脑上的连接器版本较旧，还不支持查看 git。"
        case .failed(let message): return message
        case .idle, .loading, .loaded: return LinkErrors.describe(error)
        }
    }
}

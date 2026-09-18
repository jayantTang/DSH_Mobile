import Foundation

/// Git, read from the computer that holds the work tree.
///
/// The Host has no endpoint that runs a command, so these calls are answered by
/// the connector itself — reserved `_link/git*` method names that never reach the
/// Host, exactly like the file-upload path. The payoff over the Host's filesystem
/// observations is a **baseline**: git can say which files differ, in which
/// direction, and what the patch is, which an observation feed of paths and
/// version tokens cannot.
///
/// Every call is read-only. The connector's command whitelist (status, diff,
/// log, show, rev-parse, cat-file) has no way to stage, commit or check out
/// anything, and it runs git with locking off so looking at a repository can
/// never leave an `index.lock` behind for the agent to trip over.
public struct GitClient: Sendable {

    private let carrier: any DSHCarrier

    public init(carrier: any DSHCarrier) {
        self.carrier = carrier
    }

    // MARK: - Wire arguments

    private struct CwdArgs: Encodable, Sendable {
        let cwd: String
    }

    private struct DiffArgs: Encodable, Sendable {
        let cwd: String
        let path: String
        let staged: Bool
    }

    private struct ShowFileArgs: Encodable, Sendable {
        let cwd: String
        let sha: String
        let path: String
    }

    private struct LogArgs: Encodable, Sendable {
        let cwd: String
        let skip: Int
        let limit: Int
    }

    private struct FileArgs: Encodable, Sendable {
        let cwd: String
        let rev: String
        let path: String
    }

    // MARK: - Calls

    /// The working tree's change set: branch, and one entry per changed path.
    public func status(cwd: String) async throws -> GitStatus {
        try await carrier.unary(method: "_link/gitStatus", args: CwdArgs(cwd: cwd), as: GitStatus.self)
    }

    /// One file's patch. Untracked files come back as pure additions.
    public func diff(cwd: String, path: String, staged: Bool = false) async throws -> GitPatch {
        try await carrier.unary(
            method: "_link/gitDiff",
            args: DiffArgs(cwd: cwd, path: path, staged: staged),
            as: GitPatch.self
        )
    }

    /// Recent commits, newest first, one page at a time.
    public func log(cwd: String, skip: Int = 0, limit: Int = 20) async throws -> GitLogPage {
        try await carrier.unary(
            method: "_link/gitLog",
            args: LogArgs(cwd: cwd, skip: skip, limit: limit),
            as: GitLogPage.self
        )
    }

    /// One commit with the files it touched.
    public func show(cwd: String, sha: String) async throws -> GitCommitDetail {
        try await carrier.unary(
            method: "_link/gitShow",
            args: ShowFileArgs(cwd: cwd, sha: sha, path: ""),
            as: GitCommitDetail.self
        )
    }

    /// One file's patch inside one commit.
    public func show(cwd: String, sha: String, path: String) async throws -> GitPatch {
        try await carrier.unary(
            method: "_link/gitShow",
            args: ShowFileArgs(cwd: cwd, sha: sha, path: path),
            as: GitPatch.self
        )
    }

    /// The bytes of one file as of one revision, for reading history.
    public func file(cwd: String, rev: String, path: String) async throws -> GitFileAtRevision {
        try await carrier.unary(
            method: "_link/gitFile",
            args: FileArgs(cwd: cwd, rev: rev, path: path),
            as: GitFileAtRevision.self
        )
    }
}

// MARK: - Payloads

/// `_link/gitStatus`.
public struct GitStatus: Decodable, Sendable, Equatable {
    public let root: String
    public let hasHead: Bool
    public let branch: GitBranch
    public let files: [GitFileChange]
    public let truncated: Bool

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(String.self, forKey: .root)
        hasHead = try container.decodeIfPresent(Bool.self, forKey: .hasHead) ?? true
        branch = try container.decodeIfPresent(GitBranch.self, forKey: .branch) ?? GitBranch()
        files = try container.decodeIfPresent([GitFileChange].self, forKey: .files) ?? []
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    private enum CodingKeys: String, CodingKey { case root, hasHead, branch, files, truncated }
}

public struct GitBranch: Decodable, Sendable, Equatable {
    public let head: String?
    public let oid: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let detached: Bool

    public init(
        head: String? = nil,
        oid: String? = nil,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        detached: Bool = false
    ) {
        self.head = head
        self.oid = oid
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.detached = detached
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        head = try container.decodeIfPresent(String.self, forKey: .head)
        oid = try container.decodeIfPresent(String.self, forKey: .oid)
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        ahead = try container.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try container.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        detached = try container.decodeIfPresent(Bool.self, forKey: .detached) ?? false
    }

    private enum CodingKeys: String, CodingKey { case head, oid, upstream, ahead, behind, detached }

    /// What to put above the change list.
    public var label: String {
        if detached { return "游离 HEAD" }
        return head ?? "未知分支"
    }
}

/// One changed path, with git's own two-sided status.
public struct GitFileChange: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Decodable, Sendable {
        case modified
        case added
        case deleted
        case renamed
        case copied
        case typechange
        case untracked
        case conflicted
    }

    public let path: String
    public let originalPath: String?
    public let kind: Kind
    public let staged: Bool
    public let unstaged: Bool

    public var id: String { path }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath)
        let raw = try container.decodeIfPresent(String.self, forKey: .kind) ?? "modified"
        kind = Kind(rawValue: raw) ?? .modified
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
        unstaged = try container.decodeIfPresent(Bool.self, forKey: .unstaged) ?? false
    }

    private enum CodingKeys: String, CodingKey { case path, originalPath, kind, staged, unstaged }

    public var statusLabel: String {
        switch kind {
        case .modified: return "已修改"
        case .added: return "已新增"
        case .deleted: return "已删除"
        case .renamed: return "已重命名"
        case .copied: return "已复制"
        case .typechange: return "类型变了"
        case .untracked: return "未跟踪"
        case .conflicted: return "有冲突"
        }
    }

    /// The directory this file lives in, `""` for the repository root — the axis
    /// the change list is grouped by.
    public var directory: String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    public var name: String {
        String(path.split(separator: "/").last ?? "")
    }
}

/// A patch, or the reason there is no patch to show.
public struct GitPatch: Decodable, Sendable, Equatable {
    public let path: String
    public let staged: Bool
    public let untracked: Bool
    public let binary: Bool
    public let text: String
    public let truncated: Bool

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
        untracked = try container.decodeIfPresent(Bool.self, forKey: .untracked) ?? false
        binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    private enum CodingKeys: String, CodingKey { case path, staged, untracked, binary, text, truncated }

    /// Whether there is nothing to draw: a binary file, a pure rename, or a
    /// change that only touched the mode. The caller has the status entry, which
    /// is where "renamed" and "deleted" actually come from.
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public struct GitCommit: Decodable, Sendable, Equatable, Identifiable {
    public let sha: String
    public let short: String
    public let author: String
    public let date: String
    public let subject: String
    public let refs: [String]

    public var id: String { sha }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha = try container.decode(String.self, forKey: .sha)
        short = try container.decodeIfPresent(String.self, forKey: .short) ?? String(sha.prefix(7))
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        refs = try container.decodeIfPresent([String].self, forKey: .refs) ?? []
    }

    private enum CodingKeys: String, CodingKey { case sha, short, author, date, subject, refs }
}

public struct GitLogPage: Decodable, Sendable, Equatable {
    public let root: String
    public let commits: [GitCommit]
    public let hasMore: Bool
    public let skip: Int

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decodeIfPresent(String.self, forKey: .root) ?? ""
        commits = try container.decodeIfPresent([GitCommit].self, forKey: .commits) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        skip = try container.decodeIfPresent(Int.self, forKey: .skip) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case root, commits, hasMore, skip }
}

public struct GitCommitDetail: Decodable, Sendable, Equatable {
    public let commit: GitCommit?
    public let files: [GitNumstat]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commit = try container.decodeIfPresent(GitCommit.self, forKey: .commit)
        files = try container.decodeIfPresent([GitNumstat].self, forKey: .files) ?? []
    }

    private enum CodingKeys: String, CodingKey { case commit, files }
}

/// One row of `--numstat`: how much changed, or that it was binary.
public struct GitNumstat: Decodable, Sendable, Equatable, Identifiable {
    public let path: String
    public let originalPath: String?
    public let additions: Int?
    public let deletions: Int?
    public let binary: Bool

    public var id: String { path }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath)
        additions = try container.decodeIfPresent(Int.self, forKey: .additions)
        deletions = try container.decodeIfPresent(Int.self, forKey: .deletions)
        binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
    }

    private enum CodingKeys: String, CodingKey { case path, originalPath, additions, deletions, binary }
}

/// A file as of one revision.
public struct GitFileAtRevision: Decodable, Sendable, Equatable {
    public let rev: String
    public let path: String
    public let bytes: Int
    /// Base64, exactly as the wire carries it.
    public let data: String

    public var contents: Data? { Data(base64Encoded: data) }
}

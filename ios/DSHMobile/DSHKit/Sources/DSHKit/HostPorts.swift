import Foundation

/// 按单元切开的宿主能力端口。
///
/// `DSHClient` 是整个 wire API（39 个方法）；Domain 只该看见自己用到的那一组。
/// 这些协议由 `DSHClient` 直接 conform，`LinkService` 暴露 `chatHost` / `settingsHost` /
/// `filesHost` / `directoryHost`，Domain 不再出现 `DSHClient` 类型。
public protocol ChatHosting: Sendable {
    func sessions() async throws -> SessionListValue
    func historyWindow(_ request: HistoryWindowRequest) async throws -> HistoryWindowValue
    var historyWindowEncoding: String? { get }
    func sessionPage(_ request: SessionPageRequest) async throws -> SessionPage
    func sessionFind(_ request: HistorySearchRequest) async throws -> HistorySearchValue
    func follow(_ request: SessionFollowRequest) async -> AsyncThrowingStream<SessionFollowFrame, any Error>
    func prompt(_ request: SessionPromptRequest) async throws
    func cancel(sessionId: String) async throws
    func rename(sessionId: String, title: String) async throws
    func forkSession(sessionId: String, atSeq: Int?) async throws -> JSONValue
    func selectModel(sessionId: String, selection: ModelSelection) async throws
    func modelCatalog() async throws -> ModelCatalog
    func fileReferences(agentId: String, query: String) async throws -> [FileReferenceCandidate]
    func updateSettings(namespace: String, patch: JSONValue, expectedRevision: Int?) async throws
    func attachment(sessionId: String, attachmentId: String) async throws -> JSONValue
}

public extension ChatHosting {
    func forkSession(sessionId: String) async throws -> JSONValue {
        try await forkSession(sessionId: sessionId, atSeq: nil)
    }

    func updateSettings(namespace: String, patch: JSONValue) async throws {
        try await updateSettings(namespace: namespace, patch: patch, expectedRevision: nil)
    }
}

public protocol SettingsHosting: Sendable {
    func settings() async throws -> JSONValue
    func updateSettings(namespace: String, patch: JSONValue, expectedRevision: Int?) async throws
    func replaceSettings(namespace: String, section: JSONValue, expectedRevision: Int?) async throws
    func describeCredentials(refs: [JSONValue]) async throws -> JSONValue
    func setCredential(ref: JSONValue, value: String) async throws
    func unsetCredential(ref: JSONValue) async throws
}

public extension SettingsHosting {
    func updateSettings(namespace: String, patch: JSONValue) async throws {
        try await updateSettings(namespace: namespace, patch: patch, expectedRevision: nil)
    }

    func replaceSettings(namespace: String, section: JSONValue) async throws {
        try await replaceSettings(namespace: namespace, section: section, expectedRevision: nil)
    }
}

public protocol FilesHosting: Sendable {
    func workspaceFiles(scopeId: String, path: String) async throws -> JSONValue
    func workspaceFileRead(scopeId: String, path: String, range: JSONValue?) async throws -> JSONValue
    func workspaceFileStat(scopeId: String, path: String) async throws -> JSONValue
    func workspaceChanges(scopeId: String) async -> AsyncThrowingStream<JSONValue, any Error>
    func workspaceFileReadBytes(scopeId: String, path: String, offset: Int, length: Int) async throws -> JSONValue
}

public extension FilesHosting {
    func workspaceFileRead(scopeId: String, path: String) async throws -> JSONValue {
        try await workspaceFileRead(scopeId: scopeId, path: path, range: nil)
    }
}

public protocol DirectoryHosting: Sendable {
    func directoryListing(path: String?) async throws -> HostDirectoryListing
    func createDirectory(parent: String, name: String) async throws -> String
}

public extension DirectoryHosting {
    func directoryListing() async throws -> HostDirectoryListing {
        try await directoryListing(path: nil)
    }
}

extension DSHClient: ChatHosting {}
extension DSHClient: SettingsHosting {}
extension DSHClient: FilesHosting {}
extension DSHClient: DirectoryHosting {}

public protocol ActivityHosting: Sendable {
    func activityRoster() async throws -> ActivityRoster
    func jobKill(sessionId: String, jobId: String) async throws -> JobKillValue
    func subagentInterrupt(childSessionId: String, parentSessionId: String) async throws -> SubagentInterruptValue
    func jobFollow(sessionId: String?, jobId: String, from: Int?) async -> AsyncThrowingStream<JobFollowFrame, any Error>
    func jobList(sessionId: String) async -> AsyncThrowingStream<JobListFrame, any Error>
}

public extension ActivityHosting {
    func jobFollow(sessionId: String?, jobId: String) async -> AsyncThrowingStream<JobFollowFrame, any Error> {
        await jobFollow(sessionId: sessionId, jobId: jobId, from: nil)
    }
}

extension DSHClient: ActivityHosting {}

public protocol GitHosting: Sendable {
    func status(cwd: String) async throws -> GitStatus
    func diff(cwd: String, path: String, staged: Bool) async throws -> GitPatch
    func log(cwd: String, skip: Int, limit: Int) async throws -> GitLogPage
    func show(cwd: String, sha: String) async throws -> GitCommitDetail
    func show(cwd: String, sha: String, path: String) async throws -> GitPatch
    func file(cwd: String, rev: String, path: String) async throws -> GitFileAtRevision
}

public extension GitHosting {
    func diff(cwd: String, path: String) async throws -> GitPatch {
        try await diff(cwd: cwd, path: path, staged: false)
    }

    func log(cwd: String) async throws -> GitLogPage {
        try await log(cwd: cwd, skip: 0, limit: 20)
    }

    func log(cwd: String, skip: Int) async throws -> GitLogPage {
        try await log(cwd: cwd, skip: skip, limit: 20)
    }
}

extension GitClient: GitHosting {}

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
    var historyFoldEnabled: Bool { get }
    /// 概要 v2 能力（`history-fold-summary-v2`）：首屏按轮取讲话 + 概要 + 回答。
    var historySummaryFoldEnabled: Bool { get }
    var historyCoverageEnabled: Bool { get }
    /// 连接器是否声明了 `history-window`；没有时取页必须走 `session/page`。
    var supportsExactHistoryWindow: Bool { get }
    func sessionPage(_ request: SessionPageRequest) async throws -> SessionPage
    func sessionFind(_ request: HistorySearchRequest) async throws -> HistorySearchValue
    func follow(_ request: SessionFollowRequest) async -> AsyncThrowingStream<SessionFollowFrame, any Error>
    func prompt(_ request: SessionPromptRequest) async throws
    /// 宿主的排队控制流（`session/control`）；旧连接器没有它，订阅会失败。
    func sessionControlFrames() async -> AsyncThrowingStream<SessionControlFrame, any Error>
    /// 改/撤/插一条排队输入（`session/updateQueue`）。
    func updateQueue(sessionId: String, itemId: String, action: QueueAction) async throws
    func cancel(sessionId: String) async throws
    func rename(sessionId: String, title: String) async throws
    func forkSession(sessionId: String, atSeq: Int?) async throws -> JSONValue
    func selectModel(sessionId: String, selection: ModelSelection) async throws
    func modelCatalog() async throws -> ModelCatalog
    func fileReferences(agentId: String, query: String) async throws -> [FileReferenceCandidate]
    func updateSettings(namespace: String, patch: JSONValue, expectedRevision: Int?) async throws
    func attachment(sessionId: String, attachmentId: String) async throws -> JSONValue
}

/// 排队控制不可用（旧连接器没有 `session/control` / `session/updateQueue`）。
struct SessionQueueUnavailable: Error, Sendable, Equatable {
    init() {}
    var description: String { "the connector does not support queued input control" }
}

public extension ChatHosting {
    /// 默认实现：没有控制流的连接器返回空流（UI 退回“只显示本地乐观队列”）。
    func sessionControlFrames() async -> AsyncThrowingStream<SessionControlFrame, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// 默认实现：明确报不支持，调用方据此回退本地乐观队列。
    func updateQueue(sessionId: String, itemId: String, action: QueueAction) async throws {
        throw SessionQueueUnavailable()
    }

    /// 老连接器（不认识 v2 能力）默认没有它：所有调用方照旧走 v1 / 原事件。
    var historySummaryFoldEnabled: Bool { false }

    /// 本连接该用哪种 `fold`：v2 > v1 > 不折。单一判定点，调用方不各写一遍。
    var historyFoldMode: HistoryWindowFold? {
        if historySummaryFoldEnabled { return .summary }
        if historyFoldEnabled { return .v1 }
        return nil
    }

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

extension DSHClient: HostClient {}
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
    func jobFollow(jobId: String) async -> AsyncThrowingStream<JobFollowFrame, any Error> {
        await jobFollow(sessionId: nil, jobId: jobId, from: nil)
    }

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

/// 链路门面（`LinkGateway`）用到的宿主能力。
public protocol GatewayHosting: Sendable {
    func hostEvents() async -> AsyncThrowingStream<HostEvent, any Error>
    func answer(_ result: EventAnswer) async throws
    func sessionDigest(since: String?) async throws -> SessionListValue
    /// 连接器自答的目录清单（在电脑本机补过 `mtimeMs`）。与 `sessionDigest` 归同一个协议：
    /// 自答方法的归宿是链路门面；`FilesHosting` **不含**它，Domain 不许绕过门面直连。
    func dirListing(scopeId: String, path: String, root: String) async throws -> JSONValue
    func archiveSession(_ sessionId: String, archived: Bool) async throws -> [String]
    func createWorkspace(path: String) async throws -> WorkspaceCreateValue
    func deleteWorkspace(id: String) async throws
    func createSession(_ request: SessionCreateRequest) async throws -> JSONValue
    func workspaces(timeout: Duration) async throws -> WorkspaceBaseline
    /// 工作区/归档的实时帧：baseline 播种，change 增量。
    func workspaceFrames() async -> AsyncThrowingStream<WorkspaceFrame, any Error>
    func linkHandshake(client: LinkHandshakeRequest) async throws -> LinkHandshake
    func pushDiagnostics(_ request: LinkDiagnosticsRequest) async throws -> LinkDiagnosticsAck
}

/// 连接适配器持有的宿主对象：六个按域切开的协议 + 链路门面。
/// App/Domain 只拿其中一段，不拿这个全量类型。
public extension GatewayHosting {
    func workspaceFrames() async -> AsyncThrowingStream<WorkspaceFrame, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func workspaces() async throws -> WorkspaceBaseline {
        try await workspaces(timeout: .seconds(15))
    }
}

public protocol HostClient: ChatHosting, SettingsHosting, FilesHosting, DirectoryHosting,
    ActivityHosting, GatewayHosting, Sendable {
    var carrier: any DSHCarrier { get }
    var capabilities: Set<String> { get }
}

public enum HostClientFactory {
    public static let sessionDigestCapability = "session-digest"
    /// 连接器能答 `_link/dirListing`（目录条目带本机 mtime）。没有它就走 `workspaceFiles/list`，
    /// 文件页与升级前逐屏一致——只是不显示时间，不报错。
    public static let dirMtimesCapability = "dir-mtimes"
    public static let jobsRosterMethod = "_link/jobRoster"

    public static func make(carrier: any DSHCarrier,
                            capabilities: Set<String> = []) -> any HostClient {
        DSHClient(carrier: carrier, capabilities: capabilities)
    }
}

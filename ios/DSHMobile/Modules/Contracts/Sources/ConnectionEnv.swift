import DSHKit
import Foundation
import Observation

/// 界面读连接状态的唯一入口。
///
/// 为什么不直接 `@Environment(ConnectionStore.self)`：那会让每个 UI target 依赖
/// `DSHConnectionDomain`（具体实现）。`ConnectionEnv` 在契约层，持有 `any LinkService`，
/// 把连接状态以转发属性暴露给 SwiftUI；`@Observable` 的观察链在转发层仍然成立
/// （读 `env.state` 会读到 `ConnectionStore.state` 的 observation registrar）。
@MainActor
@Observable
public final class ConnectionEnv: LinkService {

    private let service: any LinkService

    public init(_ service: any LinkService) {
        self.service = service
    }

    public var profiles: [ConnectionProfile] { service.profiles }
    public var activeProfile: ConnectionProfile? { service.activeProfile }
    public var state: ConnectionState { service.state }
    public var lastError: String? { service.lastError }
    public var capabilities: Set<String> { service.capabilities }
    public var connectorVersion: String? { service.connectorVersion }
    public var hostVersion: String? { service.hostVersion }
    public var hostHome: String? {
        get { service.hostHome }
        set { service.hostHome = newValue }
    }
    public var activeBaseURL: URL? { service.activeBaseURL }
    public var scopeId: String? { service.scopeId }
    public var chatHost: (any ChatHosting)? { service.chatHost }
    public var settingsHost: (any SettingsHosting)? { service.settingsHost }
    public var filesHost: (any FilesHosting)? { service.filesHost }
    public var directoryHost: (any DirectoryHosting)? { service.directoryHost }
    public var activityHost: (any ActivityHosting)? { service.activityHost }
    public var gitHost: (any GitHosting)? { service.gitHost }
    public var link: LinkGateway { service.link }
    public var supportsFileTransfer: Bool { service.supportsFileTransfer }
    public var showsOutdatedConnectorNotice: Bool { service.showsOutdatedConnectorNotice }

    public func dismissOutdatedConnectorNotice() { service.dismissOutdatedConnectorNotice() }
    public func noteFirstRender() async { await service.noteFirstRender() }
    public func accountStateStream() async -> AsyncStream<[String]> { await service.accountStateStream() }
    public func supports(_ capability: String) -> Bool { service.supports(capability) }
    public func uploadFile(fileURL: URL, name: String, sessionId: String) async throws -> StagedFile {
        try await service.uploadFile(fileURL: fileURL, name: name, sessionId: sessionId)
    }
    public func fileTransferTarget() throws -> (relayURL: URL, deviceToken: String) {
        try service.fileTransferTarget()
    }
}

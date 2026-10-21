import DSHKit
import Foundation

/// 连接服务的抽象（契约 C3/C6）：Core 与其它单元只依赖这个协议，
/// 不依赖 DSHConnectionDomain 的具体实现 `ConnectionStore`。
///
/// 为什么放纯协议层：Core（L2）要拿连接状态、要让别人能注入假实现，
/// 不能反过来依赖功能单元的实现 target。
/// 只读连接状态与宿主能力：UI 与只读模型依赖这一段。
@MainActor
public protocol ConnectionStatus: AnyObject {
    var profiles: [ConnectionProfile] { get }
    var activeProfile: ConnectionProfile? { get }
    var state: ConnectionState { get }
    var lastError: String? { get }
    var capabilities: Set<String> { get }
    var connectorVersion: String? { get }
    var hostVersion: String? { get }
    var hostHome: String? { get set }
    var activeBaseURL: URL? { get }
    var scopeId: String? { get }
    var chatHost: (any ChatHosting)? { get }
    var settingsHost: (any SettingsHosting)? { get }
    var filesHost: (any FilesHosting)? { get }
    var directoryHost: (any DirectoryHosting)? { get }
    var activityHost: (any ActivityHosting)? { get }
    var gitHost: (any GitHosting)? { get }
    func supports(_ capability: String) -> Bool
    var showsOutdatedConnectorNotice: Bool { get }
    func dismissOutdatedConnectorNotice()
    func noteFirstRender() async
}

public extension ConnectionStatus {
    var isConnected: Bool { state.isConnected }
    var isConnecting: Bool { state.isConnecting }
    var showsOutdatedConnectorNotice: Bool { false }
    func dismissOutdatedConnectorNotice() {}
    func noteFirstRender() async {}
}

/// 链路门面：需要发事件应答、读 relay 身份的模型依赖这一段。
@MainActor
public protocol ConnectionLink: AnyObject {
    var link: LinkGateway { get }
}

/// 文件下载目标：文件浏览器依赖这一段。
@MainActor
public protocol FileTransferring: AnyObject {
    func fileTransferTarget() throws -> (relayURL: URL, deviceToken: String)
}

/// 文件上传：只有发送路径依赖这一段。
@MainActor
public protocol FileUploading: AnyObject {
    func uploadFile(fileURL: URL, name: String, sessionId: String) async throws -> StagedFile
}

/// 账户级状态变化（032）。
@MainActor
public protocol AccountStateStreaming: AnyObject {
    func accountStateStream() async -> AsyncStream<[String]>
}

/// 完整连接服务：Core/App 的装配与需要上传/账户流的模型依赖它。
/// UI 只依赖 ConnectionStatus（必要时加 ConnectionLink / FileTransferring）。
@MainActor
public protocol LinkService: ConnectionStatus, ConnectionLink, FileTransferring, FileUploading, AccountStateStreaming {}

/// 连接错误文案（原 ConnectionStore.describe，025/026 下沉到协议层供全部单元共用）。
public enum LinkErrors {
    /// The relay and connector already speak in codes; showing those raw is how
    /// "DSh 响应格式异常：中转没有返回落盘路径" ended up in front of a user. Every
    /// branch below answers "what happened, and what can I do" — and the last one
    /// deliberately keeps the original wording rather than flattening an unknown
    /// failure into a generic sentence.
public static func describe(_ error: any Error) -> String {
        if let failure = error as? DSHRPCFailure {
            switch failure.code {
            case "file/unsupported":
                // 连接器没有桥接帧（版本旧）：relay 已经在给这个语义，这里与
                // `RelayFileTransfer.Unavailable.connectorTooOld` 共用同一条文案键。
                return String(localized: "电脑上的连接器版本过旧，请更新后重发")
            case "host/offline":
                return String(localized: "电脑上的连接器不在线，请确认电脑开着 DSH 后再试")
            case "auth/invalid-token", "auth/unauthorized":
                return String(localized: "这个连接的凭据已失效，请重新配对")
            // 配对失败原来只有一句"配对码无效、已用或过期"，用户没法判断是打错了
            // 还是拿着屏幕上那张旧码又扫了一次。中转现在把三种原因分开报（`pair/...`），
            // 这里各给一句话，而且都说清下一步：回电脑刷新二维码页。
            case "pair/used-code":
                return String(localized: "这个配对码已经用过了，请在电脑「移动端连接」里点「换一张」，再扫新出现的那张")
            case "pair/expired-code":
                return String(localized: "这个配对码已经过期，请在电脑「移动端连接」里点「换一张」，再扫新出现的那张")
            case "pair/invalid-code":
                return String(localized: "配对码不对，请核对电脑上显示的配对码")
            default:
                break
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut:
                return String(localized: "网络超时，可以再点一次发送")
            case .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dataNotAllowed:
                return String(localized: "网络中断，可以再点一次发送")
            default:
                break
            }
        }
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

import DSHKit
import Foundation

/// 连接服务的抽象（契约 C3/C6）：Core 与其它单元只依赖这个协议，
/// 不依赖 DSHConnectionDomain 的具体实现 `ConnectionStore`。
///
/// 为什么放纯协议层：Core（L2）要拿连接状态、要让别人能注入假实现，
/// 不能反过来依赖功能单元的实现 target。
@MainActor
public protocol LinkService: AnyObject {
    /// 已保存的连接方式列表。
    var profiles: [ConnectionProfile] { get }
    /// 当前选中的连接方式。
    var activeProfile: ConnectionProfile? { get }
    /// 当前连接状态（UI 穷举展示）。
    var state: ConnectionState { get }
    /// 最近一次错误（用户可读）。
    var lastError: String? { get }
    /// 对端能力集（如文件传输）。
    var capabilities: Set<String> { get }
    /// 连接器版本号。
    var connectorVersion: String? { get }
    /// 对端家目录（路径缩写用）。
    var hostHome: String? { get set }
    /// 当前连接的基地址。
    var activeBaseURL: URL? { get }
    /// 本机标识（host 侧会话归档键）。
    var scopeId: String? { get }
    /// 底层客户端（协议细节操作走它）。
    var client: DSHClient? { get }
    /// 链路门面（读状态、发事件应答）。
    var link: LinkGateway { get }
    /// 账户级状态变化（032）：给出变了的 key；值要去 `/account/state` 拉。
    func accountStateStream() async -> AsyncStream<[String]>

    /// 能力探测：对端是否支持某个能力 id。
    func supports(_ capability: String) -> Bool
    /// 经中转上传一个文件。
    func uploadFile(fileURL: URL, name: String, sessionId: String) async throws -> StagedFile
    /// 文件传输目标（中转地址 + 设备令牌）。
    func fileTransferTarget() throws -> (relayURL: URL, deviceToken: String)
}

public extension LinkService {
    var isConnected: Bool { state.isConnected }
    var isConnecting: Bool { state.isConnecting }
}

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

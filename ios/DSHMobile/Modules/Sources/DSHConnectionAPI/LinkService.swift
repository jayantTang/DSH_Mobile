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

    /// 能力探测：对端是否支持某个能力 id。
    func supports(_ capability: String) -> Bool
}

public extension LinkService {
    var isConnected: Bool { state.isConnected }
    var isConnecting: Bool { state.isConnecting }
}

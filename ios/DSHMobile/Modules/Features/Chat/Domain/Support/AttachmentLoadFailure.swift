import Foundation
import DSHKit

/// 一次取图失败的原因分类（设计 §5 B2）。
///
/// 这是**唯一**的失败分类：界面文案、diagnostics 的 `error` 短码、以及"链路是否还没就绪"
/// 的判定都从这里派生，不再在别处写第二串字符串。
///
/// `category` 只产出稳定短码（英文、无空格），是给设备日志用的；`displayText` 是给用户
/// 看的那一句。日志**只**发 `category`，不发 `displayText`、不发文件名 / URL / 正文。
public enum AttachmentLoadFailure: Equatable, Sendable {
    /// 链路根本没连上（宿主不可达 / 还没握手）。
    case notConnected
    /// 网络不可达（DNS、路由、超时前的连接失败）。
    case unreachable
    /// 连接在请求中途被关掉。
    case carrierClosed
    /// 请求超时。
    case timedOut
    /// 宿主回了非 2xx。
    case http(Int)
    /// 凭据无效（需要重新配对）。
    case notAuthenticated
    /// 响应形状不对（缺字段、不是 JSON、字节无法 base64 解码）。
    case malformed
    /// 字节不是可显示的图片。
    case decode
    case unknown

    /// 设备日志里的稳定短码（"只增"的事件词表用它）。
    public var category: String {
        switch self {
        case .notConnected: return "not-connected"
        case .unreachable: return "unreachable"
        case .carrierClosed: return "carrier-closed"
        case .timedOut: return "timed-out"
        case .http(let status): return "http-\(status)"
        case .notAuthenticated: return "not-authenticated"
        case .malformed: return "malformed"
        case .decode: return "decode"
        case .unknown: return "unknown"
        }
    }

    /// 界面上那一句（失败态的可读原因；重试入口由视图给）。
    public var displayText: String {
        switch self {
        case .notConnected: return String(localized: "未连接")
        case .unreachable: return String(localized: "网络不通")
        case .carrierClosed: return String(localized: "连接被断开")
        case .timedOut: return String(localized: "请求超时")
        case .http(let status): return String(localized: "服务器返回了 \(status)")
        case .notAuthenticated: return String(localized: "需要重新配对电脑")
        case .malformed: return String(localized: "返回的字节无法解码")
        case .decode: return String(localized: "字节不是可显示的图片")
        case .unknown: return String(localized: "图片加载失败")
        }
    }

    /// 链路不在 = 界面该继续转圈、等链路回来再试（不是"请求有错"）。
    public var isLinkNotReady: Bool {
        switch self {
        case .notConnected, .unreachable, .carrierClosed: return true
        case .timedOut, .http, .notAuthenticated, .malformed, .decode, .unknown: return false
        }
    }

    /// 传输层错误的映射（`DSHTransportError` 的每个 case 都在这里，没有第二处 `if`）。
    public static func from(_ error: any Error) -> AttachmentLoadFailure {
        guard let transport = error as? DSHTransportError else {
            return .unknown
        }
        switch transport {
        case .notConnected: return .notConnected
        case .unreachable: return .unreachable
        case .carrierClosed: return .carrierClosed
        case .timedOut: return .timedOut
        case .httpStatus(let status, _): return .http(status)
        case .notAuthenticated: return .notAuthenticated
        case .malformedResponse: return .malformed
        case .streamFailed:
            // 流在跑起来之后失败：连接层面的问题，与"响应形状不对"不同。
            return .carrierClosed
        }
    }
}

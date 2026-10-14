import Foundation
import RelayKit

/// 经中转的后台文件传输**适配器**（spec 023 边界收敛）。
///
/// 为什么单独一个文件：`RelayFileTransfer` 属于 RelayKit（它反过来依赖 DSHKit，所以 DSHKit
/// 里包不了它），而产品路径不该出现 RelayKit 的类型名。这层皮只做转发与形状转换，
/// 让 `WorkspaceFilesModel` 拿到 App 自己的值类型。
///
/// 它是守卫白名单文件之一（≤8）：白名单就是给这种"必须碰实现层"的适配器准备的。
enum FileTransferAdapter {

    /// 下载结果（App 自己的形状，不带 RelayKit 类型）。
    struct Downloaded {
        let url: URL
        let bytes: Int
    }

    /// 后台会话的身份（系统唤醒时用它判断事件是不是我们的）。
    static var sessionIdentifier: String { RelayFileTransfer.sessionIdentifier }

    /// 冷启动时把后台会话重新挂上（只建会话、不发请求）。
    static func reassociate() { _ = RelayFileTransfer.reassociate() }

    /// 注入 RelayKit 的日志出口（它自己没有 logger）。
    static func setLogger(_ sink: (@Sendable (String) -> Void)?) {
        RelayFileTransfer.BackgroundEvents.setLogger(sink)
    }

    /// 交付系统给的后台事件完成回调。
    static func setHandler(_ action: (() -> Void)?) {
        RelayFileTransfer.BackgroundEvents.setHandler(action)
    }

    /// 经中转把工作区文件拉到 `destination`（后台 `URLSession` 任务，进程挂起也能完成）。
    static func download(
        to destination: URL,
        scopeId: String,
        path: String,
        version: String,
        target: (relayURL: URL, deviceToken: String),
        expectedBytes: Int?,
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> Downloaded {
        let transfer = RelayFileTransfer(relayURL: target.relayURL, deviceToken: target.deviceToken)
        let fetched = try await transfer.download(
            scopeId: scopeId,
            path: path,
            to: destination,
            version: version,
            expectedBytes: expectedBytes,
            bid: UUID().uuidString,
            onProgress: onProgress
        )
        return Downloaded(url: fetched.url, bytes: fetched.bytes)
    }
}

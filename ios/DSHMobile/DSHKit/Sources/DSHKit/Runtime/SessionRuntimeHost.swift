import Foundation

/// 门面的实现体：**不导出**。
///
/// 为什么不导出：App 要的是"一个入口"，不是"一个可以顺手摸的类型"。实现体留在 `internal`，
/// App 就只能拿 `any SessionRuntime`——它既没法向下转型到实现层，也就没法绕开门面。
/// 这是 SC-003（App 不得直接使用实现层）的机制保证，不是风格偏好。
///
/// 依赖全部注入（宪法 VII.1）：这一层不读全局单例、不读环境变量、不自己拨号。
@MainActor
final class SessionRuntimeHost: SessionRuntime {

    /// 传输状态的来源。骨架阶段由调用方提供（App 侧的适配文件把今天的链接状态包装成闭包）；
    /// S2 把 `LinkSupervisor` 搬进来之后，这里会换成由门面自己持有的监管对象。
    private let transportProvider: @MainActor () -> TransportStateSnapshot

    init(transport: @escaping @MainActor () -> TransportStateSnapshot) {
        self.transportProvider = transport
    }

    var transport: TransportStateSnapshot { transportProvider() }
}

/// App 构造门面的**唯一**入口。
///
/// 工厂是 public、实现体是 internal：这样 App 侧的白名单适配文件里只会出现门面与只读模型的
/// 名字，不会出现 `SessionRuntimeHost`（守住 contracts/session-runtime.md §0 的第 4 条）。
///
/// - Parameter transport: 传回当前传输状态。骨架阶段由调用方提供；S2 之后这个参数会消失，
///   改由门面内部持有 `LinkSupervisor` 并从注入的拨号面推导。
@MainActor
public func makeSessionRuntime(
    transport: @escaping @MainActor () -> TransportStateSnapshot
) -> any SessionRuntime {
    SessionRuntimeHost(transport: transport)
}

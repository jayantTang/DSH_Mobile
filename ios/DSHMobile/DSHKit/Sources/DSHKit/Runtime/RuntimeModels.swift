import Foundation

/// 门面的只读模型：视图可以直接渲染的不可变快照。
///
/// 纪律（`specs/023-app-dshkit-boundary/contracts/session-runtime.md` §0）：
///
///   * 值类型、`Sendable`、**没有方法**——视图不得经由模型反向调用门面；
///   * 不得持有 `DSHClient` / `MessageStore` / 管道 / carrier 的引用；
///   * 不得携带可变集合。
///
/// 这个文件是 Runtime 组里唯一的"数据出口"：门面的每个能力都产出这里定义（或已升格）的类型，
/// 而不是把实现层的类型透出去。
public struct TransportStateSnapshot: Sendable, Equatable {

    /// 传输层处在哪一档。命名沿用 `LinkSupervisor` 的状态机（data-model E4）。
    public enum Phase: String, Sendable, Equatable {
        case idle
        case dialing
        case connected
        case backoff
    }

    /// 当前档位。
    public let phase: Phase

    /// 退避级别。**只有稳定存活超过阈值才清零**（022 的裁定，不得回退）。
    public let backoffLevel: Int

    /// 连接器上报的协议版本；`nil` = 还没握手。
    public let connectorVersion: Int?

    /// 版本兼容判定结果。判定只有一份（在 DSHKit 侧），App 只读它产出的提示。
    public let isConnectorSupported: Bool

    public init(
        phase: Phase = .idle,
        backoffLevel: Int = 0,
        connectorVersion: Int? = nil,
        isConnectorSupported: Bool = true
    ) {
        self.phase = phase
        self.backoffLevel = backoffLevel
        self.connectorVersion = connectorVersion
        self.isConnectorSupported = isConnectorSupported
    }
}

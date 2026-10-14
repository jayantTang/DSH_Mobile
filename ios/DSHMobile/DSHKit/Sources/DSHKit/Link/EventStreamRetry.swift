import Foundation

/// 宿主**事件流**断开后重新订阅的节奏（spec 023 边界收敛：从 `HostEventHub` 抽出的策略）。
///
/// ## 与连接退避的区别（这是它单独存在的理由）
///
/// 这条重试**不拨号**：它只是重新订阅一个已经存在的链路（`client.hostEvents()`），所以每次尝试
/// 都便宜得多，节奏也就该更密——`0.5s × 次数`，封顶 8 秒。连接的退避（`ReconnectBackoff`）
/// 面对的是"拨一条新 socket"，那边是 1s 起步、倍增、封顶 30s。
///
/// **2026-10-14 记一笔**：这段计算原来写在 App 的 `HostEventHub.start` 里（`min(8, 0.5 * attempt)`），
/// 是这个仓库里**第三个**重试节奏（另两个是 `LinkCarrier.ReconnectPolicy` 与 `ConnectionStore`
/// 驱动的 `LinkSupervisor`）。它不拨号，所以不违反 022「一个 socket 一个所有者」的结论；
/// 但"节奏散落三处"本身是漂移风险，所以先把**计算**收进这里、配单测，
/// 要不要并入统一的退避另外再议（改了就会改变用户看到的恢复速度）。
public enum EventStreamRetry {

    /// 单次等待的上限。
    public static let maximumDelay: TimeInterval = 8

    /// 每次尝试之间的固定增量（线性，不是倍增）。
    public static let step: TimeInterval = 0.5

    /// 第 `attempt` 次失败之后该等多久（`attempt` 从 1 开始）。
    ///
    /// - Parameter attempt: 第几次失败；小于 1 视为 1（第一次失败也要等一个 step，不空转）。
    public static func delay(afterAttempt attempt: Int) -> TimeInterval {
        min(maximumDelay, step * Double(max(1, attempt)))
    }
}

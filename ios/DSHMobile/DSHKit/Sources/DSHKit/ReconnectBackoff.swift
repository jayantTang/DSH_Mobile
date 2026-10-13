import Foundation

/// 重连退避：**只按链路存活时长清零**（spec 022 FR-001）。
///
/// 为什么不是"连上就清零"：2026-10-13 真机风暴里每个 socket 只活约 0.8 秒，`attempt` 每次都被
/// 连上的那一刻归零，于是延迟永远停在 `base`，稳定每秒重连一次、两分钟内接入 111 次。
///
/// 为什么也不是"某次调用成功就清零"：风暴现场数据里**确实有成功调用**（同一批 `ok=true` 的
/// 请求与失败请求交错），按成功清零循环依旧。所以要按**存活时长**判断：只有连续存活到
/// `stabilityWindow` 的连接才算"链路真的好了"。
///
/// 纯值类型，无并发与 IO，方便在 DSHKit 单测里把边界钉死。
public struct ReconnectBackoff: Sendable, Equatable {
    /// 连接至少活这么久才算稳定（`<` 不清零）。
    public static let stabilityWindow: TimeInterval = 15

    public let base: TimeInterval
    public let multiplier: Double
    public let cap: TimeInterval

    /// 连续失败轮次（0 = 下一轮用最小延迟）。
    public private(set) var attempt: Int

    /// 默认值与 `LinkCarrier` 的 `ReconnectPolicy` **同一形状**（1 秒起步、倍增、封顶 30 秒）：
    /// 重连现在只有一个所有者，两边不该有两套节奏。原来的线性 `0.6 × (attempt+1)` 在 120 秒里
    /// 仍会重连 18 次，达不到 SC-001 的"≤8 次"。
    public init(base: TimeInterval = 1, multiplier: Double = 2, cap: TimeInterval = 30) {
        self.base = base
        self.multiplier = multiplier
        self.cap = cap
        self.attempt = 0
    }

    /// 下一次重连前应等多久。
    public var nextDelay: TimeInterval {
        min(cap, base * pow(multiplier, Double(attempt)))
    }

    /// 记录一条连接结束。
    ///
    /// - Parameter livedFor: 这条连接从建立到结束活了多少秒。
    /// - Returns: 这次结束是否把退避清零了（供诊断记录）。
    @discardableResult
    public mutating func noteConnectionEnded(livedFor: TimeInterval) -> Bool {
        if livedFor >= Self.stabilityWindow {
            attempt = 0
            return true
        }
        attempt += 1
        return false
    }

    /// 显式清零：用户主动动作、回到前台、主动断开（spec 022 FR-002）。
    public mutating func reset() {
        attempt = 0
    }
}

import Foundation

/// 连接监管的**状态机**（spec 023 FR-004 / data-model E4）：什么时候探活、几次失败才判"断了"、
/// 拨号之间该等多久。App 侧只负责执行它给出的结论（睡、探、拨）。
///
/// ## 为什么要有它
///
/// 2026-10-13 的连接风暴复盘（spec 022）里，根因之一是"两台重连机器在抢同一个 socket"，
/// 另一条是**判断散落在 App 里**：探活节拍、几次算失败、退避什么时候清零，都写在一个
/// `while` 循环的中间，除了跑真机没有别的验证手段。把这三条判断抽出来之后，
/// 它们变成纯函数，可以在 macOS 上 `swift test`（本文件同目录的 `ReconnectBackoff`
/// 已经是这样了——本类型只是把剩下的判断也收进来）。
///
/// ## 口径（照搬 022 的结论，不改语义）
///
/// * **已连接走慢心跳、未连接走快探活**：链路上没活物时要早发现，链路好的时候别打扰它；
/// * **单次探活失败不改判**：链路抖一下不该让界面闪"重连中"；连续 `failuresToDeclareDown`
///   次失败才判；
/// * **退避只在"活得够久"之后清零**：0.8 秒就掉线的连接不算稳定，延迟必须逐次增长
///   （否则就是每秒一次的接入风暴）。
public struct LinkSupervisor: Sendable, Equatable {

    public struct Policy: Sendable, Equatable {
        /// 已连接时的探活周期。
        public var heartbeat: TimeInterval
        /// 未连接时的探活周期（等 carrier 自愈回来）。
        ///
        /// 默认 **2 秒**——与搬迁前 App 里的 `recoveryProbe` 常量一致（不是"顺手调优"：
        /// 搬迁不许改行为，要调另开任务）。
        public var recoveryProbe: TimeInterval
        /// 连续几次探活失败才判"链路已断"。
        public var failuresToDeclareDown: Int
        public var backoff: ReconnectBackoff

        public init(heartbeat: TimeInterval = 20,
                    recoveryProbe: TimeInterval = 2,
                    failuresToDeclareDown: Int = 2,
                    backoff: ReconnectBackoff = ReconnectBackoff()) {
            self.heartbeat = heartbeat
            self.recoveryProbe = recoveryProbe
            self.failuresToDeclareDown = failuresToDeclareDown
            self.backoff = backoff
        }

        public static let `default` = Policy()
    }

    /// 一次探活之后该做什么。
    public enum ProbeVerdict: Sendable, Equatable {
        /// 成功，或失败次数还没到阈值：保持现状。
        case unchanged
        /// 连续失败到阈值：判"链路已断"。
        case declareDown
    }

    public let policy: Policy
    private var backoff: ReconnectBackoff
    private var probeFailures = 0

    public init(policy: Policy = .default) {
        self.policy = policy
        self.backoff = policy.backoff
        self.probeFailures = 0
    }

    // MARK: - 探活

    /// 探活节拍：链路上有活物（已连接）时慢，没有时快。
    public func probeInterval(isConnected: Bool) -> TimeInterval {
        isConnected ? policy.heartbeat : policy.recoveryProbe
    }

    /// 记一次探活结果，给出"要不要判链路已断"。
    ///
    /// 成功即清零失败计数（连续两次的语义：中间成功一次就重新数）。
    public mutating func noteProbe(ok: Bool) -> ProbeVerdict {
        guard !ok else {
            probeFailures = 0
            return .unchanged
        }
        probeFailures += 1
        return probeFailures >= policy.failuresToDeclareDown ? .declareDown : .unchanged
    }

    /// 当前累计的连续探活失败次数（诊断用）。
    public var consecutiveProbeFailures: Int { probeFailures }

    /// 探活恢复成功（同一 carrier 自愈）后调用：把失败计数清掉。
    public mutating func noteProbeRecovered() { probeFailures = 0 }

    // MARK: - 拨号与退避

    /// 上一条链路结束了：把"活了多久"交给退避，返回**下一次拨号前应等多久**。
    ///
    /// 活得够久（`ReconnectBackoff.stabilityWindow`）才清零；否则逐次增长。
    public mutating func noteLinkEnded(livedFor: TimeInterval) -> TimeInterval {
        backoff.noteConnectionEnded(livedFor: livedFor)
        return backoff.nextDelay
    }

    /// 下一次拨号前应等多久（**只读**，不推进退避）。
    ///
    /// 与 `noteLinkEnded` 的分工要看清楚——App 的循环是"上一条链路刚结束 → 先记它活了多久 →
    /// 再取这次的延迟"：
    ///
    /// ```swift
    /// if let connectedAt { _ = supervisor.noteLinkEnded(livedFor: now - connectedAt) }  // 推进
    /// let delay = supervisor.nextDelay                                                   // 不推进
    /// ```
    ///
    /// 两次都用 `noteLinkEnded` 会把退避推进两档（第一次失败本该等 2 秒，会变成 4 秒）。
    public var nextDelay: TimeInterval { backoff.nextDelay }

    /// 当前退避级别（0 = 下一次用最小延迟）。诊断用。
    public var attempt: Int { backoff.attempt }

    /// 用户主动动作、回到前台、主动断开：退避清零（022 FR-002：这类动作不等退避）。
    public mutating func reset() {
        backoff.reset()
        probeFailures = 0
    }

    /// 拨号当前是否应当发起。`isDialing` 为真表示已有在飞拨号——
    /// 调用方应当**合流**而不是另起一拨（022 US3：同目标的在飞拨号直接复用）。
    public func shouldDial(isDialing: Bool) -> Bool { !isDialing }
}

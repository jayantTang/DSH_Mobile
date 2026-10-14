import Foundation

/// 转写窗口的**策略层**：什么该丢、丢多少，全部在这里决定；UIKit 那一侧只负责量尺寸、
/// 应用 offset 与画出来。
///
/// ## 它替代了什么
///
/// 到 2026-10-14 为止，"窗口"这件事在仓库里有四处实现（spec 023 的 S1 目标是把策略收敛到一处）：
///
/// | 位置 | 形态 | 本次处置 |
/// |---|---|---|
/// | `DSHKit/ViewportBandPlanner` | 按行数带挑回收/水合候选 | **已经是策略层**，保留 |
/// | `DSHKit/TranscriptPayloadBudget.rowsToReclaim` | 按字节从两端收 | **生产代码无人调用**（只有它自己的单测），见下方「已知遗留」 |
/// | App `ChatModel.rowsToDropForBudget` | 按字节从最老端真丢，返回行数 | **搬到这里**（`rowsToDrop`） |
/// | App `TranscriptListHost.dropOldest/prepend` | 量锚点位移并改 `contentOffset` | 留原地：这是 UIKit 的"应用"，不是策略 |
///
/// ## 口径（照搬，不改语义）
///
/// * 只在总量 **超过** 预算时才丢（等于预算不丢）；
/// * 只从**最老端**数，够了就停；
/// * 保留带 `keep = keepLast ?? min(120, max(20, 行数/4))`——写死 120 会让"窗口本来就小"时
///   丢弃整条路走不通（2026-10-08 实测：54 行窗口 + 4KB 预算时一次都没触发）；
/// * 最多丢到只剩保留带。
///
/// ## 已知遗留（S1 记账，待 owner 拍板）
///
/// `TranscriptPayloadBudget.rowsToReclaim` 是**死代码**：它按字节从两端挑"回收"的 id，
/// 而真机上跑的是 `ViewportBandPlanner`（按行数带）+ 本文件（按字节丢最老端）。
/// 两条路语义不同（回收=换占位载荷、保留行；丢弃=真移除行），不能简单合并：
/// 要么把它接进回收路径（等于改 008 已验证过的回收语义），要么删掉。**本轮不动它**。
public enum TranscriptWindowPlanner {

    /// 保留带的形状：默认"不超过 120 行、不少于 20 行、按窗口的四分之一自适应"。
    public struct KeepBand: Sendable, Equatable {
        public var maximum: Int
        public var minimum: Int
        public var divisor: Int

        public init(maximum: Int = 120, minimum: Int = 20, divisor: Int = 4) {
            self.maximum = maximum
            self.minimum = minimum
            self.divisor = divisor
        }

        public static let `default` = KeepBand()

        /// 当前窗口下该保留多少行。
        public func rows(forRowCount count: Int) -> Int {
            guard divisor > 0 else { return min(maximum, max(minimum, count)) }
            return min(maximum, max(minimum, count / divisor))
        }
    }

    /// 按载荷预算算「最老端该真的丢几行」。
    ///
    /// - Parameters:
    ///   - payloadBytes: 各行当前占用的字节数，**按时间顺序**（旧 → 新）。
    ///   - budget: 预算（沿用 `TranscriptPayloadBudget`，不另造一个预算类型）。
    ///   - keepLast: 显式指定保留行数；`nil` 时按 `band` 自适应。
    /// - Returns: 要从最老端丢掉的**行数**（0 = 没超预算，不该丢）。
    public static func rowsToDrop(
        payloadBytes: [Int],
        under budget: TranscriptPayloadBudget,
        keepLast: Int? = nil,
        band: KeepBand = .default
    ) -> Int {
        let count = payloadBytes.count
        guard count > 0 else { return 0 }
        let total = payloadBytes.reduce(0, +)
        guard total > budget.limitBytes else { return 0 }
        let keep = min(count, keepLast ?? band.rows(forRowCount: count))
        var over = total - budget.limitBytes
        var dropped = 0
        for size in payloadBytes {
            guard dropped < count - keep else { break }
            over -= size
            dropped += 1
            if over <= 0 { break }
        }
        return dropped
    }

    /// 按「窗口最多几行」算该丢几行。
    ///
    /// 与字节预算那条是**两个不同的旋钮**：这个按行数上限（DEBUG 探针 `-DSHProbeWindowRows`
    /// 专门用来把这条路逼出来，因为真实会话很难自然达到字节预算），那个按载荷字节。
    /// 两条都保留，但**策略都只在这里有一份**——App 侧只负责"丢"这个动作。
    ///
    /// - Returns: 要丢的行数；`limit <= 0` 或没超上限时为 0。
    public static func rowsToDrop(rowCount: Int, limit: Int) -> Int {
        guard limit > 0, rowCount > limit else { return 0 }
        return rowCount - limit
    }
}

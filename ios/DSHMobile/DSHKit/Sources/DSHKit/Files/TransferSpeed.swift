import Foundation

/// 传输速率的**算法**（spec 023 的 S3d）：一次采样有多快、什么时候该忽略这次采样、
/// 以及"整段平均"那条路。
///
/// ## 边界
///
/// * **文件种类判定不在这里**——`WorkspaceFileKind` 早就在 DSHKit（`Sources/DSHKit/WorkspaceFileKind.swift`）。
/// * **状态不在这里**：App 仍持有 `transferRates` / `transferStarted` / `lastSample` 这几张表，
///   本类型只回答"这次采样算出多少"。
///
/// ## 为什么要抽
///
/// 这段计算原来散在 `WorkspaceFilesModel` 的两处（增量采样与续传完成），一个用指数平滑、
/// 一个用整段平均，而且**都有一条容易踩的边界**：采样间隔太短时 `bytes/seconds` 会算出尖峰，
/// 界面上就是"速度突然 200 MB/s"。这种数字没人会专门去复现，但一眼假。
public enum TransferSpeed {

    /// 一次采样：什么时候、累计到了多少字节。
    public struct Sample: Sendable, Equatable {
        public var at: TimeInterval
        public var bytes: Int

        public init(at: TimeInterval, bytes: Int) {
            self.at = at
            self.bytes = bytes
        }
    }

    /// 比这更短的采样一律不算：除出来是尖峰，不是速度（原来写死在 App 里）。
    public static let minimumSampleSeconds: TimeInterval = 0.15

    /// 平滑系数：新值占 0.4，历史占 0.6。
    ///
    /// 单个窗口的抖动不代表速度；但也不能太钝——传输本身只有几秒。
    public static let smoothingWeight = 0.4

    /// 一整段传输的平均速率（MB/s）。
    ///
    /// - Returns: `bytes <= 0` 或时长非正时返回 `nil`（没有可报的速度）。
    public static func average(bytes: Int, seconds: TimeInterval) -> Double? {
        guard bytes > 0, seconds > 0 else { return nil }
        return Double(bytes) / seconds / 1_048_576
    }

    /// 两次采样之间的**瞬时**速率（MB/s）。
    ///
    /// - Returns: 间隔不足 `minimumSampleSeconds`、或者字节数没有增长（重传、乱序、回退）
    ///   时返回 `nil` —— 调用方应当**原样保留上一次的速率**，而不是报一个假数字。
    public static func instant(previous: Sample, current: Sample) -> Double? {
        let seconds = current.at - previous.at
        guard seconds > minimumSampleSeconds else { return nil }
        let bytes = current.bytes - previous.bytes
        guard bytes > 0 else { return nil }
        return Double(bytes) / seconds / 1_048_576
    }

    /// 指数平滑：没有历史就用瞬时值，有历史就按 `smoothingWeight` 混合。
    public static func smoothed(previous: Double?, instant: Double) -> Double {
        guard let previous else { return instant }
        return previous * (1 - smoothingWeight) + instant * smoothingWeight
    }
}

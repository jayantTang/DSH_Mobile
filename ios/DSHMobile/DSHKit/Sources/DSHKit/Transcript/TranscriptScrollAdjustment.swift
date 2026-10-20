import Foundation

/// 转写宿主的锚点位移计算（纯函数，不依赖 UIKit）。
///
/// `prepend` / `dropOldest` / `reconcile` 三处必须是同一套口径：
/// 量锚点在变更前后的视觉位置，差值原样加回 `contentOffset`；修正后再量残差，
/// 只有超过容差才再修一次。抽成纯函数是为了让这条口径能在 DSHKit 的单测里钉住，
/// 而不是散落在三个 UIKit 方法里各写一遍。
public enum TranscriptScrollAdjustment {

    /// 锚点位移：变更后位置减变更前位置。
    ///
    /// 与旧实现逐字同口径：任一端缺失时按 0 处理（`nil` 表示这一行已经不在视图里，
    /// 不能凭空给出位移）。
    public static func delta(anchorBefore: Double?, anchorAfter: Double?) -> Double {
        (anchorAfter ?? 0) - (anchorBefore ?? 0)
    }

    /// 修正后的残差：超过容差才返回非零，否则返回 0（不再修第二次）。
    public static func residual(anchorBefore: Double?, anchorAfterCorrection: Double?,
                                tolerance: Double) -> Double {
        let value = (anchorAfterCorrection ?? anchorBefore ?? 0) - (anchorBefore ?? 0)
        return abs(value) > tolerance ? value : 0
    }
}

/// 历史取页的触发口径（非 UI 层，纯函数）。
///
/// 触发依据是"视口里还剩多少内容"，不是滚动手势本身：读者还剩不到两屏时
/// 就该补下一批，连续滚动事件由任务级单飞去重，不再由视图自己节流。
///
/// 用 `Double` 而不是 `CGFloat`：这里只做数与数的乘法，UI 层把 `bounds.height`
/// 显式转换进来即可。这样 DSHKit 不必 import CoreGraphics，Linux 工具链也能编译。
public enum HistoryTriggerPolicy {
    /// 低水位：距顶部不足两屏时请求。下限 240pt 兼容极矮的窗口。
    public static let screens: Double = 2
    public static let minimumMargin: Double = 240

    public static func margin(viewportHeight: Double) -> Double {
        max(minimumMargin, viewportHeight * screens)
    }

    public static func shouldRequest(distanceToTop: Double, viewportHeight: Double) -> Bool {
        distanceToTop < margin(viewportHeight: viewportHeight)
    }
}

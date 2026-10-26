import Foundation

/// 聊天转写区的底部几何：**唯一的计算入口**。
///
/// 之前视图、UIKit 宿主、按钮各自维护 `contentSize + inset - bounds` 与
/// 40pt/1pt 两套阈值，底部落在哪里取决于谁先算。这里把“可见视口、内容底、
/// 上下 inset”变成纯函数，宿主只执行结果；键盘、旋转、内容增减都能离线单测。
public struct ChatViewportGeometry: Sendable, Equatable {
    /// 可见窗口高度（不含输入区/键盘；由容器实际分给转写的高度给出）。
    public let viewportHeight: Double
    /// 内容真实底部（最后一行的 maxY，不是估算的 contentSize）。
    public let contentBottom: Double
    public let topInset: Double
    public let bottomInset: Double

    public init(viewportHeight: Double, contentBottom: Double,
                topInset: Double = 0, bottomInset: Double = 0) {
        self.viewportHeight = max(0, viewportHeight)
        self.contentBottom = max(0, contentBottom)
        self.topInset = max(0, topInset)
        self.bottomInset = max(0, bottomInset)
    }

    /// 可滚动到的最大 offset。内容不足一屏时返回 `-topInset`（贴顶，不可滚）。
    public var maxOffset: Double {
        max(-topInset, contentBottom + bottomInset - viewportHeight)
    }

    /// 当前 offset 距“内容底 + 底部 inset”的可见距离；0 表示最后一行完整可见。
    public func distanceFromBottom(offset: Double) -> Double {
        max(0, contentBottom + bottomInset - viewportHeight - offset)
    }

    /// 精确贴底：容差只在这里定义一次，界面不再各写一套。
    public func isAtBottom(offset: Double, tolerance: Double = 1) -> Bool {
        distanceFromBottom(offset: offset) <= tolerance
    }
}

// 这份文件刻意**不**依赖 UIKit / SwiftUI 的尺寸类：`DSHLayoutMode` 是纯判定，要能在
// macOS 的 `swift test` 里被执行（护栏单测必须真的跑得到）。把 SwiftUI 尺寸类翻译成
// "宽还是窄"的那层适配留在下面的 iOS 专用初始化器里。
import SwiftUI

/// 宽窄两态：布局判定的唯一依据。
///
/// 它**不**回答"是不是 iPad"：iPhone Pro Max 横屏同样是 `.wide`，
/// 今天就已经在跑分栏。iPad 专场适配由 `\.dshPadAdaptation` 另外管。
public enum DSHLayoutMode: String, Sendable, Equatable {
    case compact
    case wide

    /// 唯一的真相："宽度是不是紧凑的这一类"。尺寸类等外部输入先归一成它。
    public init(isCompact: Bool) {
        self = isCompact ? .compact : .wide
    }

    #if canImport(UIKit)
    /// SwiftUI 尺寸类 → 两态。`nil` 落**宽态**：今天那行守卫是
    /// `if horizontalSizeClass == .compact { 栈 } else { 分栏 }`，`nil` 走 else。
    public init(_ sizeClass: UserInterfaceSizeClass?) {
        self.init(isCompact: sizeClass == .compact)
    }
    #endif
}

private struct DSHLayoutModeKey: EnvironmentKey {
    /// 默认窄态：没有显式注入的子树（预览、单测、被别处托管的视图）
    /// 落到今天手机上的布局。
    static let defaultValue: DSHLayoutMode = .compact
}

public extension EnvironmentValues {
    var dshLayoutMode: DSHLayoutMode {
        get { self[DSHLayoutModeKey.self] }
        set { self[DSHLayoutModeKey.self] = newValue }
    }
}

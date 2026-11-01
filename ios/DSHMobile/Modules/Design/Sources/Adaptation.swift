// 这份文件刻意**不**依赖 UIKit：`isPadWide` 是纯判定，要能在 macOS 的
// `swift test` 里被执行。idiom 由调用点（`RootView`）先归一成 `isPad: Bool`。
import SwiftUI

/// 「这段适配只属于 iPad 宽屏」的唯一判定。
///
/// 为什么单独一条：iPhone Pro Max 横屏也是 `.wide`，今天就在跑分栏；
/// 若把整页弹层、阅读宽度、指针、快捷键挂到"宽屏"上，iPhone 会跟着变。
/// 这里刻意多问一句"是不是 iPad"，且**不**把它塞进布局判据（那会改掉 iPhone 横屏的分栏）。
private struct DSHPadAdaptationKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var dshPadAdaptation: Bool {
        get { self[DSHPadAdaptationKey.self] }
        set { self[DSHPadAdaptationKey.self] = newValue }
    }
}

public enum DSHAdaptation {
    /// iPad 且宽屏才为真。`RootView` 是唯一调用点，它把 idiom 归一成 `isPad`。
    public static func isPadWide(isPad: Bool, layout: DSHLayoutMode) -> Bool {
        isPad && layout == .wide
    }
}

// 键盘快捷键**不在这里**：按键修饰符挂在视图上时由 UIKit 从第一响应者沿响应者链派发，
// 而 NavigationSplitView 的每一列与每个整页弹层都是独立 hosting controller，
// 详情列与弹层里的控件收不到（2026-11-01 实测，见 `maintainers/ipad适配方案.md` §13.2）。
// 快捷键已改为场景级命令，见 `DSHMobile/App/PadCommands.swift`。

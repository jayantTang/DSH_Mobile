#if os(iOS)
// 整份文件都是 iOS 键盘通知与 UIKit 的（`UIResponder`、`CGRect` 帧）：
// 025 阶段4b 加这层包裹，因为 `swift build` / `swift test` 在 macOS 上构建整个包，
// 裸 `import UIKit` 会让 macOS 构建直接失败（DSHDesign 其余文件是逐处
// `#if canImport(UIKit)`，这里整份都依赖它，包裹整文件更诚实）。
import SwiftUI
import UIKit

/// 键盘出现/消失的通知，转成一个可以 `onChange` 的布尔值。
///
/// 为什么需要它：键盘改变的是 **safe area 高度**，`ScrollView` 的内容偏移因此被重新
/// 计算。屏幕上是 `LazyVStack`，它会按"可见矩形"决定哪些行存在——偏移一变、可见矩形
/// 一挪，已经渲染过的行可能被回收，而新的可见区间指向**还没渲染的空位**，于是会话上方
/// 出现一片空白，随手往下拉一下（触发一次新的布局与可见区间）才恢复。
///
/// 所以"键盘可见性变化"这件事必须被显式处理：等键盘动画结束、布局稳定之后，把视口
/// 重新钉回底部锚点，迫使 `LazyVStack` 按新视口重建可见的行。
///
/// 用通知而不是 `@FocusState`：焦点只反映"输入框是否聚焦"，而这里要跟的是**视口尺寸
/// 真的变了**——外接键盘、快捷指令切换输入法、分屏等都只改键盘高度而不改焦点。
/// 探针钩子（025）：设计系统不认识 App 的调试仪器 ViewportProbe。
public final class KeyboardProbe: @unchecked Sendable {
    public static let shared = KeyboardProbe()
    public init() {}
    public var isOn: () -> Bool = { false }
    public var note: (String, [String: String]) -> Void = { _, _ in }
}

public struct KeyboardVisibilityObserver: ViewModifier {
    /// 键盘出现或消失时调用；`true` 表示正在显示。
    let onChange: (Bool) -> Void

    /// 与系统键盘动画对齐。iOS 的键盘动画约 0.25s，取 0.35s 留出余量，
    /// 在动画结束、布局稳定之后再动视口，否则滚动会被动画中的布局覆盖掉。
    private static let settleDelay = Duration.milliseconds(350)

    public func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification)) { _ in
                report(true)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification)) { _ in
                report(false)
            }
            // 联想词栏、切换输入法、外接键盘切换都只发这一条：它不改焦点，
            // 但改键盘高度、也就是改转写区的视口高度。
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard KeyboardProbe.shared.isOn(),
                      let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                else { return }
                KeyboardProbe.shared.note("keyboard.frame", ["h": String(format: "%.0f", frame.height)])
            }
    }

    private func report(_ visible: Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            onChange(visible)
        }
    }
}

extension View {
    /// 键盘可见性变化（在动画结束后回调）。
    ///
    /// 025 阶段4b：转写页在 `DSHChatUI`（另一个模块）里用它，所以这里必须是 public。
    public func onKeyboardVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(KeyboardVisibilityObserver(onChange: action))
    }
}
#endif

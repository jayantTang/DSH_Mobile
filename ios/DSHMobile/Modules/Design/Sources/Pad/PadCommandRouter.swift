#if canImport(UIKit)
// 与 `\.dshPadAdaptation` 同一条条件编译（macOS 上没有该环境键）。
import SwiftUI

/// iPad 专用快捷键的**派发中心**。
///
/// 为什么不挂在按钮上：按键修饰符在 iOS 上被注册成 `UIKeyCommand`，UIKit 从
/// **当前第一响应者**沿响应者链派发。`NavigationSplitView` 的每一列、以及每个整页弹层，
/// 都是独立的 hosting controller —— 侧栏列表持有第一响应者时，详情列工具栏上的快捷键
/// 根本不在那条链上，整页弹层的呈现控制器同理。2026-11-01 实测：挂在按钮上时
/// ⌘N（侧栏）生效，⌘F（详情列）与 Esc（整页弹层）都收不到。
///
/// 场景级 `Commands` 装在整个 scene 上，属于窗口级菜单命令，与"第一响应者落在哪一列"
/// 无关 —— 这是 iPadOS 上"无论焦点在哪都能按"的正规机制。
///
/// **为什么这个类型在 Design 而不是 App target**：消费方是功能模块里的视图
/// （本轮只剩 `SessionListView`），模块不允许反向依赖 App target；场景菜单本身
/// （`Commands`）按方案放在 `DSHMobile/App/PadCommands.swift`。
///
/// 派发纪律（review 时逐条核对）：
/// 1. 消费者一律 `.onChange(of: sequence)` + `guard padAdaptation`；
/// 2. 消费者不得新增状态，只调用已有的动作。
@Observable
@MainActor
public final class PadCommandRouter {
    /// 本轮只有 ⌘N 一条（owner 2026-11-01 裁定）。⌘F / ⌘⏎ / Esc 已从菜单与消费者里
    /// 一起删掉，不留"永远不触发"的分支；三者的现场记录见
    /// `test/CAPABILITY-GAPS.md`「iPad 键盘快捷键只有 ⌘N 生效」。
    public enum Command: Equatable {
        case newSession
    }

    /// 每次派发 +1；消费者用 `onChange(of: sequence)` 只做一次动作。
    public private(set) var sequence = 0
    public private(set) var last: Command?

    public init() {}

    public func post(_ command: Command) {
        last = command
        sequence += 1
    }
}
#endif

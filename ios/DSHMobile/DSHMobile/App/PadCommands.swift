import DSHDesign
import SwiftUI

/// 场景菜单：只派发，不做事（M9）。
///
/// 键表只有 ⌘N（新建会话）。**不要再往这里加 ⌘,（设置）**：iPadOS 把它交给系统
/// （实测按下弹起系统「设置」App），App 侧挂了也收不到。
/// 其它组合暂缺的原因与下一步方向见 `test/CAPABILITY-GAPS.md`「iPad 键盘快捷键只有 ⌘N 生效」。
///
/// 为什么装在这里而不是挂在按钮上：见 `PadCommandRouter` 的注释与方案 §13.2 的实测表。
/// 动作由持有它的视图执行（`SessionListView`），菜单只负责把按键变成一条事件。
struct PadCommandMenu: Commands {
    let router: PadCommandRouter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新建会话") { router.post(.newSession) }
                .keyboardShortcut("n", modifiers: .command)
        }
    }
}

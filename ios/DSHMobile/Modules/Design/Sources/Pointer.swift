#if canImport(UIKit)
// `hoverEffect` 只有 iOS/tvOS 的 SwiftUI 有（macOS 没有），整文件条件编译。
import SwiftUI

/// 行的指针可达性：iPad 宽屏给悬停高亮与右键菜单；其余情况原样返回。
///
/// 为什么不按宽屏判：iPhone 横屏也是宽屏，`contextMenu` 会变成"长按弹菜单"，
/// 那是 iPhone 上新增的行为，违反"零变化"。
/// 转写行**不挂**：那个宿主里 `contextMenu` 的几何是错的（见 `MessageActions`）。
public struct RowPointer<Menu: View>: ViewModifier {
    @Environment(\.dshPadAdaptation) private var pad
    let menu: Menu

    public func body(content: Content) -> some View {
        if pad {
            content
                .hoverEffect(.highlight)
                .contextMenu { menu }
        } else {
            content
        }
    }
}

public extension View {
    func dshRowPointer<M: View>(@ViewBuilder menu: () -> M) -> some View {
        modifier(RowPointer(menu: menu()))
    }
}
#endif

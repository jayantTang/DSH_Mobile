#if canImport(UIKit)
// `fullScreenCover` 是 iOS/tvOS 的 API（macOS 没有），整文件条件编译。
import SwiftUI

/// 整页弹层的呈现方式：唯一一处。
///
/// iPad 宽屏用 `fullScreenCover`（整页，靠各屏自己导航栏上的关闭按钮退出）；
/// 其余情况（iPhone 含横屏、iPad 窄分屏）用 `.sheet`，与今天逐字节相同。
/// 不用 iOS 18 的 `presentationSizing`：部署目标 17.0，用它就得有两套外观。
public extension View {
    func dshSurface<C: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        modifier(DSHSurface(isPresented: isPresented, make: content))
    }

    func dshSurface<I: Identifiable, C: View>(
        item: Binding<I?>,
        @ViewBuilder content: @escaping (I) -> C
    ) -> some View {
        modifier(DSHSurfaceItem(item: item, make: content))
    }
}

private struct DSHSurface<C: View>: ViewModifier {
    @Environment(\.dshPadAdaptation) private var pad
    @Binding var isPresented: Bool
    let make: () -> C

    func body(content: Content) -> some View {
        if pad {
            content.fullScreenCover(isPresented: $isPresented, content: make)
        } else {
            content.sheet(isPresented: $isPresented, content: make)
        }
    }
}

private struct DSHSurfaceItem<I: Identifiable, C: View>: ViewModifier {
    @Environment(\.dshPadAdaptation) private var pad
    @Binding var item: I?
    let make: (I) -> C

    func body(content: Content) -> some View {
        if pad {
            content.fullScreenCover(item: $item, content: make)
        } else {
            content.sheet(item: $item, content: make)
        }
    }
}
#endif

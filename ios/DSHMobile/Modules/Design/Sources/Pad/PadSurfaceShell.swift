#if canImport(UIKit)
// 与 `\.dshPadAdaptation` 同一条条件编译（macOS 上没有该环境键）。
import SwiftUI

/// 给"自己没有导航栏"的弹层补一层 iPad 外壳：标题 + 关闭。
///
/// 只用于 **没有** `NavigationStack` 的两屏（工作区文件、诊断）。已有导航栏的四屏
/// （设置/连接/记录/网页）**不要**套，会变成两层导航栈。
/// `pad == false` 时原样返回内容：iPhone 上这一屏的外观与今天完全一样。
public struct PadSurfaceShell<Content: View>: View {
    @Environment(\.dshPadAdaptation) private var pad
    @Environment(\.dismiss) private var dismiss
    private let title: LocalizedStringKey
    private let content: Content

    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        if pad {
            NavigationStack {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("关闭") { dismiss() }
                        }
                    }
            }
        } else {
            content
        }
    }
}
#endif

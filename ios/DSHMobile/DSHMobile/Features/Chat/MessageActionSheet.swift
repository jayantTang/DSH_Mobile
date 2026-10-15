import DSHDesign
import DSHKit
import SwiftUI

/// 转写行长按后弹出的动作单（自己画）。
///
/// **为什么不用系统那两条路**（2026-10-12，spec 013，都是实测结论）
///
/// - `contextMenu`：它把被长按的**整行**抬起来当预览。转写的一行常常比屏幕还高（一整个回答），
///   抬起来没地方放——真机上它压住导航栏、面板半透明透出正文，遮罩也只盖住一部分，看着像两层 UI
///   糊在一起（owner 截图）。给它一个尺寸固定的 `preview:` 也治不好：截图上预览与菜单仍然叠着。
/// - 系统 `confirmationDialog`：在本机仿真器里按钮会进无障碍树，但画面截图上什么都没有
///   （内联 `Binding` 与普通 `@State` 两种写法、轻点与长按两种触发都试过）。
///
/// 所以自己画一块完全可控的：一层遮罩（点它即取消）+ 底部卡片。尺寸与位置不依赖行高，
/// 两个转写容器（UIKit 宿主与 SwiftUI `List`）下表现一致，也不需要新增文案——三条文案都在表里。
struct MessageActionSheet: View {
    /// 这一条自己的名字（「助手的回答」/「我的消息」/「工具 · X」），由调用方给。
    let title: String
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void

    var body: some View {
        card
            .padding(.horizontal, DSHTheme.Spacing.loose)
            .padding(.bottom, DSHTheme.Spacing.tight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // 遮罩放在 `background` 里：`ignoresSafeArea` 只影响这一层的绘制，不去撑大
            // 卡片所在的布局框。放在 `ZStack` 里当兄弟视图会连布局一起撑大，卡片会被安全区
            // 顶到屏幕外（2026-10-12 实测：底部"取消"那一行被切掉）。
            .background {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onCancel() }
                    .accessibilityIdentifier("message.actions.scrim")
            }
    }

    private var card: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSHTheme.Spacing.tight)

            Hairline()
            action(.select, run: onSelect)
            Hairline()
            action(.copy, run: onCopy)
            Hairline()
            action(.cancel, run: onCancel)
        }
        .background(DSHTheme.layer1)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous)
                .stroke(DSHTheme.border1, lineWidth: 1)
        )
        // 卡片本身不挂标识：容器上的 accessibilityIdentifier 会**下传**给子元素、把按钮自己的
        // id 覆盖掉（仓库里记过这个坑）。判定看的是三个按钮与那层遮罩。
    }

    private func action(_ kind: Kind, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 22)
                Text(kind.title)
                    .font(DSHTheme.Typography.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(kind.isCancel ? DSHTheme.labelSecondary : DSHTheme.labelPrimary)
            .padding(.horizontal, DSHTheme.Spacing.loose)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(kind.identifier)
    }

    /// 三个动作。文案用 `LocalizedStringKey` 字面量，键就是中文（仓库约定，两套表里都有）。
    private enum Kind {
        case select, copy, cancel

        var title: LocalizedStringKey {
            switch self {
            case .select: "选择文本"
            case .copy: "拷贝整条消息"
            case .cancel: "取消"
            }
        }

        var symbol: String {
            switch self {
            case .select: "text.cursor"
            case .copy: "doc.on.doc"
            case .cancel: "xmark"
            }
        }

        var identifier: String {
            switch self {
            case .select: "message.actions.select"
            case .copy: "message.actions.copy"
            case .cancel: "message.actions.cancel"
            }
        }

        var isCancel: Bool { self == .cancel }
    }
}

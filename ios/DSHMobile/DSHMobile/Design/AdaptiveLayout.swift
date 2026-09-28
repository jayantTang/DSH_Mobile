import SwiftUI

// MARK: - 自适应容器
//
// 设置页在英文下比中文长得多（短标签能到 6.5 倍：「提醒」→ "Notifications"），
// 而这一页的值大多长度不受控（relay 地址、主机主目录、连接器名、凭据 ref）。
// 两个容器把「英文更长」这件事交给布局原语吸收，而不是靠缩字号或省略号：
//
//   - `AdaptivePair`：标签｜值。一行放得下就是原来那一行；放不下就整对上下堆叠。
//   - `AdaptiveRow`：前导｜文本列｜尾部控件。尾部控件拿满固有宽度，文本列换行。
//
// 刻意**不**做的事（见方案 G9）：不测量文本宽度、不读 `sizeThatFits`、不因宽度改
// `frame(width:)`、不缩字号（`minimumScaleFactor` / `dynamicTypeSize`）、不引入
// `GeometryReader`。两个容器都只做「候选布局能不能装下」这一件事，由 SwiftUI 的
// `ViewThatFits` 判定。

/// 「标签｜值」：一行放不下时整对堆叠，值/标签都不出现省略号。
///
/// 候选 1 用 `LabeledContent` 表达，而不是手写 `HStack`：它就是同一套
/// 「标签 + 间隔 + 值」的刚性行（两者都 `fixedSize(horizontal: true)`，宽度=和，
/// 装不下就不 fit），同时**保住了这一行原有的取值样式**——`LabeledContent` 的标签是
/// 主色、值是次级色，手写 `HStack` 会把值从次级色变成主色，那是 B2/G12 不允许的
/// 版式变化。候选 2 里值显式取次级色，跟候选 1 保持一致。
struct AdaptivePair<Label: View, Value: View>: View {
    private let label: Label
    private let value: Value

    init(@ViewBuilder label: () -> Label, @ViewBuilder value: () -> Value) {
        self.label = label()
        self.value = value()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            LabeledContent {
                value.fixedSize(horizontal: true, vertical: false)
            } label: {
                label.fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 2) {
                label.fixedSize(horizontal: true, vertical: false)
                value
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 「前导｜文本列｜尾部控件」：尾部控件拿满固有宽度，文本列换行而不是被挤掉。
///
/// 尾部给更高的布局优先级（先分配），文本列吃剩下的宽度并换行；文本列内部的
/// 多行 `Text` 由调用点加 `.fixedSize(horizontal: false, vertical: true)`。
struct AdaptiveRow<Leading: View, Content: View, Trailing: View>: View {
    private let alignment: VerticalAlignment
    private let spacing: CGFloat
    private let leading: Leading
    private let content: Content
    private let trailing: Trailing

    init(
        alignment: VerticalAlignment = .top,
        spacing: CGFloat = DSHTheme.Spacing.tight,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.leading = leading()
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            leading
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            trailing
                .layoutPriority(2)
        }
    }
}

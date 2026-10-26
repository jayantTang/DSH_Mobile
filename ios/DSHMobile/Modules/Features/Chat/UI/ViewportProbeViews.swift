#if os(iOS)
import DSHDesign
#if DEBUG
import SwiftUI

// MARK: - 把一块视图的屏幕坐标报给探针

/// 把一行的屏幕矩形报给探针；`no-rows` 变体下不挂，用来控制"这些 background
/// 会不会自己改变布局"。
struct ProbedRow: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        if ChatProbe.shared.noRowProbe {
            content
        } else {
            content.background(ViewportProbeReporter(id: id))
        }
    }
}

/// 挂在每一行（以及尾部气泡、输入框）上，把它的屏幕矩形报给探针。
struct ViewportProbeReporter: View {
    let id: String

    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .global)
            Color.clear
                .onAppear { ChatProbe.shared.enterRow?(id, rect) }
                .onChange(of: rect) { _, next in ChatProbe.shared.updateRow?(id, next) }
                .onDisappear { ChatProbe.shared.leaveRow?(id) }
        }
    }
}

extension View {
    /// 让这一行出现在探针的覆盖核对里。
    func probed(_ id: String) -> some View {
        modifier(ProbedRow(id: id))
    }
}

/// 滚动几何的记录：偏移、内容高、容器高。
///
/// 只在 iOS 18 以上可用（`onScrollGeometryChange`），系统更低时什么都不做——
/// 探针是诊断工具，不值得为它提高部署目标。
struct ScrollGeometryProbe: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: ScrollFacts.self) { geometry in
                ScrollFacts(offset: geometry.contentOffset.y,
                            content: geometry.contentSize.height,
                            container: geometry.containerSize.height)
            } action: { _, facts in
                ChatProbe.shared.setScroll?(facts.offset, facts.content)
                ChatProbe.shared.probeNote?("scroll", [
                    "offset": String(format: "%.0f", facts.offset),
                    "content": String(format: "%.0f", facts.content),
                    "container": String(format: "%.0f", facts.container),
                    "beyond": String(format: "%.0f", facts.offset + facts.container - facts.content),
                ], false)
            }
        } else {
            content
        }
    }

    /// 只带三个数，避免为了记录把整个 `ScrollGeometry` 拖进依赖里。
    struct ScrollFacts: Equatable {
        var offset: CGFloat
        var content: CGFloat
        var container: CGFloat
    }
}


#else
import SwiftUI
import DSHChatDomain

struct ScrollGeometryProbe: ViewModifier {
    func body(content: Content) -> some View { content }
}

extension View {
    func probed(_ id: String) -> some View { self }
}
#endif


/// 转写行在 `List` 模式下需要的装饰。
///
/// `List` 默认给每行内边距、分隔线和系统底色；聊天转写要的是"行就是自己画的那块"，
/// 所以全部去掉，行距与左右留白改由行自己给（与 `LazyVStack` 那两个 padding 对齐）。
struct TranscriptRowChrome: ViewModifier {
    let inList: Bool
    /// 行底留白。过程行（轮次行、分组行）自带更紧的间距：分组行按桌面是 20pt
    /// 行高 + 一点点缝，用正文那 12pt 会把一组拆成一条条孤立的行。
    var bottomPadding: CGFloat = DSHTheme.Spacing.standard

    func body(content: Content) -> some View {
        if inList {
            content
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.horizontal, DSHTheme.Spacing.loose)
                .padding(.bottom, bottomPadding)
        } else {
            content
        }
    }
}
#endif

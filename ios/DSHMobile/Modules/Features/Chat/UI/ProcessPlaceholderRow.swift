#if os(iOS)
import DSHDesign
import DSHKit
import SwiftUI

// MARK: - 过程区占位行（设计 20261027 折叠抖动方案 A / M7、M7'-1）

/// 尾轮边界未确认时的一行占位提示：**固定高度**，不做新的设计语言。
///
/// 三种状态各自的结局都可见：静置写「过程区状态未确认」，确认中写「正在确认…」，
/// 失败态写失败原因。**静置与失败都整行可点**（同一个重试入口）——静置态正是
/// `.earliest` / `.capped` 两种结局停的地方，不给它点击入口就是死路。
/// `.resolving` 不可点（`retryTailBoundary` 的 guard 也挡重复进入），高度不随状态变化。
struct ProcessPlaceholderRow: View {
    let placeholder: TimelineProcessPlaceholder
    let onRetry: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: TimelineProcessPlaceholder.height)
            .contentShape(Rectangle())
            .accessibilityIdentifier(identifier)
    }

    /// 可点的两态共用重试标识（自动化用例按它点）；确认中不可点，用行标识。
    private var identifier: String {
        if case .resolving = placeholder.state { return "row.process.unknown" }
        return "chat.process.unknown.retry"
    }

    @ViewBuilder
    private var content: some View {
        switch placeholder.state {
        case .resolving:
            Text("正在确认过程区状态…")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
        case .unresolved:
            retryButton { Text("过程区状态未确认") }
        case .failed(let failure):
            retryButton { Text(text(for: failure)) }
        }
    }

    /// 静置态与失败态是同一个动作：**整行**可点（44 pt 行高，不是文案本身的大小），
    /// 点下去重试一次（有 5 s 上限）。
    ///
    /// `frame`/`contentShape` 必须落在 `Button` 的 label 上：只包在外层容器上时，
    /// 命中区域仍然只是那一行文案，手指落在行内空白处点不动。
    private func retryButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button(action: onRetry) {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                label()
                    .font(DSHTheme.Typography.micro)
            }
            .foregroundStyle(DSHTheme.brand)
            .frame(maxWidth: .infinity, minHeight: TimelineProcessPlaceholder.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.process.unknown.retry")
    }

    private func text(for failure: TimelineProcessPlaceholder.TailBoundaryFailure) -> String {
        switch failure {
        case .read: return String(localized: "读取过程区状态失败，点击重试")
        case .hole: return String(localized: "过程区缺一段记录，点击重试")
        case .timeout: return String(localized: "确认过程区状态超时，点击重试")
        }
    }
}
#endif

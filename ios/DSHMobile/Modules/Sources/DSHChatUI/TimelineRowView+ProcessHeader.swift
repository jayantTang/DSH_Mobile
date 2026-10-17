#if os(iOS)
import DSHDesign
import DSHKit
import SwiftUI

/// One line standing in for a folded process.
///
/// The turn-level row is the tree's root; group rows are a lighter second level.
/// Both keep the same identity while open and closed, so the list host's scroll
/// anchor survives a toggle.
struct ProcessHeaderRow: View {
    let header: TimelineProcessHeader
    var onToggle: (() -> Void)?

    private var isGroup: Bool { header.scope == .group }
    private var isExpanded: Bool { header.isExpanded }
    private var canFold: Bool { header.isFoldable }

    private var statusText: String {
        if header.isRunning { return String(localized: "进行中") }
        if header.hasFailure { return Self.reasonText(header.endReason) }
        if header.endReason == "max-steps" { return String(localized: "达步数上限") }
        return String(localized: "已完成")
    }

    private var summaryText: String {
        var parts: [String] = [statusText]
        if header.toolCount > 0 {
            parts.append(String(format: String(localized: "%lld 次工具调用"), header.toolCount))
        }
        if header.reasoningCount > 0 {
            parts.append(String(format: String(localized: "%lld 段思考"), header.reasoningCount))
        }
        if let duration = header.duration, duration > 0 {
            parts.append(String(format: String(localized: "用时 %@"), Self.durationText(duration)))
        }
        if header.isPartial {
            parts.append(String(localized: "部分记录"))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        isGroup ? String(localized: "过程组") : String(localized: "过程")
    }

    var body: some View {
        Button {
            onToggle?()
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                if canFold {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: isGroup ? 8 : 9, weight: .semibold))
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Image(systemName: isGroup ? "ellipsis.circle" : "bolt.horizontal.circle")
                    .font(.system(size: isGroup ? 11 : 12, weight: .regular))
                    .foregroundStyle(header.hasFailure ? DSHTheme.danger : DSHTheme.labelTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summaryText)
                        .font(isGroup ? DSHTheme.Typography.micro : DSHTheme.Typography.caption)
                        .foregroundStyle(header.hasFailure ? DSHTheme.danger : DSHTheme.labelSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if isGroup, let detail = groupDetail {
                        Text(detail)
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelDimmed)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if header.isRunning {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.leading, isGroup ? DSHTheme.Spacing.loose : 0)
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, isGroup ? 2 : 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canFold)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(isExpanded ? String(localized: "已展开") : String(localized: "已收起")))
        .accessibilityHint(Text(canFold
            ? (isExpanded ? String(localized: "收起过程") : String(localized: "展开过程"))
            : ""))
        .accessibilityAddTraits(.isButton)
    }

    private var groupDetail: String? {
        let ordered = header.activityCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.rawValue < rhs.key.rawValue
        }
        guard !ordered.isEmpty else { return nil }
        return ordered.prefix(3).map { activity, count in
            "\(Self.activityText(activity)) \(count)"
        }.joined(separator: " · ")
    }

    private static func activityText(_ activity: TimelineProcessActivity) -> String {
        switch activity {
        case .read: return String(localized: "读取")
        case .write: return String(localized: "写入")
        case .edit: return String(localized: "修改")
        case .search: return String(localized: "搜索")
        case .commands: return String(localized: "命令")
        case .code: return String(localized: "代码")
        case .web: return String(localized: "联网")
        case .subagents: return String(localized: "子智能体")
        case .questions: return String(localized: "提问")
        case .plan: return String(localized: "计划")
        case .tools: return String(localized: "工具")
        }
    }

    private static func reasonText(_ reason: String?) -> String {
        switch reason {
        case "cancelled", "canceled", "aborted": return String(localized: "已停止")
        case "interrupted": return String(localized: "被中断")
        case "error", "failed": return String(localized: "出错结束")
        default: return String(localized: "已停止")
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        if duration < 60 { return String(format: "%.1fs", duration) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%dm %02ds", minutes, seconds)
    }
}
#endif

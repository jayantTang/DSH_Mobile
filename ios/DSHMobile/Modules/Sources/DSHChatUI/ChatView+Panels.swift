#if os(iOS)
@_exported import DSHChatDomain
import DSHConnectionDomain
import DSHCore
import DSHDesign
import DSHFoundation
import DSHKit
import SwiftUI

// MARK: - 面板与横幅（自 ChatView.swift 拆出，026 P4）
//
// 同一模块的私有内嵌 View；`private` 改为 internal（模块内可见），语义不变。

// MARK: - Session info

/// Everything about the session that is useful occasionally but not always.
///
/// Keeping it in a popover is the whole point: the transcript gets the screen,
/// and the metadata is one tap away rather than two permanent lines.
struct SessionInfoPopover: View {
    let model: ChatModel
    let home: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            if let session = model.session {
                row("标题", session.displayTitle, selectable: false)

                if let cwd = session.cwd {
                    row("目录", PathFormat.short(cwd, home: home), selectable: true)
                }
                row("会话 ID", session.sessionId, selectable: true)
            }

            if model.currentSelection != nil || model.currentPermission != nil {
                Divider()
            }
            if let selection = model.currentSelection {
                row("模型", "\(selection.model)（\(selection.provider)）", selectable: false)
                if let effort = selection.reasoningEffort {
                    row("推理强度", effort, selectable: false)
                }
            }
            if let permission = model.currentPermission {
                row("权限", permission, selectable: false)
            }

            if let pressure = model.session?.projections?.values?.contextPressure,
               let window = pressure.contextWindow, window > 0,
               let used = pressure.pressureTokens {
                // What the session list can only hint at with a bar: how full the
                // context window is right now, and with how many tokens.
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
                    Text("上下文占用")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                        .frame(minWidth: 76, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(TokenFormat.compact(used)) / \(TokenFormat.compact(window))（\(Int((Double(used) / Double(window) * 100).rounded()))%）")
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelPrimary)
                            .monospacedDigit()
                        PressureBar(fraction: Double(used) / Double(window))
                            .frame(width: 120)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.info.context")
            }

            if let usage = model.timeline.lastUsage, usage.totalTokens > 0 {
                Divider()
                row("Token 用量", TokenFormat.compact(usage.totalTokens), selectable: false)
                if let uncached = usage.uncachedInputTokens {
                    row("输入（未缓存）", TokenFormat.compact(uncached), selectable: false)
                }
                if let cached = usage.cacheReadTokens {
                    row("输入（缓存命中）", TokenFormat.compact(cached), selectable: false)
                }
                if let output = usage.outputTokens {
                    row("输出", TokenFormat.compact(output), selectable: false)
                }
            }

            Divider()
            row("状态", model.isRunning ? "运行中" : "空闲", selectable: false)
        }
        .padding(DSHTheme.Spacing.loose)
        .frame(minWidth: 260, idealWidth: 300, alignment: .leading)
    }

    private func row(_ label: String, _ value: String, selectable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSHTheme.Spacing.tight) {
            Text(label)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
                .frame(minWidth: 76, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelPrimary)
                .modifier(OptionalTextSelection(enabled: selectable))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Streaming

/// The provisional bubble shown while tokens are still arriving.
struct StreamingBubble: View {
    let attempt: StreamingAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            if !attempt.reasoning.isEmpty {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    ProgressView().controlSize(.mini)
                    Text("正在思考…")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            }
            if !attempt.text.isEmpty {
                MarkdownText(text: attempt.text, isStreaming: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(0.92)
    }
}

// MARK: - Pending prompt

/// The banner that surfaces a blocking host prompt.
///
/// Leaving one of these unanswered visibly stalls the desktop session, so it is
/// pinned above the composer rather than buried in the toolbar.
struct PendingPromptBanner: View {
    let prompt: HostEventHub.Pending
    let model: ChatModel

    @State var isShowingSheet = false

    var body: some View {
        Button {
            isShowingSheet = true
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 13, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.title)
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelPrimary)
                    if let first = prompt.userQuestions?.questions.first {
                        Text(first.header ?? first.question)
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text("回应")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.brand)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DSHTheme.brand)
            }
            .padding(.horizontal, DSHTheme.Spacing.loose)
            .padding(.vertical, DSHTheme.Spacing.tight)
            // Brand blue, not amber: this is a prompt to act, and amber made
            // it read as a warning about something going wrong.
            .background(DSHTheme.brandSubtle)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A stable handle for the unattended runs: the banner is the only way
        // into the question sheet, and a coordinate tap on it would be a guess.
        .accessibilityIdentifier("chat.pending")
        .sheet(isPresented: $isShowingSheet) {
            if let questions = prompt.userQuestions {
                UserQuestionSheet(prompt: prompt, questions: questions, model: model)
            } else {
                GenericPromptSheet(prompt: prompt, model: model)
            }
        }
    }
}


/// Applies text selection only when asked.
///
/// `textSelection` is generic over the selectability type, so a ternary between
/// `.enabled` and `.disabled` does not type-check; a modifier keeps both
/// branches concrete.
struct OptionalTextSelection: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}


/// A short-lived confirmation that a run finished.
struct CompletionBanner: View {
    let text: String
    /// Only abnormal endings are tinted as warnings.
    var isWarning: Bool {
        text.contains("取消") || text.contains("中断") || text.contains("出错")
    }

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
            Text(text)
                .font(DSHTheme.Typography.micro)
        }
        .foregroundStyle(DSHTheme.labelPrimary)
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.vertical, 7)
        .background(DSHTheme.layer3, in: Capsule())
        .overlay(
            Capsule().stroke(
                (isWarning ? DSHTheme.brand : DSHTheme.success).opacity(0.5),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

/// A dismissible notice that something the person asked for did not happen.
///
/// Its shape follows `CompletionBanner` (same capsule, same layer colour) so the
/// two read as one family, and it uses `DSHTheme.brand` — the existing warning
/// tint — rather than a new colour. The text is the whole message
/// (`ChatModel` composes "what failed / why / what to do"), so nothing is
/// truncated here with `.lineLimit(1)`; a two-line sentence is still readable.
struct ChatErrorBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DSHTheme.brand)
            Text(text)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelPrimary)
                .multilineTextAlignment(.leading)
                // 标识放在**文本块**上而不是整个 HStack：给容器加标识会让 SwiftUI
                // 把整条提示合成一个可访问元素，里面的关闭按钮就点不到了（实测，见
                // `OutdatedConnectorBanner`）。
                .accessibilityIdentifier("chat.error.banner")
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .padding(DSHTheme.Spacing.tight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.error.dismiss")
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.vertical, 7)
        .background(DSHTheme.layer3, in: Capsule())
        .overlay(Capsule().stroke(DSHTheme.brand.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

/// 视口顶部到内容顶部的距离（点）；停在最上面时是 0。
///
/// iOS 18 起直接读滚动几何（`contentOffset + contentInsets.top`）。更低的系统没有这个
/// API，`ChatView` 就只剩哨兵行的 `onAppear` 触发——补页仍然会自动发生，只是要等行被
/// 建出来那一刻，而不是提前 120pt。
struct TranscriptTopDistance: ViewModifier {
    let onChange: (CGFloat) -> Void

    /// 这个平台上有没有滚动几何可读（决定"到没到顶部"由谁说了算）。
    static var available: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            // 值取数组而不是单个 `CGFloat`：`CGFloat` 那一版实测有一次整段回调都没来
            // （2026-09-24 run 20260924-225605：补页一次都没触发），换数组之后 3/3 轮都到。
            content.onScrollGeometryChange(for: [CGFloat].self) { geometry in
                [geometry.contentOffset.y, geometry.contentInsets.top]
            } action: { _, values in
                onChange(values[0] + values[1])
            }
        } else {
            content
        }
    }
}
#endif
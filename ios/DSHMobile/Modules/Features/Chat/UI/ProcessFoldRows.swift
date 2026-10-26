#if os(iOS)
import DSHChatDomain
import DSHDesign
import DSHKit
import SwiftUI

/// 过程折叠的三行，逐条对齐桌面（设计 `20261025-过程折叠-对齐桌面` §3.2）：
///
/// - `ProcessTurnRow`：一轮的状态行，`已完成，用时 1分39秒` + 箭头 + 0.5pt 底线；
/// - `ProcessGroupRow`：组行，活动图标 + 箭头 + 动作短语，单组也显示；
/// - `RunningLine`：底部的 `深度求索中，用时 12秒 ···`。
///
/// 文案全部由 `ProcessFoldText`（领域层纯函数）产出，视图只管排版与命中区。

// MARK: - 轮次行

/// 一轮的状态行：高 33pt、14/24、tertiary、底部 0.5pt `border2`、整行可点。
///
/// 箭头在文字右侧 4pt、展开旋转 180°；不可收起的轮次（被停止的）不画箭头、
/// 按钮禁用 —— 与桌面 `canCollapse = foldable && hasContent && !alwaysOpen` 一致。
struct ProcessTurnRow: View {
    let header: TimelineProcessHeader
    var onToggle: (() -> Void)?

    static let height: CGFloat = 33
    /// 桌面 `padding: 0 0 8px`：33pt 里最后 8pt 是底距，线条压在最下面。
    private static let bottomInset: CGFloat = 8
    /// 文字行高 24pt（桌面 `line-height: 24px`），在剩下的 25pt 里垂直居中。
    private static let labelHeight: CGFloat = 24

    private var canCollapse: Bool { header.isFoldable }
    private var label: String {
        ProcessFoldText.turnLabel(endReason: header.endReason, duration: header.duration)
    }

    var body: some View {
        // 常开的轮次（被停止的）**不是按钮**：桌面上它是 `disabled` 的按钮，
        // 手机上用非按钮渲染，既点不动，也不会被系统按禁用态调暗。
        if canCollapse {
            Button {
                onToggle?()
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(header.isExpanded ? String(localized: "已展开") : String(localized: "已收起")))
            .accessibilityHint(Text(header.isExpanded ? String(localized: "收起过程") : String(localized: "展开过程")))
            .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(DSHTheme.Typography.processLabel)
                .foregroundStyle(DSHTheme.processLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            if canCollapse {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(DSHTheme.processLabel)
                    .rotationEffect(.degrees(header.isExpanded ? 180 : 0))
                    .animation(.easeInOut(duration: 0.1), value: header.isExpanded)
                    .padding(.leading, DSHTheme.Spacing.hairline)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.labelHeight)
        .frame(height: Self.height - Self.bottomInset, alignment: .center)
        .padding(.bottom, Self.bottomInset)
        // 边界由这一条线承担：折叠轮不再另设「已完成」分隔行。
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSHTheme.border2)
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - 分组行

/// 一条分组行：活动图标 14 + 箭头 14 + 动作短语 14，间距 6、行高 20、tertiary。
///
/// 短语由 `ProcessFoldText.groupTitle` 给出（最多 3 类活动、不带次数）；
/// 运行中的那条改用 `正在<动作> · <当前命令/工具>`。组默认收起。
struct ProcessGroupRow: View {
    let header: TimelineProcessHeader
    /// 运行中的实时状态；只有 `header.isRunning` 的那条会用到。
    var running: ProcessRunningDetail?
    var onToggle: (() -> Void)?

    static let height: CGFloat = 20

    private var activity: TimelineProcessActivity? {
        if header.isRunning { return running?.activity }
        return ProcessFoldText.topActivity(header.activityCounts)
    }

    private var title: String {
        if header.isRunning {
            return ProcessFoldText.runningGroupTitle(activity: running?.activity,
                                                     detail: running?.detail ?? "")
        }
        return ProcessFoldText.groupTitle(header.activityCounts)
    }

    private var icon: String {
        guard let activity else { return ProcessFoldText.thinkingIcon }
        return ProcessFoldText.activityIcon(activity)
    }

    var body: some View {
        Button {
            onToggle?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 14, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(header.isExpanded ? 180 : 0))
                    .animation(.easeInOut(duration: 0.1), value: header.isExpanded)
                Text(title)
                    .font(DSHTheme.Typography.processLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSHTheme.processLabel)
            .frame(height: Self.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(header.isExpanded ? String(localized: "已展开") : String(localized: "已收起")))
        .accessibilityHint(Text(header.isExpanded ? String(localized: "收起过程") : String(localized: "展开过程")))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 深度求索行

/// 底部运行行：上方 0.5pt 线、上距 12pt、鲸尾 14pt + 12/22 的 `#345EBA` 文字。
///
/// 计时每 1 秒刷新一次（与桌面一致），只重算这一行的文本子树，不播报；
/// 轮次一结束这一行随 `runningDetail` 一起消失，原地换成轮次行的「已完成，用时」。
struct RunningLine: View {
    /// 本轮开始的时刻；nil 时只写「深度求索中」。
    let since: Date?

    static let refresh: TimeInterval = ProcessFoldText.runningRefresh

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(DSHTheme.border1)
                .frame(height: 0.5)
                .padding(.bottom, 10)
            TimelineView(.periodic(from: .now, by: Self.refresh)) { context in
                HStack(spacing: 6) {
                    WhaleTailShape()
                        .stroke(style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14)
                    Text(ProcessFoldText.deepDivingText(elapsed: elapsed(at: context.date)))
                        .font(DSHTheme.Typography.runningLine)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .foregroundStyle(DSHTheme.deepDiving)
        }
        .padding(.top, DSHTheme.Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ProcessFoldText.deepDivingText(elapsed: elapsed(at: Date()))))
        .allowsHitTesting(false)
    }

    private func elapsed(at date: Date) -> TimeInterval? {
        guard let since else { return nil }
        return max(0, date.timeIntervalSince(since))
    }
}

// MARK: - 步骤卡（概要 v2）

/// 概要 v2 的一条步骤：**沿用工具卡的壳**（同一套底色/圆角/描边/分隔线），
/// 只把内容换成本地已有的元数据与按需取回的正文。
///
/// 收起时一句话就够：名称 + 参数预览 + 状态 + `输出 N B · 点开查看`；
/// 展开后原地显示正文（加载中转 spinner，失败给「点按重试」）。
/// 思考步骤没有参数，写「思考」+ 大小。
struct ProcessStepRow: View {
    let step: TimelineProcessStep
    let isExpanded: Bool
    var onToggle: (() -> Void)?
    var onRetry: (() -> Void)?

    private var isThinking: Bool { step.kind == .reasoning }

    private var title: String {
        ProcessFoldText.stepTitle(kind: step.kind, name: step.name)
    }

    private var hint: String {
        if isThinking {
            return ProcessFoldText.thinkingStepHint(bytes: step.bytes)
        }
        return ProcessFoldText.stepOutputHint(bytes: step.bytes, body: step.body)
    }

    private var icon: String {
        if isThinking { return ProcessFoldText.thinkingIcon }
        return ProcessFoldText.activityIcon(TimelineProcessActivity.classify(step.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Hairline()
                details
            }
        }
        .background(DSHTheme.layer1)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous)
                .stroke(step.status == .error ? DSHTheme.danger.opacity(0.4) : DSHTheme.border1,
                        lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            onToggle?()
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(step.status == .error ? DSHTheme.danger : DSHTheme.brand)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.processLabel)
                    if !step.preview.isEmpty {
                        Text(step.preview)
                            .font(DSHTheme.Typography.code)
                            .foregroundStyle(DSHTheme.labelPrimary)
                            .lineLimit(isExpanded ? 4 : 2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 0)

                if step.isRunning || step.body == .loading {
                    ProgressView()
                        .controlSize(.mini)
                } else if step.status == .error {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DSHTheme.danger)
                }

                Text(hint)
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(step.body == .failed ? DSHTheme.danger : DSHTheme.processLabel)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DSHTheme.labelDimmed)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, DSHTheme.Spacing.standard)
            .padding(.vertical, DSHTheme.Spacing.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("process.step.header")
    }

    @ViewBuilder
    private var details: some View {
        switch step.body {
        case .loading:
            HStack(spacing: DSHTheme.Spacing.tight) {
                ProgressView().controlSize(.mini)
                Text("正在取正文…")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.processLabel)
            }
            .padding(DSHTheme.Spacing.tight)
        case .tooLarge:
            // 终态：超出一条能展开的上限，不给重试（点多少次都是同一个结果）。
            Text("输出过大，无法在手机上展开")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.processLabel)
                .padding(DSHTheme.Spacing.tight)
                .accessibilityIdentifier("process.step.tooLarge")
        case .failed:
            Button {
                onRetry?()
            } label: {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Image(systemName: "arrow.clockwise")
                    Text("输出加载失败 · 点按重试")
                }
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.danger)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("process.step.retry")
            .padding(DSHTheme.Spacing.tight)
        case .loaded(let text, _):
            Text(text)
                .font(DSHTheme.Typography.code)
                .foregroundStyle(DSHTheme.labelSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSHTheme.Spacing.tight)
                .background(DSHTheme.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
                .padding(DSHTheme.Spacing.tight)
        case nil:
            // 展开但正文还没回来（点开的同一次更新里会出现一帧）：给 spinner，
            // 不留一块空白。
            HStack(spacing: DSHTheme.Spacing.tight) {
                ProgressView().controlSize(.mini)
                Text("正在取正文…")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.processLabel)
            }
            .padding(DSHTheme.Spacing.tight)
        }
    }
}

/// 桌面 `RunningWhaleTail` 的那条鲸尾路径（16×16 视图框，描边 1）。
///
/// 手机没有那套 APNG 动图，只画静态路径：形状本身与桌面同源，缩放由帧尺寸决定。
struct WhaleTailShape: Shape {
    /// 桌面 SVG 的 `d`，按 16×16 的视图框逐段转录（描边路径，不闭合）。
    private static let segments: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: 8.967, y: 12.328), CGPoint(x: 8.45, y: 10.4), CGPoint(x: 8.45, y: 9.65)),
        (CGPoint(x: 8.45, y: 8.94), CGPoint(x: 8.88, y: 8.43), CGPoint(x: 9.6, y: 8.43)),
        (CGPoint(x: 11.285, y: 8.43), CGPoint(x: 12.106, y: 8.281), CGPoint(x: 12.685, y: 8.104)),
        (CGPoint(x: 13.71, y: 7.791), CGPoint(x: 14.585, y: 6.768), CGPoint(x: 15.055, y: 5.945)),
        (CGPoint(x: 15.137, y: 5.803), CGPoint(x: 14.99, y: 5.641), CGPoint(x: 14.829, y: 5.671)),
        (CGPoint(x: 13.829, y: 5.86), CGPoint(x: 12.828, y: 5.376), CGPoint(x: 11.827, y: 4.978)),
        (CGPoint(x: 10.659, y: 4.514), CGPoint(x: 9.491, y: 4.707), CGPoint(x: 8.935, y: 4.876)),
        (CGPoint(x: 8.805, y: 4.915), CGPoint(x: 8.658, y: 4.819), CGPoint(x: 8.636, y: 4.686)),
        (CGPoint(x: 8.468, y: 3.643), CGPoint(x: 7.405, y: 2.615), CGPoint(x: 5.498, y: 2.238)),
        (CGPoint(x: 4.54, y: 2.048), CGPoint(x: 3.748, y: 1.574), CGPoint(x: 3.347, y: 1.202)),
        (CGPoint(x: 3.252, y: 1.113), CGPoint(x: 3.088, y: 1.125), CGPoint(x: 3.03, y: 1.242)),
        (CGPoint(x: 2.628, y: 2.059), CGPoint(x: 2.168, y: 3.82), CGPoint(x: 5.248, y: 6.115)),
        (CGPoint(x: 5.82, y: 6.494), CGPoint(x: 6.31, y: 6.785), CGPoint(x: 6.574, y: 7.637)),
        (CGPoint(x: 6.72, y: 8.104), CGPoint(x: 6.157, y: 9.168), CGPoint(x: 6.061, y: 9.368)),
        (CGPoint(x: 5.157, y: 11.27), CGPoint(x: 5.089, y: 12.19), CGPoint(x: 4.926, y: 13.742)),
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 8.844, y: 13.742))
        for segment in Self.segments {
            path.addCurve(to: segment.2, control1: segment.0, control2: segment.1)
        }
        let scale = min(rect.width, rect.height) / 16
        let scaled = path.applying(CGAffineTransform(scaleX: scale, y: scale))
        let bounds = scaled.boundingRect
        return scaled.offsetBy(dx: (rect.width - bounds.width) / 2 - bounds.minX,
                               dy: (rect.height - bounds.height) / 2 - bounds.minY)
    }
}
#endif

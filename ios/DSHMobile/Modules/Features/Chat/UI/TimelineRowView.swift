#if os(iOS)
import DSHCore
import DSHDesign
import DSHKit
import SwiftUI
import DSHChatDomain

/// Renders one transcript row.
///
/// The visual language mirrors the desktop client: the human's messages are
/// tinted bubbles, assistant prose is plain and full-width, thinking is
/// collapsed, and tool calls are bordered cards that expand into their
/// arguments and output.
struct TimelineRowView: View {
    let item: TimelineItem

    var body: some View {
        row
            // `contain` makes the row itself an element that is queryable and
            // annotatable while leaving its children reachable. Without it a
            // plain container is not an accessibility element at all, so the
            // identifier was invisible to both UI tests and VoiceOver.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }

    /// Stable identifier so UI tests can address a row without depending on
    /// its rendered text.
    private var identifier: String {
        switch item.kind {
        case .userMessage: return "row.user"
        case .assistantText: return "row.assistant"
        case .reasoning: return "row.reasoning"
        case .toolCall: return "row.tool"
        case .notice: return "row.notice"
        case .turnDivider: return "row.turnEnd"
        case .unknown: return "row.unknown"
        case .gap: return "row.gap"
        case .processHeader(let header):
            if header.scope == .group { return "row.process.group" }
            return header.turn > 0 ? "row.process.turn.\(header.turn)" : "row.process"
        case .processStep: return "row.process.step"
        case .runningLine: return "row.runningLine"
        }
    }

    /// 缺口行被点（失败态的「点击重试」）：把缺口范围交回给调用方（ChatModel）。
    /// 默认 nil：列表宿主之外（搜索面板等）的行不可点。
    var onGapRetry: ((_ start: Int, _ end: Int) -> Void)?
    /// T022 失败用户消息被点（「发送失败，点击重发」）：把行身份交回调用方。
    var onSendRetry: ((_ rowId: String) -> Void)?
    /// 「已发送，未确认，点击核对」被点：把行身份交回给调用方（只核对，不重发）。
    var onSendVerify: ((_ rowId: String) -> Void)?
    /// 018：活动适配层（`subagent` 卡的状态与已跑时长；能力位缺失时不传）。
    var activity: ActivityModel?
    /// 018：打开子会话（装配层压入导航栈）。
    var onOpenSession: ((String) -> Void)?
    /// 018：这一行属于哪个会话（子智能体停止要用父会话 id）。
    var parentSessionId: String?
    /// 运行行的单行文案（步数/类型/字数），由 ChatView 从模型计算后传入。
    var running: RunningLineDescriptor?
    /// 033：过程节点的展开/收起回调。nil 时节点不可操作（预览等场景）。
    var onToggleProcess: (() -> Void)?
    /// 概要 v2：步骤卡是否展开（模型持有），以及点开/重试。
    var onToggleProcessStep: ((String) -> Void)?
    var onRetryProcessStep: ((String) -> Void)?
    /// 运行中过程区的实时状态：只有当前那条分组行会用它写「正在… · 命令」。
    var processRunning: ProcessRunningDetail?

    @ViewBuilder
    private var row: some View {
        switch item.kind {
        case .userMessage(let text, let images, let isSteering, let isPending, let isAgentSent):
            UserMessageRow(
                text: text,
                images: images,
                isSteering: isSteering,
                isPending: isPending,
                isAgentSent: isAgentSent,
                sendFailed: item.sendFailed,
                sendUnconfirmed: item.sendUnconfirmed,
                time: item.at,
                onResend: item.sendFailed ? { onSendRetry?(item.id) } : nil,
                onVerify: item.sendUnconfirmed ? { onSendVerify?(item.id) } : nil
            )

        case .assistantText(let text):
            // 流式行（isStreaming）整块按纯文本渲染，结束后一次完整解析
            // （代码块补高亮并进 A 类缓存，key 带行身份，T020）。
            VStack(alignment: .leading, spacing: 2) {
                MarkdownText(text: text, isStreaming: item.isStreaming, cacheKey: item.id)
                if let at = item.at {
                    Text(at, format: .dateTime.hour().minute())
                        .font(.system(size: 11))
                        .foregroundStyle(DSHTheme.labelDimmed)
                        .accessibilityLabel(at.formatted(date: .omitted, time: .shortened))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .reasoning(let text):
            ReasoningRow(text: text)

        case .toolCall(let invocation):
            ToolCallRow(
                invocation: invocation,
                activity: activity,
                parentSessionId: parentSessionId,
                onOpenSession: onOpenSession
            )

        case .notice(let text, let isError):
            NoticeRow(text: text, isError: isError)

        case .turnDivider:
            // 分隔行已并入轮次行（底边 0.5pt 线），折叠投影不再输出它。
            // 这个分支为「原始行」路径（搜索、长按）留空，不再画第二条「已完成」。
            EmptyView()

        case .unknown:
            EmptyView()

        case .gap(let start, let end, let status):
            GapRowView(status: status) { onGapRetry?(start, end) }

        case .processHeader(let header):
            if header.scope == .group {
                ProcessGroupRow(header: header, running: processRunning) { onToggleProcess?() }
            } else {
                ProcessTurnRow(header: header) { onToggleProcess?() }
            }

        case .runningLine(let line):
            RunningLine(since: line.since, descriptor: running)

        case .processStep(let step):
            ProcessStepRow(
                step: step,
                isExpanded: step.isExpanded,
                onToggle: { onToggleProcessStep?(step.id) },
                onRetry: { onRetryProcessStep?(step.id) }
            )
        }
    }
}

// MARK: - 缺口行（spec 009 / tasks T014）

/// 缺口占位行：固定高度（44pt），三态——spinner / 「加载失败，点击重试」（可点）/
/// 「已到最早」。高度定死是关键纪律：加载态只以缺口行表达，数据行一旦出现排版
/// 必然已完成，不存在「先占位后变高」的数据行（spec 009「UI 刷新推导」）。
private struct GapRowView: View {
    let status: TimelineItem.GapStatus
    let onRetry: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .contentShape(Rectangle())
            // 标识要放在各自元素上：容器上的 accessibilityIdentifier 会下传覆盖子元素
            // 自己的 id（仓库测试约定）。失败态的容器标识会让按钮上的 chat.gap.retry
            // 被覆盖成 row.gap.failed，XCUITest 因此找不到重试条（用例 48，
            // 2026-10-11 复跑实测：屏幕上看得见、查询返回不存在）。
            .accessibilityIdentifier(containerIdentifier)
    }

    /// 失败态的对外标识就是重试按钮自己的 `chat.gap.retry`（行即是按钮）；
    /// loading/exhausted 是纯文本行，标识留在容器上。
    private var containerIdentifier: String {
        switch status {
        case .failed: return "chat.gap.retry"
        case .loading, .exhausted: return "row.gap.\(accessibilityState)"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .loading:
            HStack(spacing: DSHTheme.Spacing.hairline) {
                ProgressView().controlSize(.mini)
                Text("正在加载…")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
            }
        case .failed(let retryable):
            Button(action: onRetry) {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("加载失败，点击重试")
                        .font(DSHTheme.Typography.micro)
                }
                .foregroundStyle(DSHTheme.brand)
            }
            .buttonStyle(.plain)
            .disabled(!retryable)
            .accessibilityIdentifier("chat.gap.retry")
        case .exhausted:
            Text("已到最早")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
        }
    }

    private var accessibilityState: String {
        switch status {
        case .loading: return "loading"
        case .failed: return "failed"
        case .exhausted: return "exhausted"
        }
    }

    /// 固定高度：缺口补齐走「删缺口行 + 插数据行 + 位移修正」一次事务，
    /// 高度自始至终不变是位移残差 ≤8pt 的前提之一。
    static let height: CGFloat = 44
}

// MARK: - User message

private struct UserMessageRow: View {
    let text: String
    let images: [ContentBlock.ImageAttachment]
    let isSteering: Bool
    /// True until the host promotes a queued message into the transcript.
    let isPending: Bool
    /// True when the agent sent this, not the person holding the phone.
    let isAgentSent: Bool
    /// T022：没发出去（发送失败 / 重启恢复未发出），行尾给可点的重发入口。
    var sendFailed: Bool = false
    /// 已受理、确认帧却没来（宿主撤单、轮次以错误结束）。既不是"等待开始"，
    /// 也不是"没发出去"：点一次核对，服务端查重命中就转已发送，否则才允许重发。
    var sendUnconfirmed: Bool = false
    var time: Date?
    var onResend: (() -> Void)?
    var onVerify: (() -> Void)?

    /// The agent's own messages sit on the agent's side, like every other thing
    /// it says. They arrive as prompts — the protocol's only door for a picture
    /// — so without this they would be drawn as if the user had sent them.
    private var alignment: HorizontalAlignment { isAgentSent ? .leading : .trailing }

    var body: some View {
        HStack {
            if !isAgentSent { Spacer(minLength: 40) }
            VStack(alignment: alignment, spacing: DSHTheme.Spacing.hairline) {
                if isSteering {
                    Text("插入当前轮次")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.brand)
                } else if sendFailed {
                    // T022：复用缺口行的重试视觉（箭头 + 品牌色小字），点击重发。
                    Button(action: { onResend?() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .semibold))
                            Text("发送失败，点击重发")
                                .font(DSHTheme.Typography.micro)
                        }
                        .foregroundStyle(DSHTheme.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.send.retry")
                } else if isPending {
                    // Immediate acknowledgement that the message was accepted,
                    // before the host has had time to start its turn.
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text("已发送，等待开始")
                            .font(DSHTheme.Typography.micro)
                    }
                    .foregroundStyle(DSHTheme.labelTertiary)
                } else if sendUnconfirmed {
                    // 已受理，但确认帧没来（典型：宿主在轮次失败时把队列项撤了，
                    // 撤单帧又不带被撤项身份）。不能一直挂着"等待开始"，也不能
                    // 直接当"没发出去"——点一次核对，查重命中才算已发送。
                    Button(action: { onVerify?() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 9))
                            Text("已发送，未确认，点击核对")
                                .font(DSHTheme.Typography.micro)
                        }
                        .foregroundStyle(DSHTheme.labelTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.send.verify")
                }
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
                    if !images.isEmpty {
                        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
                            ForEach(images, id: \.attachmentId) { image in
                                AttachmentThumbnail(attachment: image, maxHeight: 220)
                            }
                        }
                    }
                    if !text.isEmpty {
                        Text(text)
                            .font(DSHTheme.Typography.body)
                            .foregroundStyle(DSHTheme.labelPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, DSHTheme.Spacing.standard)
                .padding(.vertical, DSHTheme.Spacing.tight)
                .background(
                    RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous)
                        .fill(isAgentSent ? DSHTheme.layer1 : DSHTheme.brandSubtle)
                )
                .opacity(isPending ? 0.66 : 1)
                if let time {
                    Text(time, format: .dateTime.hour().minute())
                        .font(.system(size: 11))
                        .foregroundStyle(DSHTheme.labelDimmed)
                        .accessibilityLabel(time.formatted(date: .omitted, time: .shortened))
                }
            }
            if isAgentSent { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Reasoning

/// Collapsed chain-of-thought, matching the desktop client's disclosure.
private struct ReasoningRow: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                    Text("思考过程")
                        .font(DSHTheme.Typography.micro)
                    Spacer(minLength: 0)
                    Text("\(text.count) 字")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelDimmed)
                }
                .foregroundStyle(DSHTheme.labelTertiary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DSHTheme.Spacing.loose)
                    .padding(.bottom, DSHTheme.Spacing.hairline)
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                .fill(DSHTheme.layer1)
        )
    }
}

// MARK: - Tool call

/// One tool invocation: header, expandable arguments, and its output.
struct ToolCallRow: View {
    let invocation: ToolInvocation
    /// 018：活动适配层（能力位缺失时 nil → 卡片不新增任何一行）。
    var activity: ActivityModel?
    /// 018：子会话的父会话 id（停止要它）。
    var parentSessionId: String?
    /// 运行行的单行文案（步数/类型/字数），由 ChatView 从模型计算后传入。
    var running: RunningLineDescriptor?
    /// 018：打开子会话。
    var onOpenSession: ((String) -> Void)?
    /// `nil` follows the default for this result; a tap pins it either way.
    @State private var expansionOverride: Bool?
    /// 018：「停止」的第一下（3 秒内第二下才发请求）。
    @State private var armedStop = false
    @State private var disarmTask: Task<Void, Never>?
    /// Whether the raw arguments and the machine text are on screen. Off by
    /// default for a card whose point is the picture: `{"caption": "…",
    /// "screenshot": true}` and a `<path>…</path>` handle next to a screenshot
    /// are noise — the picture is the whole message.
    @State private var showsDetails = false

    private var hasOutput: Bool { !invocation.resultBlocks.isEmpty }

    /// True when this result carries a picture.
    ///
    /// Such a card opens by itself. A screenshot the agent took is the point of
    /// the message that contains it, and leaving it behind a collapsed
    /// disclosure means the picture is never seen without hunting for it.
    private var hasImage: Bool {
        invocation.resultBlocks.contains { block in
            if case .image = block { return true }
            return false
        }
    }

    /// Open by default only when the result is a picture **and the call worked**.
    ///
    /// A failed `read_image` is the case that taught this: the tool returns the
    /// text it fetched plus a picture, the error made it "not picture-only", and
    /// `hasImage` opened the card — so a failed fetch dumped the whole page into
    /// the transcript as an exception message. A failure now starts folded like
    /// any other card, with its text one tap away.
    private var isExpanded: Bool {
        expansionOverride ?? (hasImage && !invocation.isError)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Hairline()
                details
            }
            if subagentFooterVisible {
                Hairline()
                subagentFooter
            }
        }
        .background(DSHTheme.layer1)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous)
                .stroke(invocation.isError ? DSHTheme.danger.opacity(0.4) : DSHTheme.border1, lineWidth: 1)
        )
    }

    // MARK: - subagent 卡（018 §4）

    /// 从调用结果文本里取子会话 id（格式 `started subagent <childSessionId>`）。
    /// 拿不到证据就不加任何新行——不猜哪个后台身份属于这张卡。
    private var subagentChildId: String? {
        guard invocation.name == "subagent", !invocation.isRunning else { return nil }
        guard let range = invocation.resultText.range(of: "started subagent ") else { return nil }
        let tail = invocation.resultText[range.upperBound...]
        let id = tail.prefix { character in
            character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "." || character == ":"
        }
        return id.isEmpty ? nil : String(id)
    }

    private var subagentChild: SessionSummary? {
        guard let id = subagentChildId else { return nil }
        return activity?.summary(sessionId: id)
    }

    private var subagentFooterVisible: Bool {
        activity?.isAvailable == true && subagentChildId != nil
    }

    private var subagentFooter: some View {
        HStack(spacing: DSHTheme.Spacing.tight) {
            if let child = subagentChild {
                if child.isSubagentActive, let since = child.subagentActiveSince {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("运行中 · \(ActivityDuration.clock(sinceMilliseconds: since))")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.brand)
                            .monospacedDigit()
                    }
                } else {
                    Text("已完成")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
            }
            Spacer(minLength: 0)
            if subagentChild?.isSubagentActive == true,
               subagentChild?.subagentMode == .continuable {
                subagentStopControl
            }
            if let childId = subagentChildId {
                Button {
                    onOpenSession?(childId)
                } label: {
                    Text("打开子会话 ›")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.brand)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.tool.openChild")
            }
        }
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.vertical, DSHTheme.Spacing.tight)
    }

    /// 与面板同一套：三级灰小字、两段确认、不乐观改状态。
    private var subagentStopControl: some View {
        Button {
            if armedStop {
                armedStop = false
                disarmTask?.cancel()
                guard let childId = subagentChildId, let parentSessionId else { return }
                Task {
                    await activity?.stopSubagent(
                        childSessionId: childId,
                        parentSessionId: parentSessionId
                    )
                }
            } else {
                armedStop = true
                disarmTask?.cancel()
                disarmTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { armedStop = false }
                }
            }
        } label: {
            Text(armedStop ? "再按一次停止" : "停止")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(armedStop ? DSHTheme.danger : DSHTheme.labelTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.tool.stopSubagent")
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { expansionOverride = !isExpanded }
        } label: {
            HStack(spacing: DSHTheme.Spacing.tight) {
                Image(systemName: Self.icon(for: invocation.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(invocation.isError ? DSHTheme.danger : DSHTheme.brand)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    // Tool names come from the host ("read", "bash") and pass
                    // through untouched; the labels this client mints itself for
                    // a result whose call never loaded are translated.
                    Text(String(localized: String.LocalizationValue(invocation.name)))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelSecondary)
                    if !invocation.summary.isEmpty {
                        Text(invocation.summary)
                            .font(DSHTheme.Typography.code)
                            .foregroundStyle(DSHTheme.labelPrimary)
                            .lineLimit(isExpanded ? 4 : 2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 0)

                if invocation.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else if invocation.isError {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DSHTheme.danger)
                } else if hasOutput {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DSHTheme.success)
                }

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
        // The card's own row is a container (children: .contain), so a tap
        // aimed at `row.tool` lands on the container and toggles nothing. Give
        // the disclosure itself an address.
        .accessibilityIdentifier("tool.header")
    }

    /// True when the arguments are worth a line at all.
    private var hasArguments: Bool {
        !invocation.arguments.isEmpty && invocation.arguments != "{}"
    }

    /// The picture-only view of a result that carries one.
    ///
    /// A tool that returns an image also returns the text it needed for the
    /// model — a `<path>`/`<type>` handle for `read_image`, a file name and size
    /// for `send_image`, or the whole fetched page when the fetch failed. None of
    /// that is what the person is looking at, and it pushes the picture down the
    /// card. Failures are included: a failed call with a picture now keeps its
    /// text behind 「显示详情」 as well, which is what stops an exception message
    /// from arriving as a wall of text.
    private var pictureOnly: Bool { hasImage }

    private var detailBlocks: [ContentBlock] {
        // 「显示详情」 has to bring the text back with the parameters: the whole
        // point of the disclosure is that nothing became unreachable. (It did
        // exactly that on the first run of TC-MOB-24 — the parameters appeared
        // and the machine text stayed hidden.)
        guard pictureOnly, !showsDetails else { return invocation.resultBlocks }
        let images = invocation.resultBlocks.filter { block in
            if case .image = block { return true }
            return false
        }
        return images.isEmpty ? invocation.resultBlocks : images
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
            if hasArguments, !pictureOnly || showsDetails {
                Text("参数")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
                Text(Self.prettyPrinted(invocation.arguments))
                    .font(DSHTheme.Typography.code)
                    .foregroundStyle(DSHTheme.labelSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DSHTheme.Spacing.tight)
                    .background(DSHTheme.codeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
            }

            if hasOutput {
                if !pictureOnly {
                    Text(invocation.isError ? "错误输出" : "输出")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                ToolOutputView(blocks: detailBlocks)
            } else if invocation.isRunning {
                Text("执行中…")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
            }

            // Not deleted, just out of the way: a tool call one cannot inspect is
            // worse than a slightly noisy one, and this is one small tap.
            if pictureOnly {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { showsDetails.toggle() }
                } label: {
                    Label(
                        showsDetails ? "隐藏详情" : "显示详情",
                        systemImage: showsDetails ? "chevron.up" : "chevron.down"
                    )
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.tool.arguments")
            }
        }
        .padding(DSHTheme.Spacing.tight)
    }

    /// Maps a tool name to an icon, echoing the desktop client's set.
    static func icon(for name: String) -> String {
        switch name {
        case "bash", "shell", "pwsh": return "terminal"
        case "read", "read_file": return "doc.text"
        case "write", "create": return "square.and.pencil"
        case "edit", "str_replace", "str_replace_editor", "apply_patch": return "pencil.line"
        case "glob": return "folder.badge.questionmark"
        case "grep", "search": return "magnifyingglass"
        case "web_search": return "globe"
        case "web_fetch": return "arrow.down.doc"
        case "subagent", "task": return "person.2"
        case "workflow": return "point.3.connected.trianglepath.dotted"
        case "present": return "shippingbox"
        case "todo_write", "todo": return "checklist"
        case "job_list", "jobs": return "list.bullet.rectangle"
        case "goal": return "target"
        case "skill": return "wand.and.stars"
        default: return "wrench.and.screwdriver"
        }
    }

    /// Re-indents a JSON argument string so it reads in a narrow column.
    static func prettyPrinted(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8)
        else { return json }
        return text
    }
}

/// Renders tool output, tinting unified diffs the way the desktop client does.
private struct ToolOutputView: View {
    let blocks: [ContentBlock]
    /// How much output is rendered before the reader asks for more.
    ///
    /// Every line is a real view; a few thousand of them is not something a
    /// phone should lay out just because a command was verbose.
    private let collapsedLineLimit = 120
    @State private var isShowingAllOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            ForEach(Array(Self.flatten(blocks).enumerated()), id: \.offset) { _, block in
                content(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSHTheme.Spacing.tight)
        .background(DSHTheme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
        .textSelection(.enabled)
    }

    /// Unwraps nested tool-result envelopes into a flat block list.
    ///
    /// The host nests a tool's own content one level inside a result envelope,
    /// and deeper in principle. Flattening here keeps the view non-recursive,
    /// which both avoids an opaque-type cycle and renders in one pass.
    static func flatten(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var output: [ContentBlock] = []
        var pending = Array(blocks.reversed())

        while let block = pending.popLast() {
            if case .toolResult(_, let inner, _) = block {
                // The envelope carries no text of its own: splice its children
                // in place, or drop it when it is empty.
                pending.append(contentsOf: inner.reversed())
                continue
            }
            output.append(block)
        }
        return output
    }

    /// Whether output is a unified diff rather than ordinary text.
    static func looksLikeDiff(_ lines: [String]) -> Bool {
        let markerCount = lines.filter { line in
            line.hasPrefix("@@") || line.hasPrefix("+++") || line.hasPrefix("---")
        }.count
        guard markerCount > 0 else { return false }
        // Require a real hunk header so a stray `---` rule in prose output does
        // not flip the block into a horizontally scrolling diff.
        return lines.contains { $0.hasPrefix("@@") }
    }

    @ViewBuilder
    private func content(for block: ContentBlock) -> some View {
        switch block {
        case .text(let text):
            let lines = text.components(separatedBy: .newlines)
            let limit = isShowingAllOutput ? lines.count : collapsedLineLimit
            let visible = Array(lines.prefix(limit))
            // A unified diff only reads correctly when its lines stay on one
            // line: wrapping breaks the +/- alignment that carries the meaning.
            // Ordinary output wraps normally, which is friendlier on a phone.
            if Self.looksLikeDiff(visible) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                            DiffLine(line: line)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                        DiffLine(line: line)
                    }
                }
            }
            if lines.count > limit {
                Button {
                    isShowingAllOutput = true
                } label: {
                    Text("显示其余 \(lines.count - limit) 行")
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.brand)
                        .padding(.top, DSHTheme.Spacing.hairline)
                }
                .buttonStyle(.plain)
            }

        case .image(let attachment):
            // The actual picture, not a filename: the bytes are fetched from
            // the attachment service and shown inline.
            AttachmentThumbnail(attachment: attachment)

        case .file(let attachment):
            Label(attachment.name, systemImage: "doc")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelSecondary)

        case .reasoning(let text):
            Text(text)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)

        case .toolCall(let id, let name, _):
            Label("\(name) · \(id)", systemImage: "arrow.turn.down.right")
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)

        case .toolResult:
            // Unreachable: `flatten` splices every result envelope away before
            // rendering. Rendering nothing here is what keeps this view
            // non-recursive, which SwiftUI's opaque return types require.
            EmptyView()

        case .unknown(_, let raw):
            Text(raw.compactDescription)
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelTertiary)
        }
    }
}

/// One line of tool output, tinted when it is part of a unified diff.
private struct DiffLine: View {
    let line: String

    private var tone: Color? {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return nil }
        if line.hasPrefix("+") { return DSHTheme.diffAdded }
        if line.hasPrefix("-") { return DSHTheme.diffRemoved }
        if line.hasPrefix("@@") { return DSHTheme.brandSubtle }
        return nil
    }

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(DSHTheme.Typography.code)
            .foregroundStyle(DSHTheme.labelPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, tone == nil ? 0 : 4)
            .background(tone ?? .clear)
        // No per-line `textSelection` here. A tool result can be hundreds of
        // lines, and a selectable `Text` per line is enough layout work to
        // stall the main thread while scrolling. Selection is enabled once on
        // the surrounding block instead.
    }
}

// MARK: - Notice

private struct NoticeRow: View {
    let text: String
    let isError: Bool

    /// Host prose can be arbitrarily long (a compaction summary, an error, and
    /// before 2026-09-24 a whole tool result whose call was not loaded). The
    /// folding rule lives in DSHKit so it is testable; this view only draws it.
    private var folded: NoticeFolding.Result { NoticeFolding.fold(text) }

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            HStack(alignment: .top, spacing: DSHTheme.Spacing.hairline) {
                Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                    .font(.system(size: 11))
                Text(isExpanded ? text : folded.text)
                    .font(DSHTheme.Typography.micro)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if folded.isTruncated {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "收起" : Self.expandLabel(hiddenLines: folded.hiddenLines))
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.brand)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("row.notice.expand")
            }
        }
        .foregroundStyle(isError ? DSHTheme.danger : DSHTheme.labelTertiary)
        .padding(.horizontal, DSHTheme.Spacing.tight)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                .fill(DSHTheme.layer1)
        )
    }

    /// A notice clipped by characters alone hides no *lines*, so promising a
    /// line count there would read as "展开其余 0 行" (or a negative number).
    static func expandLabel(hiddenLines: Int) -> String {
        hiddenLines > 0 ? "展开其余 \(hiddenLines) 行" : "展开全文"
    }
}
#endif

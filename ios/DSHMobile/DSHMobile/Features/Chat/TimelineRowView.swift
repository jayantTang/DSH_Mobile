import DSHKit
import SwiftUI

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
        }
    }

    @ViewBuilder
    private var row: some View {
        switch item.kind {
        case .userMessage(let text, let images, let isSteering, let isPending, let isAgentSent):
            UserMessageRow(
                text: text,
                images: images,
                isSteering: isSteering,
                isPending: isPending,
                isAgentSent: isAgentSent
            )

        case .assistantText(let text):
            MarkdownText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .reasoning(let text):
            ReasoningRow(text: text)

        case .toolCall(let invocation):
            ToolCallRow(invocation: invocation)

        case .notice(let text, let isError):
            NoticeRow(text: text, isError: isError)

        case .turnDivider(let turn, let reason, let duration):
            TurnDividerRow(turn: turn, reason: reason, duration: duration)

        case .unknown:
            EmptyView()
        }
    }
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
            }
            if isAgentSent { Spacer(minLength: 40) }
        }
    }
}

/// The end of one turn.
///
/// Always drawn, including for ordinary completions: without a visible end, a
/// finished run and a stalled one look identical from the transcript.
struct TurnDividerRow: View {
    let turn: Int
    let reason: String
    let duration: TimeInterval?

    private var isNormal: Bool {
        reason == "completed" || reason == "unknown"
    }

    private var text: String {
        var parts: [String] = []
        parts.append(isNormal ? String(localized: "已完成") : Self.describe(reason))
        if let duration {
            parts.append(String(format: "%.1fs", duration))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            Rectangle()
                .fill(DSHTheme.border1)
                .frame(height: 1)
            HStack(spacing: 3) {
                Image(systemName: isNormal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(text)
                    .font(DSHTheme.Typography.micro)
                    .fixedSize()
            }
            .foregroundStyle(isNormal ? DSHTheme.success : DSHTheme.danger)
            Rectangle()
                .fill(DSHTheme.border1)
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityLabel("第 \(turn) 轮\(text)")
    }

    static func describe(_ reason: String) -> String {
        switch reason {
        case "cancelled", "canceled": return "已取消"
        case "interrupted": return "被中断"
        case "error", "failed": return "出错结束"
        case "max-steps": return "达步数上限"
        default: return "结束：\(reason)"
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
    /// `nil` follows the default for this result; a tap pins it either way.
    @State private var expansionOverride: Bool?
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
        }
        .background(DSHTheme.layer1)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.large, style: .continuous)
                .stroke(invocation.isError ? DSHTheme.danger.opacity(0.4) : DSHTheme.border1, lineWidth: 1)
        )
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

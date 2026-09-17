import DSHKit
import SwiftUI

/// One session transcript, with the composer pinned to the bottom.
struct ChatView: View {
    @Environment(AttachmentImages.self) private var attachmentImages
    @Environment(ConnectionStore.self) private var store
    @Environment(HostEventHub.self) private var hub
    @Bindable var model: ChatModel
    /// Opens the workspace browser. Nil until that surface is available, in
    /// which case its affordance is hidden rather than shown disabled.
    var onOpenFiles: ((SessionSummary) -> Void)?
    /// Opens the plugin WebView fallback for one origin.
    var onOpenWeb: ((URL) -> Void)?

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isShowingModelPicker = false
    @State private var isShowingInfo = false
    /// Whether new output should pull the view to the bottom. Turning this off
    /// while the reader is scrolling back is what stops a running turn from
    /// yanking them away from what they are reading.
    @State private var isFollowing = true
    /// The session already anchored on open, so it is done only once.
    @State private var anchoredSessionId: String?
    /// Rate limit for tail scrolling during a stream.
    @State private var lastScrollAt = Date.distantPast
    /// A transient confirmation shown when a run ends. The persistent marker
    /// lives in the transcript; this exists so the end of a long run is noticed
    /// even if the reader has scrolled away from the last message.
    @State private var completionBanner: String?
    /// Owned here rather than in the composer so the transcript can re-pin
    /// itself when the keyboard changes the viewport.
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let prompts = model.pendingPrompts.first {
                PendingPromptBanner(prompt: prompts, model: model)
            }
            Hairline()
            Composer(model: model, isFocused: $isFocused)
        }
        .background(DSHTheme.background)
        .overlay(alignment: .top) {
            if let completionBanner {
                CompletionBanner(text: completionBanner)
                    .padding(.top, DSHTheme.Spacing.hairline)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: model.completionSignal) {
            guard let finished = model.completion else { return }
            let normal = finished.reason == "completed" || finished.reason == "unknown"
            var text = normal ? "本轮已完成" : TurnDividerRow.describe(finished.reason)
            if let duration = finished.duration {
                text += String(format: " · 用时 %.1fs", duration)
            }
            withAnimation(.snappy(duration: 0.2)) { completionBanner = text }
            Task {
                try? await Task.sleep(for: .seconds(3.5))
                withAnimation(.easeOut(duration: 0.25)) {
                    if completionBanner == text { completionBanner = nil }
                }
            }
        }
        // The directory is what identifies a working session at a glance; the
        // generated title is one tap away in the info popover instead of
        // occupying the navigation bar on every screen.
        .navigationTitle(headerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .alert("重命名会话", isPresented: $isRenaming) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let title = renameText
                Task { await model.rename(to: title) }
            }
        }
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerSheet(model: model)
        }
    }

    /// The directory name, falling back to the title when there is no workspace.
    private var headerTitle: String {
        if let cwd = model.session?.cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return model.session?.displayTitle ?? "会话"
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            transcriptScroll(proxy)
        }
    }

    private func transcriptScroll(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                if model.hasOlder {
                    Button {
                        Task { await model.loadOlder() }
                    } label: {
                        HStack(spacing: DSHTheme.Spacing.hairline) {
                            if model.isLoadingOlder {
                                ProgressView().controlSize(.mini)
                            }
                            Text(model.isLoadingOlder ? "加载中…" : "加载更早的消息")
                                .font(DSHTheme.Typography.micro)
                        }
                        .foregroundStyle(DSHTheme.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DSHTheme.Spacing.tight)
                    }
                    .buttonStyle(.plain)
                    .id(Self.topAnchor)
                }

                ForEach(model.timeline.items) { item in
                    TimelineRowView(item: item)
                        .id(item.id)
                }

                // Everything below is a single, permanently present tail. It
                // must not live inside an `if`: the anchor used to be attached
                // to whichever of three branches was active, so every state
                // change (send → submitting → streaming → committed) destroyed
                // and rebuilt it, and a scroll aimed at it could land on
                // nothing — leaving the transcript blank.
                Group {
                    if model.activity == .submitting, model.timeline.streaming == nil {
                        HStack(spacing: DSHTheme.Spacing.hairline) {
                            ProgressView().controlSize(.mini)
                            Text("已发送，等待电脑端开始…")
                                .font(DSHTheme.Typography.micro)
                                .foregroundStyle(DSHTheme.labelTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let streaming = model.timeline.streaming, !streaming.isEmpty {
                        StreamingBubble(attempt: streaming)
                    }
                }

                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchor)
            }
            .scrollTargetLayout()
            .padding(.horizontal, DSHTheme.Spacing.loose)
            .padding(.vertical, DSHTheme.Spacing.standard)
        }
        .accessibilityIdentifier("chat.transcript")
        // Imperative scrolling only, and only in one direction (us -> view).
        //
        // A `scrollPosition(id:)` binding was tried here and had to be removed:
        // it is bidirectional, so every user scroll rewrote the binding, which
        // re-applied the anchor, which scrolled again. On a long transcript that
        // feedback saturated the main thread and the UI stopped rendering —
        // which is exactly what a blank conversation area is.
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.sendSignal) {
            // Sending always returns to the tail, and it must not be throttled:
            // the throttled path is what left a freshly sent message appended
            // below the viewport with nothing scrolling to it, so the reader
            // saw the agent's output but never their own message.
            isFollowing = true
            scrollToBottom(proxy, force: true)
        }
        .onChange(of: model.scrollSignal) {
            guard isFollowing else { return }
            scrollToBottom(proxy)
        }
        .simultaneousGesture(
            DragGesture().onChanged { value in
                if value.translation.height > 24 { isFollowing = false }
            }
        )
        .overlay(alignment: .bottomTrailing) {
            if !isFollowing, !model.timeline.items.isEmpty {
                Button {
                    isFollowing = true
                    scrollToBottom(proxy, animated: true)
                } label: {
                    HStack(spacing: DSHTheme.Spacing.hairline) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(model.isRunning ? "回到最新" : "回到底部")
                            .font(DSHTheme.Typography.micro)
                    }
                    .foregroundStyle(DSHTheme.labelPrimary)
                    .padding(.horizontal, DSHTheme.Spacing.tight)
                    .padding(.vertical, 6)
                    .background(DSHTheme.layer3, in: Capsule())
                    .overlay(Capsule().stroke(DSHTheme.border2, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.trailing, DSHTheme.Spacing.loose)
                .padding(.bottom, DSHTheme.Spacing.tight)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .overlay {
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let message):
                ErrorStateView(message: message) {
                    if let session = model.session {
                        Task { await model.open(session) }
                    }
                }
            case .ready where model.timeline.items.isEmpty && model.activity == .idle:
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right",
                    title: "空会话",
                    message: "在下面输入内容，或从电脑端继续这个会话。"
                )
            default:
                EmptyView()
            }
        }
        .onAppear {
            isFollowing = true
            scrollToBottom(proxy, animated: false)
        }
        // Anchoring waits for content. `onAppear` runs before the session has
        // been folded, so scrolling there finds nothing and the view settles at
        // the tail instead — which is exactly the position that hides the
        // instruction under the answer.
        .onChange(of: model.session?.sessionId, initial: true) { _, sessionId in
            anchoredSessionId = nil
            // Attachments are authorized per session, so the loader has to know
            // which one the rows on screen belong to.
            attachmentImages.sessionId = sessionId
        }
        .onChange(of: model.timeline.items.count) { _, _ in anchorToLastUserMessage(proxy) }
        .onChange(of: model.phase) { _, _ in anchorToLastUserMessage(proxy) }
    }

    /// The row holding the most recent message from the user.
    ///
    /// Opening a session anchors here rather than at the very bottom: the tail
    /// of a finished run is the agent's output, and anchoring there leaves the
    /// instruction that produced it scrolled off the top — which reads as "my
    /// message is gone" even though it is in the transcript.
    private var lastUserMessageId: String? {
        model.timeline.items.last { item in
            if case .userMessage = item.kind { return true }
            return false
        }?.id
    }

    /// Puts the user's own instruction at the top of the viewport, once per
    /// session, so the answer reads underneath it.
    private func anchorToLastUserMessage(_ proxy: ScrollViewProxy) {
        let sessionId = model.session?.sessionId
        guard let sessionId, anchoredSessionId != sessionId,
              let lastUser = lastUserMessageId
        else { return }
        anchoredSessionId = sessionId
        isFollowing = false
        proxy.scrollTo(lastUser, anchor: .top)
        // Following resumes only when the reader asks for it or sends again.
    }

    /// Moves the viewport to the tail. The only place that scrolls.
    ///
    /// Throttled, because streaming appends text many times a second and each
    /// append asks to follow. Scrolling — and especially animating a scroll —
    /// on every token saturates the main thread, and a blocked main thread
    /// renders nothing, which is what a blank transcript looks like.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true, force: Bool = false) {
        let now = Date()
        if !force, animated, now.timeIntervalSince(lastScrollAt) < Self.scrollThrottle {
            return
        }
        lastScrollAt = now
        if force {
            // Twice: once now so the row is brought in as it is added, and once
            // after the layout that inserting it triggers.
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if isFollowing { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
        } else if animated, !model.isRunning {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        } else {
            // Unanimated while a run is in flight: the content moves every
            // frame anyway, so an animation per update is pure overhead.
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    /// Minimum interval between follow-the-tail scrolls.
    private static let scrollThrottle: TimeInterval = 0.15

    private static let bottomAnchor = "transcript-bottom"
    private static let topAnchor = "transcript-top"

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Run state is the one piece of status worth permanent space, and
            // only while it is actually doing something.
            if model.isRunning {
                StatusDot(level: .busy, size: 7, animated: true)
                    .accessibilityIdentifier("chat.running")
                    .accessibilityLabel("运行中")
            }

            Button {
                isShowingInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityIdentifier("chat.info")
            .accessibilityLabel("会话信息")
            .popover(isPresented: $isShowingInfo, arrowEdge: .top) {
                SessionInfoPopover(model: model, home: store.hostHome)
                    .presentationCompactAdaptation(.popover)
            }

            Menu {
                Button {
                    isShowingModelPicker = true
                } label: {
                    Label("选择模型", systemImage: "cpu")
                }
                if let session = model.session, let onOpenFiles {
                    Button {
                        onOpenFiles(session)
                    } label: {
                        Label("工作区文件", systemImage: "folder")
                    }
                }
                Divider()
                Button {
                    renameText = model.session?.displayTitle ?? ""
                    isRenaming = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button {
                    // The fork lands as a new session; the list picks it up from
                    // the host's session-added event, so nothing else to do here.
                    Task { _ = await model.fork() }
                } label: {
                    Label("从此处分叉", systemImage: "arrow.triangle.branch")
                }
                if let onOpenWeb, let base = store.activeBaseURL {
                    Divider()
                    Button {
                        onOpenWeb(base)
                    } label: {
                        Label("用网页界面打开", systemImage: "safari")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("chat.more")
            .accessibilityLabel("更多")
        }
    }
}

// MARK: - Session info

/// Everything about the session that is useful occasionally but not always.
///
/// Keeping it in a popover is the whole point: the transcript gets the screen,
/// and the metadata is one tap away rather than two permanent lines.
private struct SessionInfoPopover: View {
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
private struct StreamingBubble: View {
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
private struct PendingPromptBanner: View {
    let prompt: HostEventHub.Pending
    let model: ChatModel

    @State private var isShowingSheet = false

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
private struct OptionalTextSelection: ViewModifier {
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
private struct CompletionBanner: View {
    let text: String
    /// Only abnormal endings are tinted as warnings.
    private var isWarning: Bool {
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

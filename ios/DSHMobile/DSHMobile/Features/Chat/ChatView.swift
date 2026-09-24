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
    /// 这份转写属于哪个会话（`RootView.sessionDestination` 一屏一份，用 `.id()` 区分）。
    var sessionId: String

    /// 现在屏幕上的还是不是我的会话。
    ///
    /// 为什么必须问这一句：换会话时被推出的那一份 `ChatView` **在转场期间还活着**，
    /// 而它读的是同一个 `ChatModel`——模型已经把 timeline 换成新会话的（行数从 92
    /// 掉到 3），这份"已经不在屏幕上"的视图如果这时还发 `scrollTo`，那条已经解析成
    /// index path 的滚动就会落在新内容上。2026-09-21 18:26 的崩溃原文：
    /// `Attempted to scroll the collection view to an out-of-bounds item (91) when
    /// there are only 3 items in section 0`——91 是上一个会话的最后一行，3 是新会话
    /// 空转写的两行占位 + 底部标记。UIKit 抛的异常没人接 = 闪退。
    /// 所以：不是我的会话，就一次都不滚。
    private var ownsTranscript: Bool { model.session?.sessionId == sessionId }

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isShowingModelPicker = false
    @State private var isShowingInfo = false
    /// Whether new output should pull the view to the bottom. Turning this off
    /// while the reader is scrolling back is what stops a running turn from
    /// yanking them away from what they are reading.
    @State private var isFollowing = true
    /// Rate limit for tail scrolling during a stream.
    @State private var lastScrollAt = Date.distantPast
    /// 内容变化后排的那一次"确认仍在尾部"。可取消，所以流式输出时不会堆积。
    /// 见 `repinAfterContentChange`：这是"打开会话停在半路"的修正，只做一次、延迟执行。
    @State private var contentRepinTask: Task<Void, Never>?
    /// 打开会话时那段"钉到底部"的序列（见 `pinOnOpen`）。
    @State private var openPinTask: Task<Void, Never>?
    /// 已经排过打开钉底的会话；换会话时重置。
    @State private var openedSessionId: String?
    /// 打开钉底进行中：这段时间里的跟随滚动**不做动画**。
    /// 动画化的滚动正是"中段滑到底部"那种观感的来源——一帧内瞬移看不出来，200ms 的滑动
    /// 一定看得见。
    @State private var isPinningOnOpen = false
    /// 读者是否自己拖动过：拖动之后，打开钉底与跟随都不再抢滚动位置。
    @State private var userScrolled = false
    /// A transient confirmation shown when a run ends. The persistent marker
    /// lives in the transcript; this exists so the end of a long run is noticed
    /// even if the reader has scrolled away from the last message.
    @State private var completionBanner: String?
    /// 打开成「单条全文」的那条消息（长按正文 → 选择文本）。
    @State private var readingMessage: MessageSelection?
    /// 顶部哨兵是否已经（或即将）进入视口。见 `evaluateTopDistance`。
    @State private var sentinelNearTop = false
    /// 最近一次量到的"视口顶部离内容顶部还有多远"。
    ///
    /// 必须存下来：`onScrollGeometryChange` 只在**值变化**时回调，而"会话一打开就停在
    /// 内容顶部"这种情况（初次布局时内容还是空的）从头到尾就没变过——2026-09-24 实测
    /// 8 轮里有 2 轮整段回调都没来，补页一次都没触发。所以距离要缓存，改由
    /// "会话/内容变化"这些时机重新判一次（`evaluateTopDistance`）。
    @State private var topDistance: CGFloat?
    /// 正在跑的那串"连续补页"。见 `pumpOlder`。
    @State private var olderPump: Task<Void, Never>?
    /// 已经处理过的补页代数，用来把"头部插入"从"尾部追加"里分出来。
    @State private var handledPrepend = 0
    /// 搜索面板是否打开。
    @State private var isSearching = false
    /// 搜索面板选中的那条（行 id）：转写页滚动到它并短暂高亮。
    @State private var searchJumpId: String?
    /// 刚刚跳过去、正在高亮的那一行。
    @State private var highlightedItemId: String?
    /// 高亮的清除任务（连续跳转时上一次要取消）。
    @State private var highlightTask: Task<Void, Never>?
    /// 补页前视口里最上面那条消息的 id：补完要把它锚回视口顶部（见 `anchorAfterPrepend`）。
    @State private var prependAnchor: String?
    /// 那一次锚定的重试序列。
    @State private var prependAnchorTask: Task<Void, Never>?
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
                .probed("composer")
        }
        .background(DSHTheme.background)
        .task {
            ViewportProbe.start()
            ViewportProbe.resume()
            await ViewportProbe.runTyping(into: model, focus: $isFocused)
        }
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
                text += " · " + String(format: String(localized: "用时 %.1fs"), duration)
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
        .sheet(isPresented: $isSearching) {
            TranscriptSearchSheet(model: model) { id in searchJumpId = id }
        }
        .sheet(item: $readingMessage) { message in
            MessageTextSheet(message: message)
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
        // 转写容器用 `List`（底层是 UICollectionView 的复用）。
        //
        // 为什么不是 `ScrollView + LazyVStack`：懒加载在视口高度变化（键盘弹出、
        // 输入框长高）时会重新估算还没量到的行，估算拿"已量到的最高一行"当模板——
        // 会话里一个 6924pt 的长回答，就能把 110 行的内容高度从实测 4 万估到 87 万。
        // 滚动几何一旦是假的，任何"滚到底"（我们的跟随、系统的底部锚定）都会把视口
        // 送进一片没有渲染内容的空位：会话区整片空白，直到估算回落或用户手动一拉。
        //
        // `List` 的行同样只建可见的那些（长会话打开 6 秒级，与懒加载同量级），
        // 但内容高度由真实 cell 高度累加而来，没有那份估算。同一会话、同一操作下
        // 实测：懒加载每轮白 2–7 段（最长一段 14 秒），`List` 0 段（2/2 轮）；
        // 内容高度从"中位 29 万、最大 87 万来回跳"变成稳定在 4 万。
        //
        // 换普通 `VStack` 也能不白，但整份已加载历史都要布局，重会话打开 25 秒
        // 还没就绪，那条路已否掉（见用例 `32-长会话里边流式边打字不跳白.md`）。
        stackContainer(proxy)
        // Imperative scrolling only, and only in one direction (us -> view).
        //
        // A `scrollPosition(id:)` binding was tried here and had to be removed:
        // it is bidirectional, so every user scroll rewrote the binding, which
        // re-applied the anchor, which scrolled again. On a long transcript that
        // feedback saturated the main thread and the UI stopped rendering —
        // which is exactly what a blank conversation area is.
        .defaultScrollAnchor(.bottom)
        // 探针：滚动几何（偏移 / 内容高 / 容器高）。"落在内容之外"这种状态
        // 只能从这里看出来，光看"有没有已渲染的行"看不出来。
        .modifier(ScrollGeometryProbe())
        .accessibilityIdentifier("chat.transcript")
        // 探针：转写区自己的矩形。它和已渲染行的矩形之差就是"没被盖住的带"。
        .background(
            GeometryReader { proxy in
                let rect = proxy.frame(in: .global)
                Color.clear
                    .onAppear { ViewportProbe.setViewport(rect) }
                    .onChange(of: rect) { _, next in ViewportProbe.setViewport(next) }
            }
        )
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.sendSignal) {
            isFollowing = true
            scrollToBottom(proxy, force: true)
        }
        .onChange(of: model.scrollSignal) {
            ViewportProbe.note("scrollSignal", ["draft": String(model.draft.count)])
            guard isFollowing, ownsTranscript else { return }
            if isPinningOnOpen {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            } else {
                scrollToBottom(proxy)
            }
        }
        .simultaneousGesture(
            DragGesture().onChanged { value in
                if value.translation.height > 24 {
                    isFollowing = false
                    userScrolled = true
                }
            }
        )
        .overlay(alignment: .top) { olderLoadingPill }
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
            ViewportProbe.resume()
            scrollToBottom(proxy, animated: false)
        }
        .onChange(of: searchJumpId) { _, id in
            guard let id else { return }
            jumpToItem(id, proxy: proxy)
        }
        // 探针驱动（`-DSHProbeOlderScroll`）：仿真器里没法对转写页做手势滑动，
        // 所以"往上滑"这一段由 App 自己代劳，其余全是产品代码。
        .task { await runOlderScrollDrive(proxy) }
        // 离开转写页就暂停探针采样：退回列表后"转写区"没有任何内容可量，
        // 继续采只会把列表记成"会话区白了"。
        .onDisappear { ViewportProbe.pause() }
        .onChange(of: model.session?.sessionId, initial: true) { _, sessionId in
            attachmentImages.sessionId = sessionId
            userScrolled = false
            openedSessionId = nil
            olderPump?.cancel()
            olderPump = nil
            highlightTask?.cancel()
            highlightedItemId = nil
            searchJumpId = nil
            prependAnchorTask?.cancel()
            prependAnchorTask = nil
            prependAnchor = nil
            sentinelNearTop = false
            // 注意：**不要**把 `topDistance` 清掉。它是滚动几何的事实，不是会话状态；
            // 而"首次布局时内容还是空的、视口就停在顶部"这种情况，几何值此后**再也不变**，
            // 清了就永远补不回来（2026-09-24 实测：清了之后补页和钉底一起失灵）。
            if let sessionId { pinOnOpen(proxy, sessionId: sessionId) }
            evaluateTopDistance(proxy)
        }
        .onChange(of: model.timeline.items.count) { _, count in
            ViewportProbe.setContent(items: count, streaming: model.timeline.streaming?.text.count ?? 0)
            // 内容变了要重判一次：首次快照落地时"视口停在内容顶部"这件事本身
            // 不产生滚动几何变化，只靠回调会漏（见 `topDistance`）。
            evaluateTopDistance(proxy)
            // 头部插入（补更早的一页）不跟着钉底，改把读者原本那一行锚回视口顶部。
            if model.prependSignal != handledPrepend {
                handledPrepend = model.prependSignal
                anchorAfterPrepend(proxy)
                return
            }
            repinAfterContentChange(proxy)
        }
        .onChange(of: model.timeline.streaming?.text.count ?? 0) { _, streamed in
            ViewportProbe.setContent(items: model.timeline.items.count, streaming: streamed)
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .ready { ViewportProbe.markReady() }
        }
        .onKeyboardVisibilityChange { visible in
            ViewportProbe.note("keyboard", ["visible": visible ? "1" : "0",
                                            "following": isFollowing ? "1" : "0"])
            repinAfterViewportChange(proxy, keyboardVisible: visible)
        }
        .onChange(of: model.draft.count) { _, count in
            ViewportProbe.note("draft", ["chars": String(count),
                                         "following": isFollowing ? "1" : "0"])
        }
        .onChange(of: isFollowing) { _, following in
            ViewportProbe.note("following", ["on": following ? "1" : "0"])
            // 手指往上滑正是"到没到顶部"这条判定的输入之一。而且拖动是**唯一**不依赖
            // 滚动几何变化的信号：视口本来就停在顶部时，再拖也不产生几何变化，
            // 只靠回调会漏掉补页（2026-09-24 实测 3 轮里 1 轮）。
            evaluateTopDistance(proxy)
        }
    }

    /// 转写容器本身。抽出来是因为把 `List`/`ScrollView` 两套容器写在同一个
    /// 修饰符链里，编译器会报"表达式太复杂"。
    @ViewBuilder
    private func stackContainer(_ proxy: ScrollViewProxy) -> some View {
        if ProbeVariants.lazyStack {
            // 复现用：换回懒加载容器（`-DSHProbeVariants lazy-stack`）。
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                    stackContent(proxy)
                }
                .scrollTargetLayout()
                .padding(.horizontal, DSHTheme.Spacing.loose)
                .padding(.vertical, DSHTheme.Spacing.standard)
            }
            .modifier(TranscriptTopDistance { distance in noteTopDistance(distance, proxy: proxy) })
        } else {
            List {
                stackContent(proxy)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .modifier(TranscriptTopDistance { distance in noteTopDistance(distance, proxy: proxy) })
        }
    }

    /// 整份转写的内容（两种容器共用）。
    ///
    /// 必须**直接**吐出行，不能再套一层 `VStack`：套一层就等于让 `LazyVStack`
    /// 只有一个子视图，懒加载随之失效。
    @ViewBuilder
    private func stackContent(_ proxy: ScrollViewProxy) -> some View {
        olderSentinel(proxy)
        ForEach(model.timeline.items) { item in row(item) }
        tail
        bottomMarker
    }

    /// 顶部哨兵：读者滑到最上面就自动补更早的一页。**没有按钮**。
    ///
    /// 2026-09-24 用户反馈的原话是「每页一个『查看更多』，点了还会跳到那一段的开头」，
    /// 要的是微信那种"一直往上滑就一直有"。所以这里换成一行哨兵：
    ///
    /// - 它一进入视口（提前 `sentinelApproach`，见 `noteTopDistance`）就自己补页，读者不用点；
    /// - 补回来的一页**长在视口上方**：`anchorAfterPrepend` 把补页前的那一条重新锚回
    ///   视口顶部，于是读者手指底下的内容一动不动，继续上滑才看到更早的消息。
    ///   这正是"跳到新那段开头"的解药——不锚的话，`List` 保留的是偏移量而不是
    ///   可见内容，插进头部的高度会把视口顶到新页的中间去。
    /// - 它**永远占一行、高度永远 1pt**（这是老约束，见 `tail` 的注释）：转写容器是
    ///   `UICollectionView` 撑起来的，`scrollTo` 先把锚点解析成 index path，
    ///   行数在这中间少一行，那条滚动就越界崩溃。行高也必须恒定——哨兵上面长出来的
    ///   任何一点高度都会让"把某一行锚回顶部"差出那么多（实测差 13pt）。
    ///   所以"正在加载"不画在这一行里，而是浮在转写区顶部（`olderLoadingPill`）。
    @ViewBuilder
    private func olderSentinel(_ proxy: ScrollViewProxy) -> some View {
        Color.clear
            .frame(height: 1)
            .modifier(TranscriptRowChrome(inList: !ProbeVariants.lazyStack))
            .id(Self.topAnchor)
            // iOS 17 上没有滚动几何，补页只能靠"这一行被建出来"（= 读者滑到了最上面）。
            // iOS 18 起由 `TranscriptTopDistance` 说了算，这里不再抢着触发。
            .onAppear {
                guard !TranscriptTopDistance.available else { return }
                // 17 上没有滚动几何，只能拿"行被建出来"当信号。多一道 `!isFollowing`：
                // 读者还在看最新的一轮（跟随时）不该因为 `List` 提前建了这行就补页——
                // 补页会往视口上方插内容，而那时没法把位置锚回来。
                guard !isFollowing, model.hasOlder else { return }
                sentinelNearTop = true
                ViewportProbe.note("older.sentinel", ["near": "1", "why": "appear",
                                                     "items": String(model.timeline.items.count)])
                pumpOlder(proxy)
            }
            .onDisappear {
                guard !TranscriptTopDistance.available else { return }
                sentinelNearTop = false
            }
    }

    /// 补页进行中的提示：浮在转写区顶部，不进内容（行高恒定，见 `olderSentinel`）。
    @ViewBuilder
    private var olderLoadingPill: some View {
        if model.isLoadingOlder {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                ProgressView().controlSize(.mini)
                Text("正在加载更早的消息…")
                    .font(DSHTheme.Typography.micro)
                    .foregroundStyle(DSHTheme.labelSecondary)
            }
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, 5)
            .background(DSHTheme.layer3, in: Capsule())
            .overlay(Capsule().stroke(DSHTheme.border2, lineWidth: 1))
            .padding(.top, DSHTheme.Spacing.hairline)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// 一行消息。抽出来是为了让"懒加载/非懒加载"两种排布共用同一份定义。
    private func row(_ item: TimelineItem) -> some View {
        TimelineRowView(item: item)
            // 搜索跳过来的那一行：淡底 + 左侧色条，一眼能认出"就是这条"。
            .background(alignment: .leading) {
                if highlightedItemId == item.id {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DSHTheme.brand.opacity(0.10))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(DSHTheme.brand)
                                .frame(width: 2)
                        }
                }
            }
            .modifier(TranscriptRowChrome(inList: !ProbeVariants.lazyStack))
            .id(item.id)
            .probed("row:\(item.id)")
            // 长按 = 这一行的文字入口：全文/选择文本、拷贝整条。
            //
            // 为什么长按菜单而不是长按选中：转写容器是 `List`，长按会被 cell
            // 先接走，行上声明的 `textSelection` 根本到不了手指；选中改在打开的
            // 全文页里做（那里由文本视图自己接管手势）。`contextMenu` 在 List 行上
            // 是稳的，且不引入任何新的滚动手势——转写容器刚因跳白/闪退加固过。
            .modifier(MessageActions(item: item) { readingMessage = $0 })
    }

    /// 尾部那块（等待提示或流式气泡）。
    ///
    /// 它必须**永远存在**、不能住在 `if` 里：早先锚点挂在三个分支中的某一个上，
    /// 每次状态变化（send → submitting → streaming → committed）都会把它销毁重建，
    /// 指向它的滚动就会落空——那正是"整片空白"。
    ///
    /// 而且它必须**永远占一行**。转写容器是 `UICollectionView` 撑起来的，`scrollTo`
    /// 先把锚点解析成一个 item 的 index path，到下一次内容更新时才真正执行；行数只要
    /// 在这中间少一行，那条已经解析好的"最后一行"就越界。UIKit 不返回空、直接抛
    /// `NSInternalInconsistencyException`，没人接 = 闪退。崩溃报告实例（2026-09-21）：
    /// `Attempted to scroll the collection view to an out-of-bounds item (61) when there
    /// are only 61 items in section 0`——发送那一刻行数是 62（钉底就是钉第 61 项），
    /// host 一开始跑、这行等待提示消失，就只剩 61 行。空着也得留一行。
    @ViewBuilder
    private var tail: some View {
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
            } else {
                // 没有提示、也没有气泡时的占位：1pt、看不见，只为"这一行在"。
                Color.clear.frame(height: 1)
            }
        }
        .modifier(TranscriptRowChrome(inList: !ProbeVariants.lazyStack))
        .probed("tail")
    }

    /// 内容末尾的 1pt 标记，滚到底的目标。
    private var bottomMarker: some View {
        Color.clear
            .frame(height: 1)
            .modifier(TranscriptRowChrome(inList: !ProbeVariants.lazyStack))
            .id(Self.bottomAnchor)
            .probed("bottom")
    }

    /// 记下新的距离并重新判定（iOS 18 起才有距离可测；更低的系统只剩哨兵的 `onAppear`）。
    private func noteTopDistance(_ distance: CGFloat, proxy: ScrollViewProxy) {
        topDistance = distance
        evaluateTopDistance(proxy)
    }

    /// 视口贴在内容顶部时该做什么。
    ///
    /// 两件事，顺序不能反：
    /// 1. **该在底部却停在顶部**——读者没往上翻过（`isFollowing`）却已经在内容顶部，
    ///    那是"打开会话没钉到底"（老毛病，8 轮里见 2 轮：初次布局时内容还是空的，
    ///    `pinOnOpen` 那一串滚完就再没人管了）。这时补页是错的：读者要看的是最新。
    ///    钉回底部，距离随之变大，补页自然不触发。
    /// 2. **读者真在顶部**——补一页。补完距离会跳成"一页那么高"，于是重新武装，
    ///    再滑上来就再补，不用点任何东西。
    private func evaluateTopDistance(_ proxy: ScrollViewProxy) {
        guard ownsTranscript else { return }
        guard let distance = topDistance else {
            // 一次滚动几何都没量到（iOS 17，或内容落地前）：按"该在底部"处理——
            // 读者没往上翻过就钉回底部，别停在会话开头。
            ViewportProbe.note("older.nogeometry", [
                "following": isFollowing ? "1" : "0",
                "items": String(model.timeline.items.count),
            ])
            if isFollowing, !userScrolled { scrollToBottom(proxy, animated: false, force: true) }
            return
        }
        let near = distance < Self.sentinelApproach
        if near != sentinelNearTop {
            sentinelNearTop = near
            ViewportProbe.note("older.sentinel", [
                "distance": String(format: "%.0f", distance),
                "near": near ? "1" : "0",
                "following": isFollowing ? "1" : "0",
                "items": String(model.timeline.items.count),
            ])
        }
        guard near else { return }
        if isFollowing, !userScrolled {
            ViewportProbe.note("older.repin", ["distance": String(format: "%.0f", distance)])
            // 带一次延迟重钉：这次判定往往发生在"内容刚落地、行还没排完"的那一刻，
            // 单次 `scrollTo` 会落在空布局上（2026-09-24 实测 3 轮里 1 轮就这么卡住了）。
            repinAfterContentChange(proxy)
            return
        }
        pumpOlder(proxy)
    }

    /// 连续补页：只要视口还贴着已加载内容的顶部、上面还有更早的消息，就一直补。
    ///
    /// 三条约束，每一条都对应一个已经看到的坏现象：
    /// 1. 补页前记住"当前第一条"，补完由 `anchorAfterPrepend` 把它锚回视口顶部——
    ///    新内容因此长在视口**上方**。不锚的话 `List` 保留的是偏移量而不是可见内容，
    ///    插进头部的高度会把视口顶进新那一页的中间，也就是用户说的"跳到新那段的开头"。
    /// 2. 一次上滑最多连补 `maxOlderBurst` 页：视口比一页还高（短会话）时补一页填不满
    ///    屏幕，那就接着补；但绝不允许无限补下去。
    /// 3. 每次补完等一拍再判断"视口还在不在顶部"：锚定与插入都要下一帧才落地。
    private func pumpOlder(_ proxy: ScrollViewProxy) {
        guard ownsTranscript, sentinelNearTop, model.hasOlder, !model.isLoadingOlder,
              olderPump == nil else { return }
        olderPump = Task { @MainActor in
            defer { olderPump = nil }
            for _ in 0..<Self.maxOlderBurst {
                if Task.isCancelled || !ownsTranscript { return }
                let anchor = model.timeline.items.first?.id
                let before = ViewportProbe.scrollFacts
                let count = model.timeline.items.count
                await model.loadOlder()
                guard model.timeline.items.count > count else { return }
                prependAnchor = anchor
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
                let after = ViewportProbe.scrollFacts
                var kept = "-"
                if let before, let after {
                    let movedOffset = after.offset - before.offset
                    let grewContent = after.content - before.content
                    kept = abs(movedOffset - grewContent) <= Self.keepTolerance ? "1" : "0"
                    if kept == "0" {
                        ViewportProbe.note("older.jumped", [
                            "movedOffset": String(format: "%.0f", movedOffset),
                            "grewContent": String(format: "%.0f", grewContent),
                            "items": String(model.timeline.items.count),
                        ], force: true)
                    }
                }
                ViewportProbe.note("older.pump", [
                    "items": String(model.timeline.items.count),
                    "anchor": anchor ?? "-",
                    "hasOlder": model.hasOlder ? "1" : "0",
                    // `kept == 1` = 内容长了多少、偏移就跟着走了多少：可见内容没动。
                    "kept": kept,
                ], force: true)
                if !sentinelNearTop { return }
            }
        }
    }

    /// 补页之后把"补页前那一条"锚回视口顶部——读者原地不动。
    ///
    /// 为什么不能在 `loadOlder()` 返回时立刻锚：那一刻 `List` 还没应用这次插入
    /// （2026-09-24 实测：锚定滚动的落点是"插入前"的布局，偏移停在 -103，插入一生效，
    /// 视口就留在了新内容上）。所以真正的锚定放在**视图看到条数变化之后**
    /// （`onChange(of: items.count)`），并按 0 / 60 / 160 / 320ms 重试几次：
    /// 第一次通常和插入同一帧落地，后面几次兜住"行高还在折"的情况。
    /// 视口一旦离开顶部（`sentinelNearTop == false`）就停手，绝不和读者抢滚动。
    private func anchorAfterPrepend(_ proxy: ScrollViewProxy) {
        guard let anchor = prependAnchor else { return }
        prependAnchorTask?.cancel()
        prependAnchorTask = Task { @MainActor in
            for delay in [0, 60, 160, 320] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                if Task.isCancelled || !ownsTranscript { return }
                guard model.timeline.items.contains(where: { $0.id == anchor }) else { return }
                if !sentinelNearTop { return }
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    /// 滚到搜索选中的那一行，并高亮一会儿。
    ///
    /// 三次重试的理由和 `pinOnOpen` 一样：目标行的位置要等 `List` 把这一批行折完才准，
    /// 只滚一次会落在"当时的"位置上。同时把跟随关掉、并记成"读者自己滚过"——
    /// 否则滚过去之后只要内容一变，`repinAfterContentChange` 就把人拽回底部。
    private func jumpToItem(_ id: String, proxy: ScrollViewProxy) {
        guard ownsTranscript else { return }
        isFollowing = false
        userScrolled = true
        ViewportProbe.note("search.jump", ["item": id], force: true)
        Task { @MainActor in
            for delay in [0, 120, 300] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                if Task.isCancelled || !ownsTranscript { return }
                guard model.timeline.items.contains(where: { $0.id == id }) else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            highlightedItemId = id
            highlightTask?.cancel()
            highlightTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1600))
                if Task.isCancelled { return }
                if highlightedItemId == id { highlightedItemId = nil }
            }
        }
    }

    /// `-DSHProbeOlderScroll <n>`：由 App 自己把视口送到顶部 n 次（见
    /// `ViewportProbe.olderScrollRounds`）。仿真器里没法对转写页做手势滑动，
    /// 所以"一直往上滑"这一段只能这样驱动；送上去之后的一切都是产品代码。
    private func runOlderScrollDrive(_ proxy: ScrollViewProxy) async {
        guard let rounds = ViewportProbe.olderScrollRounds, rounds > 0 else { return }
        // 等首屏与钉底那一串走完，否则驱动会和 `pinOnOpen` 抢滚动位置。
        try? await Task.sleep(for: .seconds(6))
        for round in 1...rounds {
            guard ownsTranscript, !Task.isCancelled else { return }
            // 手指挥做的事这里也要做：真实拖动会把"跟随中"关掉（见 `simultaneousGesture`），
            // 而 `scrollTo` 不会。不置这一位，读者到了顶部却还被判成"在看最新"，
            // 于是被钉回底部（`evaluateTopDistance` 的第一条），补页永远不触发。
            isFollowing = false
            userScrolled = true
            ViewportProbe.note("older.drive", [
                "round": String(round), "phase": "up",
                "items": String(model.timeline.items.count),
                "top": ViewportProbe.topVisibleRow() ?? "-",
            ], force: true)
            proxy.scrollTo(Self.topAnchor, anchor: .top)
            try? await Task.sleep(for: .milliseconds(500))
            ViewportProbe.note("older.drive", [
                "round": String(round), "phase": "at-top",
                "loading": model.isLoadingOlder ? "1" : "0",
                "near": sentinelNearTop ? "1" : "0",
                "top": ViewportProbe.topVisibleRow() ?? "-",
            ], force: true)
            try? await Task.sleep(for: .seconds(4))
        }
        ViewportProbe.note("older.drive", [
            "phase": "done",
            "items": String(model.timeline.items.count),
            "hasOlder": model.hasOlder ? "1" : "0",
            "top": ViewportProbe.topVisibleRow() ?? "-",
        ], force: true)
    }

    /// 打开会话时把视口钉到底部：立即一次 + 120ms + 300ms 各一次，**都不带动画**。
    ///
    /// 为什么要一小串而不是一次：`LazyVStack` 的行是边生成边修正行高的，内容总高在首批
    /// 布局之后还会变大——系统的底部锚定因此停在"当时的底部"（用户看到的中段）。
    /// 命中 `ChatModel.cache` 的二次进入尤其明显：整份 timeline 一帧内恢复，
    /// **条数不再变化**，所以"内容变化后重钉"那条路根本不会触发，只能靠这里。
    ///
    /// 三次的成本可以忽略（每次只是一次 scrollTo，不做布局、不做动画），换来的是一帧内
    /// 就落到最终位置；读者一旦自己拖动过就立刻停手。
    private func pinOnOpen(_ proxy: ScrollViewProxy, sessionId opened: String) {
        // 不是我的会话就一次都不滚（换会话时这份视图可能还活着，见 `ownsTranscript`）。
        guard ownsTranscript else { return }
        guard openedSessionId != opened else { return }
        openedSessionId = opened
        openPinTask?.cancel()
        openPinTask = Task { @MainActor in
            isPinningOnOpen = true
            defer { isPinningOnOpen = false }
            for delay in [0, 120, 300] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                if Task.isCancelled { return }
                guard openedSessionId == opened, !userScrolled, ownsTranscript else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            // 打开阶段结束，跟随恢复常规（可动画）行为。
            isFollowing = true
        }
    }

    /// 内容变化之后确认一次"还在尾部"。
    ///
    /// 单次、延迟、可取消：每次内容变化都把上一次排的撤掉，所以流式输出时不会堆积；
    /// 读者自己翻上去（isFollowing == false）就完全不动。
    private func repinAfterContentChange(_ proxy: ScrollViewProxy) {
        guard isFollowing, ownsTranscript else { return }
        // 先立刻钉一次：这一批内容如果已经布局好，它就直接生效，用户看不到任何中间态。
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        contentRepinTask?.cancel()
        contentRepinTask = Task { @MainActor in
            // 再延迟一次：`LazyVStack` 的行高会在折入过程中被修正，修正会让内容总高变化，
            // 系统的底部锚定因此可能停在半路——等这批布局落定后再钉一次才是最终位置。
            // 150ms 是"够布局完成"与"看不出延迟"之间的取值（实测 150ms 能落到底，
            // 不排这一次则停在半路）。
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            guard ownsTranscript else { return }
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    /// 视口尺寸变化（键盘出现/消失）后把会话钉回底部。
    ///
    /// 只在不处于"用户正在回看历史"时执行：`isFollowing == false` 意味着读者主动
    /// 翻到了上面，这时把他们拽回底部比一片空白更让人恼火——而空白只发生在视口底部
    /// 指向未渲染区域时，回看历史时视口停在已渲染的旧行上，不受影响。
    private func repinAfterViewportChange(_ proxy: ScrollViewProxy, keyboardVisible: Bool) {
        guard isFollowing, ownsTranscript else { return }
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        // 第二次：第一次滚动后 LazyVStack 才会按新视口重建可见行，行高变化又会
        // 移动内容，所以再钉一次。这与 `scrollToBottom(force:)` 的双击是同一个理由。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard isFollowing, ownsTranscript else { return }
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    // 打开会话时**不做任何"把某条消息锚到顶部"的动作**。
    //
    // 那套做法（把最后一条用户消息放到视口顶部）现在是"打开停在中间"的直接来源：
    // 锚定发生在首屏内容还没折完的时候，落点随即被后续内容推走；而且它在二次打开
    // （内容已缓存、折入更快）时和 `defaultScrollAnchor(.bottom)` 打架，观感是"卡在
    // 中间不加载"。打开就交给系统锚在底部，配合 `onAppear` 的那次 scrollToBottom。

    /// Moves the viewport to the tail. The only place that scrolls.
    ///
    /// Throttled, because streaming appends text many times a second and each
    /// append asks to follow. Scrolling — and especially animating a scroll —
    /// on every token saturates the main thread, and a blocked main thread
    /// renders nothing, which is what a blank transcript looks like.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true, force: Bool = false) {
        // 唯一的滚动出口，所以"不是我的会话就别滚"也只需要在这里把一道关。
        guard ownsTranscript else { return }
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
                if isFollowing, ownsTranscript { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
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

    /// 一次"上滑到底"最多连补几页（见 `pumpOlder`）。
    private static let maxOlderBurst = 3
    /// 视口离内容顶部还剩这么多点就补页（见 `noteTopDistance`）。
    ///
    /// 取"哨兵行的高度"这个量级（1pt 行 + 12pt 行距）是有原因的：补页时把**第一条消息**
    /// 锚回视口顶部，而触发那一刻视口顶其实在哨兵行里，所以读者看到的内容会往上挪
    /// `sentinelApproach` 以内的一点点。阈值放大到一屏，这个挪动就成了"倒退几行"的跳。
    /// 实测 13pt（不到一行字）：锚定误差 ≤ 哨兵行高 + 阈值。
    private static let sentinelApproach: CGFloat = 16
    /// 判"位置没跳"的容差：内容长了多少、偏移就该跟着走多少，差在这一点之内算原地不动。
    private static let keepTolerance: CGFloat = 20

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
                isSearching = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityIdentifier("chat.search")
            .accessibilityLabel("在本会话里搜索")

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

/// 视口顶部到内容顶部的距离（点）；停在最上面时是 0。
///
/// iOS 18 起直接读滚动几何（`contentOffset + contentInsets.top`）。更低的系统没有这个
/// API，`ChatView` 就只剩哨兵行的 `onAppear` 触发——补页仍然会自动发生，只是要等行被
/// 建出来那一刻，而不是提前 120pt。
private struct TranscriptTopDistance: ViewModifier {
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

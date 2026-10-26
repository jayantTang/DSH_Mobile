#if os(iOS)
@_exported import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHDesign
import DSHFoundation
import DSHKit
import SwiftUI

/// One session transcript, with the composer pinned to the bottom.
public struct ChatView: View {
    @Environment(AttachmentImages.self) private var attachmentImages
    @Environment(ConnectionEnv.self) var store
    @Environment(HostEventHub.self) private var hub
    @Bindable var model: ChatModel
    /// Opens the workspace browser. Nil until that surface is available, in
    /// which case its affordance is hidden rather than shown disabled.
    var onOpenFiles: ((SessionSummary) -> Void)?
    /// Opens the plugin WebView fallback for one origin.
    var onOpenWeb: ((URL) -> Void)?
    /// 018：从面板或工具卡打开一个子会话（由装配层压入导航栈）。
    var onOpenSession: ((String) -> Void)?
    /// 这份转写属于哪个会话（`RootView.sessionDestination` 一屏一份，用 `.id()` 区分）。
    var sessionId: String

    /// 018：活动名单的应用级适配层（一份名单同时供列表与面板读）。
    @MainActor var activity: ActivityModel { .shared }
    /// 任务与子智能体面板（半屏 sheet）。
    @State var isShowingActivity = false

    /// 无人值守截图用：`-DSHOpenScreen activity` / `activity-output` 直接打开面板
    ///（后者再展开第一个在跑任务的输出）。仅 DEBUG；与 `RootView` 的 `-DSHOpenScreen`
    /// 同一族，未知取值在那边不匹配任何页面，因此互不干扰。
    @State private var automationActivity: String?


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
    private var ownsTranscript: Bool { ChatViewOwnership.isOwner(sessionId: model.session?.sessionId, viewSessionId: sessionId) }

    /// 这一屏**实际交给渲染器**的行。
    ///
    /// 唯一来源是 `ChatModel.rowsFor(screen:)`：归属判断在模型里做，渲染与量具读同一处，
    /// 所以"屏幕上画了什么"与"判定量到什么"永远是同一件事。行不属于这一屏时它返回空——
    /// 换会话的过渡帧不会把上一个会话的内容画出来。
    private var rowsHandedToRenderer: [TimelineItem] {
        splitLongAssistantRows(model.rowsFor(screen: sessionId))
    }

    /// 超长 assistant 回答拆成多个显示行：单条 6,000pt 的行会超出宿主行级
    /// 虚拟化能覆盖的范围（视口带无行覆盖 → 白屏/贴底失准）。拆分只发生在显示层，
    /// 折叠、搜索与选择仍以原消息为准（`parentID` / `fullText`）。
    private func splitLongAssistantRows(_ rows: [TimelineItem]) -> [TimelineItem] {
        var out: [TimelineItem] = []
        out.reserveCapacity(rows.count)
        for item in rows {
            guard case .assistantText(let text) = item.kind,
                  !item.isStreaming, text.count > 1_200 else {
                out.append(item)
                continue
            }
            let parts = AssistantTextSplitter.split(text)
            guard parts.count > 1 else {
                out.append(item)
                continue
            }
            for (index, part) in parts.enumerated() {
                let id = index == 0 ? item.id : "\(item.id)#part\(index)"
                out.append(item.asAssistantFragment(id: id, text: part,
                                                    parentID: item.id, fullText: text))
            }
        }
        return out
    }

    #if DEBUG
    /// 量具的输入：这一屏是谁、交出去的行属于谁、交出去几条。
    ///
    /// 三个一起变才算一次（`Equatable`）——只比条数会漏掉"条数相同但换了会话"。
    private struct StaleRenderKey: Equatable {
        let screen: String
        let owner: String?
        let rows: Int
    }

    private var staleRenderKey: StaleRenderKey {
        // owner 取模型当前发布的那个会话，与 `rowsFor(screen:)` 判的是同一个值。
        StaleRenderKey(screen: sessionId, owner: model.visible?.summary.sessionId,
                       rows: rowsHandedToRenderer.count)
    }
    #endif

    @State var isRenaming = false
    @State var renameText = ""
    @State var isShowingModelPicker = false
    @State var isShowingInfo = false
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
    /// 正在被长按的那一行。非 nil 就显示动作单（013：自己画，见 `MessageActionSheet`）。
    @State private var askingItem: TimelineItem?
    /// 顶部哨兵是否已经（或即将）进入视口。见 `evaluateTopDistance`。
    @State private var sentinelNearTop = false
    /// 最近一次量到的"视口顶部离内容顶部还有多远"。
    ///
    /// 必须存下来：`onScrollGeometryChange` 只在**值变化**时回调，而"会话一打开就停在
    /// 内容顶部"这种情况（初次布局时内容还是空的）从头到尾就没变过——2026-09-24 实测
    /// 8 轮里有 2 轮整段回调都没来，补页一次都没触发。所以距离要缓存，改由
    /// "会话/内容变化"这些时机重新判一次（`evaluateTopDistance`）。
    @State private var topDistance: CGFloat?
    /// 上面那个距离是什么时候量到的。补页必须用"刚量到的"位置，见 `evaluateTopDistance`。
    @State private var topDistanceAt = Date.distantPast
    /// 正在跑的那串"连续补页"。见 `pumpOlder`。
    @State private var olderPump: Task<Void, Never>?
    /// 已经处理过的补页代数，用来把"头部插入"从"尾部追加"里分出来。
    @State private var handledPrepend = 0
    /// 延后的窗口裁剪（见 `onChange(of: items.count)` 的注释）。
    @State private var trimWindowTask: Task<Void, Never>?
    /// 每完成一次锚定就 +1。补页那一侧靠它等"**这一次**插页的锚定跑完"，
    /// 而不是等一个可能属于上一页的 `prependAnchorTask`（2026-10-08 实测：等错了对象，
    /// 于是 `kept` 量在锚定之前，把已经锚住的页记成 0）。
    @State private var anchorCompletions = 0
    /// 搜索面板是否打开。
    @State var isSearching = false
    /// 033：刚被点开/收起的过程节点；内容变化后把它带回视口。
    @State private var processToggleAnchor: String?
    /// 搜索面板选中的那条（行 id）：转写页滚动到它并短暂高亮。
    @State private var searchJumpHit: TranscriptSearchHit?
    /// 正在为跳转换窗口（这期间不让"钉底/补页"插手，否则会把刚换好的窗口又拽回去）。
    @State private var rebalancing = false
    /// 新宿主（uikit）的跳转目标：换窗口之后由宿主的 `scrollToItem` 落点，
    /// 不再走 SwiftUI 的 `ScrollViewProxy`（spec 008 的 US2）。
    @State private var listJumpId: String?
    /// uikit 跳转的重试令牌：同一行 id 也要能再次触发（落地被布局抖动冲掉时）。
    @State private var listJumpNonce = 0
    /// 新宿主的引用（回收/水合要从外面把行交回去）。
    @State private var listHostRef: TranscriptListHost?
    /// 宿主正在执行"我们发起的滚动"（回到底部/打开钉底）时为真：这期间不要把它当成"读者滚走了"。
    @State private var listHostRefIsScrollingProgrammatically = false
    /// 宿主几何给出的"此刻是否贴底"：按钮显隐只认这个事实，不认可能滞后的 `isFollowing`。
    @State private var hostAtBottom = true
    /// 回到底部的信号：DOM 里没有可依赖的滚动代理，走 representable 的更新周期
    /// 交给宿主（比在按钮闭包里拿一个可能为 nil 的宿主引用可靠）。
    @State private var bottomSignal = 0
    /// 刚刚跳过去、正在高亮的那一行。
    @State private var highlightedItemId: String?
    /// 高亮的清除任务（连续跳转时上一次要取消）。
    @State private var highlightTask: Task<Void, Never>?
    /// 补页前视口里最上面那条消息的 id：补完要把它锚回视口顶部（见 `anchorAfterPrepend`）。
    @State private var prependAnchor: String?
    /// 记下这次补页**发起时**读者是不是贴在顶部。
    ///
    /// 不能用"插入完成后 sentinelNearTop"来判断：插入本身就会把哨兵挤出视口，
    /// 于是锚定的四次重试会被 `onDisappear` 全部挡掉——2026-10-08 实测 `older.pump kept=0`
    /// 就是这么来的（视口留在了新内容上）。发起时在顶部 ⇒ 补完必须锚回来。
    @State private var prependAnchorAtTop = false
    /// 补页**之前**的滚动几何（偏移 / 内容高），用来判断锚定有没有收敛。
    @State private var prependBaseline: (offset: CGFloat, content: CGFloat)?
    /// 那一次锚定的重试序列。
    @State private var prependAnchorTask: Task<Void, Never>?
    /// Owned here rather than in the composer so the transcript can re-pin
    /// itself when the keyboard changes the viewport.
    @FocusState private var isFocused: Bool

    /// 显式 public 初始化器（025 阶段4b）：装配层（`RootView`）在模块外构造这一屏，
    /// 而成员逐一初始化器对 public struct 默认是 internal。
    public init(
        model: ChatModel,
        onOpenFiles: ((SessionSummary) -> Void)? = nil,
        onOpenWeb: ((URL) -> Void)? = nil,
        onOpenSession: ((String) -> Void)? = nil,
        sessionId: String
    ) {
        self.model = model
        self.onOpenFiles = onOpenFiles
        self.onOpenWeb = onOpenWeb
        self.onOpenSession = onOpenSession
        self.sessionId = sessionId
    }

    public var body: some View {
        VStack(spacing: 0) {
            transcript
            if let prompts = model.pendingPrompts.first {
                PendingPromptBanner(prompt: prompts, model: model)
            }
            // 排队输入：输入区上方独立条带，不进转写、不影响输入框高度。
            QueuedInputBar(model: model)
            Hairline()
            Composer(model: model, isFocused: $isFocused)
                .probed("composer")
        }
        .background(DSHTheme.background)
        // 018：聊天页把当前会话的轮次喂成 `timeline.isTurnOpen`（列表喂的是
        // `session/list.running`，两者口径不同，这里覆盖）。
        .task { syncActivityBinding() }
        .onChange(of: model.timeline.isTurnOpen) { _, _ in syncActivityBinding() }
        .onChange(of: model.session?.sessionId) { _, _ in syncActivityBinding() }
        .onDisappear {
            guard ownsTranscript else { return }
            activity.bindChat(sessionId: nil, isTurnOpen: false)
        }
        .task {
            ChatProbe.shared.start?()
            ChatProbe.shared.resume?()
            // 端口在调用点构造（spec 024 / FR-005）：调试工具只认这三个动作，
            // 不再直接持有 `ChatModel`，基础设施与工具目录都不认识业务类型。
            // `#if DEBUG`：类型本身只在 DEBUG 的 DSHFoundation 里（见 `ChatViewSeams`）。
            #if DEBUG
            await ChatViewSeams.shared.runTyping?(
                TypingTarget(isRunning: { model.isRunning },
                             draft: { model.draft },
                             setDraft: { model.draft = $0 }),
                $isFocused)
            #endif
        }
        .overlay(alignment: .top) {
            // **Stacked, not two parallel overlays.** `CompletionBanner` already
            // occupies the top layer; a second `.overlay(alignment: .top)` would
            // draw the two on top of each other (the "two sibling views drawn
            // overlapping" mistake from f3b0e91). A `VStack` inside the one
            // overlay makes them share the space in order.
            VStack(spacing: DSHTheme.Spacing.hairline) {
                if let completionBanner {
                    CompletionBanner(text: completionBanner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                // **The failure has to be visible here.** `lastError` used to have
                // exactly one reader in the whole app (`Composer`'s prompt sheet),
                // so a file that failed to send looked like "the spinner stopped".
                // With the fallback removed there is nothing else to see, so this
                // banner is what makes "the send failed" a thing the user knows.
                if let failure = model.lastError {
                    ChatErrorBanner(text: failure) { model.clearLastError() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, DSHTheme.Spacing.hairline)
        }
        .onChange(of: model.completionSignal) {
            guard let finished = model.completion else { return }
            // 与转写里的轮次行同一句：不再另立一套「本轮已完成」的说法。
            let text = ProcessFoldText.turnLabel(endReason: finished.reason,
                                                 duration: finished.duration)
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
            TranscriptSearchSheet(model: model) { hit in searchJumpHit = hit }
        }
        .task {
            #if DEBUG
            if let requested = Self.automationActivityScreen() {
                automationActivity = requested
                isShowingActivity = true
            }
            #endif
        }
        .sheet(isPresented: $isShowingActivity) {
            ActivitySheet(
                sessionId: sessionId,
                onOpenSession: { childId in
                    isShowingActivity = false
                    onOpenSession?(childId)
                },
                // 直接读启动参数，不读 `automationActivity` 状态：同一轮 `.task` 里
                // 先赋值再呈现时，sheet 内容可能拿到旧值（nil），自动展开就不生效。
                automation: Self.automationScreenArgument
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $readingMessage) { message in
            MessageTextSheet(message: message)
        }
        // 013：长按一行 → 动作单。手势由宿主报上来（`onRowAsk`），UI 在这里画。
        //
        // 不用系统 `contextMenu`/`confirmationDialog` 的理由写在 `MessageActionSheet` 顶部：
        // 前者在这个宿主里预览与背板几何是错的（owner 截图），后者在本机根本看不到上屏。
        .overlay {
            if let item = askingItem, let payload = item.selectableMessage {
                MessageActionSheet(
                    title: payload.title,
                    onSelect: {
                        readingMessage = item.messageSelection
                        withAnimation(.snappy(duration: 0.18)) { askingItem = nil }
                    },
                    onCopy: {
                        item.copyTextToPasteboard()
                        withAnimation(.snappy(duration: 0.18)) { askingItem = nil }
                    },
                    onCancel: {
                        withAnimation(.snappy(duration: 0.18)) { askingItem = nil }
                    }
                )
            }
        }
    }

    /// The directory name, falling back to the title when there is no workspace.
    private var headerTitle: String {
        // 018 §5：子会话只换标题，不加任何退出/关闭控件（退出沿用系统导航手势）。
        if let session = model.session, session.isSubagent {
            return String(localized: "子智能体 · \(session.subagentLabel ?? session.sessionId)")
        }
        if let cwd = model.session?.cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return model.titleOverride ?? model.session?.displayTitle ?? "会话"
    }

    /// 018 §2：工具栏那个点是否出现（有活才出现入口；能力位缺失整块不出现）。
    var isActivityVisible: Bool {
        activity.isAvailable && (activity.snapshot(sessionId: sessionId)?.isBusy ?? false)
    }

    /// 入口是否常驻：只要连接器支持活动名单就一直在。
    ///
    /// owner 2026-10-17：入口原来只在"有活在跑"时出现，任务一结束就没有入口，
    /// 已结束的任务与子智能体因此再也点不开。现在改成常驻图标，有没有活都进得去。
    /// 能力位缺失（旧的连接器 / direct 通道）仍然整块不出现。
    var isActivityEntryVisible: Bool {
        activity.isAvailable
    }

    /// 018：把这一屏的当前会话与 `timeline.isTurnOpen` 交给活动适配层。
    ///
    /// 转场期间旧屏幕还活着，但它已经不代表屏幕上的会话（`ownsTranscript`），
    /// 这时不许用旧轮次去覆盖新会话的绑定。
    private func syncActivityBinding() {
        guard ownsTranscript else { return }
        activity.bindChat(sessionId: sessionId, isTurnOpen: model.timeline.isTurnOpen)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            transcriptSignals(proxy)
        }
    }

    /// 转写外壳：容器与三处浮层。
    ///
    /// 为什么拆成两段：跨模块之后这一整条修饰符链的推导超出编译器的耐心
    /// （`error: the compiler is unable to type-check this expression in reasonable
    /// time`）——与 `stackContainer` 当初从这一链里抽出来是同一个理由。
    private func transcriptChrome(_ proxy: ScrollViewProxy) -> some View {
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
        .defaultScrollAnchor(isFollowing ? .bottom : nil)
        // 探针：滚动几何（偏移 / 内容高 / 容器高）。"落在内容之外"这种状态
        // 只能从这里看出来，光看"有没有已渲染的行"看不出来。
        .modifier(ScrollGeometryProbe())
        .accessibilityIdentifier("chat.transcript")
        .onChange(of: processToggleAnchor) { _, anchor in
            guard let anchor else { return }
            processToggleAnchor = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                if ChatProbe.shared.listHost == "uikit" {
                    listHostRef?.scrollTo(id: anchor)
                } else {
                    proxy.scrollTo(anchor, anchor: .center)
                }
            }
        }
        // 探针：转写区自己的矩形。它和已渲染行的矩形之差就是"没被盖住的带"。
        .background(
            GeometryReader { proxy in
                let rect = proxy.frame(in: .global)
                Color.clear
                    .onAppear { ChatProbe.shared.setViewport?(rect) }
                    .onChange(of: rect) { _, next in ChatProbe.shared.setViewport?(next) }
            }
        )
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.sendSignal) {
            isFollowing = true
            scrollToBottom(proxy, force: true)
        }
        .onChange(of: model.scrollSignal) {
            ChatProbe.shared.probeNote?("scrollSignal", ["draft": String(model.draft.count)], false)
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
                    // 读者往新的一头拖：在飞的那一页没必要补了（FR-016 的"反向滚动取消"）。
                    cancelOlderPump(reason: "reverse")
                }
            }
        )
        .overlay(alignment: .top) { olderLoadingPill }
        .overlay(alignment: .top) {
            VStack(spacing: DSHTheme.Spacing.hairline) {
                summaryRetryBar
                olderRetryBar
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // 009「↓ 新消息」胶囊（T018）：reading 态且有新消息到达时出现，
            // 点击一律滚到最新（差值补齐与降级在模型侧，见 ChatModel+Follow）。
            // 与 008「回到底部」按钮共用同一视觉家族（胶囊、layer3、描边、投影）。
            if model.pipelineActive, model.followState == .reading, model.unreadWhileReading > 0 {
                Button {
                    Task { @MainActor in
                        await model.jumpToLatest()
                        isFollowing = true
                        userScrolled = false
                        listHostRef?.scrollToBottom()
                    }
                } label: {
                    HStack(spacing: DSHTheme.Spacing.hairline) {
                        if model.isCatchingUpTail {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(String(format: String(localized: "↓ %lld 条新消息"),
                                    model.unreadWhileReading))
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
                .accessibilityIdentifier("chat.newMessages")
                .padding(.trailing, DSHTheme.Spacing.loose)
                .padding(.bottom, DSHTheme.Spacing.tight)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if !hostAtBottom, userScrolled, !model.timeline.items.isEmpty {
                Button {
                    // 先滚：读者点下去立刻有反馈；尾部补齐在后台做，回来再钉一次。
                    // `userScrolled` 先留着：只有宿主真的报到底才清，没滚到位就还能再点。
                    isFollowing = true
                    model.noteWantsBottom()
                    requestBottomScroll(proxy)
                    Task { @MainActor in
                        // 只有还在跑的会话才需要补齐尾部；已完成的会话本地底部就是真底，
                        // 再做一次 summary 刷新/补齐只会让点击变慢，还可能把视图拉回中间。
                        guard model.pipelineActive, model.isRunning else { return }
                        await model.jumpToLatest()
                        isFollowing = true
                        requestBottomScroll(proxy)
                    }
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
    }

    /// 转写区的三个状态浮层（加载 / 失败 / 空会话）。
    ///
    /// 与 `transcriptScroll` 分家：跨模块后一条长链的推导会超时（见 `transcriptChrome`）。
    private func transcriptSurface(_ proxy: ScrollViewProxy) -> some View {
        transcriptChrome(proxy)
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
    }

    /// 转写页的探针驱动、切换与生命周期钩子。
    ///
    /// 修饰符链拆成三段（`transcriptChrome` → `transcriptScroll` → 这里），两个长
    /// `.onChange` 闭包体抽成具名方法：跨模块（`DSHChatDomain` 在另一个 target、
    /// 探针端口又是可选闭包）之后，一条 20+ 修饰符的长链会让编译器放弃推导
    /// （`unable to type-check this expression in reasonable time`）。
    private func transcriptSignals(_ proxy: ScrollViewProxy) -> some View {
        transcriptScroll(proxy)
        #if DEBUG
        // 量具：这一屏交给了渲染器哪些行、它们属于谁（`StaleRenderWatch`）。
        // 用 `onChange(initial: true)` 而不是在 `body` 里直接调用：判定的输入是
        // "**交出去**的那批行"，与渲染读同一个表达式，两者不会各说各话。
        .onChange(of: staleRenderKey, initial: true) { _, key in
            StaleRenderWatch.handed(screen: key.screen, owner: key.owner, rows: key.rows)
        }
        #endif
        .onChange(of: model.timeline.items.count) { _, count in
            itemsCountDidChange(count, proxy: proxy)
        }
        .onChange(of: model.timeline.streaming?.text.count ?? 0) { _, streamed in
            ChatProbe.shared.setContent?(model.timeline.items.count, streamed)
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .ready { ChatProbe.shared.markReady?() }
        }
        .onKeyboardVisibilityChange { visible in
            ChatProbe.shared.probeNote?("keyboard", ["visible": visible ? "1" : "0",
                                            "following": isFollowing ? "1" : "0"], false)
            repinAfterViewportChange(proxy, keyboardVisible: visible)
        }
        .onChange(of: model.draft.count) { _, count in
            ChatProbe.shared.probeNote?("draft", ["chars": String(count),
                                         "following": isFollowing ? "1" : "0"], false)
        }
        .onChange(of: isFollowing) { _, following in
            ChatProbe.shared.probeNote?("following", ["on": following ? "1" : "0"], false)
            // 手指往上滑正是"到没到顶部"这条判定的输入之一。而且拖动是**唯一**不依赖
            // 滚动几何变化的信号：视口本来就停在顶部时，再拖也不产生几何变化，
            // 只靠回调会漏掉补页（2026-09-24 实测 3 轮里 1 轮）。
            evaluateTopDistance(proxy)
        }
    }

    /// 转写页的生命周期与切换钩子（三段链的中间一段）。
    private func transcriptScroll(_ proxy: ScrollViewProxy) -> some View {
        transcriptSurface(proxy)
        .onAppear {
            isFollowing = true
            ChatProbe.shared.resume?()
            requestBottomScroll(proxy, open: true)
        }
        .onChange(of: searchJumpHit) { _, hit in
            searchJumped(hit, proxy: proxy)
        }
        // 探针驱动（`-DSHProbeOlderScroll`）：仿真器里没法对转写页做手势滑动，
        // 所以"往上滑"这一段由 App 自己代劳，其余全是产品代码。
        // 新宿主自带驱动（coordinator 里那份），**旧的 SwiftUI 驱动必须让位**：
        // 它会去置 `isFollowing=false, userScrolled=true`，把 uikit 路径的 `pinToBottom` 打成假，
        // 于是预算检查永远"算得出来但不该丢"（2026-10-08 实测：`list.budget count=14 pin=0`）。
        .task { if ChatProbe.shared.listHost != "uikit" { await runOlderScrollDrive(proxy) } }
        // 离开转写页就暂停探针采样：退回列表后"转写区"没有任何内容可量，
        // 继续采只会把列表记成"会话区白了"。
        .onDisappear { ChatProbe.shared.pause?() }
        .onChange(of: model.session?.sessionId, initial: true) { _, sessionId in
            sessionDidChange(sessionId, proxy: proxy)
        }
    }

    /// 跳到搜索命中那一条。
    private func searchJumped(_ hit: TranscriptSearchHit?, proxy: ScrollViewProxy) {
        guard let hit else { return }
        Task { @MainActor in await jumpToHit(hit, proxy: proxy) }
    }


    /// 会话切换：先把上一屏的临时状态收干净，再钉底、再判一次补页。
    ///
    /// 从 `.onChange` 闭包里抽出来的，逐字搬移（见 `transcriptScroll` 里的说明）。
    private func sessionDidChange(_ sessionId: String?, proxy: ScrollViewProxy) {
        attachmentImages.sessionId = sessionId
        userScrolled = false
        openedSessionId = nil
        olderPump?.cancel()
        olderPump = nil
        highlightTask?.cancel()
        highlightedItemId = nil
        searchJumpHit = nil
        prependAnchorTask?.cancel()
        prependAnchorTask = nil
        prependAnchor = nil
        sentinelNearTop = false
        cancelOlderPump(reason: "switch")
        // 注意：**不要**把 `topDistance` 清掉。它是滚动几何的事实，不是会话状态；
        // 而"首次布局时内容还是空的、视口就停在顶部"这种情况，几何值此后**再也不变**，
        // 清了就永远补不回来（2026-09-24 实测：清了之后补页和钉底一起失灵）。
        hostAtBottom = true
        if let sessionId { pinOnOpen(proxy, sessionId: sessionId) }
        evaluateTopDistance(proxy)
    }

    /// 时间线条数变了：裁窗口、报探针、重判补页。
    private func itemsCountDidChange(_ count: Int, proxy: ScrollViewProxy) {
        // 窗口预算：只在读者跟着尾部时裁，而且**延后一拍**——打开会话时 `pinOnOpen`
        // 会在 0/120/300ms 连发几次 `scrollTo`，此刻缩短 items 会让在飞的目标 index path
        // 失效，UIKit 直接 SIGABRT（2026-10-08 run 20261008-202231 实测）。
        scheduleWindowTrim()
        let streamed = model.timeline.streaming?.text.count ?? 0
        ChatProbe.shared.setContent?(count, streamed)
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

    /// 转写容器本身。抽出来是因为把 `List`/`ScrollView` 两套容器写在同一个
    /// 修饰符链里，编译器会报"表达式太复杂"。
    @ViewBuilder
    private func stackContainer(_ proxy: ScrollViewProxy) -> some View {
        if ChatProbe.shared.listSpike {
            // spike 屏（spec 008 Phase 0）：不读会话，纯造数据量位移与并发。
            TranscriptListSpikeView()
        } else if ChatProbe.shared.listHost == "uikit" {
            // spec 008 US1：新列表宿主渲染真会话。行视图直接复用本视图的 `row(_:)`，
            // 所以两条路的视觉是同一套代码（验收口径：等价，不追逐像素）。
            TranscriptListRepresentable(
                items: rowsHandedToRenderer,
                makeRow: { AnyView(row($0)) },
                pinToBottom: isFollowing,
                bottomSignal: bottomSignal,
                onDiagnostic: { name, fields in ChatProbe.shared.probeNote?(name, fields, true) },
                canLoadOlder: { model.hasOlder },
                isLoadingOlder: { model.isLoadingOlder },
                onNearTop: { Task { await model.loadOlder() } },
                onScroll: { distance in
                    model.noteReaderTopRow(listHostRef?.topVisibleRowID)
                    topDistance = distance
                    // 几何的新鲜度戳必须与值同写：只写值时哨兵路径的
                    // `older.stale` 会拿 distantPast 算出垃圾 age，把补页恒挡掉
                    // （uikit 宿主下 SwiftUI 哨兵仍参与补页判定，用例 57 实测）。
                    topDistanceAt = Date()
                    let near = distance < Self.sentinelApproach
                    if near != sentinelNearTop {
                        sentinelNearTop = near
                        ChatProbe.shared.probeNote?("older.sentinel", [
                            "distance": String(format: "%.0f", distance),
                            "near": near ? "1" : "0",
                            "following": isFollowing ? "1" : "0",
                            "items": String(model.timeline.items.count),
                        ], false)
                    }
                },
                onBudgetCheck: { visibleRows in
                    // 跟随尾部时才丢：读者不在尾巴上时丢东西会把他正在看的行抽走。
                    guard isFollowing, !userScrolled else { return [] }
                    // 保留带按**屏**算：至少留住两屏，否则丢弃之后内容比一屏还短，
                    // 看起来像会话被截断（run 20261008-230106 的 T037）。
                    let keep = max(24, visibleRows * 2)
                    let plan = model.trimPlanForBudget(keepLast: keep)
                    guard !plan.isEmpty else { return [] }
                    _ = model.applyTrim(plan)
                    return plan.displayDropIDs
                },
                driveRounds: ChatProbe.shared.olderScrollRounds ?? 0,
                onDriveBegin: {
                    isFollowing = false
                    userScrolled = true
                },
                onReclaim: { ids in
                    // 回收只是把行的重内容换掉；行与高度都留着（FR-003/FR-005）。
                    listHostRef?.apply(.reclaim(ids))
                },
                onNeedRehydrate: { seqs in
                    // **内存命中同帧还回**（owner 定调：回收/水合不许有任何过渡性视觉
                    // 变化，0.2s 闪白也算缺陷）：宿主从主线程的滚动防抖任务里调进来，
                    // 正本又还在 `timeline.items` 里，先同步水合，不让视口看到
                    // 「透明占位 + 异步水合」之间那一帧白（用例 55，run 20261011-111236）。
                    let cached = MainActor.assumeIsolated { model.cachedItems(forSeqs: seqs) }
                    if !cached.isEmpty {
                        listHostRef?.rehydrate(items: cached)
                        listHostRef?.scheduleReclaimCheck()
                    }
                    // 内存未命中（预算裁剪已把它从时间线里丢掉）才走异步磁盘兜底：
                    // 甩得再快也最多看到磁盘水合的延迟，而内存命中是绝大多数。
                    let hitSeqs = Set(cached.map(\.seq))
                    let missing = seqs.filter { !hitSeqs.contains($0) }
                    guard !missing.isEmpty else { return }
                    Task { @MainActor in
                        let items = await model.items(forSeqs: missing)
                        guard !items.isEmpty else { return }
                        listHostRef?.rehydrate(items: items)
                        // 水合完立刻再查一轮：附近还有回收行（上一轮没取全、或新滚进来
                        // 一段）就连着补——静止的视口不会再有滚动事件触发扫描，等它会
                        // 把可见带白在那儿（用例 57 的 ~1s 残白）。
                        listHostRef?.scheduleReclaimCheck()
                    }
                },
                onAtBottomExact: { hostAtBottom = $0 },
                onBottomChanged: { atBottom in  // 几何驱动

                    if model.processToggleFollowHold { return }
                    // 009 管道 + uikit 宿主：跟随判定由跟底两态接管（48pt + 向上拖动
                    // 抑制，见 onFollowGeometry），这条旧回调只在其它路径生效。
                    guard !(model.pipelineActive && ChatProbe.shared.listHost == "uikit") else { return }
                    // 唯一可靠的"跟随"依据：滚动几何。原来靠拖动位移（>24pt）判定，
                    // 于是"轻轻往上滑/刷新"这类情况仍被判成跟随，内容一变就被拽到底部
                    // （2026-10-08 真机反馈："偶尔自动跳到底部"）。
                    if atBottom {
                        isFollowing = true
                        userScrolled = false
                        listHostRef?.cancelBottomIntent()
                    } else {
                        isFollowing = false
                        userScrolled = true
                        // 跟尾意图由宿主拥有：只有读者真正拖动（或程序化跳转）才清，
                        // 几何回调不能清——程序化钉底过程中的中间位置会误报"离开"。
                    }
                },
                onFollowGeometry: { distance, draggingUp in
                    if model.processToggleFollowHold {
                        if draggingUp { model.releaseProcessToggleFollow() }
                        return
                    }
                    // 跟底两态（T017）：状态判定收敛在模型，这里只把结论同步给
                    // 本视图的两个滚动开关（isFollowing 是所有自动滚动的总闸）。
                    model.noteReaderTopRow(listHostRef?.topVisibleRowID)
                    model.noteFollowGeometry(distance: distance, draggingUp: draggingUp)
                    guard model.pipelineActive else { return }
                    if model.followState == .atBottom {
                        if !isFollowing {
                            isFollowing = true
                            userScrolled = false
                            listHostRef?.cancelBottomIntent()
                        }
                    } else if isFollowing {
                        isFollowing = false
                        userScrolled = true
                        // 同上：不清宿主的跟尾意图，交给拖动回调。
                    }
                },
                jumpToId: listJumpId,
                hostRef: $listHostRef,
                onRowAsk: { id in
                    guard let item = model.timeline.items.first(where: { $0.id == id }) else { return }
                    withAnimation(.snappy(duration: 0.18)) { askingItem = item }
                },
                // 009（T013/T015）：管道快照的每次变化都是多段混合变更，
                // 必须作为一次原子更新提交（统一锚位移修正）。
                atomicApply: true
            )
            .accessibilityIdentifier("chat.transcript.list")
        } else if ChatProbe.shared.lazyStack {
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
        ForEach(rowsHandedToRenderer) { item in row(item) }
        tail
        bottomMarker
    }

    /// 延后一拍再裁窗口（见 `onChange(of: items.count)` 的注释）。
    ///
    /// 抽成独立方法还有一个实际原因：把 Task 直接写在 `onChange` 闭包里会让
    /// SwiftUI 的类型推断超时（2026-10-08 实测 "unable to type-check this expression"）。
    private func scheduleWindowTrim() {
        trimWindowTask?.cancel()
        trimWindowTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, !isPinningOnOpen, olderPump == nil, prependAnchorTask == nil else { return }
            model.trimWindowIfNeeded(readerIsFollowing: isFollowing && !userScrolled)
        }
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
            .modifier(TranscriptRowChrome(inList: !ChatProbe.shared.lazyStack))
            .id(Self.topAnchor)
            // 「读者到没到最上面」这件事**以这一行的生死为准**，滚动几何只是提前量。
            //
            // 为什么不能只靠几何：`onScrollGeometryChange` 只在**值变化**时回调，而"内容长出来
            // 但没滚动"（首屏快照落地、补页插入）不产生回调。2026-09-24 实测：一次运行里
            // 0.3 秒之后它整段不响，内容高从 39 涨到 5978 都没报——补页与"钉回底部"一起失灵。
            // 行是被 `List` 按"离视口多远"建/拆的，这个信号一直有。
            .onAppear {
                sentinelNearTop = true
                ChatProbe.shared.probeNote?("older.sentinel", ["near": "1", "why": "appear",
                                                     "items": String(model.timeline.items.count)], false)
                if isFollowing, !userScrolled {
                    // 读者没往上翻过、却已经在内容顶部：那是"打开会话没钉到底"，先钉回去。
                    ChatProbe.shared.probeNote?("older.repin", ["distance": "-1"], false)
                    repinAfterContentChange(proxy)
                    return
                }
                pumpOlder(proxy)
            }
            .onDisappear { sentinelNearTop = false }
    }

    /// 首屏概要取数失败的页级重试条（能力 `history-fold-summary-v2`）。
    ///
    /// 概要模式按整轮取数：某一轮大到一页读不完时，连接器如实回 `link/too-large`，
    /// 这里把它变成一句能行动的话。失败不静默、不阻断已有内容，也不影响单条卡片。
    @ViewBuilder
    private var summaryRetryBar: some View {
        if model.summaryScreenState.isFailed {
            let tooLarge: Bool = {
                if case .failed(let tooLarge) = model.summaryScreenState { return tooLarge }
                return false
            }()
            Button {
                ChatProbe.shared.probeNote?("summary.retry.tap", [:], true)
                Task { await model.retrySummaryScreen() }
            } label: {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Image(systemName: "arrow.clockwise")
                    Text(tooLarge
                         ? "概要加载失败：有一轮过大，点按重试"
                         : "概要加载失败，点按重试")
                }
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelPrimary)
                .padding(.horizontal, DSHTheme.Spacing.tight)
                .padding(.vertical, 6)
                .background(DSHTheme.layer3, in: Capsule())
                .overlay(Capsule().stroke(DSHTheme.border2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.summary.retry")
        }
    }

    /// 取页失败时的重试条：浮在转写区顶部，不进内容（行高恒定，见 `olderSentinel`）。
    ///
    /// 为什么必须有：取页失败曾经是**完全静默**的——`hasOlder` 被写成 false，读者只看到
    /// "再也翻不动了"，没有任何可点的东西（spec 007 FR-004/FR-007）。这里给一句
    /// 能行动的话和一个按钮，失败就不再是死路。
    @ViewBuilder
    private var olderRetryBar: some View {
        // 009 管道模式下失败态由顶部缺口行（点击重试）表达，不再叠这条胶囊。
        if !model.pipelineActive, let reason = model.olderFailure {
            Button {
                ChatProbe.shared.probeNote?("older.retry.tap", ["reason": reason], true)
                Task { await model.retryOlder() }
            } label: {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    Image(systemName: "arrow.clockwise")
                    Text("读取更早的记录失败，点按重试")
                }
                .font(DSHTheme.Typography.micro)
                .foregroundStyle(DSHTheme.labelPrimary)
                .padding(.horizontal, DSHTheme.Spacing.tight)
                .padding(.vertical, 6)
                .background(DSHTheme.layer3, in: Capsule())
                .overlay(Capsule().stroke(DSHTheme.border2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.older.retry")
            .padding(.top, DSHTheme.Spacing.hairline)
            .transition(.opacity)
            // 诊断：把重试条真正布局出来的尺寸与位置落盘。用例 53 的截图一直抓到"加载态"，
            // 有了这行就能区分"抓拍时机不巧"与"它在树上但没被画出来/被遮住"。
            .background(
                GeometryReader { geometry in
                    Color.clear.onAppear {
                        ChatProbe.shared.probeNote?("older.retryBar", [
                            "w": String(format: "%.0f", geometry.size.width),
                            "h": String(format: "%.0f", geometry.size.height),
                            "y": String(format: "%.0f", geometry.frame(in: .global).minY),
                        ], true)
                    }
                }
            )
        }
    }

    /// 补页进行中的提示：浮在转写区顶部，不进内容（行高恒定，见 `olderSentinel`）。
    @ViewBuilder
    private var olderLoadingPill: some View {
        // 已经失败过就不再显示"正在加载"：那会让人以为还在忙，而实际上要等的是他自己点一下
        // （或 3 秒后那一次自动补试）。两者互斥，屏幕上也才看得出"现在是失败态"。
        // 预取现在提前一屏半发生，所以这行小字会在读者快到顶之前就出现——
        // 真机反馈过"加载中要有小字，否则以为获取历史有问题"。
        // 009 管道模式下加载态由顶部缺口行（spinner）表达，不再叠这条小字。
        if !model.pipelineActive, model.isLoadingOlder, model.olderFailure == nil {
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

    /// 过程行的行底留白。
    ///
    /// 轮次行与回答之间按桌面留 16pt；分组行之间只留一条缝——每组都是 20pt 高的一行，
    /// 用正文那 12pt 会把一组拆成一条条孤立的行。
    static func rowBottomPadding(for item: TimelineItem) -> CGFloat {
        guard case .processHeader(let header) = item.kind else { return DSHTheme.Spacing.standard }
        return header.scope == .group ? DSHTheme.Spacing.hairline : 16
    }

    /// 一行消息。抽出来是为了让"懒加载/非懒加载"两种排布共用同一份定义。
    private func row(_ item: TimelineItem) -> some View {
        var rowView = TimelineRowView(item: item)
        // 缺口行「加载失败，点击重试」（T016）：重试由管道的状态机接管。
        rowView.onGapRetry = { start, end in
            Task { await model.retryGap(start: start, end: end) }
        }
        // T022 失败用户消息「发送失败，点击重发」：管道的重发状态机接管。
        rowView.onSendRetry = { rowId in
            Task { await model.retrySend(rowId: rowId) }
        }
        // 「已发送，未确认，点击核对」：只核对（服务端查重），重发要读者再点一次。
        rowView.onSendVerify = { rowId in
            Task { await model.verifySend(rowId: rowId) }
        }
        // 运行中的那条分组行写「正在<动作> · <当前命令/工具>」。
        if case .processHeader(let header) = item.kind, header.scope == .group, header.isRunning {
            rowView.processRunning = model.runningDetail
        }
        // 018：subagent 卡绑定运行态与「打开子会话」；其它卡片读不到证据就不加行。
        rowView.activity = activity
        rowView.onOpenSession = onOpenSession
        rowView.parentSessionId = model.session?.sessionId
        rowView.onToggleProcessStep = { id in
            // 展开步骤卡会按需取一条正文：与过程节点一样先退出跟随，
            // 免得同一次更新里的"钉底"把卡片顶走。
            isFollowing = false
            userScrolled = true
            model.holdProcessToggleFollow()
            ChatProbe.shared.probeNote?("process.step.toggle", ["id": id], true)
            model.toggleProcessStep(id)
        }
        rowView.onRetryProcessStep = { id in
            ChatProbe.shared.probeNote?("process.step.retry", ["id": id], true)
            model.retryProcessStepBody(id)
        }
        rowView.onToggleProcess = {
            if case .processHeader(let header) = item.kind {
                // 展开/收起是读者动作：先退出跟随，否则同一次更新里的"钉底"
                // 会抵消宿主的锚点修正，把视口甩到最新一条（spec 033 FR-015）。
                isFollowing = false
                userScrolled = true
                model.holdProcessToggleFollow()
                ChatProbe.shared.probeNote?("process.toggle", [
                    "id": item.id, "expanded": header.isExpanded ? "1" : "0",
                ], true)
                listHostRef?.cancelBottomIntent()
                // Put the node at the top *before* the content grows; otherwise
                // the list's bottom anchor pushes it off screen (spec 033 FR-015).
                listHostRef?.scrollTo(id: item.id)
                // Give the list one update to see pinToBottom == false and drop
                // its bottom intent before the transcript grows.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(40))
                    if header.scope == .group {
                        model.toggleProcessGroup(groupKey: item.id)
                    } else {
                        model.toggleProcess(turnKey: item.id)
                    }
                    processToggleAnchor = item.id
                }
            }
        }
        return rowView
            // 搜索跳过来的那一行：淡底 + 左侧色条，一眼能认出"就是这条"。
            .background(alignment: .leading) {
                if let highlightedItemId,
                   highlightedItemId == item.id || highlightedItemId == item.parentID {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DSHTheme.brand.opacity(0.10))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(DSHTheme.brand)
                                .frame(width: 2)
                        }
                }
            }
            .modifier(TranscriptRowChrome(inList: !ChatProbe.shared.lazyStack,
                                          bottomPadding: Self.rowBottomPadding(for: item)))
            .id(item.id)
            .probed("row:\(item.id)")
            // 长按 = 这一行的文字入口：全文/选择文本、拷贝整条。
            //
            // 长按 = 这一行的文字入口：全文/选择文本、拷贝整条。
            //
            // 013：UIKit 宿主下长按由宿主的手势认（见 `TranscriptListHost.onRowAsk`），
            // 这里只负责另一条宿主分支的 `contextMenu`。
            .modifier(MessageActions(item: item,
                                     hostOwnsLongPress: ChatProbe.shared.listHost == "uikit") {
                readingMessage = $0
            })
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
            // 运行行不再画在这里：它是显示行（`rowsFor` 末尾的 `running-line`），
            // uikit 与 stack 两个宿主都能渲染（TC-112 的根因就是它原来只住在这里）。
        }
        .modifier(TranscriptRowChrome(inList: !ChatProbe.shared.lazyStack))
        .probed("tail")
    }

    /// 内容末尾的 1pt 标记，滚到底的目标。
    private var bottomMarker: some View {
        Color.clear
            .frame(height: 1)
            .modifier(TranscriptRowChrome(inList: !ChatProbe.shared.lazyStack))
            .id(Self.bottomAnchor)
            .probed("bottom")
    }

    /// 记下新的距离并重新判定（iOS 18 起才有距离可测；更低的系统只剩哨兵的 `onAppear`）。
    private func noteTopDistance(_ distance: CGFloat, proxy: ScrollViewProxy) {
        topDistance = distance
        topDistanceAt = Date()
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
            ChatProbe.shared.probeNote?("older.nogeometry", [
                "following": isFollowing ? "1" : "0",
                "items": String(model.timeline.items.count),
            ], false)
            if isFollowing, !userScrolled { scrollToBottom(proxy, animated: false, force: true) }
            return
        }
        // 预加载的"可见余量"：离顶部还有一屏（`prefetchMargin`）就开始惦记补页，
        // 真正触发仍在 `sentinelApproach`（哨兵行进视口）。两条线分开的理由是
        // **取消**——读者掉头往下时，靠 `prefetchMargin` 才有个明确的"可以放弃"的界限。
        if distance >= Self.sentinelApproach, distance <= Self.prefetchMargin, !model.isLoadingOlder {
            ChatProbe.shared.probeNote?("prefetch.near", [
                "distance": String(format: "%.0f", distance),
                "margin": String(format: "%.0f", Self.prefetchMargin),
            ], false)
        }
        let near = distance < Self.sentinelApproach
        if near != sentinelNearTop {
            sentinelNearTop = near
            ChatProbe.shared.probeNote?("older.sentinel", [
                "distance": String(format: "%.0f", distance),
                "near": near ? "1" : "0",
                "following": isFollowing ? "1" : "0",
                "items": String(model.timeline.items.count),
            ], false)
        }
        guard near else { return }
        if isFollowing, !userScrolled {
            ChatProbe.shared.probeNote?("older.repin", ["distance": String(format: "%.0f", distance)], false)
            // 带一次延迟重钉：这次判定往往发生在"内容刚落地、行还没排完"的那一刻，
            // 单次 `scrollTo` 会落在空布局上（2026-09-24 实测 3 轮里 1 轮就这么卡住了）。
            // 这一支**允许用旧数据**：钉底是幂等的、方向明确的（读者没往上翻，就该在底部）。
            repinAfterContentChange(proxy)
            return
        }
        // 补页这一支必须用"刚量到的"位置：几何只在**值变化**时回调，而"视口一直停在顶部"
        // 这种情况不再产生变化，缓存下来的 0 会一直留着。读者其实已经不在顶部时拿它去补页，
        // 就是往视口上方插内容、把读者看到的位置顶走（2026-09-24 实测：跳转到搜索命中后
        // 又白补了一页，命中那一行被顶出屏幕）。
        let fresh = Date().timeIntervalSince(topDistanceAt) < Self.distanceFreshness
        guard fresh else {
            ChatProbe.shared.probeNote?("older.stale", [
                "distance": String(format: "%.0f", distance),
                "age": String(format: "%.1f", Date().timeIntervalSince(topDistanceAt)),
            ], false)
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
    @State private var lastPumpTrace = Date.distantPast

    private func pumpOlder(_ proxy: ScrollViewProxy) {
        guard ownsTranscript, sentinelNearTop, model.hasOlder || model.hasUnfilledGaps,
              !model.isLoadingOlder, olderPump == nil else {
            // 顶部不再自动补页时，必须能区分是哪一条闸门挡住的：没有这条，
            // "还有历史却不动"只能靠猜（2026-10-18 仿真连续上拉 386 次卡在同一处）。
            if Date().timeIntervalSince(lastPumpTrace) > 1 {
                lastPumpTrace = Date()
                DSHLog.event("pump.skip", [
                    "owns": ownsTranscript ? "1" : "0",
                    "nearTop": sentinelNearTop ? "1" : "0",
                    "hasOlder": model.hasOlder ? "1" : "0",
                    "gaps": model.hasUnfilledGaps ? "1" : "0",
                    "loading": model.isLoadingOlder ? "1" : "0",
                    "pumping": olderPump == nil ? "0" : "1",
                ])
            }
            return
        }
        // 已经失败过就先别自动再试：否则"重试条出现 → 布局变化把哨兵推回来 → 又发一页 →
        // 失败清掉 olderFailure → 胶囊出现 → 失败 → 重试条再出现"会一直翻来覆去
        // （2026-10-08 用例 53 实测：探针里重试条 7.68s 就布局好了，8.5s 的截图却是加载态）。
        // 失败之后由读者点重试条，或由那一次自动补试收尾。
        guard model.olderFailure == nil else { return }
        olderPump = Task { @MainActor in
            defer { olderPump = nil }
            for _ in 0..<Self.maxOlderBurst {
                if Task.isCancelled || !ownsTranscript { return }
                let anchor = model.timeline.items.first?.id
                let before = ChatProbe.shared.scrollFacts?()
                let count = model.timeline.items.count
                // 锚点在 await 之前落位：插入会在同一帧触发 onChange(items.count)，
                // 以前等返回再赋值，锚定分支可能先跑（顺序未定义）。
                prependAnchor = anchor
                prependAnchorAtTop = sentinelNearTop
                prependBaseline = before
                let anchorSequence = anchorCompletions
                await model.loadOlder()
                guard model.timeline.items.count > count else {
                    prependAnchor = nil
                    return
                }
                // 等锚定收敛后再量 `kept`：固定睡 400ms 会在"一页 150 行"的降级通道上
                // 量到还在折行的中间态，把已经收敛的补页误记成 kept=0（用例 50 实测）。
                // `onChange(items.count)` 是**异步投递**的：插入刚返回时锚定任务可能还没建起来，
                // 此刻直接 await 会立刻返回，等于在没锚之前就量 kept（2026-10-08 实测：读回路径
                // 因此被误记成 kept=0，而它其实锚住了）。先等任务出现，再等它跑完。
                var waitedForAnchor = 0
                while anchorCompletions == anchorSequence, waitedForAnchor < 1500 {
                    try? await Task.sleep(for: .milliseconds(25))
                    waitedForAnchor += 25
                }
                if Task.isCancelled { return }
                let after = ChatProbe.shared.scrollFacts?()
                var kept = "-"
                if let before, let after {
                    let movedOffset = after.offset - before.offset
                    let grewContent = after.content - before.content
                    kept = abs(movedOffset - grewContent) <= Self.keepTolerance ? "1" : "0"
                    if kept == "0" {
                        ChatProbe.shared.probeNote?("older.jumped", [
                            "movedOffset": String(format: "%.0f", movedOffset),
                            "grewContent": String(format: "%.0f", grewContent),
                            "items": String(model.timeline.items.count),
                        ], true)
                    }
                }
                ChatProbe.shared.probeNote?("older.pump", [
                    "items": String(model.timeline.items.count),
                    "anchor": anchor ?? "-",
                    "hasOlder": model.hasOlder ? "1" : "0",
                    "gaps": model.hasUnfilledGaps ? "1" : "0",
                    // `kept == 1` = 内容长了多少、偏移就跟着走了多少：可见内容没动。
                    "kept": kept,
                ], true)
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
    /// 判断依据是"这次插入**发起时**读者在不在顶部"（`prependAnchorAtTop`），不是插入后的
    /// 哨兵状态：插入必然把哨兵挤出视口，用后者会把锚定全部挡掉（就是 `kept=0` 的成因）。
    /// 读者若在这次补页之后自己滚走了，`sentinelNearTop` 会被 `evaluateTopDistance` 置回 false，
    /// 那一次的后续重试就会停手——不去和读者抢滚动。
    private func anchorAfterPrepend(_ proxy: ScrollViewProxy) {
        guard let anchor = prependAnchor, prependAnchorAtTop else { return }
        prependAnchorTask?.cancel()
        prependAnchorTask = Task { @MainActor in
            // 由**测量**决定锚几次，而不是由固定时刻表决定（原来的 0/60/160/320ms 四枪）。
            //
            // 为什么：一页 30 行时第一枪就到位，一页 150 行（降级通道）时行高要过一秒才折完，
            // 固定时刻表要么锚不够、要么白锚。这里的判据是"内容高度连着两轮没变"——布局稳了
            // 就停手，没稳就再锚一次，最多 `anchorAttemptCap` 次。
            var attempts = 0
            var stableRounds = 0
            var lastContent = ChatProbe.shared.scrollFacts?()?.content
            while attempts < Self.anchorAttemptCap {
                if Task.isCancelled || !ownsTranscript { return }
                guard model.timeline.items.contains(where: { $0.id == anchor }) else { return }
                // 第一枪无条件锚（插入刚落地）；之后读者若已离开顶部就停手，不跟他抢滚动。
                if attempts > 0, !sentinelNearTop { return }
                proxy.scrollTo(anchor, anchor: .top)
                attempts += 1
                try? await Task.sleep(for: .milliseconds(80))
                let content = ChatProbe.shared.scrollFacts?()?.content
                if let lastContent, let content, abs(content - lastContent) < 1 {
                    stableRounds += 1
                } else {
                    stableRounds = 0
                }
                lastContent = content
                if stableRounds >= 2 { break }
            }
            anchorCompletions += 1
            ChatProbe.shared.probeNote?("older.anchor", [
                "attempts": String(attempts),
                "stable": stableRounds >= 2 ? "1" : "0",
            ], true)
        }
    }

    /// 滚到搜索选中的那一行，并高亮一会儿。
    ///
    /// 三次重试的理由和 `pinOnOpen` 一样：目标行的位置要等 `List` 把这一批行折完才准，
    /// 只滚一次会落在"当时的"位置上。同时把跟随关掉、并记成"读者自己滚过"——
    /// 否则滚过去之后只要内容一变，`repinAfterContentChange` 就把人拽回底部。
    /// 跳到一条**命中**上。
    ///
    /// 和 `jumpToItem(id:)` 的区别是它认的是**seq**：合并搜索缓冲会重新折时间线，
    /// 行 id 可能就变了（2026-10-08 T068：按 id 跳时，合并之后 `contains(id)` 不再成立，
    /// 梯子里的重试全部直接 return，视口就停在合并把它挤到的位置上）。
    /// 这里每一枪都重新按 seq 解析一次行，解析不到才退回去用面板给的那个 id。
    private func jumpToHit(_ hit: TranscriptSearchHit, proxy: ScrollViewProxy) async {
        // 这条路的**每个**出口都要留痕（T037 同款纪律）：原来只有"滚完了"的那一条
        // 才有 `search.jump`，2026-10-11 用例 49 两次复跑里它一次都没出现，凭日志
        // 分不清是"根本没进这个函数"还是"卡在换窗口上"（run 20261011-204318：
        // 面板关掉了、视口留在底部、探针里既没有 search.jump 也没有 search.rebase*）。
        ChatProbe.shared.probeNote?("search.jump.begin", [
            "item": hit.id, "seq": String(hit.seq),
            "owner": ownsTranscript ? "1" : "0",
            "inWindow": TranscriptHitLocator.row(exactlyForSeq: hit.seq,
                                                 in: model.timeline.items) == nil ? "0" : "1",
            // 行在时间线里 ≠ 在**管道窗口**里：搜索上下文 prepend 的行会被下一次
            // refold 抹掉，跳转必须按后者判（见 ChatPipelineBridge.holds）。
            "inPipeline": model.pipelineHolds(seq: hit.seq) ? "1" : "0",
        ], true)
        guard ownsTranscript else {
            ChatProbe.shared.probeNote?("search.jump.skip", ["reason": "not-owner"], true)
            return
        }
        isFollowing = false
        userScrolled = true
        // 命中在窗口内时不走 rebaseWindow，模型侧也要强制「阅读中」（spec 场景 9：
        // 否则跳转后到下一条几何上报之间来的增量会按 atBottom 计、还可能拽回底部）。
        model.noteJumpToReading()
        // 命中可能是被折叠的过程行：先展开它所在的轮次/过程组，后面的
        // `TranscriptHitLocator` 才能在显示行里解析到它（spec 033 FR-013）。
        if let raw = TranscriptHitLocator.row(exactlyForSeq: hit.seq, in: model.timeline.items) {
            _ = model.revealProcess(containingRowID: raw.id)
        }
        // 命中可能在窗口**之外**（搜索是全会话的，时间线只装一窗）：先换窗口再滚，
        // 否则"按 seq 解析行"只会解析到窗口的第一行，怎么滚都落不到目标上（T068）。
        // 归属判据是**管道窗口**（`pipelineHolds`），不是"时间线里凑巧有这一行"：
        // 搜索命中会把命中附近的一段从本地库 prepend 进时间线，那段不在管道的
        // records 里，下一次 refold 就把目标行拿掉、视口掉回尾部（2026-10-11
        // 用例 49 run 20261011-210558 实测）。管道窗口里真没有才让管道拉目标页。
        if model.pipelineActive {
            if !model.pipelineHolds(seq: hit.seq) {
                // **不等它**：换窗口是网络动作（丢回包时 unary 要等 60 秒超时），
                // 跳转不能跟着一起卡住——命中行可能已经在时间线里（搜索上下文
                // prepend 的那一段），梯子照旧一枪枪试，换窗口落地后后面的枪会
                // 打在正确的行上（`search.jump.rebase` 留痕，2026-10-11 用例 49
                // run 20261011-210945 实测：await 换窗口把 `search.jump` 整条吞掉）。
                ChatProbe.shared.probeNote?("search.jump.rebase", ["seq": String(hit.seq)], true)
                rebalancing = true
                Task { @MainActor in
                    _ = await model.rebaseWindow(around: hit.seq)
                    rebalancing = false
                }
            }
        } else if TranscriptHitLocator.row(exactlyForSeq: hit.seq, in: model.timeline.items) == nil,
                  !model.timeline.items.contains(where: { $0.id == hit.id }) {
            _ = model.commitSearchHistory()
        }
        ChatProbe.shared.probeNote?("search.jump", [
            "item": hit.id, "seq": String(hit.seq),
            // 换窗口之后目标解析到了没有：`-` = 没有可指向的行，梯子每一枪都会跳过。
            "resolved": TranscriptHitLocator.row(exactlyForSeq: hit.seq,
                                                in: model.timeline.items)?.id ?? "-",
        ], true)
        Task { @MainActor in
            for delay in [0, 120, 300, 600, 1000, 1800, 2600] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                if Task.isCancelled || !ownsTranscript { return }
                // 精确归属：换窗口失败时钳制版会把目标解析成窗口第一行，
                // 梯子会把视口滚到错误位置还以为成功（009 场景⑥回归）。
                if let raw = TranscriptHitLocator.row(exactlyForSeq: hit.seq, in: model.timeline.items) {
                    _ = model.revealProcess(containingRowID: raw.id)
                }
                guard let row = TranscriptHitLocator.row(
                    exactlyForSeq: hit.seq,
                    in: model.rowsFor(screen: sessionId)) else {
                    continue
                }
                if ChatProbe.shared.listHost == "uikit" {
                    // uikit 下 ScrollViewProxy 不在宿主的视图树里（无效调用）；
                    // 交给宿主滚，且 nonce 递增让同一目标也能重试（布局未稳会落空）。
                    listJumpNonce += 1
                    listJumpId = "\(row.id)#\(listJumpNonce)"
                } else {
                    proxy.scrollTo(row.id, anchor: .center)
                }
            }
            let visible = ChatProbe.shared.visibleRowIds?() ?? []
            let target = TranscriptHitLocator.row(
                exactlyForSeq: hit.seq,
                in: model.rowsFor(screen: sessionId))?.id ?? hit.id
            if ChatProbe.shared.listHost == "uikit" {
                // 新宿主：把目标交给它滚过去（同一次更新里定位，不经过 ScrollViewProxy）。
                listJumpNonce += 1
                listJumpId = "\(target)#\(listJumpNonce)"
                return
            }
            ChatProbe.shared.probeNote?("search.jump.settle", [
                "item": target, "seq": String(hit.seq),
                "top": ChatProbe.shared.topVisibleRow?() ?? "-",
                "items": String(model.timeline.items.count),
                "visible": String(visible.count),
                "near": visible.prefix(3).joined(separator: "|"),
            ], true)
            highlightedItemId = target
            highlightTask?.cancel()
            highlightTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1600))
                if Task.isCancelled { return }
                highlightedItemId = nil
            }
        }
    }

    private func jumpToItem(_ id: String, proxy: ScrollViewProxy) {
        guard ownsTranscript else { return }
        isFollowing = false
        userScrolled = true
        model.noteJumpToReading() // 同 jumpToHit：跳转强制「阅读中」（spec 场景 9）。
        // 选中的那条可能还在"搜索缓冲"里（面板往前翻过历史、但没动时间线）：
        // 先把它并进时间线，下面的重试才找得到这一行。并入会往视口上方插内容，
        // 所以紧接着的跳转本身也是"把视口带到那一条"。
        _ = model.revealProcess(containingRowID: id)
        if !model.timeline.items.contains(where: { $0.id == id }) {
            _ = model.commitSearchHistory()
        }
        ChatProbe.shared.probeNote?("search.jump", ["item": id], true)
        Task { @MainActor in
            // 梯子要够长：`commitSearchHistory()` 把搜索缓冲并进时间线时是**往上方插内容**，
            // 插入落地会把目标行挤走；只滚三次（0/120/300ms）时，最后一次常常落在插入之前的布局上
            // （2026-10-08 用例 49 实测：`search.jump` 之后 offset 变成 -116，目标行不在屏幕上）。
            // 最后两枪要打在"内容稳定之后"：并缓冲/插内容会让 `List` 在 1–2 秒里继续
            // 调整偏移（探针里 19.2s 到 20.7s 之间 top_row_y 还在变），早于这个时刻的 scrollTo
            // 都会落在旧布局上（2026-10-08 用例 49 实测：2.2s 时目标行已经在视口上方 360pt）。
            for delay in [0, 120, 300, 600, 1000, 1800, 2600] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                if Task.isCancelled || !ownsTranscript { return }
                _ = model.revealProcess(containingRowID: id)
                guard model.rowsFor(screen: sessionId).contains(where: { $0.id == id }) else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            // 落点诊断：跳完之后视口最上面是哪一行。目标行不在附近就说明又没钉住。
            let visible = ChatProbe.shared.visibleRowIds?() ?? []
            ChatProbe.shared.probeNote?("search.jump.settle", [
                "item": id, "top": ChatProbe.shared.topVisibleRow?() ?? "-",
                "items": String(model.timeline.items.count),
                // 目标行到底在不在视口里、周围是哪些行——一次就能分清"视口外"与"没渲染"。
                "visible": String(visible.count),
                "near": visible.prefix(3).joined(separator: "|"),
            ], true)
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
    /// `ChatProbe.shared.olderScrollRounds`）。仿真器里没法对转写页做手势滑动，
    /// 所以"一直往上滑"这一段只能这样驱动；送上去之后的一切都是产品代码。
    private func runOlderScrollDrive(_ proxy: ScrollViewProxy) async {
        guard let rounds = ChatProbe.shared.olderScrollRounds, rounds > 0 else { return }
        // 等首屏与钉底那一串走完，否则驱动会和 `pinOnOpen` 抢滚动位置。
        try? await Task.sleep(for: .seconds(6))
        for round in 1...rounds {
            guard ownsTranscript, !Task.isCancelled else { return }
            // 手指挥做的事这里也要做：真实拖动会把"跟随中"关掉（见 `simultaneousGesture`），
            // 而 `scrollTo` 不会。不置这一位，读者到了顶部却还被判成"在看最新"，
            // 于是被钉回底部（`evaluateTopDistance` 的第一条），补页永远不触发。
            isFollowing = false
            userScrolled = true
            ChatProbe.shared.probeNote?("older.drive", [
                "round": String(round), "phase": "up",
                "items": String(model.timeline.items.count),
                "top": ChatProbe.shared.topVisibleRow?() ?? "-",
            ], true)
            proxy.scrollTo(Self.topAnchor, anchor: .top)
            try? await Task.sleep(for: .milliseconds(500))
            ChatProbe.shared.probeNote?("older.drive", [
                "round": String(round), "phase": "at-top",
                "loading": model.isLoadingOlder ? "1" : "0",
                "near": sentinelNearTop ? "1" : "0",
                "top": ChatProbe.shared.topVisibleRow?() ?? "-",
            ], true)
            try? await Task.sleep(for: .seconds(4))
        }
        ChatProbe.shared.probeNote?("older.drive", [
            "phase": "done",
            "items": String(model.timeline.items.count),
            "hasOlder": model.hasOlder ? "1" : "0",
            "top": ChatProbe.shared.topVisibleRow?() ?? "-",
        ], true)
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
                requestBottomScroll(proxy, open: true)
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
        guard isFollowing, !userScrolled, ownsTranscript else { return }
        // 先立刻钉一次：这一批内容如果已经布局好，它就直接生效，用户看不到任何中间态。
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        contentRepinTask?.cancel()
        contentRepinTask = Task { @MainActor in
            // 再按 150/450/900ms 各钉一次：行高是在折入过程中被修正的，修正会改变内容总高，
            // 系统的底部锚定因此可能停在半路。三次的成本只是一次 `scrollTo`（不布局、不动画），
            // 而"打开会话停在顶部"这个毛病是**间歇性**的——2026-09-24 实测 8 轮里 2 轮，
            // 只排一次 150ms 会漏（那次内容 1.1 秒才落地，行高更晚）。
            // 每次之前都重新问一遍"读者还在跟随吗"，一旦他自己拖过就立刻停手。
            for delay in [150, 450, 900] {
                try? await Task.sleep(for: .milliseconds(delay))
                if Task.isCancelled { return }
                guard isFollowing, !userScrolled, ownsTranscript else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
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
    /// 请求宿主滚到底：打开/回底共用一个入口，按宿主类型分派（不在各处重复分支）。
    private func requestBottomScroll(_ proxy: ScrollViewProxy, open: Bool = false) {
        if ChatProbe.shared.listHost == "uikit" {
            if open {
                listHostRef?.beginFollowingTail()
            } else {
                bottomSignal &+= 1
            }
        } else if open {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        } else {
            scrollToBottom(proxy, animated: true)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true, force: Bool = false) {
        model.releaseProcessToggleFollow()
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
    /// 取消在飞的补页并留一条诊断（反向滚动、切会话都走这里）。
    private func cancelOlderPump(reason: String) {
        guard olderPump != nil else { return }
        olderPump?.cancel()
        olderPump = nil
        ChatProbe.shared.probeNote?("prefetch.cancel", ["reason": reason], true)
    }

    /// 预加载余量：离顶部还有这么高就开始"惦记"下一页（见 `evaluateTopDistance`）。
    /// 比触发线（`sentinelApproach`）大得多，所以它是**预取意图**而不是触发点；
    /// 掉头往下超过这条线就取消在飞的补页。
    private static let prefetchMargin: CGFloat = 700
    /// 一次补页最多锚几次（测量驱动：布局稳定就提前停）。
    private static let anchorAttemptCap = 10
    /// 判"位置没跳"的容差：内容长了多少、偏移就该跟着走多少，差在这一点之内算原地不动。
    private static let keepTolerance: CGFloat = 20
    /// 位置数据的新鲜度上限：超过它就不许拿它触发补页（见 `evaluateTopDistance`）。
    private static let distanceFreshness: TimeInterval = 0.6

    private static let bottomAnchor = "transcript-bottom"
    private static let topAnchor = "transcript-top"

    /// 截图入口的取值：Release 恒为 `nil`（`automationActivityScreen()` 只在 DEBUG 里有定义）。
    ///
    /// 单独抽一层而不是在 sheet 里直接调：Release 里那次调用会让整个 body 的类型检查
    /// 超时（`error: the compiler is unable to type-check this expression in reasonable time`）。
    static var automationScreenArgument: String? {
        #if DEBUG
        return automationActivityScreen()
        #else
        return nil
        #endif
    }

#if DEBUG
    /// `-DSHOpenScreen activity|activity-output`；其它取值返回 nil（交给 `RootView` 处理）。
    static func automationActivityScreen() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHOpenScreen"),
              arguments.indices.contains(index + 1)
        else { return nil }
        let value = arguments[index + 1]
        return ["activity", "activity-output", "activity-settled"].contains(value) ? value : nil
    }
#endif

}

#endif

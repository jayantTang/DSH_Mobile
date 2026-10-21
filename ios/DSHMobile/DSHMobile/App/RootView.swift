import DSHFilesUI
import DSHPluginUI
import DSHSettingsUI
import DSHSessionsDomain
import DSHSessionsUI
import DSHChatDomain
import DSHChatUI
import DSHConnectionDomain
import DSHCore
import DSHConnectionUI
import DSHFilesDomain
import DSHSettingsDomain
import DSHFeedbackDomain
import DSHFeedbackUI
import DSHDesign
import DSHFoundation
import DSHKit
import SwiftUI
import UIKit

/// The application root: owns the long-lived stores and routes between
/// onboarding and the main workspace.
struct RootView: View {
    @State private var store: ConnectionStore
    @State private var connectionEnv: ConnectionEnv
    @State private var hub = HostEventHub()
    @State private var updates = UpdateChecker()
    @State private var alertPrefs = SessionAlertPrefs.shared
    @State private var feedbackServices = FeedbackServices(renderMarkdown: { AnyView(MarkdownText(text: $0)) })
    @State private var sessionsServices = SessionsServices(
        refreshFeedback: { await FeedbackCenter.shared.applicationBecameActive() },
        feedbackUnreadCount: { FeedbackCenter.shared.unreadCount },
        feedbackView: { AnyView(FeedbackCenterView()) }
    )
    @State private var alerts = SessionAlerts()
    @State private var attachmentImages = AttachmentImages()
    @State private var viewLog = SessionViewLog()
    /// 032：本机答过哪些待回应提示（跨设备互斥用）。
    @State private var answerLog = PromptAnswerLog()
    @State private var listModel = SessionListModel()
    /// 018：活动可见性的适配层。应用级一份名单，列表与聊天页读同一份。
    @State private var activity = ActivityModel.shared

    /// 026：探针从 static 改实例后，由装配点在构造期注入（行为与 static 版一致）。
    init() {
        let store = ConnectionStore()
        _store = State(initialValue: store)
        _connectionEnv = State(initialValue: ConnectionEnv(store))
        let note: (String, [String: String], Bool) -> Void = { kind, fields, force in
            ViewportProbe.note(kind, fields, force: force)
        }
        store.probeNote = note
        hub.probeNote = note
        SessionRouter.shared.probeNote = note
        listModel.probeNote = note
    }
    @State private var chatModel = ChatModel()
    /// 009 消息层（磁盘层 + 内存层枢纽）：列表/会话的冷启动叠加都从它取数。
    @State private var messageLayer = MessageLayer.withAppProbes()
    /// Holds the app awake in the background while there is work to report on.
    @State private var keepAlive = RunKeepAlive()
    /// 前后台副作用执行器：首次 phase 变化时用当前 stores 装配。
    @State private var lifecycle: ScenePhaseCoordinator?

    @Environment(\.scenePhase) private var scenePhase
    @State private var lastConnected = false
    /// Once the workspace has been reached, a dropped link reconnects *inside*
    /// it. Falling back to the pairing screen made every trip to the background
    /// look like the connection had been lost for good.
    @State private var enteredWorkspace = false
    @State private var connectionError: String?

    var body: some View {
        // 模块化后这条修饰链跨模块解析变慢，拆成两个计算属性分段推导（025）。
        stageTwo
    }

    private var stageOne: some View {
        content
            .environment(store)
            .environment(connectionEnv)
            .environment(hub)
            .environment(activity)
            .environment(updates)
            .environment(alerts)
            .environment(alertPrefs)
            .environment(sessionsServices)
            .environment(feedbackServices)
            .environment(attachmentImages)
            .tint(DSHTheme.brand)
            .alert("连接失败", isPresented: Binding(
                get: { connectionError != nil },
                set: { if !$0 { connectionError = nil } }
            )) {
                Button("好", role: .cancel) { connectionError = nil }
            } message: {
                Text(connectionError ?? "")
            }
            // A reconnected link is a different world from the one that failed:
            // pictures that lost their race with an outage get another chance
            // without anyone tapping.
            .onChange(of: store.state.isConnected) { _, isConnected in
                if isConnected { attachmentImages.clearFailures() }
                // 018：断线 → 冻结本地推断并标「上次已知」；重连 → 重新问名单。
                activity.setConnected(isConnected)
            }
            .onChange(of: store.activeProfile?.id) { _, _ in
                // 032：档案一换（刚配对、切到另一台电脑）就去对齐账户级状态。
                // 挂在"主机在线"上是不够的：电脑睡着时也应当能对齐已读与开关。
                Task { await AccountStateSync.shared.refresh() }
            }
            .task {
                let startup = AppStartupCoordinator(
                    store: store, hub: hub, listModel: listModel, chatModel: chatModel,
                    messageLayer: messageLayer, attachmentImages: attachmentImages,
                    activity: activity, viewLog: viewLog, answerLog: answerLog,
                    alertPrefs: alertPrefs,
                    onConnectionFailure: { connectionError = $0 })
                await startup.start()
            }
            .task {
                // P-3 尾巴的复现钩子：把 `-DSHStageFile <路径>` 走**附件菜单那条路**
                // —— `Composer.copyIntoContainer`（现在是 `OutgoingFiles.stage`），
                // 再交给同一个 `sendFile(fileURL:)`。`-DSHUploadFilePath` 直接用调用方
                // 给的路径，**不经过**暂存，验不到"发完把自己那份删掉"这件事；
                // 系统文件选择器是跨进程的、XCUITest 点不到（见 19a 用例的备注）。
                // 这条钩子是唯一能自动验到 P-3 改的那段代码的入口。
                if let path = Self.automationStageFile() {
                    for _ in 0..<40 where chatModel.session == nil {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    await Self.stageAndSend(path: path, model: chatModel)
                    return
                }
                if let path = Self.automationUploadFilePath() {
                    for _ in 0..<40 where chatModel.session == nil {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    await chatModel.sendFile(
                        named: (path as NSString).lastPathComponent,
                        fileURL: URL(fileURLWithPath: path))
                    return
                }
                guard let path = Self.automationUploadFile(),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path))
                else { return }
                for _ in 0..<40 where chatModel.session == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                await chatModel.sendFile(named: (path as NSString).lastPathComponent, data: data)
            }
            .task {
                guard let path = Self.automationDraftImage(),
                      let image = UIImage(contentsOfFile: path)
                else { return }
                // Waits for a session to exist so the picture lands in the one
                // the run opened rather than a model about to be replaced.
                for _ in 0..<40 where chatModel.session == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                chatModel.addDraftImages([image], names: [(path as NSString).lastPathComponent])
            }
            // Its own task: the connection task has an early return for the
            // automation path, and the update check must not be skipped.
            .task {
                await updates.refresh()
            }
            .task {
                await alerts.prepare()
            }
            #if DEBUG
            // P-13 步骤 0 的探针（`-DSHP13ResumeProbe`）：连接就绪后，按中转通道
            // 真实下载一个文件、中途按"暂停"的语义取消，看系统给不给 resume data、
            // 第二次请求发不发 `Range`。只在带那个参数启动时工作，见 `P13ResumeProbe`。
            .task(id: store.state.isConnected) {
                guard P13ResumeProbe.isOn else { return }
                // The control run fetches a direct URL and must not depend on a
                // live connection: it measures what iOS does with a given response
                // shape, and a relay in the picture would be a second variable.
                if P13ResumeProbe.isControlRun {
                    P13ResumeProbe.run(
                        relayURL: URL(string: "http://127.0.0.1/")!, deviceToken: "control"
                    )
                    return
                }
                guard store.state.isConnected, let target = try? store.fileTransferTarget()
                else { return }
                P13ResumeProbe.run(relayURL: target.relayURL, deviceToken: target.deviceToken)
            }
            #endif
            .task {
                // 仿真器复现「App 在后台时用户点了通知」（`-DSHProbeNotifyTap <sid>@<秒>`）。
                // 走的完全是产品那条 `didReceive` → `SessionRouter` → `MainView` 的路，
                // 探针只负责把这一下点出来。DEBUG-only，见 `NotificationProbe`。
                //
                // 叠栈那条路（"已经在会话 A 里，通知再把 B 推上来"，用例 102）用
                // `{{pick}}` 给 B：运行器每轮现挑一条真实会话，只读地推上来，
                // 开关见 `test/cases/current/102-换会话不闪上一个会话.md`。
                await ViewportProbe.runNotifyTapProbe(delegate: alerts)
            }
            .task {
                // 推送登记：把本机 APNs 令牌与环境报给 relay。
                //
                // 放在这里（而不是连接成功之后）是刻意的：手机"不在家"的时候
                // 恰恰没有连接，而推送正是为那一刻存在的——若只有连着才上报，
                // 会变成"只有不需要推送的时候才登记得上"。
                // 令牌可能来自本次启动的回调，也可能早就落盘了，两条路都会调
                // `reportToRelayIfNeeded`，未变化时是一次空操作。
                await APNSRegistrar.shared.reportToRelayIfNeeded()
            }
            .task {
                // 一启动就把落盘的列表装进 model，**不等连接**：屏幕立刻有行可看，
                // 而不是先空着等 host 答话（这正是"打开是空的"的来源）。
                // 先认下上次那台电脑（下面要按它读快照），再读缓存。
                if store.adoptPreferredProfile() {
                    // 采纳即视为"进过工作区"：屏幕留在列表上（缓存行 + 状态胶囊），
                    // 而不是被弹回连接页——连接页只负责"从没连过任何一台"这件事。
                    enteredWorkspace = true
                    Task { await store.reconnectIfNeeded() }
                }
                listModel.loadCachedList()
                // 磁盘缓存的自净：过期与超预算的转写在启动时清一次（不在热路径上做）。
                await Task.detached {
                    await Self.housekeepTranscriptStore()
                    AttachmentDiskCache().prune()
                }.value
                // 认下上次那台电脑并直接进列表：连不上也在列表上显示缓存 + 未连接，
                // 而不是把用户拦在连接页（换电脑走列表顶部的连接入口）。
            }
            .task {
                // OTA 诊断（仅 `DIAGNOSTICS` 构建存在）：启动即采集，并在连接建立/更换后
                // 把推送目标换到当前链路。非 OTA 构建里整段被编译掉，闭包为空。
                #if DIAGNOSTICS
                AppDiagnostics.shared.start()
                while !Task.isCancelled {
                    AppDiagnostics.shared.attachIfNeeded(store.diagnosticsCarrier)
                    try? await Task.sleep(for: .seconds(1))
                }
                #endif
            }
            .task {
                // 夹具：`-DSHProbeAsk <sessionId>` 时由 App 自己给那个会话发一条
                // "立刻提问"的提示词——host 侧 RPC 发起的提问送不到手机，
                // 只有走产品这条路（本设备发起的 turn）waterfall 才会回到 App。
                await ViewportProbe.runAskProbe(provider: { store.chatHost })
            }
            .task {
                // Injected link drop: see `automationDropLinkAfter`. Debug only,
                // like the hook itself — the release build has none of this.
                #if DEBUG
                guard let delay = Self.automationDropLinkAfter() else { return }
                try? await Task.sleep(for: .seconds(delay))
                await store.dropLinkForTesting()
                #endif
            }
            .onChange(of: store.state.isConnected) { _, isConnected in
                syncConnectionState(isConnected)
            }
    }

    private var stageTwo: some View {
        stageOne
            .onChange(of: scenePhase) { _, phase in
                let coordinator = lifecycle ?? ScenePhaseCoordinator(
                    store: store, hub: hub, listModel: listModel, chatModel: chatModel,
                    updates: updates, alerts: alerts, keepAlive: keepAlive)
                lifecycle = coordinator
                coordinator.handle(phase.lifecyclePhase)
            }
            .onChange(of: hub.isLive) { _, live in
                // The feed is back after a drop: whatever happened while it was
                // away is only visible in a fresh list, and a run that ended in
                // that window still owes the user a notification.
                guard live else { return }
                Task { await listModel.refresh() }
            }
            .onChange(of: listModel.runningCount) { _, running in
                if let lifecycle {
                    lifecycle.syncHoldAwake(phase: scenePhase.lifecyclePhase)
                } else {
                    keepAlive.sync(
                        isBackground: scenePhase == .background,
                        hasWorkInFlight: running > 0 || !hub.pending.isEmpty
                    )
                }
            }
            .onChange(of: hub.hostHome) { _, home in
                if let home { store.hostHome = home }
            }
            .onOpenURL { url in
                #if DIAGNOSTICS
                if AppDiagnostics.shared.handle(url: url) { return }
                #endif
                handle(url)
            }
    }

    /// Handles a QR-code or pasted connection link.
    private func handle(_ url: URL) {
        guard let link = ConnectLink(url: url) else { return }
        Task {
            if let failure = await store.connect(link: link) {
                connectionError = failure
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        // Once the workspace has been reached, a dropped link no longer
        // navigates: the screen keeps what it has and the status chip reports
        // the state. The pairing screen is for "not connected to anything yet",
        // which is a different situation from "the network blinked" — and the
        // difference is the whole point of a remote client you leave running.
        if store.state.isConnected || enteredWorkspace {
            MainView(
                listModel: listModel,
                chatModel: chatModel,
                automationSessionId: Self.automationSessionId(),
                automationScreen: Self.automationScreen(),
                automationFile: Self.automationFile(),
                automationFilesDir: Self.automationFilesDir()
            )
        } else {
            ConnectionView(onPairingChanged: { await APNSRegistrar.shared.pairingChanged() })
        }
    }

    #if DEBUG
    /// A workspace file to open on launch, relative to the session's workspace.
    static func automationFile() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHOpenFile"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// A picture to pre-load into the composer, for the unattended run.
    ///
    /// The system photo picker runs out of process and cannot be driven from a
    /// UI test, so the part worth testing — encoding, uploading, rendering — is
    /// driven from a file instead. The picker itself is Apple's UI.
    static func automationDraftImage() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHDraftImage"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }
    /// A file to upload through the app's own path, for the unattended run.
    ///
    /// The Files picker runs out of process, so the app's side of a file send —
    /// read, chunk, upload, prompt — is driven from a path instead.
    static func automationUploadFile() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHUploadFile"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// 与 `-DSHUploadFile` 相同，但走**文件 URL** 那条路（`sendFile(fileURL:)`）。
    ///
    /// 这是大文件真正走的分支：R-1 的后台上传只在 ≥ 阈值且连接器报了
    /// `background-transfer` 时启用，而它要的输入是一个留在磁盘上的文件。
    /// 老钩子先把整个文件读进 `Data`，那已经跨过了边界，验不到新路。
    static func automationUploadFilePath() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHUploadFilePath"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// 走**暂存**那条路发一个文件（P-3 尾巴的复现钩子）。
    ///
    /// 与 `-DSHUploadFilePath` 的差别就是这条用例要问的那件事：那个钩子把调用方给的
    /// 路径直接交给上传，**不产生** App 自己的拷贝，所以"发完把拷贝删掉"在它下面
    /// 根本不会发生。这里先走 `Composer` 的 `copyIntoContainer`
    /// （= `OutgoingFiles.stage`），再发 —— 与用户在附件菜单里选一个文件完全相同。
    static func automationStageFile() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHStageFile"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// Stages `path` the way the composer does and sends the copy.
    ///
    /// Returns silently on a staging failure: the case then sees no prompt and
    /// fails on its own assertion, rather than on a retry loop here that would
    /// hide which half broke.
    static func stageAndSend(path: String, model: ChatModel) async {
        guard let staged = Composer.stageForAutomation(path) else {
            DSHLog.push("stage-file: staging failed for \(path)")
            return
        }
        DSHLog.push("stage-file: staged \(path) -> \(staged.path)")
        await model.sendFile(named: staged.lastPathComponent, fileURL: staged)
    }
    #else
    static func automationDraftImage() -> String? { nil }
    static func automationUploadFile() -> String? { nil }
    static func automationUploadFilePath() -> String? { nil }
    #endif

    #if DEBUG
    /// Opens one named session on launch, for the same unattended verification.
    static func automationSessionId() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHOpenSession"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// Opens one of the sheet surfaces on launch, so every screen can be
    /// reviewed from a screenshot without a human tap.
    static func automationScreen() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHOpenScreen"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// Workspace-relative directory for the file browser to open at.
    static func automationFilesDir() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHFilesDir"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// Seconds after launch at which to drop the link, for the unattended run.
    ///
    /// "The network blinked" cannot be produced from inside the simulator — the
    /// process keeps its sockets and the Mac keeps its route — so the drop is
    /// injected at the carrier, which is the same place a dead socket shows up.
    /// Everything the user sees afterwards is the product's own recovery.
    static func automationDropLinkAfter() -> Double? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHDropLinkAfter"),
              index + 1 < arguments.count
        else { return nil }
        return Double(arguments[index + 1])
    }
    #else
    static func automationSessionId() -> String? { nil }
    static func automationScreen() -> String? { nil }
    static func automationFile() -> String? { nil }
    static func automationFilesDir() -> String? { nil }
    static func automationDropLinkAfter() -> Double? { nil }
    static func automationStageFile() -> String? { nil }
    static func stageAndSend(path: String, model: ChatModel) async {}
    #endif

    /// What identifies "the computer we are talking to", for caches that must
    /// not survive a switch. The agent id is the host's own name for itself;
    /// the profile's UUID covers a profile that has not enrolled yet.
    private var connectionScope: String? { store.scopeId }

    private func syncConnectionState(_ isConnected: Bool) {
        guard isConnected != lastConnected else { return }
        lastConnected = isConnected
        if isConnected {
            enteredWorkspace = true
            // "Already read" marks belong to one computer.
            viewLog.useScope(connectionScope)
            answerLog.useScope(connectionScope)
            // 032：连上之后再对齐一次账户级状态。启动时那次拉取可能早于配对完成
            // （那时还没有可用档案/令牌，请求要么发不出、要么用旧令牌被 401 掉）。
            Task { await AccountStateSync.shared.refresh() }
            hub.startIfNeeded(link: store.link)
            Task { await listModel.start() }
            // Whatever was on screen when the link went away is stale by the
            // time it comes back: re-open the transcript so a blip cannot leave
            // a frozen conversation that looks live.
            Task { await chatModel.reopenAfterReconnect() }
            // 连上是一次"补报"的机会，而且是必需的一次：令牌可能在还没有任何配对
            // 的时候就到了（那时没地方可报），也可能这次的设备行是新的。上报本身
            // 幂等，未变化时是一次空操作，所以每次都问一遍不花代价。
            Task { await APNSRegistrar.shared.reportToRelayIfNeeded() }
        } else if store.activeProfile == nil {
            // A deliberate switch or disconnect: the old host's data must go —
            // every cache, not just the live streams. Cloning or forking a
            // session on another computer can reuse an id, and a cached
            // transcript (or a cached picture) would then be shown as that
            // computer's.
            hub.stop()
            listModel.forgetConnection()
            Task { await chatModel.forgetConnection() }
            attachmentImages.reset()
            viewLog.useScope(nil)
            answerLog.useScope(nil)
            // 这里**不**停订阅：配对/切换档案过程中必然有一次"断开→连上"，
            // 停了就再也没人把它接回来（2026-10-16 真机实测：推送一直没反应，
            // 根因就是这里）。订阅本身按"流结束就 3 秒后重订"工作，链路回来自会恢复。
        }
        // Otherwise the link dropped under a workspace the user is still in.
        // Nothing is torn down: the feed restarts itself, the rows stay put,
        // and the status chip is what says the connection is down.
    }
}

/// Facts about this device that only the device can answer.
///
/// Debug only, like the rest of the automation surface: a shipping build has no
/// reason to enumerate its own fonts.
@MainActor
enum AutomationDiagnostics {
    /// Filled by whoever is on screen, so a run can read app state that has no
    /// other way to be observed. Debug builds only, main actor only.
    static var facts: [String] = []

    static func report() -> String {
        var lines: [String] = []
        lines.append(contentsOf: facts)
        lines.append("system font: \(UIFont.systemFont(ofSize: 17).familyName)")
        let wanted = ["PingFang", "Hiragino", "Heiti", "Songti", "Noto", "Arial Unicode"]
        let families = UIFont.familyNames.sorted()
        lines.append("families: \(families.count)")
        for name in families where wanted.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            lines.append("  \(name): \(UIFont.fontNames(forFamilyName: name).joined(separator: ", "))")
        }
        // Whether a font can draw a CJK glyph is the question that matters, so
        // ask the font rather than trusting a family name.
        lines.append("")
        for candidate in ["PingFang SC", "PingFang HK", "PingFang UI", "Hiragino Sans GB",
                          "Hiragino Sans", "Heiti SC", "STHeiti", "Arial Unicode MS", "sans-serif"] {
            if let font = UIFont(name: candidate, size: 17) {
                lines.append("available: \(candidate) → \(font.familyName)")
            } else {
                lines.append("missing:   \(candidate)")
            }
        }
        lines.append("")
        lines.append("system CJK fallback: " + canDraw("报"))
        return lines.joined(separator: "\n")
    }

    private static func canDraw(_ text: String) -> String {
        let font = UIFont.systemFont(ofSize: 17)
        let set = CTFontCopyCharacterSet(font) as CharacterSet
        return text.unicodeScalars.allSatisfy { set.contains($0) } ? "能画「\(text)」" : "画不了「\(text)」"
    }
}

/// The connected workspace: session list beside the transcript.
///
/// On a phone the split view collapses to a stack, which is the same
/// information architecture the desktop client uses at a narrow width.
struct SessionDetailView: View {
    @Bindable var model: ChatModel

    var body: some View {
        Group {
            // detail 列只有这一份 `ChatView`，它永远跟着模型当前的会话走，
            // 所以 `sessionId` 每次都取模型当下的值（见 `ChatView.ownsTranscript`）。
            if let session = model.session {
                ChatView(model: model, sessionId: session.sessionId)
            } else {
                EmptyStateView(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "选择一个会话",
                    message: "左侧列出了这个 DSH 上的全部会话；正在运行的项目会实时更新。"
                )
            }
        }
    }
}

extension HostEventHub {
    /// Starts the host feed only when it is not already running.
    ///
    /// Reconnecting to the same DSH should not open a second `$events` stream,
    /// which would give the app two `clientId`s racing to answer one prompt.
    func startIfNeeded(link: LinkGateway?) {
        guard let link, !isLive else { return }
        start(link: link)
    }
}


extension RootView {
    /// 本地历史的启动期清理（T027：007 `TranscriptStore` 退役）。
    ///
    /// 009 `MessageStore` 是纯缓存、没有 TTL/预算淘汰（取用失败即拉取兜底），
    /// 所以日常清理只剩 DEBUG 探针的整库清空；附件磁盘缓存的 `prune()`
    /// 仍在调用点照旧执行。
    static func housekeepTranscriptStore() async {
        #if DEBUG
        if ProbeVariants.clearTranscriptStore {
            await MessageLayer.clearTranscriptCache()
        }
        #endif
    }
}

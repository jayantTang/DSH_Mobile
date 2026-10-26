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

struct MainView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(ConnectionEnv.self) private var connectionEnv
    @Environment(HostEventHub.self) private var hub
    @Environment(SessionAlerts.self) private var alerts
    @Environment(AttachmentImages.self) private var attachmentImages
    /// Which layout this screen gets: a phone needs a stack it can drive.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Whether the app is in front, which decides if "already on screen" is a
    /// reason to stay quiet.
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var listModel: SessionListModel
    @Bindable var chatModel: ChatModel
    /// A session to open immediately, used by the unattended verification run.
    var automationSessionId: String?
    /// A surface to present immediately, used by the same run.
    var automationScreen: String?
    /// A workspace file to open immediately — a test report, for instance —
    /// with the viewer mode the run asked for.
    var automationFile: String?
    /// A workspace-relative directory to open the browser at, so an unattended
    /// run can land on a report's folder instead of walking there.
    var automationFilesDir: String?

    @State private var isShowingConnections = false
    @State private var isShowingSettings = false
    @State private var isShowingWebFallback = false
    /// Compact-width navigation: the list pushes the session it opens.
    ///
    /// A typed array rather than `NavigationPath` (015): "which session is on
    /// top" is read straight off it (`paths.last`), so the notification path no
    /// longer has to keep its own copy in a `@State` — that copy was what the
    /// user's back gesture cleared, which let a second, slower consumer push the
    /// same session again.
    @State private var paths: [String] = []
    @State private var isShowingDiagnostics = false
    @State private var filesScope: WorkspaceFileScope?
    /// A file to open as soon as the browser appears, for the unattended run.
    @State private var filesOpenPath: String?
    @State private var didApplyAutomationScreen = false
    @State private var didOpenAutomationFile = false
    /// Waterfalls already announced, so a re-render cannot repeat an alert.
    @State private var announcedPending: Set<String> = []

    var body: some View {
        bodyStageTwo
    }

    /// 修饰符链拆成两段（025 阶段4）：装配层现在跨多个模块，一条 30+ 修饰符的链
    /// 会让编译器放弃推导（`unable to type-check this expression in reasonable time`，
    /// 与 `ChatView.transcriptChrome` 同一个拆法）。
    private var bodyStageTwo: some View {
        bodyStageOne
        .onChange(of: hub.pending.map(\.id)) { _, ids in
            announceNewPending(ids)
        }
        .onChange(of: chatModel.session?.sessionId) { _, sessionId in
            // Which session is open decides whether a session that has never run
            // a turn is a row or stays host-side history; see `showsInList`.
            listModel.currentSessionId = sessionId
        }
        .onChange(of: paths.count) { _, count in
            // Back on the list, nothing is open — and on a phone the list is
            // only on screen when nothing is. Without this, the last session
            // opened stayed "current" for the rest of the run.
            if count == 0 {
                listModel.currentSessionId = nil
            }
        }
        // 冷启动直达：通知被点击时若是**启动**了 App，那次点击发生在
        // `MainView` 存在之前（`didReceive` 早于视图构建，连接与列表都还没有）。
        // 请求被 `SessionRouter` 存着，这里在视图真正就位后取走并等待列表到达。
        //
        // **只有一个消费者**（015）：以前这里还有一条 `.onChange(of:
        // alerts.requestedSessionId)`，与这条 `.task(id:)` 各自处理同一个请求；
        // 会话还没进列表时两者会同时攥着它，谁先等到列表谁先入栈，另一个随后
        // 又入栈一次——用户就得返回两次。触发源收敛成 `routingToken` 一处，
        // 而取走本身是原子的（`SessionRouter.take()`），所以多一个触发点也不会
        // 变成第二个消费者。
        .task(id: SessionRouter.shared.routingToken) {
            await openRequestedSession()
        }
        .task {
            // 015：仿真器复现「App 被通知**冷启动**」（`-DSHProbeNotifyColdTap <sid>`）。
            // 与 `-DSHProbeNotifyTap` 的差别是时序：这里由 `MainView` 出现来触发第二条来源
            // （`handleTap`），此刻 host 的列表通常还没到，目标会话因此不在列表里——
            // 两条来源同时存在 + 目标会话尚未进列表，正是"两个消费者各攥着同一个请求"的窗口，
            // 也就是真机冷启动点通知的形态。DEBUG-only，见 `ViewportProbe.runNotifyColdTapProbe`。
            await ViewportProbe.runNotifyColdTapProbe(
                delegate: alerts,
                isListed: { listModel.session(withId: $0) != nil }
            )
        }
        .task(id: automationFile) {
            guard let automationFile, !didOpenAutomationFile else { return }
            didOpenAutomationFile = true
            // The browser resolves its scope from a session, so the same wait
            // the files screen does applies here.
            for _ in 0..<80 where listModel.groups.isEmpty && listModel.loose.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            // A named session wins, exactly as it does for `-DSHOpenScreen files`:
            // the file lives in *that* workspace, and taking the first row of the
            // list pointed the browser at an unrelated directory — which is how a
            // run that had pinned its session still got 「这个路径不在了」.
            let session = automationSessionId.flatMap { listModel.session(withId: $0) }
                ?? listModel.groups.first?.sessions.first
                ?? listModel.loose.first
            guard let session else { return }
            filesOpenPath = automationFile
            filesScope = WorkspaceFileScope(summary: session, hostHome: store.hostHome)
        }
        .task(id: automationScreen) {
            guard let screen = automationScreen, !didApplyAutomationScreen else { return }
            didApplyAutomationScreen = true
            switch screen {
            case "settings": isShowingSettings = true
            case "connections": isShowingConnections = true
            case "web": isShowingWebFallback = true
            case "diagnostics":
                // A one-screen inventory of what this device actually has, for
                // the questions a screenshot cannot answer — which fonts exist,
                // for instance, when text renders as boxes.
                isShowingDiagnostics = true
            case "feedback":
                // 收件箱的自动化入口：列表页出现后自己把 sheet 拉起来。
                break
            case "files":
                // The file browser needs a session to resolve its workspace, and
                // picking the first one before the list has arrived leaves this
                // page silently unopened. Waiting here rather than sleeping a
                // fixed moment is what makes the screen reachable at all.
                await openFilesWhenTheListArrives()
            default: break
            }
        }
    }

    private var bodyStageOne: some View {
        Group {
            if let automationSessionId, let summary = listModel.session(withId: automationSessionId) {
                // In compact width a split view can only show one column, and
                // the sidebar column wins. An unattended run therefore presents
                // the transcript directly rather than trying to steer the split
                // view's column visibility.
                NavigationStack {
                    chat(for: summary)
                }
                .task(id: automationSessionId) {
                    await chatModel.open(summary)
                }
            } else {
                splitView
            }
        }
        .sheet(isPresented: $isShowingConnections) {
            NavigationStack {
                ConnectionView(onPairingChanged: { await APNSRegistrar.shared.pairingChanged() })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isShowingConnections = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheet(store: connectionEnv)
        }
        .sheet(item: $filesScope) { scope in
            WorkspaceFilesView(
                store: connectionEnv,
                scope: scope,
                openPath: $filesOpenPath,
                initialPath: automationFilesDir ?? ""
            )
        }
        #if DEBUG
        .sheet(isPresented: $isShowingDiagnostics) {
            ScrollView {
                Text(AutomationDiagnostics.report())
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        #endif
        .sheet(isPresented: $isShowingWebFallback) {
            // The fallback resolves its own surface from the active connection
            // and explains itself when a relay link cannot serve one.
            PluginWebFallback(store: connectionEnv)
        }
        // 设置页清了缓存：内存里的转写尾部与图片桶一起放手（否则会被写回来）。
        .onReceive(NotificationCenter.default.publisher(for: .localCachesCleared)) { _ in
            chatModel.dropPersistedTail()
            attachmentImages.clearAllCached()
            // 反馈镜像与已读标记一起清；Keychain 里的取件凭据**保留**，记录下次会重新拉回来。
            // （原在设置页里直接调，025 阶段4 设置单元进模块后改由装配层做——
            //  `*UI → DSHFeedbackDomain` 是禁止的依赖边。）
            FeedbackCenter.shared.clearLocalMirror()
        }
        .onChange(of: listModel.finishedSignal) {
            guard let finished = listModel.lastFinished else { return }
            // Silent for the session already on screen — but only while the app
            // is actually in front. Backgrounded, "on screen" means nothing: the
            // user put the phone down and is waiting to be told.
            if scenePhase == .active, chatModel.session?.sessionId == finished.sessionId { return }
            alerts.turnFinished(
                sessionId: finished.sessionId,
                title: finished.displayTitle
            )
        }
    }


    /// Presents the file browser for the first session, once there is one.
    ///
    /// Up to 20 seconds: an unattended run opens this page straight after
    /// launch, when the session list is still being fetched.
    private func openFilesWhenTheListArrives() async {
        for _ in 0..<80 {
            // A named session wins: with two sessions in one directory the
            // first one in the list is not necessarily the workspace the run
            // means to photograph.
            if let wanted = automationSessionId, let named = listModel.session(withId: wanted) {
                filesScope = WorkspaceFileScope(summary: named, hostHome: store.hostHome)
                return
            }
            if let session = listModel.groups.first?.sessions.first ?? listModel.loose.first {
                filesScope = WorkspaceFileScope(summary: session, hostHome: store.hostHome)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Opens the session a notification tap asked for, once there is one to open.
    ///
    /// **取走即拥有**（015）：一进来就把请求取走，第二个调用者拿不到任何东西，
    /// 所以同一次点按只可能走到入栈一次。等待仍然是必要的——冷启动点通知会早于列表
    /// 到达，"第一眼找不到"是"还没到"，不是"没有这个会话"——但等待期间只有一个等待者，
    /// 且入栈发生在"等到会话"的那一刻**同步**完成，慢 I/O（`chatModel.open`）排在入栈
    /// 之后。所有权与入栈之间因此没有可被用户返回动作清空的窗口。
    ///
    /// 20 秒仍没等到就放弃：请求不再有意义（会话可能已被归档或删除），
    /// 也不该在第 21 秒把用户拽进任何会话。
    private func openRequestedSession() async {
        guard let request = SessionRouter.shared.take() else { return }
        guard let summary = await awaitListed(request.sessionId) else {
            DSHLog.push("notification session \(request.sessionId) never appeared in the list")
            return
        }
        DSHLog.push("opening session \(request.sessionId) from a notification")
        commitRoute(request.sessionId)
        ViewportProbe.note("route.open", [
            "sid": request.sessionId,
            "generation": "\(request.generation)",
        ], force: true)
        await chatModel.open(summary)
        listModel.markViewed(request.sessionId)
        AccountStateSync.shared.sessionViewed()
    }

    /// Waits for `sessionId` to appear in the list, up to the 20-second budget
    /// the automation surfaces use for the same reason.
    ///
    /// `nil` means "gave up" — either the budget ran out, or the task was
    /// cancelled because a newer request arrived (the newest tap wins).
    private func awaitListed(_ sessionId: String) async -> SessionSummary? {
        for _ in 0..<80 {
            if let summary = listModel.session(withId: sessionId) { return summary }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// Pushes `sessionId` onto the stack — synchronously, and only on a phone.
    ///
    /// Reading `paths.last` is what makes this idempotent, and it covers every
    /// way a session can already be on top (a row tap, a created session, an
    /// earlier notification).
    private func commitRoute(_ sessionId: String) {
        guard horizontalSizeClass == .compact, paths.last != sessionId else { return }
        paths.append(sessionId)
        ViewportProbe.note("route.push", [
            "sid": sessionId,
            "stack": "\(paths.count)",
        ], force: true)
    }

    @ViewBuilder
    private func sessionDestination(_ sessionId: String) -> some View {
        if let summary = listModel.session(withId: sessionId) {
            chat(for: summary)
                // A view per session: the composer keeps per-view state (mention
                // suggestions, a picked photo, the unsupported-file notice), and
                // SwiftUI reuses the same instance for a different id unless told
                // not to — which is how those leaked across a switch too.
                .id(sessionId)
                .task(id: sessionId) {
                    await chatModel.open(summary)
                    // Opening is what "viewed" means: the row's marker clears
                    // here and nowhere else, so scrolling past does not count.
                    listModel.markViewed(sessionId)
                    AccountStateSync.shared.sessionViewed()
                }
        } else {
            SessionDetailView(model: chatModel)
        }
    }

    /// Opens a session the app just created.
    ///
    /// Creating one and leaving the user on the list was the defect: the new
    /// session is blank, so its row says nothing and there is nothing to see —
    /// the desktop behaves the other way round, where a new session *becomes*
    /// the selection. Pushing it onto the navigation path is what "makes" the
    /// session on a phone.
    private func openCreatedSession(_ sessionId: String) {
        guard let summary = listModel.session(withId: sessionId) else { return }
        Task { await chatModel.open(summary) }
        listModel.markViewed(sessionId)
        AccountStateSync.shared.sessionViewed()
        paths.append(sessionId)
    }

    /// The transcript for one session, with its toolbar surfaces attached.
    /// Notifies once for each session that starts waiting on the user.
    private func announceNewPending(_ ids: [String]) {
        for id in ids where !announcedPending.contains(id) {
            announcedPending.insert(id)
            guard let item = hub.pending.first(where: { $0.id == id }) else { continue }
            guard listModel.isFormalSession(item.sessionId) else { continue }
            // Already looking at it: a banner would only be in the way — unless
            // the app is in the background, where "looking at it" cannot be true.
            if scenePhase == .active, chatModel.session?.sessionId == item.sessionId { continue }
            let summary = listModel.session(withId: item.sessionId)
            alerts.needsAttention(
                sessionId: item.sessionId,
                title: summary?.displayTitle ?? item.sessionId,
                detail: item.title
            )
        }
    }

    private func chat(for summary: SessionSummary) -> some View {
        ChatView(
            model: chatModel,
            onOpenFiles: { filesScope = WorkspaceFileScope(summary: $0, hostHome: store.hostHome) },
            onOpenWeb: { _ in isShowingWebFallback = true },
            // 018：面板与 subagent 卡的「打开子会话」压入同一个导航栈。
            onOpenSession: { paths.append($0) },
            sessionId: summary.sessionId
        )
    }

    private var splitView: some View {
        splitRoot
    }

    /// A phone gets a stack, a wider screen gets the split view.
    ///
    /// The stack is what makes "open the session I just created" possible: a
    /// `NavigationSplitView` has no path to drive, and on a phone it shows the
    /// sidebar anyway, so a newly created session had nowhere to appear.
    /// Publishes the list's own counts for an unattended run to read.
    ///
    /// There is no other way to see what the app thinks it has: the archived
    /// section is invisible when its set is empty, and "invisible" is exactly
    /// what a debugging run needs to tell apart from "not loaded".
    private func publishDiagnostics() {
        #if DEBUG
        AutomationDiagnostics.facts = [
            "会话总数: \(listModel.allSessions.count)",
            "归档集合: \(listModel.archivedSessions.count)",
            "未分组: \(listModel.loose.count)",
            "工作区: \(listModel.workspaces.count)",
            // The view's own condition for showing the archived section. Stated
            // as a fact because "the section is empty" and "the data never
            // arrived" look identical from outside — and did, for an hour.
            "已归档区可显示: \(listModel.archivedSessions.isEmpty ? "否" : "是")",
        ]
        #endif
    }

    @ViewBuilder
    private var splitRoot: some View {
        layout.task(id: listModel.allSessions.count) { publishDiagnostics() }
    }

    @ViewBuilder
    private var layout: some View {
        if horizontalSizeClass == .compact {
            NavigationStack(path: $paths) {
                sidebar
                    .navigationDestination(for: String.self, destination: sessionDestination)
            }
        } else {
            NavigationSplitView {
                sidebar
                    .navigationDestination(for: String.self, destination: sessionDestination)
            } detail: {
                SessionDetailView(model: chatModel)
            }
        }
    }

    private var sidebar: some View {
        SessionListView(
            model: listModel,
            onOpenConnections: { isShowingConnections = true },
            onOpenSettings: { isShowingSettings = true },
            onOpenSession: openCreatedSession,
            openFeedbackOnAppear: automationScreen == "feedback"
        )
    }
}

/// Hosts one session transcript in the detail column before a session is chosen.

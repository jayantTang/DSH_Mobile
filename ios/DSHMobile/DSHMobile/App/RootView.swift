import DSHKit
import SwiftUI
import UIKit

/// The application root: owns the long-lived stores and routes between
/// onboarding and the main workspace.
struct RootView: View {
    @State private var store = ConnectionStore()
    @State private var hub = HostEventHub()
    @State private var updates = UpdateChecker()
    @State private var alerts = SessionAlerts()
    @State private var attachmentImages = AttachmentImages()
    @State private var viewLog = SessionViewLog()
    @State private var listModel = SessionListModel()
    @State private var chatModel = ChatModel()
    /// Holds the app awake in the background while there is work to report on.
    @State private var keepAlive = RunKeepAlive()

    @Environment(\.scenePhase) private var scenePhase
    @State private var lastConnected = false
    /// Once the workspace has been reached, a dropped link reconnects *inside*
    /// it. Falling back to the pairing screen made every trip to the background
    /// look like the connection had been lost for good.
    @State private var enteredWorkspace = false
    @State private var connectionError: String?

    var body: some View {
        content
            .environment(store)
            .environment(hub)
            .environment(updates)
            .environment(alerts)
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
            }
            .task {
                listModel.attach(to: store, hub: hub, viewLog: viewLog)
                attachmentImages.attach(store: store)
                chatModel.attach(store: store, hub: hub)
                // The feed asks for the client each time it reopens, so a repair
                // that swapped the carrier underneath is picked up by itself.
                hub.attach { [store] in store.client }

                // Automation hook first: a scripted run passes the target
                // explicitly and must not fall back to a remembered profile.
                if let link = Self.automationLink() {
                    if let failure = await store.connect(link: link) {
                        connectionError = failure
                    }
                    return
                }

                // Reconnect silently on launch so opening the app lands on the
                // session list rather than the pairing screen.
                //
                // A screenshot run that wants the pairing screen asks for it
                // instead of deleting a stored credential to get there.
                guard !Self.automationShowsOnboarding() else { return }
                forgetDirectProfilesIfAsked()
                await connectToBestAvailableProfile()
            }
            .task {
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
            .onChange(of: scenePhase) { _, phase in
                // Re-checked on every return to the foreground: that is when a
                // user who just installed an update comes back to look.
                if phase == .active { Task { await updates.refresh() } }
                if phase == .active, store.state.isConnected {
                    // The feed is left running while backgrounded — that is what
                    // makes a notification possible at all — so coming back only
                    // has to make the rows fresh again.
                    hub.startIfNeeded(client: store.client)
                    Task { await listModel.refresh() }
                } else if phase == .active {
                    // Sockets do not survive suspension; put the link back.
                    Task { await store.reconnectIfNeeded() }
                }
                // Background: keep the app alive while there is something to be
                // told about. See `RunKeepAlive`.
                keepAlive.sync(
                    isBackground: phase == .background,
                    hasWorkInFlight: listModel.runningCount > 0 || !hub.pending.isEmpty
                )
            }
            .onChange(of: hub.isLive) { _, live in
                // The feed is back after a drop: whatever happened while it was
                // away is only visible in a fresh list, and a run that ended in
                // that window still owes the user a notification.
                guard live else { return }
                Task { await listModel.refresh() }
            }
            .onChange(of: listModel.runningCount) { _, running in
                keepAlive.sync(
                    isBackground: scenePhase == .background,
                    hasWorkInFlight: running > 0 || !hub.pending.isEmpty
                )
            }
            .onChange(of: hub.hostHome) { _, home in
                if let home { store.hostHome = home }
            }
            .onOpenURL { url in
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
            ConnectionView()
        }
    }

    /// The profile to reconnect to on launch: most recently used, and only if
    /// its credential is still present.
    /// Connects to the first saved host that answers.
    ///
    /// Most recent first, then the rest. A direct profile that works on the
    /// network the computer sits on is useless anywhere else, and a user who
    /// leaves the house should not have to switch connections by hand when the
    /// relay they already paired is saved right beside it.
    private func connectToBestAvailableProfile() async {
        let ordered = store.profiles
            .filter { store.hasSecret(for: $0) }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        for profile in ordered {
            await store.connect(to: profile)
            if store.state.isConnected { return }
        }
    }

    /// Drops a saved DEBUG direct pairing when a run asks for the product path.
    ///
    /// `dsh://direct` is a test channel, but a profile saved by an earlier test
    /// run survives in the simulator and wins the reconnect race, so every later
    /// screenshot shows a transport the product does not offer.
    private func forgetDirectProfilesIfAsked() {
        guard CommandLine.arguments.contains("-DSHForgetDirect") else { return }
        for profile in store.profiles {
            if case .direct = profile.transport { store.removeProfile(profile) }
        }
    }

    private var preferredProfile: ConnectionProfile? {
        store.profiles
            .filter { store.hasSecret(for: $0) }
            .max { ($0.lastConnectedAt ?? .distantPast) < ($1.lastConnectedAt ?? .distantPast) }
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
    #else
    static func automationDraftImage() -> String? { nil }
    static func automationUploadFile() -> String? { nil }
    #endif

    #if DEBUG
    /// Reads a connection link passed on the command line.
    ///
    /// This exists so `scripts/dev/verify-simulator.sh` can exercise a real
    /// end-to-end run unattended: iOS raises a confirmation dialog for
    /// `simctl openurl` on a custom scheme, and that dialog cannot be dismissed
    /// from the command line. Debug-only, so a shipping build has no such path.
    static func automationLink() -> ConnectLink? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHConnectURL"),
              index + 1 < arguments.count,
              let url = URL(string: arguments[index + 1])
        else { return nil }
        return ConnectLink(url: url)
    }

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

    /// Keeps the app on the pairing screen instead of reconnecting on launch.
    ///
    /// Deleting the stored pairing to photograph the connection page would leave
    /// the simulator needing a fresh code for every later run; a flag costs
    /// nothing and touches no credential.
    static func automationShowsOnboarding() -> Bool {
        CommandLine.arguments.contains("-DSHOnboarding")
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
    static func automationLink() -> ConnectLink? { nil }
    static func automationSessionId() -> String? { nil }
    static func automationScreen() -> String? { nil }
    static func automationFile() -> String? { nil }
    static func automationFilesDir() -> String? { nil }
    static func automationShowsOnboarding() -> Bool { false }
    static func automationDropLinkAfter() -> Double? { nil }
    #endif

    private func syncConnectionState(_ isConnected: Bool) {
        guard isConnected != lastConnected else { return }
        lastConnected = isConnected
        if isConnected {
            enteredWorkspace = true
            hub.startIfNeeded(client: store.client)
            Task { await listModel.start() }
            // Whatever was on screen when the link went away is stale by the
            // time it comes back: re-open the transcript so a blip cannot leave
            // a frozen conversation that looks live.
            Task { await chatModel.reopenAfterReconnect() }
        } else if store.activeProfile == nil {
            // A deliberate switch or disconnect: the old host's data must go.
            hub.stop()
            listModel.stop()
            chatModel.close()
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
private struct MainView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(HostEventHub.self) private var hub
    @Environment(SessionAlerts.self) private var alerts
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
    @State private var paths = NavigationPath()
    @State private var isShowingDiagnostics = false
    @State private var filesScope: WorkspaceFileScope?
    /// A file to open as soon as the browser appears, for the unattended run.
    @State private var filesOpenPath: String?
    @State private var didApplyAutomationScreen = false
    @State private var didOpenAutomationFile = false
    /// Waterfalls already announced, so a re-render cannot repeat an alert.
    @State private var announcedPending: Set<String> = []

    var body: some View {
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
                ConnectionView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isShowingConnections = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheet(store: store)
        }
        .sheet(item: $filesScope) { scope in
            WorkspaceFilesView(
                store: store,
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
            PluginWebFallback(store: store)
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
            if count == 0 { listModel.currentSessionId = nil }
        }
        .onChange(of: alerts.requestedSessionId) { _, requested in
            // The split view owns navigation, so a tapped notification opens
            // its session by handing it to the transcript the detail column
            // already shows.
            guard let requested, let summary = listModel.session(withId: requested) else { return }
            Task { await chatModel.open(summary) }
            alerts.requestedSessionId = nil
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
        paths.append(sessionId)
    }

    /// The transcript for one session, with its toolbar surfaces attached.
    /// Notifies once for each session that starts waiting on the user.
    private func announceNewPending(_ ids: [String]) {
        for id in ids where !announcedPending.contains(id) {
            announcedPending.insert(id)
            guard let item = hub.pending.first(where: { $0.id == id }) else { continue }
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
            onOpenWeb: { _ in isShowingWebFallback = true }
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
            onOpenSession: openCreatedSession
        )
    }
}

/// Hosts one session transcript in the detail column before a session is chosen.
private struct SessionDetailView: View {
    @Bindable var model: ChatModel

    var body: some View {
        Group {
            if model.session != nil {
                ChatView(model: model)
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
    func startIfNeeded(client: DSHClient?) {
        guard let client, !isLive else { return }
        start(client: client)
    }
}

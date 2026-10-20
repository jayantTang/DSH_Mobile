import DSHConnectionAPI
import DSHCore
import DSHFoundation
import DSHKit
import Foundation
import Observation

/// Loads and groups the session list.
///
/// The desktop client's sidebar is a workspace tree; the phone reproduces that
/// grouping but keeps it flat enough to scan on a narrow screen: one section
/// per working directory, with subagent transcripts nested under the session
/// that spawned them.
@MainActor
@Observable
public final class SessionListModel {
    /// `snapshotStore` 仅测试注入临时目录；生产默认与原来一致，行为不变。
    public init(snapshotStore: SessionListSnapshotStore = SessionListSnapshotStore()) {
        self.snapshotStore = snapshotStore
    }
    /// App 注入的探针钩子（025）。
    public var probeNote: ((String, [String: String], Bool) -> Void)? = nil

    /// 018：活动名单适配层（应用级单例，由装配层注入）。列表每次从 host 拿到
    /// 会话行就喂一次；行状态与右侧计数的判定全部在 DSHKit 的 `ActivityStore`。
    public weak var activityModel: ActivityModel?

    /// One working-directory group.
    ///
    /// 形状已下沉到 DSHKit（`SessionGrouping.Group`，spec 023 的 S3c）：这里只留一个 typealias，
    /// 视图侧的名字与用法一字不变。
    public typealias Group = SessionGrouping.Group

    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// One workspace together with the sessions still live in it.
    ///
    /// The new-session sheet offers these as "start another conversation here".
    /// It deliberately does not carry the workspace's full `sessionIds`: that
    /// list is history — archived sessions, sessions never used, sessions from
    /// months ago — and labelling a group with the number of conversations it
    /// has ever held is how "48 个会话" ends up over three rows.
    public struct LiveWorkspace: Identifiable {
        public let id: String
        public let path: String
        public let title: String
        public let sessions: [SessionSummary]

        /// 真在跑的：等用户回应的那些 host 也报 running，不能算进来。
        /// 两个计数由 model 在建组时算好（只有它知道 hub 的待答集合）。
        public var runningCount: Int = 0
        public var waitingCount: Int = 0
        public var latestActivity: Double { sessions.map(\.updatedAt).max() ?? 0 }
        public init(id: String, path: String, title: String, sessions: [SessionSummary], runningCount: Int = 0, waitingCount: Int = 0) {
            self.id = id
            self.path = path
            self.title = title
            self.sessions = sessions
            self.runningCount = runningCount
            self.waitingCount = waitingCount
        }
    }

    public private(set) var phase: Phase = .idle

    /// 上一次成功刷新落盘的快照（冷启动先拿它把行画出来，再和 host 对账）。
    private let snapshotStore: SessionListSnapshotStore

    /// 屏幕上这些行是"上次的数据"还是"刚问来的"。
    ///
    /// 有它才能在离线时把话说明白：列表能看，但后面跟一句"显示的是上次的数据"，
    /// 而不是让用户以为这就是现在的状态。
    public private(set) var isShowingSnapshot = false

    /// 上一次写盘的快照内容指纹（内容没变就不重写）。
    /// 指纹按 scope 分开记（028 缺陷6）：单值记在换电脑时会压住新电脑的第一份快照——
    /// 它的内容恰好与旧电脑一样时，用户看到的是「没有缓存」而不是「上次的缓存」。
    private var lastSavedFingerprint: [String: Int] = [:]
    public private(set) var groups: [Group] = []
    /// The desktop client's explicit workspace list, in its own order.
    public private(set) var workspaces: [Workspace] = []

    /// Set when archiving failed, so the swipe can say why instead of looking
    /// like nothing happened.
    public var archiveError: String?

    /// The session the app just created.
    ///
    /// A brand-new session has no title, so its row looks like every other
    /// untitled one — marking it is how the user (and a test) can tell which
    /// row is the one they just made.
    public private(set) var lastCreatedSessionId: String?

    /// 新建会话的本地占位：宿主对空白会话的可见性由它决定，列表不能等它。
    /// 只在进程内有效，不落盘（重启后宿主没列就不该凭空出现）。
    public enum PendingState: String, Sendable, Equatable {
        /// 刚创建，宿主的列表还没出现它。
        case syncing
        /// 超过等待窗口仍未出现：仍然可打开，但如实标记未同步。
        case unsynced
    }

    public struct PendingSession: Sendable, Equatable, Identifiable {
        public let id: String
        public let directory: String
        public let createdAt: Date
        public var state: PendingState
        /// 宿主标题事件带来的标题；有它就不再显示目录占位名。
        public var title: String?
    }

    public private(set) var pendingCreated: [String: PendingSession] = [:]

    /// 宿主确认窗口：超过它仍不列出就标 unsynced。
    public static let pendingSyncWindow: TimeInterval = 10

    /// 测试可替换的时钟。
    var now: () -> Date = { Date() }

    public func pendingState(for id: String) -> PendingState? {
        pendingCreated[id]?.state
    }

    /// 宿主标题事件：写到对应占位，并清掉“未同步”（宿主已经认识它）。
    public func noteSessionTitle(id: String, title: String) {
        guard var pending = pendingCreated[id], !title.isEmpty else { return }
        pending.title = title
        pending.state = .syncing
        pendingCreated[id] = pending
        regroup()
    }

    public func pendingTitle(for id: String) -> String? {
        pendingCreated[id]?.title
    }

    /// The session the app currently has open, when it has one.
    ///
    /// The desktop sidebar shows a session that has never run a turn only while
    /// it is the selected one — it is that workspace's provisional "new session"
    /// row, not history. Reproducing that rule needs the phone to know which row
    /// is the open one.
    public var currentSessionId: String? {
        didSet { if currentSessionId != oldValue { regroup() } }
    }

    /// Sessions taken out of the workspace surfaces, newest first.
    ///
    /// Archiving hides a session from the grouping surfaces; it does not delete
    /// it, and the host still lists it. Keeping them reachable is what makes the
    /// action safe on a phone — hiding them for good is how a tidy-up turns into
    /// a loss.
    ///
    /// Empty sessions are the one thing left out, for the same reason they are
    /// left out above: there is nothing in them to find. The host's archived set
    /// also collects ids of sessions that were never used, and listing those
    /// would put the grey row back on screen one section further down.
    public var archivedSessions: [SessionSummary] {
        allSessions
            .filter { archivedSessionIds.contains($0.sessionId) && showsInList($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A path as the desktop client would show it.
    public func displayPath(_ path: String) -> String {
        PathFormat.short(path, home: store?.hostHome)
    }

    /// Sessions the host is blocked on: a question or an approval is waiting for
    /// the user. Filled from `HostEventHub.pending` by the list view — the host's
    /// session summary does **not** say this (`running` stays true while a
    /// question waits, measured 2026-09-21), so the waterfall event is the only
    /// source.
    public var waitingSessionIds: Set<String> = []

    /// Records every session the list is seeing for the first time as viewed.
    ///
    /// Without this, "unseen" would mean "never opened on this phone", and the
    /// first refresh after pairing — where every session finished days ago on
    /// the computer — would mark the entire list. First sight means "nothing has
    /// happened since I could have known", which is exactly the baseline the
    /// marker needs.
    private func seedFirstSightings() {
        guard let viewLog else { return }
        // Everything the host listed — grouped, loose or archived — gets a
        // baseline, because all of it is visible somewhere in this screen.
        for session in allSessions where viewLog.lastViewed(session.sessionId) == nil {
            viewLog.markViewed(session.sessionId, at: session.updatedAt)
        }
        viewLog.prune(keeping: Set(allSessions.map(\.sessionId)))
    }

    /// Raised when a session goes from running to idle.
    ///
    /// The chat stream only reports turns for the session on screen, so the way
    /// to know that *any* session finished is the host's own `running` flag,
    /// which this list already refreshes.
    public private(set) var finishedSignal = 0
    public private(set) var lastFinished: SessionSummary?

    /// Sessions the host reported as running on the previous refresh.
    private var previouslyRunning: Set<String> = []

    /// True when the workspace list could not be read and the list is falling
    /// back to grouping by directory.
    ///
    /// Surfaced in the UI on purpose: a silent fallback looks exactly like
    /// correct behaviour while showing the wrong grouping, which is how a stale
    /// install and a failed fetch became indistinguishable.
    public private(set) var isUsingFallbackGrouping = false

    /// Sessions the user has archived on the desktop; kept out of the list.
    private var archivedSessionIds: Set<String> = []

    /// Sessions with no workspace, plus subagents whose parent is not visible.
    ///
    /// These are reference material rather than things the user is working on,
    /// so the list keeps them behind one collapsed disclosure instead of
    /// interleaving them with live work.
    public private(set) var loose: [SessionSummary] = []
    public private(set) var lastRefreshed: Date?

    public var searchText: String = "" {
        didSet { if searchText != oldValue { regroup() } }
    }

    /// Every session the list knows about, grouped or not. Read by the
    /// new-session sheet, which offers the directories they run in.
    public private(set) var allSessions: [SessionSummary] = []

    private var eventTask: Task<Void, Never>?
    private var refreshDebounce: Task<Void, Never>?
    private(set) weak var store: (any LinkService)?
    private weak var hub: HostEventHub?

    // MARK: 冷启动 009 叠加（T010/T011；逻辑在 SessionListModel+ColdStart.swift）

    /// 009 消息层（磁盘层聚合数据 + 预取瀑布）；nil 时整套叠加缺位，回退现有行为。
    weak var messageLayer: MessageLayer?
    /// 这台电脑本轮启动有没有排过预取瀑布（只排一次）。
    public var lastPrefetchScope: String?

    /// Whether a session is still worth continuing.
    ///
    /// "Live" is the phone's own word, and it has to be defined from what the
    /// host actually says, because the wire has no "this session is over" flag.
    /// Two signals are available and both are used: the host's archived set,
    /// and `blank` — a session with no turn in it, which the host keeps for
    /// every "new session" that was opened and never used. Everything else is
    /// live, whether or not it is running right now: "not running" is the state
    /// of every session between turns, and treating that as dead would empty
    /// this list.
    private func isLive(_ session: SessionSummary) -> Bool {
        !archivedSessionIds.contains(session.sessionId) && !session.blank && !session.isSubagent
    }

    /// Workspaces that still hold a live session, live ones first.
    ///
    /// Derived from the host's workspace list rather than from directories, so
    /// it matches the desktop sidebar; workspaces whose sessions are all
    /// archived or blank disappear instead of being offered as an empty room.
    public var liveWorkspaces: [LiveWorkspace] {
        var live: [String: SessionSummary] = [:]
        for session in allSessions where isLive(session) {
            live[session.sessionId] = session
        }
        let built = workspaces.compactMap { workspace -> LiveWorkspace? in
            let members = workspace.sessionIds.compactMap { live[$0] }
            guard !members.isEmpty else { return nil }
            return LiveWorkspace(
                id: workspace.workspaceId,
                path: workspace.path,
                title: workspace.title,
                sessions: orderSessions(members),
                runningCount: members.filter { isReallyRunning($0) }.count,
                waitingCount: members.filter { waitingSessionIds.contains($0.sessionId) }.count
            )
        }
        return SessionListOrder.groups(
            built,
            isRunning: { $0.runningCount > 0 || $0.waitingCount > 0 },
            activity: \.latestActivity
        )
    }

    /// Sessions currently executing a turn among the ones on screen.
    ///
    /// Counting every session in the host's registry made the badge disagree
    /// with what the user could see: sessions in the folded ungrouped bucket
    /// were counted but not visible.
    public var runningCount: Int {
        groups.reduce(0) { $0 + $1.sessions.filter { isReallyRunning($0) }.count }
    }

    /// Sessions blocked on the user, among the ones on screen.
    public var waitingCount: Int {
        groups.reduce(0) { $0 + $1.sessions.filter { waitingSessionIds.contains($0.sessionId) }.count }
    }

    /// Running, and not one of the ones actually waiting for an answer.
    ///
    /// The host keeps `running` true while a question waits, so counting them
    /// together made the badge claim "3 运行中" when two of the three were
    /// sitting there waiting for the user.
    public func isReallyRunning(_ session: SessionSummary) -> Bool {
        session.running && !waitingSessionIds.contains(session.sessionId)
    }

    /// Running sessions that live in the folded ungrouped bucket.
    ///
    /// Surfaced separately rather than silently folded away, so the badge can
    /// stay honest without making the ungrouped bucket look empty.
    public var ungroupedRunningCount: Int {
        loose.filter { isReallyRunning($0) }.count
    }

    public var ungroupedWaitingCount: Int {
        loose.filter { waitingSessionIds.contains($0.sessionId) }.count
    }

    public var isEmpty: Bool {
        groups.isEmpty && loose.isEmpty
    }

    /// Whether a search is currently narrowing the list.
    public var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Looks up one session by id, for navigation destinations.
    public func session(withId id: String) -> SessionSummary? {
        if let match = allSessions.first(where: { $0.sessionId == id }) { return match }
        if let pending = pendingCreated[id] { return Self.placeholder(from: pending) }
        if let match = loose.first(where: { $0.sessionId == id }) { return match }
        for group in groups {
            if let match = group.sessions.first(where: { $0.sessionId == id }) { return match }
            for children in group.children.values {
                if let match = children.first(where: { $0.sessionId == id }) { return match }
            }
        }
        return nil
    }

    // MARK: - Lifecycle

    public func attach(to store: any LinkService, hub: HostEventHub, viewLog: SessionViewLog? = nil,
                messageLayer: MessageLayer? = nil) {
        self.store = store
        self.hub = hub
        self.messageLayer = messageLayer
        if let viewLog { self.viewLog = viewLog }
    }

    /// When each session was last opened on this phone.
    ///
    /// Injected rather than created here so the same log is shared with the
    /// screen that opens sessions — that write is what clears an unseen row.
    public var viewLog: SessionViewLog?

    /// What the leading dot should say for this row.
    public func state(of session: SessionSummary) -> SessionRowState {
        SessionRowState.of(
            waiting: waitingSessionIds.contains(session.sessionId),
            running: session.running,
            blank: session.blank,
            updatedAt: session.updatedAt,
            lastViewedAt: viewLog?.lastViewed(session.sessionId)
        )
    }

    /// Records that this session is on screen now.
    ///
    /// Routed through the model because the model owns the log: the screen that
    /// opens a session has no business knowing where "viewed" is stored.
    public func markViewed(_ sessionId: String) {
        viewLog?.markViewed(sessionId)
    }

    /// The row's state, as the accessibility tree should name it.
    ///
    /// Tests assert on this rather than on a colour: a dot's hue is not
    /// something a run can read, and "looks blue" is not a verdict.
    public func stateIdentifier(of session: SessionSummary) -> String {
        "session.state.\(state(of: session).rawValue)"
    }

    /// Loads the list, then keeps it fresh from the host event stream.
    public func start() async {
        await refresh()
        subscribeToHostEvents()
    }

    /// Files a session away, or puts it back.
    ///
    /// The host returns the whole archived set, so the list can be corrected
    /// immediately — a row that stays on screen until the next refresh reads as
    /// a failed swipe, which is how the first attempt at this felt.
    ///
    /// `archived: false` is accepted and ignored by this DSH version: the set is
    /// one-way. The parameter is still sent, so a host that does support it
    /// starts working without a client change.
    @discardableResult
    public func setArchived(_ archived: Bool, sessionId: String) async -> Bool {
        // 028 缺陷4：未连接时也必须给出用户可见的原因——静默返回 false 会让
        // 右滑手势看起来「没反应」（视图只在有文案时弹提示）。
        guard let link = store?.link, link.isConnected else {
            archiveError = String(localized: "尚未连接")
            return false
        }
        do {
            let ids = try await link.archiveSession(sessionId, archived: archived)
            archivedSessionIds = Set(ids)
            regroup()
            return true
        } catch {
            archiveError = error.localizedDescription
            return false
        }
    }

    /// Starts a session in a project directory and returns its id.
    ///
    /// The directory is resolved to a workspace *before* the session exists,
    /// because that is the only thing that files it: `session/create` files a
    /// session when the request names a `workspaceId`, and a session created
    /// with a bare `cwd` belongs to no workspace at all — which is what put
    /// sessions started from the phone under "未分组" while the desktop showed
    /// the same session as ungrouped too.
    ///
    /// `workspace/create` is resolve-or-register, so a directory that is
    /// already a workspace (including one the host knows under a canonicalized
    /// path) comes back as itself instead of a duplicate.
    public func startSession(directory: String) async throws -> String {
        guard let link = store?.link, link.isConnected else { throw SessionListError.notConnected }
        let registration = try await link.createWorkspace(path: directory)

        let id: String
        do {
            let value = try await link.createSession(
                SessionCreateRequest(workspaceId: registration.workspace.workspaceId)
            )
            guard let created = value["sessionId"]?.stringValue else { throw SessionListError.noSessionId }
            id = created
        } catch {
            // A registration this call created would otherwise outlive the
            // failure as an empty group in the desktop sidebar. One the host
            // already had is none of this call's business.
            if registration.created {
                try? await link.deleteWorkspace(id: registration.workspace.workspaceId)
            }
            throw error
        }

        // The new session must be in the list before it can be opened: the
        // caller looks it up by id to build the chat screen. A blank session is
        // invisible to the desktop client until it is current, and the host can
        // take a moment to list it, so this waits rather than guessing.
        // 宿主对空白会话的可见性由它自己决定：客户端不能等它把行吐出来。
        // 先落一行本地占位，用户立刻能看到、能打开；后台刷一次，宿主要是
        // 列出了同 id，reconcilePending() 会把它换成宿主行。
        lastCreatedSessionId = id
        pendingCreated[id] = PendingSession(id: id, directory: directory,
                                            createdAt: now(), state: .syncing)
        regroup()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            await self?.refresh()
        }
        return id
    }

    enum SessionListError: Error, LocalizedError {
        case notConnected
        case noSessionId

        var errorDescription: String? {
            switch self {
            case .notConnected: "尚未连接"
            case .noSessionId: "主机没有返回会话 id"
            }
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        refreshDebounce?.cancel()
        refreshDebounce = nil
    }

    /// Drops what the previous host's list was made of.
    ///
    /// `stop()` only cancels the streams: the rows, the workspace list and the
    /// search filter stayed on screen (and in memory) after a switch, so the new
    /// computer's list briefly showed the old one's groups.
    public func forgetConnection() {
        stop()
        groups = []
        loose = []
        workspaces = []
        allSessions = []
        archivedSessionIds = []
        lastCreatedSessionId = nil
        pendingCreated = [:]
        currentSessionId = nil
        searchText = ""
        finishedSignal = 0
        lastFinished = nil
        previouslyRunning = []
        phase = .idle
        lastRefreshed = nil
        // 换了电脑：指纹与"显示的是缓存"都必须复位，否则新一轮刷新可能因为
        // 指纹相同而跳过落盘（缓存文件已经不属于这台的语义），状态行也会一直
        // 说"显示上次数据"。
        lastSavedFingerprint = [:]
        digestVersion = nil
        isShowingSnapshot = false
        lastPrefetchScope = nil
    }

    /// 上次摘要的覆盖版本；连接器换机或版本失效时由全量响应重置。
    private var digestVersion: String?

    public func refresh() async {
        // 冷启动（或上次没拉成）：先把落盘的旧列表画出来，屏幕上立刻有东西，
        // 再去问 host。有缓存时**不进 loading**——那正是"空白等网络"的来源。
        showSnapshotIfEmpty()
        guard let link = store?.link, link.isConnected else {
            phase = .failed(String(localized: "尚未连接"))
            return
        }
        if groups.isEmpty { phase = .loading }
        do {
            let value = try await link.sessions(since: digestVersion)
            if value.full == true || digestVersion == nil {
                allSessions = value.items
            } else {
                allSessions = SessionDigestMerge.apply(current: allSessions, value: value)
            }
            digestVersion = value.version
            reconcilePending()
            // 018 T028：会话行喂给活动状态机（子会话计数 + 行轮次）。
            // 轮次口径沿用列表既有语义（`summary.running`）；聊天页当前会话由
            // `ActivityModel.bindChat` 用 `timeline.isTurnOpen` 覆盖。
            (activityModel ?? ActivityModel.shared).applySessions(value.items)
            // Retried: the fallback is the wrong grouping, so it should be a
            // last resort rather than the first answer to a slow response.
            if let baseline = await loadWorkspaces(link: link) {
                workspaces = baseline.items
                archivedSessionIds = Set(baseline.archivedSessionIds)
                isUsingFallbackGrouping = false
            } else {
                isUsingFallbackGrouping = workspaces.isEmpty
            }
            regroup()
            seedFirstSightings()
            noteFinishedRuns()
            lastRefreshed = Date()
            isShowingSnapshot = false
            phase = .loaded
            saveSnapshot()
            // T011：host 数据回来之后排一次冷启动预取瀑布（只排一次；
            // 磁盘层可能已被它喂出新的摘要，顺手再叠一次）。
            scheduleColdStartPrefetch()
        } catch {
            // Keep any previously loaded rows visible: a transient failure
            // should not blank out a list the user is reading.
            if groups.isEmpty {
                phase = .failed(LinkErrors.describe(error))
            }
        }
    }

    /// 冷启动/离线时先把上次的列表画出来（不等连接）。
    public func loadCachedList() {
        showSnapshotIfEmpty()
    }

    /// Draws the last known list when there is nothing on screen yet.
    ///
    /// Only when empty: a refresh that fails halfway must never replace live rows
    /// with older ones. And it never merges snapshot rows into a live list —
    /// that would resurrect sessions the user has since archived.
    private func showSnapshotIfEmpty() {
        // 只认**这台电脑**的快照：以前是全局单文件，换电脑之后冷启动会把上一台的
        // 列表画出来（两台电脑的会话 id 可能撞）。
        guard let scope = store?.scopeId,
              allSessions.isEmpty, groups.isEmpty,
              let snapshot = snapshotStore.load(scope: scope)
        else { return }
        allSessions = snapshot.items
        workspaces = snapshot.workspaces
        archivedSessionIds = Set(snapshot.archivedSessionIds)
        regroup()
        // 这些行还没跟 host 对过账，所以先不进"已完成未看"的判定：把看到时间按快照
        // 里的更新时间打底，等真数据回来再算（否则一冷启动整屏都是绿的）。
        seedFirstSightings()
        isShowingSnapshot = true
        lastSavedFingerprint[scope] = snapshot.contentFingerprint
        phase = .loaded
        // 诊断：冷启动到底有没有用上缓存（排查"打开是空的"时第一眼要看的就是这行）。
        probeNote?("snapshot.loaded", ["items": String(snapshot.items.count)], true)
    }

    /// Remembers the list for the next cold start. Metadata only.
    ///
    /// Skipped when the content is identical to what was last written: the list is
    /// refetched on every debounced host event, and rewriting ~150 KB of JSON each
    /// time is disk churn nobody asked for. The window/archived sets are part of
    /// the fingerprint, so a change there still lands.
    private func saveSnapshot() {
        guard let scope = store?.scopeId else { return }
        let snapshot = SessionListSnapshot(
            scope: scope,
            savedAt: Date(),
            items: allSessions,
            workspaces: workspaces,
            archivedSessionIds: Array(archivedSessionIds)
        )
        let fingerprint = snapshot.contentFingerprint
        guard fingerprint != lastSavedFingerprint[scope] else {
            probeNote?("snapshot.unchanged", ["items": String(allSessions.count)], false)
            return
        }
        lastSavedFingerprint[scope] = fingerprint
        snapshotStore.save(snapshot)
        // 规模可见：会话上千时这个 RPC 的载荷会开始咬人（协议里没有分页可用，
        // 见 DSHClient.sessions 的注释），到时候能在日志里先看见。
        probeNote?("snapshot.saved", [
            "items": String(allSessions.count),
            "workspaces": String(workspaces.count),
        ], true)
        if allSessions.count > 2_000 {
            probeNote?("snapshot.large", ["items": String(allSessions.count)], true)
        }
    }

    /// 设置页里的"清除缓存"。
    public func clearCachedSnapshot() {
        if let scope = store?.scopeId { snapshotStore.clear(scope: scope) }
        lastSavedFingerprint = [:]
        digestVersion = nil
        isShowingSnapshot = false
    }

    /// Subscribes to the host feed so sessions started elsewhere appear here.
    ///
    /// Session lifecycle events are frequent during heavy work, so refreshes
    /// are debounced and the raw event payload never reaches the view layer.
    /// The feed itself is owned by the shared hub, so the app holds exactly one
    /// host event connection no matter how many screens are open.
    private func subscribeToHostEvents() {
        eventTask?.cancel()
        guard let hub else { return }
        eventTask = Task { [weak self] in
            for await event in hub.events() {
                guard let self else { return }
                guard case .emit(let name, _) = event else { continue }
                guard Self.affectsSessionList(name) else { continue }
                self.scheduleDebouncedRefresh()
            }
        }
    }

    private static func affectsSessionList(_ event: String) -> Bool {
        event.hasPrefix("api-session/")
            || event == "session/title"
            || event == "session/created"
            || event == "session/disposed"
            || event == "turn/start"
            || event == "turn/end"
    }

    private func scheduleDebouncedRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: - Grouping

    /// Compares this refresh's running set with the last one.
    private func noteFinishedRuns() {
        let running = Set(allSessions.filter(\.running).map(\.sessionId))
        defer { previouslyRunning = running }

        // Nothing to compare against on the first refresh: every idle session
        // would look like something that just finished.
        guard !previouslyRunning.isEmpty else { return }

        let finished = previouslyRunning.subtracting(running)
        guard let id = finished.first,
              let session = allSessions.first(where: { $0.sessionId == id })
        else { return }

        lastFinished = session
        finishedSignal += 1
    }

    /// Reads the workspace list, retrying before giving up.
    ///
    /// A previously loaded list is kept on failure: better a slightly stale
    /// grouping than inventing groups the user never made.
    private func loadWorkspaces(link: LinkGateway) async -> WorkspaceBaseline? {
        for attempt in 0..<3 {
            if let baseline = try? await link.workspaces(timeout: .seconds(20)) {
                return baseline
            }
            guard attempt < 2 else { break }
            try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
        }
        return nil
    }

    /// Whether a session becomes a row, or stays host-side history.
    ///
    /// A blank session has never run a turn: it is what the host keeps when a
    /// new session is opened and nothing is ever sent to it. The desktop shows
    /// such a session only as the provisional row of the workspace's current
    /// session; everywhere else it is invisible. Reproducing that is what keeps
    /// the grey, titleless row out of every directory the user once opened a
    /// session in — and it keeps the exception the phone needs, because a
    /// session created here has to be reachable before it has any content.
    private func showsInList(_ session: SessionSummary) -> Bool {
        // 判据只有一份，在 DSHKit：分组（`SessionGrouping.partition`）与这里的"已归档"区共用它。
        SessionGrouping.showsInList(session,
                                    currentSessionId: currentSessionId,
                                    lastCreatedSessionId: lastCreatedSessionId)
    }

    /// 宿主行 + 尚未被宿主确认的占位（占位在前，宿主优先去重）。
    private var displaySessions: [SessionSummary] {
        guard !pendingCreated.isEmpty else { return allSessions }
        let hostIds = Set(allSessions.map(\.sessionId))
        let pending = pendingCreated.values
            .filter { !hostIds.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
            .map(Self.placeholder(from:))
        return pending + allSessions
    }

    /// 宿主列出同 id 就接管；超时仍没有就标 unsynced。
    private func reconcilePending() {
        guard !pendingCreated.isEmpty else { return }
        let hostIds = Set(allSessions.map(\.sessionId))
        let clock = now()
        for (id, pending) in pendingCreated {
            if hostIds.contains(id) {
                pendingCreated.removeValue(forKey: id)
                continue
            }
            if pending.state == .syncing,
               clock.timeIntervalSince(pending.createdAt) > Self.pendingSyncWindow {
                pendingCreated[id]?.state = .unsynced
            }
        }
    }

    private static func placeholder(from pending: PendingSession) -> SessionSummary {
        SessionSummary(
            sessionId: pending.id,
            updatedAt: pending.createdAt.timeIntervalSince1970 * 1000,
            running: false, blank: true,
            parentSessionId: nil, origin: nil, cwd: pending.directory,
            projections: nil, agentAvailable: nil)
    }

    private func regroup() {
        // 切分判定（谁上列表、怎么按 workspace 分配、子代理挂给谁、没归档的归哪里）在 DSHKit
        // 的 `SessionGrouping` 里，带单测；这里只负责取用 + 排序 + 文案（都是 App 的东西）。
        let partition = SessionGrouping.partition(
            sessions: displaySessions,
            archivedIds: archivedSessionIds,
            workspaces: workspaces,
            query: searchText,
            currentSessionId: currentSessionId,
            lastCreatedSessionId: lastCreatedSessionId
        )

        if workspaces.isEmpty {
            // 从没读到过 workspace 列表：按目录兜底。空目录名的那一组拿"未分组"这句文案
            // （文案归 App，DSHKit 那边返回空标题）。
            groups = orderGroups(partition.directoryGroups.map { group in
                var titled = group
                if titled.title.isEmpty { titled.title = String(localized: "未分组") }
                return titled
            })
            // 折叠桶也按状态排序（待答 → 运行中 → 未看 → 看过），而不是只按时间：
            // 一个在等用户回答的会话被压到 48 条折叠列表的中间，等于没做这个状态。
            loose = orderSessions(partition.loose)
            return
        }

        groups = orderGroups(partition.workspaceGroups)
        loose = partition.loose.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Groups with something running first, then the rest; each part by the
    /// group's most recent activity.
    ///
    /// This deliberately parts ways with the desktop sidebar, which shows the
    /// user's own workspace order: on a phone the list is opened to answer "is
    /// anything happening?", so work in flight outranks a saved arrangement.
    private func orderGroups(_ groups: [Group]) -> [Group] {
        let sorted = SessionListOrder.groups(
            groups,
            isRunning: { $0.sessions.contains(where: \.running) },
            activity: { $0.sessions.map(\.updatedAt).max() ?? 0 }
        )
        // Members are ordered after the groups, so the state lookup runs once per
        // group rather than inside the comparison.
        return sorted.map { group in
            Group(
                id: group.id,
                path: group.path,
                title: group.title,
                sessions: orderSessions(group.sessions),
                children: group.children
            )
        }
    }

    /// Running first, then finished-unseen, then the rest; newest first inside
    /// each bucket.
    ///
    /// The state buckets are the whole point: a session that finished while the
    /// user was away should be one glance away, not wherever the desktop's
    /// assignment order happens to put it.
    private func orderSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        SessionListOrder.members(
            sessions,
            state: { [weak self] session in
                self?.state(of: session) ?? .finishedSeen
            },
            updatedAt: \.updatedAt
        )
    }
}

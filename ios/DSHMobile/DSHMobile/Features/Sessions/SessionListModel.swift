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
final class SessionListModel {

    /// One working-directory group.
    struct Group: Identifiable {
        let id: String
        let path: String
        var title: String
        var sessions: [SessionSummary]
        /// Subagent transcripts keyed by their parent session id.
        var children: [String: [SessionSummary]]
    }

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var groups: [Group] = []
    /// The desktop client's explicit workspace list, in its own order.
    private(set) var workspaces: [Workspace] = []

    /// Set when archiving failed, so the swipe can say why instead of looking
    /// like nothing happened.
    var archiveError: String?

    /// The session the app just created.
    ///
    /// A brand-new session has no title, so its row looks like every other
    /// untitled one — marking it is how the user (and a test) can tell which
    /// row is the one they just made.
    private(set) var lastCreatedSessionId: String?

    /// The session the app currently has open, when it has one.
    ///
    /// The desktop sidebar shows a session that has never run a turn only while
    /// it is the selected one — it is that workspace's provisional "new session"
    /// row, not history. Reproducing that rule needs the phone to know which row
    /// is the open one.
    var currentSessionId: String? {
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
    var archivedSessions: [SessionSummary] {
        allSessions
            .filter { archivedSessionIds.contains($0.sessionId) && showsInList($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A path as the desktop client would show it.
    func displayPath(_ path: String) -> String {
        PathFormat.short(path, home: store?.hostHome)
    }

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
    private(set) var finishedSignal = 0
    private(set) var lastFinished: SessionSummary?

    /// Sessions the host reported as running on the previous refresh.
    private var previouslyRunning: Set<String> = []

    /// True when the workspace list could not be read and the list is falling
    /// back to grouping by directory.
    ///
    /// Surfaced in the UI on purpose: a silent fallback looks exactly like
    /// correct behaviour while showing the wrong grouping, which is how a stale
    /// install and a failed fetch became indistinguishable.
    private(set) var isUsingFallbackGrouping = false

    /// Sessions the user has archived on the desktop; kept out of the list.
    private var archivedSessionIds: Set<String> = []

    /// Sessions with no workspace, plus subagents whose parent is not visible.
    ///
    /// These are reference material rather than things the user is working on,
    /// so the list keeps them behind one collapsed disclosure instead of
    /// interleaving them with live work.
    private(set) var loose: [SessionSummary] = []
    private(set) var lastRefreshed: Date?

    var searchText: String = "" {
        didSet { if searchText != oldValue { regroup() } }
    }

    /// Every session the list knows about, grouped or not. Read by the
    /// new-session sheet, which offers the directories they run in.
    private(set) var allSessions: [SessionSummary] = []
    private var eventTask: Task<Void, Never>?
    private var refreshDebounce: Task<Void, Never>?
    private weak var store: ConnectionStore?
    private weak var hub: HostEventHub?

    /// Sessions currently executing a turn among the ones on screen.
    ///
    /// Counting every session in the host's registry made the badge disagree
    /// with what the user could see: sessions in the folded ungrouped bucket
    /// were counted but not visible.
    var runningCount: Int {
        groups.reduce(0) { $0 + $1.sessions.filter(\.running).count }
    }

    /// Running sessions that live in the folded ungrouped bucket.
    ///
    /// Surfaced separately rather than silently folded away, so the badge can
    /// stay honest without making the ungrouped bucket look empty.
    var ungroupedRunningCount: Int {
        loose.filter(\.running).count
    }

    var isEmpty: Bool {
        groups.isEmpty && loose.isEmpty
    }

    /// Whether a search is currently narrowing the list.
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Looks up one session by id, for navigation destinations.
    func session(withId id: String) -> SessionSummary? {
        if let match = allSessions.first(where: { $0.sessionId == id }) { return match }
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

    func attach(to store: ConnectionStore, hub: HostEventHub, viewLog: SessionViewLog? = nil) {
        self.store = store
        self.hub = hub
        if let viewLog { self.viewLog = viewLog }
    }

    /// When each session was last opened on this phone.
    ///
    /// Injected rather than created here so the same log is shared with the
    /// screen that opens sessions — that write is what clears an unseen row.
    var viewLog: SessionViewLog?

    /// What the leading dot should say for this row.
    func state(of session: SessionSummary) -> SessionRowState {
        SessionRowState.of(
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
    func markViewed(_ sessionId: String) {
        viewLog?.markViewed(sessionId)
    }

    /// The row's state, as the accessibility tree should name it.
    ///
    /// Tests assert on this rather than on a colour: a dot's hue is not
    /// something a run can read, and "looks blue" is not a verdict.
    func stateIdentifier(of session: SessionSummary) -> String {
        "session.state.\(state(of: session).rawValue)"
    }

    /// Loads the list, then keeps it fresh from the host event stream.
    func start() async {
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
    func setArchived(_ archived: Bool, sessionId: String) async -> Bool {
        guard let client = store?.client else { return false }
        do {
            let ids = try await client.archiveSession(sessionId, archived: archived)
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
    func startSession(directory: String) async throws -> String {
        guard let client = store?.client else { throw SessionListError.notConnected }
        let registration = try await client.createWorkspace(path: directory)

        let id: String
        do {
            let value = try await client.createSession(
                SessionCreateRequest(workspaceId: registration.workspace.workspaceId)
            )
            guard let created = value["sessionId"]?.stringValue else { throw SessionListError.noSessionId }
            id = created
        } catch {
            // A registration this call created would otherwise outlive the
            // failure as an empty group in the desktop sidebar. One the host
            // already had is none of this call's business.
            if registration.created {
                try? await client.deleteWorkspace(id: registration.workspace.workspaceId)
            }
            throw error
        }

        // The new session must be in the list before it can be opened: the
        // caller looks it up by id to build the chat screen. A blank session is
        // invisible to the desktop client until it is current, and the host can
        // take a moment to list it, so this waits rather than guessing.
        lastCreatedSessionId = id
        for _ in 0..<6 {
            await refresh()
            if self.session(withId: id) != nil { break }
            try? await Task.sleep(for: .milliseconds(300))
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

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        refreshDebounce?.cancel()
        refreshDebounce = nil
    }

    func refresh() async {
        guard let client = store?.client else {
            phase = .failed("尚未连接")
            return
        }
        if groups.isEmpty { phase = .loading }
        do {
            let value = try await client.sessions()
            allSessions = value.items
            // Retried: the fallback is the wrong grouping, so it should be a
            // last resort rather than the first answer to a slow response.
            if let baseline = await loadWorkspaces(client: client) {
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
            phase = .loaded
        } catch {
            // Keep any previously loaded rows visible: a transient failure
            // should not blank out a list the user is reading.
            if groups.isEmpty {
                phase = .failed(ConnectionStore.describe(error))
            }
        }
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
    private func loadWorkspaces(client: DSHClient) async -> WorkspaceBaseline? {
        for attempt in 0..<3 {
            if let baseline = try? await client.workspaces(timeout: .seconds(20)) {
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
        guard session.blank else { return true }
        return session.sessionId == currentSessionId || session.sessionId == lastCreatedSessionId
    }

    private func regroup() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        // Archived sessions are hidden on the desktop, so they are hidden here.
        // The same goes for sessions that have never run a turn: the host keeps
        // one for every "new session" that was opened and never used, and the
        // desktop never lists them as rows.
        let visible = allSessions.filter {
            !archivedSessionIds.contains($0.sessionId) && showsInList($0)
        }

        let filtered: [SessionSummary]
        if query.isEmpty {
            filtered = visible
        } else {
            filtered = visible.filter { session in
                if session.displayTitle.lowercased().contains(query) { return true }
                if let cwd = session.cwd, cwd.lowercased().contains(query) { return true }
                if let objective = session.projections?.values?.goal?.goal?.objective,
                   objective.lowercased().contains(query) {
                    return true
                }
                return false
            }
        }

        // Subagent transcripts are reached through the session that spawned
        // them, never as list rows of their own.
        var byParent: [String: [SessionSummary]] = [:]
        var topLevel: [SessionSummary] = []
        for session in filtered {
            if session.isSubagent, let parent = session.parentSessionId {
                byParent[parent, default: []].append(session)
            } else {
                topLevel.append(session)
            }
        }
        let byId = Dictionary(topLevel.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })

        // Group exactly the way the desktop sidebar does: the host's workspace
        // list, each holding the sessions the user assigned to it, in the
        // user's own order. Deriving groups from the working directory instead
        // — which is what this used to do — invents groups the user never made
        // and shows sessions the desktop keeps folded away.
        var assigned = Set<String>()
        var built: [Group] = []
        for workspace in workspaces {
            let members = workspace.sessionIds.compactMap { id -> SessionSummary? in
                guard let session = byId[id] else { return nil }
                assigned.insert(id)
                return session
            }
            guard !members.isEmpty else { continue }
            built.append(
                Group(
                    id: workspace.workspaceId,
                    path: workspace.path,
                    title: workspace.title,
                    sessions: members,
                    children: byParent
                )
            )
        }

        // Anything the user has not filed into a workspace. The desktop keeps
        // this folded; it is reference material, not current work.
        let unfiled = topLevel
            .filter { !assigned.contains($0.sessionId) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let orphans = byParent
            .filter { !byId.keys.contains($0.key) }
            .flatMap(\.value)

        if workspaces.isEmpty {
            // No workspace list was ever read: group by directory so the list
            // is still usable. The header states that this is a fallback, and
            // unfiled sessions stay folded below either way.
            groups = orderGroups(
                Dictionary(grouping: topLevel, by: { $0.cwd ?? "" })
                    .map { path, sessions in
                        Group(
                            id: path.isEmpty ? "__none__" : path,
                            path: path,
                            title: path.isEmpty ? "未分组" : (path as NSString).lastPathComponent,
                            sessions: sessions.sorted { $0.updatedAt > $1.updatedAt },
                            children: byParent
                        )
                    }
            )
            loose = (unfiled + orphans).sorted { $0.updatedAt > $1.updatedAt }
            return
        }

        groups = orderGroups(built)
        loose = (unfiled + orphans).sorted { $0.updatedAt > $1.updatedAt }
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

import DSHKit
import Foundation
import Observation
import UIKit

/// Drives one session transcript: history, the live stream, and outbound input.
@MainActor
@Observable
final class ChatModel {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// The transcript, folded from the journal and the live assistant stream.
    private(set) var timeline = ChatTimeline()
    private(set) var phase: Phase = .idle
    private(set) var session: SessionSummary?
    /// What the agent is doing right now.
    ///
    /// This has to come from the turn events on the session's own follow
    /// stream. An earlier version listened for them on the forwarded host event
    /// feed, which never carries them — so the state latched on at send time and
    /// the stop button stayed on screen forever, even after the run finished.
    enum Activity: Equatable {
        case idle
        /// A prompt this phone sent has been accepted, but no turn has started.
        case submitting
        /// The host reported a turn in progress.
        case running
    }

    var activity: Activity {
        if timeline.isTurnOpen { return .running }
        if isAwaitingTurnStart { return .submitting }
        return .idle
    }

    /// True only while a turn is genuinely in flight.
    var isRunning: Bool { activity == .running }

    /// Whether a stop control should be offered at all.
    var isBusy: Bool { activity != .idle }

    /// The most recent completed turn, used to announce the end of a run.
    private(set) var completion: ChatTimeline.Completion?

    /// Bumped whenever a run finishes, so the view can flash a confirmation.
    private(set) var completionSignal: Int = 0

    /// Streaming chunks waiting to be folded into the transcript.
    private var pendingStreamFrames: [AssistantStreamFrame] = []
    private var streamFlushTask: Task<Void, Never>?

    /// How often coalesced stream frames are folded in.
    ///
    /// Eight times a second is smoother than the tokens arriving and roughly an
    /// order of magnitude cheaper than folding each one.
    private static let streamFlushInterval = Duration.milliseconds(120)

    /// A picture chosen for the next prompt, held until it is sent.
    ///
    /// The bytes are carried as base64 because that is the only door a picture
    /// has into a session: the Host promotes inline prompt images to durable
    /// attachments, and the attachment service itself is read-only.
    struct DraftImage: Identifiable {
        let id = UUID()
        let mediaType: String
        let base64: String
        let name: String
        let preview: UIImage
    }

    /// Pictures queued in the composer, sent with the next prompt.
    private(set) var draftImages: [DraftImage] = []

    /// Name of the file being uploaded, for the composer to show.
    private(set) var isUploadingFile: String?

    /// Set between submitting a prompt and the host starting its turn.
    private var isAwaitingTurnStart = false
    /// The host's own view of whether it is running, from the session summary.
    private var hostReportsRunning = false
    private var awaitingTimeout: Task<Void, Never>?
    private var lastSeenCompletionAt: Date?
    /// True while older history is being fetched.
    private(set) var isLoadingOlder = false
    private(set) var hasOlder = false
    private(set) var lastError: String?

    /// Model routes the host can serve, loaded once per session.
    private(set) var catalog: ModelCatalog?
    private(set) var currentSelection: ModelSelection?
    private(set) var permissionOptions: [PermissionsProjection.Option] = []
    private(set) var currentPermission: String?

    /// Composer state.
    var draft: String = ""
    /// Whether the next submission queues behind the turn or steers into it.
    var steerNext: Bool = false

    /// Bumped whenever the transcript grows, so the view can autoscroll.
    private(set) var scrollSignal: Int = 0
    /// Bumped when the user themselves adds something, which is the one case
    /// where the view should jump back to the bottom even if they had scrolled
    /// away: they are waiting to see their own message land.
    private(set) var sendSignal: Int = 0

    private var store: ConnectionStore?
    private var hub: HostEventHub?
    /// Warm transcripts, most recently used last.
    private var cache: [String: CachedSession] = [:]

    /// 转写尾部的落盘缓存（每个"电脑 + 会话"一份）。
    ///
    /// 内存缓存让"再进同一个会话"很快，但 App 一冷启动就归零，于是打开会话仍然是
    /// 空白 + 转圈。落盘的是**原始记录**的尾部——和 `session/follow` 打开时给的快照
    /// 是同一种东西，所以恢复路径与合并路径都复用现成逻辑。
    private let transcriptCache = SessionTranscriptCache()

    /// 最近的记录（尾部），落盘写的就是它。
    private var recentRecords: [SessionRecord] = []
    private var lastDiskSave = Date.distantPast
    /// 距上次落盘又攒了多少条（够了就写，不等计时器）。
    private var unsavedRecords = 0
    /// 用户刚清过缓存：在重新打开一个会话之前不要再写。
    private var persistSuspended = false

    /// 用户最后想看、但可能还没连上而没能打开的会话。
    private var pendingOpen: SessionSummary?

    /// 打开这个会话时属于哪台电脑。
    ///
    /// 不能在落盘那一刻现取 `store.scopeId`：切换/断开时 profile 已经被清掉或换成
    /// 新电脑了，旧电脑的尾部会落到 `unknown/` 或**新电脑**的目录里——两台电脑的
    /// 会话 id 本来就可能撞（fork/clone），那就是把 A 的记录当成 B 的显示。
    private var sessionScope: String?

    /// 这次打开用的同步计划（快照到达时还要用它判断合并还是重来）。
    private var syncPlanRef = TranscriptSyncPlan.plan(localThrough: nil, hostCursor: 0)

    /// Half-written messages, one per session.
    ///
    /// The draft used to be a single field on this (single, app-wide) model, and
    /// switching sessions never reset it: text typed for one conversation showed
    /// up in the next one's composer, and pressing send there posted it — the
    /// host stores a prompt against the session id of the moment, so from the
    /// receiving side it looked like an instruction the user never gave.
    private var drafts: [String: Draft] = [:]

    struct Draft {
        var text: String = ""
        var images: [DraftImage] = []

        var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
        }
    }
    private var cacheOrder: [String] = []
    private static let cacheLimit = 6
    private var followTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var oldestSeq: Int?
    /// The cut the follow stream opened at; older pages must stay below it.
    private var throughSeq: Int = 0

    var address: SessionAddress? { session?.address }

    /// Host prompts waiting for the human on this session.
    var pendingPrompts: [HostEventHub.Pending] {
        guard let session, let hub else { return [] }
        return hub.pending(for: session.sessionId)
    }

    // MARK: - Lifecycle

    func attach(store: ConnectionStore, hub: HostEventHub) {
        self.store = store
        self.hub = hub
    }

    /// Opens a session: cached transcript first, then the live stream.
    ///
    /// A session the user has already looked at renders instantly from cache and
    /// refreshes underneath; only a first visit shows a spinner. Re-entering a
    /// conversation is the single most common navigation in this app, so it must
    /// not feel like a page load.
    func open(_ summary: SessionSummary) async {
        // 记下"用户想看的那个会话"：如果此刻还没连上（冷启动刚进列表就点开），
        // 这一屏会停在"尚未连接"——连上之后要能自己回来，而不是让用户点重试。
        pendingOpen = summary
        guard let client = store?.client else {
            phase = .failed(String(localized: "尚未连接"))
            return
        }
        // Persist whatever the previous session had before switching away —
        // transcript and draft both. `close()` 里会写盘，所以这一步不能省：
        // 之前只写内存缓存，进程一没，刚才看的那段就没了。
        close()

        let key = summary.sessionId
        sessionScope = scopeId == "unknown" ? nil : scopeId
        persistSuspended = false
        // 这次跟 host 要多少条快照：本地尾部很新（差 ≤20 条）时只要 20 条就够对齐，
        // 少拉一遍重复数据；本地落后很多或没有本地缓存时按 60 条来，避免中间留洞。
        var syncPlan = TranscriptSyncPlan.plan(localThrough: nil, hostCursor: summary.asOfSeq)
        // 记录必须按会话隔离：带着上一个会话的 recentRecords 去写这个会话的文件，
        // 就是把 A 的内容盖到 B 上（用户看到的就是"记录丢了一部分"）。
        recentRecords = []
        lastDiskSave = .distantPast
        let cached = cache[key]
        session = summary
        // This session's own half-written message, not the last one's.
        draft = drafts[key]?.text ?? ""
        draftImages = drafts[key]?.images ?? []
        lastError = nil
        hostReportsRunning = summary.running
        isAwaitingTurnStart = false
        currentSelection = summary.projections?.values?.modelSelection?.next
            ?? summary.projections?.values?.modelSelection?.lastUsed
        permissionOptions = summary.projections?.values?.permissions?.options ?? []
        currentPermission = summary.projections?.values?.permissions?.currentValue

        if let cached {
            // Restore immediately: same rows, same scroll position, no spinner.
            timeline = cached.timeline
            timeline.clearStreaming()
            timeline.record(usage: summary.projections?.values?.tokenUsage)
            hasOlder = cached.hasOlder
            oldestSeq = cached.oldestSeq
            throughSeq = max(cached.throughSeq, summary.asOfSeq)
            // 记录也要一起恢复：否则下一次落盘会把"这个会话只有刚到的这几条"
            // 写进磁盘，之前那段就被截掉了。
            recentRecords = cached.records.isEmpty
                ? (sessionScope.flatMap { transcriptCache.load(scope: $0, sessionId: key)?.records } ?? [])
                : cached.records
            phase = .ready
            scrollSignal += 1
        } else if let scope = sessionScope,
                  let stored = transcriptCache.load(scope: scope, sessionId: key) {
            // 窗口按"本地落后 host 多少"来定：落后很多时要更大的窗口，否则
            // 快照接不上本地尾部，时间线中间会留一个永远补不上的洞。
            syncPlan = TranscriptSyncPlan.plan(
                localThrough: stored.throughSeq, hostCursor: summary.asOfSeq)
            ViewportProbe.note("transcript.window", [
                "local": String(stored.throughSeq),
                "host": String(summary.asOfSeq),
                "maxMessages": String(syncPlan.maxMessages),
                "rebase": syncPlan.reBase ? "1" : "0",
            ], force: true)
            // 接不上（落后太多，或本地游标比 host 还大）就别画本地那段了：
            // 画出来只会先闪一下跟 host 对不上的内容，然后被快照换掉。
            // 更老的历史仍在电脑上，往前翻能取回。
            timeline = ChatTimeline()
            timeline.record(usage: summary.projections?.values?.tokenUsage)
            if syncPlan.reBase {
                recentRecords = []
                hasOlder = false
                oldestSeq = nil
                throughSeq = summary.asOfSeq
                phase = .loading
            } else {
                // 冷启动/新进程：用落盘的尾部立刻把转写画出来，**不进 loading**。
                // 随后 follow 的快照会按 seq 合并进来，只补差量。
                timeline.reset(with: stored.records)
                recentRecords = stored.records
                hasOlder = stored.hasOlder
                oldestSeq = stored.oldestSeq
                throughSeq = max(stored.throughSeq, summary.asOfSeq)
                phase = .ready
                scrollSignal += 1
                ViewportProbe.note("transcript.loaded", [
                    "session": key,
                    "records": String(stored.records.count),
                    // 诊断用：读回来的"最老一条"必须等于记录里的第一条
                    "oldest": String(stored.oldestSeq ?? -1),
                ], force: true)
            }
        } else {
            timeline = ChatTimeline()
            timeline.record(usage: summary.projections?.values?.tokenUsage)
            hasOlder = false
            oldestSeq = nil
            throughSeq = summary.asOfSeq
            phase = .loading
        }

        syncPlanRef = syncPlan
        startFollowing(client: client, summary: summary, maxMessages: syncPlan.maxMessages)
        pendingOpen = nil
        await loadCatalog(client: client)
        subscribeToPrompts()
    }

    /// Stops the live streams and keeps the transcript warm for a revisit.
    func close() {
        // 顺序要紧：先把记录和转写写下去，再清状态。
        persistTranscriptNow()
        saveToCache()
        stashDraft()
        followTask?.cancel()
        followTask = nil
        eventTask?.cancel()
        eventTask = nil
        awaitingTimeout?.cancel()
        awaitingTimeout = nil
        streamFlushTask?.cancel()
        streamFlushTask = nil
        pendingStreamFrames.removeAll(keepingCapacity: false)
        isAwaitingTurnStart = false
    }

    /// Drops everything that belonged to the connection just left.
    ///
    /// Closing alone was not enough: the transcript cache is keyed by session id
    /// and the host is happy to hand out consecutive ids, so a switch to another
    /// computer could show that computer's conversation from the previous one's
    /// cache before the fresh load landed. Drafts go too — a half-written
    /// message belongs to the host it was typed for.
    func forgetConnection() {
        close()
        sessionScope = nil
        session = nil
        timeline = ChatTimeline()
        cache.removeAll()
        cacheOrder.removeAll()
        drafts.removeAll()
        draft = ""
        draftImages.removeAll()
        lastError = nil
        currentSelection = nil
        permissionOptions = []
        currentPermission = nil
        hasOlder = false
        oldestSeq = nil
        throughSeq = 0
        pendingStreamFrames.removeAll()
        phase = .idle
    }

    /// Re-opens the session on screen after the link came back.
    ///
    /// The follow stream dies with the socket, and a transcript that stopped
    /// updating looks exactly like one where nothing is happening — the worst
    /// possible failure for a client whose job is "is it still working?".
    /// Re-opening reuses the warm cache, so the rows and the reading position
    /// stay where the user left them.
    func reopenAfterReconnect() async {
        guard store?.client != nil else { return }
        // 两种情况都要恢复：先打开再断线（session 还在），以及**没连上就打开过**
        // （session 还是 nil，只有 pendingOpen 记得用户想看谁）。
        if let current = session {
            await open(current)
        } else if let wanted = pendingOpen {
            await open(wanted)
        }
    }

    // MARK: - Warm cache

    /// A transcript kept in memory so returning to a session is instant.
    private struct CachedSession {
        var timeline: ChatTimeline
        var hasOlder: Bool
        var oldestSeq: Int?
        var throughSeq: Int
        /// 这个会话的原始记录尾部（落盘写的就是它）。
        var records: [SessionRecord]
    }

    /// Keeps the composer's contents under the session it was typed for.
    ///
    /// Called on the way out of a session, so nothing typed is lost and nothing
    /// leaks: the next session loads its own draft (usually empty).
    private func stashDraft() {
        guard let key = session?.sessionId else { return }
        let current = Draft(text: draft, images: draftImages)
        if current.isEmpty { drafts.removeValue(forKey: key) } else { drafts[key] = current }
    }

    private func saveToCache() {
        guard let key = session?.sessionId, !timeline.items.isEmpty else { return }
        cache[key] = CachedSession(
            timeline: timeline,
            hasOlder: hasOlder,
            oldestSeq: oldestSeq,
            throughSeq: throughSeq,
            records: recentRecords
        )
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        // Bounded so a long session-hopping run cannot grow without limit.
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// Drops one session's cached transcript, e.g. after it is deleted.
    func forget(_ sessionId: String) {
        cache.removeValue(forKey: sessionId)
        cacheOrder.removeAll { $0 == sessionId }
        transcriptCache.clear(scope: sessionScope ?? scopeId, sessionId: sessionId)
    }

    /// 当前会话属于哪台电脑——缓存按它分目录，换电脑不会串味。
    private var scopeId: String { store?.scopeId ?? "unknown" }

    /// 把新记录并进尾部：按 seq 去重、保持顺序、只留最新 `maxRecords` 条。
    ///
    /// 两条来源（本地已存的尾部、host 刚给的快照/事件）会在同一会话里重叠——
    /// 快照的第一条往往本地早就有了。去重是必须的，替换是错的。
    private func mergeTail(_ incoming: [SessionRecord]) {
        guard !incoming.isEmpty else { return }
        var bySeq = Dictionary(recentRecords.map { ($0.event.seq, $0) }, uniquingKeysWith: { _, new in new })
        for record in incoming { bySeq[record.event.seq] = record }
        var merged = bySeq.values.sorted { $0.event.seq < $1.event.seq }
        if merged.count > SessionTranscriptCache.maxRecords {
            merged.removeFirst(merged.count - SessionTranscriptCache.maxRecords)
        }
        if merged.count > recentRecords.count { unsavedRecords += merged.count - recentRecords.count }
        recentRecords = merged
    }

    /// 把尾部写盘。默认节流：流式输出时每个事件都写会把磁盘当内存用。
    private func persistIfDue(force: Bool = false) {
        guard !persistSuspended, let sessionId = session?.sessionId else { return }
        guard let scope = sessionScope else { return }
        // 会话已经不属于当前这台电脑了（用户切走了）：别再往任何地方写。
        let currentScope = scopeId
        guard currentScope == "unknown" || currentScope == scope else { return }
        let now = Date()
        // 一轮进行中也可能被杀：1 秒或攒够 20 条就写一次，尽量把丢失窗口压小。
        let due = unsavedRecords >= 20 || now.timeIntervalSince(lastDiskSave) > 1
        guard force || due else { return }
        lastDiskSave = now
        unsavedRecords = 0
        ViewportProbe.note("transcript.saved", [
            "session": sessionId,
            "records": String(recentRecords.count),
            "lastSeq": String(recentRecords.last?.event.seq ?? -1),
        ], force: true)
        transcriptCache.save(
            SessionTranscriptSnapshot(
                savedAt: now,
                records: recentRecords,
                // 传尾部自己的第一条：这个字段必须描述"文件里存了什么"，
                // 而不是"屏幕上翻到过哪里"（后者会被 prepend 推得更老）。
                oldestSeq: recentRecords.first?.event.seq,
                throughSeq: throughSeq,
                hasOlder: hasOlder
            ),
            scope: scope,
            sessionId: sessionId
        )
    }

    /// 立刻落盘（退到后台、离开会话时用：那些时刻之后进程可能就没了）。
    func persistTranscriptNow() {
        persistIfDue(force: true)
    }

    /// 「清除本地缓存」被按下：把内存里的尾部也丢掉，并暂停写盘直到下次打开会话。
    ///
    /// 否则会出现"清完 1 秒又回来"的假象：屏幕上的会话仍然握着 200 条记录，
    /// 下一次节流落盘就把文件写回去了。
    func dropPersistedTail() {
        recentRecords = []
        unsavedRecords = 0
        persistSuspended = true
    }

    private func startFollowing(client: DSHClient, summary: SessionSummary, maxMessages: Int = 60) {
        followTask = Task { [weak self] in
            guard let self else { return }
            let stream = await client.follow(
                SessionFollowRequest(address: summary.address, maxMessages: maxMessages, assistantStream: true)
            )
            do {
                for try await frame in stream {
                    if Task.isCancelled { return }
                    self.apply(frame)
                }
                // The host ended the stream; the session may have been disposed.
                if self.phase == .loading { self.phase = .ready }
            } catch {
                guard !Task.isCancelled else { return }
                if self.phase == .loading {
                    self.phase = .failed(ConnectionStore.describe(error))
                } else {
                    self.lastError = ConnectionStore.describe(error)
                }
            }
        }
    }

    private func apply(_ frame: SessionFollowFrame) {
        switch frame {
        case .snapshot(let snapshot):
            // 这次之前本地尾部到哪（用来判断"是不是真的丢掉了一段"，冷启动没有尾部时
            // 不该记成 rebased）。
            let localLastAtSnapshot = recentRecords.last?.event.seq
            // 计划说得再好，也要看实际回来的第一条接不接得上本地尾部：
            // 接不上（中间缺一段）就只能重来，否则那个洞会写进磁盘、永远补不上。
            let needsReBase = syncPlanRef.reBase
                || TranscriptSyncPlan.stillNeedsReBase(
                    localLastSeq: recentRecords.last?.event.seq,
                    snapshotFirstSeq: snapshot.records.first?.event.seq)
            if timeline.items.isEmpty || needsReBase {
                timeline.reset(with: snapshot.records)
                if needsReBase, !timeline.items.isEmpty, localLastAtSnapshot != nil {
                    ViewportProbe.note("transcript.rebased", [
                        "localLast": String(recentRecords.last?.event.seq ?? -1),
                        "snapshotFirst": String(snapshot.records.first?.event.seq ?? -1),
                    ], force: true)
                    recentRecords = []
                }
            } else {
                // Warm cache: update in place so the reader keeps any older
                // history they had already paged in.
                timeline.merge(snapshot: snapshot.records)
            }
            throughSeq = max(throughSeq, snapshot.cursor)
            // 本地可能已经存着比这次快照更老的一段（冷启动缓存）：取更小的那个，
            // 否则"往前翻"会从快照的第一条开始要，等于把本地已有的又拉一遍。
            oldestSeq = [oldestSeq, snapshot.records.first?.event.seq]
                .compactMap { $0 }
                .min()
            // 以 host 为准：`hasMore=false` 意味着这次快照的窗口已经退到日志开头，
            // 那就真的没有更早的了。以前写成 `|| hasOlder`，本地旧状态会把"到底了"
            // 硬说成"还能往前翻"，点下去什么也加载不出来。
            hasOlder = snapshot.hasMore
            phase = .ready
            scrollSignal += 1
            // 快照要**并进**本地尾部，不能替换：本地可能存着 200 条，而这次的快照
            // 只有 20 条（本地很新时故意少要），直接替换等于把已落盘的历史截掉
            // ——用户看到的就是"切后台回来少了一部分记录"。
            mergeTail(snapshot.records)
            persistIfDue(force: true)

        case .event(let event):
            flushStreamFrames()
            let change = timeline.apply(event)
            if case .none = change {} else { scrollSignal += 1 }
            mergeTail([SessionRecord(event: event)])
            persistIfDue()
            // A live event proves the stream is healthy even if the summary
            // was stale when the list was fetched.
            if phase != .ready { phase = .ready }
            reactToTurnLifecycle(event)

        case .assistantStream(let streamFrame):
            // Coalesced rather than applied per token. A model emits many
            // chunks a second, and each one otherwise re-renders the whole
            // transcript; on a phone that is enough to make the UI stop
            // responding while a session is streaming.
            enqueueStreamFrame(streamFrame)

        case .unknown:
            break
        }
    }

    /// Queues one streaming frame and schedules a coalesced fold.
    private func enqueueStreamFrame(_ frame: AssistantStreamFrame) {
        pendingStreamFrames.append(frame)
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.streamFlushInterval)
            guard !Task.isCancelled else { return }
            self?.flushStreamFrames()
        }
    }

    /// Folds every queued streaming frame in one go.
    ///
    /// Ordering is preserved: committed events flush first, so a message can
    /// never be folded before the deltas that preceded it.
    private func flushStreamFrames() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard !pendingStreamFrames.isEmpty else { return }
        let frames = pendingStreamFrames
        pendingStreamFrames.removeAll(keepingCapacity: true)

        var changed = false
        for frame in frames {
            if case .none = timeline.apply(frame) {} else { changed = true }
        }
        if changed { scrollSignal += 1 }
    }

    /// Turns the two lifecycle events into run state and a completion signal.
    ///
    /// Everything else in the journal is content; these two are state.
    private func reactToTurnLifecycle(_ event: SessionEvent) {
        switch event.type {
        case "turn/start":
            isAwaitingTurnStart = false
            hostReportsRunning = true
            awaitingTimeout?.cancel()
            awaitingTimeout = nil

        case "turn/end":
            isAwaitingTurnStart = false
            hostReportsRunning = false
            awaitingTimeout?.cancel()
            awaitingTimeout = nil
            // 一轮结束是天然检查点：此刻把尾部写死，进程随后没了也不丢这一轮。
            persistIfDue(force: true)
            if let finished = timeline.lastCompletion,
               finished.at != lastSeenCompletionAt {
                lastSeenCompletionAt = finished.at
                completion = finished
                completionSignal += 1
            }
            // Token usage and the running flag both move at turn boundaries.
            Task { await self.refreshSummary() }

        default:
            break
        }
    }

    /// Watches the forwarded host feed for changes worth re-reading.
    private func subscribeToPrompts() {
        eventTask?.cancel()
        guard let hub, let session else { return }
        let target = session.sessionId
        eventTask = Task { [weak self] in
            for await event in hub.events() {
                guard let self else { return }
                switch event {
                case .emit(let name, _) where name == "session/title":
                    await self.refreshSummary()
                case .ready:
                    await self.refreshSummary()
                default:
                    break
                }
                _ = target
            }
        }
    }

    private func refreshSummary() async {
        guard let client = store?.client, let current = session else { return }
        guard let value = try? await client.sessions(),
              let updated = value.items.first(where: { $0.sessionId == current.sessionId })
        else { return }
        session = updated
        hostReportsRunning = updated.running
        currentPermission = updated.projections?.values?.permissions?.currentValue
        timeline.record(usage: updated.projections?.values?.tokenUsage)
    }

    private func loadCatalog(client: DSHClient) async {
        guard catalog == nil else { return }
        catalog = try? await client.modelCatalog()
    }

    // MARK: - History pagination

    /// Loads one older page and prepends it.
    func loadOlder() async {
        guard let client = store?.client, let address, let oldest = oldestSeq, oldest > 1 else {
            hasOlder = false
            return
        }
        guard !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            let page = try await client.sessionPage(
                SessionPageRequest(
                    address: address,
                    throughSeq: throughSeq,
                    beforeSeq: oldest,
                    maxMessages: 60
                )
            )
            _ = timeline.prepend(older: page.records)
            hasOlder = page.hasMore && !page.records.isEmpty
            if let first = page.records.first?.event.seq { oldestSeq = first }
        } catch {
            // Paging past the cursor is the common failure after the host has
            // trimmed a session; stop offering more rather than surfacing it.
            hasOlder = false
        }
    }

    // MARK: - Outbound actions

    /// Adds pictures to the next prompt.
    ///
    /// Downscaled first: a phone photo is many megabytes, and the Host will
    /// shrink it anyway — sending the original just makes the upload slow.
    func addDraftImages(_ images: [UIImage], names: [String] = []) {
        for (index, image) in images.enumerated() {
            let resized = Self.downscaled(image, maximumEdge: 2048)
            guard let data = resized.jpegData(compressionQuality: 0.85) else { continue }
            let name = index < names.count ? names[index] : "photo-\(draftImages.count + 1).jpg"
            draftImages.append(
                DraftImage(
                    mediaType: "image/jpeg",
                    base64: data.base64EncodedString(),
                    name: name,
                    preview: resized
                )
            )
        }
    }

    func removeDraftImage(id: UUID) {
        draftImages.removeAll { $0.id == id }
    }

    func clearDraftImages() {
        draftImages.removeAll()
    }

    /// Scales an image down so its longest edge fits `maximumEdge`.
    private static func downscaled(_ image: UIImage, maximumEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maximumEdge else { return image }
        let scale = maximumEdge / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Submits the composer's text.
    ///
    /// Steer mode interrupts the running turn instead of queueing behind it,
    /// which is how the desktop client's "steer" affordance behaves.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draftImages
        guard !text.isEmpty || !images.isEmpty, let client = store?.client, let session else { return }
        let owner = session.sessionId

        let mode: SessionPromptRequest.Mode = (steerNext && isRunning) ? .steer : .queue
        // Which conversation this text belongs to, fixed here: the user may
        // switch away while the send is in flight, and neither the clear nor a
        // failure's restore may land on whatever happens to be on screen then.
        // Cleared optimistically so the field empties the instant you send, but
        // restored if the host refuses — losing typed text to a transient
        // failure is worse than seeing it come back.
        draft = ""
        drafts.removeValue(forKey: owner)

        // The request id is minted here because the host stores it on the
        // durable message's source; that is what lets the transcript replace
        // this optimistic row instead of showing the message twice.
        let requestId = UUID().uuidString
        timeline.echoUserPrompt(requestId: requestId, text: text)
        scrollSignal += 1
        sendSignal += 1
        isAwaitingTurnStart = true
        // If the host is already mid-turn the message sits in its queue, and
        // `timeline.isTurnOpen` already reports running; otherwise a turn
        // starts within a second. Either way this must not latch forever.
        awaitingTimeout?.cancel()
        awaitingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.isAwaitingTurnStart = false
        }

        // Cleared only once the bytes are on their way; a failed send puts the
        // pictures back alongside the text.
        draftImages.removeAll()

        do {
            try await client.prompt(
                SessionPromptRequest(
                    requestId: requestId,
                    sessionId: session.sessionId,
                    mode: mode,
                    content: Self.promptContent(text: text, images: images)
                )
            )
        } catch {
            isAwaitingTurnStart = false
            // Back to the conversation it was typed in — visible if the user is
            // still there, waiting quietly if they have moved on.
            let restored = Draft(text: text, images: images)
            drafts[owner] = restored
            // `session` was captured by the guard at the top of this function,
            // so it is this send's own session — not whatever is on screen now.
            if session.sessionId == owner {
                if draft.isEmpty { draft = text }
                if draftImages.isEmpty { draftImages = images }
            }
            lastError = ConnectionStore.describe(error)
        }
    }

    /// Uploads one file and tells the agent where it landed.
    ///
    /// The Host cannot receive file bytes — `workspaceFiles/*` is read-only and
    /// `uploadFile` is not served — so the link stages the file on the computer
    /// and the prompt names the path. The agent then reads it with the ordinary
    /// tools it already has.
    func sendFile(named name: String, data: Data) async {
        guard let session, let store else { return }
        let owner = session.sessionId
        isUploadingFile = name
        defer { isUploadingFile = nil }

        do {
            let staged = try await store.uploadFile(
                data: data,
                name: name,
                sessionId: session.sessionId
            )
            // The path is what makes this useful: without it the agent knows a
            // file exists but not where. The prompt belongs to the session the
            // file was staged for, which is not necessarily the one on screen
            // by the time the upload finishes.
            let text = "我发送了一个文件，已保存到：\(staged.path)（\(staged.bytes) 字节）"
            guard session.sessionId == owner else {
                drafts[owner] = Draft(text: text, images: [])
                return
            }
            draft = text
            await send()
        } catch {
            lastError = ConnectionStore.describe(error)
        }
    }

    /// The prompt body: the words, then one part per picture.
    private static func promptContent(text: String, images: [DraftImage]) -> [PromptContentPart] {
        var content: [PromptContentPart] = []
        if !text.isEmpty { content.append(.text(text)) }
        for image in images {
            content.append(.image(mediaType: image.mediaType, data: image.base64, name: image.name))
        }
        return content
    }

    /// Cancels the running turn.
    func cancel() async {
        guard let client = store?.client, let session else { return }
        do {
            try await client.cancel(sessionId: session.sessionId)
            isAwaitingTurnStart = false
        } catch {
            lastError = ConnectionStore.describe(error)
        }
    }

    func rename(to title: String) async {
        guard let client = store?.client, let session else { return }
        do {
            try await client.rename(sessionId: session.sessionId, title: title)
            await refreshSummary()
        } catch {
            lastError = ConnectionStore.describe(error)
        }
    }

    /// Forks the session, returning the new session's id when the host reports it.
    func fork() async -> String? {
        guard let client = store?.client, let session else { return nil }
        do {
            let value = try await client.forkSession(sessionId: session.sessionId)
            return value["sessionId"]?.stringValue ?? value["id"]?.stringValue
        } catch {
            lastError = ConnectionStore.describe(error)
            return nil
        }
    }

    func selectModel(_ selection: ModelSelection) async {
        guard let client = store?.client, let session else { return }
        let previous = currentSelection
        currentSelection = selection
        do {
            try await client.selectModel(sessionId: session.sessionId, selection: selection)
        } catch {
            currentSelection = previous
            lastError = ConnectionStore.describe(error)
        }
    }

    /// Updates the displayed permission preset.
    ///
    /// The preset is owned by the host's session, not by an RPC, so this only
    /// reflects a choice locally; the authoritative value arrives with the next
    /// session projection. It exists so the picker can show intent immediately.
    func setPermissionLocally(_ value: String) {
        currentPermission = value
    }

    /// Answers a pending host prompt.
    ///
    /// The sheet hands over the wire answer it built (`UserQuestionsAnswer`),
    /// because the encoding has rules the caller should not have to know: free
    /// text is its own field, and a single-select answer typed in words carries
    /// no selected labels.
    func answer(_ item: HostEventHub.Pending, answers: UserQuestionsAnswer) async {
        guard let hub else { return }
        do {
            try await hub.answer(item, with: .result(try JSONValue(from: answers)))
        } catch {
            lastError = ConnectionStore.describe(error)
        }
    }

    /// Declines a prompt so the desktop client can handle it.
    func pass(_ item: HostEventHub.Pending) async {
        await hub?.pass(item)
    }

    /// Autocomplete candidates for `@` file references.
    func fileReferences(query: String) async -> [FileReferenceCandidate] {
        guard let client = store?.client, let session else { return [] }
        return (try? await client.fileReferences(agentId: session.sessionId, query: query)) ?? []
    }
}

extension JSONValue {
    /// Re-encodes a value into a JSON value, used to hand typed models to the
    /// dynamic event-result channel.
    init(from model: some Encodable) throws {
        let data = try JSONEncoder().encode(model)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

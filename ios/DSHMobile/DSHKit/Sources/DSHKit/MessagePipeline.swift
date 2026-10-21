import Foundation

/// 多会话内存层枢纽（spec 009 架构决定 §1/§2 / tasks T009 / contracts/memory-pipeline.md）。
///
/// 每会话懒建一个 `SessionPipeline`；对外只暴露契约面：
/// - `snapshots(for:)`：首次订阅立即吐出当前快照（`SnapshotDiff` 的 insert 全量），
///   之后只发增量 diff（insert/remove/update + gap 行生灭合并在同一次 diff）。
///   多订阅者各自一条独立 AsyncStream，互不影响。
/// - `send(text:)`：上行五拍——稳定 UUID clientId → 乐观插入（pending，身份即
///   clientId）→ 落库队列 → 网络（注入的 sender）→ 确认后 tempId→serverId
///   **原地替换**（UUID 身份不变，行高不变，spec 场景 11）。
///
/// 行身份纪律：数据行出现即排版完成（A 类由 SessionPipeline 水合时回填）；
/// 身份 = UUID，排序键 = seq；pending 用合成 seq（Int.max 起递减）排在末尾，
/// 确认后换正式 seq 不换身份。
public actor MessagePipeline {

    // MARK: - 契约类型（contracts/memory-pipeline.md）

    /// 订阅键：磁盘/网络两侧都靠 (scope, sessionId) 定位一个会话。
    public struct SessionRef: Hashable, Sendable {
        public let scope: String
        public let sessionId: String

        public init(scope: String, sessionId: String) {
            self.scope = scope
            self.sessionId = sessionId
        }
    }

    /// 数据行：排版已完成的不可变快照。`id` 是稳定 UUID，状态变化不改身份。
    public struct RenderedMessage: Identifiable, Sendable {
        public enum Status: String, Sendable, Equatable {
            case sent, pending, failed
            /// 已受理、但确认帧永远没来（宿主撤单、轮次以错误结束）。
            /// 与 failed 的区别：不能直接重发（宿主可能已经收下），先核对一次再定。
            case unconfirmed
        }

        public let id: UUID
        /// 排序键：正式消息是服务端 seq；pending 是合成键（见 SessionState）。
        public let seq: Int
        public let record: SessionRecord
        public let status: Status

        public init(id: UUID, seq: Int, record: SessionRecord, status: Status) {
            self.id = id
            self.seq = seq
            self.record = record
            self.status = status
        }
    }

    /// 行：数据行或缺口行（gap 身份 `gap:<start>-<end>` 由区间集派生）。
    public enum Row: Identifiable, Sendable {
        case message(RenderedMessage)
        case gap(GapRow)

        public var id: String {
            switch self {
            case .message(let message): return message.id.uuidString
            case .gap(let gap): return gap.id
            }
        }
    }

    public typealias GapRow = SessionPipeline.GapRow

    /// 一次原子提交（契约：changes 一次应用；anchor 由控件层按视口实况填）。
    public struct SnapshotDiff: Sendable {
        /// 视口顶部首个完整可见行 seq + 行内偏移（唯一位移锚，spec「唯一位移锚」）。
        /// 内存层不知道视口，由接收方在应用时填；内存层恒发 nil。
        public struct Anchor: Sendable, Equatable {
            public let seq: Int
            public let offset: Double

            public init(seq: Int, offset: Double) {
                self.seq = seq
                self.offset = offset
            }
        }

        public let anchor: Anchor?
        public let changes: [Change]

        public enum Change: Sendable {
            case insert([Row])
            case remove([String]) // RowID
            case update([Row])
        }

        public init(anchor: Anchor? = nil, changes: [Change]) {
            self.anchor = anchor
            self.changes = changes
        }
    }

    /// 上行发送的网络面（测试注入假回包）。参数：会话、文本、clientId（同时是
    /// 发给服务端的 requestId——身份只有这一套，spec 场景 11）、是否 steer。
    /// 返回服务端确认的正式记录；返回 nil 表示"已受理，确认走下行回流"——
    /// 下行记录里的 `source.rpcId == clientId` 时由管道原地替换（T022）。
    public typealias Sender = @Sendable (SessionRef, String, UUID, Bool) async throws -> SessionRecord?
    /// 重发前的查重面（T022 重启恢复）：按 clientId 对服务端最新页查一次，
    /// 命中说明崩溃前其实已确认（没落库），只替换不重发。返回 nil = 没查到。
    public typealias ConfirmationLookup = @Sendable (SessionRef, UUID) async -> SessionRecord?
    /// 每会话的取页器工厂（产品适配 TranscriptPageFetcher，测试给假 fetcher）。
    public typealias PageFetchFactory = @Sendable (SessionRef) -> SessionPipeline.PageFetch

    // MARK: - 状态

    let store: MessageStore?  // internal：上行扩展（+Send）要用
    private let fetchFactory: PageFetchFactory
    let sender: Sender // internal：+Send
    let confirmationLookup: ConfirmationLookup? // internal：+Send
    private let frameTick: @Sendable () async -> Void
    let now: @Sendable () -> TimeInterval // internal：+Send
    private let pageSize: Int
    private let hotLimit: Int
    /// 轮次结束后多久把仍在 pending 的行标成「未确认」。留一点余量，是因为
    /// 轮次结束与下一条排队消息被提升成 durable 记录之间有几毫秒到几秒的空隙。
    private let unconfirmedGrace: TimeInterval

    var pipelines: [SessionRef: SessionPipeline] = [:] // internal：+Send 的 flushWrites 要用
    var states: [SessionRef: SessionState] = [:] // internal：+Send

    /// 每会话的聚合状态：行表 + 订阅者 + 泵任务。
    struct SessionState { // internal：+Send
        /// 行表：排序键 → 渲染消息（pending 用 Int.max 起递减的合成键）。
        var rows: [Int: RenderedMessage] = [:]
        /// 下行数据行的身份映射：seq → UUID（身份稳定，重复水合不换 id）。
        var identities: [Int: UUID] = [:]
        /// clientId → 行键（确认时找到要原地替换的行）。pending 与 failed 都留着
        /// ——只有确认（下行 rpcId 命中或 sender 回包）才摘除，这样"标了失败但服务端
        /// 其实已收到"的消息能被下行确认救回来。
        var pendingSeqs: [UUID: Int] = [:]
        var nextSyntheticSeq = Int.max
        var gaps: [GapRow] = []
        var continuations: [UUID: AsyncStream<SnapshotDiff>.Continuation] = [:]
        var pump: Task<Void, Never>?
        /// 轮次结束后的「未确认」扫描（每会话一个，后到的时间点覆盖先到的）。
        var unconfirmedSweep: Task<Void, Never>?
    }

    init(
        store: MessageStore?,
        fetchFactory: @escaping PageFetchFactory,
        sender: @escaping Sender,
        confirmationLookup: ConfirmationLookup? = nil,
        frameTick: @escaping @Sendable () async -> Void = {},
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        pageSize: Int = 50,
        hotLimit: Int = 500,
        unconfirmedGrace: TimeInterval = 20
    ) {
        self.store = store
        self.fetchFactory = fetchFactory
        self.sender = sender
        self.confirmationLookup = confirmationLookup
        self.frameTick = frameTick
        self.now = now
        self.pageSize = pageSize
        self.hotLimit = hotLimit
        self.unconfirmedGrace = unconfirmedGrace
    }

    // MARK: - 会话访问（产品/测试入口）

    /// 某会话的 SessionPipeline（懒建）。拉取/推送合并在这一层之下。
    public func pipeline(for session: SessionRef) -> SessionPipeline {
        if let pipeline = pipelines[session] { return pipeline }
        let store = self.store
        let pipeline = SessionPipeline(
            scope: session.scope, sessionId: session.sessionId,
            store: store, fetch: fetchFactory(session),
            frameTick: frameTick, now: now,
            pageSize: pageSize, hotLimit: hotLimit,
            flushWrites: { changes in
                // 落库低优先级批量写（spec §3：崩丢由「取用失败即拉取」兜底）。
                guard let store else { return }
                Task { try? await store.applyWrites(changes) }
            })
        pipelines[session] = pipeline
        return pipeline
    }

    /// 某会话热窗口的最新 seq（nil = 还没建管道/还没有窗口）。
    ///
    /// 给 App 侧的空回包注入判方向用（`-DSHProbeEmptyPage`）：注入只许打在
    /// 「往更早方向」的请求上，而那件事只有热窗口知道。
    public func hotNewest(for session: SessionRef) async -> Int? {
        guard let pipeline = pipelines[session] else { return nil }
        return await pipeline.hotNewestSeq
    }

    // MARK: - 快照订阅（契约面）

    /// 订阅某会话的快照流。首帧是当前快照（可能只有 gap 行），之后是增量。
    public func snapshots(for session: SessionRef) async -> AsyncStream<SnapshotDiff> {
        let subscriptionID = UUID()
        let initial = await ensurePrimedState(for: session)
        return AsyncStream { continuation in
            states[session]?.continuations[subscriptionID] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscription(subscriptionID, for: session) }
            }
        }
    }

    private func removeSubscription(_ id: UUID, for session: SessionRef) {
        states[session]?.continuations.removeValue(forKey: id)
    }

    /// 懒建聚合状态：用 SessionPipeline 现有快照 prime（订阅前已水合的数据
    /// 不能丢），再启动泵（把 SessionPipeline 的 Diff 翻译成 SnapshotDiff 广播）。
    /// 返回该订阅的首帧（当前全量）。
    func ensurePrimedState(for session: SessionRef) async -> SnapshotDiff {
        if let state = states[session] {
            return snapshotDiff(state)
        }
        let pipeline = pipeline(for: session)
        let (records, gaps) = await pipeline.snapshot()
        var state = SessionState()
        for record in records {
            let id = UUID()
            state.identities[record.event.seq] = id
            state.rows[record.event.seq] = RenderedMessage(
                id: id, seq: record.event.seq, record: record, status: .sent)
        }
        state.gaps = gaps
        states[session] = state
        let pump = Task { [weak self] in
            for await diff in await pipeline.diffs() {
                await self?.applyPipelineDiff(diff, for: session)
            }
        }
        states[session]?.pump = pump
        return snapshotDiff(state)
    }

    /// 当前全量行 → 首帧快照（insert 一次给出，升序）。
    private func snapshotDiff(_ state: SessionState) -> SnapshotDiff {
        let rows = currentRows(state)
        return SnapshotDiff(changes: rows.isEmpty ? [] : [.insert(rows)])
    }

    /// 全量有序行：数据行按 seq 升序，gap 行按区间位置插入。
    private func currentRows(_ state: SessionState) -> [Row] {
        let messages = state.rows.sorted { $0.key < $1.key }.map { Row.message($0.value) }
        var result = messages
        for gap in state.gaps.sorted(by: { $0.start < $1.start }) {
            let index = result.firstIndex { row in
                if case .message(let message) = row { return message.seq > gap.start }
                return false
            } ?? result.count
            result.insert(.gap(gap), at: index)
        }
        return result
    }

    // MARK: - 下行：SessionPipeline.Diff → SnapshotDiff 广播

    private func applyPipelineDiff(_ diff: SessionPipeline.Diff, for session: SessionRef) async {
        guard var state = states[session] else { return }
        var changes: [SnapshotDiff.Change] = []
        /// 下行确认到的上行消息（rpcId 命中 pending/failed 行）：落库确认。
        var confirmations: [(UUID, SessionRecord)] = []

        let removed = applyRemovals(diff.removed, state: &state)
        if !removed.isEmpty { changes.append(.remove(removed)) }

        // pending 确认后 WSS 回流同 seq：行已存在 → update，否则 insert（身份稳定）。
        var insertedRows: [Row] = []
        var reclassifiedUpdates: [Row] = []
        for record in diff.inserted {
            if let clientId = Self.confirmationClientId(of: record),
               let confirmed = confirmPendingRow(
                   clientId: clientId, with: record, state: &state) {
                reclassifiedUpdates.append(confirmed)
                confirmations.append((clientId, record))
                continue
            }
            let id = state.identities[record.event.seq] ?? {
                let id = UUID()
                state.identities[record.event.seq] = id
                return id
            }()
            let message = RenderedMessage(id: id, seq: record.event.seq, record: record, status: .sent)
            let isNew = state.rows[record.event.seq] == nil
            state.rows[record.event.seq] = message
            if isNew { insertedRows.append(.message(message)) } else { reclassifiedUpdates.append(.message(message)) }
        }
        if !insertedRows.isEmpty { changes.append(.insert(insertedRows)) }

        var updatedRows: [Row] = reclassifiedUpdates
        for record in diff.updated {
            // 同 seq 的再次到达也可能是确认：正式记录先被水合/落盘、pending 行后插
            // （restorePending 的顺序就是如此）时，durable 记录再送一遍走的是 update。
            // 以前只认 inserted，这条失败行从此没有任何机会被救回。
            if let clientId = Self.confirmationClientId(of: record),
               let confirmed = confirmPendingRow(clientId: clientId, with: record, state: &state) {
                updatedRows.append(confirmed)
                confirmations.append((clientId, record))
                continue
            }
            guard let id = state.identities[record.event.seq] else { continue }
            let message = RenderedMessage(id: id, seq: record.event.seq, record: record, status: .sent)
            state.rows[record.event.seq] = message
            updatedRows.append(.message(message))
        }
        if !updatedRows.isEmpty { changes.append(.update(updatedRows)) }

        // gap 行生灭与数据行变化合并在同一次 diff（契约规则 4）。
        changes.append(contentsOf: gapChanges(from: state.gaps, to: diff.gaps))
        state.gaps = diff.gaps

        states[session] = state
        guard !changes.isEmpty else { return }
        broadcast(SnapshotDiff(changes: changes), to: state.continuations)
        await enqueueConfirmations(confirmations, for: session)
        // 轮次结束是一条硬边界：排队消息要么在下一轮开始时被提升成 durable 记录，
        // 要么被宿主撤回（日志里 `agent/inbox/spliced` removedCount=1）。撤回帧不带
        // 被撤项的身份，手机端换不成"这一行作废"，于是这里用轮次结束当判据：
        // 过了宽限期仍是 pending 的行，标成「未确认」，不再声称"等待开始"。
        if diff.inserted.contains(where: { $0.event.type == "turn/end" }) {
            scheduleUnconfirmedSweep(for: session)
        }
    }

    /// 排一次「未确认」扫描（宽限期后执行；同一会话只留最后一次）。
    private func scheduleUnconfirmedSweep(for session: SessionRef) {
        guard var state = states[session] else { return }
        state.unconfirmedSweep?.cancel()
        let grace = unconfirmedGrace
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.markUnconfirmed(for: session)
        }
        state.unconfirmedSweep = task
        states[session] = state
    }

    /// 把仍在 pending 的行标成「未确认」。
    ///
    /// 保留 `pendingSeqs` 映射：迟到的下行确认仍然照常把它救成 sent
    /// （`confirmPendingRow` 只认 pendingSeqs，不认状态）。
    func markUnconfirmed(for session: SessionRef) {
        guard var state = states[session] else { return }
        var updates: [Row] = []
        for (clientId, seq) in state.pendingSeqs {
            guard let row = state.rows[seq], row.status == .pending else { continue }
            let message = RenderedMessage(id: row.id, seq: seq, record: row.record, status: .unconfirmed)
            state.rows[seq] = message
            state.pendingSeqs[clientId] = seq
            updates.append(.message(message))
        }
        states[session] = state
        guard !updates.isEmpty else { return }
        broadcast(SnapshotDiff(changes: [.update(updates)]), to: state.continuations)
    }

    /// 按 seq 核销行（返回被删行的 id 列表，供 .remove 广播）。
    private func applyRemovals(_ seqs: [Int], state: inout SessionState) -> [String] {
        seqs.compactMap { seq -> String? in
            guard let id = state.identities[seq] else { return nil }
            state.identities.removeValue(forKey: seq)
            state.rows.removeValue(forKey: seq)
            return id.uuidString
        }
    }

    /// 下行确认的落库（pending 行换正式行）。按序 await：confirm 不得抢在
    /// 该消息此前的 upsertPending 之前进写队列。
    private func enqueueConfirmations(
        _ confirmations: [(UUID, SessionRecord)], for session: SessionRef
    ) async {
        guard !confirmations.isEmpty else { return }
        let pipeline = pipeline(for: session)
        for (clientId, record) in confirmations {
            await pipeline.enqueueWrite(.confirmPending(
                scope: session.scope, sessionId: session.sessionId,
                clientId: clientId.uuidString, record: record), key: record.event.seq)
        }
    }

    /// T022 下行确认：durable 用户消息的 source.rpcId 就是发送时的 clientId
    /// （同一套 UUID 身份）。命中则 tempId→serverId 原地替换，不产生第二行；
    /// 标了 failed 但实际已发出的也在此救回。返回替换后的行（update 广播用）。
    private func confirmPendingRow(
        clientId: UUID, with record: SessionRecord, state: inout SessionState
    ) -> Row? {
        guard let synthetic = state.pendingSeqs[clientId] else { return nil }
        state.pendingSeqs.removeValue(forKey: clientId)
        state.rows.removeValue(forKey: synthetic)
        let message = RenderedMessage(id: clientId, seq: record.event.seq, record: record, status: .sent)
        state.rows[record.event.seq] = message
        state.identities[record.event.seq] = clientId
        return .message(message)
    }

    /// 一条下行记录是不是某条上行消息的确认：durable 用户消息且 source.rpcId
    /// 是个 UUID（发送时把 clientId 当 requestId 发出，host 原样落在 source 上）。
    static func confirmationClientId(of record: SessionRecord) -> UUID? {
        guard case .userMessage(let message) = ChatEventDecoder.decode(record.event),
              message.isFromHuman, let rpcId = message.rpcId else { return nil }
        return UUID(uuidString: rpcId)
    }

    /// 两组 gap（派生量）比对出生灭：消失的整体 remove，新生/状态变化 insert/update。
    private func gapChanges(from old: [GapRow], to new: [GapRow]) -> [SnapshotDiff.Change] {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        let removedIDs = old.filter { newByID[$0.id] == nil }.map(\.id)
        var changes: [SnapshotDiff.Change] = []
        if !removedIDs.isEmpty { changes.append(.remove(removedIDs)) }
        let inserted = new.filter { oldByID[$0.id] == nil }.map(Row.gap)
        if !inserted.isEmpty { changes.append(.insert(inserted)) }
        let updated = new.filter { oldByID[$0.id] != nil && oldByID[$0.id] != $0 }.map(Row.gap)
        if !updated.isEmpty { changes.append(.update(updated)) }
        return changes
    }

    func broadcast(
        _ diff: SnapshotDiff,
        to continuations: [UUID: AsyncStream<SnapshotDiff>.Continuation]
    ) {
        for continuation in continuations.values {
            continuation.yield(diff)
        }
    }

    // MARK: - 冷启动预取瀑布（spec「冷启动流程」/ tasks T011）

    /// 一个预取目标：会话 + 列表已知的最新游标（host 的 asOfSeq 或磁盘层 newestSeq）。
    public struct PrefetchTarget: Sendable, Hashable {
        public let session: SessionRef
        public let newestSeq: Int

        public init(session: SessionRef, newestSeq: Int) {
            self.session = session
            self.newestSeq = newestSeq
        }
    }

    /// 按列表顺序预取前 `limit` 个会话的最新页（[newestSeq-P+1, newestSeq]，页对齐
    /// 由 SessionPipeline 负责）：区间命中读磁盘、缺口网络按页拉；并发上限
    /// `concurrency`（spec：3–4 个会话）。`persistedRanges` 是磁盘层持久化的区间集，
    /// 采纳后命中段零网络。单个会话失败静默——磁盘只是缓存，取用失败即拉取兜底，
    /// 预取不许成为错误来源。用户点开的会话由调用方传 `.jump`，抢占在途预取。
    public func prefetchLatestPages(
        _ targets: [PrefetchTarget],
        persistedRanges: [SessionRef: RangeIndex] = [:],
        limit: Int = 10,
        concurrency: Int = 3,
        priority: SessionPipeline.FetchPriority = .prefetch
    ) async {
        let selected = targets.filter { $0.newestSeq > 0 }.prefix(limit)
        var iterator = selected.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while let target = iterator.next() {
                if running >= concurrency {
                    await group.next()
                    running -= 1
                }
                running += 1
                group.addTask {
                    await self.prefetchLatestPage(target, persistedRanges: persistedRanges, priority: priority)
                }
            }
            await group.waitForAll()
        }
    }

    /// 单会话最新页水合：采纳持久化区间 → 「取不到就拉」→ 区间集回写磁盘层
    /// （下次冷启动预取判定直接命中，data-model 的 ranges_json）。
    private func prefetchLatestPage(
        _ target: PrefetchTarget,
        persistedRanges: [SessionRef: RangeIndex],
        priority: SessionPipeline.FetchPriority
    ) async {
        let pipeline = pipeline(for: target.session)
        if let persisted = persistedRanges[target.session] {
            await pipeline.adoptPersistedRanges(persisted)
        }
        let lower = max(1, target.newestSeq - pageSize + 1)
        _ = try? await pipeline.records(in: lower...target.newestSeq, priority: priority)
        // 最新页落地后 coverageRevision 才等于会话最新号；此时装载持久化的
        // 已知为空结论，旧版本的记录在装载时被过滤掉。
        await pipeline.adoptPersistedKnownEmpty()
        if let store {
            let ranges = await pipeline.ranges
            try? await store.saveRanges(
                scope: target.session.scope, sessionId: target.session.sessionId, ranges: ranges)
        }
    }
}

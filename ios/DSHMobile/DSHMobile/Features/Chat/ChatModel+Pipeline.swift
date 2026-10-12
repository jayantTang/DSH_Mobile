import DSHKit
import Foundation

/// 009 渲染数据源接线（tasks T013/T016，spec 009「UI 刷新推导」场景 4/5/6）。
///
/// `ChatModel` 已超 500 行，所以「订阅 MessagePipeline 快照 → 折叠 → 落回时间线」
/// 整段在新文件里：桥（`ChatPipelineBridge`）持有订阅任务与重建状态，
/// `ChatModel` 主文件只留存储属性与几个写私有成员的落点方法。
///
/// 纪律：
/// - 数据行经现有 `ChatTimeline` 折叠成 `TimelineItem`（008 的行身份与折叠语义不变）；
///   `.gap` 行按同一身份（`gap:<start>-<end>`）映射成缺口占位行。
/// - 折叠是重活，离开主线程做；代数戳保证只有最新一次重建落地（慢折叠不得覆盖新快照）。
/// - 用户动作转发：向上翻页 → `records(in:, .userVisible)`；跳转 → `.jump`；
///   失败缺口点击 → `SessionPipeline.retry`（3 次重试上限由管道接管，UI 只渲染状态）。
extension ChatModel {

    /// 渲染数据源是否已切到 MessagePipeline（决定宿主走原子 reconcile 与缺口行渲染）。
    var pipelineActive: Bool { pipelineBridge != nil }

    /// 打开会话时启动订阅（open() 在 `warmMessageLayer` 之后调用：地址簿已登记、
    /// 最新页已按 .jump 插队水合，首帧快照通常直接有数据）。
    func startPipelineSubscription(for summary: SessionSummary) {
        pipelineBridge?.stop()
        pipelineBridge = nil
        guard let pipeline = messageLayer?.pipeline, let scope = sessionScope else { return }
        let ref = MessagePipeline.SessionRef(scope: scope, sessionId: summary.sessionId)
        pipelineBridge = ChatPipelineBridge(model: self, pipeline: pipeline, ref: ref)
        // T022 重启恢复：上次没发出去的消息（磁盘 status='pending'）以「未发出」
        // 呈现并进时间线，管道内部各尝试重发一次（重发前按 clientId 查重）。
        Task { await pipeline.restorePending(for: ref) }
    }

    /// 失败用户消息「点击重发」（T022）：行身份 `user-<clientId>` 去掉前缀就是
    /// 管道的稳定 UUID。重发走管道状态机；失败只回错误条，行保持 failed。
    func retrySend(rowId: String) async {
        guard let bridge = pipelineBridge, rowId.hasPrefix("user-"),
              let clientId = UUID(uuidString: String(rowId.dropFirst("user-".count)))
        else { return }
        // 失败不用另外上报：行仍保持 failed（可再点），这就是反馈。
        try? await bridge.resend(clientId: clientId)
    }

    /// 关会话/换连接时停掉订阅（订阅的 onTermination 会自行从管道注销）。
    func stopPipelineSubscription() {
        pipelineBridge?.stop()
        pipelineBridge = nil
    }

    /// 缺口行「加载失败，点击重试」（T016：清计数后重拉，3 次上限仍由管道把守）。
    func retryGap(start: Int, end: Int) async {
        await pipelineBridge?.retryGap(start: start, end: end)
    }

    /// 管道窗口里真的有这条 seq 吗（跳转要不要换窗口；见 `ChatPipelineBridge.holds`）。
    /// 管道没起来（老路径）时恒 false——那种情况由本地窗口/搜索缓冲决定。
    func pipelineHolds(seq: Int) -> Bool {
        pipelineBridge?.holds(seq: seq) ?? false
    }
}

/// 每会话一份的 009 接线状态：快照里的有序记录、缺口行、折叠代数。
///
/// 拆文件：用户驱动的取页与追平（向上翻页 / 顶部缺口行 / 尾部追平）在
/// `ChatModel+PipelineFetch.swift`；这里留订阅、折叠落地、跳转与上行。
/// 被那个扩展用到的成员因此是 internal 而不是 private（沿用 DSHKit 里
/// `SessionPipeline+Paging` 的同一做法）。
@MainActor
final class ChatPipelineBridge {

    weak var model: ChatModel? // internal：+PipelineFetch（取页半边）要用
    private let pipeline: MessagePipeline
    private let ref: MessagePipeline.SessionRef
    /// 会话级管道（拿一次存下来：取页/重试/读 topExhausted 都走它）。
    var session: SessionPipeline? // internal：+PipelineFetch 要用

    /// 快照数据行的唯一事实来源（seq → 记录；与 MessagePipeline 的广播保持一致）。
    var records: [Int: SessionRecord] = [:] // internal：+PipelineFetch 要用
    /// 行 id → seq（.remove 按行 id 核销用）。
    private var rowSeqs: [String: Int] = [:]
    /// T022 上行状态（seq → pending/failed/sent）：折叠后回标到时间线行
    /// （pending 回声样式、failed 可点重发），状态变化不改行身份。
    private var sendStatuses: [Int: MessagePipeline.RenderedMessage.Status] = [:]
    /// 当前缺口行（派生量的最新一份）。
    private var gaps: [SessionPipeline.GapRow] = []
    /// 管道判定的「已到最早」（hasMore=false / clamped；网络失败永不置位）。
    private var topExhausted = false

    private var subscription: Task<Void, Never>?
    /// 折叠代数：慢折叠回来时若已过期就丢弃（新快照优先）。
    private var foldGeneration = 0
    /// T023 跳转等待（事件驱动）：等「某 seq 折进时间线」的 waiter 与其超时任务。
    /// 落地在 `refold` 的整树重建分支之后由 `resolveRebaseWaiters()` 唤醒。
    private var rebaseWaiters: [UUID: (seq: Int, continuation: CheckedContinuation<String?, Never>)] = [:]
    private var rebaseTimeouts: [UUID: Task<Void, Never>] = [:]
    /// 「向上翻页」进行中（顶部缺口行 spinner 由它驱动，镜像进 model.isLoadingOlder）。
    var isLoadingOlder = false // internal：+PipelineFetch 要用
    /// 最近一次取页失败原因（顶部缺口行据此转「点击重试」）。
    var olderFailure: String? // internal：+PipelineFetch 要用
    /// 失败后的一次自动补试（沿用 007 FR-004 语义：只补一次，不循环）。
    var didAutoRetry = false // internal：+PipelineFetch 要用
    /// T037：锚点不可知时挂起的「向上翻页」——首个数据落地后自动补一次
    /// （没有它，读者会在管道还没数据时拉了却什么都没发生）。置位/清位都在
    /// `ChatModel+PipelineFetch.swift` 与 `apply`。
    var pendingOlderRequest = false // internal：+PipelineFetch 要用

    /// 一次「向上翻页」拉多少条（与管道页大小一致）。
    static let pageSize = 50 // internal：+PipelineFetch / 尾部追平预算要用

    /// 017：一次向上翻要几页。一页一次往返就是"每屏等一次"的来源，所以一次多要几屏；
    /// 上限同时受连接器 `MAX_CHUNKS_PER_CALL`（12 块）与单帧字节预算约束，3 页留有余量。
    static let pagesPerFetch = 3
    /// 点胶囊直跳最新的降级阈值（页）：超过就丢中间段（spec 场景 7）。
    static let catchUpPageBudget = 5 // internal：+PipelineFetch 要用

    init(model: ChatModel, pipeline: MessagePipeline, ref: MessagePipeline.SessionRef) {
        self.model = model
        self.pipeline = pipeline
        self.ref = ref
        subscribe()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        // T037：挂起的「向上翻页」（加载中 / 已到最早）不能跨会话留着——桥本身随
        // 会话丢弃，但 `model.isLoadingOlder` 是共享的，留着会挡住新会话的自动补页。
        pendingOlderRequest = false
        isLoadingOlder = false
        model?.notePipelineLoadingOlder(false)
        model?.notePipelineOlderFailure(nil)
        // 关会话时唤醒还挂着的跳转 waiter，不让 continuation 泄漏。
        let waiters = rebaseWaiters
        rebaseWaiters.removeAll()
        for task in rebaseTimeouts.values { task.cancel() }
        rebaseTimeouts.removeAll()
        for waiter in waiters.values { waiter.continuation.resume(returning: nil) }
    }

    // MARK: - 订阅

    private func subscribe() {
        subscription = Task { @MainActor [weak self] in
            guard let self else { return }
            let session = await self.pipeline.pipeline(for: self.ref)
            self.session = session
            let stream = await self.pipeline.snapshots(for: self.ref)
            for await diff in stream {
                if Task.isCancelled { return }
                self.apply(diff)
            }
        }
    }

    /// 一次 SnapshotDiff（可能同时含头部插入 + gap 生灭 + 尾部更新）落到
    /// 桥状态，然后触发一次重建——宿主那边由 reconcile 作为一次原子更新提交。
    private func apply(_ diff: MessagePipeline.SnapshotDiff) {
        var messagesChanged = false
        var gapsChanged = false
        var hasRemove = false
        /// T020 流式快进路候选：diff 里只有 provisional 行的 update 时，
        /// 只改那一行的文本，不整树重折（每 token 一批 diff 时整树重折是主开销）。
        var streamUpdates: [(seq: Int, text: String, reasoning: String)] = []
        var onlyStreamingUpdates = true
        // 尾部到达计数（T018 未读数）：只数"比现有最大 seq 还新"的插入——
        // 向上翻页的 prepend 与首帧快照都不算（后者由 maxSeqBefore == nil 排除）。
        // 最大值只在**正式 seq**里取：pending/failed 回声用 Int.max 起递减的合成
        // seq，混进来会把 maxSeqBefore 顶到天花板——之后胶囊永不出现（T018）。
        let maxSeqBefore = records.keys
            .filter { sendStatuses[$0] != .pending && sendStatuses[$0] != .failed }
            .max()
        var tailArrivals = 0
        for change in diff.changes {
            switch change {
            case .remove(let ids):
                hasRemove = true
                onlyStreamingUpdates = false
                for id in ids {
                    if let seq = rowSeqs.removeValue(forKey: id) {
                        records.removeValue(forKey: seq)
                        sendStatuses.removeValue(forKey: seq)
                        messagesChanged = true
                    } else if gaps.contains(where: { $0.id == id }) {
                        gaps.removeAll { $0.id == id }
                        gapsChanged = true
                    }
                }
            case .insert(let rows), .update(let rows):
                if case .insert = change { onlyStreamingUpdates = false }
                for row in rows {
                    switch row {
                    case .message(let message):
                        if let before = maxSeqBefore, message.seq > before { tailArrivals += 1 }
                        // T022 原地替换：同一行 id 换 seq（tempId→serverId）时，
                        // 旧合成 seq 的记录必须核销，否则折叠出两行。
                        if let oldSeq = rowSeqs[message.id.uuidString], oldSeq != message.seq {
                            records.removeValue(forKey: oldSeq)
                            sendStatuses.removeValue(forKey: oldSeq)
                        }
                        records[message.seq] = message.record
                        rowSeqs[message.id.uuidString] = message.seq
                        sendStatuses[message.seq] = message.status
                        messagesChanged = true
                        if onlyStreamingUpdates,
                           let content = Self.streamingContent(of: message.record) {
                            streamUpdates.append((message.seq, content.text, content.reasoning))
                        }
                    case .gap(let gap):
                        onlyStreamingUpdates = false
                        if let index = gaps.firstIndex(where: { $0.id == gap.id }) {
                            gaps[index] = gap
                        } else {
                            gaps.append(gap)
                        }
                        gapsChanged = true
                    }
                }
            }
        }
        if tailArrivals > 0 { model?.noteTailArrivals(tailArrivals) }
        // T037：锚点还不可知时挂起的「向上翻页」（管道刚就绪、首帧数据刚到）——
        // 数据一落地就补一次，不让读者停在「加载中」。清位后置 false 再进
        // loadOlder（它自己要求不在飞）。
        if pendingOlderRequest, !records.isEmpty {
            pendingOlderRequest = false
            isLoadingOlder = false
            model?.notePipelineLoadingOlder(false)
            Task { @MainActor [weak self] in await self?.loadOlder() }
        }
        // 快进路：全部增量都是"流式行文本变长"且缺口/删除都没动 → 单行更新。
        // 提交由 reconcile 走 008 统一锚一次修正（T021），不单独触发布局。
        if onlyStreamingUpdates, !hasRemove, !gapsChanged, !streamUpdates.isEmpty,
           let model, streamUpdates.allSatisfy({
               model.applyStreamingRow(seq: $0.seq, text: $0.text, reasoning: $0.reasoning)
           }) {
            return
        }
        refold(messagesChanged: messagesChanged, gapsChanged: gapsChanged)
    }

    /// provisional 记录的流式内容（text/reasoning）；非流式记录返回 nil。
    /// 判定只看**本机**标记（`AssistantMessage.isProvisional`）——管道在
    /// SessionPipeline+Streaming 里打的；宿主的 `data.stream` 是原始模型块日志，
    /// 不是流式标记（spec 011）。
    private static func streamingContent(of record: SessionRecord) -> (text: String, reasoning: String)? {
        guard case .assistantMessage(let message) = ChatEventDecoder.decode(record.event),
              message.isProvisional else { return nil }
        var text = ""
        var reasoning = ""
        for block in message.content {
            switch block {
            case .text(let value): text += value
            case .reasoning(let value): reasoning += value
            default: break
            }
        }
        return (text, reasoning)
    }

    // MARK: - 折叠与落地

    /// 重建：读 topExhausted → 折叠（离主线程）→ 代数校验 → 落回 model。
    /// 只有缺口变化时跳过整树折叠（spinner → 点击重试不碰数据行）。
    func refold(messagesChanged: Bool, gapsChanged: Bool) { // internal：+PipelineFetch 要用
        guard messagesChanged || gapsChanged else { return }
        foldGeneration += 1
        let generation = foldGeneration
        let snapshot = records.sorted { $0.key < $1.key }.map(\.value)
        let currentGaps = gaps
        let statuses = sendStatuses
        Task { @MainActor [weak self] in
            guard let self, let model = self.model else { return }
            let exhausted = await self.session?.topExhausted ?? false
            let gapItems = self.gapItems(currentGaps, topExhausted: exhausted)
            guard messagesChanged else {
                model.applyPipelineGaps(gapItems)
                return
            }
            let folded = await Task.detached(priority: .userInitiated) {
                var timeline = ChatTimeline()
                _ = timeline.reset(with: snapshot)
                // T022：发送状态回标（pending 回声样式 / failed 可点重发），
                // 状态变化不改行身份、不改行高（spec 场景 11）。
                timeline.markSendStates(statuses)
                return timeline
            }.value
            guard generation == self.foldGeneration else { return }
            self.topExhausted = exhausted
            model.applyPipelineRebuild(
                folded, gaps: gapItems,
                topExhausted: exhausted, oldestSeq: self.records.keys.min())
            // T023：命中行已随这次折叠落进时间线，唤醒等待跳转的 waiter。
            self.resolveRebaseWaiters()
        }
    }

    /// 缺口行集合：管道派生的中间缺口 + 顶部合成行（向上拉的 spinner 与中间
    /// 缺口同机制）。尾部追平（T018/T019）期间再补一行合成**底部**缺口行。
    private func gapItems(
        _ pipelineGaps: [SessionPipeline.GapRow], topExhausted: Bool
    ) -> [TimelineItem] {
        var items = pipelineGaps.map { gap in
            ChatTimeline.gapItem(start: gap.start, end: gap.end, status: Self.map(gap.status))
        }
        if let top = topGapItem(topExhausted: topExhausted) {
            items.insert(top, at: 0)
        }
        if model?.isCatchingUpTail == true {
            // seq 取 Int.max-1：合成身份，排序恒在最后，不与任何真实缺口/数据行撞键。
            items.append(ChatTimeline.gapItem(start: .max - 1, end: .max - 1, status: .loading))
        }
        return items
    }

    /// 顶部合成行：已到最早（仅 topExhausted）> 失败可重试 > 加载中。
    /// 实现在 `ChatModel+PipelineFetch.swift`（取页半边）。

    private static func map(_ status: SessionPipeline.GapRow.Status) -> TimelineItem.GapStatus {
        switch status {
        case .loading: return .loading
        case .failed(let retryable): return .failed(retryable: retryable)
        case .exhausted: return .exhausted
        }
    }

    // MARK: - 用户动作（转发管道）

    /// 把**本地库**读出来的一段并进管道（搜索上下文用，0 网络）。
    ///
    /// 走与 follow 下行同一条合并路径（`SessionPipeline.apply(events:)`：热窗口 +
    /// 区间集 + 一次 diff）。为什么非并不可：`refold` 是
    /// `timeline.reset(with: 管道 records)`，只 prepend 进时间线的行会被下一次折叠
    /// 整段抹掉——命中行随之消失，跳转过去之后视口又掉回尾部
    ///（2026-10-11 用例 49 run 20261011-210558：`list.settle anchor=reasoning-1643-0`
    /// 之后紧接的 refold 把 rows 从 100 收到 98）。本地库里的记录是"已经存在的事实"，
    /// 并进管道与磁盘水合同一条理，不发网络、不改身份。
    func absorb(records: [SessionRecord]) async {
        guard let session, !records.isEmpty else { return }
        await session.apply(events: records.map(\.event))
    }

    /// 管道窗口里**真的装着**这条 seq 吗——跳转要不要换窗口的判据。
    ///
    /// 只看管道自己的 `records`（+ 缺口），**不看** `model.timeline.items`：
    /// 搜索命中会把命中附近的一段 prepend 进时间线（`loadContextForHits`），
    /// 那一段在 `absorb` 之前并不属于管道，下一次折叠就被抹掉。
    ///
    /// 2026-10-11 用例 49 的「点结果后视口停在 seq≈2400」就是这么来的
    ///（run 20261011-210558）：命中 1685 靠这段临时的 prepend 被判成"窗口内"，
    /// 跳转跳过换窗口、梯子也确实滚过去了（`list.settle anchor=reasoning-1643-0`），
    /// 但紧接着的 refold（rows 100→98）把目标行从时间线里拿掉，视口掉回尾部。
    func holds(seq: Int) -> Bool {
        guard let oldest = records.keys.min(), let newest = records.keys.max(),
              seq >= oldest, seq <= newest else { return false }
        // 窗口内的缺口不算"装着"：那一行 refold 之后是缺口占位，没有内容行可跳。
        // 顶部合成行（`gap:0-0`）不在 seq 正区间里，不参与。
        return !gaps.contains { seq >= $0.start && seq <= $0.end }
    }

    /// 跳转（.jump）：抢占在途低优预取，只拉目标附近一段；返回命中行的 id。
    ///
    /// 等待是**事件驱动**而非轮询（T023 收口）：本地命中直接返回行 id；否则先
    /// 登记「等 seq 落地」的 waiter，再向管道要页——快照 diff → 整树折叠落进
    /// 时间线的那一刻（`refold` 落地分支调 `resolveRebaseWaiters()`）解析出
    /// 命中行并唤醒 waiter。3 秒超时兜底（水合失败 / 目标已被裁剪等），
    /// 超时返回 nil，视图侧的滚动梯子照旧兜底。
    func rebase(around seq: Int, leading: Int, limit: Int) async -> String? {
        guard let model, let session else { return nil }
        // 本地命中（行已在**管道窗口**里）直接渲染，不等水合（spec「搜索策略」2）。
        // 必须精确归属：`row(forSeq:)` 把窗口外命中钳到窗口第一行，误当本地
        // 命中会跳过换窗口拉取——搜索跳转因此成为空操作（009 场景⑥）。
        // 归属判据必须用 `holds(seq:)`（只看管道自己的 records），不能用
        // `model.timeline.items`：搜索上下文 prepend 进去的行不在管道里，
        // refold 一到就没了（见 `holds` 的头注）。
        if holds(seq: seq),
           let row = TranscriptHitLocator.row(exactlyForSeq: seq, in: model.timeline.items) {
            return row.id
        }
        let upper = seq + leading
        let lower = max(1, upper - limit + 1)
        // T027 修补（US8 报告的同构问题）：跳页只拉目标对齐页，目标与当前窗口
        // 之间的缺口不在任何在飞拉取里，会停在 .loading 永远转圈——与 catchUp
        // 的降级分支同构，同样置为可重试失败（点它才拉，符合跳页省流量语义）。
        let windowOldest = records.keys.min()
        let windowNewest = records.keys.max()
        async let landed = waitForRebaseRow(seq: seq)
        do {
            let fetched = try await session.records(in: lower...upper, priority: .jump)
            ViewportProbe.note("search.rebase.fetched", [
                "seq": String(seq), "range": "\(lower)-\(upper)",
                "count": String(fetched.count),
                "first": String(fetched.first?.event.seq ?? -1),
                "last": String(fetched.last?.event.seq ?? -1),
            ], force: true)
        } catch {
            // 拉取失败必须可见（T016 同款纪律）：waiter 超时只会返回 nil，
            // 没有这条 note 时跳转静默落空，无法分辨"没拉到"还是"没等到"。
            ViewportProbe.note("search.rebase.failed", [
                "seq": String(seq), "range": "\(lower)-\(upper)",
                "reason": String(describing: error),
            ], force: true)
        }
        if let windowOldest, upper + 1 <= windowOldest - 1 {
            await session.abandonGap((upper + 1)...(windowOldest - 1))
        }
        if let windowNewest, windowNewest + 1 <= lower - 1 {
            await session.abandonGap((windowNewest + 1)...(lower - 1))
        }
        return await landed
    }

    /// 等一次整树折叠把 `seq` 折进时间线；落地返回行 id，超时（3s）返回 nil。
    private func waitForRebaseRow(seq: Int) async -> String? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            rebaseWaiters[id] = (seq: seq, continuation: continuation)
            // 超时兜底：管道水合失败或快照里没有这条 seq 时，不能挂住跳转。
            rebaseTimeouts[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let waiter = self.rebaseWaiters.removeValue(forKey: id)
                else { return }
                self.rebaseTimeouts.removeValue(forKey: id)
                waiter.continuation.resume(returning: nil)
            }
        }
    }

    /// 整树折叠落地后调用：时间线里已出现 waiter 等的 seq 就解析行 id 并唤醒。
    private func resolveRebaseWaiters() {
        guard !rebaseWaiters.isEmpty, let model else { return }
        for (id, waiter) in rebaseWaiters {
            // 同上（精确归属）：钳制版会在目标页未落地时把 waiter 解析到窗口
            // 第一行——跳转落到错行，重试梯子还以为已成功。
            guard let row = TranscriptHitLocator.row(exactlyForSeq: waiter.seq, in: model.timeline.items)
            else { continue }
            rebaseWaiters.removeValue(forKey: id)
            rebaseTimeouts.removeValue(forKey: id)?.cancel()
            waiter.continuation.resume(returning: row.id)
        }
    }

    /// 预算裁剪同步（008 FR-002）：模型丢到哪条，桥里的记录也丢到哪条，
    /// 否则下一次 diff 重建会把刚丢的行补回来。
    func dropRecords(below seq: Int) {
        records = records.filter { $0.key >= seq }
        sendStatuses = sendStatuses.filter { $0.key >= seq }
    }

    /// T022 失败行「点击重发」：交给管道的重发状态机（查重 → pending → 网络 →
    /// 确认原地替换），行身份不变。
    func resend(clientId: UUID) async throws {
        try await pipeline.resend(clientId: clientId, for: ref)
    }

    /// 下行数据进管道（follow 快照 / WSS 事件）：合并进热窗口并经 diff 重建。
    func applyDownstream(records page: [SessionRecord]) {
        applyDownstream(events: page.map(\.event))
    }

    func applyDownstream(event: SessionEvent) {
        applyDownstream(events: [event])
    }

    /// 流式帧进管道（T020）：经 SessionPipeline 的 frameTick 合并成 diff，
    /// App 侧旧的 120ms 合流在管道模式下退役（非管道路径仍走 ChatModel 本地缓冲）。
    func applyDownstream(stream frame: AssistantStreamFrame) {
        Task { @MainActor [weak self] in
            await self?.session?.apply(stream: frame)
        }
    }

    private func applyDownstream(events: [SessionEvent]) {
        guard session != nil, !events.isEmpty else { return }
        // 批量入口：一份快照合并成一次 diff，避免按条数触发重建。
        Task { @MainActor [weak self] in
            await self?.session?.apply(events: events)
        }
    }
}

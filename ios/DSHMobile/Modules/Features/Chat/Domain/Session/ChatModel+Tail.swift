import DSHFoundation
import DSHKit
import Foundation

/// 尾轮边界在**模型层**的那一半：首帧播种、边界迁移时的一次性保位、落库、冲突观测。
///
/// 职责归属（设计 `20261027-折叠抖动-方案A.md` §2.1）：
/// - 边界事实只有一份，在 `ChatTimeline.tail`（DSHKit）；
/// - 读者顶部可见行是**测量值**，存在 `transcriptStore.readerTopRowID`，
///   只在"边界从非关闭变成关闭"的那一次被读一遍；
/// - 占位行的三态存在 `transcriptStore.tailBoundaryAttempt`，投影只搬运；
/// - 边界的持久化副本只有**一个写点**（`persistTailBoundary`），只读一次（播种）。
///
/// 这个文件里没有第二份"在不在跑"：`timeline.isTurnOpen` 是 `tail.boundary` 的派生。
extension ChatModel {

    /// 读者顶部可见行（宿主回传的测量值）。唯一写入口是 `noteReaderTopRow(_:)`。
    var readerTopRowID: String? {
        get { transcriptStore.readerTopRowID }
        set { transcriptStore.readerTopRowID = newValue }
    }

    /// 过程区「边界未确认」的三态（占位行显示什么由它决定）。
    var tailBoundaryAttempt: TimelineProcessPlaceholder.State {
        get { transcriptStore.tailBoundaryAttempt }
        set { transcriptStore.tailBoundaryAttempt = newValue }
    }

    /// 换会话/重开：上一次的测量值与占位状态都属于上一屏，不能带过来。
    ///
    /// 不带过来的理由是结构性的：一次打开的**重放**会走过 `unknown → closed`，
    /// 若旧顶部行还在，保位判定就会在"首次打开"时把某个历史轮次强行展开
    ///（设计 §2.3 明令禁止）。`pendingOpen` 也是同一道闸，两者都在这里落。
    func clearTailScope() {
        readerTopRowID = nil
        tailBoundaryAttempt = .unresolved
    }

    /// 首帧边界种子（设计 §2.3 的决策顺序）。
    ///
    /// 1. 同进程缓存里的时间线 `tail`：最强证据（来自实时事件）；
    /// 2. 磁盘上的 `session_tail` 行（M2'）：上次亲身观测到的最后一个事实；
    /// 3. 宿主说在跑（`summary.running`）：列表级事实，比本地旧值新；
    /// 4. 都没有就是 `.unknown`——投影输出一行占位行，不铺开原始过程行。
    ///
    /// 播种值只是"窗口里没有边界行"时的兜底：`reset` 回放会按合并表改写它。
    func tailSeed(for summary: SessionSummary,
                  cached: TranscriptCache.Entry?,
                  persisted: TranscriptTail.Boundary? = nil) -> TranscriptTail.Boundary {
        let cachedBoundary = cached?.timeline.tail.boundary
        let known: TranscriptTail.Boundary? = {
            if let cachedBoundary, !cachedBoundary.isUnknown { return cachedBoundary }
            if let persisted, !persisted.isUnknown { return persisted }
            return nil
        }()
        // 宿主说在跑，但它上次看到的是"已结束"：列表级事实比本地旧值新，覆盖成 open
        //（已经是 open 就不动，那条更准的 startedAt 在已知值里）。
        if summary.running, known?.isOpen != true {
            return openSeed(cached: cached, persisted: persisted)
        }
        if let known { return known }
        return .unknown
    }

    /// 宿主说在跑时的种子：轮号取三方最大（旧值不许把新轮说小），
    /// 计时起点优先用缓存里的（那是 `turn/start` 的宿主时间）。
    private func openSeed(cached: TranscriptCache.Entry?,
                          persisted: TranscriptTail.Boundary?) -> TranscriptTail.Boundary {
        let known = max(cached?.timeline.tail.boundary.turn ?? 0,
                        persisted?.turn ?? 0,
                        cached?.timeline.currentTurn ?? 0)
        return .open(turn: known,
                     startedAt: cached?.timeline.openTurnStartedAt ?? persisted?.startedAt)
    }

    /// 首帧播种的**唯一计算点**（M2'-3）：一次打开只算一次，两处（发布播种、冷启动 reset）
    /// 都用它的返回值。分开算会变成两次读库，且两次可能落在不同的行上。
    func seedBoundary(for summary: SessionSummary,
                      cached: TranscriptCache.Entry?) async -> TranscriptTail.Boundary {
        // 有同进程缓存就不读盘：缓存是最强证据，读一次盘只是多一次延迟。
        var persisted: TranscriptTail.Boundary?
        if cached == nil, let scope = sessionScope {
            persisted = await persistedBoundary(scope: scope, sessionId: summary.sessionId)
        }
        return tailSeed(for: summary, cached: cached, persisted: persisted)
    }

    /// 磁盘上的边界副本。读失败返回 nil **并发探针**：落 unknown 是有意的
    ///（它显示成可重试的占位行，比编一个边界诚实）。
    func persistedBoundary(scope: String, sessionId: String) async -> TranscriptTail.Boundary? {
        guard let layer = messageBacking else { return nil }
        do {
            return try await layer.tailBoundary(scope: scope, sessionId: sessionId)?.asBoundary
        } catch {
            TailTrace.notePersistReadFailed(session: sessionId, reason: String(describing: error))
            return nil
        }
    }

    /// 边界迁移：**同一会话所有发布的唯一公共点**（`timeline` setter 调用）。
    ///
    /// 为什么不在 `reactToTurnLifecycle`：直连路径下它跑在 `timeline.apply(event)`
    /// 之后，管道路径下它跑在 `bridge.applyDownstream` 之后，而管道的新时间线是
    /// 异步折叠、稍后才经 `applyPipelineRebuild` 落地——那一刻 `plan` 还是旧的一帧，
    /// 用它判定就会重演"用上一帧的显示决定这一帧"的同类错误。
    func noteTailTransition(from previous: TranscriptTail, to current: TranscriptTail) {
        guard previous.boundary != current.boundary else { return }
        let hold = applyReaderHold(previous: previous, current: current)
        let persisted = persistTailBoundary(current)
        TailTrace.note(from: previous.boundary, to: current.boundary,
                       hold: hold, persisted: persisted)
    }

    /// 边界落库（M2'-4）：**唯一写点**。三条硬约束在同一个 guard 里一次判完。
    ///
    /// - `.unknown` 永不落库（`StoredTailBoundary.init?` 返回 nil）；
    /// - 搜索中间窗口不落库（`showsTail == false`）；
    /// - 不知道属于哪台电脑/哪个会话时不落库。
    ///
    /// - Returns: 是否已交给写链。探针的 `persisted=1` 就是它，**不保证已落盘**：
    ///   落盘失败另发 `tail.persist.failed`。
    @discardableResult
    private func persistTailBoundary(_ current: TranscriptTail) -> Bool {
        guard current.showsTail, !current.boundary.isUnknown,
              let layer = messageBacking, let scope = sessionScope,
              let sessionId = session?.sessionId,
              let stored = StoredTailBoundary(current.boundary) else { return false }
        enqueueWrite { [weak self] in
            do {
                try await layer.setTailBoundary(scope: scope, sessionId: sessionId, stored)
            } catch {
                await MainActor.run { self?.noteTailPersistFailed(stored, error: error) }
            }
        }
        return true
    }

    /// 落盘失败：只发探针，**不新增"落盘失败"状态字段**。
    ///
    /// 它在界面上的表达就是它的后果——下次打开边界仍未知、占位行可重试。
    /// 再加一个只在内存里的失败标志就是第二份状态。
    private func noteTailPersistFailed(_ stored: StoredTailBoundary, error: any Error) {
        TailTrace.notePersistFailed(session: session?.sessionId ?? "",
                                    turn: stored.turn, to: stored.boundary,
                                    reason: String(describing: error))
    }

    /// 宿主重放旧 `turn/start`（轮次号 ≤ 已关闭轮次号）：合并表已经拒绝这条证据，
    /// 这里**只记录不改行为**——现场能一眼看出"是宿主重放，不是屏幕又抖了"。
    func noteTailConflict(_ event: SessionEvent) {
        guard case .turnStart(let turn) = ChatEventDecoder.decode(event) else { return }
        guard case .closed(let closed, _) = timeline.tail.boundary, turn <= closed else { return }
        TailTrace.noteConflict(session: session?.sessionId ?? "", turn: turn, closed: closed)
    }

    /// 一次性保位：轮次从"非关闭"变成"关闭"的这一帧，读者脚下的内容不许被收走。
    ///
    /// 五个前置条件全满足才判定；命中就写 `manualTurn[turnKey] = true`（命中行属于
    /// 某个组时一并展开那个组）。**已有手工状态一律不覆盖**——读者亲手收起的轮次，
    /// 不该因为一次关闭又被摊开。
    ///
    /// - Returns: 探针取值（`applied` / `skipped:*` / `none`）。
    private func applyReaderHold(previous: TranscriptTail, current: TranscriptTail) -> String {
        guard current.showsTail else { return "skipped:notTail" }
        guard case .closed(let closedTurn, _) = current.boundary else { return "none" }
        guard !previous.boundary.isClosed else { return "none" }
        // 首次打开/播种期间不判定（§2.3）：此时屏幕上的"顶部行"还不是读者的选择。
        guard pendingOpen == nil else { return "skipped:opening" }
        let plan = TranscriptProcessFold.plan(items: timeline.items, tail: current,
                                              currentTurn: timeline.currentTurn,
                                              summaries: timeline.foldSummaries)
        var hold = TranscriptProcessFold.readerHold(topRowID: readerTopRowID, plan: plan,
                                                    closedTurn: closedTurn)
        if case .applied(let turnKey, _) = hold, foldState.manualTurn[turnKey] != nil {
            hold = .skipped(reason: "manual")
        }
        if case .applied(let turnKey, let groupKey) = hold {
            foldState.manualTurn[turnKey] = true
            if let groupKey { foldState.expandedGroups.insert(groupKey) }
        }
        return hold.probeValue
    }

    #if DEBUG
    /// 夹具注入口（M7'-2）：把占位行状态钉在指定值。
    ///
    /// 只在 `-DSHProbeProcessFoldFixture` 的夹具分支被调用，**不新增生产通路**，
    /// 也不是产品开关——它就是"一行赋值"，让占位行的三态能在仿真器里被截图。
    public func probeApplyPlaceholderState(_ state: TimelineProcessPlaceholder.State) {
        tailBoundaryAttempt = state
    }
    #endif
}

import DSHFoundation
import DSHKit
import Foundation

/// A plan for dropping the oldest rows without breaking a folded turn.
///
/// The host sees display rows, while the payload budget is measured on original
/// rows. `displayDropIDs` is therefore the only thing the list host may remove:
/// it is a prefix of the current display rows.
public struct TranscriptTrimPlan: Sendable, Equatable {
    public let rawCount: Int
    public let displayDropIDs: [String]
    public let cutoffSeq: Int?

    public init(rawCount: Int, displayDropIDs: [String], cutoffSeq: Int?) {
        self.rawCount = rawCount
        self.displayDropIDs = displayDropIDs
        self.cutoffSeq = cutoffSeq
    }

    public var isEmpty: Bool { rawCount <= 0 || displayDropIDs.isEmpty }
}

public extension ChatModel {

    /// Rows the view should draw for this screen, with completed process folded.
    func displayRowsFor(screen sessionId: String) -> [TimelineItem] {
        guard let visible, visible.summary.sessionId == sessionId else { return [] }
        let plan = TranscriptProcessFold.plan(
            items: visible.timeline.items,
            isTurnOpen: visible.timeline.isTurnOpen,
            currentTurn: visible.timeline.currentTurn,
            summaries: visible.timeline.foldSummaries)
        // 折叠摘要：只在状态变化时发（`FoldTrace.note` 内部比较并节流）。
        // 这行是"某些已完成的历史对话没有折叠"唯一的现场证据来源。
        FoldTrace.note(plan: plan, session: sessionId)
        var rows = TranscriptProcessFold.displayRows(plan, state: foldState)
        // 排队输入不进转写：`isPending` 的乐观用户行由输入区上方的条带呈现
        //（设计 `20261026-排队输入-设计.md` §3/§5）。发送失败/未确认的行仍然
        // 留在转写里（它们要能点重试），只隐藏"还在等待"的那一种。
        rows.removeAll { item in
            guard case .userMessage(_, _, _, let isPending, _) = item.kind else { return false }
            return isPending && !item.sendFailed && !item.sendUnconfirmed
        }
        // 末尾运行行：一轮还在跑时，两个列表宿主都要看到它。
        // 它必须在行模型里（uikit 宿主只渲染 `rowsFor`），身份稳定、不参与裁剪。
        if visible.timeline.isTurnOpen {
            let runningKey = plan.turns.last(where: { $0.isRunning })?.key
            rows.append(TimelineRunningLine(since: runningSince, turnKey: runningKey).item)
        }
        // 单条步骤正文的三态贴在步骤行上；模型是唯一所有者，投影只做搬运。
        // 展开状态已经由 `TranscriptProcessFold.displayRows` 从同一份 foldState 贴上。
        if !stepBodies.isEmpty {
            for index in rows.indices {
                guard case .processStep(let step) = rows[index].kind,
                      let body = stepBodies[step.id] else { continue }
                rows[index].kind = .processStep(step.with(body: body))
            }
        }
        // 展开摘要的取详情进度贴在表头上；模型是唯一所有者，投影只做搬运。
        if !prefetchStatus.isEmpty {
            for index in rows.indices {
                guard case .processHeader(let header) = rows[index].kind,
                      let status = prefetchStatus[header.id] else { continue }
                rows[index].kind = .processHeader(header.with(prefetchStatus: status))
            }
        }
        return rows
    }

    /// The original rows, for callers that must reason about hidden content
    /// (search, paging, long-press lookup). Views should use `displayRowsFor`.
    func rawRowsFor(screen sessionId: String) -> [TimelineItem] {
        guard let visible, visible.summary.sessionId == sessionId else { return [] }
        return visible.timeline.items
    }

    func toggleProcess(turnKey: String) {
        let plan = processPlan()
        guard let turn = plan.turnByKey[turnKey] else { return }

        // v1 的"点开再补拉"只在没有 v2 能力时才是通路：v2 能力在时页面统一
        // 走概要（不存在预折摘要行），这条分支不应再被走到。
        let v2SummaryMode = store?.chatHost?.historySummaryFoldEnabled == true
        // 连接器折好下发的摘要：这一轮没有过程行可展开，点它等于「把详情取回来」。
        // 先记为展开，详情落地后整树重建，这一轮自然恢复成正常的可折叠轮次。
        if !v2SummaryMode, let header = Self.prefetchedSummary(in: turn, plan: plan) {
            let range = Self.prefetchedRange(in: turn, plan: plan) ?? header.startSeq...header.endSeq
            foldState.manualTurn[turnKey] = true
            Task { [weak self] in
                await self?.loadPrefetchedSummary(header, range: range, turnKey: turnKey)
            }
            return
        }

        guard turn.canCollapse else { return }
        let expanded = TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: foldState)
        foldState.manualTurn[turnKey] = !expanded
        // 收起整轮时，组也一并回到收起（桌面 board2 ④）：下次展开仍是先看到分组。
        if expanded {
            for group in turn.groups { foldState.expandedGroups.remove(group.key) }
        }
    }

    /// 轮次里有没有「连接器折好下发」的摘要行（`isPrefetched`）。
    static func prefetchedSummary(in turn: TranscriptProcessFold.Turn,
                                  plan: TranscriptProcessFold.Plan) -> TimelineProcessHeader? {
        for index in turn.processIndexes {
            if case .processHeader(let header) = plan.rows[index].kind, header.isPrefetched {
                return header
            }
        }
        return nil
    }

    /// 一轮里所有连接器摘要覆盖的 seq 段（合并后的展开范围）。
    static func prefetchedRange(in turn: TranscriptProcessFold.Turn,
                                plan: TranscriptProcessFold.Plan) -> ClosedRange<Int>? {
        var lower: Int?
        var upper: Int?
        for index in turn.range {
            guard case .processHeader(let header) = plan.rows[index].kind, header.isPrefetched else { continue }
            lower = min(lower ?? header.startSeq, header.startSeq)
            upper = max(upper ?? header.endSeq, header.endSeq)
        }
        guard let lower, let upper, lower <= upper else { return nil }
        return lower...upper
    }

    /// 取回摘要背后的真实过程行。
    ///
    /// 走的是现有 `_link/sessionWindow`（不带 `fold`），不新增端点；取回后交给管道
    /// `absorb`，摘要记录所在的 seq 被真实事件覆盖，下一次整树重建就把它换掉。
    /// 失败时不改任何状态：摘要行还在，读者可以再点一次。
    func loadPrefetchedSummary(_ header: TimelineProcessHeader,
                               range: ClosedRange<Int>,
                               turnKey: String) async {
        guard header.isPrefetched,
              let client = store?.chatHost, let address else { return }
        // 同一轮只允许一个在飞的详情请求；失败后（.failed）允许再次点按重试。
        if case .loading = prefetchStatus[header.id] { return }
        prefetchStatus[header.id] = .loading(loaded: 0)
        let lower = range.lowerBound
        let upper = range.upperBound
        // 一次只取 `PrefetchPager.window` 条，按 seq 往下滚到 lower 为止。
        // 旧实现一次要整个区间（可能几千个 seq、几百条记录），宿主按条数与字节
        // 截断后只回来一小段，表头写着“230 次工具调用”，展开却只有几条。
        var cursor = upper + 1
        var collected = 0
        var coveredLow = upper
        do {
            while let window = PrefetchPager.next(lower: lower, cursor: cursor) {
                #if DEBUG
                FoldPerfProbe.begin(.historyNone, limit: window.count,
                                    maxBytes: 512 * 1024)
                #endif
                let value = try await client.historyWindow(HistoryWindowRequest(
                    address: address, before: cursor, through: nil,
                    limit: window.count, maxBytes: 512 * 1024,
                    encoding: client.historyWindowEncoding, fold: nil))
                #if DEBUG
                FoldPerfProbe.finished(.historyNone, records: value.records.count,
                                        bytes: FoldPerfProbe.payloadBytes(value.records))
                #endif
                let records = value.records.filter { $0.event.seq >= lower && $0.event.seq <= upper }
                guard let oldest = records.map(\.event.seq).min(), oldest < cursor else { break }
                collected += records.count
                coveredLow = min(coveredLow, oldest)
                prefetchStatus[header.id] = (prefetchStatus[header.id] ?? .loading(loaded: 0))
                    .advanced(by: records.count)
                await pipelineBridge?.absorb(records: records)
                cursor = oldest
            }
            guard collected > 0 else {
                prefetchStatus[header.id] = nil
                return
            }
            // 明细已经落地，进度标记随之消失；表头改由摘要+明细共同计数。
            prefetchStatus[header.id] = nil
            foldState.manualTurn[turnKey] = true
            ChatProbe.shared.probeNote?("process.expand", [
                "turn": turnKey, "records": String(collected),
                "complete": PrefetchPager.isComplete(lower: lower, coveredLow: coveredLow) ? "1" : "0",
            ], true)
        } catch {
            // 取消不算失败（切换会话时的正常收尾）；其余错误要落到可重试的终态。
            if error is CancellationError {
                prefetchStatus[header.id] = nil
            } else {
                prefetchStatus[header.id] = .failed
            }
            ChatProbe.shared.probeNote?("process.expandFailed", [
                "turn": turnKey, "reason": String(describing: error),
            ], true)
        }
    }

    /// 分组只有一种状态需要记：读者亲手展开的组。缺省就是收起（桌面同款）。
    func toggleProcessGroup(groupKey: String) {
        guard processPlan().groupByKey[groupKey] != nil else { return }
        if foldState.expandedGroups.contains(groupKey) {
            foldState.expandedGroups.remove(groupKey)
        } else {
            foldState.expandedGroups.insert(groupKey)
        }
    }

    /// Expand the turn (and group) that owns `id`, then return the visible row
    /// id to jump to. Returns nil when the row is outside the loaded window.
    @discardableResult
    func revealProcess(containingRowID id: String) -> String? {
        let plan = processPlan()
        guard let target = TranscriptProcessFold.revealTarget(rowID: id, plan: plan) else {
            return nil
        }
        if plan.processRowIDs.contains(id) {
            foldState.manualTurn[target.turnKey] = true
            if let group = target.groupKey { foldState.expandedGroups.insert(group) }
        }
        return id
    }

    func holdProcessToggleFollow() {
        guard !processToggleFollowHold else { return }
        processToggleFollowHold = true
    }

    func releaseProcessToggleFollow() {
        guard processToggleFollowHold else { return }
        processToggleFollowHold = false
    }

    func noteReaderTopRow(_ id: String?) {
        guard foldState.readerTopRowID != id else { return }
        foldState.readerTopRowID = id
    }

    /// Compute the oldest rows the payload budget wants to drop, aligned so a
    /// folded turn is never cut in half. Does not mutate the transcript.
    func trimPlanForBudget(keepLast: Int? = nil) -> TranscriptTrimPlan {
        let items = timeline.items
        guard !items.isEmpty else { return TranscriptTrimPlan(rawCount: 0, displayDropIDs: [], cutoffSeq: nil) }
        let sizes = items.map { TranscriptRowPayload(item: $0).payloadBytes }
        let proposed = TranscriptWindowPlanner.rowsToDrop(
            payloadBytes: sizes,
            under: TranscriptPayloadBudget(limitBytes: Self.payloadBudgetBytes),
            keepLast: keepLast)
        guard proposed > 0, proposed < items.count else {
            return TranscriptTrimPlan(rawCount: 0, displayDropIDs: [], cutoffSeq: nil)
        }
        let plan = processPlan()
        var cutoff = items[proposed].seq
        // Do not cut a turn: if the first kept row holds the tail of a turn,
        // drop that whole turn instead (or keep it whole when it is the only one).
        if let turn = plan.turns.first(where: { $0.startSeq < cutoff && cutoff <= $0.endSeq }) {
            cutoff = turn.startSeq
        }
        guard let firstKept = items.firstIndex(where: { $0.seq >= cutoff }) else {
            return TranscriptTrimPlan(rawCount: 0, displayDropIDs: [], cutoffSeq: nil)
        }
        let rawCount = firstKept
        guard rawCount > 0 else {
            return TranscriptTrimPlan(rawCount: 0, displayDropIDs: [], cutoffSeq: nil)
        }
        let display = TranscriptProcessFold.displayRows(plan, state: foldState)
        var dropIDs: [String] = []
        for row in display {
            if row.seq >= cutoff { break }
            if case .processHeader(let header) = row.kind, header.endSeq >= cutoff { break }
            dropIDs.append(row.id)
        }
        return TranscriptTrimPlan(rawCount: rawCount, displayDropIDs: dropIDs,
                                  cutoffSeq: cutoff)
    }

    /// Apply a trim plan. The caller must then give the host the same plan's
    /// `displayDropIDs`, so both sides remove one prefix.
    @discardableResult
    func applyTrim(_ plan: TranscriptTrimPlan) -> Int {
        guard plan.rawCount > 0 else { return 0 }
        let dropped = dropOldestRows(plan.rawCount)
        // 概要 v2 的元数据不占行：按**轮次对齐**的裁剪线一起丢。不能用"第一条
        // 剩下的行"来判——一轮的过程可以整段都在概要里（窗口里没有行），那样会
        // 把还留着的轮次的概要误删。`cutoffSeq` 就是留着的那个轮次的起点。
        if let cutoff = plan.cutoffSeq {
            timeline.pruneFoldSummaries(before: cutoff)
        }
        pruneFoldState()
        return dropped
    }

    /// Drop reader/group state whose keys are no longer present.
    func pruneFoldState() {
        let plan = processPlan()
        let turnKeys = Set(plan.turns.map(\.key))
        let groupKeys = Set(plan.groups.map(\.key))
        let stepKeys = Set(plan.groups.flatMap { $0.steps.map(\.id) })
        foldState.manualTurn = foldState.manualTurn.filter { turnKeys.contains($0.key) }
        foldState.expandedGroups.formIntersection(groupKeys)
        foldState.expandedSteps.formIntersection(stepKeys)
        stepBodies = stepBodies.filter { stepKeys.contains($0.key) }
        if let top = foldState.readerTopRowID,
           !plan.rows.contains(where: { $0.id == top }) {
            foldState.readerTopRowID = nil
        }
    }

    func processPlan() -> TranscriptProcessFold.Plan {
        guard let visible else {
            return TranscriptProcessFold.plan(items: [], isTurnOpen: false)
        }
        return TranscriptProcessFold.plan(
            items: visible.timeline.items,
            isTurnOpen: visible.timeline.isTurnOpen,
            currentTurn: visible.timeline.currentTurn,
            summaries: visible.timeline.foldSummaries)
    }
}


/// 展开预折摘要时的取页规划。纯函数，单测直接钉"要分批、要覆盖到 lower"。
public enum PrefetchPager {
    /// 每批最多取多少个 seq。取值只受宿主单次回包上限约束，与页大小无关。
    public static let window = 150

    /// 下一批的请求范围；`cursor` 是"从哪个 seq 之下开始取"（不含）。
    /// 已经覆盖到 lower 就返回 nil。
    public static func next(lower: Int, cursor: Int) -> ClosedRange<Int>? {
        guard cursor > lower else { return nil }
        let upper = cursor - 1
        let lowerBound = max(lower, upper - window + 1)
        return lowerBound...upper
    }

    /// 取到的最老 seq 已经到 lower，即整段覆盖完成。
    public static func isComplete(lower: Int, coveredLow: Int) -> Bool {
        coveredLow <= lower
    }
}

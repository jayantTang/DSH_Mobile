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
            currentTurn: visible.timeline.currentTurn)
        // 折叠摘要：只在状态变化时发（`FoldTrace.note` 内部比较并节流）。
        // 这行是"某些已完成的历史对话没有折叠"唯一的现场证据来源。
        FoldTrace.note(plan: plan, session: sessionId)
        return TranscriptProcessFold.displayRows(plan, state: foldState)
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

        // 连接器折好下发的摘要：这一轮没有过程行可展开，点它等于「把详情取回来」。
        // 先记为展开，详情落地后整树重建，这一轮自然恢复成正常的可折叠轮次。
        if let header = Self.prefetchedSummary(in: turn, plan: plan) {
            let range = Self.prefetchedRange(in: turn, plan: plan) ?? header.startSeq...header.endSeq
            foldState.manualTurn[turnKey] = true
            Task { [weak self] in
                await self?.loadPrefetchedSummary(header, range: range, turnKey: turnKey)
            }
            return
        }

        guard turn.isFoldable else { return }
        let expanded = TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: foldState)
        foldState.manualTurn[turnKey] = !expanded
        if !expanded {
            for group in turn.groups { foldState.collapsedGroups.remove(group.key) }
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
              let client = store?.client, let address else { return }
        let lower = range.lowerBound
        let upper = range.upperBound
        do {
            let value = try await client.historyWindow(HistoryWindowRequest(
                address: address, before: upper + 1, through: nil,
                limit: upper - lower + 1, maxBytes: 512 * 1024,
                encoding: client.historyWindowEncoding, fold: nil))
            let records = value.records.filter { $0.event.seq >= lower && $0.event.seq <= upper }
            guard !records.isEmpty else { return }
            await pipelineBridge?.absorb(records: records)
            foldState.manualTurn[turnKey] = true
            ChatProbe.shared.probeNote?("process.expand", [
                "turn": turnKey, "records": String(records.count),
            ], true)
        } catch {
            ChatProbe.shared.probeNote?("process.expandFailed", [
                "turn": turnKey, "reason": String(describing: error),
            ], true)
        }
    }

    func toggleProcessGroup(groupKey: String) {
        let plan = processPlan()
        guard let group = plan.groupByKey[groupKey] else { return }
        let turn = plan.turnByKey[group.turnKey]
        // Completed turns show their groups expanded; in a running turn only
        // the still-growing (not yet sealed) group is open by default.
        let defaultOpen = turn.map { !$0.isRunning || !TranscriptProcessFold.isGroupClosed(group, in: $0) } ?? true
        if foldState.expandedGroups.contains(groupKey) {
            foldState.expandedGroups.remove(groupKey)
            foldState.collapsedGroups.insert(groupKey)
        } else if foldState.collapsedGroups.contains(groupKey) {
            foldState.collapsedGroups.remove(groupKey)
            foldState.expandedGroups.insert(groupKey)
        } else if defaultOpen {
            foldState.collapsedGroups.insert(groupKey)
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
            if let group = target.groupKey { foldState.collapsedGroups.remove(group) }
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
        pruneFoldState()
        return dropped
    }

    /// Drop reader/group state whose keys are no longer present.
    func pruneFoldState() {
        let plan = processPlan()
        let turnKeys = Set(plan.turns.map(\.key))
        let groupKeys = Set(plan.groups.map(\.key))
        foldState.manualTurn = foldState.manualTurn.filter { turnKeys.contains($0.key) }
        foldState.collapsedGroups.formIntersection(groupKeys)
        foldState.expandedGroups.formIntersection(groupKeys)
        if let top = foldState.readerTopRowID,
           !plan.rows.contains(where: { $0.id == top }) {
            foldState.readerTopRowID = nil
        }
    }

    private func processPlan() -> TranscriptProcessFold.Plan {
        guard let visible else {
            return TranscriptProcessFold.plan(items: [], isTurnOpen: false)
        }
        return TranscriptProcessFold.plan(
            items: visible.timeline.items,
            isTurnOpen: visible.timeline.isTurnOpen,
            currentTurn: visible.timeline.currentTurn)
    }
}

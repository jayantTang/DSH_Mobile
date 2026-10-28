@testable import DSHChatDomain
import DSHKit
import XCTest

/// The exception matrix from `data-model.md §11`; every row has at least one
/// case here so a later simplification cannot silently start hiding evidence.
final class TranscriptProcessFoldEdgeTests: XCTestCase {

    private func plan(_ timeline: ChatTimeline, open: Bool = false) -> TranscriptProcessFold.Plan {
        TranscriptProcessFold.plan(items: timeline.items,
                                   tail: ProcessFoldFixtures.tail(timeline, running: open),
                                   currentTurn: timeline.currentTurn)
    }

    func test_max_steps_is_a_normal_completion_and_folds() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.turnEnd(seq: 4, reason: "max-steps"),
        ])
        XCTAssertTrue(try XCTUnwrap(plan(timeline).turns.first).isFoldable)
    }

    func test_non_error_notice_is_part_of_the_process_and_hidden_when_folded() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.notice(seq: 3, text: "compacted"),
            ProcessFoldFixtures.toolCall(seq: 4, callId: "c1", name: "bash"),
            ProcessFoldFixtures.assistant(seq: 5, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 6),
        ])
        let turn = try XCTUnwrap(plan(timeline).turns.first)
        XCTAssertTrue(turn.isFoldable)
        let rows = TranscriptProcessFold.displayRows(plan(timeline), state: TranscriptFoldState())
        XCTAssertFalse(rows.contains { if case .notice = $0.kind { return true }; return false })
    }

    func test_unknown_event_is_part_of_the_process_and_hidden_when_folded() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ["type": .string("something/new"), "seq": .int(3), "data": .object([:])],
            ProcessFoldFixtures.toolCall(seq: 4, callId: "c1", name: "bash"),
            ProcessFoldFixtures.assistant(seq: 5, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 6),
        ])
        // The fold retains unknown events as `.unknown` rows; they are process.
        let turn = try XCTUnwrap(plan(timeline).turns.first)
        XCTAssertTrue(turn.isFoldable)
        let rows = TranscriptProcessFold.displayRows(plan(timeline), state: TranscriptFoldState())
        XCTAssertFalse(rows.contains { if case .unknown = $0.kind { return true }; return false })
    }

    func test_second_user_message_is_a_boundary_not_a_fold_blocker() throws {
        // 2026-10-18：中途插话不再取消整轮折叠。用户消息在 leading 里，收起时仍可见；
        // 原先"有第二条用户消息就整轮铺开"会让长会话里的大量轮次永远不可折。
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.user(seq: 4, text: "and this"),
            ProcessFoldFixtures.assistant(seq: 5, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 6),
        ])
        let turn = try XCTUnwrap(plan(timeline).turns.first)
        XCTAssertTrue(turn.isFoldable)
        let rows = TranscriptProcessFold.displayRows(plan(timeline), state: TranscriptFoldState())
        let texts = rows.compactMap { item -> String? in
            if case .userMessage(let text, _, _, _, _) = item.kind { return text }
            return nil
        }
        XCTAssertTrue(texts.contains("q"))
        XCTAssertTrue(texts.contains("and this"))
    }

    func test_foldability_predicate_has_no_gap_failure_or_interleaved_input_terms() {
        // 判据只由这三项决定；gap、中途插话、失败与预折摘要都不在签名里——
        // 失败与正常完成同一套折叠（M5），任何一项都不应把整轮重新变成不可折。
        XCTAssertTrue(TranscriptProcessFold.isFoldable(
            hasDivider: true, isRunning: false, hasProcessRows: true))
        XCTAssertFalse(TranscriptProcessFold.isFoldable(
            hasDivider: false, isRunning: false, hasProcessRows: true))
        XCTAssertFalse(TranscriptProcessFold.isFoldable(
            hasDivider: true, isRunning: true, hasProcessRows: true))
        XCTAssertFalse(TranscriptProcessFold.isFoldable(
            hasDivider: true, isRunning: false, hasProcessRows: false))
    }

    /// 尾段能不能折，由**边界事实**决定，不再由「窗口里有没有分隔行」推断。
    ///
    /// 旧断言（"没有分隔行且不在跑 ⇒ 不可折"）是本次删除的旧行为：它正是长轮次
    /// 被条数切开后整段铺开的原因。现在两个世界的形状分开钉：
    /// 边界不知道 ⇒ 不折（投影出占位行）；边界说已结束 ⇒ 折。
    func test_a_tail_without_a_divider_is_decided_by_the_boundary() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
        ])
        let unknown = try XCTUnwrap(
            TranscriptProcessFold.plan(items: timeline.items, tail: .unknown,
                                       currentTurn: timeline.currentTurn).turns.first)
        XCTAssertFalse(unknown.isFoldable)
        XCTAssertTrue(unknown.isBoundaryUnknown)
        XCTAssertTrue(unknown.isPartial)

        let closed = TranscriptTail(boundary: .closed(turn: 1, reason: "completed"), showsTail: true)
        let settled = try XCTUnwrap(
            TranscriptProcessFold.plan(items: timeline.items, tail: closed,
                                       currentTurn: timeline.currentTurn).turns.first)
        XCTAssertTrue(settled.isFoldable, "边界说这一轮结束了，就是可折叠")
        XCTAssertFalse(settled.isBoundaryUnknown)
    }

    func test_header_falls_back_to_seq_when_the_turn_number_is_unknown() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.toolCall(seq: 10, callId: "c1", name: "bash", turn: 0),
            ProcessFoldFixtures.assistant(seq: 11, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 12, turn: 0),
        ])
        let turn = try XCTUnwrap(plan(timeline).turns.first)
        XCTAssertEqual(turn.key, "turn-process:seq:10")
        XCTAssertTrue(TranscriptProcessFold.revealTarget(rowID: timeline.items[0].id, plan: plan(timeline))?.turnKey == turn.key)
    }

    func test_large_counts_do_not_change_folding() throws {
        let timeline = try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: 120, reasoning: 40))
        let turn = try XCTUnwrap(plan(timeline).turns.first)
        XCTAssertEqual(turn.toolCount, 120)
        XCTAssertEqual(turn.reasoningCount, 40)
        XCTAssertTrue(turn.isFoldable)
        let rows = TranscriptProcessFold.displayRows(plan(timeline), state: TranscriptFoldState())
        XCTAssertEqual(rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let header) = item.kind { return header }
            return nil
        }.first?.toolCount, 120)
    }

    func test_group_state_never_hides_the_final_answer_or_the_turn_row() throws {
        let timeline = try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: 4,
                                               reasoning: 2, intermediate: true))
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        // 组默认收起（expandedGroups 为空）；回答与轮次行都不受组状态影响。
        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertTrue(rows.contains { if case .assistantText(let text) = $0.kind { return text.hasPrefix("answer") }; return false })
        XCTAssertTrue(rows.contains { if case .processHeader(let header) = $0.kind, header.scope == .turn { return true }; return false })
        XCTAssertFalse(rows.contains { if case .turnDivider = $0.kind { return true }; return false })
        // 组展开再收起都不改变回答与轮次行。
        for group in turn.groups { state.expandedGroups.insert(group.key) }
        let expanded = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertTrue(expanded.contains { if case .assistantText(let text) = $0.kind { return text.hasPrefix("answer") }; return false })
    }

    func test_projection_of_a_500_row_transcript_stays_under_the_budget() throws {
        var events: [[String: JSONValue]] = []
        var seq = 1
        for turn in 1...10 {
            events += ProcessFoldFixtures.completedTurn(turn: turn, startSeq: seq,
                                                         tools: 50, reasoning: 2)
            seq = (events.last?["seq"]?.intValue ?? seq) + 1
        }
        let timeline = try ProcessFoldFixtures.timeline(events)
        XCTAssertGreaterThanOrEqual(timeline.items.count, 500)
        var state = TranscriptFoldState()
        var durations: [Double] = []
        for _ in 0..<20 {
            let started = CFAbsoluteTimeGetCurrent()
            let plan = TranscriptProcessFold.plan(items: timeline.items, tail: .unknown,
                                                  currentTurn: timeline.currentTurn)
            _ = TranscriptProcessFold.displayRows(plan, state: state)
            durations.append(CFAbsoluteTimeGetCurrent() - started)
        }
        let average = durations.reduce(0, +) / Double(durations.count)
        print("process-fold-projection: rows=\(timeline.items.count) average=\(average * 1000)ms max=\((durations.max() ?? 0) * 1000)ms")
        XCTAssertLessThan(average, 0.016, "average projection took \(average * 1000)ms")
        state.manualTurn["turn-process:1"] = true
        let expanded = TranscriptProcessFold.displayRows(
            TranscriptProcessFold.plan(items: timeline.items, tail: .unknown),
            state: state)
        XCTAssertGreaterThan(expanded.count, 0)
    }

    func test_rapid_toggle_state_is_idempotent() throws {
        let timeline = try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: 2))
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        for _ in 0..<10 { state.manualTurn[turn.key] = true }
        let a = TranscriptProcessFold.displayRows(plan, state: state).map(\.id)
        for _ in 0..<10 { state.manualTurn[turn.key] = true }
        XCTAssertEqual(a, TranscriptProcessFold.displayRows(plan, state: state).map(\.id))
        state.manualTurn[turn.key] = false
        XCTAssertFalse(TranscriptProcessFold.displayRows(plan, state: state).map(\.id).contains(timeline.items[2].id))
    }
}

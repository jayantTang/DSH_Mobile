import DSHChatDomain
import DSHKit
import XCTest

/// The exception matrix from `data-model.md §11`; every row has at least one
/// case here so a later simplification cannot silently start hiding evidence.
final class TranscriptProcessFoldEdgeTests: XCTestCase {

    private func plan(_ timeline: ChatTimeline, open: Bool = false) -> TranscriptProcessFold.Plan {
        TranscriptProcessFold.plan(items: timeline.items, isTurnOpen: open,
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

    func test_foldability_predicate_has_no_gap_or_interleaved_input_terms() {
        // 判据只由这四项决定；gap、中途插话与预折摘要都不在签名里，
        // 任何一项都不应把整轮重新变成不可折。
        XCTAssertTrue(TranscriptProcessFold.isFoldable(
            hasDivider: true, isRunning: false, hasFailure: false,
            hasProcessRows: true))
        XCTAssertFalse(TranscriptProcessFold.isFoldable(
            hasDivider: false, isRunning: false, hasFailure: false,
            hasProcessRows: true))
        XCTAssertFalse(TranscriptProcessFold.isFoldable(
            hasDivider: true, isRunning: true, hasFailure: false,
            hasProcessRows: true))
        XCTAssertFalse(TranscriptProcessFold.isFoldable(
            hasDivider: true, isRunning: false, hasFailure: true,
            hasProcessRows: true))
        XCTAssertFalse(TranscriptProcessFold.isFoldable(
            hasDivider: true, isRunning: false, hasFailure: false,
            hasProcessRows: false))
    }

    func test_tail_without_a_divider_and_not_running_is_not_folded() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
        ])
        let turn = try XCTUnwrap(plan(timeline, open: false).turns.first)
        XCTAssertFalse(turn.isFoldable)
        XCTAssertTrue(turn.isPartial)
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

    func test_collapsed_group_does_not_hide_the_final_answer_or_divider() throws {
        let timeline = try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: 4,
                                               reasoning: 2, intermediate: true))
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        for group in turn.groups { state.collapsedGroups.insert(group.key) }
        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertTrue(rows.contains { if case .assistantText(let text) = $0.kind { return text.hasPrefix("answer") }; return false })
        XCTAssertTrue(rows.contains { if case .turnDivider = $0.kind { return true }; return false })
    }

    func test_reader_on_a_group_member_holds_the_turn_open() throws {
        let timeline = try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: 4,
                                               reasoning: 2, intermediate: true))
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        let member = try XCTUnwrap(turn.groups.last?.indexes.first).self
        let row = timeline.items[member]
        var state = TranscriptFoldState()
        state.readerTopRowID = row.id
        XCTAssertTrue(TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: state))
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
            let plan = TranscriptProcessFold.plan(items: timeline.items, isTurnOpen: false,
                                                  currentTurn: timeline.currentTurn)
            _ = TranscriptProcessFold.displayRows(plan, state: state)
            durations.append(CFAbsoluteTimeGetCurrent() - started)
        }
        let average = durations.reduce(0, +) / Double(durations.count)
        print("process-fold-projection: rows=\(timeline.items.count) average=\(average * 1000)ms max=\((durations.max() ?? 0) * 1000)ms")
        XCTAssertLessThan(average, 0.016, "average projection took \(average * 1000)ms")
        state.manualTurn["turn-process:1"] = true
        let expanded = TranscriptProcessFold.displayRows(
            TranscriptProcessFold.plan(items: timeline.items, isTurnOpen: false),
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

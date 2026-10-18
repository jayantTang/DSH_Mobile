import DSHChatDomain
import DSHKit
import XCTest

final class TranscriptProcessFoldTests: XCTestCase {

    // MARK: - Fixtures

    private func completed(tools: Int = 2, intermediate: Bool = false) throws -> ChatTimeline {
        try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: tools,
                                               reasoning: 1, intermediate: intermediate))
    }

    private func plan(_ timeline: ChatTimeline, isTurnOpen: Bool = false) -> TranscriptProcessFold.Plan {
        TranscriptProcessFold.plan(items: timeline.items, isTurnOpen: isTurnOpen,
                                   currentTurn: timeline.currentTurn)
    }

    private func plan(_ items: [TimelineItem], isTurnOpen: Bool = false) -> TranscriptProcessFold.Plan {
        TranscriptProcessFold.plan(items: items, isTurnOpen: isTurnOpen, currentTurn: 1)
    }

    private func header(_ item: TimelineItem) -> TimelineProcessHeader? {
        guard case .processHeader(let header) = item.kind else { return nil }
        return header
    }

    private func ids(_ rows: [TimelineItem]) -> [String] { rows.map(\.id) }

    // MARK: - Folding

    func test_a_completed_turn_folds_to_question_process_answer_and_divider() throws {
        let timeline = try completed(tools: 2)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isFoldable)
        XCTAssertEqual(turn.toolCount, 2)
        XCTAssertEqual(turn.reasoningCount, 1)

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertEqual(rows.count, 4)
        guard case .userMessage = rows[0].kind else { return XCTFail("first row must be the question") }
        let header = try XCTUnwrap(self.header(rows[1]))
        XCTAssertEqual(header.scope, .turn)
        XCTAssertFalse(header.isExpanded)
        XCTAssertEqual(header.toolCount, 2)
        guard case .assistantText(let answer) = rows[2].kind else { return XCTFail("second visible row must be the answer") }
        XCTAssertEqual(answer, "answer 1")
        guard case .turnDivider = rows[3].kind else { return XCTFail("last row must be the divider") }
    }

    func test_expanding_restores_every_original_row_in_order() throws {
        let timeline = try completed(tools: 3, intermediate: true)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true

        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        let withoutHeaders = rows.filter { self.header($0) == nil }
        XCTAssertEqual(ids(withoutHeaders), ids(timeline.items))
        XCTAssertTrue(rows.contains { if case .assistantText(let text) = $0.kind { return text == "still working 1" }; return false })
    }

    func test_pure_qna_has_no_process_header() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.assistant(seq: 3, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 4),
        ])
        let plan = plan(timeline)
        XCTAssertFalse(try XCTUnwrap(plan.turns.first).isFoldable)
        XCTAssertEqual(ids(TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())),
                       ids(timeline.items))
    }

    func test_running_turn_stays_expanded() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
        ])
        let plan = plan(timeline, isTurnOpen: true)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isRunning)
        XCTAssertFalse(turn.isFoldable)
        XCTAssertEqual(ids(TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())),
                       ids(timeline.items))
    }

    func test_error_turn_stays_expanded() throws {
        for reason in ["error", "failed", "cancelled", "interrupted", "aborted"] {
            let timeline = try ProcessFoldFixtures.timeline([
                ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
                ProcessFoldFixtures.user(seq: 2, text: "q"),
                ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
                ProcessFoldFixtures.toolResult(seq: 4, callId: "c1", isError: true),
                ProcessFoldFixtures.turnEnd(seq: 5, reason: reason),
            ])
            let plan = plan(timeline)
            XCTAssertFalse(try XCTUnwrap(plan.turns.first).isFoldable, reason)
            XCTAssertEqual(ids(TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())),
                           ids(timeline.items), reason)
        }
    }

    func test_steering_is_a_boundary_not_a_fold_blocker() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.steering(seq: 4, text: "also do this"),
            ProcessFoldFixtures.assistant(seq: 5, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 6),
        ])
        let plan = plan(timeline)
        // 2026-10-18：中途插话不再取消整轮折叠，但读者自己说的话必须仍然可见。
        XCTAssertTrue(try XCTUnwrap(plan.turns.first).isFoldable)
        XCTAssertTrue(ids(TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState()))
            .contains(try XCTUnwrap(timeline.items.first { item in
                if case .userMessage(_, _, let steering, _, _) = item.kind { return steering }
                return false
            }).id))
    }

    func test_gap_does_not_block_folding_and_stays_visible() throws {
        let timeline = try completed(tools: 2)
        let gap = ChatTimeline.gapItem(start: 3, end: 3, status: .loading)
        var items = timeline.items
        items.insert(gap, at: 2)
        let plan = plan(items)
        // 2026-10-18：缺段不再让整轮不可折；缺口行以轮内一行的形式保留，
        // 收起时也可见（否则读者会以为这一段历史是完整的）。
        XCTAssertTrue(try XCTUnwrap(plan.turns.first).isFoldable)
        XCTAssertTrue(ids(TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())).contains(gap.id))
    }

    func test_error_notice_prevents_folding() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.notice(seq: 4, text: "boom", isError: true),
            ProcessFoldFixtures.assistant(seq: 5, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 6),
        ])
        let plan = plan(timeline)
        XCTAssertFalse(try XCTUnwrap(plan.turns.first).isFoldable)
    }

    // MARK: - Groups

    func test_intermediate_assistant_text_splits_groups() throws {
        let timeline = try completed(tools: 4, intermediate: true)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.groups.count, 2)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertEqual(rows.compactMap { header($0)?.scope == .group ? true : nil }.count, 2)
        XCTAssertTrue(rows.contains { if case .assistantText(let text) = $0.kind { return text == "still working 1" }; return false })
    }

    func test_single_group_has_no_group_header() throws {
        let timeline = try completed(tools: 2)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.groups.count, 1)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertFalse(rows.contains { header($0)?.scope == .group })
    }

    func test_collapsing_one_group_only_hides_that_group() throws {
        let timeline = try completed(tools: 4, intermediate: true)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        let first = try XCTUnwrap(turn.groups.first)
        state.collapsedGroups.insert(first.key)
        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        for index in first.indexes {
            XCTAssertFalse(rows.contains { $0.id == timeline.items[index].id })
        }
        let second = try XCTUnwrap(turn.groups.last)
        XCTAssertTrue(rows.contains { $0.id == timeline.items[try! XCTUnwrap(second.indexes.first)].id })
    }

    // MARK: - Defaults and reader context

    func test_reader_inside_process_holds_the_turn_open() throws {
        let timeline = try completed(tools: 2)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        let toolRow = try XCTUnwrap(plan.rows.first { item in
            if case .toolCall = item.kind { return true }
            return false
        })
        var state = TranscriptFoldState()
        state.readerTopRowID = toolRow.id
        XCTAssertTrue(TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: state))
        XCTAssertTrue(ids(TranscriptProcessFold.displayRows(plan, state: state)).contains(toolRow.id))
    }

    func test_reader_on_the_answer_does_not_hold_it_open() throws {
        let timeline = try completed(tools: 2)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        let answer = try XCTUnwrap(plan.rows.first { item in
            if case .assistantText = item.kind { return true }
            return false
        })
        var state = TranscriptFoldState()
        state.readerTopRowID = answer.id
        XCTAssertFalse(TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: state))
    }

    func test_reader_on_a_group_header_holds_the_turn_open() throws {
        let timeline = try completed(tools: 4, intermediate: true)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        let group = try XCTUnwrap(turn.groups.last)
        var state = TranscriptFoldState()
        state.readerTopRowID = group.key
        XCTAssertTrue(TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: state))
    }

    func test_manual_collapse_wins_over_reader_context() throws {
        let timeline = try completed(tools: 2)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        let toolRow = try XCTUnwrap(plan.rows.first { item in
            if case .toolCall = item.kind { return true }
            return false
        })
        var state = TranscriptFoldState()
        state.readerTopRowID = toolRow.id
        state.manualTurn[turn.key] = false
        XCTAssertFalse(TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: state))
    }

    // MARK: - Partial / edge

    func test_partial_turn_with_divider_is_foldable_and_marked_partial() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.toolCall(seq: 10, callId: "c1", name: "bash", turn: 4),
            ProcessFoldFixtures.toolResult(seq: 11, callId: "c1", turn: 4),
            ProcessFoldFixtures.assistant(seq: 12, text: "a", turn: 4),
            ProcessFoldFixtures.turnEnd(seq: 13, turn: 4),
        ])
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isFoldable)
        XCTAssertTrue(turn.isPartial)
        XCTAssertEqual(turn.turn, 4)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertEqual(rows.compactMap(header).count, 1)
        XCTAssertEqual(rows.last?.id, timeline.items.last?.id)
    }

    func test_no_final_answer_still_folds_to_header_and_divider() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.turnEnd(seq: 4),
        ])
        let rows = TranscriptProcessFold.displayRows(plan(timeline), state: TranscriptFoldState())
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.compactMap(header).count, 1)
        guard case .turnDivider = rows.last?.kind else { return XCTFail("divider must remain") }
    }

    func test_trailing_process_after_answer_is_hidden_when_folded_and_visible_when_expanded() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.assistant(seq: 3, text: "a"),
            ProcessFoldFixtures.toolCall(seq: 4, callId: "c1", name: "bash"),
            ProcessFoldFixtures.toolResult(seq: 5, callId: "c1"),
            ProcessFoldFixtures.turnEnd(seq: 6),
        ])
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isFoldable)
        let answer = try XCTUnwrap(timeline.items.first { if case .assistantText = $0.kind { return true }; return false })
        let tool = try XCTUnwrap(timeline.items.first { if case .toolCall = $0.kind { return true }; return false })
        let folded = ids(TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState()))
        XCTAssertTrue(folded.contains(answer.id))
        XCTAssertFalse(folded.contains(tool.id))
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        XCTAssertTrue(ids(TranscriptProcessFold.displayRows(plan, state: state)).contains(tool.id))
    }

    func test_ten_turns_twenty_tools_each_fit_the_history_budget() throws {
        var events: [[String: JSONValue]] = []
        var seq = 1
        for turn in 1...10 {
            events += ProcessFoldFixtures.completedTurn(turn: turn, startSeq: seq,
                                                         tools: 20, reasoning: 2)
            seq = (events.last?["seq"]?.intValue ?? seq) + 1
        }
        let timeline = try ProcessFoldFixtures.timeline(events)
        let plan = plan(timeline)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertLessThanOrEqual(Double(rows.count), Double(timeline.items.count) * 0.20,
                                 "folded history was \(rows.count) of \(timeline.items.count) rows")
        let questions = timeline.items.filter { if case .userMessage = $0.kind { return true }; return false }
        let answers = timeline.items.filter { if case .assistantText(let text) = $0.kind { return text.hasPrefix("answer") }; return false }
        for item in questions + answers {
            XCTAssertTrue(ids(rows).contains(item.id), "missing \(item.id)")
        }
    }

    func test_reveal_target_for_a_hidden_tool_row() throws {
        let timeline = try completed(tools: 2)
        let plan = plan(timeline)
        let tool = try XCTUnwrap(plan.rows.first { if case .toolCall = $0.kind { return true }; return false })
        let target = try XCTUnwrap(TranscriptProcessFold.revealTarget(rowID: tool.id, plan: plan))
        XCTAssertEqual(target.rowID, tool.id)
        XCTAssertNotNil(target.turnKey)
        XCTAssertTrue(plan.processRowIDs.contains(tool.id))
    }

    func test_running_turn_folds_completed_groups_and_keeps_the_active_one_open() throws {
        // 进行中：第一段过程（bash）已被中间回答封口，应折叠成组节点；
        // 第二段（read）仍在增长，保持展开。
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.toolResult(seq: 4, callId: "c1"),
            ProcessFoldFixtures.assistant(seq: 5, text: "first part done"),
            ProcessFoldFixtures.toolCall(seq: 6, callId: "c2", name: "read"),
            ProcessFoldFixtures.toolResult(seq: 7, callId: "c2"),
        ])
        let plan = plan(timeline, isTurnOpen: true)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isRunning)
        XCTAssertEqual(turn.groups.count, 2)

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        // 第一段组节点在，但成员被收起；第二段成员直接可见。
        let groupHeaders = rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let header) = item.kind, header.scope == .group { return header }
            return nil
        }
        XCTAssertEqual(groupHeaders.count, 1, "only the closed group gets a header")
        XCTAssertEqual(groupHeaders.first?.toolCount, 1)
        XCTAssertFalse(groupHeaders.first?.isExpanded ?? true)
        XCTAssertFalse(rows.contains { $0.id == timeline.items[1].id },
                       "closed group's tool call is hidden")
        XCTAssertTrue(rows.contains { $0.id == timeline.items[2].id },
                      "intermediate assistant text stays visible")
        XCTAssertTrue(rows.contains { $0.id == timeline.items[3].id },
                      "active group's tool call stays visible")
    }

    func test_running_turn_without_a_boundary_keeps_everything_visible() throws {
        // 进行中、只有一段连续过程：没有可封口的组，全部展开。
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.toolResult(seq: 4, callId: "c1"),
            ProcessFoldFixtures.toolCall(seq: 5, callId: "c2", name: "read"),
            ProcessFoldFixtures.toolResult(seq: 6, callId: "c2"),
        ])
        let plan = plan(timeline, isTurnOpen: true)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.groups.count, 1)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertFalse(rows.contains { header($0)?.scope == .group })
        XCTAssertEqual(rows.count, timeline.items.count)
    }

    func test_running_turn_group_header_expands_on_tap() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.toolResult(seq: 4, callId: "c1"),
            ProcessFoldFixtures.assistant(seq: 5, text: "first part done"),
            ProcessFoldFixtures.toolCall(seq: 6, callId: "c2", name: "read"),
            ProcessFoldFixtures.toolResult(seq: 7, callId: "c2"),
        ])
        let plan = plan(timeline, isTurnOpen: true)
        let turn = try XCTUnwrap(plan.turns.first)
        let closedGroup = try XCTUnwrap(turn.groups.first)
        var state = TranscriptFoldState()
        let collapsed = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertFalse(collapsed.contains { $0.id == timeline.items[1].id })

        state.expandedGroups.insert(closedGroup.key)
        let expanded = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertTrue(expanded.contains { $0.id == timeline.items[1].id })
    }

    func test_display_is_idempotent() throws {
        let timeline = try completed(tools: 3, intermediate: true)
        let plan = plan(timeline)
        var state = TranscriptFoldState()
        state.manualTurn[try XCTUnwrap(plan.turns.first).key] = true
        let first = ids(TranscriptProcessFold.displayRows(plan, state: state))
        let second = ids(TranscriptProcessFold.displayRows(plan, state: state))
        XCTAssertEqual(first, second)
    }

    func test_only_the_trailing_answer_run_stays_visible_when_folded() throws {
        // 过程里有中间回复，最后才是正式回答：收起时只留末尾那一段。
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.assistant(seq: 4, text: "intermediate"),
            ProcessFoldFixtures.toolCall(seq: 5, callId: "c2", name: "bash"),
            ProcessFoldFixtures.assistant(seq: 6, text: "final"),
            ProcessFoldFixtures.turnEnd(seq: 7),
        ])
        let plan = plan(timeline)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let texts = rows.compactMap { item -> String? in
            if case .assistantText(let text) = item.kind { return text }
            return nil
        }
        XCTAssertEqual(texts, ["final"], "intermediate prose is process; the final answer must stay visible when folded")
    }

    func test_prefetch_pager_covers_whole_range_in_bounded_windows() {
        var cursor = 1000
        var lowest = Int.max
        var batches = 0
        while let window = PrefetchPager.next(lower: 1, cursor: cursor) {
            XCTAssertLessThanOrEqual(window.count, PrefetchPager.window)
            XCTAssertEqual(window.upperBound, cursor - 1)
            lowest = min(lowest, window.lowerBound)
            batches += 1
            if PrefetchPager.isComplete(lower: 1, coveredLow: window.lowerBound) { break }
            cursor = window.lowerBound
        }
        XCTAssertEqual(lowest, 1, "the pager must reach lower instead of stopping halfway")
        XCTAssertEqual(batches, 7)
        XCTAssertTrue(PrefetchPager.isComplete(lower: 1, coveredLow: 1))
        XCTAssertFalse(PrefetchPager.isComplete(lower: 1, coveredLow: 151))
    }

    func test_header_counts_survive_replacing_the_summary_with_details() throws {
        // 摘要被明细替换前后，表头数字必须一致：前者=摘要计数，后者=明细行计数。
        var summarized = ChatTimeline()
        for event in [
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ["type": .string("+link/fold"), "seq": .int(3), "data": .object([
                "turn": .int(1), "startSeq": .int(3), "endSeq": .int(6),
                "toolCount": .int(3), "reasoningCount": .int(1),
                "messageCount": .int(1), "subagentCount": .int(0),
                "durationMs": .int(9_000),
            ])],
            ProcessFoldFixtures.assistant(seq: 7, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 8, turn: 1),
        ] { _ = summarized.apply(try ProcessFoldFixtures.record(event).event) }
        let summarizedTurn = try XCTUnwrap(
            TranscriptProcessFold.plan(items: summarized.items, isTurnOpen: false).turns.first)
        XCTAssertEqual(summarizedTurn.toolCount, 3)
        XCTAssertEqual(summarizedTurn.reasoningCount, 1)

        var detailed = ChatTimeline()
        for event in [
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.toolCall(seq: 4, callId: "c2", name: "bash"),
            ProcessFoldFixtures.toolCall(seq: 5, callId: "c3", name: "bash"),
            ProcessFoldFixtures.assistant(seq: 6, text: nil, reasoning: "why"),
            ProcessFoldFixtures.assistant(seq: 7, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 8, turn: 1),
        ] { _ = detailed.apply(try ProcessFoldFixtures.record(event).event) }
        let detailedTurn = try XCTUnwrap(
            TranscriptProcessFold.plan(items: detailed.items, isTurnOpen: false).turns.first)
        XCTAssertEqual(detailedTurn.toolCount, summarizedTurn.toolCount)
        XCTAssertEqual(detailedTurn.reasoningCount, summarizedTurn.reasoningCount)
    }

    // MARK: - 连接器折好下发的摘要（history-fold-summary）

    func test_prefetched_summary_folds_with_the_same_header_as_recent_turns() throws {
        var timeline = ChatTimeline()
        let events: [[String: JSONValue]] = [
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ["type": .string("+link/fold"), "seq": .int(3), "data": .object([
                "turn": .int(1), "startSeq": .int(3), "endSeq": .int(4),
                "finalSeq": .int(5), "dividerSeq": .int(6),
                "toolCount": .int(2), "reasoningCount": .int(1),
                "messageCount": .int(1), "subagentCount": .int(0),
                "endReason": .string("done"), "durationMs": .int(1200),
                "foldedCount": .int(2),
            ])],
            ProcessFoldFixtures.assistant(seq: 5, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 6, turn: 1, reason: "done"),
        ]
        for event in events { _ = timeline.apply(try ProcessFoldFixtures.record(event).event) }

        let plan = TranscriptProcessFold.plan(items: timeline.items, isTurnOpen: false)
        let turn = try XCTUnwrap(plan.turns.first)
        // 2026-10-18：预折摘要不再让整轮铺开，表头与近期轮次同一样式；
        // 计数取摘要里的值（明细没下发时按行数会漏）。
        XCTAssertTrue(turn.isFoldable)
        XCTAssertEqual(turn.toolCount, 2)
        XCTAssertEqual(turn.reasoningCount, 1)
        XCTAssertEqual(turn.duration ?? 0, 1.2, accuracy: 0.001)

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let headers = rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let header) = item.kind { return header }
            return nil
        }
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers.first?.toolCount, 2)
        XCTAssertEqual(headers.first?.isPrefetched, false, "prefetched turns use the normal header, not a separate summary row")
        XCTAssertTrue(rows.contains { item in
            if case .assistantText(let text) = item.kind { return text == "a" }
            return false
        })
    }


    func test_multiple_prefetched_headers_merge_into_one_row() throws {
        var timeline = ChatTimeline()
        let foldEvent = { (seq: Int, start: Int, end: Int, tools: Int) -> [String: JSONValue] in
            ["type": .string("+link/fold"), "seq": .int(seq), "data": .object([
                "turn": .int(1), "startSeq": .int(start), "endSeq": .int(end),
                "toolCount": .int(tools), "reasoningCount": .int(0),
                "messageCount": .int(1), "subagentCount": .int(0),
                "foldedCount": .int(2),
            ])]
        }
        let events: [[String: JSONValue]] = [
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            foldEvent(3, 3, 4, 2),
            ProcessFoldFixtures.assistant(seq: 5, text: "intermediate"),
            foldEvent(6, 6, 7, 3),
            ProcessFoldFixtures.assistant(seq: 8, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 9, turn: 1, reason: "done"),
        ]
        for event in events { _ = timeline.apply(try ProcessFoldFixtures.record(event).event) }

        let plan = TranscriptProcessFold.plan(items: timeline.items, isTurnOpen: false)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let headers = rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let header) = item.kind { return header }
            return nil
        }
        XCTAssertEqual(headers.count, 1, "one turn spanning pages still shows one process node")
        XCTAssertEqual(headers.first?.toolCount, 5, "counts are summed")
        XCTAssertEqual(headers.first?.startSeq, 3)
        XCTAssertEqual(headers.first?.endSeq, 7)
    }

}

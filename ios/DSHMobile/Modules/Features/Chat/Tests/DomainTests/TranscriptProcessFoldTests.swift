@testable import DSHChatDomain
import DSHKit
import XCTest

final class TranscriptProcessFoldTests: XCTestCase {

    // MARK: - Fixtures

    private func completed(tools: Int = 2, intermediate: Bool = false) throws -> ChatTimeline {
        try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: tools,
                                               reasoning: 1, intermediate: intermediate))
    }

    private func plan(_ timeline: ChatTimeline, running: Bool = false) -> TranscriptProcessFold.Plan {
        TranscriptProcessFold.plan(items: timeline.items,
                                   tail: ProcessFoldFixtures.tail(timeline, running: running),
                                   currentTurn: timeline.currentTurn)
    }

    private func plan(_ items: [TimelineItem], running: Bool = false) -> TranscriptProcessFold.Plan {
        let boundary: TranscriptTail.Boundary = running
            ? .open(turn: 1, startedAt: nil) : .closed(turn: 1, reason: "completed")
        return TranscriptProcessFold.plan(items: items,
                                          tail: TranscriptTail(boundary: boundary, showsTail: true),
                                          currentTurn: 1)
    }

    private func header(_ item: TimelineItem) -> TimelineProcessHeader? {
        guard case .processHeader(let header) = item.kind else { return nil }
        return header
    }

    private func ids(_ rows: [TimelineItem]) -> [String] { rows.map(\.id) }

    // MARK: - Folding

    func test_a_completed_turn_folds_to_one_turn_row_and_keeps_the_answer() throws {
        let timeline = try completed(tools: 2)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isFoldable)
        XCTAssertEqual(turn.toolCount, 2)
        XCTAssertEqual(turn.reasoningCount, 1)

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        // 一行轮次行取代原来的「折叠行 + 已完成分隔行」两行；回答始终可见。
        XCTAssertEqual(rows.count, 3, "folded rows: \(rows.map(\.id))")
        guard case .userMessage = rows[0].kind else { return XCTFail("first row must be the question") }
        let header = try XCTUnwrap(self.header(rows[1]))
        XCTAssertEqual(header.scope, .turn)
        XCTAssertFalse(header.isExpanded)
        XCTAssertEqual(header.toolCount, 2)
        guard case .assistantText(let answer) = rows[2].kind else { return XCTFail("second visible row must be the answer") }
        XCTAssertEqual(answer, "answer 1")
    }

    func test_answer_before_a_question_stays_visible_while_the_turn_is_open() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "帮我选"),
            ProcessFoldFixtures.assistant(seq: 3, text: "我的建议是 A"),
            ProcessFoldFixtures.toolCall(seq: 4, callId: "q1", name: "ask_user"),
        ])
        let plan = TranscriptProcessFold.plan(items: timeline.items, tail: ProcessFoldFixtures.tail(timeline, running: true),
                                              currentTurn: 1)
        let turn = try XCTUnwrap(plan.turns.first)
        let answerIDs = turn.answerIndexes.map { timeline.items[$0].id }
        XCTAssertTrue(timeline.items.contains { item in
            guard case .assistantText(let text) = item.kind else { return false }
            return text == "我的建议是 A" && answerIDs.contains(item.id)
        }, "提问前的正式回答不能折进过程：\(answerIDs)")
    }

    func test_steering_input_inside_a_running_turn_stays_visible() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "开始"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.steering(seq: 4, text: "插入的问题"),
            ProcessFoldFixtures.toolCall(seq: 5, callId: "c2", name: "read"),
        ])
        let plan = TranscriptProcessFold.plan(items: timeline.items, tail: ProcessFoldFixtures.tail(timeline, running: true),
                                              currentTurn: 1)
        let steering = try XCTUnwrap(timeline.items.first { $0.id == "user-steer-4" })
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertTrue(rows.contains { $0.id == steering.id },
                      "运行中插入的提问不能被折叠掉")
    }

    func test_a_send_image_tool_stays_visible_when_the_turn_is_collapsed() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "发张图"),
            ProcessFoldFixtures.assistant(seq: 3, text: "好，截图"),
            ProcessFoldFixtures.toolCall(seq: 4, callId: "img", name: "send_image"),
            ProcessFoldFixtures.toolResult(seq: 5, callId: "img", text: "shot.png"),
            ProcessFoldFixtures.assistant(seq: 6, text: "已发送"),
            ProcessFoldFixtures.turnEnd(seq: 7, turn: 1),
        ])
        XCTAssertTrue(timeline.items.contains { if case .toolCall = $0.kind { return true }; return false },
                      "timeline must contain the tool call: \(timeline.items.map(\.id))")
        let plan = TranscriptProcessFold.plan(items: timeline.items, tail: .unknown,
                                              currentTurn: 1)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.toolCount, 0, "交付工具不算过程")
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertTrue(rows.contains { item in
            guard case .toolCall(let invocation) = item.kind else { return false }
            return invocation.name == "send_image"
        }, "send_image 的卡片收起时也必须可见：\(rows.map(\.id))")
    }

    func test_the_turn_divider_is_never_projected() throws {
        // 收起、展开、失败、中断四种情况都不再输出分隔行：轮次行底部的 0.5pt 线
        // 承担边界职责，屏幕上不再有第二条「已完成」。
        for reason in ["completed", "error", "aborted", "max-steps"] {
            let timeline = try ProcessFoldFixtures.timeline([
                ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
                ProcessFoldFixtures.user(seq: 2, text: "q"),
                ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
                ProcessFoldFixtures.assistant(seq: 4, text: "a"),
                ProcessFoldFixtures.turnEnd(seq: 5, reason: reason),
            ])
            let plan = plan(timeline)
            let turn = try XCTUnwrap(plan.turns.first)
            for expanded in [false, true] {
                var state = TranscriptFoldState()
                state.manualTurn[turn.key] = expanded
                let rows = TranscriptProcessFold.displayRows(plan, state: state)
                XCTAssertFalse(rows.contains { if case .turnDivider = $0.kind { return true }; return false },
                               "divider leaked for \(reason) (expanded: \(expanded))")
                XCTAssertTrue(rows.contains { if case .assistantText(let text) = $0.kind { return text == "a" }; return false },
                              "answer was folded away for \(reason)")
            }
        }
    }

    func test_expanding_a_turn_shows_group_rows_and_expanding_a_group_restores_its_steps() throws {
        let timeline = try completed(tools: 3, intermediate: true)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true

        let groupsOnly = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertEqual(groupsOnly.compactMap { header($0)?.scope == .group ? true : nil }.count,
                       turn.groups.count)
        XCTAssertTrue(groupsOnly.contains { if case .assistantText(let text) = $0.kind { return text == "still working 1" }; return false })
        // 组默认收起：展开轮次这时还看不到任何步骤卡。
        XCTAssertFalse(groupsOnly.contains { item in
            if case .toolCall = item.kind { return true }
            return false
        })

        for group in turn.groups { state.expandedGroups.insert(group.key) }
        let fullyOpen = TranscriptProcessFold.displayRows(plan, state: state)
        let withoutProxies = fullyOpen.filter { self.header($0) == nil }
        let originals = timeline.items.filter { if case .turnDivider = $0.kind { return false }; return true }
        XCTAssertEqual(ids(withoutProxies), ids(originals),
                       "every original row except the dropped divider must be back, in order")
    }

    func test_after_a_cancel_the_group_row_is_no_longer_marked_running() throws {
        // 运行中 → 取消：同一个分组行的 isRunning 必须翻回 false，
        // 行签名（`TimelineRowSignature`）据此重载，标题从「正在分析请求」回到静态短语。
        var timeline = ChatTimeline()
        let running: [[String: JSONValue]] = [
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
        ]
        for event in running { _ = timeline.apply(try ProcessFoldFixtures.record(event).event) }
        let runningPlan = TranscriptProcessFold.plan(items: timeline.items, tail: ProcessFoldFixtures.tail(timeline, running: true),
                                                     currentTurn: 1)
        let runningTurn = try XCTUnwrap(runningPlan.turns.first)
        XCTAssertFalse(runningTurn.groups.isEmpty)
        let runningHeaders = TranscriptProcessFold.displayRows(runningPlan, state: TranscriptFoldState())
            .compactMap { item -> TimelineProcessHeader? in
                if case .processHeader(let header) = item.kind { return header }
                return nil
            }
        let runningHeader = try XCTUnwrap(runningHeaders.first { $0.scope == .group })
        XCTAssertTrue(runningHeader.isRunning)
        XCTAssertTrue(ProcessFoldText.runningGroupTitle(activity: .commands, detail: "x")
            .hasPrefix("正在"))

        _ = timeline.apply(try ProcessFoldFixtures.record(
            ProcessFoldFixtures.turnEnd(seq: 4, turn: 1, reason: "interrupted")).event)
        let endedPlan = TranscriptProcessFold.plan(items: timeline.items, tail: .unknown,
                                                   currentTurn: 1)
        let endedTurn = try XCTUnwrap(endedPlan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[endedTurn.key] = true
        let endedHeaders = TranscriptProcessFold.displayRows(endedPlan, state: state)
            .compactMap { item -> TimelineProcessHeader? in
                if case .processHeader(let header) = item.kind { return header }
                return nil
            }
        let endedGroup = try XCTUnwrap(endedHeaders.first { $0.scope == .group })
        XCTAssertFalse(endedGroup.isRunning, "取消后分组行不再运行")
        XCTAssertEqual(ProcessFoldText.groupTitle(endedGroup.activityCounts), "执行了命令")
        XCTAssertNotEqual(TimelineRowSignature.of(runningHeader.item),
                          TimelineRowSignature.of(endedGroup.item),
                          "签名必须变化，否则列表不会重载这一行")
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
        // 没有过程就不出轮次行；分隔行也一并消失，只剩讲话与回答。
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertFalse(rows.contains { header($0) != nil })
        XCTAssertFalse(rows.contains { if case .turnDivider = $0.kind { return true }; return false })
        let expected = timeline.items.filter { if case .turnDivider = $0.kind { return false }; return true }
        XCTAssertEqual(ids(rows), ids(expected))
    }

    func test_running_turn_has_no_turn_row_and_one_collapsed_group_row() throws {
        // 运行中没有轮次行：当前分组行就是过程区的入口（桌面 board3）。
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
        ])
        let plan = plan(timeline, running: true)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isRunning)
        XCTAssertFalse(turn.isFoldable)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertFalse(rows.contains { header($0)?.scope == .turn }, "a running turn has no turn row")
        XCTAssertFalse(rows.contains { if case .turnDivider = $0.kind { return true }; return false })
        let groupHeaders = rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let header) = item.kind, header.scope == .group { return header }
            return nil
        }
        XCTAssertEqual(groupHeaders.count, 1, "the current group row is the only process row")
        XCTAssertEqual(groupHeaders.first?.isRunning, true)
        XCTAssertFalse(rows.contains { if case .toolCall = $0.kind { return true }; return false },
                       "the running group is collapsed until the reader taps it")
    }

    func test_error_turn_folds_like_a_normal_completion() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.toolResult(seq: 4, callId: "c1", isError: true),
            ProcessFoldFixtures.turnEnd(seq: 5, reason: "error"),
        ])
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isFoldable)
        XCTAssertTrue(turn.isFailed)
        XCTAssertTrue(turn.canCollapse)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let header = try XCTUnwrap(rows.compactMap(header).first)
        XCTAssertEqual(header.scope, .turn)
        XCTAssertFalse(header.isExpanded)
        XCTAssertTrue(header.isFoldable, "error keeps the arrow and stays tappable")
        XCTAssertTrue(ProcessFoldText.turnLabel(endReason: header.endReason, duration: header.duration) == "处理失败")
    }

    func test_interrupted_turn_stays_open_without_an_arrow() throws {
        // 桌面实拍：`<button disabled aria-expanded="true">Stopped</button>` —— 常开、
        // 无箭头、按钮不可点，内容（分组行、讲话、回答）直接铺开。
        for reason in ["aborted", "interrupted", "cancelled"] {
            let timeline = try ProcessFoldFixtures.timeline([
                ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
                ProcessFoldFixtures.user(seq: 2, text: "q"),
                ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
                ProcessFoldFixtures.assistant(seq: 4, text: "still working"),
                ProcessFoldFixtures.toolCall(seq: 5, callId: "c2", name: "read"),
                ProcessFoldFixtures.assistant(seq: 6, text: "answer"),
                ProcessFoldFixtures.turnEnd(seq: 7, reason: reason),
            ])
            var state = TranscriptFoldState()
            state.manualTurn["turn-process:1"] = false
            let plan = plan(timeline)
            let turn = try XCTUnwrap(plan.turns.first)
            XCTAssertTrue(turn.isStopped, reason)
            XCTAssertFalse(turn.canCollapse, reason)
            let rows = TranscriptProcessFold.displayRows(plan, state: state)
            let turnRow = try XCTUnwrap(rows.compactMap(header).first, reason)
            XCTAssertEqual(turnRow.scope, .turn, reason)
            XCTAssertTrue(turnRow.isExpanded, reason)
            XCTAssertFalse(turnRow.isFoldable, "no arrow, button disabled (\(reason))")
            XCTAssertEqual(rows.compactMap { header($0)?.scope == .group ? true : nil }.count, 2, reason)
            XCTAssertTrue(rows.contains { if case .assistantText(let text) = $0.kind { return text == "still working" }; return false }, reason)
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

    func test_error_notice_does_not_prevent_folding() throws {
        // 失败与正常完成同一套折叠（M5）：报错不再把整轮铺开。
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.notice(seq: 4, text: "boom", isError: true),
            ProcessFoldFixtures.assistant(seq: 5, text: "a"),
            ProcessFoldFixtures.turnEnd(seq: 6),
        ])
        let turn = try XCTUnwrap(plan(timeline).turns.first)
        XCTAssertTrue(turn.isFoldable)
        XCTAssertTrue(turn.hasFailure)
        let rows = TranscriptProcessFold.displayRows(plan(timeline), state: TranscriptFoldState())
        XCTAssertFalse(rows.contains { if case .notice = $0.kind { return true }; return false })
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

    func test_a_single_group_still_gets_a_group_row() throws {
        // 桌面单步轮次展开后也先看到一条分组行（M3）；组默认收起。
        let timeline = try completed(tools: 2)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.groups.count, 1)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        let groupHeader = try XCTUnwrap(rows.compactMap(header).first { $0.scope == .group })
        XCTAssertFalse(groupHeader.isExpanded, "groups start collapsed")
        XCTAssertEqual(groupHeader.toolCount, 2)
        XCTAssertFalse(rows.contains { if case .toolCall = $0.kind { return true }; return false })
    }

    func test_expanding_one_group_only_reveals_that_group() throws {
        let timeline = try completed(tools: 4, intermediate: true)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        let first = try XCTUnwrap(turn.groups.first)
        state.expandedGroups.insert(first.key)
        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertTrue(rows.contains { $0.id == timeline.items[try! XCTUnwrap(first.indexes.first)].id })
        let second = try XCTUnwrap(turn.groups.last)
        XCTAssertFalse(rows.contains { $0.id == timeline.items[try! XCTUnwrap(second.indexes.first)].id })
    }

    // MARK: - Defaults and reader context

    /// 读者手工展开/收起是**唯一**的整轮展开依据（M3）。
    ///
    /// 旧实现还要读一个 `readerTopRowID`（列表宿主回传的顶部可见行）来"不把内容从
    /// 读者脚下收走"——那条通路的语义已改成"轮次关闭那一刻的一次性保位"，判定在
    /// `ChatModel.noteTailTransition` 上（用例在 `ChatModelProcessFoldTests`）。
    func test_manual_toggle_is_the_only_whole_turn_input() throws {
        let timeline = try completed(tools: 2)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        let toolRow = try XCTUnwrap(plan.rows.first { item in
            if case .toolCall = item.kind { return true }
            return false
        })
        var state = TranscriptFoldState()
        XCTAssertFalse(TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: state),
                       "默认收起：已完成的轮次不等任何测量值")
        XCTAssertFalse(ids(TranscriptProcessFold.displayRows(plan, state: state)).contains(toolRow.id))

        state.manualTurn[turn.key] = true
        XCTAssertTrue(TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: state))
        // 展开整轮先看到分组行；组默认收起，组内过程行仍不出现（桌面同款）。
        let group = try XCTUnwrap(turn.groups.first)
        XCTAssertTrue(ids(TranscriptProcessFold.displayRows(plan, state: state)).contains(group.key))
        XCTAssertFalse(ids(TranscriptProcessFold.displayRows(plan, state: state)).contains(toolRow.id))

        state.expandedGroups.insert(group.key)
        XCTAssertTrue(ids(TranscriptProcessFold.displayRows(plan, state: state)).contains(toolRow.id))

        state.manualTurn[turn.key] = false
        XCTAssertFalse(TranscriptProcessFold.isTurnExpanded(turn, plan: plan, state: state))
        XCTAssertFalse(ids(TranscriptProcessFold.displayRows(plan, state: state)).contains(toolRow.id))
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
        guard case .assistantText = rows.last?.kind else {
            return XCTFail("the answer must be the last row once the divider is gone")
        }
    }

    func test_no_final_answer_still_folds_to_a_single_turn_row() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.turnEnd(seq: 4),
        ])
        let rows = TranscriptProcessFold.displayRows(plan(timeline), state: TranscriptFoldState())
        // 问题 + 轮次行：没有回答、也没有分隔行。
        XCTAssertEqual(rows.count, 2, "rows: \(rows.map(\.id))")
        XCTAssertEqual(rows.compactMap(header).count, 1)
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
        XCTAssertFalse(ids(TranscriptProcessFold.displayRows(plan, state: state)).contains(tool.id),
                       "groups are collapsed until the reader opens them")
        for group in turn.groups { state.expandedGroups.insert(group.key) }
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

    func test_running_turn_shows_all_groups_collapsed_with_the_last_one_live() throws {
        // 进行中：两条分组行都在，都是收起态；最后一条（仍在增长）标记为运行时行。
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.toolResult(seq: 4, callId: "c1"),
            ProcessFoldFixtures.assistant(seq: 5, text: "first part done"),
            ProcessFoldFixtures.toolCall(seq: 6, callId: "c2", name: "read"),
            ProcessFoldFixtures.toolResult(seq: 7, callId: "c2"),
        ])
        let plan = plan(timeline, running: true)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isRunning)
        XCTAssertEqual(turn.groups.count, 2)

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let groupHeaders = rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let header) = item.kind, header.scope == .group { return header }
            return nil
        }
        XCTAssertEqual(groupHeaders.count, 2)
        XCTAssertEqual(groupHeaders.filter(\.isRunning).count, 1, "only the growing group is live")
        XCTAssertEqual(groupHeaders.last?.isRunning, true)
        XCTAssertFalse(rows.contains { $0.id == timeline.items[1].id }, "collapsed group hides its steps")
        XCTAssertTrue(rows.contains { $0.id == timeline.items[2].id },
                      "intermediate assistant text stays visible")
        XCTAssertFalse(rows.contains { $0.id == timeline.items[3].id })
    }

    func test_running_turn_with_a_single_group_still_shows_one_group_row() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.toolResult(seq: 4, callId: "c1"),
            ProcessFoldFixtures.toolCall(seq: 5, callId: "c2", name: "read"),
            ProcessFoldFixtures.toolResult(seq: 6, callId: "c2"),
        ])
        let plan = plan(timeline, running: true)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.groups.count, 1)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let groupHeader = try XCTUnwrap(rows.compactMap(header).first { $0.scope == .group })
        XCTAssertTrue(groupHeader.isRunning)
        XCTAssertFalse(rows.contains { if case .toolCall = $0.kind { return true }; return false })
    }

    func test_running_turn_group_row_expands_on_tap() throws {
        let timeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "c1", name: "bash"),
            ProcessFoldFixtures.toolResult(seq: 4, callId: "c1"),
        ])
        let plan = plan(timeline, running: true)
        let turn = try XCTUnwrap(plan.turns.first)
        let group = try XCTUnwrap(turn.groups.first)
        var state = TranscriptFoldState()
        XCTAssertFalse(TranscriptProcessFold.displayRows(plan, state: state)
            .contains { $0.id == timeline.items[1].id })

        state.expandedGroups.insert(group.key)
        XCTAssertTrue(TranscriptProcessFold.displayRows(plan, state: state)
            .contains { $0.id == timeline.items[1].id })
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
            TranscriptProcessFold.plan(items: summarized.items, tail: .unknown).turns.first)
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
            TranscriptProcessFold.plan(items: detailed.items, tail: .unknown).turns.first)
        XCTAssertEqual(detailedTurn.toolCount, summarizedTurn.toolCount)
        XCTAssertEqual(detailedTurn.reasoningCount, summarizedTurn.reasoningCount)
    }

    func test_prefetched_turn_without_a_divider_still_folds_as_one() throws {
        // 窗口里没有结束分隔线，但预折摘要本身就说明这一段已完成：
        // 不能再把摘要当成一条单独的折叠行嵌在轮次里（展开后还会看到"小折叠"）。
        var timeline = ChatTimeline()
        let events: [[String: JSONValue]] = [
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "q"),
            ["type": .string("+link/fold"), "seq": .int(3), "data": .object([
                "turn": .int(1), "startSeq": .int(3), "endSeq": .int(4),
                "toolCount": .int(2), "reasoningCount": .int(1),
                "messageCount": .int(1), "subagentCount": .int(0),
            ])],
            ProcessFoldFixtures.assistant(seq: 5, text: "a"),
        ]
        for event in events { _ = timeline.apply(try ProcessFoldFixtures.record(event).event) }
        let plan = TranscriptProcessFold.plan(items: timeline.items, tail: .unknown)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isFoldable)
        var expanded = TranscriptFoldState()
        expanded.manualTurn[turn.key] = true
        let rows = TranscriptProcessFold.displayRows(plan, state: expanded)
        XCTAssertFalse(rows.contains { item in
            if case .processHeader(let header) = item.kind { return header.isPrefetched }
            return false
        }, "expanded turn must not keep a summary row")
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

        let plan = TranscriptProcessFold.plan(items: timeline.items, tail: .unknown)
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

        let plan = TranscriptProcessFold.plan(items: timeline.items, tail: .unknown)
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

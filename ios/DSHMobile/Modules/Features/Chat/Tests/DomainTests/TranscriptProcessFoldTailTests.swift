@testable import DSHChatDomain
import DSHKit
import XCTest

/// 投影的边界口径（设计 `20261027-折叠抖动-方案A.md` M3 / A1 的投影半边 + A4）。
///
/// 两条硬约束写在这里当护栏：
/// 1. `TranscriptFoldState` 里只有**读者动作**（轮/组/步骤三个集合），任何"位置、
///    几何、可见"字段都不许进来——投影的入参里不存在测量值，"投影幂等"因此是
///    类型事实，不是约定。
/// 2. 尾轮边界未知时输出**一行固定高度占位行**，不铺开原始过程行；窗口不在会话
///    尾部（搜索跳转）时两者都不做，表现与改动前一致。
final class TranscriptProcessFoldTailTests: XCTestCase {

    // MARK: - 夹具

    /// 窗口从一个轮次的中间开始：只有过程行与一条尾部回答，没有任何边界行。
    private func cutWindow(middleAnswer: Bool = false) throws -> [TimelineItem] {
        var events: [[String: JSONValue]] = [
            ProcessFoldFixtures.toolCall(seq: 100, callId: "c1", name: "bash", turn: 7),
            ProcessFoldFixtures.toolResult(seq: 101, callId: "c1", turn: 7),
            ProcessFoldFixtures.assistant(seq: 102, reasoning: "想想", turn: 7),
            ProcessFoldFixtures.toolCall(seq: 103, callId: "c2", name: "read", turn: 7),
            ProcessFoldFixtures.toolResult(seq: 104, callId: "c2", turn: 7),
        ]
        if middleAnswer {
            events.append(ProcessFoldFixtures.assistant(seq: 105, text: "中间讲话", turn: 7))
        }
        events.append(ProcessFoldFixtures.assistant(seq: 106, text: "尾部回答", turn: 7))
        return try ProcessFoldFixtures.timeline(events).items
    }

    private func plan(_ items: [TimelineItem],
                      tail: TranscriptTail,
                      currentTurn: Int = 0) -> TranscriptProcessFold.Plan {
        TranscriptProcessFold.plan(items: items, tail: tail, currentTurn: currentTurn)
    }

    private func placeholders(_ rows: [TimelineItem]) -> [TimelineProcessPlaceholder] {
        rows.compactMap { item -> TimelineProcessPlaceholder? in
            if case .processPlaceholder(let value) = item.kind { return value }
            return nil
        }
    }

    // MARK: - 边界未知：一行占位行，不铺开

    func test_unknown_tail_projects_one_placeholder_and_no_raw_process_rows() throws {
        let items = try cutWindow()
        let plan = plan(items, tail: TranscriptTail(boundary: .unknown, showsTail: true))
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())

        let placeholders = placeholders(rows)
        XCTAssertEqual(placeholders.count, 1, "恰好一行占位行：\(rows.map(\.id))")
        XCTAssertEqual(placeholders.first?.id, "process-unknown:100",
                       "身份与排序键取这一轮的起点 seq")
        XCTAssertEqual(placeholders.first?.startSeq, 100,
                       "排序键取这一轮的起点 seq，裁剪前缀按它比较")
        XCTAssertEqual(placeholders.first?.state, .unresolved, "投影只搬运动作状态，自己不臆造")
        // 原始过程行一条都不许出现：过去「整段铺开」正是首帧形态跳变的原因。
        XCTAssertFalse(rows.contains { if case .toolCall = $0.kind { return true }; return false },
                       "过程行不许铺开：\(rows.map(\.id))")
        XCTAssertFalse(rows.contains { if case .reasoning = $0.kind { return true }; return false })
        // 尾部回答是读者的内容，不是过程细节：它跟着占位行一起留着。
        XCTAssertTrue(rows.contains { item in
            if case .assistantText(let text) = item.kind { return text == "尾部回答" }
            return false
        }, "尾部回答必须可见：\(rows.map(\.id))")
    }

    func test_unknown_tail_keeps_the_leading_user_message() throws {
        var events: [[String: JSONValue]] = [
            ProcessFoldFixtures.user(seq: 90, text: "跑一下构建", turn: 7),
            ProcessFoldFixtures.toolCall(seq: 91, callId: "c1", name: "bash", turn: 7),
            ProcessFoldFixtures.toolResult(seq: 92, callId: "c1", turn: 7),
        ]
        events.append(ProcessFoldFixtures.assistant(seq: 93, text: "构建通过", turn: 7))
        let items = try ProcessFoldFixtures.timeline(events).items
        let rows = TranscriptProcessFold.displayRows(
            plan(items, tail: TranscriptTail(boundary: .unknown, showsTail: true)),
            state: TranscriptFoldState())
        guard case .userMessage = rows.first?.kind else {
            return XCTFail("前导用户消息必须在最上面：\(rows.map(\.id))")
        }
        XCTAssertEqual(placeholders(rows).count, 1)
        XCTAssertEqual(rows.count, 3, "用户消息 + 占位行 + 回答：\(rows.map(\.id))")
    }

    // MARK: - 边界已结束（窗口里没有分隔行）：折叠，不铺开

    func test_closed_tail_without_divider_folds_instead_of_spreading() throws {
        let items = try cutWindow()
        let plan = plan(items,
                        tail: TranscriptTail(boundary: .closed(turn: 7, reason: "completed"),
                                             showsTail: true),
                        currentTurn: 7)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isFoldable, "边界说这一轮结束了，就是可折叠，不必等分隔行")

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertEqual(rows.count, 2, "一条轮次行 + 尾部回答：\(rows.map(\.id))")
        guard case .processHeader(let header) = rows[0].kind else {
            return XCTFail("第一行是轮次行")
        }
        XCTAssertEqual(header.scope, .turn)
        XCTAssertFalse(header.isExpanded, "已完成的轮默认收起")
        XCTAssertEqual(header.turn, 7)
        guard case .assistantText(let answer) = rows[1].kind else {
            return XCTFail("第二行是尾部回答")
        }
        XCTAssertEqual(answer, "尾部回答")
        XCTAssertFalse(rows.contains { if case .toolCall = $0.kind { return true }; return false })
        XCTAssertTrue(placeholders(rows).isEmpty, "边界已确认就不该有占位行")
    }

    func test_closed_tail_is_not_running() throws {
        let items = try cutWindow()
        let plan = plan(items,
                        tail: TranscriptTail(boundary: .closed(turn: 7, reason: "interrupted"),
                                             showsTail: true),
                        currentTurn: 7)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertFalse(turn.isRunning)
        XCTAssertFalse(turn.isBoundaryUnknown)
    }

    // MARK: - 窗口不在尾部（搜索跳转）：表现与改动前一致

    func test_detached_window_does_not_treat_bottom_segment_as_tail() throws {
        let items = try cutWindow()
        // 搜索跳转打开的中间窗口：边界原样带过来（这里是最常见的一种——开着），
        // 但窗口底下不是会话尾部，所以末段既不算 running、也不出占位行。
        for boundary in [TranscriptTail.Boundary.open(turn: 7, startedAt: nil),
                         .closed(turn: 7, reason: "completed"),
                         .unknown] {
            let plan = plan(items, tail: TranscriptTail(boundary: boundary, showsTail: false))
            let turn = try XCTUnwrap(plan.turns.first)
            XCTAssertFalse(turn.isRunning, "中间窗口的末段不许标成 running（\(boundary)）")
            XCTAssertFalse(turn.isBoundaryUnknown, "中间窗口不许出占位行（\(boundary)）")
            XCTAssertFalse(turn.isFoldable, "没有分隔行就不折叠，与改动前一致（\(boundary)）")
            let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
            XCTAssertTrue(placeholders(rows).isEmpty)
            XCTAssertEqual(rows.count, items.count - 0, "原始行原样铺开：\(rows.map(\.id))")
        }
    }

    // MARK: - 运行中的尾轮

    func test_running_tail_projects_groups_and_no_turn_header() throws {
        let items = try cutWindow()
        let plan = plan(items, tail: TranscriptTail(boundary: .open(turn: 7, startedAt: nil),
                                                    showsTail: true),
                        currentTurn: 7)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isRunning)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertFalse(rows.contains { item in
            if case .processHeader(let header) = item.kind, header.scope == .turn { return true }
            return false
        }, "运行中的轮次没有轮次行")
        XCTAssertTrue(placeholders(rows).isEmpty)
    }

    // MARK: - 投影幂等（防回潮守门）

    func test_projection_is_idempotent_under_the_same_plan_and_state() throws {
        let items = try cutWindow(middleAnswer: true) + []
        let plan = plan(items, tail: TranscriptTail(boundary: .unknown, showsTail: true))
        let state = TranscriptFoldState()
        let first = TranscriptProcessFold.displayRows(plan, state: state)
        for _ in 0..<100 {
            XCTAssertEqual(first.map(\.id),
                           TranscriptProcessFold.displayRows(plan, state: state).map(\.id))
        }
        XCTAssertTrue(state.manualTurn.isEmpty, "投影本身不许写读者动作")
        XCTAssertTrue(state.expandedGroups.isEmpty)
        XCTAssertTrue(state.expandedSteps.isEmpty)
    }

    func test_projection_ignores_the_reader_position() throws {
        // 读者停在哪里都不能影响投影：`TranscriptFoldState` 里已经没有这个字段了。
        // 这条用例是防回潮守门——把"顶部可见行"塞回折叠态就会让它红。
        let items = try cutWindow()
        let plan = plan(items,
                        tail: TranscriptTail(boundary: .closed(turn: 7, reason: "completed"),
                                             showsTail: true),
                        currentTurn: 7)
        let base = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        var state = TranscriptFoldState()
        state.expandedGroups.insert("process-group:7:100")
        let onlyGroups = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertEqual(base.map(\.id), onlyGroups.map(\.id),
                       "读者动作只有展开组，收起态的轮次不受影响")

        state.manualTurn[plan.turns[0].key] = false
        XCTAssertEqual(base.map(\.id),
                       TranscriptProcessFold.displayRows(plan, state: state).map(\.id),
                       "读者亲手收起，与默认收起是同一结果")
    }
}

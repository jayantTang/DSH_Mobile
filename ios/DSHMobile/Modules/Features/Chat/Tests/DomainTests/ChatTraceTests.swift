import DSHKit
import XCTest
@testable import DSHChatDomain

/// 折叠/取页事件字段的纯函数：字段名与排序是解析侧的契约，不能随手改。
final class ChatTraceTests: XCTestCase {
    func testFoldFieldsSortReasons() {
        let fields = FoldTrace.fields(turns: 5, foldable: 3, running: 1, openCompleted: 1,
                                      reasons: ["noProcess": 2, "gap": 1])
        XCTAssertEqual(fields["turns"], "5")
        XCTAssertEqual(fields["foldable"], "3")
        XCTAssertEqual(fields["running"], "1")
        XCTAssertEqual(fields["open"], "1")
        XCTAssertEqual(fields["why"], "gap:1,noProcess:2")
    }

    func testFoldFieldsOmitWhyWhenNothingOpen() {
        let fields = FoldTrace.fields(turns: 2, foldable: 2, running: 0, openCompleted: 0, reasons: [:])
        XCTAssertNil(fields["why"])
    }

    // MARK: - 尾轮边界事件（M8 的 tail.boundary）

    func testTailTraceNamesTheThreeBoundaries() {
        XCTAssertEqual(TailTrace.name(.unknown), "unknown")
        XCTAssertEqual(TailTrace.name(.open(turn: 2, startedAt: nil)), "open")
        XCTAssertEqual(TailTrace.name(.closed(turn: 2, reason: "completed")), "closed")
    }

    func testTailTraceFieldsCarryFromToTurnHoldAndPersistence() {
        let fields = TailTrace.fields(from: .open(turn: 2, startedAt: nil),
                                      to: .closed(turn: 2, reason: "completed"),
                                      hold: "applied", persisted: false)
        XCTAssertEqual(fields, [
            "from": "open", "to": "closed", "turn": "2",
            "hold": "applied", "persisted": "0",
        ], "字段名与取值是验收口径（持 Phase 1 无持久化副本）")
        XCTAssertEqual(TailTrace.fields(from: .unknown, to: .closed(turn: 7, reason: nil),
                                        hold: "skipped:noMeasurement", persisted: true)["persisted"],
                       "1")
        XCTAssertEqual(TailTrace.fields(from: .unknown, to: .open(turn: 0, startedAt: nil),
                                        hold: "none", persisted: false)["turn"], "0")
    }

    // MARK: - 形态事件（M8'-1）

    /// 五种 shape 的判定口径：词表固定，判定顺序即优先级。
    @MainActor
    func test_fold_shape_vocabulary_is_stable() throws {
        let emptyPlan = TranscriptProcessFold.plan(items: [], tail: .unknown)
        let state = TranscriptFoldState()
        XCTAssertEqual(FoldTrace.shape(rows: [], plan: emptyPlan, state: state), .empty,
                       "空帧：一行都没有，不是一个折叠形态（ARCH-REVIEW 3 §12.4）")
        XCTAssertEqual(FoldTrace.shape(
            rows: [TimelineProcessPlaceholder(turn: 1, startSeq: 3).item],
            plan: emptyPlan, state: state), .unknown)
        XCTAssertEqual(FoldTrace.shape(rows: [TimelineRunningLine(since: Date()).item],
                                       plan: emptyPlan, state: state), .running)

        let timeline = try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: 3))
        let plan = TranscriptProcessFold.plan(items: timeline.items,
                                              tail: ProcessFoldFixtures.tail(timeline, running: false),
                                              currentTurn: timeline.currentTurn)
        let foldedRows = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertEqual(FoldTrace.shape(rows: foldedRows, plan: plan, state: state), .folded)

        var expanded = TranscriptFoldState()
        let key = try XCTUnwrap(plan.turns.first?.key)
        expanded.manualTurn[key] = true
        let expandedRows = TranscriptProcessFold.displayRows(plan, state: expanded)
        XCTAssertEqual(FoldTrace.shape(rows: expandedRows, plan: plan, state: expanded), .expanded)
    }

    /// 空帧：`rows==0` 只能是 `empty`，绝不能落成 `mixed` 或 `folded`。
    @MainActor
    func test_fold_shape_is_empty_when_there_are_no_rows() throws {
        let state = TranscriptFoldState()
        // 计划里有可折轮次，但这一帧一行都没交出来（重建期的空屏）。
        let timeline = try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: 2))
        let plan = TranscriptProcessFold.plan(
            items: timeline.items,
            tail: ProcessFoldFixtures.tail(timeline, running: false),
            currentTurn: timeline.currentTurn)
        XCTAssertFalse(plan.turns.isEmpty, "前置：计划里有轮次")
        XCTAssertEqual(FoldTrace.shape(rows: [], plan: plan, state: state), .empty)
    }

    /// `mixed` 只用于"**有过程行**但既不可折也不在跑"；没有过程行的整窗是 `folded`。
    @MainActor
    func test_fold_shape_is_mixed_only_when_the_window_has_process_rows() throws {
        let state = TranscriptFoldState()
        // ① 有一段过程行、又不是尾部窗口（搜索跳到中间）：不可折、不在跑 → mixed。
        let cut = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.user(seq: 1, text: "q"),
            ProcessFoldFixtures.toolCall(seq: 2, callId: "c-1", name: "bash"),
        ])
        let cutTail = TranscriptTail(boundary: .unknown, showsTail: false)
        let cutPlan = TranscriptProcessFold.plan(items: cut.items, tail: cutTail)
        XCTAssertFalse(cutPlan.processRowIDs.isEmpty, "前置：这一段有过程行")
        let cutRows = TranscriptProcessFold.displayRows(cutPlan, state: state)
        XCTAssertFalse(cutRows.isEmpty)
        XCTAssertEqual(FoldTrace.shape(rows: cutRows, plan: cutPlan, state: state), .mixed)

        // ② 整窗只有一条讲话（没有任何过程行）：不是 mixed，是 folded。
        // 注意不能用"讲话 + 回答"当夹具：尾部段不可折时回答本身会被算进过程行
        //（`processIndexes` 取 missing-answer 区间），那属于 mixed 的形态。
        let plain = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.user(seq: 1, text: "q"),
        ])
        let plainPlan = TranscriptProcessFold.plan(items: plain.items, tail: cutTail)
        XCTAssertTrue(plainPlan.processRowIDs.isEmpty, "前置：这一段没有过程行")
        let plainRows = TranscriptProcessFold.displayRows(plainPlan, state: state)
        XCTAssertFalse(plainRows.isEmpty)
        XCTAssertEqual(FoldTrace.shape(rows: plainRows, plan: plainPlan, state: state), .folded,
                       "没有过程区可展开时，收起态就是它唯一的样子")
    }

    func test_fold_shape_fields_are_the_judged_columns() {
        let tail = TranscriptTail(boundary: .open(turn: 2, startedAt: nil), showsTail: false)
        let fields = FoldTrace.shapeFields(shape: .running, session: "s-1", rows: 12, tail: tail,
                                           turns: 3, foldable: 2, hold: 1)
        XCTAssertEqual(fields, [
            "session": "s-1", "rows": "12", "shape": "running", "tail": "open",
            "reachesTail": "0", "turns": "3", "foldable": "2", "hold": "1",
        ])
    }

    /// 同签名 10 次只发 1 条（节流状态与 `fold.summary` 各一份，不互相吞）。
    @MainActor
    func test_fold_shape_is_throttled_per_signature() {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        FoldTrace.resetShapeThrottleForTesting()
        ChatProbe.shared.probeNote = { kind, _, _ in
            if kind == "fold.shape" { counter.value += 1 }
        }
        defer {
            ChatProbe.shared.probeNote = nil
            FoldTrace.resetShapeThrottleForTesting()
        }
        let plan = TranscriptProcessFold.plan(items: [], tail: .unknown)
        for _ in 0..<10 {
            FoldTrace.noteShape(rows: [], plan: plan, state: TranscriptFoldState(),
                                tail: .unknown, session: "s-1")
        }
        XCTAssertEqual(counter.value, 1, "同签名只发一条")
    }

    // MARK: - 冲突与落库失败（M8'-2 / M2'-4）

    func test_tail_conflict_fields() {
        XCTAssertEqual(TailTrace.conflictFields(session: "s-1", turn: 5, closed: 5), [
            "session": "s-1", "turn": "5", "closed": "5",
        ])
    }

    func test_persist_failed_fields_carry_turn_and_boundary() {
        XCTAssertEqual(TailTrace.persistFailedFields(session: "s-1", turn: 3,
                                                     to: "open", reason: "noAddress"), [
            "session": "s-1", "turn": "3", "to": "open", "reason": "noAddress",
        ])
        XCTAssertEqual(TailTrace.placeholderStateName(.resolving), "resolving")
        XCTAssertEqual(TailTrace.placeholderStateName(.failed(.timeout)), "failed:timeout")
    }

    // MARK: - 取页

    func testPageFieldsOmitUnsetNumbers() {
        let start = PageTrace.fields(direction: "older", from: 10, to: 0, pages: 3)
        XCTAssertEqual(start, ["dir": "older", "from": "10", "pages": "3"])
        let done = PageTrace.fields(direction: "older", from: 10, to: 4, pages: 3,
                                    records: 6, elapsedMs: 220)
        XCTAssertEqual(done["to"], "4")
        XCTAssertEqual(done["records"], "6")
        XCTAssertEqual(done["ms"], "220")
    }
}

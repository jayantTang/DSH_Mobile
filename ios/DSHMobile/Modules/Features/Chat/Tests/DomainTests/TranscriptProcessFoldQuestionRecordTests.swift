@testable import DSHChatDomain
import DSHKit
import XCTest

/// SR-02.16：作答记录不参与过程折叠。
///
/// 折叠只能收过程行（工具、思考、分组）；读者自己的选择必须一直可见，
/// 否则收起一轮之后就看不到"我刚才选了什么"。
final class TranscriptProcessFoldQuestionRecordTests: XCTestCase {

    private let arguments = #"{"questions":[{"id":"q1","question":"用哪套配色？","header":"配色"},{"id":"q2","question":"要附截图吗？"}]}"#
    private let answers = #"{"answers":[{"id":"q1","selected":["深色"]},{"id":"q2","selected":[],"custom":"不用了"}]}"#

    private func plan(_ timeline: ChatTimeline, running: Bool = false) -> TranscriptProcessFold.Plan {
        let boundary: TranscriptTail.Boundary = running
            ? .open(turn: 1, startedAt: nil) : .closed(turn: 1, reason: "completed")
        return TranscriptProcessFold.plan(
            items: timeline.items,
            tail: TranscriptTail(boundary: boundary, showsTail: true),
            currentTurn: 1,
            summaries: timeline.foldSummaries)
    }

    private func record(in rows: [TimelineItem]) -> (headers: [String], questions: [String], answers: [String])? {
        for row in rows {
            if case .questionRecord(let headers, let questions, let answers) = row.kind {
                return (headers, questions, answers)
            }
        }
        return nil
    }

    private func liveTimeline() throws -> ChatTimeline {
        try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "帮我选一下"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "ask-1", name: "ask_user_question",
                                         arguments: arguments),
            ProcessFoldFixtures.toolResult(seq: 4, callId: "ask-1", text: answers),
            ProcessFoldFixtures.assistant(seq: 5, text: "好，用深色。"),
            ProcessFoldFixtures.turnEnd(seq: 6),
        ])
    }

    func test_collapsed_turn_keeps_the_answer_record_visible() throws {
        let timeline = try liveTimeline()
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.canCollapse)

        let record = try XCTUnwrap(self.record(in: timeline.items))
        XCTAssertEqual(record.questions, ["用哪套配色？", "要附截图吗？"])
        XCTAssertEqual(record.answers, ["深色", "不用了"])

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let shown = try XCTUnwrap(self.record(in: rows))
        XCTAssertEqual(shown.answers, record.answers, "收起轮次后作答记录仍原样可见")
        XCTAssertEqual(shown.questions, record.questions)
        XCTAssertEqual(rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let header) = item.kind { return header }
            return nil
        }.count, 1)

        // 记录是内容行，不是过程：不计数、不参与分组、不在 processRowIDs 里。
        XCTAssertEqual(turn.toolCount, 1, "工具计数只算 ask_user_question 这一步")
        let recordItem = try XCTUnwrap(timeline.items.first {
            if case .questionRecord = $0.kind { return true }
            return false
        })
        XCTAssertFalse(plan.processRowIDs.contains(recordItem.id))
        XCTAssertFalse(turn.groups.contains { group in
            group.indexes.contains { plan.rows[$0].id == recordItem.id }
        })
    }

    func test_expanded_turn_still_shows_the_record_once() throws {
        let timeline = try liveTimeline()
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        for group in turn.groups { state.expandedGroups.insert(group.key) }

        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        let records = rows.filter { if case .questionRecord = $0.kind { return true }; return false }
        XCTAssertEqual(records.count, 1, "展开只是把过程放出来，不复制记录")
    }

    func test_running_turn_shows_the_record_before_the_run_ends() throws {
        // 还在跑：去掉结束分隔行，边界仍开着。
        let running = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "帮我选一下"),
            ProcessFoldFixtures.toolCall(seq: 3, callId: "ask-1", name: "ask_user_question",
                                         arguments: arguments),
            ProcessFoldFixtures.toolResult(seq: 4, callId: "ask-1", text: answers),
            ProcessFoldFixtures.toolCall(seq: 5, callId: "c2", name: "bash"),
        ])
        let rows = TranscriptProcessFold.displayRows(plan(running, running: true),
                                                     state: TranscriptFoldState())
        XCTAssertNotNil(record(in: rows), "答案一回来就应看到记录，不必等到轮次结束")
    }

    func test_summary_page_projects_the_record_without_raw_tool_rows() throws {
        let window = """
        {"records":[
          {"event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"event":{"type":"user/message","seq":2,"time":1001,"data":{
            "source":{"kind":"user","rpcId":"r-1"},
            "content":[{"type":"text","text":"帮我选一下"}]}}},
          {"event":{"type":"+link/fold","seq":3,"time":1002,"data":{
            "v":2,"turn":1,"startSeq":3,"endSeq":4,"durationMs":1000,"endReason":"completed",
            "activities":{"questions":1},
            "groups":[{"startSeq":3,"endSeq":4,"activities":{"questions":1},"toolCount":1,
              "steps":[{"seq":3,"kind":"tools","name":"ask_user_question","preview":"配色","status":"ok","resultSeq":4,"bytes":120}]}]}}},
          {"event":{"type":"+link/question","seq":4,"time":1003,"data":{
            "callId":"ask-1",
            "questions":[{"id":"q1","question":"用哪套配色？"},{"id":"q2","question":"要附截图吗？"}],
            "answers":[{"id":"q1","selected":["深色"]},{"id":"q2","selected":[],"custom":"不用了"}]}}},
          {"event":{"type":"assistant/message","seq":5,"time":1005,"data":{
            "turn":1,"step":2,
            "message":{"role":"assistant","content":[{"type":"text","text":"好，用深色。"}]}}}},
          {"event":{"type":"turn/end","seq":6,"time":1006,"data":{"turn":1,"reason":{"kind":"completed"}}}}
        ],"startSeq":1,"endSeq":6,"hasMore":false}
        """
        let timeline = try FoldSummaryV2Fixtures.timeline(window)
        XCTAssertEqual(timeline.foldSummaries.count, 1)
        XCTAssertFalse(timeline.items.contains { if case .toolCall = $0.kind { return true }; return false },
                       "概要页不下发工具行")

        let plan = FoldSummaryV2Fixtures.plan(timeline)
        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let shown = try XCTUnwrap(record(in: rows))
        XCTAssertEqual(shown.questions, ["用哪套配色？", "要附截图吗？"])
        XCTAssertEqual(shown.answers, ["深色", "不用了"])
    }

    func test_copy_text_marks_skipped_and_keeps_question_answer_pairs() throws {
        let timeline = try liveTimeline()
        let row = try XCTUnwrap(timeline.items.first {
            if case .questionRecord = $0.kind { return true }
            return false
        })
        let text = try XCTUnwrap(row.questionRecordCopyText)
        XCTAssertTrue(text.contains("配色 — 用哪套配色？\n深色"))
        XCTAssertTrue(text.contains("要附截图吗？\n不用了"), "自定义答案不能丢")

        let skippedTimeline = try ProcessFoldFixtures.timeline([
            ProcessFoldFixtures.turnStart(seq: 1, turn: 1),
            ProcessFoldFixtures.user(seq: 2, text: "帮我选一下"),
            ProcessFoldFixtures.toolCall(
                seq: 3, callId: "ask-2", name: "ask_user_question",
                arguments: #"{"questions":[{"id":"q2","question":"要附截图吗？"}]}"#),
            ProcessFoldFixtures.toolResult(
                seq: 4, callId: "ask-2",
                text: #"{"answers":[{"id":"q2","selected":[]}]}"#),
        ])
        let skippedRow = try XCTUnwrap(skippedTimeline.items.first {
            if case .questionRecord = $0.kind { return true }
            return false
        })
        XCTAssertEqual(skippedRow.questionRecordCopyText, "要附截图吗？\n已跳过")
    }
}

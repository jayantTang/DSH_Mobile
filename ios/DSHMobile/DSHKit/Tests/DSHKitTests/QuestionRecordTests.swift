import Foundation
import XCTest

@testable import DSHKit

/// SR-02.16：作答记录必须单独成一行的投影与落点。
///
/// 覆盖三条输入路径（实时工具结果、折叠页记录、计时提问的迟到回复），
/// 以及同一调用的重复到达不重复成行、问题文字按更完整的一份合并。
final class QuestionRecordTests: XCTestCase {

    private let args: [String: Any] = [
        "questions": [
            ["id": "q1", "question": "用哪套配色？", "header": "配色", "multi_select": false],
            ["id": "q2", "question": "要附截图吗？"],
        ],
    ]

    private let answers: [String: Any] = [
        "answers": [
            ["id": "q1", "selected": ["深色"]],
            ["id": "q2", "selected": [], "custom": "不用了"],
        ],
    ]

    private func event(_ object: [String: Any]) throws -> SessionEvent {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(SessionEvent.self, from: data)
    }

    private func toolCall(seq: Int, arguments: [String: Any]) throws -> SessionEvent {
        try event([
            "type": "tool/call", "seq": seq, "time": 1_700_000_000_000,
            "data": [
                "turn": 1, "step": 1, "callId": "ask-1",
                "name": "ask_user_question",
                "arguments": String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8) ?? "",
            ],
        ])
    }

    private func toolResult(seq: Int, payload: [String: Any]) throws -> SessionEvent {
        let text = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? ""
        return try event([
            "type": "tool/result", "seq": seq, "time": 1_700_000_000_100,
            "data": [
                "turn": 1, "step": 1,
                "message": [
                    "source": ["kind": "tool", "callId": "ask-1"],
                    "content": [[
                        "type": "tool-result", "toolCallId": "ask-1",
                        "content": [["type": "text", "text": text]],
                    ]],
                ],
            ],
        ])
    }

    private func summaryRecord(seq: Int, questions: [String: Any]?, answers: [String: Any]) throws -> SessionEvent {
        var data: [String: Any] = ["callId": "ask-1", "answers": answers["answers"] as Any]
        if let questions { data["questions"] = questions["questions"] }
        return try event([
            "type": QuestionRecordProjection.recordType, "seq": seq, "time": 1_700_000_000_100,
            "data": data,
        ])
    }

    // MARK: - Projection

    func test_decode_record_pairs_questions_and_answers_in_order() throws {
        let record = try XCTUnwrap(QuestionRecordProjection.decode(
            try summaryRecord(seq: 3, questions: args, answers: answers).data))
        XCTAssertEqual(record.questions, ["用哪套配色？", "要附截图吗？"])
        XCTAssertEqual(record.headers, ["配色", ""])
        XCTAssertEqual(record.answers, ["深色", "不用了"])
    }

    func test_decode_record_drops_malformed_shapes() throws {
        XCTAssertNil(QuestionRecordProjection.decode(.object([:])))
        let noCall = try event([
            "type": QuestionRecordProjection.recordType, "seq": 1,
            "data": ["questions": [], "answers": [["id": "q", "selected": []]]],
        ])
        XCTAssertNil(QuestionRecordProjection.decode(noCall.data))
        let badSelected = try event([
            "type": QuestionRecordProjection.recordType, "seq": 1,
            "data": ["callId": "c", "answers": [["id": "q", "selected": "x"]]],
        ])
        XCTAssertNil(QuestionRecordProjection.decode(badSelected.data))
    }

    func test_tool_result_record_ignores_pending_and_keeps_answers_without_questions() {
        let pending = QuestionRecordProjection.fromToolResult(
            callId: "ask-1",
            arguments: String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!,
            resultText: #"{"pending":true,"callId":"ask-1"}"#)
        XCTAssertNil(pending, "计时提问超时不是答案批次，不能画一条空记录")

        let record = QuestionRecordProjection.fromToolResult(
            callId: "ask-1",
            arguments: "",
            resultText: #"{"answers":[{"id":"q1","selected":["深色"]}]}"#)
        XCTAssertEqual(record?.questions, [""])
        XCTAssertEqual(record?.answers, ["深色"])
    }

    func test_late_reply_parses_only_the_question_reply_payload() {
        let text = #"{"kind":"answer_to_pending_question","callId":"ask-1","questions":[{"id":"q1","question":"用哪套配色？"}],"answers":[{"id":"q1","selected":["深色"]}]}"#
        let record = QuestionRecordProjection.fromLateReply(callId: "ask-1", text: text)
        XCTAssertEqual(record?.answers, ["深色"])
        XCTAssertNil(QuestionRecordProjection.fromLateReply(
            callId: "ask-1", text: #"{"kind":"something_else","answers":[]}"#))
        XCTAssertNil(QuestionRecordProjection.fromLateReply(callId: "", text: text))
    }

    func test_merge_keeps_the_richer_text_set() {
        let short = QuestionRecordProjection(
            callId: "ask-1", headers: [""], questions: ["用哪套"], answers: [""])
        let full = QuestionRecordProjection(
            callId: "ask-1", headers: ["配色"], questions: ["用哪套配色？"], answers: ["深色"])
        XCTAssertEqual(short.merging(full), full)
        XCTAssertEqual(full.merging(short), full, "更完整的一份不会被截断版本覆盖")
    }

    // MARK: - Timeline

    func test_live_tool_result_appends_one_question_record_row() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try toolCall(seq: 1, arguments: args))
        _ = timeline.apply(try toolResult(seq: 2, payload: answers))

        let records = timeline.items.filter { if case .questionRecord = $0.kind { return true }; return false }
        XCTAssertEqual(records.count, 1)
        guard case .questionRecord(let headers, let questions, let answers) = records[0].kind else {
            return XCTFail("not a record")
        }
        XCTAssertEqual(questions, ["用哪套配色？", "要附截图吗？"])
        XCTAssertEqual(headers, ["配色", ""])
        XCTAssertEqual(answers, ["深色", "不用了"])
        XCTAssertEqual(records[0].seq, 2, "记录落在结果事件的 seq 上")
    }

    func test_replaying_the_summary_record_does_not_duplicate_and_keeps_the_richer_questions() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try toolCall(seq: 1, arguments: args))
        _ = timeline.apply(try toolResult(seq: 2, payload: answers))
        // 折叠页里的记录可能把问题文字截短：同一 callId 只更新，不新增。
        _ = timeline.apply(try summaryRecord(seq: 2, questions: nil, answers: answers))

        let records = timeline.items.filter { if case .questionRecord = $0.kind { return true }; return false }
        XCTAssertEqual(records.count, 1)
        guard case .questionRecord(_, let questions, let answers) = records[0].kind else {
            return XCTFail("not a record")
        }
        XCTAssertEqual(questions.count, 2, "先到的完整问题文字不能被只有答案的记录抹掉")
        XCTAssertEqual(answers, ["深色", "不用了"])
    }

    func test_pending_tool_result_creates_no_record() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try toolCall(seq: 1, arguments: args))
        _ = timeline.apply(try toolResult(seq: 2, payload: ["pending": true, "callId": "ask-1"]))
        XCTAssertFalse(timeline.items.contains {
            if case .questionRecord = $0.kind { return true }
            return false
        })
    }

    func test_late_reply_becomes_a_question_record_not_raw_json() throws {
        let payload = #"{"kind":"answer_to_pending_question","callId":"ask-1","questions":[{"id":"q1","question":"用哪套配色？"}],"answers":[{"id":"q1","selected":["深色"]}]}"#
        let late = try event([
            "type": "user/message", "seq": 9, "time": 1_700_000_001_000,
            "data": [
                "content": [["type": "text", "text": payload]],
                "source": ["kind": "user-question-reply", "callId": "ask-1"],
                "role": "user", "id": "late-1",
            ],
        ])
        var timeline = ChatTimeline()
        _ = timeline.apply(late)

        XCTAssertEqual(timeline.items.count, 1)
        guard case .questionRecord(_, let questions, let answers) = timeline.items[0].kind else {
            return XCTFail("late reply must be a question record, not a user bubble")
        }
        XCTAssertEqual(questions, ["用哪套配色？"])
        XCTAssertEqual(answers, ["深色"])
        XCTAssertFalse(timeline.items.contains {
            if case .userMessage = $0.kind { return true }
            return false
        }, "原始 JSON 不能作为用户消息显示")
    }
}

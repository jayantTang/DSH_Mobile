import Foundation
import XCTest

@testable import DSHKit

/// M6b 的协议层：`fold` 三态、步骤正文解析、步骤行的正文状态。
final class SummaryFoldModeTests: XCTestCase {

    private func foldField(_ fold: HistoryWindowFold?) throws -> JSONValue? {
        let request = HistoryWindowRequest(address: .session(sessionId: "s"), before: 10,
                                           fold: fold)
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(JSONValue.self, from: data)["fold"]
    }

    func test_fold_encodes_three_modes_and_keeps_the_v1_shape() throws {
        XCTAssertEqual(try foldField(.summary)?.stringValue, "summary")
        XCTAssertEqual(try foldField(.v1)?.boolValue, true)
        XCTAssertEqual(try foldField(HistoryWindowFold.none)?.boolValue, false)
        XCTAssertNil(try foldField(nil), "不折时不带这个字段")
        // 现有调用的 Bool 字面量照旧编译，并落到同一份编码上。
        XCTAssertEqual(try foldField(true)?.boolValue, true)
        XCTAssertEqual(try foldField(false)?.boolValue, false)
    }

    func test_fold_decodes_bool_and_string_forms_and_rejects_unknown_modes() throws {
        func decode(_ raw: String) throws -> HistoryWindowFold {
            try JSONDecoder().decode(HistoryWindowFold.self, from: Data(raw.utf8))
        }
        XCTAssertEqual(try decode("true"), .v1)
        XCTAssertEqual(try decode("false"), HistoryWindowFold.none)
        XCTAssertEqual(try decode(#""summary""#), .summary)
        XCTAssertThrowsError(try decode(#""bogus""#))
    }

    func test_the_summary_capability_name_is_the_one_the_connector_advertises() {
        XCTAssertEqual(HistoryWindowWire.summaryFoldCapability, "history-fold-summary-v2")
        XCTAssertEqual(LinkHandshake.Capability.historyFoldSummaryV2,
                       HistoryWindowWire.summaryFoldCapability)
    }

    // MARK: - reset 不丢运行态 / 本地缓存键

    func test_reset_keeps_the_open_turn_when_the_window_has_no_turn_boundary() throws {
        var timeline = ChatTimeline()
        timeline.apply(try JSONDecoder().decode(
            SessionEvent.self,
            from: Data(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#.utf8)))
        XCTAssertTrue(timeline.isTurnOpen)
        // 裁到轮次中间：窗口里只有过程行，没有任何轮次边界——reset 不能凭"没看到
        // turn/start"就以为这一轮结束了（运行行与计时都靠这一位）。
        timeline.reset(with: [try record(
            #"{"type":"tool/call","seq":2,"data":{"turn":1,"step":1,"callId":"c1","name":"bash","arguments":"{}"}}"#)])
        XCTAssertTrue(timeline.isTurnOpen, "没有轮次边界时保留原来的运行态")

        // 有边界时以记录为准（这里是一轮结束）。
        timeline.reset(with: [try record(
            #"{"type":"turn/end","seq":3,"data":{"turn":1,"reason":{"kind":"completed"}}}"#)])
        XCTAssertFalse(timeline.isTurnOpen)
    }

    func test_the_step_body_cache_key_is_defined_in_one_place() {
        XCTAssertEqual(TranscriptLocalCacheKeys.stepBodies(sessionId: "abc"),
                       "step-body-cache:abc")
    }

    // MARK: - 步骤正文

    private func record(_ json: String) throws -> SessionRecord {
        SessionRecord(event: try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8)))
    }

    func test_a_tool_step_body_comes_from_its_result_record() throws {
        let record = try record("""
        {"type":"tool/result","seq":4,"data":{"message":{"source":{"callId":"c1"},
          "content":[{"type":"tool-result","toolCallId":"c1","isError":false,
            "content":[{"type":"text","text":"BUILD OK"}]}]}}}
        """)
        XCTAssertEqual(ProcessStepBodyReader.text(for: .tools, in: record, seq: 4), "BUILD OK")
        XCTAssertNil(ProcessStepBodyReader.text(for: .tools, in: record, seq: 5),
                     "seq 对不上就不是这一条的内容")
        XCTAssertNil(ProcessStepBodyReader.text(for: .reasoning, in: record, seq: 4),
                     "工具结果不是思考正文")
    }

    func test_a_reasoning_step_body_only_takes_the_thinking_blocks() throws {
        let record = try record("""
        {"type":"assistant/message","seq":5,"data":{"turn":1,"step":1,
          "message":{"role":"assistant","content":[
            {"type":"reasoning","text":"先看包"},
            {"type":"text","text":"这句是讲话"}]}}}
        """)
        XCTAssertEqual(ProcessStepBodyReader.text(for: .reasoning, in: record, seq: 5), "先看包")
        XCTAssertNil(ProcessStepBodyReader.text(for: .tools, in: record, seq: 5))
    }

    func test_an_empty_body_is_not_invented() throws {
        let record = try record("""
        {"type":"tool/result","seq":4,"data":{"message":{"source":{"callId":"c1"},
          "content":[{"type":"tool-result","toolCallId":"c1","isError":false,"content":[]}]}}}
        """)
        XCTAssertNil(ProcessStepBodyReader.text(for: .tools, in: record, seq: 4))
    }

    func test_a_too_large_body_is_a_terminal_state() {
        let step = TimelineProcessStep(
            id: "s-2", groupKey: "g", turn: 1, seq: 3, kind: .tools,
            name: "bash", preview: "cat huge.log", status: .ok, resultSeq: 4,
            bytes: TimelineProcessStep.detailMaxBytes + 1)
        XCTAssertEqual(step.with(body: .tooLarge).body, .tooLarge)
    }

    func test_adopting_a_summary_page_keeps_the_covered_range_and_the_end_evidence() async throws {
        let record = SessionRecord(event: try JSONDecoder().decode(
            SessionEvent.self,
            from: Data(#"{"type":"user/message","seq":3,"data":{"source":{"kind":"user"},"content":[]}}"#.utf8)))
        func makePipeline() -> SessionPipeline {
            SessionPipeline(scope: "s", sessionId: "x", store: nil,
                            fetch: { _, _ in
                                SessionPipeline.FetchPage(records: [], hasMore: true)
                            })
        }
        // 覆盖范围用连接器给的整段（不是首尾记录）：中间被折掉的 seq 也算已读。
        // hasMore=false + 覆盖到 seq 1 → 「到最早」；clamped 同理（日志被裁剪）。
        let exhausted = makePipeline()
        await exhausted.adoptSummaryPage(records: [record], covered: 1...10,
                                         hasMore: false, clamped: false,
                                         knownEmpty: [[5, 6]], revision: "10")
        let exhaustedNewest = await exhausted.ranges.newest
        let exhaustedTop = await exhausted.topExhausted
        XCTAssertEqual(exhaustedNewest, 10)
        XCTAssertTrue(exhaustedTop)

        let clamped = makePipeline()
        await clamped.adoptSummaryPage(records: [record], covered: 1...10,
                                       hasMore: true, clamped: true)
        let clampedTop = await clamped.topExhausted
        XCTAssertTrue(clampedTop, "被截断的日志允许「到最早」")

        let partial = makePipeline()
        await partial.adoptSummaryPage(records: [record], covered: 5...10,
                                       hasMore: true, clamped: false)
        let partialTop = await partial.topExhausted
        XCTAssertFalse(partialTop, "还有更早时不能当成到底")
    }

    func test_a_step_row_carries_its_body_state_without_losing_identity() {
        let step = TimelineProcessStep(
            id: "s-1", groupKey: "g", turn: 1, seq: 3, kind: .tools,
            name: "bash", preview: "swift build", status: .ok, resultSeq: 4, bytes: 900)
        XCTAssertNil(step.body)
        let loaded = step.with(body: .loaded(text: "BUILD OK", bytes: 8))
        XCTAssertEqual(loaded.id, step.id)
        XCTAssertEqual(loaded.resultSeq, 4)
        XCTAssertEqual(loaded.bytes, 900)
        XCTAssertEqual(loaded.body, .loaded(text: "BUILD OK", bytes: 8))
        XCTAssertEqual(loaded.body?.text, "BUILD OK")
    }
}

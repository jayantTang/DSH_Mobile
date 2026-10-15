import DSHChatDomain
import DSHKit
import XCTest

/// 025 T022 — what a transcript row hands to the reader, and how the fold that
/// produces those rows behaves.
///
/// The rows are built the way the app builds them: real journal events decoded
/// from JSON and folded by `ChatTimeline`. That keeps the cases on the public
/// surface (no memberwise-init shortcut into the kit's types) and means the
/// fixtures are the same shapes the host sends.
///
/// Deliberately **not** here: streaming and paging driven through `ChatModel`.
/// `ChatModel.attach(store:hub:)` wants a live `ConnectionStore`, and the store
/// takes no carrier of its own, so `FakeCarrier` cannot reach the chat model's
/// transport. Faking that seam would mean changing product code, so the
/// streaming fold is exercised directly (`ChatTimeline.apply(_: AssistantStreamFrame)`)
/// and the full path with a real relay stays with the simulator lanes.
@MainActor
final class TranscriptRowTests: XCTestCase {

    // MARK: - Fixtures

    private func record(_ object: [String: JSONValue]) throws -> SessionRecord {
        let data = try JSONEncoder().encode(JSONValue.object(object))
        return SessionRecord(event: try JSONDecoder().decode(SessionEvent.self, from: data))
    }

    private func fold(_ events: [[String: JSONValue]]) throws -> ChatTimeline {
        var timeline = ChatTimeline()
        for event in events {
            timeline.apply(try record(event).event)
        }
        return timeline
    }

    /// A `user/message` as the host journals it.
    private func userMessage(
        seq: Int,
        text: String,
        sourceKind: String = "user"
    ) -> [String: JSONValue] {
        [
            "type": .string("user/message"),
            "seq": .int(seq),
            "data": .object([
                "id": .string("message-\(seq)"),
                "source": .object(["kind": .string(sourceKind)]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string(text)]),
                ]),
            ]),
        ]
    }

    private func assistantMessage(seq: Int, blocks: [JSONValue]) -> [String: JSONValue] {
        [
            "type": .string("assistant/message"),
            "seq": .int(seq),
            "data": .object([
                "turn": .int(1),
                "step": .int(1),
                "message": .object(["content": .array(blocks)]),
            ]),
        ]
    }

    private func turnEnd(seq: Int) -> [String: JSONValue] {
        [
            "type": .string("turn/end"),
            "seq": .int(seq),
            "data": .object([
                "turn": .int(1),
                "reason": .object(["kind": .string("completed")]),
            ]),
        ]
    }

    private func toolCall(seq: Int, callId: String, name: String, arguments: String) -> [String: JSONValue] {
        [
            "type": .string("tool/call"),
            "seq": .int(seq),
            "data": .object([
                "turn": .int(1),
                "step": .int(1),
                "callId": .string(callId),
                "name": .string(name),
                "arguments": .string(arguments),
            ]),
        ]
    }

    private func toolResult(seq: Int, callId: String, text: String) -> [String: JSONValue] {
        [
            "type": .string("tool/result"),
            "seq": .int(seq),
            "data": .object([
                "turn": .int(1),
                "step": .int(1),
                "message": .object([
                    "source": .object(["callId": .string(callId)]),
                    "content": .array([
                        .object([
                            "type": .string("tool-result"),
                            "toolCallId": .string(callId),
                            "isError": .bool(false),
                            "content": .array([
                                .object(["type": .string("text"), "text": .string(text)]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]
    }

    // MARK: - What a row offers to copy

    func test_a_message_from_the_human_offers_its_text() throws {
        let timeline = try fold([userMessage(seq: 1, text: "hello there")])

        let item = try XCTUnwrap(timeline.items.first)
        guard case .userMessage(let text, _, _, _, let isAgentSent) = item.kind else {
            return XCTFail("expected a user message row, got \(item.kind)")
        }
        XCTAssertEqual(text, "hello there")
        XCTAssertFalse(isAgentSent)

        let payload = try XCTUnwrap(item.selectableMessage)
        XCTAssertEqual(payload.text, "hello there")
        XCTAssertFalse(payload.isMonospaced)
        XCTAssertFalse(payload.title.isEmpty)
    }

    func test_only_what_the_human_typed_becomes_a_row() throws {
        // The host journals plugin and runtime-context messages under the same
        // event type; showing them as bubbles is how one prompt looked sent twice.
        let timeline = try fold([
            userMessage(seq: 1, text: "background note", sourceKind: "plugin"),
            userMessage(seq: 2, text: "queued item", sourceKind: "runtime"),
        ])

        XCTAssertTrue(timeline.items.isEmpty)
    }

    func test_prose_is_copyable_and_thinking_is_not() throws {
        let timeline = try fold([
            assistantMessage(seq: 2, blocks: [
                .object(["type": .string("text"), "text": .string("the answer")]),
                .object(["type": .string("reasoning"), "text": .string("the thinking")]),
            ]),
        ])

        XCTAssertEqual(timeline.items.count, 2)
        guard case .assistantText(let prose) = timeline.items[0].kind else {
            return XCTFail("expected prose first, got \(timeline.items[0].kind)")
        }
        XCTAssertEqual(prose, "the answer")
        XCTAssertEqual(timeline.items[0].selectableMessage?.text, "the answer")
        XCTAssertEqual(timeline.items[0].selectableMessage?.isMonospaced, false)

        guard case .reasoning = timeline.items[1].kind else {
            return XCTFail("expected reasoning second, got \(timeline.items[1].kind)")
        }
        XCTAssertNil(timeline.items[1].selectableMessage)
    }

    func test_a_tool_call_copies_its_name_arguments_and_output() throws {
        let timeline = try fold([
            toolCall(seq: 3, callId: "call-1", name: "bash", arguments: "{\"command\":\"ls\"}"),
            toolResult(seq: 4, callId: "call-1", text: "file.txt"),
        ])

        let item = try XCTUnwrap(timeline.items.first)
        guard case .toolCall(let invocation) = item.kind else {
            return XCTFail("expected a tool call row, got \(item.kind)")
        }
        XCTAssertEqual(invocation.name, "bash")
        XCTAssertEqual(invocation.resultText, "file.txt")

        let payload = try XCTUnwrap(item.selectableMessage)
        XCTAssertTrue(payload.isMonospaced, "a tool card is copied as monospaced text")
        XCTAssertTrue(payload.text.contains("bash"), "unexpected payload: \(payload.text)")
        XCTAssertTrue(payload.text.contains("\"command\":\"ls\""), "unexpected payload: \(payload.text)")
        XCTAssertTrue(payload.text.contains("file.txt"), "unexpected payload: \(payload.text)")
    }

    func test_a_turn_divider_offers_nothing_to_copy() throws {
        let timeline = try fold([turnEnd(seq: 5)])
        let item = try XCTUnwrap(timeline.items.first)

        guard case .turnDivider = item.kind else {
            return XCTFail("expected a turn divider, got \(item.kind)")
        }
        XCTAssertNil(item.selectableMessage)
    }

    // MARK: - Pending echoes and rows the fold would not produce

    func test_an_unconfirmed_echo_is_the_only_pending_row() throws {
        var timeline = ChatTimeline()
        timeline.echoUserPrompt(requestId: "request-1", text: "sending now")
        timeline.apply(try record(userMessage(seq: 1, text: "settled earlier")).event)

        let pending = ChatModel.pendingEchoes(in: timeline.items)

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.seq, Int.max - 1)
        XCTAssertFalse(ChatModel.isGapRow(pending[0]))
    }

    func test_a_folded_row_is_not_a_gap_row() throws {
        let timeline = try fold([userMessage(seq: 1, text: "hello")])
        let item = try XCTUnwrap(timeline.items.first)

        XCTAssertFalse(ChatModel.isGapRow(item))
        XCTAssertTrue(item.kind.isContentRow)
        XCTAssertFalse(item.kind.covers(seq: 1))
    }

    func test_streaming_a_row_without_a_folded_transcript_is_reported_as_such() {
        // The single-row fast path may not be applicable yet; the caller has to
        // learn that so it can fall back to a full fold instead of dropping the
        // text.
        let model = ChatModel()

        XCTAssertFalse(model.applyStreamingRow(seq: 7, text: "partial", reasoning: "why"))
    }

    // MARK: - Constants the rest of the app keys off

    func test_the_search_range_key_is_scoped_to_its_session() {
        XCTAssertEqual(ChatModel.searchRangeKey("session-1"), "search.range.session-1")
        XCTAssertNotEqual(ChatModel.searchRangeKey("a"), ChatModel.searchRangeKey("b"))
    }

    func test_the_row_payload_budget_defaults_to_thirty_two_megabytes() {
        let saved = ChatProbe.shared.payloadBudgetKB
        defer { ChatProbe.shared.payloadBudgetKB = saved }

        ChatProbe.shared.payloadBudgetKB = nil
        XCTAssertEqual(ChatModel.payloadBudgetBytes, 32 * 1024 * 1024)

        // The probe narrows it so the discard path is reachable on a real
        // session instead of only in theory.
        ChatProbe.shared.payloadBudgetKB = 64
        XCTAssertEqual(ChatModel.payloadBudgetBytes, 64 * 1024)
    }

    // MARK: - Streaming, folded

    func test_streaming_chunks_accumulate_in_one_provisional_row() {
        var timeline = ChatTimeline()
        timeline.apply(.start(attemptId: "attempt-1", revision: 1, turn: 1, step: 1, startedAfterSeq: 0))
        timeline.apply(.chunk(
            attemptId: "attempt-1", revision: 1, index: 0, time: nil, chunk: .textDelta("Hel")
        ))
        timeline.apply(.chunk(
            attemptId: "attempt-1", revision: 1, index: 1, time: nil, chunk: .textDelta("lo")
        ))

        XCTAssertEqual(timeline.streaming?.text, "Hello")
        XCTAssertTrue(timeline.isTurnOpen)

        timeline.apply(.end(attemptId: "attempt-1", revision: 1, index: 0, committedSeq: nil))
        XCTAssertNil(timeline.streaming)
    }

    func test_a_chunk_without_a_running_attempt_is_ignored() {
        var timeline = ChatTimeline()

        timeline.apply(.chunk(
            attemptId: "attempt-1", revision: 1, index: 0, time: nil, chunk: .textDelta("orphan")
        ))

        XCTAssertNil(timeline.streaming)
    }
}

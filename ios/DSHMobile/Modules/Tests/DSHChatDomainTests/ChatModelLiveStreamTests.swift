import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 026 P3 — the inbound half of the same seam: frames the fake carrier yields on
/// `session/follow` are decoded by `DSHClient` and folded by `ChatModel`, so a case
/// can start from wire bytes instead of from a `ChatTimeline` constructor.
///
/// What is **not** here: anything that depends on real host timing — a socket that
/// drops mid-turn, a reconnect that resumes the stream, a prompt the host answers
/// seconds later. The fake stream delivers its frames and ends, which is enough for
/// the fold but not for those. They stay with the simulator lanes.
///
/// Outbound RPCs are in `ChatModelTransportTests`.
@MainActor
final class ChatModelLiveStreamTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!

    override func setUp() {
        super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        model = ChatModel()
    }

    override func tearDown() async throws {
        await model.close()
        hub.stop()
        model = nil
        hub = nil
        carrier = nil
        try await super.tearDown()
    }

    /// Opens the fixture session with `frames` waiting on the follow stream.
    private func openFollowing(_ frames: [JSONValue]) async throws {
        carrier.streamResponses["session/follow"] = frames
        let profile = TestFixtures.relayProfile()
        let fake = FakeLinkService(
            profiles: [profile],
            state: .connected(hostHome: "/Users/tester")
        )
        fake.activeProfile = profile
        fake.clientOverride = DSHClient(carrier: carrier)
        model.attach(store: fake, hub: hub)
        await model.open(try ChatSeam.summary())
    }

    /// Runs the main actor until `condition` holds, or returns false on timeout.
    private func eventually(
        deadline: TimeInterval = 2,
        _ condition: () -> Bool
    ) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func test_the_opening_snapshot_becomes_transcript_rows() async throws {
        try await openFollowing([
            ChatSeam.snapshot(cursor: 2, records: [
                ChatSeam.userMessage(seq: 1, text: "what is up"),
                ChatSeam.assistantMessage(seq: 2, text: "not much"),
            ]),
        ])

        let folded = await eventually { self.model.timeline.items.count == 2 }
        guard folded else {
            return XCTFail("snapshot did not reach the transcript: \(model.timeline.items.count) rows")
        }
        guard case .userMessage(let prompt, _, _, _, _) = model.timeline.items[0].kind else {
            return XCTFail("expected the prompt first, got \(model.timeline.items[0].kind)")
        }
        XCTAssertEqual(prompt, "what is up")
        guard case .assistantText(let prose) = model.timeline.items[1].kind else {
            return XCTFail("expected the answer second, got \(model.timeline.items[1].kind)")
        }
        XCTAssertEqual(prose, "not much")
        XCTAssertEqual(model.phase, .ready, "a snapshot is enough to leave loading")
        XCTAssertFalse(model.hasOlder, "the snapshot said hasMore=false, so nothing older to page")
    }

    func test_assistant_stream_frames_arrive_as_one_growing_row() async throws {
        try await openFollowing([
            ChatSeam.snapshot(cursor: 0),
            ChatSeam.assistantStart(),
            ChatSeam.assistantTextDelta("Hel", index: 0),
            ChatSeam.assistantTextDelta("lo", index: 1),
        ])

        // Frames are coalesced (120ms) rather than folded one by one, so the
        // assertion is on the settled text, not on an intermediate state.
        let grew = await eventually { self.model.timeline.streaming?.text == "Hello" }
        XCTAssertTrue(grew, "the deltas did not accumulate into one bubble: got \(model.timeline.streaming?.text ?? "<no attempt>")")
        XCTAssertEqual(model.activity, .running, "a live attempt means the turn is open")
        XCTAssertEqual(model.timeline.streaming?.attemptId, "attempt-1")
    }

    func test_a_finished_turn_clears_the_run_state_and_signals_completion() async throws {
        try await openFollowing([
            ChatSeam.snapshot(cursor: 1),
            ChatSeam.eventFrame(ChatSeam.turnEnd(seq: 2, turn: 1)),
        ])

        let done = await eventually { self.model.completionSignal == 1 }
        XCTAssertTrue(done, "turn/end did not reach the run state")
        XCTAssertEqual(model.completion?.turn, 1)
        XCTAssertEqual(model.completion?.reason, "completed")
        XCTAssertEqual(model.activity, .idle)
        XCTAssertFalse(model.isBusy, "the stop control must go away when the turn ends")
    }

    func test_a_frame_this_build_cannot_decode_does_not_freeze_the_stream() async throws {
        // A newer host type: the kit turns it into `.unknown`, and the frames
        // after it must still arrive (a decode error that ends the stream would
        // freeze the transcript for the rest of the session).
        try await openFollowing([
            ChatSeam.snapshot(cursor: 1),
            .object(["type": .string("something-from-a-newer-host"), "payload": .string("?")]),
            ChatSeam.eventFrame(ChatSeam.turnEnd(seq: 2, turn: 1)),
        ])

        let done = await eventually { self.model.completionSignal == 1 }
        XCTAssertTrue(done, "an undecodable frame ended the stream")
    }
}

/// Wire-shape fixtures for the chat seam.
///
/// Built as JSON rather than through memberwise initialisers: the kit's models are
/// decoded from the host's payloads in production, and going through the decoder is
/// what keeps a fixture honest when the shape drifts.
enum ChatSeam {

    static func summary(id: String = "s-1", asOfSeq: Int = 12, running: Bool = false) throws -> SessionSummary {
        let json = """
        {"sessionId":"\(id)","updatedAt":1700000000000,"running":\(running),"blank":false,
         "projections":{"asOfSeq":\(asOfSeq),"values":{"title":"Transport seam"}}}
        """
        return try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
    }

    /// A `session/follow` opening frame.
    static func snapshot(cursor: Int, records: [JSONValue] = [], hasMore: Bool = false) -> JSONValue {
        .object([
            "type": .string("snapshot"),
            "cursor": .int(cursor),
            "records": .array(records.map { .object(["event": $0]) }),
            "hasMore": .bool(hasMore),
        ])
    }

    static func eventFrame(_ event: JSONValue) -> JSONValue {
        .object(["type": .string("event"), "event": event])
    }

    static func userMessage(seq: Int, text: String, sourceKind: String = "user") -> JSONValue {
        .object([
            "type": .string("user/message"),
            "seq": .int(seq),
            "data": .object([
                "id": .string("message-\(seq)"),
                "source": .object(["kind": .string(sourceKind)]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string(text)]),
                ]),
            ]),
        ])
    }

    static func assistantMessage(seq: Int, text: String, turn: Int = 1, step: Int = 1) -> JSONValue {
        .object([
            "type": .string("assistant/message"),
            "seq": .int(seq),
            "data": .object([
                "turn": .int(turn),
                "step": .int(step),
                "message": .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(text)]),
                    ]),
                ]),
            ]),
        ])
    }

    static func turnStart(seq: Int, turn: Int) -> JSONValue {
        .object([
            "type": .string("turn/start"),
            "seq": .int(seq),
            "data": .object(["turn": .int(turn)]),
        ])
    }

    static func turnEnd(seq: Int, turn: Int, reason: String = "completed") -> JSONValue {
        .object([
            "type": .string("turn/end"),
            "seq": .int(seq),
            "data": .object([
                "turn": .int(turn),
                "reason": .object(["kind": .string(reason)]),
            ]),
        ])
    }

    static func assistantStart(attemptId: String = "attempt-1", turn: Int = 1, step: Int = 1) -> JSONValue {
        .object([
            "type": .string("assistant-stream"),
            "frame": .object([
                "type": .string("start"),
                "attemptId": .string(attemptId),
                "revision": .int(0),
                "turn": .int(turn),
                "step": .int(step),
            ]),
        ])
    }

    static func assistantTextDelta(_ text: String, index: Int, attemptId: String = "attempt-1") -> JSONValue {
        .object([
            "type": .string("assistant-stream"),
            "frame": .object([
                "type": .string("chunk"),
                "attemptId": .string(attemptId),
                "revision": .int(0),
                "index": .int(index),
                "chunk": .object(["type": .string("text-delta"), "text": .string(text)]),
            ]),
        ])
    }
}

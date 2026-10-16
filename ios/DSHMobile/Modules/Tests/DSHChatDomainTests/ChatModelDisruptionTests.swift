import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 026 P3 — the chat unit where the link misbehaves.
///
/// `ChatModelTransportTests` pins the outbound envelope and
/// `ChatModelLiveStreamTests` the inbound fold; both run on a stream that
/// delivers its frames and ends. The shapes in between are here: a stream that
/// dies mid-answer, one that never ends (with a turn open, and with a prompt the
/// host never starts a turn for), a switch to another session while a stream is
/// live, a reconnect onto the same session, two prompts in flight at once, and a
/// prompt after a stop.
///
/// Fixture shape: `FakeCarrier` drives the real path — `FakeLinkService` ->
/// `DSHClient` -> `LinkGateway` -> `ChatModel` — so nothing here bypasses the
/// seam the app uses (wire fixtures are `ChatSeam`, in
/// `ChatModelLiveStreamTests.swift`). `streamScripts` replays a fixed script of
/// value / failure / hang events; `registerLiveStream` +
/// `waitForLiveStream` hand the test the continuation so a frame can be pushed
/// at a chosen moment.
///
/// Two cases are deliberately not here:
///
/// - The 20 s `isAwaitingTurnStart` timeout inside `send()`. Sleeping it out
///   would add 20 s to the suite for one assertion; the state that timeout
///   bounds is asserted to be released by `cancel()` instead.
/// - A reconnect that re-reads an on-disk tail. These fixtures attach no
///   `MessageLayer`, so `open` always plans a re-base and the replay snapshot
///   re-folds wholesale rather than merging. The case still pins that replayed
///   records land once each, and the id-dedupe path itself is exercised by the
///   re-delivered event frame.
@MainActor
final class ChatModelDisruptionTests: XCTestCase {

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

    // MARK: - 1. The link breaks mid-answer

    func test_a_stream_that_breaks_mid_answer_keeps_the_text_it_already_had() async throws {
        carrier.streamScripts["session/follow"] = [
            .value(ChatSeam.snapshot(cursor: 0)),
            .value(ChatSeam.assistantStart()),
            .value(ChatSeam.assistantTextDelta("Hel", index: 0)),
            .value(ChatSeam.assistantTextDelta("lo", index: 1)),
            .failure(DSHRPCFailure(code: "link/dropped", message: "the socket went away")),
            // The carrier keeps yielding past the failure the way a socket hands
            // over one last frame on the way down; it must not reach the fold.
            .value(ChatSeam.assistantTextDelta("!", index: 2)),
        ]
        try await openFixtureSession()

        let settled = await eventually { self.model.timeline.streaming?.text == "Hello" }
        XCTAssertTrue(settled, "the deltas never settled: got \(model.timeline.streaming?.text ?? "<none>")")
        let traced = await eventually { self.model.lastError != nil }
        XCTAssertTrue(traced, "a stream that ended in an error left no trace on the model")
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(model.timeline.streaming?.text, "Hello",
                       "the answer received so far must stay on screen")
        XCTAssertFalse(model.timeline.streaming?.text.contains("!") ?? false,
                       "a frame yielded after the failure reached the fold")
        XCTAssertEqual(model.phase, .ready,
                       "the snapshot had arrived, so the transcript must stay visible instead of spinning")
        XCTAssertEqual(model.activity, .running,
                       "the host never closed the turn, so the stop control must still be offered")
    }

    // MARK: - 2. The stream hangs

    func test_a_hung_stream_leaves_the_run_state_honest_and_a_way_out_on_the_wire() async throws {
        carrier.streamScripts["session/follow"] = [
            .value(ChatSeam.snapshot(cursor: 1)),
            .value(ChatSeam.assistantStart()),
            .value(ChatSeam.assistantTextDelta("working", index: 0)),
            .hang,
        ]
        try await openFixtureSession()

        let visible = await eventually { self.model.timeline.streaming?.text == "working" }
        XCTAssertTrue(visible, "the frame before the hang never arrived")
        carrier.unaryResponses["session/cancel"] = .success(.object([:]))
        try? await Task.sleep(for: .milliseconds(300))

        // Nothing may invent an end for a stream that never ended: the state has
        // to keep reporting what the host last said.
        XCTAssertEqual(model.activity, .running, "a hung stream fabricated an idle run state")
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.completion, "a turn that never ended was reported as completed")
        XCTAssertEqual(model.completionSignal, 0)
        XCTAssertEqual(model.phase, .ready)

        // The way out of the wedge is the stop control, which goes to the host.
        await model.cancel()
        let call = try XCTUnwrap(carrier.calls(to: "session/cancel").first)
        XCTAssertEqual(call.args?["request"]?["sessionId"]?.stringValue, "s-1")
    }

    // MARK: - 3. Switching sessions while a stream is live

    func test_a_frame_from_the_session_you_left_never_lands_in_the_one_you_opened() async throws {
        carrier.registerLiveStream("session/follow")
        attachFakeLink(carrier: carrier)
        await model.open(try ChatSeam.summary(id: "s-a", asOfSeq: 1))
        await carrier.waitForLiveStream("session/follow")
        let streamA = try XCTUnwrap(carrier.liveStreams["session/follow"])
        streamA.yield(ChatSeam.snapshot(cursor: 1, records: [
            ChatSeam.userMessage(seq: 1, text: "in A"),
        ]))
        let openedA = await eventually { self.texts() == ["in A"] }
        XCTAssertTrue(openedA, "session A never rendered: \(texts())")
        // Baseline: this same continuation folds a pushed event frame while A is
        // the session on screen. The negative below is measured against it, so
        // it cannot be explained away by a fixture that delivers nothing.
        streamA.yield(ChatSeam.eventFrame(ChatSeam.userMessage(seq: 6, text: "in A, live")))
        let fedA = await eventually { self.texts() == ["in A", "in A, live"] }
        XCTAssertTrue(fedA, "a frame pushed on A's live stream never landed in A: \(texts())")

        await model.open(try ChatSeam.summary(id: "s-b", asOfSeq: 3))
        let resubscribed = await eventually { self.carrier.calls(to: "session/follow").count == 2 }
        XCTAssertTrue(resubscribed, "opening B did not subscribe to B")
        let streamB = try XCTUnwrap(carrier.liveStreams["session/follow"])
        streamB.yield(ChatSeam.snapshot(cursor: 3, records: [
            ChatSeam.userMessage(seq: 2, text: "in B"),
        ]))
        let openedB = await eventually { self.texts() == ["in B"] }
        XCTAssertTrue(openedB, "session B never rendered: \(texts())")
        XCTAssertEqual(model.session?.sessionId, "s-b")

        // A's own continuation, pushed after the switch.
        streamA.yield(ChatSeam.eventFrame(ChatSeam.userMessage(seq: 9, text: "late from A")))
        streamA.yield(ChatSeam.eventFrame(ChatSeam.turnEnd(seq: 10, turn: 1)))
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(texts().contains("late from A"),
                       "a frame from the session we left was folded into the new one")
        XCTAssertEqual(model.completionSignal, 0,
                       "a turn belonging to the session we left ended the new one")
        XCTAssertEqual(model.timeline.items.map(\.id), ["user-message-2"],
                       "the new session's transcript changed shape")

        // Control: a push on B's own continuation does reach the model, so the
        // negative above is about A's frames and not about a fixture that
        // delivers nothing.
        streamB.yield(ChatSeam.eventFrame(ChatSeam.userMessage(seq: 5, text: "late in B")))
        let arrived = await eventually { self.texts() == ["in B", "late in B"] }
        XCTAssertTrue(arrived, "the live stream on B delivered nothing, so this case proves nothing")
    }

    // MARK: - 4. Reconnect to the same session

    func test_reopening_the_same_session_folds_its_replayed_records_once() async throws {
        carrier.registerLiveStream("session/follow")
        attachFakeLink(carrier: carrier)
        let summary = try ChatSeam.summary(id: "s-1", asOfSeq: 2)
        await model.open(summary)
        await carrier.waitForLiveStream("session/follow")
        let first = try XCTUnwrap(carrier.liveStreams["session/follow"])
        first.yield(ChatSeam.snapshot(cursor: 2, records: [
            ChatSeam.userMessage(seq: 1, text: "hello"),
            ChatSeam.assistantMessage(seq: 2, text: "part one"),
        ]))
        let opened = await eventually { self.model.timeline.items.count == 2 }
        XCTAssertTrue(opened, "the opening snapshot did not render: \(texts())")
        first.yield(ChatSeam.eventFrame(ChatSeam.assistantMessage(seq: 3, text: "part two")))
        let live = await eventually { self.model.timeline.items.count == 3 }
        XCTAssertTrue(live, "a committed event did not render: \(texts())")

        // The link goes away mid-session.
        first.finish(throwing: DSHRPCFailure(code: "link/dropped", message: "the socket went away"))
        let broke = await eventually { self.model.lastError != nil }
        XCTAssertTrue(broke, "the dropped stream left no trace on the model")

        // Re-open onto the same session: a fresh subscription, and the host
        // replays the tail this phone already folded.
        await model.open(summary)
        let resubscribed = await eventually { self.carrier.calls(to: "session/follow").count == 2 }
        XCTAssertTrue(resubscribed, "the re-opened session reused the dead subscription")
        let second = try XCTUnwrap(carrier.liveStreams["session/follow"])
        second.yield(ChatSeam.snapshot(cursor: 3, records: [
            ChatSeam.userMessage(seq: 1, text: "hello"),
            ChatSeam.assistantMessage(seq: 2, text: "part one"),
            ChatSeam.assistantMessage(seq: 3, text: "part two"),
        ]))
        // The frame that was in flight when the socket died, re-delivered.
        second.yield(ChatSeam.eventFrame(ChatSeam.assistantMessage(seq: 3, text: "part two")))
        second.yield(ChatSeam.eventFrame(ChatSeam.assistantMessage(seq: 4, text: "part three")))

        let resumed = await eventually { self.model.timeline.items.contains { $0.id == "assistant-4-0" } }
        XCTAssertTrue(resumed, "the new subscription did not fold live frames")
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(texts(), ["hello", "part one", "part two", "part three"],
                       "a replayed record landed more than once")
        XCTAssertEqual(model.timeline.items.map(\.id),
                       ["user-message-1", "assistant-2-0", "assistant-3-0", "assistant-4-0"],
                       "rows lost their durable identity across the reconnect")
    }

    // MARK: - 5. Two prompts in flight at once

    func test_two_prompts_in_flight_at_once_keep_their_own_ids_and_rows() async throws {
        let gated = GatedCarrier(FakeCarrier())
        let arrivals = PromptArrivals()
        let gate = TestGate()
        gated.hold = { method in
            guard method == "session/prompt" else { return }
            if await arrivals.note() == 1 { await gate.wait() }
        }
        carrier = gated.inner
        attachFakeLink(carrier: gated)
        gated.inner.streamResponses["session/follow"] = [ChatSeam.snapshot(cursor: 0)]
        await model.open(try ChatSeam.summary())
        let subscribed = await eventually { self.carrier.calls(to: "session/follow").count == 1 }
        XCTAssertTrue(subscribed, "the session never subscribed")
        gated.inner.unaryResponses["session/prompt"] = .success(.object([:]))

        model.draft = "first"
        let firstSend = Task { await self.model.send() }
        let parked = await eventuallyAsync { await arrivals.arrivalCount() == 1 }
        XCTAssertTrue(parked, "the first prompt never reached the carrier")

        // The first prompt is parked inside the carrier, so this one goes out
        // alone while the first is still in flight.
        model.draft = "second"
        await model.send()
        let inFlight = carrier.calls(to: "session/prompt")
        XCTAssertEqual(inFlight.count, 1, "expected only the second prompt on the wire so far")
        XCTAssertEqual(inFlight.first?.args?["request"]?["content"]?[0]?["text"]?.stringValue, "second")

        await gate.open()
        await firstSend.value

        let calls = carrier.calls(to: "session/prompt")
        XCTAssertEqual(calls.count, 2, "a second send while one was in flight did not reach the wire")
        var ids: Set<String> = []
        for call in calls {
            let request = try XCTUnwrap(call.args?["request"])
            let id = try XCTUnwrap(request["requestId"]?.stringValue)
            let text = try XCTUnwrap(request["content"]?[0]?["text"]?.stringValue)
            ids.insert(id)
            let row = model.timeline.items.first { $0.id == "user-\(id)" }
            guard let row, case .userMessage(let rowText, _, _, _, _) = row.kind else {
                return XCTFail("no optimistic row carries the request id \(id) the host was given")
            }
            XCTAssertEqual(rowText, text, "row \(id) carries the other prompt's text")
        }
        XCTAssertEqual(ids.count, 2, "two prompts were sent under one request id")
        XCTAssertEqual(Set(calls.compactMap { $0.args?["request"]?["content"]?[0]?["text"]?.stringValue }),
                       ["first", "second"])
        XCTAssertEqual(model.timeline.items.count, 2, "the two optimistic rows did not stay separate")
    }

    // MARK: - 6. A prompt after a stop

    func test_a_prompt_after_a_cancel_goes_out_with_its_own_row() async throws {
        carrier.registerLiveStream("session/follow")
        attachFakeLink(carrier: carrier)
        await model.open(try ChatSeam.summary())
        await carrier.waitForLiveStream("session/follow")
        let stream = try XCTUnwrap(carrier.liveStreams["session/follow"])
        stream.yield(ChatSeam.snapshot(cursor: 1))
        let ready = await eventually { self.model.phase == .ready }
        XCTAssertTrue(ready, "the snapshot never arrived")
        stream.yield(ChatSeam.eventFrame(ChatSeam.turnStart(seq: 1, turn: 1)))
        let running = await eventually { self.model.isRunning }
        XCTAssertTrue(running, "no open turn, so the cancel below would name no run")

        carrier.unaryResponses["session/cancel"] = .success(.object([:]))
        carrier.unaryResponses["session/prompt"] = .success(.object([:]))
        await model.cancel()
        let stopped = try XCTUnwrap(carrier.calls(to: "session/cancel").first)
        XCTAssertEqual(stopped.args?["request"]?["sessionId"]?.stringValue, "s-1")

        // The host confirms the stop on the session's own stream.
        stream.yield(ChatSeam.eventFrame(ChatSeam.turnEnd(seq: 2, turn: 1)))
        let settled = await eventually { self.model.activity == .idle }
        XCTAssertTrue(settled, "the run state stayed open after the host reported the turn ended")
        XCTAssertEqual(model.completionSignal, 1)

        model.draft = "after the stop"
        await model.send()

        let calls = carrier.calls(to: "session/prompt")
        XCTAssertEqual(calls.count, 1, "the prompt after a cancel never reached the wire")
        let request = try XCTUnwrap(calls.first?.args?["request"])
        XCTAssertEqual(request["content"]?[0]?["text"]?.stringValue, "after the stop")
        XCTAssertEqual(request["mode"]?.stringValue, "queue",
                       "a cancelled turn made the next prompt a steer")
        let id = try XCTUnwrap(request["requestId"]?.stringValue)
        XCTAssertTrue(model.timeline.items.contains { $0.id == "user-\(id)" },
                      "the prompt has no optimistic row")
        XCTAssertEqual(model.draft, "", "the composer kept the text it just sent")
        XCTAssertNil(model.lastError)
    }

    // MARK: - 7. A prompt whose turn never starts

    func test_a_prompt_whose_turn_never_starts_releases_the_sending_latch_on_cancel() async throws {
        carrier.streamScripts["session/follow"] = [
            .value(ChatSeam.snapshot(cursor: 1)),
            .hang,
        ]
        try await openFixtureSession()
        let ready = await eventually { self.model.phase == .ready }
        XCTAssertTrue(ready, "the snapshot never arrived")
        carrier.unaryResponses["session/prompt"] = .success(.object([:]))
        carrier.unaryResponses["session/cancel"] = .success(.object([:]))

        model.draft = "into a hung session"
        await model.send()

        // The host accepted the prompt but its turn never starts: the phone is
        // waiting, and says so rather than going idle behind the user's back.
        XCTAssertEqual(model.activity, .submitting)
        XCTAssertTrue(model.isBusy)
        let request = try XCTUnwrap(carrier.calls(to: "session/prompt").first?.args?["request"])
        let id = try XCTUnwrap(request["requestId"]?.stringValue)
        XCTAssertTrue(model.timeline.items.contains { $0.id == "user-\(id)" },
                      "the accepted prompt has no row")

        await model.cancel()
        XCTAssertEqual(model.activity, .idle, "cancel() left the sending latch on")
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(carrier.calls(to: "session/cancel").count, 1)
    }

    // MARK: - Fixtures

    /// Attaches a fake link whose `DSHClient` is `carrier` and opens the fixture
    /// session. The follow stream is whatever the carrier was programmed with.
    private func openFixtureSession(id: String = "s-1", asOfSeq: Int = 12) async throws {
        attachFakeLink(carrier: carrier)
        await model.open(try ChatSeam.summary(id: id, asOfSeq: asOfSeq))
    }

    /// An active profile is set on purpose: `ChatModel` derives its scope from it.
    private func attachFakeLink(carrier anyCarrier: any DSHCarrier) {
        let profile = TestFixtures.relayProfile()
        let fake = FakeLinkService(
            profiles: [profile],
            state: .connected(hostHome: "/Users/tester")
        )
        fake.activeProfile = profile
        fake.clientOverride = DSHClient(carrier: anyCarrier)
        model.attach(store: fake, hub: hub)
    }

    /// The prose rows in the transcript, in order.
    private func texts() -> [String] {
        model.timeline.items.compactMap { item -> String? in
            switch item.kind {
            case .userMessage(let text, _, _, _, _): return text
            case .assistantText(let text): return text
            default: return nil
            }
        }
    }

    /// Runs the main actor until `condition` holds, or returns false on timeout.
    private func eventually(deadline: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// The same, for a condition that lives on another actor (the carrier's own
    /// arrival counter, which the test cannot read synchronously).
    private func eventuallyAsync(
        deadline: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

/// Counts prompts as they enter the carrier, so a test can tell when the first
/// one is parked inside it.
private actor PromptArrivals {
    private var arrivals = 0

    /// Returns the arrival number of this prompt, starting at 1.
    func note() -> Int {
        arrivals += 1
        return arrivals
    }

    func arrivalCount() -> Int { arrivals }
}

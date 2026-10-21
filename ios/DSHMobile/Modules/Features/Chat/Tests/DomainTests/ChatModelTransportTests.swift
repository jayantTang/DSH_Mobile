@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 026 P3 — what `ChatModel` puts on the wire, over a fake carrier.
///
/// Until 026 the model's transport was unreachable from a unit test: `attach(store:hub:)`
/// wanted a live `ConnectionStore`, and the store built its own carrier, so `FakeCarrier`
/// could not see anything the model sent. `FakeLinkService.clientOverride` closes that
/// gap, and these cases assert the *envelope* — method name, session id, mode, content —
/// rather than only the fold that happens afterwards.
///
/// Inbound frames are in `ChatModelLiveStreamTests`.
///
/// Not covered here: anything that needs real host timing (reconnect, socket drop,
/// a turn that starts seconds after the prompt). Those stay with the simulator lanes.
@MainActor
final class ChatModelTransportTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!
    /// The profile the fake link is paired through; the model's scope comes from it.
    private var profile: ConnectionProfile!

    override func setUp() {
        super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        model = ChatModel()
    }

    override func tearDown() async throws {
        // Ends the hub's event stream (the model subscribes to it in `open`).
        await model.close()
        hub.stop()
        model = nil
        hub = nil
        carrier = nil
        profile = nil
        try await super.tearDown()
    }

    // MARK: - Wiring

    /// Attaches a fake link whose `DSHClient` is the fake carrier.
    ///
    /// An active profile is set on purpose: `ChatModel` derives its scope from it,
    /// and the scope is what the snapshot/disk branches key on. Leaving it nil
    /// would test a state the app never opens a session in.
    private func attachFakeLink() {
        let profile = TestFixtures.relayProfile()
        self.profile = profile
        let fake = FakeLinkService(
            profiles: [profile],
            state: .connected(hostHome: "/Users/tester")
        )
        fake.activeProfile = profile
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        model.attach(store: fake, hub: hub)
    }

    /// Opens the fixture session and waits until its follow stream is subscribed.
    ///
    /// The subscription happens on a task inside `open`, so the call is not
    /// synchronous with `open` returning.
    private func openFixtureSession(
        id: String = "s-1",
        asOfSeq: Int = 12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        attachFakeLink()
        await model.open(try ChatSeam.summary(id: id, asOfSeq: asOfSeq))
        let subscribed = await eventually {
            self.carrier.calls(to: "session/follow").count == 1
        }
        XCTAssertTrue(subscribed, "open() never subscribed to the session", file: file, line: line)
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

    // MARK: - open

    func test_open_subscribes_to_the_session_the_summary_names() async throws {
        try await openFixtureSession()

        let call = try XCTUnwrap(carrier.calls(to: "session/follow").first)
        let request = try XCTUnwrap(call.args?["request"])
        XCTAssertEqual(request["address"]?["kind"]?.stringValue, "session")
        XCTAssertEqual(request["address"]?["sessionId"]?.stringValue, "s-1")
        XCTAssertEqual(request["assistantStream"]?.boolValue, true,
                       "without this flag the host sends no token-level frames")
        // The window is the sync plan's business, but it must go out unchanged.
        XCTAssertEqual(
            request["maxMessages"]?.intValue,
            TranscriptSyncPlan.plan(localThrough: nil, hostCursor: 12).maxMessages
        )
    }

    func test_an_open_session_whose_stream_ends_stops_showing_loading() async throws {
        try await openFixtureSession()

        // The fake stream ends immediately: that is the host disposing the
        // session, and the screen must leave `loading` rather than spin.
        let settled = await eventually { self.model.phase == .ready }
        XCTAssertTrue(settled, "phase stayed \(self.model.phase) after the stream ended")
        XCTAssertEqual(model.session?.sessionId, "s-1")
        XCTAssertEqual(model.sessionScope, profile.id.uuidString,
                       "the scope must be the profile the session was opened on")
    }

    // MARK: - send

    func test_send_puts_the_prompt_on_the_wire_with_the_session_that_was_opened() async throws {
        try await openFixtureSession()
        carrier.unaryResponses["session/prompt"] = .success(.object([:]))

        model.draft = "ping from the phone"
        await model.send()

        let calls = carrier.calls(to: "session/prompt")
        XCTAssertEqual(calls.count, 1, "one composer submit is exactly one RPC")
        let request = try XCTUnwrap(calls.first?.args?["request"])
        XCTAssertEqual(request["sessionId"]?.stringValue, "s-1")
        XCTAssertEqual(request["mode"]?.stringValue, "queue",
                       "nothing is running, so the prompt queues")
        XCTAssertEqual(request["content"]?.arrayValue?.count, 1)
        XCTAssertEqual(request["content"]?[0]?["type"]?.stringValue, "text")
        XCTAssertEqual(request["content"]?[0]?["text"]?.stringValue, "ping from the phone")

        // The id the host receives is the identity of the optimistic row: that is
        // the only thing that lets the host's echo replace the row instead of
        // showing the message twice.
        let requestId = try XCTUnwrap(request["requestId"]?.stringValue)
        XCTAssertTrue(model.timeline.items.contains { $0.id == "user-\(requestId)" },
                      "no row carries the request id the host was given")

        XCTAssertEqual(model.draft, "", "the composer empties on send")
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.activity, .submitting, "accepted, but no turn has started")
    }

    func test_a_prompt_the_host_refuses_restores_the_text_and_clears_the_sending_state() async throws {
        try await openFixtureSession()
        carrier.unaryResponses["session/prompt"] = .failure(
            DSHRPCFailure(code: "link/timeout", message: "the connector did not answer")
        )

        model.draft = "keep me"
        await model.send()

        XCTAssertEqual(carrier.calls(to: "session/prompt").count, 1)
        XCTAssertEqual(model.draft, "keep me", "a failed send must not eat what was typed")
        XCTAssertEqual(model.activity, .idle, "the sending latch must not stick")
        let error = try XCTUnwrap(model.lastError)
        XCTAssertFalse(error.isEmpty)
    }

    func test_steering_a_running_turn_asks_the_host_to_steer() async throws {
        carrier.streamResponses["session/follow"] = [ChatSeam.eventFrame(ChatSeam.turnStart(seq: 1, turn: 1))]
        try await openFixtureSession()
        let running = await eventually { self.model.isRunning }
        XCTAssertTrue(running, "no open turn, so this case would not exercise steering")

        carrier.unaryResponses["session/prompt"] = .success(.object([:]))
        model.steerNext = true
        model.draft = "stop and do this instead"
        await model.send()

        let call = try XCTUnwrap(carrier.calls(to: "session/prompt").first)
        XCTAssertEqual(call.args?["request"]?["mode"]?.stringValue, "steer",
                       "steering a live turn must interrupt it, not queue behind it")
    }

    func test_send_without_an_open_session_never_reaches_the_wire() async {
        attachFakeLink()
        model.draft = "into the void"
        await model.send()
        XCTAssertTrue(carrier.calls(to: "session/prompt").isEmpty)
        XCTAssertEqual(model.draft, "into the void")
    }

    // MARK: - cancel

    func test_cancel_names_the_open_session() async throws {
        try await openFixtureSession()
        carrier.unaryResponses["session/cancel"] = .success(.object([:]))

        await model.cancel()

        let call = try XCTUnwrap(carrier.calls(to: "session/cancel").first)
        XCTAssertEqual(call.args?["request"]?["sessionId"]?.stringValue, "s-1")
        XCTAssertEqual(model.activity, .idle)
        XCTAssertFalse(model.isBusy)
    }
}

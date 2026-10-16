import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 025 T016 — `HostEventHub` subscribing to the host feed and fanning it out.
///
/// The feed is the app's only source of "a run ended" and "a question is
/// waiting", so the cases here drive the real `DSHClient` over the fake carrier
/// from `DSHTestingSupport`: the frames are decoded exactly as they are on a
/// live socket, the hub folds them into `pending`, and subscribers see the same
/// sequence. What is *not* covered is the reconnect loop's timing — that is
/// `EventStreamRetry`'s own contract, and the simulator lanes exercise the whole
/// path with a real relay.
@MainActor
final class HostEventHubTests: XCTestCase {

    private var hub: HostEventHub!

    override func setUp() {
        super.setUp()
        hub = HostEventHub()
    }

    override func tearDown() {
        hub?.stop()
        hub = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// One round of the feed: a handshake, two waiting prompts, one withdrawal.
    private static func feed() -> [JSONValue] {
        [
            .object([
                "type": .string("ready"),
                "clientId": .string("client-1"),
                "host": .object(["home": .string("/Users/tester")]),
            ]),
            .object([
                "type": .string("waterfall"),
                "event": .string("user-questions/request"),
                "eventId": .string("event-1"),
                "agentId": .string("session-1"),
                "request": .object(["question": .string("Continue?")]),
            ]),
            .object([
                "type": .string("waterfall"),
                "event": .string("approval/asked"),
                "eventId": .string("event-2"),
                "agentId": .string("session-2"),
                "request": .object(["tool": .string("bash")]),
            ]),
            .object([
                "type": .string("cancel"),
                "eventId": .string("event-1"),
            ]),
        ]
    }

    /// A gateway over a fake carrier that answers `$events` with the feed.
    private func makeGateway() -> LinkGateway {
        let carrier = FakeCarrier()
        carrier.streamResponses["$events"] = Self.feed()
        let client = DSHClient(carrier: carrier)
        return LinkGateway(clientProvider: { client })
    }

    /// Runs the main actor until `condition` holds, or fails the case.
    private func eventually(
        _ description: String,
        deadline: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)")
    }

    // MARK: - Before anything is attached

    func test_a_new_hub_has_no_feed_and_nothing_pending() {
        XCTAssertFalse(hub.isLive)
        XCTAssertNil(hub.hostHome)
        XCTAssertTrue(hub.pending.isEmpty)
        XCTAssertTrue(hub.pendingPrompts(for: "session-1").isEmpty)
    }

    func test_starting_without_a_link_leaves_the_hub_idle() async {
        hub.start(link: nil)

        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(hub.isLive)
        XCTAssertTrue(hub.pending.isEmpty)
    }

    func test_answering_without_a_link_fails_instead_of_disappearing() async {
        // A silently dropped answer leaves the host waiting forever; the caller
        // has to be able to say "this did not go out".
        let item = PendingPrompts.Item(
            id: "event-1",
            event: "user-questions/request",
            agentId: "session-1",
            request: .null,
            arrivedAt: Date()
        )

        do {
            try await hub.answer(item, with: .next)
            XCTFail("answering with no live link must not succeed")
        } catch let error as DSHTransportError {
            guard case .carrierClosed = error else {
                return XCTFail("unexpected transport error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - The feed

    func test_subscribers_receive_the_feed_in_order() async {
        // The subscriber registers *after* the feed starts: `start` tears down
        // every existing subscription first (product behaviour, unchanged here),
        // so a stream opened before it would be finished on the spot.
        hub.start(link: makeGateway())
        let stream = hub.events()
        var received: [HostEvent] = []
        let collector = Task { for await event in stream { received.append(event) } }
        defer { collector.cancel() }

        await eventually("four frames to reach the subscriber") { received.count >= 4 }

        let head = Array(received.prefix(4))
        guard case .ready(let clientId, _)? = head.first else {
            return XCTFail("expected a ready frame first, got \(head)")
        }
        XCTAssertEqual(clientId, "client-1")
        guard case .waterfall(let firstWaterfall)? = head.dropFirst().first else {
            return XCTFail("expected a waterfall second")
        }
        XCTAssertEqual(firstWaterfall.eventId, "event-1")
        XCTAssertEqual(firstWaterfall.event, "user-questions/request")
        XCTAssertEqual(firstWaterfall.agentId, "session-1")
        guard case .cancelled(let cancelledId)? = head.last else {
            return XCTFail("expected a cancellation last")
        }
        XCTAssertEqual(cancelledId, "event-1")
    }

    func test_the_handshake_publishes_the_host_home() async {
        hub.start(link: makeGateway())

        await eventually("the feed to be folded") { hub.pending.count == 1 }

        // The host home is set by the `ready` frame and survives until the hub
        // is stopped, so it is the stable way to see that the handshake landed.
        // `isLive` is deliberately not asserted here: the fake feed ends as soon
        // as it has been read, and the loop clears the flag when a stream ends
        // (a live socket simply never ends), so the flag is only true for a
        // window that no assertion can catch reliably.
        XCTAssertEqual(hub.hostHome, "/Users/tester")
    }

    func test_a_waiting_prompt_is_promoted_and_kept_by_session() async {
        hub.start(link: makeGateway())

        await eventually("the feed to be folded") { hub.pending.count == 1 }

        XCTAssertEqual(hub.pending.first?.id, "event-2", "the withdrawal must have removed event-1")
        XCTAssertEqual(hub.pending.first?.event, "approval/asked")
        XCTAssertEqual(hub.pendingPrompts(for: "session-2").map(\.id), ["event-2"])
        XCTAssertTrue(hub.pendingPrompts(for: "session-1").isEmpty)
        XCTAssertTrue(hub.pendingPrompts(for: "session-3").isEmpty)
    }

    func test_only_the_last_prompt_survives_a_replayed_feed() async {
        // The loop re-subscribes whenever the stream ends, and the relay
        // replays what is still waiting: the set must not grow a duplicate for
        // the same event id.
        hub.start(link: makeGateway())

        await eventually("the feed to be folded") { hub.pending.count == 1 }

        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(hub.pending.count, 1)
        XCTAssertEqual(hub.pending.first?.id, "event-2")
    }

    func test_stopping_finishes_every_subscription() async {
        let stream = hub.events()
        let finished = expectation(description: "the subscriber stream finished")
        let collector = Task {
            for await _ in stream {}
            finished.fulfill()
        }

        hub.stop()

        await fulfillment(of: [finished], timeout: 2)
        await collector.value
        XCTAssertFalse(hub.isLive)
        XCTAssertTrue(hub.pending.isEmpty)
    }
}

// MARK: - 032：作答跨设备互斥

extension HostEventHubTests {
    /// 别的设备答掉的提示要从本机待回应里去掉（宿主不一定撤回）。
    ///
    /// 夹具本身撤回过 event-1，所以这里剩的是 event-2（approval/asked）。
    func test_remote_answers_drop_matching_prompts() async {
        hub.start(link: makeGateway())
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(hub.pending.map(\.id), ["event-2"], "fixture leaves one prompt after the cancel")

        XCTAssertTrue(hub.applyRemoteAnswers(["event-2"]))

        XCTAssertTrue(hub.pending.isEmpty)
        XCTAssertFalse(hub.applyRemoteAnswers(["event-2"]), "already gone -> no change")
        XCTAssertFalse(hub.applyRemoteAnswers([]), "empty set is a no-op")
    }

    /// 本机答掉一条要通知账户级同步；重复应答不该再通知（本地认领在先）。
    func test_answering_fires_the_account_hook_once() async {
        hub.start(link: makeGateway())
        try? await Task.sleep(for: .milliseconds(120))
        var reported: [String] = []
        hub.onPromptAnswered = { reported.append($0) }

        let first = try? XCTUnwrap(hub.pending.first)
        if let first { try? await hub.answer(first, with: .result(.object(["ok": .bool(true)]))) }
        await settle()
        XCTAssertEqual(reported, ["event-2"])

        // 再答一次同一条：抛 promptAlreadyAnswered，且**不再**通知。
        if let first { _ = try? await hub.answer(first, with: .result(.object(["ok": .bool(true)]))) }
        await settle()
        XCTAssertEqual(reported, ["event-2"], "a second tap must not report again")
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }
}

// `@testable`: `SessionRouter` has no public initializer (the app only ever uses
// `.shared`), and the mirror it exposes is internal. Nothing here touches
// `SessionRouter.shared`.
@testable import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// Race and composition cases for the two DSHCore types that exist to behave
/// under several callers at once: `HostEventHub` (one feed, fanned out to every
/// screen) and `SessionRouter` (one request, several consumers).
///
/// `HostEventHubTests` covers the feed's happy path and `SessionRouterTests` the
/// take-once rule on a quiet system. What is pinned here is what happens when
/// two callers act at the same moment: a prompt answered twice, two screens
/// answering one prompt, a subscriber that stops reading, a reconnect, and two
/// consumers racing for one request.
///
/// Where the code does *not* do what one would expect, the case pins what it
/// actually does and says so, rather than asserting an aspiration:
///
/// * A repeated answer is **idempotent, not an error**: `HostEventHub.answer`
///   has no local dedupe, so the repeat still goes out on the wire. First
///   answer wins in the connector (`mobile-link`'s `WaterfallDedupe`), and
///   `LinkCarrier.eventResult` is fire-and-forget, so nothing comes back to the
///   loser. The hub's guarantee is only "the pending set loses the prompt once".
/// * A full subscriber buffer drops the **oldest** frames (`bufferingNewest`)
///   and never blocks the feed, which is what keeps one slow screen from
///   stalling the app's only event stream.
@MainActor
final class HostEventHubConcurrencyTests: XCTestCase {

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

    /// A carrier that records the `$events/result` frames the hub sends.
    ///
    /// `FakeCarrier.eventResult` accepts everything and records nothing, so the
    /// answer path is invisible through it. This wraps one — the `$events` feed
    /// still comes from `FakeCarrier`'s live stream, faults and all — and adds
    /// the frame log plus an optional park, so a case can look at the hub while
    /// an answer is still in flight.
    private final class AnswerCarrier: DSHCarrier, @unchecked Sendable {
        /// The frame log, behind a lock for the same reason `FakeCarrier`'s call
        /// log is: it is appended to from a task while the case reads it.
        private final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var frames: [JSONValue] = []

            func append(_ frame: JSONValue) {
                lock.lock()
                defer { lock.unlock() }
                frames.append(frame)
            }

            var answered: [JSONValue] {
                lock.lock()
                defer { lock.unlock() }
                return frames
            }
        }

        let inner = FakeCarrier()
        private let log = Log()
        /// When set, every `eventResult` parks here until the case opens it.
        var park: TestGate?

        var answered: [JSONValue] { log.answered }

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String, args: Args, as valueType: Value.Type
        ) async throws -> Value {
            try await inner.unary(method: method, args: args, as: valueType)
        }

        func stream<Args: Encodable & Sendable>(
            endpoint: String, args: Args
        ) async -> AsyncThrowingStream<JSONValue, any Error> {
            await inner.stream(endpoint: endpoint, args: args)
        }

        func eventResult(_ result: JSONValue) async throws {
            log.append(result)
            if let park { await park.wait() }
        }

        func close() async {}
    }

    /// An `$events` feed the case pushes frames into.
    private func liveGateway(_ carrier: AnswerCarrier) -> LinkGateway {
        carrier.inner.registerLiveStream("$events")
        let client = HostClientFactory.make(carrier: carrier)
        return LinkGateway(clientProvider: { client })
    }

    /// Starts the hub on a live feed and pushes `frames` into it.
    ///
    /// The stream is opened first so nothing is yielded before someone is
    /// listening.
    private func startLiveFeed(_ carrier: AnswerCarrier, _ frames: [JSONValue] = []) async {
        hub.start(link: liveGateway(carrier))
        await carrier.inner.waitForLiveStream("$events")
        guard let live = carrier.inner.liveStreams["$events"] else {
            return XCTFail("the hub never subscribed to $events")
        }
        for frame in frames { live.yield(frame) }
    }

    private static func readyFrame(clientId: String, home: String = "/Users/tester") -> JSONValue {
        .object([
            "type": .string("ready"),
            "clientId": .string(clientId),
            "host": .object(["home": .string(home)]),
        ])
    }

    private static func waterfallFrame(_ eventId: String,
                                       event: String = "user-questions/request",
                                       agentId: String = "session-1") -> JSONValue {
        .object([
            "type": .string("waterfall"),
            "event": .string(event),
            "eventId": .string(eventId),
            "agentId": .string(agentId),
            "request": .object(["question": .string("Continue?")]),
        ])
    }

    private static func cancelFrame(_ eventId: String) -> JSONValue {
        .object([
            "type": .string("cancel"),
            "eventId": .string(eventId),
        ])
    }

    /// One string field of a recorded answer frame.
    private func field(_ frame: JSONValue, _ key: String) -> String? {
        guard case .object(let object) = frame, case .string(let value)? = object[key] else { return nil }
        return value
    }

    /// The `outcome.kind` of a recorded answer frame (`next` / `result` / …).
    private func outcomeKind(_ frame: JSONValue) -> String? {
        guard case .object(let object) = frame, case .object(let outcome)? = object["outcome"] else { return nil }
        guard case .string(let kind)? = outcome["kind"] else { return nil }
        return kind
    }

    /// The event id of a waterfall or cancellation frame, for ordering checks.
    private func id(of event: HostEvent?) -> String? {
        switch event {
        case .waterfall(let waterfall): return waterfall.eventId
        case .cancelled(let eventId): return eventId
        default: return nil
        }
    }

    /// Runs the main actor until `condition` holds, or fails the case.
    private func eventually(
        _ description: String,
        deadline: TimeInterval = 5,
        _ condition: () -> Bool
    ) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)")
    }

    // MARK: - One prompt, two answers

    func test_answering_the_same_prompt_twice_is_idempotent_for_the_pending_set() async throws {
        let carrier = AnswerCarrier()
        await startLiveFeed(carrier, [
            Self.readyFrame(clientId: "client-1"),
            Self.waterfallFrame("event-1"),
        ])

        await eventually("the prompt to be promoted") { hub.pending.count == 1 }
        let item = try XCTUnwrap(hub.pending.first)

        try await hub.answer(item, with: .next)
        XCTAssertTrue(hub.pending.isEmpty, "an answered prompt must leave the pending set")
        XCTAssertEqual(carrier.answered.count, 1)
        XCTAssertEqual(field(carrier.answered[0], "clientId"), "client-1")
        XCTAssertEqual(field(carrier.answered[0], "eventId"), "event-1")
        XCTAssertEqual(outcomeKind(carrier.answered[0]), "next")

        // 029 缺陷10已修：第二次应答在本地被拒绝（先认领后发），不产生第二帧。
        do {
            try await hub.answer(item, with: .next)
            XCTFail("the second answer must be refused locally")
        } catch {
            XCTAssertEqual(error as? HostEventHub.HostEventHubError, .promptAlreadyAnswered)
        }
        XCTAssertTrue(hub.pending.isEmpty, "the repeat must not put the prompt back")
        XCTAssertEqual(carrier.answered.count, 1,
                       "the hub claims locally: the second answer never reaches the wire")
    }

    func test_two_consumers_answering_one_prompt_both_reach_the_wire_and_the_prompt_goes_once() async throws {
        let carrier = AnswerCarrier()
        let park = TestGate()
        carrier.park = park
        await startLiveFeed(carrier, [
            Self.readyFrame(clientId: "client-1"),
            Self.waterfallFrame("event-1"),
        ])

        await eventually("the prompt to be promoted") { hub.pending.count == 1 }
        let item = try XCTUnwrap(hub.pending.first)

        // Two screens answer the same prompt; the local claim decides the winner.
        let first = Task { try await hub.answer(item, with: .result(.string("yes"))) }
        let second = Task { try await hub.answer(item, with: .rejected(code: "declined", message: "not me")) }

        await park.open()
        var errors: [String] = []
        for task in [first, second] {
            do { try await task.value } catch { errors.append("\(error)") }
        }

        // 029 缺陷10已修：恰好一帧上线；输家在本地拿到 promptAlreadyAnswered。
        XCTAssertEqual(carrier.answered.count, 1,
                       "exactly one answer reaches the wire; got \(carrier.answered.count)")
        XCTAssertEqual(errors.count, 1,
                       "exactly one caller is told it lost; got \(errors)")
        XCTAssertTrue(hub.pending.isEmpty, "the prompt is answered exactly once from here")
    }

    // MARK: - One subscriber that stops reading

    func test_a_full_subscriber_buffer_drops_the_oldest_frames_without_stopping_the_feed() async throws {
        let carrier = AnswerCarrier()
        await startLiveFeed(carrier)
        let live = try XCTUnwrap(carrier.inner.liveStreams["$events"])
        let stream = hub.events()

        // More waterfalls than the hub's declared window (`bufferingNewest(512)`)
        // keeps, so the buffer is guaranteed to overflow before anyone reads a
        // frame.
        live.yield(Self.readyFrame(clientId: "client-1"))
        for ordinal in 0...600 { live.yield(Self.waterfallFrame("e\(ordinal)")) }
        await eventually("every frame to be folded", deadline: 20) { hub.pending.count == 601 }

        // Nothing has consumed yet. The hub must fold one more frame instead of
        // blocking on the full subscriber buffer: this is the whole point of
        // `bufferingNewest` — one screen that stops reading cannot stall the
        // app's only event stream.
        live.yield(Self.waterfallFrame("e601"))
        await eventually("the feed to survive a full subscriber buffer", deadline: 20) {
            hub.pending.count == 602
        }

        var received: [HostEvent] = []
        let collector = Task { for await event in stream { received.append(event) } }
        defer { collector.cancel() }

        await eventually("the subscriber to drain its window", deadline: 20) { received.count >= 512 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(received.count, 512, "the window is exactly the declared capacity")

        // 603 frames have been yielded by now (a ready frame plus `e0`...`e601`)
        // and the subscriber has read none of them, so the newest 512 are the
        // ones still buffered: `e90`...`e601`, i.e. the 91 oldest were dropped
        // and the newest frame survived.
        XCTAssertEqual(id(of: received.first), "e90", "the frames dropped must be the oldest ones")
        XCTAssertEqual(id(of: received.last), "e601", "the newest frame must survive the overflow")

        // The stream is interrupted, not ended: a frame pushed after the
        // overflow still reaches the subscriber, and the hub is still folding.
        live.yield(Self.cancelFrame("e90"))
        await eventually("a post-overflow frame to arrive") { received.count == 513 }
        guard case .cancelled(let cancelled)? = received.last else {
            return XCTFail("expected the post-overflow cancellation last, got \(String(describing: received.last))")
        }
        XCTAssertEqual(cancelled, "e90")
        XCTAssertEqual(hub.pending.count, 601, "the hub kept folding after the overflow")
    }

    // MARK: - Reconnect

    func test_restarting_after_stop_feeds_only_the_new_subscription() async throws {
        let first = AnswerCarrier()
        await startLiveFeed(first, [
            Self.readyFrame(clientId: "client-1"),
            Self.waterfallFrame("event-1"),
        ])

        let oldStream = hub.events()
        var old: [HostEvent] = []
        var oldFinished = false
        let oldCollector = Task {
            for await event in oldStream { old.append(event) }
            oldFinished = true
        }
        await eventually("the first round to unfold") { hub.pending.count == 1 && old.count == 2 }

        hub.stop()

        await eventually("the old subscription to end") { oldFinished }
        await oldCollector.value
        XCTAssertFalse(hub.isLive, "a stopped hub is not live")
        XCTAssertTrue(hub.pending.isEmpty, "stop() must not leave a prompt behind")

        // The second round is a new socket — what a reconnect looks like from
        // here is exactly this: `start` re-subscribes on whatever link it is
        // handed now (the app hands it the store's freshly built gateway). Only
        // a subscription opened after `start()` may see these frames.
        let second = AnswerCarrier()
        await startLiveFeed(second, [
            Self.readyFrame(clientId: "client-2", home: "/Users/second"),
            Self.waterfallFrame("event-2", agentId: "session-2"),
        ])

        let newStream = hub.events()
        var fresh: [HostEvent] = []
        let newCollector = Task { for await event in newStream { fresh.append(event) } }
        defer { newCollector.cancel() }

        await eventually("the new subscription to receive the feed") { fresh.count == 2 && hub.pending.count == 1 }

        guard case .ready(let clientId, let home)? = fresh.first else {
            return XCTFail("expected a ready frame first, got \(String(describing: fresh.first))")
        }
        XCTAssertEqual(clientId, "client-2")
        XCTAssertEqual(home, "/Users/second")
        XCTAssertEqual(id(of: fresh.last), "event-2")
        XCTAssertEqual(hub.pending.first?.id, "event-2", "the second round's prompt replaced the cleared one")

        // The old subscription is finished for good: the new socket's frames
        // never reach it, and it did not resume.
        XCTAssertEqual(old.count, 2)
        XCTAssertTrue(oldFinished)
    }

    // MARK: - SessionRouter: one request, several consumers

    /// The take-once rule itself is checked in `SessionRouterTests`. Kept here is
    /// the part that needs two consumers acting at once: whichever of them reads
    /// the box first is the only one that gets anything. That rule is what keeps
    /// one notification tap from pushing the same transcript twice, so it is
    /// worth pinning under a burst rather than one call after another.
    func test_consumers_racing_for_one_request_leave_exactly_one_holder() async {
        let router = SessionRouter()
        router.request(sessionId: "session-1")

        let held = await withTaskGroup(of: SessionRequest?.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in router.take() }
            }
            var taken: [SessionRequest] = []
            for await request in group {
                if let request { taken.append(request) }
            }
            return taken
        }

        XCTAssertEqual(held.count, 1, "one tap must have exactly one holder; got \(held.count)")
        XCTAssertEqual(held.first?.sessionId, "session-1")
        XCTAssertNil(router.requestedSessionId, "the mirror is cleared with the box")
    }

    /// `take()` and `takeIntent()` are the same action seen two ways, so a race
    /// between them must also produce exactly one winner — a second exit that
    /// reads the box would reintroduce the double push through the back door.
    func test_take_and_takeIntent_racing_for_one_request_have_exactly_one_winner() async {
        let router = SessionRouter()
        router.request(sessionId: "session-1")

        let winners = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in router.take() == nil ? nil : "take" }
            group.addTask { @MainActor in router.takeIntent() == nil ? nil : "intent" }
            var won: [String] = []
            for await winner in group {
                if let winner { won.append(winner) }
            }
            return won
        }

        XCTAssertEqual(winners.count, 1, "the two exits share one box; got \(winners)")
        XCTAssertTrue(winners == ["take"] || winners == ["intent"])
        XCTAssertNil(router.requestedSessionId)
        XCTAssertNil(router.take(), "nothing is left for a third consumer")
        XCTAssertNil(router.takeIntent())
    }
}

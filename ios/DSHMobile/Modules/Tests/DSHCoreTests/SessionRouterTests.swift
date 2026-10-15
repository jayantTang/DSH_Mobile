// `@testable`: the router has no public initializer (the app only ever uses
// `.shared`), and the read-only mirrors it exposes are internal. Cases here
// still build throwaway instances and never touch `.shared`.
@testable import DSHCore
import XCTest

/// 025 T016 — `SessionRouter`'s take-once rule (015) and its payload parsing.
///
/// The router is a process-wide object because a notification tap can arrive
/// before any view exists; the defect it removes is a request being *read* by
/// two consumers, which pushed the same transcript twice. That rule lives in
/// the box behind `request`/`take`, so it is checked here on throwaway
/// instances — nothing in this file touches `SessionRouter.shared`.
///
/// `RouteIntent` (tasks T014) does not exist in this tree yet: the router was
/// never split into intent and execution, so there is no enum to encode. When
/// it lands, its cases belong in this target.
@MainActor
final class SessionRouterTests: XCTestCase {


    // MARK: - Take once, own once

    func test_a_request_is_taken_exactly_once() {
        let router = SessionRouter()

        router.request(sessionId: "session-1")

        XCTAssertEqual(router.requestedSessionId, "session-1")
        XCTAssertEqual(router.take()?.sessionId, "session-1")
        XCTAssertNil(router.take(), "a second consumer must get nothing to act on")
        XCTAssertNil(router.requestedSessionId, "the mirror has to be cleared with the box")
    }

    func test_taking_nothing_is_not_an_error() {
        let router = SessionRouter()

        XCTAssertNil(router.take())
        XCTAssertNil(router.requestedSessionId)
        XCTAssertEqual(router.routingToken, "0")
    }

    func test_the_newest_request_wins() {
        let router = SessionRouter()

        router.request(sessionId: "session-1")
        router.request(sessionId: "session-2")

        XCTAssertEqual(router.take()?.sessionId, "session-2")
        XCTAssertNil(router.take())
    }

    func test_every_request_gets_its_own_generation() {
        // Two taps on the same session are two events: the view drives its
        // handler on the token, so a repeated id must still re-run it.
        let router = SessionRouter()

        router.request(sessionId: "session-1")
        let first = router.take()
        router.request(sessionId: "session-1")
        let second = router.take()

        XCTAssertEqual(first?.sessionId, second?.sessionId)
        XCTAssertEqual(first?.generation, 1)
        XCTAssertEqual(second?.generation, 2)
        XCTAssertNotEqual(first?.generation, second?.generation)
    }

    func test_the_routing_token_tracks_the_generation() {
        let router = SessionRouter()

        router.request(sessionId: "session-1")
        XCTAssertEqual(router.routingToken, "1")

        router.request(sessionId: "session-2")
        XCTAssertEqual(router.routingToken, "2")

        _ = router.take()
        XCTAssertEqual(router.routingToken, "2", "taking must not rewind the token")
    }

    func test_consume_is_the_older_take_that_drops_the_generation() {
        let router = SessionRouter()

        router.request(sessionId: "session-1")

        XCTAssertEqual(router.consume(), "session-1")
        XCTAssertNil(router.consume())
    }

    // MARK: - The diagnostic hook

    func test_the_probe_hook_sees_both_the_request_and_the_take() {
        final class Notes {
            var kinds: [String] = []
            var fields: [[String: String]] = []
        }
        let notes = Notes()
        let router = SessionRouter()
        router.probeNote = { (kind: String, fields: [String: String], _: Bool) in
            notes.kinds.append(kind)
            notes.fields.append(fields)
        }

        router.request(sessionId: "session-1")
        _ = router.take()

        XCTAssertEqual(notes.kinds, ["route.request", "route.take"])
        XCTAssertEqual(notes.fields.first?["sid"], "session-1")
        XCTAssertEqual(notes.fields.last?["sid"], "session-1")
        XCTAssertEqual(notes.fields.first?["generation"], "1")
    }

    // MARK: - Payload parsing

    func test_a_session_id_is_read_from_either_key() {
        XCTAssertEqual(SessionRouter.sessionId(in: ["sessionId": "from-session-id"]), "from-session-id")
        XCTAssertEqual(SessionRouter.sessionId(in: ["sid": "from-sid"]), "from-sid")
    }

    func test_the_payload_is_trimmed_before_it_is_used() {
        XCTAssertEqual(SessionRouter.sessionId(in: ["sid": "  session-1 \n"]), "session-1")
    }

    func test_an_empty_payload_yields_no_request_at_all() {
        XCTAssertNil(SessionRouter.sessionId(in: [:]))
        XCTAssertNil(SessionRouter.sessionId(in: ["sid": ""]))
        XCTAssertNil(SessionRouter.sessionId(in: ["sid": "   "]))
        XCTAssertNil(SessionRouter.sessionId(in: ["sid": 42]))
        XCTAssertNil(SessionRouter.sessionId(in: ["sid": ["nested": "no"]]))
    }

    func test_the_launch_payload_is_read_when_the_runner_passes_one() {
        // `-DSHNotifySession <id>` reproduces a cold launch from a notification
        // tap, which `simctl launch` cannot otherwise produce. A test runner
        // passes no such switch, which is itself the case under test: nothing
        // asked for must read as `nil`, not as an empty session id.
        let arguments = CommandLine.arguments
        let flag = "-DSHNotifySession"
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            XCTAssertNil(SessionRouter.automationRequestedSession())
            return
        }
        let expected = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(SessionRouter.automationRequestedSession(), expected.isEmpty ? nil : expected)
    }
}

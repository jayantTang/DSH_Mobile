import XCTest
@testable import DSHKit

/// The ordering rules behind "运行中的排最前".
///
/// Tested here rather than in a UI run because a list looks identical whichever
/// way it was sorted — unless the run happens to catch the exact two rows that
/// moved, which is how an ordering case passes for the wrong reason.
final class SessionListOrderTests: XCTestCase {

    private struct Row {
        let id: String
        let state: SessionRowState
        let updatedAt: Double
    }

    private struct Bucket {
        let id: String
        let running: Bool
        let activity: Double
    }

    func testAGroupWithSomethingRunningComesFirst() {
        let groups = [
            Bucket(id: "quiet-newest", running: false, activity: 9_000),
            Bucket(id: "busy-oldest", running: true, activity: 100),
        ]
        let ordered = SessionListOrder.groups(groups, isRunning: \.running, activity: \.activity)
        XCTAssertEqual(ordered.map(\.id), ["busy-oldest", "quiet-newest"])
    }

    func testQuietGroupsKeepNewestFirst() {
        // The parts are independent: running-ness decides between them, recency
        // decides inside each.
        let groups = [
            Bucket(id: "old", running: false, activity: 100),
            Bucket(id: "new", running: false, activity: 900),
        ]
        let ordered = SessionListOrder.groups(groups, isRunning: \.running, activity: \.activity)
        XCTAssertEqual(ordered.map(\.id), ["new", "old"])
    }

    func testTwoRunningGroupsBreakTheTieOnActivity() {
        let groups = [
            Bucket(id: "busy-older", running: true, activity: 100),
            Bucket(id: "busy-newer", running: true, activity: 500),
        ]
        let ordered = SessionListOrder.groups(groups, isRunning: \.running, activity: \.activity)
        XCTAssertEqual(ordered.map(\.id), ["busy-newer", "busy-older"])
    }

    func testRowsSortRunningThenUnseenThenSeenThenBlank() {
        let rows = [
            Row(id: "blank", state: .blank, updatedAt: 9_000),
            Row(id: "seen", state: .finishedSeen, updatedAt: 8_000),
            Row(id: "unseen", state: .finishedUnseen, updatedAt: 7_000),
            Row(id: "running", state: .running, updatedAt: 1_000),
        ]
        let ordered = SessionListOrder.members(rows, state: \.state, updatedAt: \.updatedAt)
        XCTAssertEqual(ordered.map(\.id), ["running", "unseen", "seen", "blank"])
    }

    func testRowsInsideAStateBucketAreNewestFirst() {
        let rows = [
            Row(id: "older", state: .finishedUnseen, updatedAt: 100),
            Row(id: "newer", state: .finishedUnseen, updatedAt: 400),
        ]
        let ordered = SessionListOrder.members(rows, state: \.state, updatedAt: \.updatedAt)
        XCTAssertEqual(ordered.map(\.id), ["newer", "older"])
    }

    func testABlankSessionNeverOutranksAFinishedOne() {
        // A session created a second ago is "newest", and it still belongs at the
        // bottom: it has nothing for the user to read.
        let rows = [
            Row(id: "just-created", state: .blank, updatedAt: 1_000_000),
            Row(id: "finished", state: .finishedSeen, updatedAt: 10),
        ]
        let ordered = SessionListOrder.members(rows, state: \.state, updatedAt: \.updatedAt)
        XCTAssertEqual(ordered.map(\.id), ["finished", "just-created"])
    }
}

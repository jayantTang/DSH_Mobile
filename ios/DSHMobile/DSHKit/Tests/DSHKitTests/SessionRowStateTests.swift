import XCTest
@testable import DSHKit

/// The three-state rule behind the session list's leading dot.
///
/// The list is the one screen a person checks to answer "did anything finish
/// while I was away?", so each branch here is a claim the UI makes about the
/// user's attention. Getting one wrong is not a cosmetic bug: mark everything
/// unseen and the dot means nothing, mark nothing and the phone stops being
/// useful for walking away.
final class SessionRowStateTests: XCTestCase {

    func testARunningSessionIsRunningEvenIfItWasJustOpened() {
        XCTAssertEqual(
            SessionRowState.of(running: true, blank: false, updatedAt: 500, lastViewedAt: 900),
            .running
        )
    }

    func testFinishedAfterTheLastLookIsUnseen() {
        XCTAssertEqual(
            SessionRowState.of(running: false, blank: false, updatedAt: 1_000, lastViewedAt: 900),
            .finishedUnseen
        )
    }

    func testFinishedBeforeTheLastLookIsSeen() {
        XCTAssertEqual(
            SessionRowState.of(running: false, blank: false, updatedAt: 800, lastViewedAt: 900),
            .finishedSeen
        )
    }

    func testTheSameInstantCountsAsSeen() {
        // Opening a session and having nothing change afterwards must not leave
        // a dot behind: `updatedAt` is the last activity, and viewing is one.
        XCTAssertEqual(
            SessionRowState.of(running: false, blank: false, updatedAt: 900, lastViewedAt: 900),
            .finishedSeen
        )
    }

    func testANeverOpenedSessionIsSeenRatherThanUnseen() {
        // The first refresh after pairing lists sessions the phone has never
        // opened — finished days ago on the computer. Calling those unseen would
        // make the marker meaningless on day one.
        XCTAssertEqual(
            SessionRowState.of(running: false, blank: false, updatedAt: 5_000, lastViewedAt: nil),
            .finishedSeen
        )
    }

    func testABlankSessionIsNeitherRunningNorUnseen() {
        // "新会话" has no turn to have finished; the list shows it faint instead.
        XCTAssertEqual(
            SessionRowState.of(running: false, blank: true, updatedAt: 1_000, lastViewedAt: 100),
            .blank
        )
    }

    func testRunningOutranksBlank() {
        // A session is blank until its first turn ends; while that turn runs it
        // is running first, blank second.
        XCTAssertEqual(
            SessionRowState.of(running: true, blank: true, updatedAt: 1_000, lastViewedAt: nil),
            .running
        )
    }

    func testTheRankOrderIsRunningUnseenSeenBlank() {
        XCTAssertEqual(
            SessionRowState.allCases.sorted { $0.rank < $1.rank },
            [.running, .finishedUnseen, .finishedSeen, .blank]
        )
    }
}

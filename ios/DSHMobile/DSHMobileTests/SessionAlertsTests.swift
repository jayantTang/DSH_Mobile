#if DEBUG
import XCTest

@testable import DSHMobile

/// SR-08.06: one event kind per session maps to one notification identity, so a
/// repeated delivery replaces the banner instead of stacking another one.
@MainActor
final class SessionAlertsTests: XCTestCase {
    func testSameEventUsesTheSameIdentifier() {
        XCTAssertEqual(SessionAlerts.identifier(for: .turnEnd, sessionId: "s-1"), "turn-end-s-1")
        XCTAssertEqual(SessionAlerts.identifier(for: .attention, sessionId: "s-1"), "attention-s-1")
    }

    func testDifferentEventKindsDoNotCollide() {
        XCTAssertNotEqual(SessionAlerts.identifier(for: .turnEnd, sessionId: "s-1"),
                          SessionAlerts.identifier(for: .attention, sessionId: "s-1"))
    }

    func testDifferentSessionsDoNotCollide() {
        XCTAssertNotEqual(SessionAlerts.identifier(for: .turnEnd, sessionId: "s-1"),
                          SessionAlerts.identifier(for: .turnEnd, sessionId: "s-2"))
    }
}
#endif

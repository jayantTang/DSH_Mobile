import XCTest
@testable import DSHKit

final class HistoryTriggerPolicyTests: XCTestCase {
    func test_margin_is_two_screens_with_a_floor() {
        XCTAssertEqual(HistoryTriggerPolicy.margin(viewportHeight: 800), 1600)
        XCTAssertEqual(HistoryTriggerPolicy.margin(viewportHeight: 100), 240)
    }

    func test_requests_when_less_than_two_screens_remain() {
        XCTAssertTrue(HistoryTriggerPolicy.shouldRequest(distanceToTop: 1500, viewportHeight: 800))
        XCTAssertFalse(HistoryTriggerPolicy.shouldRequest(distanceToTop: 1700, viewportHeight: 800))
        XCTAssertTrue(HistoryTriggerPolicy.shouldRequest(distanceToTop: 239, viewportHeight: 100))
    }
}

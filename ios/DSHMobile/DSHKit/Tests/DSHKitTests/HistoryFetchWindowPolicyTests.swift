import XCTest

@testable import DSHKit

final class HistoryFetchWindowPolicyTests: XCTestCase {

    func testStartsAtTheProductBase() {
        XCTAssertEqual(HistoryFetchWindowPolicy().pages, 3)
    }

    func testLowYieldDoublesUpToTheCeiling() {
        var policy = HistoryFetchWindowPolicy()
        XCTAssertEqual(policy.observe(records: 1), 6)
        XCTAssertEqual(policy.observe(records: 1), 8)
        XCTAssertEqual(policy.observe(records: 0), 8, "封顶后不再增长")
    }

    func testHighYieldShrinksBackToTheBase() {
        var policy = HistoryFetchWindowPolicy(pages: 8)
        XCTAssertEqual(policy.observe(records: 80), 4)
        XCTAssertEqual(policy.observe(records: 80), 3)
        XCTAssertEqual(policy.observe(records: 80), 3, "不低于基数")
    }

    func testMiddleYieldKeepsTheWindowSteady() {
        var policy = HistoryFetchWindowPolicy(pages: 6)
        XCTAssertEqual(policy.observe(records: 20), 6)
    }

    func testResetGoesBackToTheBase() {
        var policy = HistoryFetchWindowPolicy(pages: 8)
        policy.reset()
        XCTAssertEqual(policy.pages, 3)
    }
}

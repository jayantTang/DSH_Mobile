@testable import DSHChatDomain
import XCTest

/// flight 与 driver 拆成两个事实（设计 §5 B1 / 用例 IMG-FLT-01、IMG-FLT-02）。
///
/// flight 存在 = 这张图还没有字节；`settle` 只由"已加载"与"用户取消 / 重置"调用。
/// 驱动因自动次数用尽结束**不**结算——链路恢复时还要靠它重跑。
final class AttachmentFlightsTests: XCTestCase {

    // MARK: - IMG-FLT-01 登记与结案

    func testAFlightStaysUntilItIsSettled() {
        var flights = AttachmentFlights()
        flights.register(id: "at_1", variant: "image/png:1200", session: "s1")

        XCTAssertTrue(flights.isAwaiting(id: "at_1", session: "s1"))
        XCTAssertEqual(flights.awaiting(session: "s1").count, 1)
        XCTAssertEqual(flights.variant(id: "at_1", session: "s1"), "image/png:1200")

        flights.settle(id: "at_1", session: "s1")
        XCTAssertFalse(flights.isAwaiting(id: "at_1", session: "s1"))
        XCTAssertTrue(flights.awaiting(session: "s1").isEmpty)
    }

    func testRegisteringTwiceKeepsOneFlight() {
        var flights = AttachmentFlights()
        flights.register(id: "at_1", variant: nil, session: "s1")
        flights.register(id: "at_1", variant: "v2", session: "s1")
        XCTAssertEqual(flights.count, 1)
        XCTAssertEqual(flights.variant(id: "at_1", session: "s1"), "v2", "登记覆盖同一条")
    }

    func testAFlightBelongsToItsSessionOnly() {
        var flights = AttachmentFlights()
        flights.register(id: "at_1", variant: nil, session: "s1")
        flights.register(id: "at_1", variant: nil, session: "s2")

        XCTAssertEqual(flights.awaiting(session: "s1").count, 1)
        XCTAssertEqual(flights.awaiting(session: "s2").count, 1)
        flights.settle(id: "at_1", session: "s1")
        XCTAssertTrue(flights.awaiting(session: "s1").isEmpty)
        XCTAssertFalse(flights.awaiting(session: "s2").isEmpty, "另一个会话不受影响")
    }

    // MARK: - IMG-FLT-02 会话裁剪

    func testPruningDropsTheOtherSessionsAndRemoveAllClearsEverything() {
        var flights = AttachmentFlights()
        flights.register(id: "at_a", variant: nil, session: "A")
        flights.register(id: "at_b", variant: nil, session: "B")

        flights.prune(sessions: ["A"])
        XCTAssertTrue(flights.isAwaiting(id: "at_a", session: "A"))
        XCTAssertFalse(flights.isAwaiting(id: "at_b", session: "B"))

        flights.removeAll()
        XCTAssertEqual(flights.count, 0)
        XCTAssertTrue(flights.awaiting(session: "A").isEmpty)
    }

    // MARK: - 用尽不结算

    func testAnExhaustedDriverLeavesTheFlightForTheNextLinkEstablish() {
        var flights = AttachmentFlights()
        flights.register(id: "at_1", variant: nil, session: "s1")

        // 「自动次数用尽」在驱动层：它只结束驱动，不碰这张表。
        // 这里断言的是语义：没有人调 settle，flight 就还在。
        XCTAssertTrue(flights.isAwaiting(id: "at_1", session: "s1"))
        XCTAssertEqual(flights.pending(session: "s1").map(\.attachmentId), ["at_1"])
    }
}

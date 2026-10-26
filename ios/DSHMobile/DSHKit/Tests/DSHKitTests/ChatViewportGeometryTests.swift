import XCTest

@testable import DSHKit

final class ChatViewportGeometryTests: XCTestCase {
    func test_long_content_bottom_is_content_plus_inset_minus_viewport() {
        let g = ChatViewportGeometry(viewportHeight: 500, contentBottom: 1200,
                                     topInset: 20, bottomInset: 80)
        XCTAssertEqual(g.maxOffset, 780, accuracy: 0.001)
        XCTAssertEqual(g.distanceFromBottom(offset: 780), 0, accuracy: 0.001)
        XCTAssertTrue(g.isAtBottom(offset: 780))
        XCTAssertFalse(g.isAtBottom(offset: 680))
    }

    func test_keyboard_inset_extends_the_bottom_without_moving_content() {
        let without = ChatViewportGeometry(viewportHeight: 500, contentBottom: 1200, bottomInset: 0)
        let with = ChatViewportGeometry(viewportHeight: 500, contentBottom: 1200, bottomInset: 300)
        XCTAssertEqual(without.maxOffset, 700, accuracy: 0.001)
        XCTAssertEqual(with.maxOffset, 1000, accuracy: 0.001)
        XCTAssertEqual(with.distanceFromBottom(offset: 700), 300, accuracy: 0.001)
    }

    func test_short_content_cannot_scroll_and_sits_at_top() {
        let g = ChatViewportGeometry(viewportHeight: 500, contentBottom: 200,
                                     topInset: 10, bottomInset: 80)
        XCTAssertEqual(g.maxOffset, -10, accuracy: 0.001)
        XCTAssertTrue(g.isAtBottom(offset: -10))
    }

    func test_content_growth_changes_the_target() {
        let before = ChatViewportGeometry(viewportHeight: 500, contentBottom: 1200)
        let after = ChatViewportGeometry(viewportHeight: 500, contentBottom: 1500)
        XCTAssertEqual(after.maxOffset - before.maxOffset, 300, accuracy: 0.001)
    }
}

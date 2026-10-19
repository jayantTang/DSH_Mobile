import XCTest
@testable import DSHKit

final class FetchJobCoordinatorTests: XCTestCase {
    func test_same_range_joins_instead_of_duplicate() {
        var coordinator = FetchJobCoordinator()
        guard case .run = coordinator.request(100...149, slot: .user) else {
            return XCTFail("first request must run")
        }
        XCTAssertEqual(coordinator.request(100...149, slot: .user), .joined)
        XCTAssertEqual(coordinator.depth, 1)
    }

    func test_user_slot_is_exclusive_but_prefetch_does_not_block() {
        var coordinator = FetchJobCoordinator()
        guard case .run = coordinator.request(100...149, slot: .user) else {
            return XCTFail("first user request must run")
        }
        XCTAssertEqual(coordinator.request(50...99, slot: .user), .rejectedUserBusy)
        guard case .run = coordinator.request(50...99, slot: .prefetch) else {
            return XCTFail("prefetch has its own slot")
        }
        XCTAssertEqual(coordinator.depth, 2)
    }

    func test_cancel_only_touches_overlapping_ranges() {
        var coordinator = FetchJobCoordinator()
        _ = coordinator.request(100...149, slot: .user)
        _ = coordinator.request(300...349, slot: .prefetch)
        XCTAssertEqual(coordinator.cancel(overlapping: 120...140), [100...149])
        XCTAssertNil(coordinator.state(of: 100...149))
        XCTAssertEqual(coordinator.state(of: 300...349), .running(attempt: 1))
    }

    func test_terminal_ranges_are_removed_and_reusable() {
        var coordinator = FetchJobCoordinator()
        _ = coordinator.request(100...149, slot: .user)
        XCTAssertTrue(coordinator.succeed(100...149))
        XCTAssertEqual(coordinator.depth, 0)
        guard case .run = coordinator.request(100...149, slot: .user) else {
            return XCTFail("a finished range can be requested again")
        }
    }

    func test_depth_cap_matches_two_slots() {
        var coordinator = FetchJobCoordinator()
        _ = coordinator.request(1...50, slot: .user)
        _ = coordinator.request(51...100, slot: .prefetch)
        XCTAssertEqual(coordinator.depth, FetchJobCoordinator.maxDepth)
    }
}

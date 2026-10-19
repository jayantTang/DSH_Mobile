import XCTest
@testable import DSHKit

final class FetchJobMachineTests: XCTestCase {
    func test_four_attempts_then_retryable_failure() {
        var job = FetchJobMachine(slot: .user)
        XCTAssertTrue(job.start())
        XCTAssertEqual(job.attemptFailed(elapsed: 0.1), .retry(after: 0.5))
        XCTAssertTrue(job.resumeAfterBackoff(0.5))
        XCTAssertEqual(job.attemptFailed(elapsed: 0.1), .retry(after: 1))
        XCTAssertTrue(job.resumeAfterBackoff(1))
        XCTAssertEqual(job.attemptFailed(elapsed: 0.1), .retry(after: 2))
        XCTAssertTrue(job.resumeAfterBackoff(2))
        XCTAssertEqual(job.attemptFailed(elapsed: 0.1), .fail)
        XCTAssertEqual(job.state, .failed(retryable: true))
        XCTAssertEqual(job.attempts, 4, "首次 + 3 次退避")
    }

    func test_success_is_terminal_and_ignores_later_ticks() {
        var job = FetchJobMachine(slot: .prefetch)
        XCTAssertTrue(job.start())
        job.succeed()
        XCTAssertEqual(job.state, .succeeded)
        XCTAssertTrue(job.isTerminal)
        XCTAssertEqual(job.attemptFailed(), .ignore)
        XCTAssertFalse(job.start())
    }

    func test_cancel_is_terminal_and_idempotent() {
        var job = FetchJobMachine(slot: .user)
        job.cancel()
        XCTAssertEqual(job.state, .cancelled)
        job.cancel()
        XCTAssertEqual(job.state, .cancelled)
        XCTAssertFalse(job.start())
    }

    func test_batch_budget_fails_even_with_attempts_left() {
        var job = FetchJobMachine(slot: .user)
        XCTAssertTrue(job.start())
        XCTAssertEqual(job.advance(by: 5.9), .ignore)
        XCTAssertEqual(job.advance(by: 0.2), .fail)
        XCTAssertEqual(job.state, .failed(retryable: true))
    }

    func test_backoff_sequence_is_bounded() {
        var job = FetchJobMachine(slot: .user)
        XCTAssertTrue(job.start())
        var delays: [TimeInterval] = []
        for _ in 0..<3 {
            guard case .retry(let delay) = job.attemptFailed(elapsed: 0.1) else {
                return XCTFail("expected retry")
            }
            delays.append(delay)
            _ = job.resumeAfterBackoff(delay)
        }
        XCTAssertEqual(delays, [0.5, 1, 2])
    }
}

@testable import DSHChatDomain
import XCTest

/// 一张图的加载状态机：失败之后必须自己再试，不能停在失败态等用户点。
final class AttachmentLoadMachineTests: XCTestCase {

    func test_begin_counts_attempts() {
        var machine = AttachmentLoadMachine()
        XCTAssertEqual(machine.phase, .idle)
        machine.begin()
        XCTAssertEqual(machine.phase, .loading(attempt: 1))
        machine.begin()
        XCTAssertEqual(machine.phase, .loading(attempt: 2))
    }

    func test_fail_schedules_backoff_without_losing_the_attempt() {
        var machine = AttachmentLoadMachine()
        machine.begin()
        let delay = machine.fail(reason: "socket")
        XCTAssertEqual(delay, .seconds(1))
        XCTAssertEqual(machine.phase, .failed(attempt: 1, reason: "socket"))
        XCTAssertEqual(machine.attempt, 1, "退避期间 attempt 不得被清零，否则重试次数形同虚设")
    }

    func test_backoff_table_grows_then_caps() {
        let expected: [Duration] = [
            .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30), .seconds(30),
        ]
        for (index, delay) in expected.enumerated() {
            XCTAssertEqual(AttachmentLoadMachine.backoff(afterAttempt: index + 1), delay,
                           "第 \(index + 1) 次失败后的等待时长不对")
        }
    }

    func test_automatic_retries_stop_at_the_cap() {
        var machine = AttachmentLoadMachine()
        for attempt in 1...AttachmentLoadMachine.maxAutomaticAttempts {
            machine.begin()
            let delay = machine.fail(reason: "boom")
            if attempt < AttachmentLoadMachine.maxAutomaticAttempts {
                XCTAssertNotNil(delay, "第 \(attempt) 次失败后还应继续自动重试")
            } else {
                XCTAssertNil(delay, "用尽自动次数后不该再排下一次")
                XCTAssertEqual(machine.phase,
                               .failed(attempt: AttachmentLoadMachine.maxAutomaticAttempts, reason: "boom"))
            }
        }
    }

    func test_success_clears_the_attempt_counter() {
        var machine = AttachmentLoadMachine()
        machine.begin()
        _ = machine.fail(reason: "boom")
        machine.begin()
        machine.succeed()
        XCTAssertEqual(machine.phase, .loaded)
        XCTAssertEqual(machine.attempt, 0)
        XCTAssertTrue(machine.isFinished)
    }

    func test_manual_retry_starts_over() {
        var machine = AttachmentLoadMachine()
        machine.begin()
        _ = machine.fail(reason: "boom")
        machine.prepareManualRetry()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.attempt, 0, "手动重试要重新给满自动次数")
        machine.begin()
        XCTAssertEqual(machine.phase, .loading(attempt: 1))
    }

    func test_link_rebuild_invalidates_so_the_next_begin_is_first_attempt() {
        var machine = AttachmentLoadMachine()
        machine.begin()
        _ = machine.fail(reason: "offline")
        machine.begin()
        _ = machine.fail(reason: "offline")
        machine.invalidate()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.attempt, 0)
        machine.begin()
        XCTAssertEqual(machine.phase, .loading(attempt: 1))
    }

    func test_failed_is_not_finished_so_a_tap_is_still_possible() {
        var machine = AttachmentLoadMachine()
        machine.begin()
        _ = machine.fail(reason: "boom")
        XCTAssertFalse(machine.isFinished)
    }
}

import XCTest

@testable import DSHKit

/// 事件流重订阅节奏的用例（spec 023 边界收敛：从 `HostEventHub.start` 抽出的策略）。
final class EventStreamRetryTests: XCTestCase {

    func testLinearStepsUpToTheCap() {
        XCTAssertEqual(EventStreamRetry.delay(afterAttempt: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(EventStreamRetry.delay(afterAttempt: 2), 1.0, accuracy: 1e-9)
        XCTAssertEqual(EventStreamRetry.delay(afterAttempt: 3), 1.5, accuracy: 1e-9)
        XCTAssertEqual(EventStreamRetry.delay(afterAttempt: 16), 8.0, accuracy: 1e-9)
    }

    func testItIsCapped() {
        XCTAssertEqual(EventStreamRetry.delay(afterAttempt: 17), 8.0, accuracy: 1e-9)
        XCTAssertEqual(EventStreamRetry.delay(afterAttempt: 1_000), 8.0, accuracy: 1e-9)
    }

    func testNonPositiveAttemptStillWaitsOneStep() {
        // 空转（0 秒）会让一条死链路把 CPU 打满，所以第 0/负数次也至少等一个 step。
        XCTAssertEqual(EventStreamRetry.delay(afterAttempt: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(EventStreamRetry.delay(afterAttempt: -3), 0.5, accuracy: 1e-9)
    }

    func testItNeverDecreases() {
        var last: TimeInterval = 0
        for attempt in 1...40 {
            let delay = EventStreamRetry.delay(afterAttempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, last)
            last = delay
        }
    }

    func testItIsDeliberatelyDenserThanTheConnectionBackoff() {
        // 这条重试不拨号，只是重新订阅，所以比"拨新 socket"的退避密：封顶 8 秒 vs 30 秒。
        // 两边都在 DSHKit，差异是设计而不是漂移——这条用例是那句话的机器版本。
        XCTAssertLessThan(EventStreamRetry.maximumDelay, ReconnectBackoff().cap)
        XCTAssertLessThan(EventStreamRetry.maximumDelay, ReconnectBackoff.stabilityWindow)
    }

    func testConstantsArePinned() {
        // 改这两个数会改变用户看到的恢复速度，所以调它必须是有意的。
        XCTAssertEqual(EventStreamRetry.step, 0.5)
        XCTAssertEqual(EventStreamRetry.maximumDelay, 8)
    }
}

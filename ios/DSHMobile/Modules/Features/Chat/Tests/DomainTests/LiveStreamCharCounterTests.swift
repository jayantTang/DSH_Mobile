import DSHKit
import XCTest

@testable import DSHChatDomain

final class LiveStreamCharCounterTests: XCTestCase {
    func test_counts_text_and_reasoning_until_end() {
        var counter = LiveStreamCharCounter()
        counter.apply(.start(attemptId: "a1", revision: 1, turn: 1, step: 1, startedAfterSeq: 1))
        counter.apply(.chunk(attemptId: "a1", revision: 1, index: 0, time: nil,
                             chunk: .reasoningDelta("先看")))
        counter.apply(.chunk(attemptId: "a1", revision: 1, index: 1, time: nil,
                             chunk: .textDelta("我现在")))
        XCTAssertEqual(counter.chars, 5)
        counter.apply(.end(attemptId: "a1", revision: 1, index: 2, committedSeq: 9))
        XCTAssertEqual(counter.chars, 0)
    }

    func test_ignores_chunks_from_another_attempt() {
        var counter = LiveStreamCharCounter()
        counter.apply(.start(attemptId: "a1", revision: 1, turn: 1, step: 1, startedAfterSeq: 1))
        counter.apply(.chunk(attemptId: "a2", revision: 1, index: 0, time: nil,
                             chunk: .textDelta("别算")))
        XCTAssertEqual(counter.chars, 0)
    }
}

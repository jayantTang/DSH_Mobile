@testable import DSHChatDomain
import XCTest

/// 单条正文缓存的上限与 LRU（D6）：没有预算就会把本地库撑大，没有淘汰就只会涨。
final class StepBodyCacheTests: XCTestCase {

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func test_a_body_is_cached_and_read_back() {
        var cache = StepBodyCache()
        XCTAssertTrue(cache.record("a", text: "AAAA", bytes: 4, at: at(10)))
        XCTAssertEqual(cache.text(for: "a"), "AAAA")
        XCTAssertEqual(cache.totalBytes, 4)
    }

    func test_recording_the_same_step_replaces_instead_of_duplicating() {
        var cache = StepBodyCache()
        cache.record("a", text: "OLD", bytes: 3, at: at(10))
        cache.record("a", text: "NEW!!", bytes: 5, at: at(20))
        XCTAssertEqual(cache.text(for: "a"), "NEW!!")
        XCTAssertEqual(cache.entries.count, 1)
        XCTAssertEqual(cache.totalBytes, 5)
    }

    func test_the_total_budget_evicts_the_least_recently_used_first() {
        var cache = StepBodyCache()
        cache.record("old", text: "1234", bytes: 4, at: at(10))
        cache.record("mid", text: "1234", bytes: 4, at: at(20))
        cache.record("new", text: "1234", bytes: 4, at: at(30))
        // 预算 8B：只能装两条，最久没用的 "old" 先走。
        cache.evict(limitBytes: 8)
        XCTAssertNil(cache.text(for: "old"))
        XCTAssertEqual(cache.text(for: "mid"), "1234")
        XCTAssertEqual(cache.text(for: "new"), "1234")
        XCTAssertEqual(cache.totalBytes, 8)
    }

    func test_touching_a_body_moves_it_out_of_the_eviction_front() {
        var cache = StepBodyCache()
        cache.record("a", text: "1234", bytes: 4, at: at(10))
        cache.record("b", text: "1234", bytes: 4, at: at(20))
        // 读一次 a：它变成最近使用，超预算时该走 b。
        cache.touch("a", at: at(30))
        cache.record("c", text: "1234", bytes: 4, at: at(40), limitBytes: 8)
        XCTAssertEqual(cache.text(for: "a"), "1234")
        XCTAssertNil(cache.text(for: "b"))
        XCTAssertEqual(cache.text(for: "c"), "1234")
    }

    func test_a_body_larger_than_the_whole_budget_is_not_cached() {
        var cache = StepBodyCache()
        XCTAssertFalse(cache.record("huge", text: "1234567890", bytes: 10, at: at(10),
                                    limitBytes: 8))
        XCTAssertNil(cache.text(for: "huge"))
        XCTAssertTrue(cache.isEmpty)
    }

    func test_the_cache_round_trips_through_json() throws {
        var cache = StepBodyCache()
        cache.record("a", text: "AAAA", bytes: 4, at: at(10))
        cache.record("b", text: "BBBBBB", bytes: 6, at: at(20))
        let data = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(StepBodyCache.self, from: data)
        XCTAssertEqual(decoded.text(for: "a"), "AAAA")
        XCTAssertEqual(decoded.text(for: "b"), "BBBBBB")
        XCTAssertEqual(decoded.totalBytes, 10)
    }
}

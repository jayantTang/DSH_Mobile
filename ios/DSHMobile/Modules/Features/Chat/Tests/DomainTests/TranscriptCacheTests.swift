@testable import DSHChatDomain
import DSHKit
import XCTest

/// 暖转写缓存的有界淘汰：连跳多个会话时不能无限长。
@MainActor
final class TranscriptCacheTests: XCTestCase {

    private func entry() -> TranscriptCache.Entry {
        TranscriptCache.Entry(
            timeline: ChatTimeline(), hasOlder: false,
            oldestSeq: nil, throughSeq: 0, records: [])
    }

    func testEvictsTheLeastRecentlyStoredBeyondLimit() {
        let cache = TranscriptCache(limit: 2)
        cache.store(entry(), for: "a")
        cache.store(entry(), for: "b")
        cache.store(entry(), for: "c")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.entry(for: "a"))
        XCTAssertNotNil(cache.entry(for: "c"))
    }

    func testStoringAgainMovesTheKeyToTheNewestSlot() {
        let cache = TranscriptCache(limit: 2)
        cache.store(entry(), for: "a")
        cache.store(entry(), for: "b")
        cache.store(entry(), for: "a")
        cache.store(entry(), for: "c")
        XCTAssertNotNil(cache.entry(for: "a"))
        XCTAssertNil(cache.entry(for: "b"))
    }

    func testRemoveAndClear() {
        let cache = TranscriptCache(limit: 3)
        cache.store(entry(), for: "a")
        cache.remove("a")
        XCTAssertNil(cache.entry(for: "a"))
        cache.store(entry(), for: "b")
        cache.clear()
        XCTAssertEqual(cache.count, 0)
    }
}

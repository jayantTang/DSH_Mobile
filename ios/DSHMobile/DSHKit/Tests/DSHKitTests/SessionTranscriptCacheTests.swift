import DSHKit
import XCTest


/// 「搜索往前读的更早历史」落盘：往返、裁剪方向、坏文件与清理。
final class SessionOlderCacheTests: XCTestCase {
    private func record(_ seq: Int) -> SessionRecord {
        let json = #"{"type":"user/message","seq":\#(seq),"time":1789276358732,"data":{"content":[]}}"#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    func testOlderHistoryRoundTripsPerComputer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SessionTranscriptCache(root: root)
        cache.saveOlder(records: (1...20).map(record), hasOlder: true, scope: "mac-a", sessionId: "s1")
        let back = try XCTUnwrap(cache.loadOlder(scope: "mac-a", sessionId: "s1"))
        XCTAssertEqual(back.records.map(\.event.seq), Array(1...20))
        XCTAssertEqual(back.oldestSeq, 1)
        XCTAssertTrue(back.hasOlder)
        XCTAssertNil(cache.loadOlder(scope: "mac-b", sessionId: "s1"), "另一台电脑不该看到这份")
        XCTAssertNil(cache.loadOlder(scope: "mac-a", sessionId: "s2"))
    }

    func testOlderHistoryTrimsTheOldestEnd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SessionTranscriptCache(root: root)
        let many = (1...(SessionTranscriptCache.maxOlderRecords + 50)).map(record)
        cache.saveOlder(records: many, hasOlder: true, scope: "mac", sessionId: "s1")
        let back = try XCTUnwrap(cache.loadOlder(scope: "mac", sessionId: "s1"))
        XCTAssertEqual(back.records.count, SessionTranscriptCache.maxOlderRecords)
        XCTAssertEqual(back.records.last?.event.seq, many.last?.event.seq, "保住紧挨窗口的新那头")
        XCTAssertEqual(back.records.first?.event.seq, 51, "丢的是最老的那 50 条")
        XCTAssertEqual(back.oldestSeq, 51, "游标跟着真正存下的记录走")
    }

    func testClearRemovesBothFiles() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SessionTranscriptCache(root: root)
        cache.save(SessionTranscriptSnapshot(savedAt: Date(), records: (1...5).map(record),
                                            oldestSeq: 1, throughSeq: 5, hasOlder: false),
                   scope: "mac", sessionId: "s1")
        cache.saveOlder(records: (1...5).map(record), hasOlder: false, scope: "mac", sessionId: "s1")
        cache.clear(scope: "mac", sessionId: "s1")
        XCTAssertNil(cache.load(scope: "mac", sessionId: "s1"))
        XCTAssertNil(cache.loadOlder(scope: "mac", sessionId: "s1"))
    }

    func testStaleOlderHistoryIsDropped() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var now = Date()
        let cache = SessionTranscriptCache(root: root, now: { now })
        cache.saveOlder(records: (1...5).map(record), hasOlder: false, scope: "mac", sessionId: "s1")
        now = now.addingTimeInterval(SessionTranscriptCache.maxAge + 60)
        XCTAssertNil(cache.loadOlder(scope: "mac", sessionId: "s1"))
    }
}

import Foundation
import Testing

@testable import DSHKit

/// The transcript tail is what makes opening a session show its content instead
/// of a spinner on a cold start, so what matters here is that it is *safe* to
/// show: the right session's records, never a stale month, never more than the
/// phone can afford.
@Suite("Session transcript cache")
struct SessionTranscriptCacheTests {

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(seq: Int, text: String = "行") -> SessionRecord {
        let json = """
        {"event":{"type":"assistant/message","seq":\(seq),"time":1700000000000,
         "data":{"message":{"id":"m\(seq)","content":[{"type":"text","text":"\(text)\(seq)"}]}}}}
        """
        return try! JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
    }

    private func snapshot(_ count: Int, savedAt: Date = Date()) -> SessionTranscriptSnapshot {
        let records = (1...count).map { record(seq: $0) }
        return SessionTranscriptSnapshot(
            savedAt: savedAt,
            records: records,
            oldestSeq: records.first?.event.seq,
            throughSeq: count,
            hasOlder: count > 1
        )
    }

    @Test("a tail survives a round trip, per computer and session")
    func roundTrip() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SessionTranscriptCache(root: root)

        cache.save(snapshot(3), scope: "agt_a", sessionId: "session-1")
        cache.save(snapshot(5), scope: "agt_b", sessionId: "session-1")

        let a = cache.load(scope: "agt_a", sessionId: "session-1")
        let b = cache.load(scope: "agt_b", sessionId: "session-1")
        #expect(a?.records.count == 3)
        #expect(b?.records.count == 5)
        // 另一台电脑的同名会话不会串味
        #expect(a?.records.last?.event.seq == 3)
        #expect(b?.records.last?.event.seq == 5)
        #expect(cache.load(scope: "agt_a", sessionId: "session-2") == nil)
    }

    @Test("only the newest records are kept")
    func trimsToTheTail() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SessionTranscriptCache(root: root)

        cache.save(snapshot(500), scope: "agt_a", sessionId: "s")
        let loaded = cache.load(scope: "agt_a", sessionId: "s")
        #expect(loaded?.records.count == SessionTranscriptCache.maxRecords)
        // 留下的是**尾部**：最后一条仍然是 500，第一条是 500-199
        #expect(loaded?.records.last?.event.seq == 500)
        #expect(loaded?.records.first?.event.seq == 500 - SessionTranscriptCache.maxRecords + 1)
        #expect(loaded?.hasOlder == true)
    }

    @Test("a tail older than the window is dropped")
    func staleTailIsDeleted() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = SessionTranscriptCache(root: root, now: { saved })
        cache.save(snapshot(2, savedAt: saved), scope: "agt_a", sessionId: "s")

        let later = SessionTranscriptCache(
            root: root, now: { saved.addingTimeInterval(31 * 24 * 60 * 60) })
        #expect(later.load(scope: "agt_a", sessionId: "s") == nil)
    }

    @Test("pruning drops the oldest files first when the budget is exceeded")
    func prunesByBudget() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 用"现在"当基准：文件 mtime 是真实的，注入一个假时钟会让比较失真。
        var current = Date()
        let cache = SessionTranscriptCache(root: root, now: { current })

        for index in 0..<3 {
            current = current.addingTimeInterval(60)
            cache.save(snapshot(60), scope: "agt_a", sessionId: "s-\(index)")
        }
        let before = cache.sizeOnDisk()
        #expect(before > 0)

        // 预算只够装一份：最老的先走，最新的留下
        let tiny = SessionTranscriptCache(root: root, now: { current }, budgetBytes: before / 3)
        #expect(tiny.prune() >= 1)
        #expect(tiny.sizeOnDisk() < before)
        #expect(cache.load(scope: "agt_a", sessionId: "s-2") != nil)
        #expect(cache.load(scope: "agt_a", sessionId: "s-0") == nil)
    }

    @Test("pruning drops everything once the window has passed")
    func prunesByAge() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var current = Date()
        let cache = SessionTranscriptCache(root: root, now: { current })
        cache.save(snapshot(5), scope: "agt_a", sessionId: "s")
        #expect(cache.sizeOnDisk() > 0)

        current = current.addingTimeInterval(31 * 24 * 60 * 60)
        #expect(cache.prune() >= 1)
        #expect(cache.sizeOnDisk() == 0)
    }

    @Test("clearing one session leaves the others alone")
    func clearOne() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SessionTranscriptCache(root: root)
        cache.save(snapshot(2), scope: "agt_a", sessionId: "s-1")
        cache.save(snapshot(2), scope: "agt_a", sessionId: "s-2")

        cache.clear(scope: "agt_a", sessionId: "s-1")
        #expect(cache.load(scope: "agt_a", sessionId: "s-1") == nil)
        #expect(cache.load(scope: "agt_a", sessionId: "s-2") != nil)

        cache.clearAll()
        #expect(cache.load(scope: "agt_a", sessionId: "s-2") == nil)
    }

    @Test("host-chosen ids cannot escape the cache directory")
    func idsAreSlugged() {
        #expect(SessionTranscriptCache.slug("../../etc/passwd") == "______etc_passwd")
        #expect(SessionTranscriptCache.slug("agt_abc-123") == "agt_abc-123")
        #expect(SessionTranscriptCache.slug("") == "unknown")
    }
}

import Foundation
import Testing

@testable import DSHKit

/// Pictures are the bulkiest thing the phone caches, so the rules that matter
/// are the cheap ones: the right host's bytes, nothing ancient, nothing over
/// budget.
@Suite("Attachment disk cache")
struct AttachmentDiskCacheTests {

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("bytes survive a round trip, per computer")
    func roundTrip() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AttachmentDiskCache(root: root)

        cache.save(Data("png-a".utf8), scope: "agt_a", attachmentId: "att_1")
        cache.save(Data("png-b".utf8), scope: "agt_b", attachmentId: "att_1")

        #expect(cache.load(scope: "agt_a", attachmentId: "att_1") == Data("png-a".utf8))
        #expect(cache.load(scope: "agt_b", attachmentId: "att_1") == Data("png-b".utf8))
        #expect(cache.load(scope: "agt_a", attachmentId: "att_2") == nil)
    }

    @Test("a picture older than the window is dropped")
    func stalePictureIsDeleted() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var current = Date()
        let cache = AttachmentDiskCache(root: root, now: { current })
        cache.save(Data("png".utf8), scope: "agt_a", attachmentId: "att_1")

        current = current.addingTimeInterval(31 * 24 * 60 * 60)
        #expect(cache.load(scope: "agt_a", attachmentId: "att_1") == nil)
    }

    @Test("pruning keeps the newest pictures when the budget is exceeded")
    func prunesByBudget() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var current = Date()
        let cache = AttachmentDiskCache(root: root, now: { current })

        for index in 0..<3 {
            current = current.addingTimeInterval(60)
            cache.save(Data(repeating: UInt8(index), count: 4_000), scope: "agt_a", attachmentId: "att_\(index)")
        }

        let tiny = AttachmentDiskCache(root: root, now: { current }, budgetBytes: 5_000)
        #expect(tiny.prune() >= 1)
        // 最新那张留下，最老的被丢掉
        #expect(cache.load(scope: "agt_a", attachmentId: "att_2") != nil)
        #expect(cache.load(scope: "agt_a", attachmentId: "att_0") == nil)
    }

    @Test("clearing removes everything")
    func clearAll() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AttachmentDiskCache(root: root)
        cache.save(Data("png".utf8), scope: "agt_a", attachmentId: "att_1")
        cache.clearAll()
        #expect(cache.load(scope: "agt_a", attachmentId: "att_1") == nil)
    }
}

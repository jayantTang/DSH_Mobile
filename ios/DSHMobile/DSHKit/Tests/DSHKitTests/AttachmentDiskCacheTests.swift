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

    @Test("two contents under one id do not collide")
    func variantSeparatesContent() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AttachmentDiskCache(root: root)

        cache.save(Data("old".utf8), scope: "agt_a", attachmentId: "att_1", variant: "10-image/png")
        cache.save(Data("new".utf8), scope: "agt_a", attachmentId: "att_1", variant: "20-image/png")

        #expect(cache.load(scope: "agt_a", attachmentId: "att_1", variant: "10-image/png") == Data("old".utf8))
        #expect(cache.load(scope: "agt_a", attachmentId: "att_1", variant: "20-image/png") == Data("new".utf8))
        // 没给标识时按 id 本身取（老调用方）
        #expect(cache.load(scope: "agt_a", attachmentId: "att_1") == nil)
    }

    @Test("pruning leaves files that were just written alone")
    func pruneSkipsFreshFiles() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var current = Date()
        let cache = AttachmentDiskCache(root: root, now: { current }, budgetBytes: 1)
        cache.save(Data(repeating: 1, count: 2_000), scope: "agt_a", attachmentId: "att_1")

        // 预算小到任何东西都超：但刚写的（10 秒内）不参与裁剪
        #expect(cache.prune() == 0)
        #expect(cache.load(scope: "agt_a", attachmentId: "att_1") != nil)

        // 过了 10 秒再看，它就该被预算挤掉了
        current = current.addingTimeInterval(11)
        #expect(cache.prune() == 1)
        #expect(cache.load(scope: "agt_a", attachmentId: "att_1") == nil)
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

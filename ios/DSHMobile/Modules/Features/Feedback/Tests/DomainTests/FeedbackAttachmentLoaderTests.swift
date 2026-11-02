@testable import DSHFeedbackDomain
import DSHFoundation
import RelayKit
import XCTest

/// 附件加载器（§5.1-8）：`fetch` → 用元数据里的 sha256 自校验 → 落缓存 → 复用。
///
/// 两条硬要求：摘要不符按失败态返回**且不写缓存**（下次还能重取）；同一摘要命中
/// 缓存后不再发请求。
@MainActor
final class FeedbackAttachmentLoaderTests: XCTestCase {

    private let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

    private func attachment(digest: String? = nil) -> FeedbackAttachment {
        FeedbackAttachment(
            attachmentId: "fa_1", name: "a.png", contentType: "image/png",
            byteSize: bytes.count,
            sha256: digest ?? FeedbackOutgoingAttachment.sha256Hex(bytes),
            createdAt: Date()
        )
    }

    private func root(_ label: String) -> TempFeedbackRoot {
        let root = TempFeedbackRoot(label: label)
        addTeardownBlock { root.remove() }
        return root
    }

    func testBytesThatDoNotMatchTheDigestFailAndAreNotCached() async throws {
        let root = root("loader-mismatch")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let bad = attachment(digest: String(repeating: "0", count: 64))
        var attempts = 0
        let cache = FeedbackAttachmentCache(disk: disk, fetch: { _ in
            attempts += 1
            return self.bytes
        })

        do {
            _ = try await cache.data(for: bad)
            XCTFail("a digest mismatch must surface as a failure")
        } catch let error as FeedbackAttachmentCache.LoadError {
            guard case .digestMismatch(let expected, let actual) = error else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
            XCTAssertEqual(expected, bad.sha256)
            XCTAssertEqual(actual, FeedbackOutgoingAttachment.sha256Hex(bytes))
        }
        XCTAssertNil(disk.cachedBytes(sha256: bad.sha256), "坏字节不许进缓存")

        // 重试：这次用正确的摘要，能拿到字节并进缓存（失败不是终局）。
        let good = attachment()
        let retried = try await cache.data(for: good)
        XCTAssertEqual(retried, bytes)
        XCTAssertEqual(disk.cachedBytes(sha256: good.sha256), bytes)
        XCTAssertEqual(attempts, 2)
    }

    func testASecondLoadHitsTheCacheInsteadOfTheNetwork() async throws {
        let root = root("loader-cache")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let good = attachment()
        var requests = 0
        let cache = FeedbackAttachmentCache(disk: disk, fetch: { _ in
            requests += 1
            return self.bytes
        })

        _ = try await cache.data(for: good)
        _ = try await cache.data(for: good)

        XCTAssertEqual(requests, 1, "同一 sha256 命中缓存后不再请求")
        XCTAssertEqual(cache.cached(good), bytes)
    }

    func testClearingTheCacheDropsTheBytesAndTheNextLoadRequestsAgain() async throws {
        let root = root("loader-clear")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let good = attachment()
        var requests = 0
        let cache = FeedbackAttachmentCache(disk: disk, fetch: { _ in
            requests += 1
            return self.bytes
        })

        _ = try await cache.data(for: good)
        cache.clear()
        XCTAssertNil(cache.cached(good))
        _ = try await cache.data(for: good)
        XCTAssertEqual(requests, 2)
    }
}

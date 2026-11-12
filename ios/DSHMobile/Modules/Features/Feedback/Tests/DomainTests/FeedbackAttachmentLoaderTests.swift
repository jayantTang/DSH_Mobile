@testable import DSHFeedbackDomain
import DSHFoundation
import Foundation
import RelayKit
import XCTest

/// 附件缓存的状态机（设计 §5 A5 / 用例 IMG-CLI-03…07）。
///
/// 四种结局都要落到可见状态：加载中带进度、成功、失败（可重试）、取消回 idle。
/// 摘要复核失败不写缓存；取消不写缓存。
@MainActor
final class FeedbackAttachmentLoaderTests: XCTestCase {

    /// 一张最小可解码的 PNG（1×1，透明）：缩略图用例需要真能被 ImageIO 读的字节。
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private var bytes: Data { Self.png }

    private func attachment(digest: String? = nil,
                            preview: FeedbackAttachmentPreview? = nil,
                            compressed: Bool = false) -> FeedbackAttachment {
        FeedbackAttachment(
            attachmentId: "fa_original", name: "a.png", contentType: "image/png",
            byteSize: bytes.count,
            sha256: digest ?? FeedbackOutgoingAttachment.sha256Hex(bytes),
            createdAt: Date(), preview: preview, compressed: compressed)
    }

    private func previewOf(_ data: Data) -> FeedbackAttachmentPreview {
        FeedbackAttachmentPreview(attachmentId: "fa_preview", contentType: "image/jpeg",
                                  byteSize: data.count,
                                  sha256: FeedbackOutgoingAttachment.sha256Hex(data),
                                  width: 64, height: 64)
    }

    private func root(_ label: String) -> TempFeedbackRoot {
        let root = TempFeedbackRoot(label: label)
        addTeardownBlock { root.remove() }
        return root
    }

    /// 假 fetch：按脚本给出分块与总长；`gate` 让用例能在加载中观察状态。
    private final class FakeFetch {
        var chunks: [Data] = []
        var total: Int?
        var failure: (any Error)?
        var calls = 0
        var ids: [String] = []
        var gate: Gate?
        /// 按调用序号（1 起）覆盖的闸门与失败：`cancel → reload` 这类交错要靠它。
        var gatesByCall: [Int: Gate] = [:]
        var failuresByCall: [Int: any Error] = [:]

        func run(_ attachmentId: String,
                 _ progress: (@Sendable (Int, Int?) -> Void)?) async throws -> Data {
            calls += 1
            let index = calls
            ids.append(attachmentId)
            progress?(0, total)
            var delivered = Data()
            for chunk in chunks {
                try await (gatesByCall[index] ?? gate)?.wait()
                try Task.checkCancellation()
                delivered.append(chunk)
                progress?(delivered.count, total)
            }
            try await (gatesByCall[index] ?? gate)?.wait()
            try Task.checkCancellation()
            if let callFailure = failuresByCall[index] ?? failure { throw callFailure }
            return delivered
        }
    }

    /// 一次性闸门：`wait()` 挂起，直到 `release()`。用例靠它稳定观察"加载中"。
    actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func release() {
            open = true
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private func cache(_ fake: FakeFetch, disk: FeedbackAttachmentDisk) -> FeedbackAttachmentCache {
        FeedbackAttachmentCache(disk: disk, fetch: { id, progress in
            try await fake.run(id, progress)
        })
    }

    // MARK: - IMG-CLI-03 成功与进度

    func testLoadingReportsProgressAndEndsLoaded() async {
        let root = root("loader-progress")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let fake = FakeFetch()
        let delivered = Data(repeating: 0x41, count: 12)
        fake.total = 12
        fake.chunks = [Data(repeating: 0x41, count: 4), Data(repeating: 0x41, count: 8)]
        let cache = self.cache(fake, disk: disk)
        let target = attachment(digest: FeedbackOutgoingAttachment.sha256Hex(delivered))

        XCTAssertEqual(cache.state(for: target, variant: .original), .idle)

        let loading = Task { await cache.load(target, variant: .original) }
        await Task.yield()
        // 0 字节的起点先写进去（UI 一挂上就能看到进度条），随后是真实进度。
        guard case .loading(let received, _) = cache.state(for: target, variant: .original) else {
            return XCTFail("加载中应可见：\(cache.state(for: target, variant: .original))")
        }
        XCTAssertLessThanOrEqual(received, 12)

        let returned = await loading.value
        XCTAssertEqual(returned, fake.chunks.reduce(Data(), +))
        XCTAssertEqual(cache.state(for: target, variant: .original), .loaded)
        XCTAssertEqual(disk.cachedBytes(sha256: target.sha256), delivered, "成功必须落缓存")
    }

    func testSecondLoadHitsTheDiskInsteadOfTheNetwork() async {
        let root = root("loader-cache")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let fake = FakeFetch()
        fake.total = bytes.count
        fake.chunks = [bytes]
        let cache = self.cache(fake, disk: disk)
        let target = attachment()

        await cache.load(target, variant: .original)
        await cache.load(target, variant: .original)

        XCTAssertEqual(fake.calls, 1, "同一 sha256 命中缓存后不再请求")
        XCTAssertEqual(cache.cached(target), bytes)
        XCTAssertEqual(cache.state(for: target, variant: .original), .loaded)
    }

    // MARK: - IMG-CLI-04 失败后重试

    func testAFailureIsVisibleAndRetryable() async {
        let root = root("loader-retry")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let fake = FakeFetch()
        fake.failure = FeedbackClientError.network("offline")
        let cache = self.cache(fake, disk: disk)
        let target = attachment()
        let preview = previewOf(Data(repeating: 0x7E, count: 8))

        let first = await cache.load(target, variant: .original)
        XCTAssertNil(first)
        guard case .failed = cache.state(for: target, variant: .original) else {
            return XCTFail("失败必须落到 .failed：\(cache.state(for: target, variant: .original))")
        }

        // 预览不受影响：它的字节是另一份，直接命中缓存即可读。
        disk.storeCache(Data(repeating: 0x7E, count: 8), sha256: preview.sha256)
        let previewBytes = await cache.load(attachment(preview: preview), variant: .preview)
        XCTAssertEqual(previewBytes, Data(repeating: 0x7E, count: 8))

        // 第二次成功：状态从 failed 到 loaded，请求第 2 次。
        fake.failure = nil
        fake.chunks = [bytes]
        fake.total = bytes.count
        let second = await cache.load(target, variant: .original)
        XCTAssertEqual(second, bytes)
        XCTAssertEqual(cache.state(for: target, variant: .original), .loaded)
        XCTAssertEqual(fake.calls, 2)
    }

    // MARK: - IMG-CLI-05 取消

    func testCancellingAnOriginalReturnsToIdleAndWritesNothing() async {
        let root = root("loader-cancel")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let fake = FakeFetch()
        let gate = Gate()
        fake.gate = gate
        fake.total = 8
        fake.chunks = [Data(repeating: 0x41, count: 4), Data(repeating: 0x42, count: 4)]
        let cache = self.cache(fake, disk: disk)
        let target = attachment()

        let loading = Task { await cache.load(target, variant: .original) }
        await Task.yield()
        cache.cancelOriginal(target)
        await gate.release()
        _ = await loading.value

        XCTAssertEqual(cache.state(for: target, variant: .original), .idle, "取消回 idle")
        XCTAssertNil(disk.cachedBytes(sha256: target.sha256), "取消不写缓存")

        // 还能再点一次（取消不是终局）。
        fake.gate = nil
        fake.chunks = [bytes]
        fake.total = bytes.count
        let retried = await cache.load(target, variant: .original)
        XCTAssertEqual(retried, bytes)
        XCTAssertEqual(cache.state(for: target, variant: .original), .loaded)
    }

    // MARK: - P1-4 取消后立刻重试

    func testACancelledLoadDoesNotOverwriteTheRetryThatFollowed() async {
        let root = root("loader-cancel-retry")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let fake = FakeFetch()
        let slow = Gate()
        fake.total = bytes.count
        fake.chunks = [bytes]
        // 第一次请求：卡在闸门上，放行后**失败**；第二次请求：直接成功。
        fake.gatesByCall[1] = slow
        fake.failuresByCall[1] = FeedbackClientError.network("offline")
        let cache = self.cache(fake, disk: disk)
        let target = attachment()

        let first = Task { await cache.load(target, variant: .original) }
        await Task.yield()
        cache.cancelOriginal(target)
        XCTAssertEqual(cache.state(for: target, variant: .original), .idle)

        // 取消后立刻重试：新的请求成功。
        let retried = await cache.load(target, variant: .original)
        XCTAssertEqual(retried, bytes)
        XCTAssertEqual(cache.state(for: target, variant: .original), .loaded)

        // 旧任务这时才结束（失败）：不许把新任务的 loaded 改回 failed。
        await slow.release()
        _ = await first.value
        XCTAssertEqual(cache.state(for: target, variant: .original), .loaded,
                       "旧任务的结局不许覆盖新任务")
        XCTAssertEqual(fake.calls, 2)
        XCTAssertEqual(cache.cached(target), bytes)
    }

    // MARK: - IMG-CLI-06 摘要不符

    func testAByteThatDoesNotMatchTheDigestFailsAndIsNotCached() async {
        let root = root("loader-mismatch")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let fake = FakeFetch()
        fake.total = 32
        fake.chunks = [Data(repeating: 0x00, count: 32)]
        let cache = self.cache(fake, disk: disk)
        let target = attachment()

        let loaded = await cache.load(target, variant: .original)
        XCTAssertNil(loaded)
        guard case .failed(let reason) = cache.state(for: target, variant: .original) else {
            return XCTFail("摘要不符必须落到 .failed")
        }
        XCTAssertTrue(reason.contains("\u{5B57}\u{8282}\u{6821}\u{9A8C}\u{5931}\u{8D25}"), reason)
        XCTAssertNil(disk.cachedBytes(sha256: target.sha256), "坏字节不许进缓存")
    }

    // MARK: - IMG-CLI-07 旧信件缩略图

    func testALegacyAttachmentGetsALocalThumbnailOnce() async throws {
        let root = root("loader-thumb")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let fake = FakeFetch()
        fake.total = bytes.count
        fake.chunks = [bytes]
        let cache = self.cache(fake, disk: disk)
        let legacy = attachment()       // 没有 preview、compressed == false

        let loadedThumb = await cache.load(legacy, variant: .thumbnail)
        let first = try XCTUnwrap(loadedThumb)
        XCTAssertLessThanOrEqual(first.count, 32 * 1024)
        let stored = try XCTUnwrap(disk.cachedThumbnail(sha256: legacy.sha256))
        XCTAssertEqual(stored, first)
        XCTAssertEqual(disk.cachedBytes(sha256: legacy.sha256), bytes, "原始字节仍在下载缓存")

        // 第二次直接命中缩略图，不再取字节。
        let second = await cache.load(legacy, variant: .thumbnail)
        XCTAssertEqual(second, first)
        XCTAssertEqual(fake.calls, 1, "第二次不再下载")
    }

    // MARK: - 列表只取预览

    func testThePreviewVariantAsksForThePreviewId() async {
        let root = root("loader-preview-id")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let fake = FakeFetch()
        let previewBytes = Data(repeating: 0x41, count: 16)
        fake.chunks = [previewBytes]
        fake.total = previewBytes.count
        let cache = self.cache(fake, disk: disk)
        let target = attachment(preview: previewOf(previewBytes))

        let listed = await cache.load(target, variant: .preview)
        XCTAssertEqual(listed, previewBytes)
        XCTAssertEqual(fake.ids, ["fa_preview"], "列表读预览那一份，不碰原图 id")

        fake.chunks = [bytes]
        fake.total = bytes.count
        let original = await cache.load(target, variant: .original)
        XCTAssertEqual(original, bytes)
        XCTAssertEqual(fake.ids, ["fa_preview", "fa_original"], "全屏才请求原图")
    }

    func testACompressedAttachmentReadsTheMainObjectForThePreviewVariant() async {
        let root = root("loader-compressed")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let fake = FakeFetch()
        fake.chunks = [bytes]
        fake.total = bytes.count
        let cache = self.cache(fake, disk: disk)
        let onlyPreview = attachment(compressed: true)

        let loaded = await cache.load(onlyPreview, variant: .preview)
        XCTAssertEqual(loaded, bytes)
        XCTAssertEqual(fake.ids, ["fa_original"], "只有预览时主对象就是预览")
        XCTAssertEqual(cache.state(for: onlyPreview, variant: .preview), .loaded)
    }
}

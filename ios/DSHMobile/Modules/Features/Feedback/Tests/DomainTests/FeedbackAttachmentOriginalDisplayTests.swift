@testable import DSHFeedbackDomain
import DSHFoundation
import Foundation
import RelayKit
import XCTest

/// 全屏显示哪一份、原图入口该不该出现（评审 P1-2 / P2-6）。
///
/// 判据是纯函数 `(state, hasCachedOriginal)`：视图只读它，`cached(...)` 不负责触发重画。
@MainActor
final class FeedbackAttachmentOriginalDisplayTests: XCTestCase {

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private func root(_ label: String) -> TempFeedbackRoot {
        let root = TempFeedbackRoot(label: label)
        addTeardownBlock { root.remove() }
        return root
    }

    private func attachment(previewBytes: Data, originalBytes: Data) -> FeedbackAttachment {
        FeedbackAttachment(
            attachmentId: "fa_display_original", name: "a.jpg", contentType: "image/jpeg",
            byteSize: originalBytes.count,
            sha256: FeedbackOutgoingAttachment.sha256Hex(originalBytes),
            createdAt: Date(),
            preview: FeedbackAttachmentPreview(
                attachmentId: "fa_display_preview", contentType: "image/jpeg",
                byteSize: previewBytes.count,
                sha256: FeedbackOutgoingAttachment.sha256Hex(previewBytes),
                width: 64, height: 64),
            compressed: false)
    }

    // MARK: - 纯派生

    func testLoadedOrAlreadyOnDiskShowsTheOriginal() {
        XCTAssertTrue(FeedbackAttachmentOriginalDisplay.isAvailable(state: .loaded,
                                                                    hasCachedOriginal: true))
        XCTAssertTrue(FeedbackAttachmentOriginalDisplay.isAvailable(state: .idle,
                                                                    hasCachedOriginal: true),
                      "磁盘上已经有原图就不该再给下载按钮")
        XCTAssertFalse(FeedbackAttachmentOriginalDisplay.isAvailable(state: .idle,
                                                                     hasCachedOriginal: false))
        XCTAssertFalse(FeedbackAttachmentOriginalDisplay.isAvailable(
            state: .loading(received: 10, total: 2048), hasCachedOriginal: false))
        XCTAssertFalse(FeedbackAttachmentOriginalDisplay.isAvailable(state: .failed("网络不通"),
                                                                     hasCachedOriginal: false),
                       "失败时继续看预览")
    }

    func testTheShownVariantFollowsTheOriginalState() {
        XCTAssertEqual(FeedbackAttachmentOriginalDisplay.shownVariant(
            previewVariant: .preview, state: .idle, hasCachedOriginal: false), .preview)
        XCTAssertEqual(FeedbackAttachmentOriginalDisplay.shownVariant(
            previewVariant: .preview, state: .loading(received: 0, total: 2048),
            hasCachedOriginal: false), .preview)
        XCTAssertEqual(FeedbackAttachmentOriginalDisplay.shownVariant(
            previewVariant: .preview, state: .loaded, hasCachedOriginal: true), .original)
        XCTAssertEqual(FeedbackAttachmentOriginalDisplay.shownVariant(
            previewVariant: .thumbnail, state: .failed("x"), hasCachedOriginal: false), .thumbnail,
            "旧信件失败时仍是缩略图那一份")
    }

    // MARK: - 真实缓存：原图不在缓存 → 下载完成换图

    func testTheViewerSwitchesToTheOriginalAfterADownloadWithoutIt() async {
        let root = root("original-display")
        let disk = FeedbackAttachmentDisk(root: root.url)
        let previewBytes = Data(repeating: 0x50, count: 8)
        let originalBytes = Data(repeating: 0x4F, count: 2048)
        let attachment = attachment(previewBytes: previewBytes, originalBytes: originalBytes)
        disk.storeCache(previewBytes, sha256: attachment.preview!.sha256)

        var requests: [String] = []
        let cache = FeedbackAttachmentCache(disk: disk, fetch: { id, progress in
            requests.append(id)
            progress?(originalBytes.count, originalBytes.count)
            return originalBytes
        })

        // 打开全屏那一刻：原图不在缓存、也没有人请求过 → 显示预览。
        XCTAssertEqual(
            FeedbackAttachmentOriginalDisplay.shownVariant(
                previewVariant: .preview,
                state: cache.state(for: attachment, variant: .original),
                hasCachedOriginal: cache.cached(attachment, variant: .original) != nil),
            .preview)

        await cache.requestOriginal(attachment)

        // 下载完成：状态变成 loaded，派生结果换成原图，字节也真的换了。
        XCTAssertEqual(cache.state(for: attachment, variant: .original), .loaded)
        let variant = FeedbackAttachmentOriginalDisplay.shownVariant(
            previewVariant: .preview,
            state: cache.state(for: attachment, variant: .original),
            hasCachedOriginal: cache.cached(attachment, variant: .original) != nil)
        XCTAssertEqual(variant, .original)
        XCTAssertEqual(cache.cached(attachment, variant: variant), originalBytes)
        XCTAssertEqual(requests, ["fa_display_original"])
    }
}

/// 附件条数上限的判据（评审 P1-3）：预检与入列复查读同一个纯函数。
final class FeedbackAttachmentSlotCapacityTests: XCTestCase {
    func testTheCapIsTheSameRuleEverywhere() {
        XCTAssertTrue(FeedbackAttachmentSlotCapacity.canAdd(currentCount: 7, limit: 8))
        XCTAssertFalse(FeedbackAttachmentSlotCapacity.canAdd(currentCount: 8, limit: 8))
        XCTAssertFalse(FeedbackAttachmentSlotCapacity.canAdd(currentCount: 9, limit: 8))
        XCTAssertFalse(FeedbackAttachmentSlotCapacity.canAdd(currentCount: 0, limit: 0))
        XCTAssertFalse(FeedbackAttachmentSlotCapacity.canAdd(currentCount: -1, limit: 8))
    }
}

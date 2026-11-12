@testable import DSHFeedbackDomain
import Foundation
import RelayKit
import XCTest

/// 「压缩版」标记的判定（设计 §5 A5 / 用例 IMG-CLI-09、TC-MOB-143）。
///
/// 判据只有一个：wire 上的 `attachment.compressed`。正文/列表与全屏两处渲染都读这个
/// 类型，所以这里钉住"什么时候该标、什么时候不标"，两处不会各判一套。
final class FeedbackAttachmentCompressedBadgeTests: XCTestCase {

    private func attachment(compressed: Bool,
                            preview: FeedbackAttachmentPreview? = nil) -> FeedbackAttachment {
        FeedbackAttachment(
            attachmentId: compressed ? "fa_preview" : "fa_original",
            name: "a.jpg", contentType: "image/jpeg", byteSize: 471_859,
            sha256: String(repeating: "a", count: 64), width: 1181, height: 2560,
            createdAt: Date(), preview: preview, compressed: compressed)
    }

    private var previewStub: FeedbackAttachmentPreview {
        FeedbackAttachmentPreview(attachmentId: "fa_preview", contentType: "image/jpeg",
                                  byteSize: 471_859, sha256: String(repeating: "b", count: 64),
                                  width: 1181, height: 2560)
    }

    func testAPreviewOnlyAttachmentIsMarkedCompressed() {
        let badge = FeedbackAttachmentCompressedBadge(attachment(compressed: true))
        XCTAssertEqual(badge, .compressed)
        XCTAssertTrue(badge.isVisible)
        // 文案与标识都只有一处；正文/列表与全屏共用同一个标识。
        XCTAssertEqual(badge.identifier, "feedback.attachment.compressed")
        XCTAssertEqual(badge.text, "\u{538B}\u{7F29}\u{7248}")     // 压缩版
    }

    func testAPairedAttachmentIsNotMarkedCompressed() {
        let badge = FeedbackAttachmentCompressedBadge(
            attachment(compressed: false, preview: previewStub))
        XCTAssertEqual(badge, .none)
        XCTAssertFalse(badge.isVisible, "有原图的附件不该标压缩版")
    }

    func testALegacyAttachmentIsNotMarkedCompressed() {
        // 旧信件：没有 preview、也没有 compressed（主对象就是原图）。
        let badge = FeedbackAttachmentCompressedBadge(attachment(compressed: false))
        XCTAssertEqual(badge, .none)
    }

    func testTheJudgementComesFromCompressedNotFromThePreviewObject() {
        // 反例：带 preview 但 compressed 为 true（历史脏数据）——仍按 compressed 标。
        let badge = FeedbackAttachmentCompressedBadge(
            attachment(compressed: true, preview: previewStub))
        XCTAssertEqual(badge, .compressed, "判据是 compressed 字段，不从 preview 有无反推")
    }
}

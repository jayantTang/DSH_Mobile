@testable import DSHChatDomain
import DSHTestingSupport
import XCTest

/// 预览尺寸与原图上限（契约 §2.2 / SR-02.07）。
///
/// 位图缩放与 JPEG 编码在 UIKit 层（`ChatModel+DraftImages.swift`），但"缩到多大"
/// 与"超限转文件"是纯策略，放在领域层由这里直接验证边界值。
final class ComposerImagePolicyTests: XCTestCase {

    // MARK: 预览尺寸

    func testExactlyAtBothLimitsNeedsNoResize() {
        XCTAssertNil(ComposerImagePolicy.previewPixelSize(sourceWidth: 2560, sourceHeight: 1000),
                     "最长边正好 2560、像素不到 4MP：不重编码")
        XCTAssertTrue(ComposerImagePolicy.fitsPreview(width: 2560, height: 1000))

        XCTAssertNil(ComposerImagePolicy.previewPixelSize(sourceWidth: 2000, sourceHeight: 2000),
                     "正好 4,000,000 像素仍算在限内")
        XCTAssertTrue(ComposerImagePolicy.fitsPreview(width: 2000, height: 2000))
    }

    func testOverLongEdgeIsScaledTo2560() {
        let size = XCTAssertUnwrap(
            ComposerImagePolicy.previewPixelSize(sourceWidth: 3000, sourceHeight: 1000)
        )
        XCTAssertEqual(size.width, 2560)
        XCTAssertEqual(size.height, 853)
        XCTAssertTrue(ComposerImagePolicy.fitsPreview(width: size.width, height: size.height))
    }

    func testOverPixelBudgetIsScaledUntilBothLimitsFit() {
        // 2561×1563 ≈ 4.00 MP，两个上限都只超一点点：结果必须同时满足。
        let overPixels = XCTAssertUnwrap(
            ComposerImagePolicy.previewPixelSize(sourceWidth: 2560, sourceHeight: 1563)
        )
        XCTAssertNotEqual(overPixels.width * overPixels.height, 2560 * 1563)
        XCTAssertTrue(ComposerImagePolicy.fitsPreview(width: overPixels.width, height: overPixels.height))

        // 4000×1000 = 4.00 MP，但最长边超限：先压到 2560。
        let overEdge = XCTAssertUnwrap(
            ComposerImagePolicy.previewPixelSize(sourceWidth: 4000, sourceHeight: 1000)
        )
        XCTAssertEqual(overEdge.width, 2560)
        XCTAssertEqual(overEdge.height, 640)
    }

    func testOnePixelOverBudgetIsResized() {
        let size = XCTAssertUnwrap(
            ComposerImagePolicy.previewPixelSize(sourceWidth: 2001, sourceHeight: 2000)
        )
        XCTAssertTrue(ComposerImagePolicy.fitsPreview(width: size.width, height: size.height))
        XCTAssertLessThan(size.width * size.height, 2001 * 2000)
    }

    func testCameraSizedPhotoStaysUnderBothLimits() {
        let size = XCTAssertUnwrap(
            ComposerImagePolicy.previewPixelSize(sourceWidth: 4032, sourceHeight: 3024)
        )
        XCTAssertLessThanOrEqual(max(size.width, size.height), ComposerImagePolicy.previewMaxEdge)
        XCTAssertLessThanOrEqual(size.width * size.height, ComposerImagePolicy.previewMaxPixels)
        XCTAssertGreaterThan(size.width, 2000, "缩得过分会把预览糊掉")
    }

    func testDegenerateDimensionsAreRejected() {
        XCTAssertNil(ComposerImagePolicy.previewPixelSize(sourceWidth: 0, sourceHeight: 100))
        XCTAssertFalse(ComposerImagePolicy.fitsPreview(width: 0, height: 0))
    }

    // MARK: 原图上限

    func testOriginalAtTwentyMiBIsStillKept() {
        XCTAssertEqual(
            ComposerImagePolicy.originalDisposition(byteCount: 20 * 1024 * 1024),
            .keep,
            "正好 20 MiB 不算超限"
        )
        XCTAssertEqual(
            ComposerImagePolicy.originalDisposition(byteCount: 20 * 1024 * 1024 + 1),
            .sendAsFile,
            "超过 20 MiB 才按普通文件发送"
        )
        XCTAssertEqual(ComposerImagePolicy.originalDisposition(byteCount: 0), .unavailable)
    }
}

private func XCTAssertUnwrap<T>(_ value: T?,
                                file: StaticString = #filePath,
                                line: UInt = #line) -> T {
    guard let value else {
        XCTFail("expected a value", file: file, line: line)
        fatalError("expected a value")
    }
    return value
}

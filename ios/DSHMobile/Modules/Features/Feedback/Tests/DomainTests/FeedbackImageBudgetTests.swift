@testable import DSHFeedbackDomain
import Foundation
import XCTest

/// 编码预算策略（设计 §5 A1 / 用例 IMG-ENC-01…05）。
///
/// 这里只用**假编码器**：预算边界是纯算术与顺序，不需要真实图片、屏幕或 UIKit。
/// 真图片的编码在 `FeedbackImageTranscoderTests`。
final class FeedbackImageBudgetTests: XCTestCase {

    private let previewLimit = 512 * 1024

    /// 按预设长度返回字节的假编码器，并记下被调用了几次、用了哪些步骤。
    private final class FakeEncoder {
        private let sizes: [Int?]
        private(set) var steps: [FeedbackImageStep] = []

        init(_ sizes: [Int?]) { self.sizes = sizes }

        func encode(_ step: FeedbackImageStep) -> Data? {
            steps.append(step)
            let size = sizes.indices.contains(steps.count - 1) ? sizes[steps.count - 1] : nil
            return size.map { Data(repeating: 0x41, count: $0) }
        }
    }

    // MARK: - 512 KiB 边界

    func testExactlyTheBudgetTakesTheFirstStep() {
        let encoder = FakeEncoder([previewLimit])
        let fit = FeedbackImageBudget.firstFitting(
            steps: FeedbackImageBudget.previewSteps(hasAlpha: false),
            byteLimit: previewLimit, encode: encoder.encode)

        XCTAssertEqual(fit?.step, FeedbackImageStep(edge: 2560, quality: 0.85, flattenAlpha: false))
        XCTAssertEqual(encoder.steps.count, 1, "刚好放得下就不该再试第二步")
        XCTAssertEqual(fit?.data.count, 512 * 1024)
        XCTAssertEqual(fit?.contentType, "image/jpeg")
    }

    func testOneByteOverMovesToTheNextStep() {
        let encoder = FakeEncoder([previewLimit + 1, 409_600])
        let fit = FeedbackImageBudget.firstFitting(
            steps: FeedbackImageBudget.previewSteps(hasAlpha: false),
            byteLimit: previewLimit, encode: encoder.encode)

        XCTAssertEqual(fit?.step, FeedbackImageStep(edge: 2560, quality: 0.75, flattenAlpha: false))
        XCTAssertEqual(fit?.data.count, 409_600)
        XCTAssertEqual(encoder.steps.count, 2, "选中第二步就停，不继续试第三步")
    }

    func testNothingFitsReturnsNilAndTriesEveryStep() {
        let steps = FeedbackImageBudget.previewSteps(hasAlpha: false)
        let encoder = FakeEncoder(Array(repeating: previewLimit + 1, count: steps.count))
        XCTAssertNil(FeedbackImageBudget.firstFitting(steps: steps, byteLimit: previewLimit,
                                                     encode: encoder.encode))
        XCTAssertEqual(encoder.steps.count, steps.count, "每一步都要真编一次才知道大小")
    }

    func testAnEncodingFailureIsSkippedNotFatal() {
        let encoder = FakeEncoder([nil, 1_000])
        let fit = FeedbackImageBudget.firstFitting(
            steps: FeedbackImageBudget.previewSteps(hasAlpha: false),
            byteLimit: previewLimit, encode: encoder.encode)
        XCTAssertEqual(fit?.step.quality, 0.75, "编不出来就换下一档")
    }

    // MARK: - alpha

    func testAlphaPreviewStepsAreLosslessAndNeverFlattened() {
        let steps = FeedbackImageBudget.previewSteps(hasAlpha: true)
        let opaque = steps.filter { !$0.flattenAlpha }
        XCTAssertFalse(opaque.isEmpty)
        for step in opaque {
            XCTAssertNil(step.quality, "保留 alpha 的 PNG 没有质量参数")
            XCTAssertEqual(step.contentType, "image/png")
        }
        XCTAssertEqual(opaque.map(\.edge), [2560, 2048, 1600, 1280, 1024])

        let encoder = FakeEncoder(Array(repeating: 400_000, count: opaque.count))
        let fit = FeedbackImageBudget.firstFitting(steps: steps, byteLimit: previewLimit,
                                                   encode: encoder.encode)
        XCTAssertEqual(fit?.contentType, "image/png")
        XCTAssertEqual(fit?.step.quality, nil)
        XCTAssertEqual(fit?.step.flattenAlpha, false)
    }

    func testAlphaFallsBackToAFlattenedJPEGLast() throws {
        let steps = FeedbackImageBudget.previewSteps(hasAlpha: true)
        let last = try XCTUnwrap(steps.last)
        XCTAssertTrue(last.flattenAlpha, "最后一步才是去 alpha")
        XCTAssertEqual(last.edge, 1024)
        XCTAssertEqual(last.quality, 0.55)
        XCTAssertEqual(last.contentType, "image/jpeg")

        // 前面所有 PNG 步骤都放不下，最后一步才成。
        var sizes: [Int?] = Array(repeating: 600_000, count: steps.count - 1)
        sizes.append(300_000)
        let encoder = FakeEncoder(sizes)
        let fit = FeedbackImageBudget.firstFitting(steps: steps, byteLimit: previewLimit,
                                                   encode: encoder.encode)
        XCTAssertEqual(fit?.step, last)
        XCTAssertEqual(encoder.steps.count, steps.count, "前面的 PNG 步骤都被试过")
    }

    // MARK: - 小图不放大

    func testSmallImagesAreNotUpscaled() {
        let clamped = FeedbackImageBudget.clamped(
            FeedbackImageBudget.previewSteps(hasAlpha: false), sourceEdge: 800)
        XCTAssertTrue(clamped.allSatisfy { $0.edge == 800 }, "候选边长夹到源长边")

        let encoder = FakeEncoder([1_000])
        _ = FeedbackImageBudget.firstFitting(steps: clamped, byteLimit: previewLimit,
                                             encode: encoder.encode)
        XCTAssertEqual(encoder.steps.count, 1)
    }

    // MARK: - 原图候选

    func testOriginalStepsStartWithPassthroughWhenAllowed() {
        let steps = FeedbackImageBudget.originalSteps(pixelWidth: 6000, pixelHeight: 4000,
                                                      allowsPassthrough: true)
        XCTAssertEqual(steps.first, .passthrough)
        XCTAssertEqual(steps.dropFirst().first,
                       FeedbackImageStep(edge: 6000, quality: 0.95, flattenAlpha: false))

        let noPass = FeedbackImageBudget.originalSteps(pixelWidth: 6000, pixelHeight: 4000,
                                                       allowsPassthrough: false)
        XCTAssertFalse(noPass.contains(.passthrough))
    }

    func testTheOriginalLadderEndsAtHalfQualityAndThenShrinks() {
        let steps = FeedbackImageBudget.originalSteps(pixelWidth: 6000, pixelHeight: 4000,
                                                      allowsPassthrough: false)
        let fullSize = steps.filter { $0.edge == 6000 }
        XCTAssertEqual(fullSize.map(\.quality), [0.95, 0.92, 0.9, 0.85, 0.8, 0.75, 0.7, 0.65,
                                                 0.6, 0.55, 0.5])
        XCTAssertTrue(steps.last!.edge < 6000, "质量降到 0.5 还超预算才缩边")
        XCTAssertEqual(steps.last!.quality, 0.5)
    }

    func testTheBudgetNumbersLiveOnlyInTheBudget() {
        // 预览边长表与 512 KiB / 8 MiB 都由这个类型给；UI 与发送队列不再写第二份。
        XCTAssertEqual(FeedbackImageBudget.previewByteLimit, 512 * 1024)
        XCTAssertEqual(FeedbackImageBudget.previewSteps(hasAlpha: false).map(\.edge),
                       [2560, 2560, 2560, 2560, 2048, 1600, 1280, 1024])
        XCTAssertEqual(FeedbackImageBudget.previewSteps(hasAlpha: false).map(\.quality),
                       [0.85, 0.75, 0.65, 0.55, 0.55, 0.55, 0.55, 0.55])
    }
}

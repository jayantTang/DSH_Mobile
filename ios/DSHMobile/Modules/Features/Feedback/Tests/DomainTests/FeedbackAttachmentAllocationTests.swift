@testable import DSHFeedbackDomain
import Foundation
import RelayKit
import XCTest

/// 每封 24 MiB 的分配（设计 §5 A3 / 用例 IMG-BUD-01…05）。
///
/// 规则只有一条：先给每个逻辑附件预留主对象（图片预览 / 文件本体），再**按选择顺序**
/// 逐个尝试加入图片的原图，放不下的降级成「仅预览」；后面的小原图不会插队。
final class FeedbackAttachmentAllocationTests: XCTestCase {

    private let limits = FeedbackAttachmentLimits(
        maxPerMessage: 8, maxFileBytes: 8 * 1024 * 1024, maxTotalBytes: 24 * 1024 * 1024,
        types: ["jpeg", "png"], roles: ["original", "preview"])

    private func bytes(_ count: Int) -> Data { Data(repeating: 0x41, count: count) }

    private func image(slot: Int, preview: Int, original: Int?) -> FeedbackPreparedAttachment {
        FeedbackPreparedAttachment(
            slot: slot,
            primary: FeedbackOutgoingAttachment(name: "IMG_\(slot).jpg", contentType: "image/jpeg",
                                                data: bytes(preview), width: 640, height: 480),
            original: original.map {
                FeedbackOutgoingAttachment(name: "IMG_\(slot).jpg", contentType: "image/jpeg",
                                           data: bytes($0), width: 3000, height: 2000)
            })
    }

    private func document(slot: Int, size: Int) -> FeedbackPreparedAttachment {
        FeedbackPreparedAttachment(
            slot: slot,
            primary: FeedbackOutgoingAttachment(name: "说明.pdf", contentType: "application/pdf",
                                                data: bytes(size)),
            original: nil)
    }

    // MARK: - IMG-BUD-01 24 MiB 以内全部带上

    func testEverythingFitsUnderTheLetterBudget() {
        let items = [image(slot: 0, preview: 400 * 1024, original: 7 * 1024 * 1024),
                     image(slot: 1, preview: 400 * 1024, original: 7 * 1024 * 1024),
                     image(slot: 2, preview: 400 * 1024, original: 7 * 1024 * 1024)]
        let plan = FeedbackAttachmentAllocation.plan(items, limits: limits)

        XCTAssertEqual(plan.items.count, 3)
        XCTAssertTrue(plan.items.allSatisfy(\.includeOriginal))
        XCTAssertEqual(plan.totalBytes, 3 * (400 * 1024 + 7 * 1024 * 1024))
        XCTAssertEqual(plan.degradedCount, 0)
        XCTAssertEqual(plan.degradedSlots, [])
    }

    // MARK: - IMG-BUD-02 多出 1 字节就降级最后一个

    func testOneByteOverTheBudgetDowngradesTheLastOriginalInOrder() {
        let preview = 100 * 1024
        // 主对象合计 409 600；留给原图 24 711 424：8 MiB + 8 MiB + 7 979 008 刚好用满。
        let exact = [image(slot: 0, preview: preview, original: 8 * 1024 * 1024),
                     image(slot: 1, preview: preview, original: 8 * 1024 * 1024),
                     image(slot: 2, preview: preview, original: 7_979_008),
                     image(slot: 3, preview: preview, original: 200 * 1024)]
        let plan = FeedbackAttachmentAllocation.plan(exact, limits: limits)
        XCTAssertEqual(plan.items.map(\.includeOriginal), [true, true, true, false])
        XCTAssertEqual(plan.degradedSlots, [3])
        XCTAssertLessThanOrEqual(plan.totalBytes, limits.maxTotalBytes)
        XCTAssertEqual(plan.items.map(\.slot), [0, 1, 2, 3], "顺序不变")

        // 第三个原图再多 1 字节：连它一起降级，后面的 200 KiB 不会插队顶上。
        var oneOver = exact
        oneOver[2] = image(slot: 2, preview: preview, original: 7_979_009)
        let over = FeedbackAttachmentAllocation.plan(oneOver, limits: limits)
        XCTAssertEqual(over.items.map(\.includeOriginal), [true, true, false, false])
        XCTAssertEqual(over.degradedSlots, [2, 3])
        XCTAssertLessThanOrEqual(over.totalBytes, limits.maxTotalBytes)
    }

    // MARK: - IMG-BUD-03 预览优先、原图按选择顺序

    func testPreviewsAlwaysFitAndLaterSmallOriginalsDoNotJumpTheQueue() {
        var items = (0..<7).map { image(slot: $0, preview: 512 * 1024, original: 8 * 1024 * 1024) }
        items.append(image(slot: 7, preview: 512 * 1024, original: 1))   // 极小，但排最后
        let plan = FeedbackAttachmentAllocation.plan(items, limits: limits)

        XCTAssertEqual(plan.items.count, 8)
        XCTAssertTrue(plan.items.allSatisfy { $0.primary.byteSize == 512 * 1024 },
                      "预览全保留（8 × 512 KiB 永远放得下）")
        XCTAssertEqual(plan.items.map(\.includeOriginal),
                       [true, true, false, false, false, false, false, false])
        XCTAssertEqual(plan.degradedSlots, [2, 3, 4, 5, 6, 7],
                       "后面的 1 字节原图也不许插到前面的大原图之前")
    }

    // MARK: - IMG-BUD-04 只有预览的降级

    func testBudgetThatFitsOneOriginalLeavesTheOthersPreviewOnly() {
        let items = [image(slot: 0, preview: 100 * 1024, original: 8 * 1024 * 1024),
                     image(slot: 1, preview: 100 * 1024, original: 8 * 1024 * 1024),
                     image(slot: 2, preview: 100 * 1024, original: 8 * 1024 * 1024)]
        let tight = FeedbackAttachmentLimits(maxPerMessage: 8, maxFileBytes: 8 * 1024 * 1024,
                                             maxTotalBytes: 9 * 1024 * 1024,
                                             types: ["jpeg"], roles: ["original", "preview"])
        let plan = FeedbackAttachmentAllocation.plan(items, limits: tight)
        XCTAssertEqual(plan.items.map(\.includeOriginal), [true, false, false])
        XCTAssertEqual(plan.degradedCount, 2)
        XCTAssertTrue(plan.items.allSatisfy { $0.primary.byteSize == 100 * 1024 },
                      "降级的附件仍然带着预览")
    }

    // MARK: - 文件不参与原图分配

    func testDocumentsNeverTakeAnOriginalSlot() {
        let items = [document(slot: 0, size: 4096),
                     image(slot: 1, preview: 100 * 1024, original: 8 * 1024 * 1024)]
        let tight = FeedbackAttachmentLimits(maxPerMessage: 8, maxFileBytes: 8 * 1024 * 1024,
                                             maxTotalBytes: 9 * 1024 * 1024,
                                             types: ["jpeg", "pdf"], roles: ["original", "preview"])
        let plan = FeedbackAttachmentAllocation.plan(items, limits: tight)
        XCTAssertEqual(plan.items.map(\.includeOriginal), [false, true])
        XCTAssertEqual(plan.degradedCount, 0, "文件本来就没有原图，不算降级")
    }

    // MARK: - IMG-BUD-05 汇总文案

    func testTheSummaryReadsThePlanFields() {
        // 2 个含高清、1 个仅预览（它本来有原图，额度不够被降级）。
        let tight = FeedbackAttachmentLimits(maxPerMessage: 8, maxFileBytes: 8 * 1024 * 1024,
                                             maxTotalBytes: 12 * 1024 * 1024,
                                             types: ["jpeg"], roles: ["original", "preview"])
        let items = [image(slot: 0, preview: 100 * 1024, original: 5 * 1024 * 1024),
                     image(slot: 1, preview: 100 * 1024, original: 5 * 1024 * 1024),
                     image(slot: 2, preview: 100 * 1024, original: 8 * 1024 * 1024)]
        let plan = FeedbackAttachmentAllocation.plan(items, limits: tight)
        let summary = FeedbackAttachmentSummary(plan: plan)

        XCTAssertEqual(summary.attachmentCount, 3)
        XCTAssertEqual(summary.highDefinitionCount, 2)
        XCTAssertEqual(summary.previewOnlyCount, 1)
        XCTAssertEqual(summary.totalBytes, plan.totalBytes)
        XCTAssertEqual(plan.degradedSlots, [2])
        let text = summary.text
        XCTAssertTrue(text.contains("3 \u{4E2A}\u{9644}\u{4EF6}"), text)          // 3 个附件
        XCTAssertTrue(text.contains("\u{542B}\u{9AD8}\u{6E05} 2"), text)          // 含高清 2
        XCTAssertTrue(text.contains("\u{4EC5}\u{9884}\u{89C8} 1"), text)          // 仅预览 1
        let expected = String(format: "%.1f", Double(plan.totalBytes) / (1024 * 1024))
        XCTAssertTrue(text.contains("\(expected) MiB"), "文案里的合计来自 plan 的字节数：\(text)")
    }
}

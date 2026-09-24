import Testing

@testable import DSHKit

/// These numbers are the real boundary arithmetic from two sessions measured on
/// 2026-09-24: one where the host's offset↔seq bias is 1 (pages abut) and one
/// where it is 236 (the page silently skipped 235 seqs).
@Suite("Transcript page boundary")
struct TranscriptPageBoundaryTests {

    @Test("a contiguous page needs no correction")
    func denseLogIsLeftAlone() {
        // 请求 12676 拿到 12381..12675：正好接到 12676 之前，不需要重问
        #expect(TranscriptPageBoundary.corrected(requested: 12_676, returnedLast: 12_675, wanted: 12_676) == nil)
        // 稠密会话里偏差恒为 1
        #expect(TranscriptPageBoundary.corrected(requested: 12_968, returnedLast: 12_967, wanted: 12_968) == nil)
    }

    @Test("a short page is re-requested by exactly the shortfall")
    func gappedPageIsCorrected() {
        // 21_X 实测：请求 12616，回来只到 12380 —— 缺 235 个 seq
        let next = TranscriptPageBoundary.corrected(requested: 12_616, returnedLast: 12_380, wanted: 12_616)
        #expect(next == 12_616 + 235)
        // 校正量正好等于缺口：拿它重问，边界就落在读者等着的那条 seq（12615）上
        #expect(next! - 12_616 == (12_616 - 1) - 12_380)
    }

    @Test("a page that overshoots is accepted as-is")
    func overshootIsFine() {
        // 回来的比要的还新（重叠）没关系：重复行由时间线按 id 去掉
        #expect(TranscriptPageBoundary.corrected(requested: 1_000, returnedLast: 1_050, wanted: 1_000) == nil)
    }

    @Test("a stuck boundary does not loop forever")
    func stuckBoundaryStops() {
        // host 顶住不动（校正后没有前进）→ 返回 nil，由调用方停止提供更早的历史
        #expect(TranscriptPageBoundary.corrected(requested: 500, returnedLast: 400, wanted: 400) == nil)
        #expect(TranscriptPageBoundary.corrected(requested: 0, returnedLast: 0, wanted: 0) == nil)
    }

    @Test("hole detection matches the boundary rule")
    func holeDetection() {
        #expect(TranscriptPageBoundary.hasHole(newest: 12_380, oldest: 12_616))
        #expect(TranscriptPageBoundary.hasHole(newest: 12_615, oldest: 12_616) == false)
        #expect(TranscriptPageBoundary.hasHole(newest: 12_616, oldest: 12_616) == false)
        #expect(TranscriptPageBoundary.maxAttempts >= 2)
    }
}

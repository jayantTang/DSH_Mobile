import Testing

@testable import DSHKit

/// The plan decides whether an open *merges* a cached tail with the host's
/// snapshot or *re-bases* on it. Getting this wrong is how a transcript ends up
/// with a hole in the middle that no amount of scrolling can fill, so the cases
/// worth pinning are exactly the boundaries: fresh, slightly behind, far behind,
/// and "the local tail is ahead of the host".
@Suite("Transcript sync plan")
struct TranscriptSyncPlanTests {

    @Test("no local tail: a screenful, and nothing to merge with")
    func coldStart() {
        let plan = TranscriptSyncPlan.plan(localThrough: nil, hostCursor: 5_000)
        #expect(plan.maxMessages == TranscriptSyncPlan.minWindow)
        #expect(plan.reBase)
    }

    @Test("a fresh tail asks for the floor, and merges")
    func freshTail() {
        let plan = TranscriptSyncPlan.plan(localThrough: 4_990, hostCursor: 5_000)
        #expect(plan.maxMessages == TranscriptSyncPlan.minWindow)
        #expect(plan.reBase == false)
    }

    @Test("a moderate gap widens the window by exactly the gap plus margin")
    func moderateGap() {
        let plan = TranscriptSyncPlan.plan(localThrough: 4_900, hostCursor: 5_000)
        #expect(plan.maxMessages == 110)
        #expect(plan.reBase == false)
        // 窗口必须覆盖缺口：gap=100 时至少要 100 条才可能连续
        #expect(plan.maxMessages > 100)
    }

    @Test("a large gap asks for the whole window and lets the snapshot decide")
    func largeGapUsesTheWholeWindow() {
        let plan = TranscriptSyncPlan.plan(localThrough: 4_000, hostCursor: 5_000)
        #expect(plan.maxMessages == TranscriptSyncPlan.maxWindow)
        // 估算接不上不等于真接不上：是否重来由快照实际的第一条决定
        #expect(plan.reBase == false)
        #expect(TranscriptSyncPlan.stillNeedsReBase(localLastSeq: 4_000, snapshotFirstSeq: 4_500))
        #expect(TranscriptSyncPlan.stillNeedsReBase(localLastSeq: 4_000, snapshotFirstSeq: 3_900) == false)
    }

    @Test("a local tail ahead of the host is not trusted")
    func localAheadReBases() {
        // host 被压缩/回滚：本地游标比 host 还大，两边不是同一份日志了
        let plan = TranscriptSyncPlan.plan(localThrough: 5_100, hostCursor: 5_000)
        #expect(plan.reBase)
        #expect(plan.maxMessages == TranscriptSyncPlan.minWindow)
    }

    @Test("a snapshot that falls short still forces a re-base")
    func shortSnapshotStillReBases() {
        // 理论算得再准也要看实际回来的第一条：本地到 1000、快照从 1411 开始 = 中间有洞
        #expect(TranscriptSyncPlan.stillNeedsReBase(localLastSeq: 1_000, snapshotFirstSeq: 1_411))
        // 首尾相接（甚至重叠）就不必重来
        #expect(TranscriptSyncPlan.stillNeedsReBase(localLastSeq: 1_000, snapshotFirstSeq: 1_001) == false)
        #expect(TranscriptSyncPlan.stillNeedsReBase(localLastSeq: 1_000, snapshotFirstSeq: 900) == false)
        // 没有本地尾部就没有"洞"可言
        #expect(TranscriptSyncPlan.stillNeedsReBase(localLastSeq: nil, snapshotFirstSeq: 1_411) == false)
    }
}

import DSHKit
import XCTest

/// 用例 57 的复现单测：回收与水合各用各的尺子，导致
/// 「水合回来 → 又被同一轮回收判定抽走」的乒乓，以及可见带退化时
/// 「把正在读的 135 行一次回收」的灾难（2026-10-11 run 20261011-083732）。
///
/// 修复口径：回收与水合共用同一把「行数带」尺子（水合带严格小于回收保护带），
/// 回收保护带再并上布局点带；可见带量不出来时一律不回收。
final class ViewportBandPlannerTests: XCTestCase {

    /// 水合带（2 屏）必须严格落在回收保护带（5 屏）里——否则水合回来的行
    /// 下一次滚动就被回收，形成乒乓。
    func testRehydrateBandStaysInsideReclaimProtection() {
        let cases: [(rows: Int, lower: Int, upper: Int)] = [
            (1000, 0, 10),      // 贴在开头
            (1000, 495, 510),   // 中段
            (1000, 985, 1000),  // 贴在结尾
            (40, 5, 20),        // 小列表
            (1000, 500, 501),   // 可见带退化成 1 行
        ]
        for (rowCount, lower, upper) in cases {
            let visible = lower..<upper
            let rehydrate = ViewportBandPlanner.indexBand(visible: visible, rowCount: rowCount, screens: TranscriptWindowPlanner.Distances.rehydrateScreens)
            let protect = ViewportBandPlanner.indexBand(visible: visible, rowCount: rowCount, screens: TranscriptWindowPlanner.Distances.reclaimScreens)
            XCTAssertTrue(protect.clamped(to: 0..<rowCount).contains(rehydrate.lowerBound),
                          "visible=\(visible) 时水合带 \(rehydrate) 超出保护带 \(protect)")
            XCTAssertTrue(protect.contains(rehydrate.upperBound - 1),
                          "visible=\(visible) 时水合带 \(rehydrate) 超出保护带 \(protect)")
        }
    }

    /// 乒乓回归：模拟「水合一批行 → 紧接着做回收判定」，刚水合的行一个都不许被回收。
    func testFreshlyRehydratedRowsAreNeverReclaimedInTheSameBand() {
        let rowCount = 1000
        let visible = 490..<503
        var reclaimed = Set(0..<rowCount)   // 全部已回收（长会话翻到中段）
        // 水合：把 2 屏行数带里的行要回来。
        let rehydrateBand = ViewportBandPlanner.indexBand(visible: visible, rowCount: rowCount, screens: TranscriptWindowPlanner.Distances.rehydrateScreens)
        let hydrated = rehydrateBand.filter { reclaimed.contains($0) }
        XCTAssertFalse(hydrated.isEmpty)
        reclaimed.subtract(hydrated)
        // 回收判定（同一轮 scroll 之后 400ms 的那次）：刚水合的行必须全在保护带里。
        let victims = ViewportBandPlanner.reclaimCandidates(
            rowCount: rowCount,
            visible: visible,
            pointProtected: [],
            screens: TranscriptWindowPlanner.Distances.reclaimScreens,
            isReclaimable: { !reclaimed.contains($0) }
        )
        XCTAssertTrue(Set(victims).isDisjoint(with: hydrated),
                      "刚水合的行又被回收：\(Set(victims).intersection(hydrated))")
    }

    /// 可见带量不出来（布局剧烈变动期）：一行都不许回收。
    /// （用例 57 实测 `visible=2` 的退化带把 135 行——含正在读的尾段——一次抽走。）
    func testDegenerateVisibleRangeReclaimsNothing() {
        let victims = ViewportBandPlanner.reclaimCandidates(
            rowCount: 999,
            visible: 0..<0,
            pointProtected: [],
            screens: TranscriptWindowPlanner.Distances.reclaimScreens,
            isReclaimable: { _ in true }
        )
        XCTAssertEqual(victims, [])
    }

    /// 点带（布局坐标里视口 ±N 屏）命中的下标必须受保护：行高悬殊时
    /// 「5 屏」在点数上比行数换算更准，两种口径取并集，谁也不拆谁的台。
    func testPointBandProtectionIsHonored() {
        let rowCount = 200
        let visible = 100..<110
        // 布局点带说 120..<160 这段也在 5 屏内（这一段行特别矮）。
        let pointProtected = Set(120..<160)
        let victims = ViewportBandPlanner.reclaimCandidates(
            rowCount: rowCount,
            visible: visible,
            pointProtected: pointProtected,
            screens: TranscriptWindowPlanner.Distances.reclaimScreens,
            isReclaimable: { _ in true }
        )
        XCTAssertTrue(Set(victims).isDisjoint(with: pointProtected),
                      "点带保护的行被回收了")
        // 行数带（5×10=50 行 ⇒ 50..<160）本身就盖住 120..<160，远端照收。
        XCTAssertTrue(victims.contains(0), "最老端离视口远超 5 屏，该收")
        XCTAssertTrue(victims.contains(199), "最新端离视口远超 5 屏时也该收")
    }

    /// 可见行数为 0 或极小时换算保底：perScreen 至少是 4，退化带不会把
    /// 「5 屏」折算成「贴着眼皮」。
    func testRowsPerScreenHasAFloor() {
        XCTAssertEqual(ViewportBandPlanner.rowsPerScreen(visibleCount: 0), 4)
        XCTAssertEqual(ViewportBandPlanner.rowsPerScreen(visibleCount: 2), 4)
        XCTAssertEqual(ViewportBandPlanner.rowsPerScreen(visibleCount: 13), 13)
    }

    /// 水合候选只数带内已回收的行。
    func testRehydrateCandidatesAreReclaimedRowsInsideTheBand() {
        let visible = 10..<15
        let reclaimed: Set<Int> = [0, 8, 20, 60]
        let seqs = ViewportBandPlanner.rehydrateCandidates(
            rowCount: 100,
            visible: visible,
            screens: 2,
            isReclaimed: { reclaimed.contains($0) }
        )
        // 2 屏 × max(5,4)=10 行 ⇒ 带是 0..<25；命中的有 0、8、20，60 在带外。
        XCTAssertEqual(seqs, [0, 8, 20])
    }
}

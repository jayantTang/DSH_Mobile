import Foundation

/// 「离视口几屏」的统一换算（值见 `TranscriptWindowPlanner.Distances`：5 屏回收 / 4 屏水合）。
///
/// 修复前回收与水合各用各的尺子：回收按布局点带（`layoutAttributes` 求交），
/// 水合按下标带（可见行数折算）。行高悬殊时两把尺子量出来的不是同一段——
/// 水合刚要回来的行落在回收点带之外，下一次滚动又被抽走，形成
/// 「回收 → 水合 → 又回收」的乒乓（用例 57，run 20261011-083732 的
/// `list.reclaim` / `list.rehydrate` 交替刷屏）；可见带退化（`visible=2`）时
/// 回收点带跟着错位，一次把正在读的 135 行全部抽走（`bytes=0 rows=135`）。
///
/// 口径：回收与水合共用同一把**行数带**尺子（水合带严格小于回收保护带，
/// 乒乓在构造上不可能）；回收保护带再并上布局点带命中的下标（行高悬殊时
/// 点数口径更准，谁也不拆谁的台）；可见带量不出来时一律不回收。
public enum ViewportBandPlanner {

    /// 1 屏≈几行：按可见行数估，保底 4——可见带退化时不至于把「5 屏」
    /// 折算成「贴着眼皮」，把整列判成远处。
    public static func rowsPerScreen(visibleCount: Int) -> Int { max(visibleCount, 4) }

    /// 「可见带 ± screens 屏」的行下标窗口。可见带为空返回空窗口（调用方据此收手）。
    public static func indexBand(visible: Range<Int>, rowCount: Int, screens: Int) -> Range<Int> {
        guard !visible.isEmpty, rowCount > 0 else { return 0..<0 }
        let span = screens * rowsPerScreen(visibleCount: visible.count)
        let lower = max(0, visible.lowerBound - span)
        let upper = min(rowCount, visible.upperBound + span)
        return lower..<upper
    }

    /// 回收候选：不在保护带（行数带 ∪ 布局点带）内、且调用方判定可收的行下标。
    ///
    /// - Parameters:
    ///   - visible: 视口内行的下标区间（空 = 布局量不出来，本轮不回收）。
    ///   - pointProtected: 布局点带（视口 ± screens 屏）命中的下标。
    ///   - isReclaimable: 调用方过滤（已回收的、缺口行等不收）。
    public static func reclaimCandidates(
        rowCount: Int,
        visible: Range<Int>,
        pointProtected: Set<Int>,
        screens: Int,
        isReclaimable: (Int) -> Bool
    ) -> [Int] {
        guard !visible.isEmpty, rowCount > 0 else { return [] }
        let band = indexBand(visible: visible, rowCount: rowCount, screens: screens)
        var picked: [Int] = []
        picked.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            if band.contains(index) || pointProtected.contains(index) { continue }
            if isReclaimable(index) { picked.append(index) }
        }
        return picked
    }

    /// 水合候选：行数带（screens 屏）内已回收的行下标。水合带严格小于
    /// 回收保护带，要回来的行不会在下一轮又被回收。
    public static func rehydrateCandidates(
        rowCount: Int,
        visible: Range<Int>,
        screens: Int,
        isReclaimed: (Int) -> Bool
    ) -> [Int] {
        let band = indexBand(visible: visible, rowCount: rowCount, screens: screens)
        guard !band.isEmpty else { return [] }
        return band.filter { isReclaimed($0) }
    }
}

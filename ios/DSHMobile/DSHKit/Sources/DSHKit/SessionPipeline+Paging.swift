import Foundation

/// 页对齐工具（从 SessionPipeline 主文件拆出：主文件逼近 500 行上限）。
/// 页大小对齐的取页边界（spec 009 §6）与淘汰锚点的计算都收在这里。
extension SessionPipeline {

    /// 覆盖某缺口的对齐页集合（页大小对齐，spec §6 页边界）。
    ///
    /// 入口做**异常游标防御**（2026-10-13 崩溃回归）。seq 有两个外部来源：host 的
    /// `asOfSeq`，以及本地磁盘的聚合列 `newest_seq`。原来这两处来一个离谱值就会在
    /// 本函数里炸：`start + pageSize - 1` 整数溢出是 SIGTRAP，不是可捕获的错误
    ///（TestFlight 20261012.1310 就是磁盘聚合列被 pending 行的合成 seq 抬到
    /// `Int.max`，冷启动预取照它算页边界）。判据只有一份：终点超出 `seqCeiling` 的游标
    /// 不产页，请求自然退化为空结果（预取静默、读者路径照常回退），不崩、不发网络。
    /// 下界不管：`alignedStart` 本来就把 0/负数钳到第 1 页，保持原语义不变。
    func alignedPages(covering span: RangeIndex.Span) -> [ClosedRange<Int>] {
        guard pageSize > 0, span.end >= 1, span.start <= span.end,
              span.end <= Self.seqCeiling
        else { return [] }
        var pages: [ClosedRange<Int>] = []
        var start = alignedStart(for: span.start)
        // 页数封顶：`seqCeiling` 之内的区间理论上仍可以是两千万页（1e9 / 50），
        // 一次请求也不该无限扩。真实请求最宽的是回看（pagesPerFetch=2 页）与跳转（1 页），
        // 512 页是它们的两个数量级以上的余量。
        while start <= span.end, pages.count < Self.maxPagesPerRequest {
            guard let page = pageRange(startingAt: start) else { break }
            pages.append(page)
            let (next, overflow) = start.addingReportingOverflow(pageSize)
            guard !overflow else { break }
            start = next
        }
        return pages
    }

    /// 含某 seq 的那一页；游标离谱（超出 `seqCeiling`）或页上沿溢出时返回 nil。
    /// 预取方拿到 nil 即跳过这一页，不构造非法区间。0/负数照旧钳到第 1 页。
    func alignedPage(containing seq: Int) -> ClosedRange<Int>? {
        guard pageSize > 0, seq <= Self.seqCeiling else { return nil }
        return pageRange(startingAt: alignedStart(for: seq))
    }

    /// 从对齐起点起的一页；上沿溢出 `Int` 时返回 nil（不 trap）。
    private func pageRange(startingAt start: Int) -> ClosedRange<Int>? {
        let (end, overflow) = start.addingReportingOverflow(pageSize - 1)
        guard !overflow, end >= start else { return nil }
        return start...end
    }

    func alignedStart(for seq: Int) -> Int {
        max(1, ((max(1, seq) - 1) / pageSize) * pageSize + 1)
    }

    /// 淘汰锚点：请求区间的中点。回看水合时淘汰离锚点更远的一端，
    /// 避免把读者正在看的段抽走（T026：水合→淘汰→空白带的死循环）。
    static func anchor(of range: ClosedRange<Int>) -> Int {
        (range.lowerBound + range.upperBound) / 2
    }

    /// 服务端是否**明确说**这页到头了（spec 可见性兜底 / T038「空页即异常」）：
    /// 只有拉的是最底页（对齐起点 1）且 `hasMore == false` 或被日志裁剪（clamped）
    /// 才算「已到最早」。空回包 + 这个判定 = 正常终态（置 topExhausted）；
    /// 空回包 + 判定不成立 = 可重试失败（见 SessionPipeline.fetchPage）。
    /// 网络失败永远不得当作到底。
    static func reachedEnd(_ page: FetchPage, requested: ClosedRange<Int>) -> Bool {
        requested.lowerBound == 1 && (page.hasMore == false || page.clamped)
    }

    // MARK: - 空回包的方向判据（T038 / adeb3aa）

    /// 「往更新方向探空」的判据（**唯一一份**）：请求区间整体在热窗口最新 seq 之上。
    ///
    /// 管道用它决定空回包算不算失败；App 侧的空回包注入（`-DSHProbeEmptyPage`，
    /// 设备层验「更早方向拉空 = 失败」）也用它决定该不该打在这一次请求上——
    /// 两处必须同口径，否则注入会打在正常形态上，验到的东西就不是要看的那一条。
    /// 热窗口还没建立（冷启动首拉就是最新页）时恒为 false：那不是"探"。
    public static func isNewerDirectionProbe(pageLowerBound: Int, hotNewest: Int?) -> Bool {
        guard let hotNewest else { return false }
        return pageLowerBound > hotNewest
    }

    /// 热窗口最新 seq（nil = 这个会话还没有窗口）：App 侧注入判方向要读。
    var hotNewestSeq: Int? { hotWindow.keys.max() }

    // MARK: - gap 行派生（从主文件拆出，同一 500 行上限）

    /// 缺口行由区间集派生（spec「缺口行的生命周期」）：窗口 = 最老…最新。
    /// 已加载区间内仍未补上的空洞。`oldest` 到 1 只说明没有更早的号，
    /// 不代表中间没有缺口；调用方要据此决定"补洞"还是"到头"。
    public func uncoveredSpans() -> [ClosedRange<Int>] {
        currentGaps().map { $0.start...$0.end }
    }

    func currentGaps() -> [GapRow] {
        guard let oldest = ranges.oldest, let newest = ranges.newest, oldest <= newest else { return [] }
        // 已问过的区间也参与"覆盖"判定：空号是已知无内容，不是待加载的缺口。
        var covered = ranges
        for span in asked.spans { covered.insert(span.start...span.end) }
        for span in knownEmptyRanges().spans { covered.insert(span.start...span.end) }
        return covered.gaps(within: oldest...newest).map { span in
            GapRow(start: span.start, end: span.end, status: gapStatus(for: span))
        }
    }

    private func gapStatus(for span: RangeIndex.Span) -> GapRow.Status {
        // 该缺口覆盖的对齐页里有到 3 次失败的 → retryable。
        let firstPage = alignedPages(covering: span).first
        if let key = firstPage?.lowerBound, failureCounts[key, default: 0] >= Self.maxRetries {
            return .failed(retryable: true)
        }
        return .loading
    }

    /// 丢弃一段不打算自动补的缺口（T026 修复 US3 遗留：>5 页降级直跳
    /// 最新页后，中间缺口没有在任何在飞拉取里，停在 .loading 永远转圈）。
    /// 置为可重试失败态：用户点它走 `retry(range:)` 才真拉，符合
    /// 「丢弃中间段」的省流量语义（spec 场景 7）。只标 covering 页的
    /// 失败计数，不发网络；区间集不变（缺口仍在，只是状态变了）。
    public func abandonGap(_ range: ClosedRange<Int>) {
        guard range.lowerBound <= range.upperBound else { return }
        for page in alignedPages(covering: RangeIndex.Span(range.lowerBound, range.upperBound)) {
            failureCounts[page.lowerBound] = Self.maxRetries
        }
        emit(Diff(gaps: currentGaps()))
    }
}

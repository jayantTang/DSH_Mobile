import DSHKit
import Foundation

extension ChatModel {

    /// 搜索一页：能力在就问宿主要整个会话，否则退回本地（FR-010/FR-015）。
    ///
    /// 命中可能落在**还没加载**的位置：先把那一段上下文从本地库读回来（不联网），
    /// 再做 `seq → 行` 的映射，否则命中会因为"没有行可指"被丢掉（FR-011）。
    public func searchPage(query: String, onlyMine: Bool, cursor: String? = nil,
                    limit: Int = 50) async -> SearchPage? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空关键词只允许"浏览我的提问"这一种用法（连接器侧同样要求带 roles，
        // 否则一次无范围的全表扫描没有意义）。spec 008 的真机反馈修复。
        guard !needle.isEmpty || onlyMine, let client = store?.chatHost, let address else { return nil }
        let service = TranscriptSearchService(client: client, address: address,
                                              capabilities: effectiveCapabilities)
        switch service.source {
        case .connector:
            let value: HistorySearchValue
            do {
                value = try await service.page(query: needle, onlyMine: onlyMine,
                                               cursor: cursor, limit: limit)
            } catch {
                // 拒绝 ≠ 没有结果（FR-013）：留一条原因给界面，别退化成"命中 0 条"。
                searchRefusalReason = (error as? TranscriptSearchService.Failure)?.description
                    ?? String(describing: error)
                return nil
            }
            searchRefusalReason = nil
            await loadContextForHits(value.hits)
            return SearchPage(hits: TranscriptHitLocator.attach(hits: value.hits, to: timeline.items),
                              cursor: value.cursor, hasMore: value.hasMore, scope: "connector",
                              progress: Self.progress(of: value))
        case .local:
            searchRefusalReason = nil
            let local = TranscriptSearch.hits(in: searchItems, query: needle, onlyMine: onlyMine)
            return SearchPage(hits: local, cursor: nil, hasMore: false, scope: "local",
                              progress: nil)
        }
    }

    /// 把连接器回报的片数换算成"已扫 / 共多少"。
    ///
    /// 缺字段（走索引的部署、或支持 `search-progress` 之前的连接器）就是 nil：界面宁可说
    /// "进度未知"，也不能拿 0 当"第一片"——那会让"已扫 0/N"看起来像没扫。
    static func progress(of value: HistorySearchValue) -> SearchPage.SearchProgress? {
        guard let total = value.totalChunks, total > 0,
              let remaining = value.remainingChunks else { return nil }
        // 夹在 [0, total]：连接器已经夹过一次，这里再兜一层——旧连接器给的越界数字
        // 不该让界面显示"已扫 996/2 片"。
        let scanned = min(total, max(0, total - max(0, remaining)))
        return SearchPage.SearchProgress(scannedChunks: scanned, totalChunks: total)
    }
    /// 往前取一页进**搜索缓冲**（时间线不动）。
    @discardableResult
    public func extendSearchHistory() async -> Bool {
        guard let from = searchOldestSeq ?? oldestSeq, from > 1 else { return false }
        guard !isExtendingSearch,
              let fetcher = makePageFetcher(pageSize: PageSize.searchBuffer) else { return false }
        isExtendingSearch = true
        defer { isExtendingSearch = false }
        // 先看本地：搜索缓冲要的是"更早的一段"，本地库通常就有（还能省一次往返）。
        if let scope = sessionScope, let sessionId = session?.sessionId,
           let store = messageBacking,
           let local = try? await store.windowBefore(
               scope: scope, sessionId: sessionId, seq: from,
               limit: Self.localSearchReadLimit) {
            let fresh = local.filter { $0.event.seq < from }
            if !fresh.isEmpty {
                searchRecords.insert(contentsOf: fresh, at: 0)
                searchOldestSeq = fresh.first?.event.seq
                searchScopeVersion += 1
                persistSearchHistory()
                ChatProbe.shared.probeNote?("search.extended", [
                    "from": String(from), "records": String(fresh.count),
                    "source": "disk", "searchOldest": String(searchOldestSeq ?? -1),
                ], true)
                return true
            }
        }
        // 本地没有才问宿主。取不到就是取不到：不写任何"没有更早了"的状态，读者可以再试（FR-003）。
        guard let page = try? await fetcher.page(before: from) else {
            setOlderState(.failed(String(localized: "读取更早的记录失败，点按重试")))
            return false
        }
        let fresh = page.records.filter { $0.event.seq < from }
        guard !fresh.isEmpty else { return false }
        searchRecords.insert(contentsOf: fresh, at: 0)
        searchOldestSeq = fresh.first?.event.seq
        searchScopeVersion += 1
        persistSearchHistory()
        ChatProbe.shared.probeNote?("search.extended", [
            "from": String(from),
            "records": String(fresh.count),
            "searchOldest": String(searchOldestSeq ?? -1),
            "hostHasMore": page.hasMore ? "1" : "0",
        ], true)
        return true
    }

    /// 把搜索缓冲并进时间线（读者点了缓冲里的某一条时才做）。
    ///
    /// 只并"比时间线最老那条还老"的记录；并完清空缓冲，视图那边会跟着跳转。
    @discardableResult
    public func commitSearchHistory() -> Bool {
        guard !searchRecords.isEmpty, let oldest = oldestSeq else { return false }
        let fresh = searchRecords.filter { $0.event.seq < oldest }
        searchRecords.removeAll()
        searchOldestSeq = nil
        cachedSearchItems = nil
        searchScopeVersion += 1
        guard !fresh.isEmpty else { return false }
        let change = timeline.prepend(older: fresh)
        if case .none = change { return false }
        prependSignal += 1
        ChatProbe.shared.probeNote?("search.committed", [
            "records": String(fresh.count),
            "oldest": String(oldestSeq ?? -1),
        ], true)
        return true
    }
    /// 跳到一条很久以前的命中：把时间线的**窗口整个换掉**（spec 007 FR-011）。
    ///
    /// 为什么必须是"换窗口"而不是"插一段"：时间线是连续的，命中在 seq 1685、而窗口从 2206 起，
    /// 中间隔着几百条——插段等于把整段都读进内存，既慢又推翻"按预算装一窗"的设计。
    /// 换窗口之后，更早的一端由管道继续补，更晚的一端读者往下滑也能回来。
    ///
    /// 只从**本地库**读（0 网络）；库里没有这一段就返回 nil，界面保持原地并留一条诊断。
    public func rebaseWindow(around seq: Int, leading: Int = 20, limit: Int = 80) async -> String? {
        // 跳转/换窗口强制置为「阅读中」（spec 009 场景 9：不重置会被下一条增量拽回底部）。
        noteJumpToReading()
        // T013：跳转 = 管道的 .jump（抢占在途低优预取，只拉目标对齐页）。
        if let bridge = pipelineBridge {
            // 先问**本机库**：命中往往就是从它里面搜出来的（「只看我的提问」读的就是
            // `record` 表），这时换窗口完全不必联网——`absorb` 并进管道就够，几百毫秒
            // 内梯子就能解析到行。库里那一段不含目标（命中在更远处）才让管道走网络。
            if await hydrateLocally(around: seq, leading: leading, limit: limit) { return nil }
            return await bridge.rebase(around: seq, leading: leading, limit: limit)
        }
        guard let sessionId = session?.sessionId, let scope = sessionScope else { return nil }
        let before = max(0, seq + leading)
        var records = (try? await messageBacking?.windowBefore(
            scope: scope, sessionId: sessionId, seq: before, limit: limit)) ?? []
        var source = "disk"
        if records.isEmpty, let fetcher = makePageFetcher(pageSize: limit),
           let page = try? await fetcher.page(before: before) {
            // 本地没有（比如刚装上、或者这段从来没读过）：跟连接器要一窗，顺手落盘，
            // 下次同一个位置就不用再联网（FR-011 的"跳过去"必须在冷启动后也能成）。
            records = page.records
            source = "host"
            if !records.isEmpty {
                enqueueAppend(scope: scope, sessionId: sessionId, records: records)
            }
        }
        guard !records.isEmpty else {
            ChatProbe.shared.probeNote?("search.rebase", ["seq": String(seq), "records": "0"], true)
            return nil
        }
        // 换窗口打开的是中间窗口：末段不是会话尾部（不许标 running、不许出占位行），
        // 但"这一轮到底结没结束"这个事实原样带过来（设计 M1 调用点表）。
        timeline.reset(with: records, seeding: timeline.tail.boundary,
                       showsTail: false)
        prependSignal += 1
        let oldest = records.first?.event.seq
        let newest = records.last?.event.seq
        hasOlder = (oldest ?? 1) > 1
        setOlderState(.idle)
        let landed = TranscriptHitLocator.row(forSeq: seq, in: timeline.items)?.id
        ChatProbe.shared.probeNote?("search.rebase", [
            "seq": String(seq), "records": String(records.count), "source": source,
            "oldest": String(oldest ?? -1), "newest": String(newest ?? -1),
            "landed": landed ?? "-",
        ], true)
        return landed
    }

    /// 换窗口前先问本机库（0 网络）：把目标附近一段读回来并并进管道。
    ///
    /// 返回 true = 这一段**含目标本身**，等这次 refold 落地就够（梯子按 seq 逐枪解析），
    /// 不必联网；false = 库里没有目标（命中在更远处 / 这段从没读过），交给管道走网络。
    ///
    /// 为什么值得这一步：`pipelineActive` 之后换窗口只有"跟连接器要一窗"一条路，
    /// 而「只看我的提问」的命中就是从本机 `record` 表搜出来的——目标记录明明在手上，
    /// 却要等一次网络往返（用例 44 run 20261011-211620：点下去到断言之间只有 2 秒，
    /// 联网那一枪还没回来）。
    func hydrateLocally(around seq: Int, leading: Int, limit: Int) async -> Bool {
        guard let sessionId = session?.sessionId, let scope = sessionScope,
              let store = messageBacking, let bridge = pipelineBridge else { return false }
        let before = max(0, seq + leading + 1)
        let records = (try? await store.windowBefore(
            scope: scope, sessionId: sessionId, seq: before, limit: limit)) ?? []
        guard !records.isEmpty else { return false }
        // 目标上面还有一段（`leading` 行）才有滚动余量；顺序按 seq 升序给管道。
        await bridge.absorb(records: records.sorted { $0.event.seq < $1.event.seq })
        let covers = records.contains { $0.event.seq == seq }
        ChatProbe.shared.probeNote?("search.rebase.local", [
            "seq": String(seq), "records": String(records.count), "covers": covers ? "1" : "0",
            "oldest": String(records.first?.event.seq ?? -1),
            "newest": String(records.last?.event.seq ?? -1),
        ], true)
        return covers
    }

    /// 按行载荷预算算出"最老端该丢几行"（spec 008 的 FR-004a）。
    ///
    /// **策略已经搬到 DSHKit**（`TranscriptWindowPlanner.rowsToDrop`，spec 023 的 S1）：
    /// 保留带怎么算、够了在哪停、等于预算算不算超，全部由那边决定，这里只做两件事——
    /// 把当前窗口折成逐行字节数，以及把预算交进去。预算本身仍是 App 的旋钮：
    /// DEBUG 探针 `-DSHProbePayloadBudgetKB` 要把真实会话的 32MB 压小，否则这条路在用例里
    /// 永远看不到。
    ///
    /// 返回 0 表示没超预算，不该丢。
    public func rowsToDropForBudget(keepLast: Int? = nil) -> Int {
        // 逐行折一次就够：搬迁前是把 `TranscriptRowPayload(item:)` 折两遍（先求和、再逐行扣），
        // 现在只折一遍，行为不变、少一倍的载荷折算。
        let sizes = timeline.items.map { TranscriptRowPayload(item: $0).payloadBytes }
        return TranscriptWindowPlanner.rowsToDrop(
            payloadBytes: sizes,
            under: TranscriptPayloadBudget(limitBytes: Self.payloadBudgetBytes),
            keepLast: keepLast
        )
    }

    /// 丢掉最老端 `count` 行（宿主那边会用同一批 id 做原子丢弃）。
    @discardableResult
    public func dropOldestRows(_ count: Int) -> Int {
        let dropped = timeline.dropOldestRows(count)
        // 管道模式：桥里的记录也要同步丢到同一界线，否则下一次 diff 重建
        // 会把刚丢的行原样补回来，预算裁剪被架空（008 FR-002）。
        if dropped > 0, let bridge = pipelineBridge,
           let newFirst = timeline.items.first(where: { item in
               if case .gap = item.kind { return false }
               return true
           })?.seq {
            bridge.dropRecords(below: newFirst)
        }
        return dropped
    }
}

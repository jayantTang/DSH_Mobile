#if os(iOS)
import DSHKit
import SwiftUI
import DSHChatDomain

/// 搜索面板的动作半边（调度、执行、翻页预读）。从 TranscriptSearchSheet.swift 拆出，
/// 主文件只留视图（500 行上限，宪法）。
///
/// 注意：这里的成员访问的是主文件里 internal 的 @State，编译期仍是同一个 View 值类型，
/// 只是物理上分了文件。
extension TranscriptSearchSheet {

    // MARK: - 搜索调度

    /// 现在要搜什么（筛选 + 关键词）——同时也是"要不要重搜"的指纹。
    var searchKey: String {
        "\(onlyMine ? "mine" : "all")|\(query.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// 排一次搜索。打字时每敲一下都会把上一次排的取消掉，所以只有停下来那一次会真的跑；
    /// 指纹没变（比如只是内容变大）也走这条路，但 `immediate` 之外的重复输入不会重搜。
    ///
    /// 三类重复调度在这里被挡掉（前两类是 2026-10-11 用例 49 的回归根因）：
    ///
    ///   * **同 key 正在飞**：`scheduleSearch()` 原来无条件 `cancel()`，而时间线
    ///     一变大（`.onChange(of: items.count)`）或范围版本 +1 就会再排一次——
    ///     连接器搜索要 2 秒往返，这一刀正好砍在它身上，`performSearch` 落到
    ///     `Task.isCancelled` 静默返回，命中列表永远不出现（run 20261011-204147：
    ///     4 条 schedule 互相取消，0 条 `search.run`）。现在同 key 不打断在飞的那次，
    ///     只记一个"落地后补一次"（仅本地窗口来源需要，见 `finishSearch`）。
    ///   * **同 key 已落地且来源是连接器**：连接器命中覆盖整个会话，和本地读到
    ///     多远无关，重跑只会再打一次 2 秒往返、把读者正看着的列表换掉。
    ///   * **同 key 已经排上但还没开跑**：点胶囊会同时走按钮动作与
    ///     `.onChange(of: onlyMine)`，两条都排一次，后一条把前一条取消掉
    ///     （run 20261011-211413 的 `search.cancelled key=mine|`）——等着就行。
    func scheduleSearch(immediate: Bool = false) {
        let key = searchKey
        if runningSearchKey == key {
            pendingScopeRefresh = true
            ChatProbe.shared.probeNote?("search.dedup", ["key": key, "immediate": immediate ? "1" : "0"], true)
            return
        }
        if isSearchPending, latestSearchKey == key {
            // 已经排上、还没开跑的同一次搜索（点胶囊的双触发）：后一条不该把前一条
            // 取消重排——它跑的就是同一个指纹，等着就行，不置补跑标记。
            ChatProbe.shared.probeNote?("search.dedup", ["key": key, "queued": "1"], true)
            return
        }
        if !immediate, key == landedKey, searchSource == .connector {
            ChatProbe.shared.probeNote?("search.skip", ["key": key, "reason": "connector-covers-all"], true)
            return
        }
        searchTask?.cancel()
        latestSearchKey = key
        isSearchPending = true
        ChatProbe.shared.probeNote?("search.schedule", ["key": key, "immediate": immediate ? "1" : "0"], false)
        if immediate {
            searchTask = Task { @MainActor in await performSearch(key: key) }
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.typingDebounce))
            if Task.isCancelled {
                // 打字期间被打断的那些：探针留痕，用来证明"只有最后一次落地"。
                ChatProbe.shared.probeNote?("search.dropped", ["key": key], false)
                return
            }
            await performSearch(key: key)
        }
    }

    // MARK: - 执行

    /// 真正的匹配。
    ///
    /// 三条路，互不含糊（T040）：
    ///   * 「只看我的提问」→ **只读本地**（`record` / `record_fts`，零网络），未灌全也照读，
    ///     完整性交给顶部「同步中…」状态行，**没有**连接器岔路；
    ///   * 关键词 ≥2 字且连接器能搜整个会话 → 连接器（`sessionFind`），覆盖整会话；
    ///   * 其余 → 本地已加载的那一段（老连接器的降级，FR-015/FR-036）。
    @MainActor
    func performSearch(key: String) async {
        lastSearchKey = key
        runningSearchKey = key
        let items = model.searchItems
        let query = self.query
        let mine = onlyMine
        let started = Date()
        var found: [TranscriptSearchHit] = []
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if mine {
            // 来源先落定再 await：否则这段窗口里 `requestLoad()` 可能按上一次的
            // `.connector` 去要一页「我的提问」（那正是要删掉的那条路）。
            searchSource = .localStore
            searchCursor = nil
            pageHasMore = false
            searchProgress = nil
            // 完整性标记与命中同属一次本地读路径：先问标记，灌全时状态行不会闪。
            await refreshUserInputSyncState(rerunOnSync: false)
            found = await model.localUserInputHits(query: query)
        } else if model.connectorSearchesWholeSession, keyword.count >= 2 {
            // 只有"搜全部内容"才走连接器；`onlyMine` 恒为 false（上面已独占），
            // 所以这里不再带 roles 过滤。
            //
            // 来源同样**先落定再 await**（原来放在 await 之后）：这段时间里
            // `.onChange(items.count)` 会把这一次判成"本地窗口来源"，而
            // `requestLoad()`/`loadMore` 也会按上一次的来源去分页。
            searchSource = .connector
            let page = await model.searchPage(query: query, onlyMine: false, limit: 50)
            found = page?.hits ?? []
            searchCursor = page?.cursor
            pageHasMore = page?.hasMore ?? false
            searchProgress = page?.progress
        } else {
            // 没有这个能力：老办法（本地、只搜已加载的那一段），并且**离开主线程**匹配。
            found = await Task.detached(priority: .userInitiated) {
                TranscriptSearch.hits(in: items, query: query, onlyMine: mine)
            }.value
            searchCursor = nil
            pageHasMore = false
            searchProgress = nil
            searchSource = .localWindow
        }
        finishSearch(key: key, found: found, items: items, started: started)
    }

    /// 一次搜索的收口：先撤在飞标记，再按"取消 / 落地"两种结局分别留痕。
    ///
    /// `Task.isCancelled` 这条出口原来是**静默**的（probe 都不打）：2026-10-11
    /// 用例 49 的两次复跑里 `search.run` 一次都没出现，光看日志分不清"没跑"还是
    /// "跑到一半被取消"。现在补 `search.cancelled`。
    private func finishSearch(key: String, found: [TranscriptSearchHit],
                              items: [TimelineItem], started: Date) {
        if runningSearchKey == key { runningSearchKey = nil }
        // 范围变大（补页 / 往前翻历史）触发的补跑：只有本地窗口来源的结果依赖
        // "读到了多远"，连接器命中覆盖整个会话、本地全量库与窗口无关，都不补跑。
        let rerun = pendingScopeRefresh && searchSource == .localWindow && latestSearchKey == key
        pendingScopeRefresh = false
        if Task.isCancelled {
            ChatProbe.shared.probeNote?("search.cancelled", [
                "key": key, "source": searchSource.rawValue,
            ], true)
            return
        }
        ChatProbe.shared.probeNote?("search.run", [
            "key": key,
            "source": searchSource.rawValue,
            "items": String(items.count),
            "hits": String(found.count),
            "ms": String(format: "%.0f", Date().timeIntervalSince(started) * 1000),
        ], true)
        if latestSearchKey == key { isSearchPending = false }
        guard latestSearchKey == key else { return }
        landedKey = key
        hits = found
        // 结果集换了（切筛选、改关键词、缓冲变大）：可见集合按 id 保留，余量重算一次。
        visibleHitIds = visibleHitIds.filter { id in found.contains { $0.id == id } }
        if rerun {
            ChatProbe.shared.probeNote?("search.rerun", ["key": key, "items": String(items.count)], true)
            scheduleSearch(immediate: true)
            return
        }
        prefetchIfRunningLow()
    }

    func pick(_ hit: TranscriptSearchHit) {
        onPick(hit)
        dismiss()
    }

    // MARK: - 「同步中…」状态（T040）

    /// 读一次完整性标记（本地一次 SQLite 索引读，零网络）并落到面板状态。
    ///
    /// 由 `performSearch` 的本地路径和 `watchUserInputSyncState()` 共同调用。
    /// `rerunOnSync` 只在"由未灌全翻到已灌全"时重跑查询：列表无缝变完整，
    /// 读者不用关掉面板再打开。`performSearch` 自己调时传 false（避免自触发的重复搜）。
    func refreshUserInputSyncState(rerunOnSync: Bool = true) async {
        let synced = await model.userInputsSynced()
        guard synced != isUserInputsSynced else { return }
        isUserInputsSynced = synced
        ChatProbe.shared.probeNote?("search.sync", ["synced": synced ? "1" : "0"], true)
        if synced, rerunOnSync { scheduleSearch(immediate: true) }
    }

    /// 未灌全时每 1.5 秒轻量查一次标记，灌全立刻撤掉「同步中…」。
    ///
    /// 为什么是轮询而不是回填完成时的通知：回填跑在列表页的冷启动任务里
    ///（`SessionListModel+ColdStart`），它拿不到当前这个面板；为一条状态行铺一层
    /// 通知管线不值当。这里查的是一行索引读，只在「只看我的提问」且未灌全时才转。
    func watchUserInputSyncState() async {
        guard onlyMine else { return }
        while !Task.isCancelled {
            await refreshUserInputSyncState()
            guard isUserInputsSynced == false else { return }
            try? await Task.sleep(for: .milliseconds(Self.syncPollMilliseconds))
        }
    }

    // MARK: - 翻页预读

    /// 往搜索缓冲里再取一页（**不动时间线**，也就不会挪动读者的位置）。
    /// 可见范围之外还剩几条？不够 `prefetchAhead` 就继续往前读——读完再判一次，
    /// 所以"一旦触发就会连着读到够"（页里通常只有几条提问，一次要读好几页才攒够 10 条）。
    func prefetchIfRunningLow(fallbackWhenNothingVisible: Bool = false) {
        // localStore（「我问过的」本地全量库）没有"更早的一页"可预读。
        guard searchSource != .localStore,
              !isLoadingMore, model.canExtendSearch, !hits.isEmpty else { return }
        // 打字期间不读：那会一边追加行一边重排列表，和输入抢主线程（也正是"卡"的来源）。
        guard !isSearchPending else { return }
        let lastVisible = hits.lastIndex { visibleHitIds.contains($0.id) }
        guard let lastVisible else {
            // 还没有行上报可见（首次布局那一瞬间）：只有底部那行露面时才兜底读一页。
            if fallbackWhenNothingVisible { requestLoad() }
            return
        }
        let remaining = hits.count - 1 - lastVisible
        ChatProbe.shared.probeNote?("search.buffer", [
            "rows": String(hits.count),
            "visible": String(visibleHitIds.count),
            "remaining": String(remaining),
        ], false)
        guard remaining <= Self.prefetchAhead else { return }
        // 一轮滑动（或一次筛选/关键词变更）里最多自动读 `maxScrollDrivenLoads` 页：
        // 读者再滑一下就又有这么多。**不能**按"有产出就一直读"放开——关键词命中很多时
        // 那条路会把整段历史读完（2026-09-25 实测：搜 circleboom 一次读掉 9 页到 seq 0）。
        let produced = hits.count > lastRowCount
        guard scrollDrivenLoads < Self.maxScrollDrivenLoads else {
            ChatProbe.shared.probeNote?("search.prefetch.budget", [
                "rows": String(hits.count),
                "remaining": String(remaining),
                "budget": String(scrollDrivenLoads),
            ], true)
            return
        }
        scrollDrivenLoads += 1
        ChatProbe.shared.probeNote?("search.prefetch", [
            "rows": String(hits.count),
            "remaining": String(remaining),
            "produced": produced ? "1" : "0",
            "budget": String(scrollDrivenLoads),
        ], true)
        requestLoad()
    }

    /// 起一次"往前读一页"。同步占住 `isLoadingMore`，避免同一批行事件里起好几个。
    ///
    /// `onlyMine` 直接挡掉：「我问过的」是本地全量库，没有更早的一页，也**没有**网络可退
    ///（T040）——这里不挡的话，竞态窗口里会按上一次的来源去要连接器分页。
    func requestLoad() {
        guard !isLoadingMore, model.canExtendSearch, !onlyMine else { return }
        isLoadingMore = true
        Task { await loadMore() }
    }

    func loadMore() async {
        // 探针：记下"追加前后"的条数与**第一条**。追加只发生在列表末尾，所以第一条
        // 必须始终不变——这是"加载无感、列表不跳"的机器判据（`firstBefore == firstAfter`）。
        let firstBefore = hits.first?.id
        let countBefore = hits.count
        // 起跑时的指纹。取页是网络动作，期间读者可能切了筛选 / 改了关键词——那之后
        // 这一页属于**上一个**结果集，追进去就是"列表被换掉"（2026-10-11 用例 44
        // run 20261011-211807：切到「只看我的提问」之后，上一轮 `circleboom` 的
        // 连接器续页把 4 条命中又塞回了刚清空的列表，空态文案因此没出现）。
        let key = searchKey
        switch searchSource {
        case .localStore:
            // 正常路径到不了这里（`requestLoad` 已挡掉 onlyMine）：万一别人改了调用点，
            // 也只是重读一次本地，绝不联网。
            await performSearch(key: searchKey)
        case .connector:
            // 连接器分页：直接要下一页命中（它自己扫整个会话），不走本地缓冲。
            let page = await model.searchPage(query: self.query, onlyMine: false,
                                              cursor: searchCursor, limit: 50)
            guard searchKey == key else { return dropStalePage(key) }
            if let page {
                let existing = Set(hits.map(\.id))
                hits.append(contentsOf: page.hits.filter { !existing.contains($0.id) })
                searchCursor = page.cursor
                pageHasMore = page.hasMore
                // 翻页后进度往前走：读者看到的是"已扫 k/N 片"在增长，而不是数字不动。
                searchProgress = page.progress
            }
        case .localWindow:
            await model.extendSearchHistory()
            guard searchKey == key else { return dropStalePage(key) }
            await performSearch(key: key)
        }
        lastRowCount = hits.count
        isLoadingMore = false
        ChatProbe.shared.probeNote?("search.page", [
            "before": String(countBefore),
            "after": String(hits.count),
            "firstBefore": firstBefore ?? "-",
            "firstAfter": hits.first?.id ?? "-",
            "kept": firstBefore == hits.first?.id ? "1" : "0",
        ], true)
        // 追加进来的行在屏幕外，不会再触发 `onAppear`；所以这里主动再判一次余量，
        // 不够就接着读（"触发了就继续预加载"）。放在 `isLoadingMore` 放下之后，
        // 否则会被自己的 guard 挡掉（上一版就是这样：连读其实是靠别的行事件凑出来的）。
        prefetchIfRunningLow()
    }

    /// 这一页取回来时结果集已经换了：丢弃，不追加进新列表（留一条探针，别静默）。
    private func dropStalePage(_ key: String) {
        isLoadingMore = false
        ChatProbe.shared.probeNote?("search.page.dropped", ["key": key], true)
    }
}
#endif

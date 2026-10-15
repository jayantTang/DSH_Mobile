import DSHKit
import Foundation

/// 009 桥的取页半边（从 `ChatModel+Pipeline.swift` 拆出：主文件顶到 500 行上限，
/// 沿用 `SessionPipeline+Streaming` / `ChatModel+ColdStart` 的拆法）。
///
/// 这里只收「用户驱动的取页与追平」：向上翻页、顶部合成缺口行（已到最早 / 失败重试 /
/// 加载中）、尾部追平，以及它们的状态落地。订阅、折叠落地、跳转仍在主文件。
///
/// T037 纪律（spec 009 追加修订 1/3「加载状态不许静默」）：本文件里不允许存在
/// 「正常返回但什么都不发生」的出口——每个结局都要落到一个可见状态行。
public extension ChatPipelineBridge {

    /// 向上翻页（.userVisible）：向管道请求窗口之上的对齐范围；缺口由管道拉取回填。
    ///
    /// T037 收掉了两个静默 return：
    /// - 窗口最老序号 ≤ 1：本地已到最早（seq 从 1 编号），直接置管道「已到最早」并
    ///   渲染 `.exhausted` 行，不再空发请求；
    /// - 本地窗口还没有数据（管道未就绪）：锚点退回管道区间集的最老，据此仍发一次
    ///   拉取（不能因为本地视图为空就不拉）；连区间集都没有就渲染「加载中」并挂
    ///   `pendingOlderRequest`，首个数据落地后由 `apply` 自动补一次。
    public func loadOlder() async {
        guard let model, let session, !isLoadingOlder else { return }
        guard let oldest = await olderAnchor(session) else {
            armPendingOlder(model)
            return
        }
        guard oldest > 1 else {
            await noteEarliestReached(session, model)
            return
        }
        isLoadingOlder = true
        olderFailure = nil
        model.notePipelineLoadingOlder(true)
        model.notePipelineOlderFailure(nil)
        refold(messagesChanged: false, gapsChanged: true) // 顶部 spinner 立即出现
        defer {
            isLoadingOlder = false
            model.notePipelineLoadingOlder(false)
            refold(messagesChanged: false, gapsChanged: true)
        }
        // 017：一次向上翻不是要一页，而是要**接下来几屏**——一页一次往返就是
        // "每屏等一次"的来源。请求区间仍从最老已加载记录往上算，页边界不变。
        let lower = max(1, oldest - Self.pageSize * Self.pagesPerFetch)
        do {
            _ = try await session.records(in: lower...(oldest - 1), priority: .userVisible)
            didAutoRetry = false
            // 009 取页链路原来没有任何探针事件（pager.page 只在旧 pager 路径上），
            // 失败语义不可观测。按同一名字补回（用例按「逐页落地、首尾相接」验收）。
            ChatProbe.shared.probeNote?("pager.page", [
                "start": String(lower), "end": String(oldest - 1),
                "pages": String(Self.pagesPerFetch),
                "oldest": String(records.keys.min() ?? -1),
            ], true)
        } catch {
            // 失败绝不写成「没有更多」（T016）：顶部行转「点击重试」，并补试一次。
            olderFailure = String(localized: "读取更早的记录失败，点按重试")
            model.notePipelineOlderFailure(olderFailure)
            ChatProbe.shared.probeNote?("pager.failed", [
                "start": String(lower), "end": String(oldest - 1),
                "reason": String(describing: error),
            ], true)
            scheduleAutoRetry()
        }
    }

    /// 向上翻页的锚点：本地窗口最老序号；本地还没数据时退回管道区间集的最老
    /// （区间集声称磁盘已覆盖的范围，据此仍能算出一页）。nil = 锚点不可知。
    private func olderAnchor(_ session: SessionHandle) async -> Int? {
        if let oldest = records.keys.min() { return oldest }
        return await session.ranges.oldest
    }

    /// 锚点不可知（本地窗口与管道区间集都空）：渲染「加载中」并挂 pending 标记，
    /// 首个数据落地后由 `apply` 自动补一次拉取（T037：不能静默返回）。
    private func armPendingOlder(_ model: ChatModel) {
        pendingOlderRequest = true
        isLoadingOlder = true
        olderFailure = nil
        model.notePipelineLoadingOlder(true)
        model.notePipelineOlderFailure(nil)
        ChatProbe.shared.probeNote?("pager.pending", ["reason": "no-anchor"], true)
        refold(messagesChanged: false, gapsChanged: true)
    }

    /// 本地窗口最老序号已到 1 = 已到最早：置管道状态并整树重折一次渲染
    /// `.exhausted` 顶部行（整树走一遍是为了让 `hasOlder` 归 false——留着 true
    /// 时上滑哨兵还会继续空转）。不再发请求。
    private func noteEarliestReached(_ session: SessionHandle, _ model: ChatModel) async {
        await session.markEarliestReached()
        isLoadingOlder = false
        olderFailure = nil
        model.notePipelineLoadingOlder(false)
        model.notePipelineOlderFailure(nil)
        ChatProbe.shared.probeNote?("pager.end", ["oldest": String(records.keys.min() ?? 1)], true)
        refold(messagesChanged: true, gapsChanged: true)
    }

    /// 失败后的一次自动补试（读者停在顶部时没有任何几何变化可触发重试）。
    private func scheduleAutoRetry() {
        guard !didAutoRetry else { return }
        didAutoRetry = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(3000))
            guard !Task.isCancelled, let self, self.olderFailure != nil else { return }
            await self.loadOlder()
        }
    }

    /// 缺口行「点击重试」（T016）：清掉失败计数再拉；顶部行等价于重试向上翻页。
    public func retryGap(start: Int, end: Int) async {
        guard let session, let model else { return }
        if start == 0 {
            // 顶部合成行也要走「清计数再拉」：原来直接 loadOlder，对齐页失败计数
            // 到 maxRetries 上限后 fetchPage 直接抛 gapFailed，顶部重试条从此
            // 永远点不动（用例 48 run 20261011-103217 实测：点击后只见 gapFailed，
            // 行不消失）。与中间缺口同一个 retry 契约（SessionPipeline.retry）。
            olderFailure = nil
            didAutoRetry = false
            // T037：顶部行的两个静默出口与 loadOlder 同口径（原来这里也是直接 return）。
            guard let oldest = await olderAnchor(session) else {
                armPendingOlder(model)
                return
            }
            guard oldest > 1 else {
                await noteEarliestReached(session, model)
                return
            }
            // 017：重试与向上翻同口径——一次要的也是接下来几屏，否则点一次只回一页，
            // 读者马上又撞到同一段等待。
            let lower = max(1, oldest - Self.pageSize * Self.pagesPerFetch)
            try? await session.retry(range: lower...(oldest - 1))
            // 顶部行的恢复不走 loadOlder，pager.page 打不到；恢复动作要可观测（用例 48）。
            ChatProbe.shared.probeNote?("pager.retry", ["start": String(lower), "end": String(oldest - 1)], true)
            return
        }
        try? await session.retry(range: start...end)
        ChatProbe.shared.probeNote?("pager.retry", ["start": String(start), "end": String(end)], true)
    }

    /// 顶部合成行：已到最早（仅 topExhausted）> 失败可重试 > 加载中。
    /// start=0 是合成身份（`gap:0-0`），排序恒在最前，不与任何真实缺口撞键。
    public func topGapItem(topExhausted: Bool) -> TimelineItem? {
        if topExhausted {
            return ChatTimeline.gapItem(start: 0, end: 0, status: .exhausted)
        }
        if olderFailure != nil {
            return ChatTimeline.gapItem(start: 0, end: 0, status: .failed(retryable: true))
        }
        if isLoadingOlder {
            return ChatTimeline.gapItem(start: 0, end: 0, status: .loading)
        }
        return nil
    }

    // MARK: - 尾部追平（T018 点胶囊 / T019 可见性兜底）

    /// 桥已收到的最大 seq。
    public func localNewestSeq() -> Int { records.keys.max() ?? 0 }

    /// 尾部追平展示态变了：底部合成缺口行生灭。
    public func noteCatchUpPresentationChanged() {
        refold(messagesChanged: false, gapsChanged: true)
    }

    /// 把尾部对到 host 的 lastSeq（spec 009 场景 7 /「可见性兜底」）。
    ///
    /// - 差值 ≤ 5 页：`records(in:, .userVisible)` 逐段补齐，diff 正常回填，
    ///   底部 spinner 由 `isCatchingUpTail` 期间的合成缺口行表达；
    /// - 差值 > 5 页：降级为直接跳最新页（.jump），中间段丢弃——与跳转同语义，
    ///   留下的洞是普通的中间缺口行（点它可按既有重试路径补齐）。
    /// 幂等由管道的 in-flight 页表保证（同页合并）。
    public func catchUp(toHost lastSeq: Int) async {
        guard let session, lastSeq > 0 else { return }
        let localNewest = records.keys.max() ?? 0
        let missing = lastSeq - localNewest
        guard missing > 0 else { return }
        if missing > Self.pageSize * Self.catchUpPageBudget {
            let lower = max(1, lastSeq - Self.pageSize + 1)
            _ = try? await session.records(in: lower...lastSeq, priority: .jump)
            // T026 修复 US3 遗留：降级丢弃的中间段不在任何在飞拉取里，
            // 停在 .loading 永远转圈。置为可重试失败——用户点它才拉，
            // 符合「丢弃中间段」的省流量语义（spec 场景 7）。
            if localNewest + 1 <= lower - 1 {
                await session.abandonGap((localNewest + 1)...(lower - 1))
            }
        } else {
            _ = try? await session.records(in: (localNewest + 1)...lastSeq, priority: .userVisible)
        }
    }
}

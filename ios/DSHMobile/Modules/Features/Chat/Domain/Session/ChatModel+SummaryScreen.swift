import DSHFoundation
import DSHKit
import Foundation

/// 首屏概要取数（能力 `history-fold-summary-v2`，`fold: "summary"`）。
///
/// 与普通翻页的分工：普通窗口按 seq 取"记录"，概要模式按**整轮**取
/// "讲话 + 概要 + 回答"，`limit` 是轮数、`maxBytes` 是主约束。这一页进管道时
/// 整段 `startSeq...endSeq` 记为已读（`adoptSummaryPage`），被折掉的 seq 不会
/// 变成缺口，也不会被再取一遍。
///
/// 缓存：记录（含 `+link/fold` v2 概要）走管道落库，二次打开由 `loadStoredTail`
/// 读回并折出轮次/分组骨架；只有当最新一轮还没有概要时才发这一次请求。
public extension ChatModel {

    /// 首屏概要取数的可见状态。
    enum SummaryScreenState: Equatable, Sendable {
        case idle
        case loading
        case ready
        /// `tooLarge` = 连接器回 `link/too-large`（某一轮在一页里读不完）。
        case failed(tooLarge: Bool)

        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        public var isRetryable: Bool { isFailed }
    }

    /// 首屏轮数（设计 §3.4：先取 12 轮）。
    static let summaryScreenTurns = 12
    /// 旧页每次取几轮：与首屏同一个字节预算（256 KB），轮数小一点，
    /// 一次上拉覆盖几屏即可（设计 §3.4「分页按整轮切齐」）。
    static let summaryOlderTurns = 6
    /// 首屏字节上限（设计 §十一：未压缩 ≤200 KB；这里给 256 KB 余量）。
    static let summaryScreenMaxBytes = 256 * 1024

    /// 拉首屏概要页。能力缺失 = 什么都不做（老路径照旧）。
    ///
    /// 三种结局都落到 `summaryScreenState`：成功 `ready`、`link/too-large`
    /// `failed(tooLarge: true)`（页级重试条）、其它失败 `failed(tooLarge: false)`。
    @MainActor
    func loadSummaryScreen() async {
        guard let summary = session,
              let client = store?.chatHost,
              client.historySummaryFoldEnabled,
              // 概要走的是 `_link/sessionWindow`：同一条通道，能力位之外再确认一次。
              client.supportsExactHistoryWindow,
              let address
        else {
            summaryScreenState = .idle
            return
        }
        // 空会话（还没有任何事件）没有概要可取：直接空态，不发请求、也不报错
        //（以前空回包被当成失败，空会话一打开就顶着一条红色重试胶囊）。
        guard summary.asOfSeq > 0 else {
            summaryScreenState = .idle
            return
        }
        // 本地（概要/记录）已经覆盖到 `asOfSeq`：整页 0 请求。
        // 判据是**本地最新 seq**，不是概要的 endSeq（后者是过程段末尾，回答与
        // 轮次边界在它之后）；命中时先渲染缓存骨架，只有宿主前进才按新轮次取。
        let localNewest = await localCoverageSeq(for: summary)
        if localNewest >= summary.asOfSeq, await hasCachedSummary(for: summary) {
            summaryScreenState = .ready
            ChatProbe.shared.probeNote?("summary.screen.cached", [
                "session": summary.sessionId, "newest": String(localNewest),
            ], true)
            return
        }
        // 有缓存时只为"新轮次"取（最新几轮）；首屏才要铺满 12 轮。
        let limit = await hasCachedSummary(for: summary) ? 2 : Self.summaryScreenTurns
        let generation = openGeneration
        summaryScreenState = .loading
        do {
            let page = try await client.historyWindow(HistoryWindowRequest(
                address: address,
                before: summary.asOfSeq + 1,
                through: summary.asOfSeq,
                limit: limit,
                maxBytes: Self.summaryScreenMaxBytes,
                encoding: client.historyWindowEncoding,
                fold: .summary))
            guard generation == openGeneration else { return }
            guard !page.records.isEmpty,
                  let lower = page.startSeq ?? page.records.first?.event.seq,
                  let upper = page.endSeq ?? page.records.last?.event.seq
            else {
                // 空页不是错误：接入之后还没有可折的轮次（刚建会话、或全是系统事件）。
                // 只有真实错误（含 link/too-large）才落到 failed/重试胶囊。
                summaryScreenState = .idle
                ChatProbe.shared.probeNote?("summary.screen.empty", [
                    "session": summary.sessionId,
                ], true)
                return
            }
            await adoptSummaryScreen(page, covered: min(lower, upper)...max(lower, upper))
            guard generation == openGeneration else { return }
            summaryScreenState = .ready
            ChatProbe.shared.probeNote?("summary.screen", [
                "session": summary.sessionId,
                "records": String(page.records.count),
                "start": String(lower), "end": String(upper),
            ], true)
        } catch is CancellationError {
            summaryScreenState = .idle
        } catch let failure as DSHRPCFailure where failure.code == "link/too-large" {
            // 单轮超过一页的回读预算：如实落到页级重试，不静默、不下发半轮。
            summaryScreenState = .failed(tooLarge: true)
            ChatProbe.shared.probeNote?("summary.screen.tooLarge", ["session": summary.sessionId], true)
        } catch {
            summaryScreenState = .failed(tooLarge: false)
            ChatProbe.shared.probeNote?("summary.screen.failed", [
                "session": summary.sessionId, "reason": String(describing: error),
            ], true)
        }
    }

    /// 旧页也走概要 v2（按整轮切页）。返回 true = 这一页由概要路径处理
    /// （成功、空页或已落到可见失败态），调用方不要再走 v1。
    /// 没有 v2 能力、或已经到最早（游标 ≤ 1）时返回 false，旧路径原样。
    @MainActor
    func loadOlderSummaryPage() async -> Bool {
        guard let client = store?.chatHost,
              client.historySummaryFoldEnabled,
              client.supportsExactHistoryWindow,
              let address
        else { return false }
        // **状态归属**：概要旧页只服务管道窗口——它的"更早"来自管道记录的最老
        // 一条，回包也并回管道。没有管道、或管道还一条记录都没有时，这里既不发
        // 请求，也不写任何可见失败态（否则非管道宿主会凭空长出一条重试胶囊）。
        guard let bridge = pipelineBridge, let cursor = bridge.records.keys.min() else {
            return false
        }
        guard cursor > 1 else { return false }
        guard olderState != .loading else { return true }
        notePipelineOlder(state: .loading)
        pipelineBridge?.refold(messagesChanged: false, gapsChanged: true)
        do {
            let page = try await client.historyWindow(HistoryWindowRequest(
                address: address,
                before: cursor,
                through: nil,
                limit: Self.summaryOlderTurns,
                maxBytes: Self.summaryScreenMaxBytes,
                encoding: client.historyWindowEncoding,
                fold: .summary))
            guard let lower = page.startSeq ?? page.records.first?.event.seq,
                  let upper = page.endSeq ?? page.records.last?.event.seq
            else {
                // 空页先问"有没有可确认的更早范围"：连接器给了更早的边界
                // （`startSeq`/`scanBoundary` < 游标）才是异常；连边界都没有，
                // 就是没有更早的轮次 —— 按「已到最早」处理，不落失败。
                let confirmsOlder = (page.startSeq.map { $0 < cursor } ?? false)
                    || (page.scanBoundary.map { $0 < cursor } ?? false)
                if confirmsOlder && pipelineBridge != nil {
                    notePipelineOlder(state: .failed(
                        String(localized: "读取更早的记录失败，点按重试")))
                } else {
                    bridge.noteSummaryOlderExhausted()
                }
                return true
            }
            let covered = min(lower, upper)...max(lower, upper)
            if let bridge = pipelineBridge {
                await bridge.adoptSummaryPage(
                    records: page.records, covered: covered, hasMore: page.hasMore,
                    clamped: page.clamped ?? false,
                    knownEmpty: page.knownEmpty ?? [],
                    revision: page.revision)
            } else {
                timeline.merge(snapshot: page.records)
                if let scope = sessionScope, let id = session?.sessionId {
                    enqueueAppend(scope: scope, sessionId: id, records: page.records)
                }
                scrollSignal += 1
            }
            if !page.hasMore {
                pipelineBridge?.noteSummaryOlderExhausted()
            } else {
                finishOlderIfLoading()
            }
            ChatProbe.shared.probeNote?("summary.older", [
                "start": String(lower), "end": String(upper),
                "records": String(page.records.count),
                "hasMore": page.hasMore ? "1" : "0",
            ], true)
            return true
        } catch is CancellationError {
            finishOlderIfLoading()
            return true
        } catch let failure as DSHRPCFailure where failure.code == "link/too-large" {
            if pipelineBridge != nil {
                notePipelineOlder(state: .failed(String(localized: "有一轮过大，点按重试")))
            } else {
                finishOlderIfLoading()
            }
            return true
        } catch {
            // 管道在等回包期间被停掉（切会话/断线）：这条失败已经没有归属，
            // 不再写成可见态，免得非管道宿主画出胶囊。
            if pipelineBridge != nil {
                notePipelineOlder(state: .failed(String(localized: "读取更早的记录失败，点按重试")))
            } else {
                finishOlderIfLoading()
            }
            return true
        }
    }

    /// 页级重试：从可见的重试条进来，失败结果仍然只改这一处状态。
    @MainActor
    func retrySummaryScreen() async {
        guard !summaryScreenTaskIsRunning else { return }
        await loadSummaryScreen()
    }

    private var summaryScreenTaskIsRunning: Bool {
        if case .loading = summaryScreenState { return true }
        return false
    }

    /// 本地已经覆盖到哪个 seq：管道记录 → 时间线数据行 → 磁盘会话聚合，取最大。
    @MainActor
    private func localCoverageSeq(for summary: SessionSummary) async -> Int {
        var newest = pipelineBridge?.records.keys.max() ?? 0
        let rowSeqs = timeline.items.compactMap { item -> Int? in
            if case .runningLine = item.kind { return nil }
            return item.seq < Int.max - 1000 ? item.seq : nil
        }
        newest = max(newest, rowSeqs.max() ?? 0)
        newest = max(newest, recentRecords.last?.event.seq ?? 0)
        if let layer = messageBacking, let scope = sessionScope,
           let state = try? await layer.sessionState(scope: scope, sessionId: summary.sessionId) {
            newest = max(newest, state.newestSeq ?? 0)
        }
        return newest
    }

    /// 本地有没有概要：先看时间线，管道还没来得及重建时再读磁盘那一段。
    @MainActor
    private func hasCachedSummary(for summary: SessionSummary) async -> Bool {
        if !timeline.foldSummaries.isEmpty { return true }
        guard let layer = messageBacking, let scope = sessionScope,
              let records = try? await layer.windowBefore(
                scope: scope, sessionId: summary.sessionId, seq: Int.max,
                limit: Self.summaryScreenTurns * 40)
        else { return false }
        return records.contains { FoldSummaryV2.decode($0.event) != nil }
    }

    /// 把一页概要并进管道（管道缺位时直接并进时间线并落库）。
    @MainActor
    private func adoptSummaryScreen(_ page: HistoryWindowValue, covered: ClosedRange<Int>) async {
        if let bridge = pipelineBridge {
            await bridge.adoptSummaryPage(
                records: page.records, covered: covered, hasMore: page.hasMore,
                clamped: page.clamped ?? false,
                knownEmpty: page.knownEmpty ?? [],
                revision: page.revision)
            return
        }
        timeline.merge(snapshot: page.records)
        if let scope = sessionScope, let id = session?.sessionId {
            enqueueAppend(scope: scope, sessionId: id, records: page.records)
        }
        scrollSignal += 1
    }
}

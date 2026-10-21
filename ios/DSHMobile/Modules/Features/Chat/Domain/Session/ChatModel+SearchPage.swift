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
}

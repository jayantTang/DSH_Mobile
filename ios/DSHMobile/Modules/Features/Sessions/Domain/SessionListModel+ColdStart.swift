import DSHKit
import Foundation

/// 列表冷启动的 009 叠加（tasks T010/T011，spec 009「冷启动流程」第 1/2/4 步）。
///
/// 叠加而非替换：现有 `SessionListSnapshotStore` 快照机制照旧负责首帧，这里只在
/// MessageStore（009 磁盘层）有数据时把它的聚合信息叠上去；磁盘层为空（老用户
/// 首次启动）时一切表现与现状一致。host 数据回来后仍以 host 为准，刷新逻辑不动。
public extension SessionListModel {

    /// T011：按列表顺序为前 ~10 个会话排预取瀑布（最新页 [newestSeq-49, newestSeq]，
    /// 并发 3，低优先级后台任务）。链接未建立、磁盘层不可用都整体跳过——
    /// 预取不许报错刷日志；同一台电脑一次启动只排一次。
    /// 冷启动后台预热覆盖多少个会话（与最新页预取同一批：首屏可见的十来个）。
    static let warmupSessions = 10

    public func scheduleColdStartPrefetch() {
        guard let scope = store?.scopeId, store?.client != nil,
              lastPrefetchScope != scope,
              let layer = messageLayer, let pipeline = layer.pipeline, let store = layer.store
        else { return }
        // 列表顺序 = 分组顺序 + 折叠桶，与屏幕上一致；去重（child 不进组）。
        var seen = Set<String>()
        let ordered = (groups.flatMap(\.sessions) + loose)
            .filter { seen.insert($0.sessionId).inserted }
        guard !ordered.isEmpty else { return }
        lastPrefetchScope = scope
        layer.registerAddresses(ordered)
        // 连接器能力在 Task 外面取（Task 里 store 被 MessageStore 遮蔽）：
        // 没有 history-role-filter 时回填整体跳过（摘要不入新库，等升级）。
        let roleFilter = self.store?.supports(LinkHandshake.Capability.historyRoleFilter) ?? false
        Task(priority: .utility) {
            let states = (try? await store.sessionStates(scope: scope)) ?? []
            var persistedRanges: [MessageSessionRef: RangeIndex] = [:]
            var newestBySession: [String: Int] = [:]
            for entry in states {
                let ref = MessageSessionRef(scope: scope, sessionId: entry.sessionId)
                if !entry.ranges.isEmpty { persistedRanges[ref] = entry.ranges }
                if let newest = entry.newestSeq { newestBySession[entry.sessionId] = newest }
            }
            // 最新游标优先取磁盘层的（与持久化区间同源），没有再用 host 的 asOfSeq。
            let targets = ordered.prefix(10).compactMap { summary -> MessagePrefetchTarget? in
                let newest = newestBySession[summary.sessionId] ?? summary.asOfSeq
                guard newest > 0 else { return nil }
                return MessagePrefetchTarget(
                    session: .init(scope: scope, sessionId: summary.sessionId), newestSeq: newest)
            }
            if !targets.isEmpty {
                probeNote?("prefetch.coldstart", ["sessions": String(targets.count)], true)
                await pipeline.prefetchLatestPages(
                    targets, persistedRanges: persistedRanges, limit: 10, concurrency: 3)
            }
            // T033：预取瀑布之后灌「我问过的」全量库（优先级天然低于最新页预取——
            // 串行排在它后面；任务本身是 .utility）。逐会话串行，内部有 24h
            // 去重与 lastSeq 增量判定，重复触发是廉价的。
            // (b) 只预热**首屏可见的那一批**（与上面最新页预取同一批），不再遍历全部会话：
            // 重装后账本为空时"遍历全部"意味着 437 个会话一路扫下去。剩下的会话由面板按需灌
            // （`ChatModel.ensureUserInputsBackfilled`），用户点开哪一个就补哪一个。
            await layer.backfillUserInputs(
                scope: scope, summaries: Array(ordered.prefix(Self.warmupSessions)),
                roleFilterSupported: roleFilter)
        }
    }
}

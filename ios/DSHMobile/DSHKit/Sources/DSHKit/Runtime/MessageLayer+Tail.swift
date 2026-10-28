import Foundation

/// `MessageLayer` 上尾轮边界的那两个门面（设计 `20261027-折叠抖动-方案A.md` M2'-2）。
///
/// 与 `sessionState` 同一段语义，但**不许**照 `meta` / `clear` 那样用 `try?` 吞掉：
/// 那两条是缓存行为（丢了再取一次），边界写入不是——写失败必须让调用方看见，
/// 才能发 `tail.persist.failed` 探针（可见后果是下次打开仍未知、占位行可重试）。
///
/// 为什么单独一个文件：`MessageLayer.swift` 已 616 行（既有超限），按"既有超限文件
/// 只许持平/净减"的纪律，门面放这里；方法与类型仍是同一个，不构成第二条通路。
extension MessageLayer {

    /// 上次观测到的尾轮边界（没有行 = 从未确认）。
    public func tailBoundary(scope: String, sessionId: String) async throws -> StoredTailBoundary? {
        guard let store else { throw FetchFailure.noAddress }
        return try await store.tailBoundary(scope: scope, sessionId: sessionId)
    }

    /// 写一个会话的区间集（覆盖情况）。
    ///
    /// 产品里的写者只有一个：`MessagePipeline.prefetchLatestPage` 在最新页落地后
    /// 回写（补读要靠它判断"下方有没有洞"）。internal：目前只有用例需要直接摆出
    /// "区间集已知有缺口"的现场，产品侧不该有人从 App 层写这条事实。
    func saveRanges(scope: String, sessionId: String, ranges: RangeIndex) async throws {
        guard let store else { throw FetchFailure.noAddress }
        try await store.saveRanges(scope: scope, sessionId: sessionId, ranges: ranges)
    }

    /// 写一个会话的边界。失败抛出，由调用方落探针。
    public func setTailBoundary(scope: String, sessionId: String,
                         _ boundary: StoredTailBoundary) async throws {
        guard let store else { throw FetchFailure.noAddress }
        try await store.setTailBoundary(scope: scope, sessionId: sessionId, boundary)
    }
}

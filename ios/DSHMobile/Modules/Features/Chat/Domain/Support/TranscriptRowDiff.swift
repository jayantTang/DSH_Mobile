import Foundation

/// 列表差集：哪些行 **id 没变、内容签名变了**，需要 reload。
///
/// 为什么单独成纯函数：uikit 宿主的 `reconcile` 一度按**同一个 index 的 id**
/// 比较签名。取消时在分组行上方插入一行「已停止」，后面的行整体右移，index 对不上，
/// 分组行的签名变化就进不了 `changedIds`——cell 保留旧内容，屏幕上的「正在分析请求」
/// 要等点一下那一行才刷（TC-116）。
///
/// 口径只有一条：**按 id 对齐**。新增行不在这里（交给 diffable 插入），
/// 消失的行也不在这里（交给 diffable 删除）。
public enum TranscriptRowDiff {

    /// 一行在差集里的最小信息：身份 + 内容签名。
    public struct Row: Sendable, Equatable {
        public let id: String
        public let signature: String

        public init(id: String, signature: String) {
            self.id = id
            self.signature = signature
        }
    }

    /// 需要 reload 的行 id。
    ///
    /// - 只有"上一次也有同 id、且签名不同"才收集；
    /// - 从左/右插入、删除、重排都不会误判（index 不参与比较）；
    /// - 全新行不收集：diffable 的插入自会拿到一次正确的初次配置。
    public static func changedRowIDs(previous: [Row], current: [Row]) -> Set<String> {
        guard !previous.isEmpty else { return [] }
        var previousByID: [String: String] = [:]
        previousByID.reserveCapacity(previous.count)
        for row in previous { previousByID[row.id] = row.signature }
        var changed = Set<String>()
        for row in current {
            guard let old = previousByID[row.id] else { continue }
            if old != row.signature { changed.insert(row.id) }
        }
        return changed
    }
}

import DSHKit
import Foundation
import Observation

/// 搜索缓冲的状态：往前读进来、但还没并进时间线的那一段。
///
/// 从 `ChatModel` 拆出的第三块。它和输入区一样只服务一个面板，却和转写/网络
/// 共用一个类型；拆出来之后“缓冲属于哪个会话、覆盖到哪”只有一个所有者。
///
/// 只在本模块内使用（不对外暴露），字段读写仍由 ChatModel 的搜索方法完成。
@MainActor
@Observable
final class SearchState {

    /// 搜索范围（时间线 + 缓冲）变化的计数，面板据此刷新。
    var scopeVersion = 0
    /// 正在往前取搜索缓冲。
    var isExtending = false
    /// 缓冲记录，由旧到新。
    var records: [SessionRecord] = []
    /// 缓冲的最老 seq（`nil` = 没有缓冲）。
    var oldestSeq: Int?
    /// `searchItems` 的结果缓存，键是"缓冲条数 + 时间线条数"。
    var cachedItems: (key: String, items: [TimelineItem])?
    /// 连接器拒绝整会话搜索时的原因（面板显示提示用）。
    var refusalReason: String?

    /// 丢掉缓冲：它属于刚关掉的那个会话。
    func reset() {
        records.removeAll()
        oldestSeq = nil
        cachedItems = nil
        refusalReason = nil
        isExtending = false
        scopeVersion += 1
    }
}

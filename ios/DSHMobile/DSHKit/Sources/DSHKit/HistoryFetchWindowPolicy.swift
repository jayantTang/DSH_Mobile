import Foundation

/// 向上翻页一次要几页（spec 016 后续：折叠感知下的自适应窗口）。
///
/// 为什么需要：连接器把过程段折成一行之后，一页里"画得出来的行"不再和 seq 数
/// 成正比——同样是 50 条记录，有的页出 20 行，有的页只出 1 个过程节点。固定
/// 3 页会让后者每屏都要再翻一次。
///
/// 判据只用**这一批真正返回的记录数**：过程段已经折掉了，返回的每条记录
///（含 `+link/fold` 摘要）都会变成一行可见内容，所以它就是"这一批多了几行"。
/// 少于 `lowWatermark` 行就加倍，多到 `highWatermark` 行就收回基数；窗口上限
/// 同时受连接器单次调用预算约束（超了会拆成多页，反而更慢）。
public struct HistoryFetchWindowPolicy: Sendable, Equatable {
    static let basePages = 3
    static let minimumPages = 1
    static let maximumPages = 8
    static let lowWatermark = 6
    static let highWatermark = 40

    public private(set) var pages: Int

    public init(pages: Int = 3) {   // = `basePages`（内部常量，默认参数只能用字面量）
        self.pages = min(Self.maximumPages, max(Self.minimumPages, pages))
    }

    /// 用这一批返回的记录数调整下一次的窗口。返回调整后的页数，便于调用方记录。
    @discardableResult
    public mutating func observe(records: Int) -> Int {
        if records < Self.lowWatermark {
            pages = min(Self.maximumPages, pages * 2)
        } else if records > Self.highWatermark {
            pages = max(Self.basePages, pages / 2)
        }
        return pages
    }

    /// 换会话 / 重新打开时回到基数：上一段的密度不能带进新会话。
    public mutating func reset() {
        pages = Self.basePages
    }
}

import Foundation

/// 一页历史记录：连接器回包的最小形状。
///
/// `startSeq` / `endSeq` 来自连接器，连续性按事实校验、不靠猜；`clamped`
/// 表示日志被裁剪，只有它允许一页越过窗口而不被当成缺口。
///
/// 2026-10-21：原先这个类型嵌在 `TranscriptPager` 里。主转写的旧分页状态机
/// 已删除（生产路径恒走 `MessagePipeline`），但搜索缓冲与跳转仍在用
/// `TranscriptPageFetcher`，所以把 Page 抽成独立值类型保留下来。
public struct TranscriptPage: Sendable {
    public let records: [SessionRecord]
    public let startSeq: Int
    public let endSeq: Int
    public let hasMore: Bool
    public let clamped: Bool

    public init(records: [SessionRecord], startSeq: Int, endSeq: Int,
                hasMore: Bool, clamped: Bool = false) {
        self.records = records
        self.startSeq = startSeq
        self.endSeq = endSeq
        self.hasMore = hasMore
        self.clamped = clamped
    }
}

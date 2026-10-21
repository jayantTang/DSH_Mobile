import DSHKit
import Foundation

/// 进会话首帧的 009 磁盘层叠加（task T012，spec 009「冷启动流程」第 3 步）。
///
/// T027 之后磁盘层只剩 `MessageStore` 一家：首帧恢复就是 `loadStoredTail`
/// （ChatModel 主文件，读 session_state + 最新页）。本文件只留「点开会话即
/// 插队水合最新页」这一半。
public extension ChatModel {

    /// 点开的会话以 .jump 插队水合最新页（T011：用户操作抢占在途低优预取）。
    /// 水合结果经 009 管道落库，下次冷启动首帧直接命中磁盘。失败静默：
    /// 会话内容照旧由 follow 快照提供，预取不许成为错误来源。
    public func warmMessageLayer(for summary: SessionSummary) {
        guard let layer = messageLayer, layer.isReady,
              let scope = sessionScope, summary.asOfSeq > 0
        else { return }
        messageLayer?.registerAddresses([summary])
        let target = MessagePrefetchTarget(
            session: .init(scope: scope, sessionId: summary.sessionId),
            newestSeq: summary.asOfSeq)
        Task(priority: .utility) {
            await layer.prefetchLatestPages(
                [target], limit: 1, concurrency: 1, priority: .jump)
        }
    }
}

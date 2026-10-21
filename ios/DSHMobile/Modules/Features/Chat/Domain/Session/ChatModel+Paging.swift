import Foundation

/// 分页入口：实现移到 ChatPagingService，ChatModel 只保留对外 API。
extension ChatModel {
    public func loadOlder() async { await pagingService.loadOlder() }
    public func trimWindowIfNeeded(readerIsFollowing: Bool) {
        pagingService.trimWindowIfNeeded(readerIsFollowing: readerIsFollowing)
    }
    public func retryOlder() async { await pagingService.retryOlder() }
}

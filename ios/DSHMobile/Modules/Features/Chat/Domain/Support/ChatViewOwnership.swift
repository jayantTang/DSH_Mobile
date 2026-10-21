import Foundation

/// 会话详情视图是否仍代表屏幕上那个会话。
///
/// 转场期间旧视图还会活着；只要模型已经切到别的会话，旧的滚动/取页回调就必须弃权。
/// 视图只读这个结果，判定放在 Domain 便于纯函数用例覆盖。
public enum ChatViewOwnership {
    public static func isOwner(sessionId: String?, viewSessionId: String) -> Bool {
        sessionId == viewSessionId
    }
}

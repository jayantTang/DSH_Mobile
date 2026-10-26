import Foundation

/// 本地库里"按会话一份的缓存"的键名。
///
/// 单点定义：写入方（ChatDomain）与删除方（`MessageStore.clear`）必须用同一个
/// 字符串，否则删会话之后正文缓存会留下来。
public enum TranscriptLocalCacheKeys {
    /// 单条步骤正文缓存（JSON，LRU + 总字节上限；见 `StepBodyCache`）。
    public static func stepBodies(sessionId: String) -> String {
        "step-body-cache:\(sessionId)"
    }
}

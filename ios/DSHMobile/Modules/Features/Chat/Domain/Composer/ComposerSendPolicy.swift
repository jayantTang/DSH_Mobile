import Foundation

/// 输入区“能不能发”的唯一判据：文字非空，或至少有一张图。
/// 视图只渲染这个结果；判定放在 Domain，便于用纯函数用例覆盖。
public enum ComposerSendPolicy {
    public static func canSend(draft: String, images: [ComposerDraftImage]) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }
}

import Foundation
import Observation

/// 输入区状态：草稿、待发图片、插入/排队。
///
/// 从 `ChatModel` 拆出的第一块。ChatModel 保留同名转发属性与方法，UI 调用点不变；
/// 真正的存储在这里，会话切换由 ChatModel 调 `load` / `stash`。
///
/// 拆它的理由：这三样只由输入区改写，却和会话生命周期、网络、时间线一起挤在
/// 一个 3.8k 行的类型里；拆出来之后“草稿属于哪个会话”只有一个所有者。
/// 输入区里的一张待发图片。
///
/// `preview` 是**不透明句柄**（iOS 上是 `UIImage`），领域层不认识它，也不认识 UIKit；
/// 位图由界面层在加入时造好，只有 `Composer` 的缩略图会读它。
public struct ComposerDraftImage: Identifiable {
    public let id = UUID()
    public let mediaType: String
    public let base64: String
    public let name: String
    public let preview: AnyObject

    public init(mediaType: String, base64: String, name: String, preview: AnyObject) {
        self.mediaType = mediaType
        self.base64 = base64
        self.name = name
        self.preview = preview
    }
}

/// 半写好的消息，按会话保存。
public struct ComposerDraft {
    public var text: String = ""
    public var images: [ComposerDraftImage] = []

    public init(text: String = "", images: [ComposerDraftImage] = []) {
        self.text = text
        self.images = images
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }
}

@MainActor
@Observable
final class ComposerState {

    public var draft: String = ""
    public var images: [ComposerDraftImage] = []
    public var steerNext: Bool = false

    /// 每个会话自己的草稿：换会话不串味。
    private var drafts: [String: ComposerDraft] = [:]

    public init() {}

    /// 切到某个会话时装入它的草稿。
    public func load(sessionId: String) {
        draft = drafts[sessionId]?.text ?? ""
        images = drafts[sessionId]?.images ?? []
    }

    /// 离开某个会话时把当前草稿存回去（空草稿从表里删掉，不留空条目）。
    public func stash(sessionId: String) {
        let current = ComposerDraft(text: draft, images: images)
        if current.isEmpty {
            drafts.removeValue(forKey: sessionId)
        } else {
            drafts[sessionId] = current
        }
    }

    /// 把一段文本/图片记到指定会话（不改变当前输入区）。
    public func store(text: String, images: [ComposerDraftImage], for sessionId: String) {
        let value = ComposerDraft(text: text, images: images)
        if value.isEmpty {
            drafts.removeValue(forKey: sessionId)
        } else {
            drafts[sessionId] = value
        }
    }

    /// 发送失败：把内容记回原会话；仍停在原会话时同时放回输入区。
    public func restore(text: String, images: [ComposerDraftImage],
                        for sessionId: String, isCurrent: Bool) {
        store(text: text, images: images, for: sessionId)
        guard isCurrent else { return }
        if draft.isEmpty { draft = text }
        if self.images.isEmpty { self.images = images }
    }

    /// 丢弃某个会话的草稿（发送成功后调用）。
    public func discard(sessionId: String) {
        drafts.removeValue(forKey: sessionId)
    }

    /// 断开连接/关会话时清空全部草稿与当前输入区。
    public func reset() {
        drafts.removeAll()
        draft = ""
        images = []
        steerNext = false
    }
}

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
///
/// 一张待发图片实际有两份字节（SR-02.07 / SR-02.11）：
///
/// - `mediaType` / `base64` / `preview` 描述**预览**：发送时交给 Host 归一化，
///   模型只收到这一份。
/// - `originalData` 是选图时拿到的**原图字节**，原样保留；发送时交给连接器存成
///   「原图变体」，用户点「查看原图」才下载。超限或不能解码时它转成普通文件
///   （`originalDisposition == .sendAsFile`），绝不冒充原图。
///
/// `previewBytes` / `originalBytes` 是两份字节的实际长度（重试与界面显示都用它，
/// 不再从 base64 反复解码）。`uploadState` 是发送过程中**唯一**的上传状态。
public struct ComposerDraftImage: Identifiable {
    public let id = UUID()
    public let mediaType: String
    public let base64: String
    public let name: String
    public let preview: AnyObject

    // MARK: 原图变体（0 字节表示没有原图字节，不是"原图大小为 0"）

    /// 原图字节（选图时的 `Data`），原样保留；没有原图时为 nil。
    public let originalData: Data?
    /// 原图的媒体类型（按字节嗅探或按文件名推断）。
    public let originalMediaType: String?
    /// 原图落盘时用的名字；通常与 `name` 同扩展名，与预览不同名时以本条为准。
    public let originalName: String?
    /// 预览 JPEG 的实际字节数。
    public let previewBytes: Int
    /// 原图实际字节数；没有原图时为 nil。
    public let originalBytes: Int?
    /// 原图该怎么发：保留为原图变体 / 作为普通文件发送 / 没有原图。
    public let originalDisposition: OriginalDisposition
    /// 本次发送的上传状态；发送失败恢复草稿时回到 `.pending`。
    public var uploadState: UploadState

    /// 原图的去向。
    public enum OriginalDisposition: String, Equatable, Sendable {
        /// 在上限内：作为原图变体保存，模型仍只收到预览。
        case keep
        /// 超过 20 MiB 或无法生成预览：作为普通文件发送，可下载但不是"原图变体"。
        case sendAsFile
        /// 没有原图字节（只拿到预览）或旧连接器不支持：只发预览。
        case unavailable
    }

    /// 一张图片的上传状态。进度来自真实阶段（写暂存文件 / 已落盘 / 已提交），
    /// 不是动画。
    public enum UploadState: Equatable, Sendable {
        case pending
        case uploading(progress: Double)
        case failed(message: String)
    }

    public init(
        mediaType: String,
        base64: String,
        name: String,
        preview: AnyObject,
        originalData: Data? = nil,
        originalMediaType: String? = nil,
        originalName: String? = nil,
        previewBytes: Int? = nil,
        originalBytes: Int? = nil,
        originalDisposition: OriginalDisposition? = nil,
        uploadState: UploadState = .pending
    ) {
        self.mediaType = mediaType
        self.base64 = base64
        self.name = name
        self.preview = preview
        self.originalData = originalData
        self.originalMediaType = originalMediaType
        self.originalName = originalName
        // 既有调用点只给 base64：预览字节数从它算，语义与老字段保持一致。
        self.previewBytes = previewBytes ?? Data(base64Encoded: base64)?.count ?? 0
        self.originalBytes = originalBytes ?? originalData?.count
        if let originalDisposition {
            self.originalDisposition = originalDisposition
        } else {
            self.originalDisposition = originalData == nil ? .unavailable : .keep
        }
        self.uploadState = uploadState
    }

    /// 预览字节，按需从 base64 解出（发送前写暂存文件用）。
    public var previewData: Data? {
        Data(base64Encoded: base64)
    }

    /// 原图是否要作为变体保存（有字节且未超限）。
    public var keepsOriginal: Bool {
        originalDisposition == .keep && originalData != nil
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

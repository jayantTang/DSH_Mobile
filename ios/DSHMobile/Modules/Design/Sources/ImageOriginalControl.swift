import Foundation

/// 会话图片的"原图"入口：状态 + 三个动作，交给全屏查看器画。
///
/// 为什么把状态与动作做成值类型而不是一个协议：查看器（`ImagePreview`）在共享
/// 呈现层，不能反向依赖任何功能域；而原图下载归 `AttachmentImages`（会话）或
/// `FeedbackAttachmentCache`（回信）所有。视图只认识这份"当前是什么状态、点下去
/// 做什么"，状态的所有者仍是各自的缓存。
///
/// 状态集合刻意与需求 SR-02.11 对齐：
/// - `idle`：**有**原图、还没下载——按钮上必须带大小，用户才知道要下多少；
/// - `downloading`：进度可见、可取消；
/// - `failed`：保留预览，按钮变成可重试；
/// - `ready`：已经在看原图，入口消失；
/// - `unavailable`：原图缺失/被清理/旧数据只有一份——明说，不弹错、不重试。
public struct ImagePreviewOriginal {
    public enum Phase: Equatable, Sendable {
        case idle
        case downloading(received: Int, total: Int?)
        case failed
        case ready
        case unavailable

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    public var phase: Phase
    /// 原图字节数，用于按钮上的大小；未知时按钮只写「原图」。
    public var bytes: Int?
    public var onRequest: () -> Void
    public var onCancel: () -> Void
    /// 已就绪（或磁盘上已有）的原图字节；保存原图走这一份，绝不重新编码。
    public var data: () -> Data?
    /// 「保存原图」在还没下载时按需取回：触发下载并等到字节可用，失败返回 nil。
    ///
    /// 需求 SR-02.11：保存原图点击时按需下载，用户不必先点过「原图」。
    public var loadForSaving: () async -> Data?

    public init(phase: Phase,
                bytes: Int? = nil,
                onRequest: @escaping () -> Void,
                onCancel: @escaping () -> Void = {},
                data: @escaping () -> Data? = { nil },
                loadForSaving: @escaping () async -> Data? = { nil }) {
        self.phase = phase
        self.bytes = bytes
        self.onRequest = onRequest
        self.onCancel = onCancel
        self.data = data
        self.loadForSaving = loadForSaving
    }

    /// 「原图 12.3 MB」/「原图」。
    public var title: String {
        guard let bytes, bytes > 0 else { return String(localized: "原图") }
        return String(localized: "原图 \(ImageVariantSize.text(bytes))")
    }
}

/// 图片变体的大小显示（与信件附件同一口径：小于 1 KB 说字节，否则 KB/MB）。
public enum ImageVariantSize {
    public static func text(_ bytes: Int) -> String {
        let value = max(0, bytes)
        if value < 1024 {
            return String(localized: "\(value) 字节")
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: Int64(value))
    }
}

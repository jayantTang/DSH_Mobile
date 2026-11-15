#if os(iOS)
import DSHChatDomain
import UIKit
import UniformTypeIdentifiers

/// 从选取结果往待发队列里加图片（025 阶段4b：这一半留在界面层）。
///
/// 为什么要分家：缩放（`UIGraphicsImageRenderer`）与 JPEG 编码都要 UIKit，而
/// `DSHChatDomain` 不许 import UIKit（边界契约 C2），`swift build` 还要在 macOS 上过。
/// 领域层只收"媒体类型 + base64 + 名字 + 不透明预览句柄 + 原图字节"
/// （`ChatModel.DraftImage`）。
///
/// 预览与原图的分工（契约 §2.2）：
/// - 预览：最长边 ≤ 2560、总像素 ≤ 4,000,000，JPEG 0.85。模型只收到这一份。
/// - 原图：picker 给的 `Data` **原样保留**，不重编码；超过 20 MiB 或无法生成预览时
///   标成 `.sendAsFile`，由发送路径走普通文件，不冒充原图。
extension ChatModel {

    /// 一次选取里的一张图：原始字节 + 已解码位图。
    ///
    /// 两个字段都要：`data` 是原图（原样保留），`image` 只用来生成预览缩略图。
    /// 分开传是为了让"拿到 `Data` 后立刻丢掉"的那条老路不再出现——那正是原图
    /// 变体做不出来的原因。
    public struct DraftImageSource {
        public let data: Data
        public let image: UIImage

        public init(data: Data, image: UIImage) {
            self.data = data
            self.image = image
        }
    }

    /// Adds pictures to the next prompt, keeping the bytes the picker handed us.
    ///
    /// 预览按上限缩小并以 JPEG 0.85 重编码；原图字节不经过任何编码器。
    public func addDraftImages(_ items: [DraftImageSource], names: [String] = []) {
        var prepared: [DraftImage] = []
        for (index, item) in items.enumerated() {
            let name = index < names.count
                ? names[index]
                : "photo-\(draftImages.count + index + 1).jpg"
            prepared.append(Self.preparedDraft(item, name: name))
        }
        addDraftImages(prepared)
    }

    /// 兼容入口：只有 `UIImage` 时没有"原始字节"，原图取该图的**全分辨率 JPEG 重编码**。
    ///
    /// 这是兼容路径，不是首选：HEIC 等原始格式已经被系统解码过一次，重编码后的
    /// "原图"与用户选的那份字节不完全相同。新调用点请用
    /// ``addDraftImages(_:names:)-(DraftImageSource)`` 把 `Data` 一起交进来。
    public func addDraftImages(_ images: [UIImage], names: [String] = []) {
        let sources = images.map { image in
            DraftImageSource(
                data: image.jpegData(compressionQuality: 1) ?? Data(),
                image: image
            )
        }
        addDraftImages(sources, names: names)
    }

    // MARK: - 预览 / 原图

    private static func preparedDraft(_ source: DraftImageSource, name: String) -> DraftImage {
        let previewImage = downscaledPreview(source.image)
        let preview: (data: Data, mediaType: String)?
        if let jpeg = previewImage.jpegData(compressionQuality: CGFloat(ComposerImagePolicy.previewJPEGQuality)) {
            preview = (jpeg, "image/jpeg")
        } else if let png = previewImage.pngData() {
            // JPEG 编码失败时的兜底：仍然是真预览，不是原图冒充。
            preview = (png, "image/png")
        } else {
            preview = nil
        }

        let originalData = source.data.isEmpty ? nil : source.data
        let originalMediaType = mediaType(for: originalData, name: name)
        let disposition: DraftImage.OriginalDisposition
        if originalData == nil {
            disposition = .unavailable
        } else if preview == nil {
            // 预览生成失败：不静默丢草稿，保留原图并走文件发送。
            disposition = .sendAsFile
        } else {
            disposition = ComposerImagePolicy.originalDisposition(byteCount: originalData!.count)
        }

        return DraftImage(
            mediaType: preview?.mediaType ?? "image/jpeg",
            base64: preview?.data.base64EncodedString() ?? "",
            name: name,
            preview: previewImage,
            originalData: originalData,
            originalMediaType: originalMediaType,
            originalName: originalName(name, mediaType: originalMediaType),
            previewBytes: preview?.data.count ?? 0,
            originalBytes: originalData?.count,
            originalDisposition: disposition
        )
    }

    /// 把位图缩到预览上限内；已经在限内就原样返回（只重编码，不缩放）。
    ///
    /// 渲染器必须 `scale = 1`：默认跟随屏幕 3x，会把"2560 像素"悄悄变成 7680。
    private static func downscaledPreview(_ image: UIImage) -> UIImage {
        let pixels = pixelSize(of: image)
        guard let target = ComposerImagePolicy.previewPixelSize(
            sourceWidth: pixels.width, sourceHeight: pixels.height
        ) else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: target.width, height: target.height), format: format
        ).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        }
    }

    private static func pixelSize(of image: UIImage) -> (width: Int, height: Int) {
        if let cg = image.cgImage {
            return (cg.width, cg.height)
        }
        return (
            max(1, Int((image.size.width * image.scale).rounded())),
            max(1, Int((image.size.height * image.scale).rounded()))
        )
    }

    // MARK: - 原图媒体类型与文件名

    /// 按字节嗅探原图格式（picker 的 `Data` 没有可靠的扩展名）。
    static func mediaType(for data: Data?, name: String) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(16))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 8,
           Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) {
                return "image/heic"
            }
            if ["avif", "avis"].contains(brand) { return "image/avif" }
        }
        if bytes.count >= 4, Array(bytes[0..<4]) == Array("GIF8".utf8) {
            return "image/gif"
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return "image/webp"
        }
        // 嗅探不出来才看名字；两者都没有就交给连接器按字节判断。
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    /// 原图落盘用的名字：扩展名跟着真实格式走，不把 HEIC 存成 `.jpg`。
    static func originalName(_ name: String, mediaType: String?) -> String {
        guard let mediaType, let ext = fileExtension(for: mediaType) else { return name }
        let current = (name as NSString).pathExtension.lowercased()
        guard current != ext else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? "photo.\(ext)" : "\(base).\(ext)"
    }

    private static func fileExtension(for mediaType: String) -> String? {
        switch mediaType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/avif": return "avif"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return UTType(mimeType: mediaType)?.preferredFilenameExtension
        }
    }
}
#endif

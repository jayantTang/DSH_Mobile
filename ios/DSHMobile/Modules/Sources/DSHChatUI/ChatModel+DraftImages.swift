#if os(iOS)
import DSHChatDomain
import UIKit

/// 从 `UIImage` 往待发队列里加图片（025 阶段4b：这一半留在界面层）。
///
/// 为什么要分家：缩放（`UIGraphicsImageRenderer`）与 JPEG 编码都要 UIKit，而
/// `DSHChatDomain` 不许 import UIKit（边界契约 C2），`swift build` 还要在 macOS 上过。
/// 领域层只收"媒体类型 + base64 + 名字 + 不透明预览句柄"（`ChatModel.DraftImage`）。
/// 公开名字与搬迁前一致（`ChatModel.addDraftImages(_:names:)`），调用点一字未改。
extension ChatModel {

    /// Adds pictures to the next prompt.
    ///
    /// Downscaled first: a phone photo is many megabytes, and the Host will
    /// shrink it anyway — sending the original just makes the upload slow.
    public func addDraftImages(_ images: [UIImage], names: [String] = []) {
        var prepared: [DraftImage] = []
        for (index, image) in images.enumerated() {
            let resized = Self.downscaledForDraft(image, maximumEdge: 2048)
            guard let data = resized.jpegData(compressionQuality: 0.85) else { continue }
            let name = index < names.count ? names[index] : "photo-\(draftImages.count + index + 1).jpg"
            prepared.append(
                DraftImage(
                    mediaType: "image/jpeg",
                    base64: data.base64EncodedString(),
                    name: name,
                    preview: resized
                )
            )
        }
        addDraftImages(prepared)
    }

    /// Scales an image down so its longest edge fits `maximumEdge`.
    private static func downscaledForDraft(_ image: UIImage, maximumEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maximumEdge else { return image }
        let scale = maximumEdge / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
#endif

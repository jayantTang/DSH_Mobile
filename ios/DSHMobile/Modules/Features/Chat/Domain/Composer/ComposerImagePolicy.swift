import Foundation

/// 待发图片的尺寸与上限策略（契约 §2.2 / SR-02.07）。
///
/// 放在领域层而不是 UIKit 扩展里，是为了让"多大算预览、什么时候转文件"能被
/// `swift test`（macOS，没有 UIKit）直接验证：位图缩放与 JPEG 编码留在界面层，
/// 这里只回答**目标像素尺寸**与**原图去向**两个纯问题。
public enum ComposerImagePolicy {

    /// 预览最长边上限（像素）。
    public static let previewMaxEdge = 2560
    /// 预览总像素上限（400 万）。
    public static let previewMaxPixels = 4_000_000
    /// 预览 JPEG 质量。
    public static let previewJPEGQuality = 0.85
    /// 原图上限 20 MiB；**超过**才转普通文件，正好 20 MiB 仍按原图保留。
    public static let originalMaxBytes = 20 * 1024 * 1024

    /// 预览是否已经落在上限内（不需要缩放）。
    public static func fitsPreview(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        guard width <= previewMaxEdge, height <= previewMaxEdge else { return false }
        return Int64(width) * Int64(height) <= Int64(previewMaxPixels)
    }

    /// 预览的目标像素尺寸；已经在限内时返回 `nil`（不重编码尺寸）。
    ///
    /// 两个约束同时生效：最长边 ≤ 2560，且总像素 ≤ 4,000,000。取两者中更小的
    /// 缩放比，再向下取整，保证结果**不会因为进位越过上限**。
    public static func previewPixelSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int)? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        if fitsPreview(width: sourceWidth, height: sourceHeight) { return nil }
        let longest = Double(max(sourceWidth, sourceHeight))
        let pixels = Double(sourceWidth) * Double(sourceHeight)
        let edgeScale = Double(previewMaxEdge) / longest
        let pixelScale = (Double(previewMaxPixels) / pixels).squareRoot()
        let scale = min(1, min(edgeScale, pixelScale))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded(.down)))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded(.down)))
        return (width, height)
    }

    /// 原图字节该保留成变体，还是作为普通文件发送；没有字节时不可用。
    public static func originalDisposition(byteCount: Int) -> ComposerDraftImage.OriginalDisposition {
        guard byteCount > 0 else { return .unavailable }
        return byteCount > originalMaxBytes ? .sendAsFile : .keep
    }
}

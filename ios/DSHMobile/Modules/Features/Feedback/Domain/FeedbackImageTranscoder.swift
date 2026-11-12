import CoreGraphics
import Foundation
import ImageIO
import RelayKit
import UniformTypeIdentifiers

/// 一份编好的图片字节（预览或原图）。
public struct FeedbackEncodedImage: Sendable, Equatable {
    public let data: Data
    public let contentType: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(data: Data, contentType: String, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.contentType = contentType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var byteSize: Int { data.count }
}

/// 一张图的两份产物：预览必有，原图可能没有（超出一切候选步骤）。
public struct FeedbackPreparedImage: Sendable, Equatable {
    public let preview: FeedbackEncodedImage
    /// `nil` = 这张图只能以预览形态发出（候选步骤全部超预算）。
    public let original: FeedbackEncodedImage?
    /// 原图是不是**逐字节**沿用了源文件（没有重编码）。
    public let originalIsPassthrough: Bool

    public init(preview: FeedbackEncodedImage, original: FeedbackEncodedImage?,
                originalIsPassthrough: Bool) {
        self.preview = preview
        self.original = original
        self.originalIsPassthrough = originalIsPassthrough
    }
}

public enum FeedbackImageTranscoderError: Error, Equatable {
    /// 不是 ImageIO 能读的图片。
    case unsupportedFormat
    /// 所有候选步骤都编不出来 / 都超预算。
    case encodeFailed
}

/// 用 ImageIO 执行 ``FeedbackImageBudget`` 的候选步骤：预览按像素长边取样，原图只在
/// 需要时整图重编码。
///
/// 三条硬约束（设计 §2.2）：
///
/// 1. **像素尺寸**来自 ``CGImageSource``，不经过 UIImage / 屏幕 scale；预览用
///    `CGImageSourceCreateThumbnailAtIndex`（不整图解码）。
/// 2. 两份产物都**不带 EXIF/GPS**：写图时只给质量参数，属性字典里没有任何源元数据。
/// 3. 一张一张串行处理，外层 `autoreleasepool`；重活放在 detached 任务里，不占主线程。
public enum FeedbackImageTranscoder {

    /// 把用户选的一张图编成"预览 + 可选原图"。
    ///
    /// - `limits`：服务端下发的上限（`maxFileBytes` 就是原图的预算）；
    /// - 预览预算固定是 ``FeedbackImageBudget/previewByteLimit``（512 KiB）。
    public static func prepare(data: Data, name: String,
                               limits: FeedbackAttachmentLimits) async throws -> FeedbackPreparedImage {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try encodeAll(data: data, name: name, limits: limits)
            }
        }.value
    }

    // MARK: - 实现

    private static func encodeAll(data: Data, name: String,
                                  limits: FeedbackAttachmentLimits) throws -> FeedbackPreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { throw FeedbackImageTranscoderError.unsupportedFormat }

        let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw FeedbackImageTranscoderError.unsupportedFormat
        }
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let sourceEdge = max(pixelWidth, pixelHeight)

        // 预览：不到 512 KiB 不进缓存表之外的路径，永远重编码（顺带丢掉元数据）。
        let previewSteps = FeedbackImageBudget.clamped(
            FeedbackImageBudget.previewSteps(hasAlpha: hasAlpha), sourceEdge: sourceEdge)
        guard let previewFit = FeedbackImageBudget.firstFitting(
            steps: previewSteps, byteLimit: FeedbackImageBudget.previewByteLimit,
            encode: { encode(source, step: $0) })
        else { throw FeedbackImageTranscoderError.encodeFailed }
        let preview = try describe(previewFit.data,
                                   contentType: previewFit.contentType
                                       ?? (hasAlpha ? "image/png" : "image/jpeg"))

        // 原图：能直通就直通（≤ 单文件上限、无 EXIF/GPS、orientation 为 1）。
        let allowsPassthrough = canPassThrough(data: data, properties: properties,
                                               limits: limits)
        let steps = hasAlpha
            ? FeedbackImageBudget.alphaOriginalSteps(pixelWidth: pixelWidth,
                                                     pixelHeight: pixelHeight,
                                                     allowsPassthrough: allowsPassthrough)
            : FeedbackImageBudget.originalSteps(pixelWidth: pixelWidth,
                                                pixelHeight: pixelHeight,
                                                allowsPassthrough: allowsPassthrough)
        guard let originalFit = FeedbackImageBudget.firstFitting(
            steps: steps, byteLimit: limits.maxFileBytes,
            encode: { step in
                step.passthrough ? data : encode(source, step: step)
            })
        else {
            // 原图放不进预算：只发预览（不假装发了一张高清图）。
            return FeedbackPreparedImage(preview: preview, original: nil,
                                         originalIsPassthrough: false)
        }
        if originalFit.step.passthrough {
            guard let contentType = Self.contentTypeOfSource(source) else {
                throw FeedbackImageTranscoderError.unsupportedFormat
            }
            let original = FeedbackEncodedImage(data: data, contentType: contentType,
                                                pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            return FeedbackPreparedImage(preview: preview, original: original,
                                         originalIsPassthrough: true)
        }
        let contentType = originalFit.step.contentType
            ?? (hasAlpha ? "image/png" : "image/jpeg")
        let original = try describe(originalFit.data, contentType: contentType)
        return FeedbackPreparedImage(preview: preview, original: original,
                                     originalIsPassthrough: false)
    }

    /// 直通的三个条件缺一不可：≤ 单文件上限、**没有**可识别用户的元数据、orientation 为 1。
    ///
    /// 注意 ImageIO 自己写出来的图片总带一个只含 `PixelXDimension` / `PixelYDimension`
    /// 的 EXIF 块；那不算用户元数据（不含拍摄时间、地点、机型），所以按"有没有**除尺寸
    /// 以外**的 EXIF/TIFF 键"判，而不是"有没有 EXIF 块"。
    private static func canPassThrough(data: Data, properties: [CFString: Any],
                                       limits: FeedbackAttachmentLimits) -> Bool {
        guard data.count <= limits.maxFileBytes else { return false }
        if properties[kCGImagePropertyGPSDictionary] != nil { return false }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int,
           orientation != 1 {
            return false
        }
        return !hasUserMetadata(properties)
    }

    /// 有没有"可能带着用户信息"的元数据。
    ///
    /// 判法是**白名单**而不是只查几个已知字典：只要出现白名单之外的顶层键（IPTC、8BIM、
    /// CIFF、DNG、MakerApple、JFIF、以及将来 ImageIO 新加的字典）就当作带用户信息；
    /// 然后 EXIF / PNG 内部也只允许尺寸与色彩这几项。XMP 各厂商存在不同容器里，
    /// 白名单法不需要逐个枚举就能把它一并挡掉（评审 P2-7）。
    private static func hasUserMetadata(_ properties: [CFString: Any]) -> Bool {
        let allowedTopLevel: Set<String> = [
            "PixelWidth", "PixelHeight", "Depth", "ColorModel", "ProfileName", "HasAlpha",
            "{Exif}", "{PNG}", "{JFIF}",
        ]
        if properties.keys.contains(where: { !allowedTopLevel.contains($0 as String) }) {
            return true
        }
        let sizesOnly: Set<String> = ["PixelXDimension", "PixelYDimension"]
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           exif.keys.contains(where: { !sizesOnly.contains($0 as String) }) {
            return true
        }
        // JFIF 只有密度与版本这类格式事实；出现别的键同样按用户内容处理。
        let jfifFormatFacts: Set<String> = ["DensityUnit", "JFIFVersion", "XDensity", "YDensity",
                                           "IsProgressive"]
        if let jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any],
           jfif.keys.contains(where: { !jfifFormatFacts.contains($0 as String) }) {
            return true
        }
        // PNG 的"格式事实"只有这几项（色彩空间与交错方式）；文本块一律算用户内容。
        let pngFormatFacts: Set<String> = [
            "sRGBIntent", "Gamma", "InterlaceType", "Chromaticities",
        ]
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           png.keys.contains(where: { !pngFormatFacts.contains($0 as String) }) {
            return true
        }
        return false
    }

    /// 执行一步：按 `edge` 取样（不整图解码），需要时去 alpha，再按类型编码。
    private static func encode(_ source: CGImageSource,
                               step: FeedbackImageStep) -> Data? {
        autoreleasepool {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, step.edge),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                 options as CFDictionary)
            else { return nil }
            if step.flattenAlpha || step.quality != nil {
                guard let flattened = flatten(image) else { return nil }
                image = flattened
            }
            return encode(image, quality: step.quality)
        }
    }

    /// 压到白底（去掉 alpha）：透明区域变白，与"白底扁平化"的语义一致。
    private static func flatten(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 编码：`quality == nil` 走 PNG（无损），否则走 JPEG。
    private static func encode(_ image: CGImage, quality: CGFloat?) -> Data? {
        let type: UTType = quality == nil ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 从编好的字节里读**实际**像素尺寸与类型（不靠我们自己的推算）。
    private static func describe(_ data: Data, contentType: String) throws -> FeedbackEncodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { throw FeedbackImageTranscoderError.encodeFailed }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return FeedbackEncodedImage(data: data, contentType: contentType,
                                    pixelWidth: width, pixelHeight: height)
    }

    private static func contentTypeOfSource(_ source: CGImageSource) -> String? {
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return nil }
        return type.preferredMIMEType
    }
}

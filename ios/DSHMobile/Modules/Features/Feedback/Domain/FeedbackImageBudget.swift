import CoreGraphics
import Foundation

/// 一次图像编码的**候选步骤**：边长上限、质量、要不要去掉 alpha。
///
/// 所有数字（512 KiB、2560、2048、q85…q50、8 MiB）都只在 ``FeedbackImageBudget``
/// 里出现一次；UI 与发送队列不写第二份。
public struct FeedbackImageStep: Equatable, Sendable {
    /// 长边像素上限；`min(edge, 源长边)` 才是实际取样尺寸（小图不放大）。
    public let edge: Int
    /// `nil` = 无损（PNG）；有值 = 有损（JPEG）的质量。
    public let quality: CGFloat?
    /// `true` = 先压到白底再去 alpha（只有预览的最后一步用它）。
    public let flattenAlpha: Bool
    /// `true` = 直接使用源字节，不重编码（原图的无损直通）。
    public let passthrough: Bool

    public init(edge: Int, quality: CGFloat?, flattenAlpha: Bool, passthrough: Bool = false) {
        self.edge = edge
        self.quality = quality
        self.flattenAlpha = flattenAlpha
        self.passthrough = passthrough
    }

    /// 原图的无损直通：源字节已经满足预算与"无 EXIF/GPS"时用它。
    public static let passthrough = FeedbackImageStep(edge: 0, quality: nil,
                                                      flattenAlpha: false, passthrough: true)

    /// 这一步编出来的类型；`passthrough` 沿用源字节的类型，所以是 `nil`。
    public var contentType: String? {
        if passthrough { return nil }
        return (flattenAlpha || quality != nil) ? "image/jpeg" : "image/png"
    }
}

/// 选中了一步之后的产物：那一步 + 编出来的字节。
public struct FeedbackImageFit: Equatable, Sendable {
    public let step: FeedbackImageStep
    public let data: Data

    public init(step: FeedbackImageStep, data: Data) {
        self.step = step
        self.data = data
    }

    /// 产物类型；`passthrough` 时为 `nil`（沿用源类型）。
    public var contentType: String? { step.contentType }
}

/// 编码预算策略（**纯函数**）：按顺序试候选步骤，返回第一个不超过预算的产物。
///
/// 它不认识 UIKit、UIImage、屏幕 scale，也不做 I/O——只做"顺序 + 比较"。真正的编码
/// 由 ``FeedbackImageTranscoder`` 用 ImageIO 执行，边界由伪编码器在这里精确测。
public enum FeedbackImageBudget {
    /// 预览的字节上限（512 KiB）：列表与缩略图只读这一份。
    public static let previewByteLimit = 512 * 1024
    /// 预览的起始长边（真实像素，不是 point）。
    public static let previewMaxEdge = 2560
    /// 预览的最低长边：再小就只剩马赛克了（alpha 扁平化那一步也用它）。
    public static let previewMinEdge = 1024

    /// 预览候选表。
    ///
    /// - 无 alpha：JPEG `2560/q85 → 2560/q75 → 2560/q65 → 2560/q55 → 2048/q55 →
    ///   1600/q55 → 1280/q55 → 1024/q55`；
    /// - 有 alpha：PNG `2560 → 2048 → 1600 → 1280 → 1024`，仍超预算时最后一步是
    ///   "白底扁平化 + JPEG 1024/q55"（设计 §9 决策点 A：保 alpha 与上限，必要时缩边）。
    public static func previewSteps(hasAlpha: Bool) -> [FeedbackImageStep] {
        if hasAlpha {
            var steps = [2560, 2048, 1600, 1280, 1024].map {
                FeedbackImageStep(edge: $0, quality: nil, flattenAlpha: false)
            }
            steps.append(FeedbackImageStep(edge: previewMinEdge, quality: 0.55, flattenAlpha: true))
            return steps
        }
        return [(2560, 0.85), (2560, 0.75), (2560, 0.65), (2560, 0.55),
                (2048, 0.55), (1600, 0.55), (1280, 0.55), (1024, 0.55)].map {
            FeedbackImageStep(edge: $0.0, quality: $0.1, flattenAlpha: false)
        }
    }

    /// 原图候选表。
    ///
    /// - 可以直通（≤ 单文件上限、无 EXIF/GPS、orientation 为 1）时第一步是
    ///   ``FeedbackImageStep/passthrough``；
    /// - 否则在**原像素尺寸**下 `q95 → q92 → q90 → q85 → q80 → q75 → q70 → q65 → q60 →
    ///   q55 → q50`；
    /// - 还超预算就按 10% 步长缩边，质量固定 0.5（最后手段，设计 §9 决策点 A）；
    /// - alpha 原图全程走 PNG（不转 JPEG），超预算时同样按 10% 步长缩边。
    public static func originalSteps(pixelWidth: Int, pixelHeight: Int,
                                     allowsPassthrough: Bool) -> [FeedbackImageStep] {
        let longEdge = max(pixelWidth, pixelHeight, 1)
        var steps: [FeedbackImageStep] = allowsPassthrough ? [.passthrough] : []
        let shrinkFactors: [CGFloat] = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2]
        steps += [0.95, 0.92, 0.9, 0.85, 0.8, 0.75, 0.7, 0.65, 0.6, 0.55, 0.5].map {
            FeedbackImageStep(edge: longEdge, quality: $0, flattenAlpha: false)
        }
        steps += shrinkFactors.map {
            FeedbackImageStep(edge: Int((CGFloat(longEdge) * $0).rounded(.down)),
                              quality: 0.5, flattenAlpha: false)
        }
        return steps
    }

    /// 保留 alpha 的 PNG 原图候选（无质量参数，只能缩边）。
    public static func alphaOriginalSteps(pixelWidth: Int, pixelHeight: Int,
                                         allowsPassthrough: Bool) -> [FeedbackImageStep] {
        let longEdge = max(pixelWidth, pixelHeight, 1)
        var steps: [FeedbackImageStep] = allowsPassthrough ? [.passthrough] : []
        steps.append(FeedbackImageStep(edge: longEdge, quality: nil, flattenAlpha: false))
        steps += [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2].map {
            FeedbackImageStep(edge: Int((CGFloat(longEdge) * $0).rounded(.down)),
                              quality: nil, flattenAlpha: false)
        }
        return steps
    }

    /// 把候选步骤的边长夹到源图长边之内：小图不放大（输出尺寸就是源尺寸）。
    public static func clamped(_ steps: [FeedbackImageStep], sourceEdge: Int) -> [FeedbackImageStep] {
        steps.map { step in
            guard !step.passthrough, step.edge > sourceEdge else { return step }
            return FeedbackImageStep(edge: sourceEdge, quality: step.quality,
                                     flattenAlpha: step.flattenAlpha)
        }
    }

    /// 按顺序试，返回第一个 `data.count <= byteLimit` 的产物；编不出来（`nil`）就试下一档。
    ///
    /// 全部放不下返回 `nil`——调用方据此**如实失败**（"这张图处理失败"），不许静默发出
    /// 一份超预算的字节。
    public static func firstFitting(steps: [FeedbackImageStep], byteLimit: Int,
                                    encode: (FeedbackImageStep) -> Data?) -> FeedbackImageFit? {
        for step in steps {
            guard let data = encode(step) else { continue }
            if data.count <= byteLimit {
                return FeedbackImageFit(step: step, data: data)
            }
        }
        return nil
    }
}

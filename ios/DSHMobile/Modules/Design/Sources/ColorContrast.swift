import Foundation

/// WCAG 2.1 对比度计算（纯函数，给颜色 token 的回归单测用）。
///
/// 参考：相对亮度按 sRGB 线性化后加权（0.2126 R + 0.7152 G + 0.0722 B），
/// 对比度 = (L1 + 0.05) / (L2 + 0.05)。正文门槛 4.5:1（AA）。
public enum ColorContrast {

    /// 一档 sRGB 通道的线性化（WCAG 定义）。
    public static func linearized(_ channel: Double) -> Double {
        channel <= 0.03928
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// `0xRRGGBB` 的相对亮度（0…1）。
    public static func relativeLuminance(_ hex: UInt32) -> Double {
        let r = linearized(Double((hex >> 16) & 0xFF) / 255)
        let g = linearized(Double((hex >> 8) & 0xFF) / 255)
        let b = linearized(Double(hex & 0xFF) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// 前景/背景的对比度（1…21）。
    public static func ratio(_ foreground: UInt32, on background: UInt32) -> Double {
        let a = relativeLuminance(foreground)
        let b = relativeLuminance(background)
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG AA 正文门槛。
    public static let minimumBodyRatio = 4.5
}

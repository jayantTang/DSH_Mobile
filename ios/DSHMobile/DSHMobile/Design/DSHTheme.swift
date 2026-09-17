import SwiftUI

/// The DSH design system, transcribed from the desktop client's tokens.
///
/// The desktop UI is themed by a `--dsw-*` token layer whose alias names carry
/// the intent (`bg-layer-2`, `label-tertiary`, `border-l1`). Reproducing those
/// names rather than inventing new ones is what keeps the phone looking like
/// the same product, and it means a future token change maps mechanically.
///
/// Both appearances are defined here because the desktop client is dual-theme
/// and the phone must follow the system setting the same way.
public enum DSHTheme {

    // MARK: - Surfaces

    /// The window background.
    public static let background = adaptive(light: 0xFFFFFF, dark: 0x151517)
    /// A panel or card sitting on the background.
    public static let layer1 = adaptive(light: 0xFFFFFF, dark: 0x232324)
    /// A nested panel: inputs, list rows, code blocks.
    public static let layer2 = adaptive(light: 0xF9FAFB, dark: 0x2C2C2E)
    /// The most raised surface: popovers, menus.
    public static let layer3 = adaptive(light: 0xF5F6F7, dark: 0x353638)
    /// A dimming scrim behind sheets.
    public static let scrim = Color.black.opacity(0.5)

    // MARK: - Labels

    /// Primary reading colour: message text, titles.
    public static let labelPrimary = adaptive(light: 0x0F1115, dark: 0xF9FAFB)
    /// Supporting text: timestamps, metadata.
    public static let labelSecondary = adaptive(light: 0x61666B, dark: 0xCFD3D6)
    /// Least prominent text: hints and placeholders.
    public static let labelTertiary = adaptive(light: 0x81858C, dark: 0x81858C)
    /// Text on a filled accent, and disabled content.
    public static let labelDimmed = adaptive(light: 0xADB2B8, dark: 0x43454A)
    /// Errors and destructive affordances.
    public static let labelError = adaptive(light: 0xEC1313, dark: 0xF25A5A)

    // MARK: - Borders

    // The three border tokens carry alpha in the low byte (`0xRRGGBBAA`), which
    // is what the desktop token layer does. They must stay the only eight-digit
    // literals in the file: `Color(hex:)` reads eight digits as RGBA, so a
    // six-digit value here would be opaque.

    /// The hairline that separates adjacent rows: 4% black, 6% white.
    public static let border1 = adaptive(light: 0x0000000A, dark: 0xFFFFFF0F)
    /// The standard control outline: 10% black, 12% white.
    public static let border2 = adaptive(light: 0x0000001A, dark: 0xFFFFFF1F)
    /// A stronger outline for focused controls: 12% black, 16% white.
    public static let border3 = adaptive(light: 0x0000001F, dark: 0xFFFFFF29)

    // MARK: - Accents

    /// The DeepSeek blue used for actions and selection.
    /// DeepSeek's brand blue. The app had its own slightly different blue,
    /// which is what made it look adjacent to the official client rather than
    /// of it.
    public static let brand = Color(hex: 0x4D6BFE)
    /// A lighter brand step for dark surfaces.
    public static let brandBright = Color(hex: 0x6B85FF)
    /// A very low-opacity brand wash for selected rows.
    public static let brandSubtle = Color(hex: 0x4D6BFE).opacity(0.14)

    // MARK: - Semantic roles

    /// Success, and completed states.
    public static let success = adaptive(light: 0x22C55E, dark: 0x4ED17E)

    /// Attention that is not a failure — an incomplete attachment set, say.
    ///
    /// DeepSeek blue rather than the amber this token used to be. Amber is the
    /// loudest colour on a phone screen, and it was the last non-brand hue in
    /// the app: a warning that renders as "something is wrong" in a colour the
    /// product does not own reads as a different app.
    public static let attention = Color(hex: 0x4D6BFE)

    /// The usage ramp, in DeepSeek's own blue rather than a traffic-light scale.
    ///
    /// Amber is the loudest colour on a screen and this bar appears on every
    /// row of the session list, which made the app read as a dashboard rather
    /// than as DSH. Depth of blue carries the same "more used" signal without
    /// shouting, and it matches the accent used everywhere else.
    public static let usageLow = Color(hex: 0x7C9BFF)
    public static let usageMid = Color(hex: 0x4D6BFE)
    public static let usageHigh = Color(hex: 0x2A45C8)

    /// Literals in code, kept out of the amber family the rest of the app has
    /// moved away from and distinct from the blue used for keywords.
    public static let syntaxNumber = Color(hex: 0x8B7CFF)
    /// Failure, and destructive states.
    public static let danger = adaptive(light: 0xEF4444, dark: 0xF25A5A)

    // MARK: - Code and diff

    /// The background of an inline or fenced code block.
    public static let codeBackground = adaptive(light: 0xF5F6F7, dark: 0x1B1B1C)
    /// Added lines in a diff.
    public static let diffAdded = adaptive(light: 0xE6FAED, dark: 0x233C2C)
    /// Removed lines in a diff.
    public static let diffRemoved = adaptive(light: 0xFEF2F2, dark: 0x3A1D1D)

    // MARK: - Metrics

    public enum Radius {
        /// Chips and small controls.
        public static let small: CGFloat = 6
        /// Buttons, inputs.
        public static let medium: CGFloat = 10
        /// Cards and code blocks, matching the desktop's 12px.
        public static let large: CGFloat = 12
        /// Sheets and grouped panels.
        public static let panel: CGFloat = 16
    }

    public enum Spacing {
        public static let hairline: CGFloat = 4
        public static let tight: CGFloat = 8
        public static let standard: CGFloat = 12
        public static let loose: CGFloat = 16
        public static let section: CGFloat = 24
    }

    public enum Typography {
        /// Message body: 16/24, matching `--dsw-font-base-16`.
        public static let body = Font.system(size: 16, weight: .regular)
        /// Emphasised body and row titles.
        public static let bodyStrong = Font.system(size: 16, weight: .medium)
        /// Section headings: 20/28.
        public static let title = Font.system(size: 20, weight: .medium)
        /// Screen titles.
        public static let largeTitle = Font.system(size: 22, weight: .semibold)
        /// Supporting metadata.
        public static let caption = Font.system(size: 13, weight: .regular)
        /// The smallest labels, such as badges.
        public static let micro = Font.system(size: 11, weight: .medium)
        /// Code and tool output. The desktop uses a mono stack for these.
        public static let code = Font.system(size: 13, weight: .regular, design: .monospaced)
        /// Inline code inside prose.
        public static let codeInline = Font.system(size: 14, weight: .regular, design: .monospaced)
    }

    // MARK: - Helpers

    /// Builds a colour that follows the system appearance.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark)
                : UIColor(hex: light)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
        #endif
    }
}

extension Color {
    /// Builds a colour from a packed literal: `0xRRGGBB`, or `0xRRGGBBAA` when
    /// the value carries its own alpha.
    ///
    /// Eight digits are read as RGBA rather than as a longer RGB. Reading the
    /// alpha byte as blue is exactly the defect that painted every dark-mode
    /// border bright yellow: `0xFFFFFF0F` is white at 6%, and taking it as RGB
    /// gives `#FFFF0F`.
    init(hex: UInt32, alpha: Double? = nil) {
        let parts = hexRGBA(hex)
        self.init(
            .sRGB,
            red: parts.r,
            green: parts.g,
            blue: parts.b,
            opacity: alpha ?? parts.a
        )
    }
}

/// Splits a packed colour literal into sRGB components in 0…1.
///
/// Shared by all three colour types so a token cannot mean one thing to
/// `Color` and another to `UIColor`.
func hexRGBA(_ hex: UInt32) -> (r: Double, g: Double, b: Double, a: Double) {
    func channel(_ shift: UInt32) -> Double { Double((hex >> shift) & 0xFF) / 255 }
    guard hex > 0xFFFFFF else {
        return (channel(16), channel(8), channel(0), 1)
    }
    return (channel(24), channel(16), channel(8), channel(0))
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32, alpha: Double? = nil) {
        let parts = hexRGBA(hex)
        self.init(
            red: parts.r,
            green: parts.g,
            blue: parts.b,
            alpha: alpha ?? parts.a
        )
    }
}
#else
extension NSColor {
    convenience init(hex: UInt32, alpha: Double? = nil) {
        let parts = hexRGBA(hex)
        self.init(
            srgbRed: parts.r,
            green: parts.g,
            blue: parts.b,
            alpha: alpha ?? parts.a
        )
    }
}
#endif

import SwiftUI
import XCTest
@testable import DSHDesign

/// 色板 token 的取色断言（亮/暗两套）。
///
/// `DSHTheme` 里每个 token 都是 `Color`，取色要靠一个环境才能落地：这里统一走
/// `Color.resolve(in:)`，把 `colorScheme` 放进 `EnvironmentValues`，于是 macOS 与 iOS
/// 一条路径（`NSColor`/`UIColor` 的 appearance 两套写法对 `Color` 的动态色不一定都成立）。
///
/// 断言消息一律 ASCII：check:i18n 扫整棵 Modules 树。
/// 这个文件里的 helper 是同 target 的 `CodeHighlightingTests` 也用的（语法色必须来自这些 token）。
struct TokenRGBA: Equatable, CustomStringConvertible {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    var description: String {
        String(format: "(%.4f, %.4f, %.4f, %.4f)", r, g, b, a)
    }

    func near(_ other: TokenRGBA, within tolerance: Double = 0.002) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance
            && abs(b - other.b) <= tolerance && abs(a - other.a) <= tolerance
    }
}

/// 一个 token 在某套外观下解析出来的值。
func resolvedToken(_ color: Color, _ scheme: ColorScheme) -> TokenRGBA {
    var environment = EnvironmentValues()
    environment.colorScheme = scheme
    let resolved = color.resolve(in: environment)
    return TokenRGBA(r: Double(resolved.red), g: Double(resolved.green),
                     b: Double(resolved.blue), a: Double(resolved.opacity))
}

/// 按 `0xRRGGBB` 三个分量写期望值，省得在断言里散落 `/255`。
func tokenRGB(_ r: UInt32, _ g: UInt32, _ b: UInt32, _ a: Double = 1) -> TokenRGBA {
    TokenRGBA(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255, a: a)
}

final class ThemeTokenTests: XCTestCase {

    // MARK: - 亮暗两套：同一个 token 必须落在两个具体值上

    func test_adaptive_tokens_resolve_differently_in_light_and_dark() {
        let table: [(name: String, color: Color, light: TokenRGBA, dark: TokenRGBA)] = [
            ("background", DSHTheme.background, tokenRGB(0xFF, 0xFF, 0xFF), tokenRGB(0x15, 0x15, 0x17)),
            ("layer1", DSHTheme.layer1, tokenRGB(0xFF, 0xFF, 0xFF), tokenRGB(0x23, 0x23, 0x24)),
            ("layer2", DSHTheme.layer2, tokenRGB(0xF9, 0xFA, 0xFB), tokenRGB(0x2C, 0x2C, 0x2E)),
            ("layer3", DSHTheme.layer3, tokenRGB(0xF5, 0xF6, 0xF7), tokenRGB(0x35, 0x36, 0x38)),
            ("labelPrimary", DSHTheme.labelPrimary, tokenRGB(0x0F, 0x11, 0x15), tokenRGB(0xF9, 0xFA, 0xFB)),
            ("labelSecondary", DSHTheme.labelSecondary, tokenRGB(0x61, 0x66, 0x6B), tokenRGB(0xCF, 0xD3, 0xD6)),
            ("labelDimmed", DSHTheme.labelDimmed, tokenRGB(0xAD, 0xB2, 0xB8), tokenRGB(0x43, 0x45, 0x4A)),
            ("labelError", DSHTheme.labelError, tokenRGB(0xEC, 0x13, 0x13), tokenRGB(0xF2, 0x5A, 0x5A)),
            ("success", DSHTheme.success, tokenRGB(0x22, 0xC5, 0x5E), tokenRGB(0x4E, 0xD1, 0x7E)),
            ("danger", DSHTheme.danger, tokenRGB(0xEF, 0x44, 0x44), tokenRGB(0xF2, 0x5A, 0x5A)),
            ("codeBackground", DSHTheme.codeBackground, tokenRGB(0xF5, 0xF6, 0xF7), tokenRGB(0x1B, 0x1B, 0x1C)),
            ("diffAdded", DSHTheme.diffAdded, tokenRGB(0xE6, 0xFA, 0xED), tokenRGB(0x23, 0x3C, 0x2C)),
            ("diffRemoved", DSHTheme.diffRemoved, tokenRGB(0xFE, 0xF2, 0xF2), tokenRGB(0x3A, 0x1D, 0x1D)),
        ]

        for entry in table {
            expectAdaptive(entry.name, entry.color, light: entry.light, dark: entry.dark)
        }
    }

    /// 只有一个 token 两套外观同值：桌面 token 层就是这么定义的，钉住它免得被"顺手修掉"。
    func test_label_tertiary_is_the_same_value_in_both_appearances() {
        let light = resolvedToken(DSHTheme.labelTertiary, .light)
        let dark = resolvedToken(DSHTheme.labelTertiary, .dark)
        XCTAssertTrue(light.near(tokenRGB(0x81, 0x85, 0x8C)), "labelTertiary light resolved \(light)")
        XCTAssertTrue(dark.near(tokenRGB(0x81, 0x85, 0x8C)), "labelTertiary dark resolved \(dark)")
        XCTAssertGreaterThan(light.a, 0.001, "labelTertiary must not be fully transparent")
        XCTAssertGreaterThan(dark.a, 0.001, "labelTertiary must not be fully transparent")
    }

    // MARK: - 品牌色与强调色

    /// 强调色只有一个色相：warning 曾经是琥珀色，是当时全 App 唯一的非品牌色，改回蓝了。
    func test_the_accent_family_shares_one_hue_and_the_warning_is_not_amber() {
        let brand = resolvedToken(DSHTheme.brand, .light)
        XCTAssertTrue(brand.near(tokenRGB(0x4D, 0x6B, 0xFE)), "brand resolved \(brand)")
        XCTAssertTrue(resolvedToken(DSHTheme.brand, .dark).near(brand), "brand must not change with appearance")
        XCTAssertTrue(resolvedToken(DSHTheme.attention, .light).near(brand), "attention must be the brand blue")
        XCTAssertTrue(resolvedToken(DSHTheme.usageMid, .light).near(brand), "usageMid must be the brand blue")

        let bright = resolvedToken(DSHTheme.brandBright, .light)
        XCTAssertTrue(bright.near(tokenRGB(0x6B, 0x85, 0xFF)), "brandBright resolved \(bright)")
        XCTAssertFalse(bright.near(brand), "brandBright must be a distinct step from brand")

        let low = resolvedToken(DSHTheme.usageLow, .light)
        let high = resolvedToken(DSHTheme.usageHigh, .light)
        XCTAssertTrue(low.near(tokenRGB(0x7C, 0x9B, 0xFF)), "usageLow resolved \(low)")
        XCTAssertTrue(high.near(tokenRGB(0x2A, 0x45, 0xC8)), "usageHigh resolved \(high)")
        XCTAssertFalse(low.near(high), "the usage ramp needs two ends")
    }

    func test_static_tokens_are_opaque_and_appearance_independent() {
        let table: [(name: String, color: Color, value: TokenRGBA)] = [
            ("brand", DSHTheme.brand, tokenRGB(0x4D, 0x6B, 0xFE)),
            ("brandBright", DSHTheme.brandBright, tokenRGB(0x6B, 0x85, 0xFF)),
            ("attention", DSHTheme.attention, tokenRGB(0x4D, 0x6B, 0xFE)),
            ("usageLow", DSHTheme.usageLow, tokenRGB(0x7C, 0x9B, 0xFF)),
            ("usageMid", DSHTheme.usageMid, tokenRGB(0x4D, 0x6B, 0xFE)),
            ("usageHigh", DSHTheme.usageHigh, tokenRGB(0x2A, 0x45, 0xC8)),
            ("syntaxNumber", DSHTheme.syntaxNumber, tokenRGB(0x8B, 0x7C, 0xFF)),
        ]
        for entry in table {
            let light = resolvedToken(entry.color, .light)
            let dark = resolvedToken(entry.color, .dark)
            XCTAssertTrue(light.near(entry.value), "\(entry.name) light resolved \(light)")
            XCTAssertTrue(dark.near(entry.value), "\(entry.name) dark resolved \(dark)")
            XCTAssertTrue(light.a > 0.99, "\(entry.name) must be opaque in light, got \(light)")
            XCTAssertTrue(dark.a > 0.99, "\(entry.name) must be opaque in dark, got \(dark)")
        }
    }

    /// 两种"淡色"是故意带 alpha 的：选中行的品牌水洗、模态背景的遮罩。
    func test_wash_tokens_stay_translucent() {
        let brand = resolvedToken(DSHTheme.brand, .light)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let wash = resolvedToken(DSHTheme.brandSubtle, scheme)
            XCTAssertEqual(wash.a, 0.14, accuracy: 0.002, "brandSubtle \(name) alpha")
            XCTAssertEqual(wash.r, brand.r, accuracy: 0.002, "brandSubtle \(name) red")
            XCTAssertEqual(wash.g, brand.g, accuracy: 0.002, "brandSubtle \(name) green")
            XCTAssertEqual(wash.b, brand.b, accuracy: 0.002, "brandSubtle \(name) blue")

            let scrim = resolvedToken(DSHTheme.scrim, scheme)
            XCTAssertEqual(scrim.a, 0.5, accuracy: 0.002, "scrim \(name) alpha")
            XCTAssertEqual(scrim.r, 0, accuracy: 0.002, "scrim \(name) red")
            XCTAssertEqual(scrim.g, 0, accuracy: 0.002, "scrim \(name) green")
            XCTAssertEqual(scrim.b, 0, accuracy: 0.002, "scrim \(name) blue")
        }
    }

    // MARK: - 边框：三个 token 的 alpha 在低字节

    /// 暗色这一半是对的：白色带 6% / 12% / 16% alpha。
    /// 老版本把 `0xFFFFFF0F` 当 RGB 读成 `#FFFF0F`，暗色模式的每条分隔线都画成亮黄。
    func test_dark_borders_are_translucent_white() {
        let table: [(name: String, color: Color, alpha: Double)] = [
            ("border1", DSHTheme.border1, 0x0F),
            ("border2", DSHTheme.border2, 0x1F),
            ("border3", DSHTheme.border3, 0x29),
        ]
        for entry in table {
            let dark = resolvedToken(entry.color, .dark)
            XCTAssertTrue(dark.near(TokenRGBA(r: 1, g: 1, b: 1, a: entry.alpha / 255), within: 0.003),
                          "\(entry.name) dark resolved \(dark), expected white at \(entry.alpha) / 255")
        }
    }

    /// 缺陷钉住（不是期望行为，是今天的读数）：三个亮色边框字面量是 `0x0000000A` /
    /// `0x0000001A` / `0x0000001F`，数值上只有 10 / 26 / 31，落不进 `Color(hex:)` 的
    /// "八位读 RGBA" 分支（判据是 `hex > 0xFFFFFF`），于是被当六位 RGB 读：
    /// 期望的"4% 黑"变成了不透明蓝通道 #00000A。
    /// 修法是把判据换成"字面量有没有写满八位"，或者给这三个 token 换写法；
    /// 修完这条用例必须改成 `tokenRGB(0, 0, 0, 0.039)` 之类的期望值。
    func test_light_borders_today_lose_their_alpha_and_gain_a_blue_channel() {
        let table: [(name: String, blue: Double)] = [
            ("border1", 0x0A / 255),
            ("border2", 0x1A / 255),
            ("border3", 0x1F / 255),
        ]
        let colors: [Color] = [DSHTheme.border1, DSHTheme.border2, DSHTheme.border3]
        for (entry, color) in zip(table, colors) {
            let light = resolvedToken(color, .light)
            XCTAssertTrue(light.near(TokenRGBA(r: 0, g: 0, b: entry.blue, a: 1), within: 0.003),
                          "\(entry.name) light resolved \(light) — the intended value is 4/10/12 percent black")
        }
    }

    // MARK: - 可读性下限

    /// 正文与次级文字在两种底色上都要够看：正文 4.5:1、提示 3:1（AA）。
    func test_labels_stay_readable_on_the_background_in_both_appearances() {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let background = resolvedToken(DSHTheme.background, scheme)
            let primary = contrastRatio(resolvedToken(DSHTheme.labelPrimary, scheme), background)
            let secondary = contrastRatio(resolvedToken(DSHTheme.labelSecondary, scheme), background)
            let tertiary = contrastRatio(resolvedToken(DSHTheme.labelTertiary, scheme), background)
            XCTAssertGreaterThanOrEqual(primary, 4.5, "labelPrimary on background, \(name): \(primary)")
            XCTAssertGreaterThanOrEqual(secondary, 4.5, "labelSecondary on background, \(name): \(secondary)")
            XCTAssertGreaterThanOrEqual(tertiary, 3.0, "labelTertiary on background, \(name): \(tertiary)")
        }
    }

    // MARK: - helpers

    private func expectAdaptive(_ name: String, _ color: Color, light: TokenRGBA, dark: TokenRGBA,
                                file: StaticString = #filePath, line: UInt = #line) {
        let resolvedLight = resolvedToken(color, .light)
        let resolvedDark = resolvedToken(color, .dark)
        XCTAssertTrue(resolvedLight.near(light), "\(name) light resolved \(resolvedLight), expected \(light)",
                      file: file, line: line)
        XCTAssertTrue(resolvedDark.near(dark), "\(name) dark resolved \(resolvedDark), expected \(dark)",
                      file: file, line: line)
        XCTAssertGreaterThan(resolvedLight.a, 0.001, "\(name) must not be transparent in light",
                             file: file, line: line)
        XCTAssertGreaterThan(resolvedDark.a, 0.001, "\(name) must not be transparent in dark",
                             file: file, line: line)
        XCTAssertFalse(resolvedLight.near(resolvedDark), "\(name) must differ between light and dark",
                       file: file, line: line)
    }

    private func relativeLuminance(_ color: TokenRGBA) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    private func contrastRatio(_ one: TokenRGBA, _ other: TokenRGBA) -> Double {
        let first = relativeLuminance(one)
        let second = relativeLuminance(other)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

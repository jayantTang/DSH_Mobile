@testable import DSHDesign
import XCTest

/// 过程折叠文字颜色的无障碍门槛（owner 2026-10-26 选 A：只加深颜色，不动布局）。
///
/// 两套外观各算一遍 WCAG AA 正文对比度（≥4.5:1），防止以后有人把颜色调回去。
final class ColorContrastTests: XCTestCase {

    private typealias Tokens = DSHTheme.ProcessTextTokens

    func test_process_label_meets_aa_on_light_and_dark_backgrounds() {
        let light = ColorContrast.ratio(Tokens.processLabelLight,
                                        on: Tokens.lightBackground)
        let dark = ColorContrast.ratio(Tokens.processLabelDark,
                                       on: Tokens.darkBackground)
        XCTAssertGreaterThanOrEqual(light, ColorContrast.minimumBodyRatio,
                                    "浅色 #61666B 对白底应为 \(light):1")
        XCTAssertGreaterThanOrEqual(dark, ColorContrast.minimumBodyRatio,
                                    "深色 #81858C 对深底应为 \(dark):1")
        // 记录当前实测值（owner 要求汇报）：5.80 / 4.92。
        XCTAssertEqual(light, 5.80, accuracy: 0.02)
        XCTAssertEqual(dark, 4.92, accuracy: 0.02)
    }

    func test_deep_diving_meets_aa_on_light_and_dark_backgrounds() {
        let light = ColorContrast.ratio(Tokens.deepDivingLight,
                                        on: Tokens.lightBackground)
        let dark = ColorContrast.ratio(Tokens.deepDivingDark,
                                       on: Tokens.darkBackground)
        XCTAssertGreaterThanOrEqual(light, ColorContrast.minimumBodyRatio,
                                    "浅色 #345EBA 对白底应为 \(light):1")
        XCTAssertGreaterThanOrEqual(dark, ColorContrast.minimumBodyRatio,
                                    "深色 #6B85FF 对深底应为 \(dark):1")
        // 记录当前实测值：6.08 / 5.58。
        XCTAssertEqual(light, 6.08, accuracy: 0.02)
        XCTAssertEqual(dark, 5.58, accuracy: 0.02)
    }

    func test_the_ratio_math_matches_the_wcag_reference_points() {
        XCTAssertEqual(ColorContrast.ratio(0x000000, on: 0xFFFFFF), 21, accuracy: 0.001)
        XCTAssertEqual(ColorContrast.ratio(0xFFFFFF, on: 0xFFFFFF), 1, accuracy: 0.001)
    }
}

import SwiftUI
import XCTest
@testable import DSHDesign

/// `dshPadAdaptation` 的唯一判据：iPad **且** 宽屏。
///
/// 四条里第二条与第三条是硬约束的护栏：iPad 窄分屏、iPhone 横屏都必须为假，
/// 否则整页弹层、阅读宽度、指针、快捷键会穿透到不该出现的形态上。
///
/// 文件**不加** `#if os(iOS)`：`isPadWide(isPad:layout:)` 不吃 UIKit（idiom 由 `RootView`
/// 归一成 `isPad`），所以这条护栏在 macOS 的 `swift test` 里也真的跑得到。
final class AdaptationTests: XCTestCase {

    func test_padWideIsTrue() {
        XCTAssertTrue(DSHAdaptation.isPadWide(isPad: true, layout: .wide))
    }

    func test_padCompactIsFalse() {
        XCTAssertFalse(DSHAdaptation.isPadWide(isPad: true, layout: .compact))
    }

    func test_phoneWideIsFalse() {
        // 这条就是 iPhone 横屏的护栏：Pro Max 横屏是 regular 宽度，今天就在跑分栏。
        XCTAssertFalse(DSHAdaptation.isPadWide(isPad: false, layout: .wide))
    }

    func test_phoneCompactIsFalse() {
        XCTAssertFalse(DSHAdaptation.isPadWide(isPad: false, layout: .compact))
    }

    func test_defaultEnvironmentValueIsFalse() {
        XCTAssertFalse(EnvironmentValues().dshPadAdaptation)
    }
}

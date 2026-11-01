import SwiftUI
import XCTest
@testable import DSHDesign

/// 布局判据只有两态，且只看宽窄（M2 的护栏）。
/// 这条用例只锁这一件事：把 idiom 塞进布局判定就会在这里红。
///
/// 文件**不加** `#if os(iOS)`：判定本身是纯函数，必须在 macOS 的 `swift test` 里也真的
/// 跑到；尺寸类那层适配（依赖 SwiftUI 的 `UserInterfaceSizeClass`，macOS 没有）另行验证。
final class LayoutModeTests: XCTestCase {

    func test_compactStaysCompact() {
        XCTAssertEqual(DSHLayoutMode(isCompact: true), .compact)
    }

    func test_notCompactIsWide() {
        // iPhone Pro Max 横屏也落在这里——宽屏不等于 iPad。
        XCTAssertEqual(DSHLayoutMode(isCompact: false), .wide)
    }

    func test_defaultEnvironmentValueIsCompact() {
        // 没有显式注入的子树（预览、被别处托管的视图）落到手机布局。
        XCTAssertEqual(EnvironmentValues().dshLayoutMode, .compact)
    }

    #if canImport(UIKit)
    /// 尺寸类适配层：`nil` 落**宽态**，因为今天那行守卫正是这么写的——
    /// `if horizontalSizeClass == .compact { 栈 } else { 分栏 }`，`nil` 走 else。
    ///
    /// 不许改成 `.compact`：那会把 iPhone 上"尺寸类暂时未定"的那一瞬从分栏翻成推栈，
    /// 是 iPhone 上可见的变化（硬约束 ①）。
    func test_sizeClassAdapter_nilAndRegularFallToWide() {
        XCTAssertEqual(DSHLayoutMode(nil), .wide)
        XCTAssertEqual(DSHLayoutMode(.regular), .wide)
    }

    func test_sizeClassAdapter_compactStaysCompact() {
        XCTAssertEqual(DSHLayoutMode(.compact), .compact)
    }
    #endif
}

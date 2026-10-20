import XCTest
@testable import DSHDesign

/// 设计 token 纯逻辑测试（不进快照的部分）：颜色解析与单位换算。
final class ThemeTests: XCTestCase {
    func test_hexRGBA_splits_channels() {
        let parts = hexRGBA(0xFF8000)
        XCTAssertEqual(parts.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(parts.g, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(parts.b, 0.0, accuracy: 0.001)
        XCTAssertEqual(parts.a, 1.0, accuracy: 0.001)
    }

    func test_hexRGBA_with_alpha_byte() {
        let parts = hexRGBA(0xFF800080)
        XCTAssertEqual(parts.a, 128.0 / 255.0, accuracy: 0.001)
    }
}

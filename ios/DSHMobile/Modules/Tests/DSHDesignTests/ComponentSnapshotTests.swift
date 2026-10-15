#if os(iOS)
import SwiftUI
import XCTest
@testable import DSHDesign
import SnapshotTesting

/// 设计系统快照：固定 size class / 浅色主题 / 中文 locale，防假阳性（025 自审修正 5）。
/// 断言消息一律 ASCII。
final class ComponentSnapshotTests: XCTestCase {

    /// 固定环境：iPhone 尺寸、浅色、简体中文。
    private func traits() -> SnapshottingTraits {
        SnapshottingTraits()
            .traits(UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: .light),
                UITraitCollection(locale: Locale(identifier: "zh-Hans")),
            ]))
    }

    func test_statusDot_ok() {
        let view = StatusDot(level: .ok)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits), traits: traits())
    }

    func test_badge_neutral() {
        let view = Badge(text: "badge")
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits), traits: traits())
    }

    func test_emptyState() {
        let view = EmptyStateView(icon: "tray", title: "empty", message: "nothing here")
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 390, height: 240)), traits: traits())
    }
}
#endif

import DSHKit
import Foundation
import XCTest

/// `MessageLayer` 的尾轮边界门面（设计 M2'-2）。
///
/// 这两条钉的不是"能不能存"，而是**失败必须可见**：`meta` / `clear` 那类缓存行为
/// 用 `try?` 吞掉是对的，边界写入吞掉就等于"下次打开仍然未知"这个后果没有任何证据。
@MainActor
final class MessageLayerTailTests: XCTestCase {

    func test_tail_boundary_throws_when_the_store_is_missing() async {
        // 没有 attach 磁盘层：两个方法都必须抛 `noAddress`，而不是返回 nil / void。
        let layer = MessageLayer()
        do {
            _ = try await layer.tailBoundary(scope: "mac", sessionId: "s1")
            XCTFail("没有磁盘层时读边界必须抛出")
        } catch {
            // 期望路径。
        }
        do {
            try await layer.setTailBoundary(
                scope: "mac", sessionId: "s1",
                try XCTUnwrap(StoredTailBoundary(.closed(turn: 1, reason: "completed"))))
            XCTFail("没有磁盘层时写边界必须抛出")
        } catch {
            // 期望路径。
        }
    }
}

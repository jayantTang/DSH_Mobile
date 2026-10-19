import XCTest
@testable import DSHChatDomain

/// 预取窗口的边界：只备视口上方两页，且必须比一次上拉小——
/// 否则预取会挤占用户请求的等待时间（spec FR-008 / SC-006）。
final class HistoryPrefetchPolicyTests: XCTestCase {
    func test_prefetch_window_is_two_pages_and_narrower_than_a_pull() {
        XCTAssertEqual(ChatPipelineBridge.prefetchOlderPages, 2)
        XCTAssertLessThan(ChatPipelineBridge.prefetchOlderPages,
                          ChatPipelineBridge.pagesPerFetch)
    }
}

import XCTest
@testable import DSHChatDomain

/// 取页状态机：终态不能被"请求收尾"覆盖，否则界面会停在加载中。
final class OlderPageStateTests: XCTestCase {
    func test_finishing_only_clears_loading() {
        XCTAssertEqual(ChatModel.OlderPageState.loading.finishing(), .idle)
        XCTAssertEqual(ChatModel.OlderPageState.idle.finishing(), .idle)
    }

    func test_failure_and_exhausted_are_terminal() {
        XCTAssertEqual(ChatModel.OlderPageState.failed("timeout").finishing(), .failed("timeout"))
        XCTAssertEqual(ChatModel.OlderPageState.exhausted.finishing(), .exhausted)
    }
}

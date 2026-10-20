@testable import DSHChatDomain
import XCTest

/// SearchState 的会话隔离：reset 清空缓冲、拒绝原因与在飞标记，并推进刷新计数。
@MainActor
final class SearchStateTests: XCTestCase {

    func testResetClearsBufferAndBumpsScopeVersion() {
        let state = SearchState()
        state.oldestSeq = 42
        state.refusalReason = "no-whole-session"
        state.isExtending = true
        state.scopeVersion = 7
        state.reset()
        XCTAssertNil(state.oldestSeq)
        XCTAssertNil(state.refusalReason)
        XCTAssertFalse(state.isExtending, "the in-flight flag must not survive a session switch")
        XCTAssertEqual(state.scopeVersion, 8)
    }

    func testChatModelForwardsSearchScopeAndRefusal() {
        let model = ChatModel()
        model.searchState.scopeVersion = 3
        model.searchState.refusalReason = "refused"
        XCTAssertEqual(model.searchScopeVersion, 3)
        XCTAssertEqual(model.searchRefusalReason, "refused")
    }
}

import DSHChatDomain
import Observation
import XCTest

/// ComposerState 拆分后的行为钉子：草稿归会话、转发属性可写、嵌套观察能触发。
///
/// 最后一个用例是这次拆分最需要的证据：UI 仍读 `model.draft`，但存储在
/// `composer` 里；如果 SwiftUI 的观察链在转发层断掉，输入框就会"打字不刷新"。
@MainActor
final class ComposerStateTests: XCTestCase {

    func testForwardedPropertiesHitTheComposerStore() {
        let model = ChatModel()
        model.draft = "hello"
        model.steerNext = true
        XCTAssertEqual(model.composer.draft, "hello")
        XCTAssertTrue(model.composer.steerNext)
    }

    func testDraftsAreIsolatedPerSession() {
        let composer = ComposerState()
        composer.draft = "for one"
        composer.stash(sessionId: "one")
        composer.draft = ""
        composer.load(sessionId: "two")
        XCTAssertEqual(composer.draft, "", "another session must not see the draft")
        composer.load(sessionId: "one")
        XCTAssertEqual(composer.draft, "for one")
    }

    func testObservationOfForwardedDraftFires() async {
        let model = ChatModel()
        let changed = expectation(description: "draft change observed")
        withObservationTracking {
            _ = model.draft
        } onChange: {
            changed.fulfill()
        }
        model.composer.draft = "typed"
        await fulfillment(of: [changed], timeout: 1)
    }
}

@testable import DSHChatDomain
import DSHKit
import Observation
import XCTest

/// TranscriptStore 的发布/清空与 ChatModel 的转发：换会话只换一个自洽的值。
@MainActor
final class TranscriptStoreTests: XCTestCase {

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(sessionId: id, updatedAt: 0)
    }

    func testPublishAndClear() {
        let store = TranscriptStore()
        XCTAssertNil(store.session)
        store.visible = .init(summary: summary("s1"), timeline: ChatTimeline())
        XCTAssertEqual(store.session?.sessionId, "s1")
        store.clear()
        XCTAssertNil(store.session)
        XCTAssertNil(store.visible)
    }

    func testChatModelForwardsSessionAndTimeline() {
        let model = ChatModel()
        model.transcriptStore.visible = .init(
            summary: summary("s2"), timeline: ChatTimeline())
        XCTAssertEqual(model.session?.sessionId, "s2")
        XCTAssertEqual(model.visible?.summary.sessionId, "s2")
    }

    func testObservationOfForwardedSessionFires() async {
        let model = ChatModel()
        let changed = expectation(description: "session change observed")
        withObservationTracking {
            _ = model.session
        } onChange: {
            changed.fulfill()
        }
        model.transcriptStore.visible = .init(
            summary: summary("s3"), timeline: ChatTimeline())
        await fulfillment(of: [changed], timeout: 1)
    }
}

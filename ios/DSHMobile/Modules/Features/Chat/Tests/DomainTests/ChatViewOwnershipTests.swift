@testable import DSHChatDomain
import XCTest

final class ChatViewOwnershipTests: XCTestCase {
    func test_only_the_current_session_owns_the_transcript() {
        XCTAssertTrue(ChatViewOwnership.isOwner(sessionId: "s1", viewSessionId: "s1"))
        XCTAssertFalse(ChatViewOwnership.isOwner(sessionId: "s2", viewSessionId: "s1"))
        XCTAssertFalse(ChatViewOwnership.isOwner(sessionId: nil, viewSessionId: "s1"))
    }
}

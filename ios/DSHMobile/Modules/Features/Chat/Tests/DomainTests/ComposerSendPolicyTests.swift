@testable import DSHChatDomain
import XCTest

final class ComposerSendPolicyTests: XCTestCase {
    func test_text_or_picture_is_sendable() {
        XCTAssertFalse(ComposerSendPolicy.canSend(draft: "  \n", images: []))
        XCTAssertTrue(ComposerSendPolicy.canSend(draft: "hello", images: []))
        XCTAssertTrue(ComposerSendPolicy.canSend(draft: "", images: [
            ComposerDraftImage(mediaType: "image/png", base64: "", name: "a.png", preview: NSObject())
        ]))
    }
}

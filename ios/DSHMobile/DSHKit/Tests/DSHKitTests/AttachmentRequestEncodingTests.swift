import XCTest
@testable import DSHKit

/// Regression for SR-02.10/attachment delivery: the host's `session/attachment`
/// endpoint takes the complete reference, not a bare `attachmentId`. A missing
/// nested reference makes every tool-result picture fail and retry forever.
final class AttachmentRequestEncodingTests: XCTestCase {
    func testAttachmentRequestNestsTheCompleteReference() throws {
        let image = ContentBlock.ImageAttachment(
            attachmentId: "att_1",
            mediaType: "image/png",
            bytes: 2048,
            width: 320,
            height: 480,
            name: "shot.png"
        )
        let request = SessionAttachmentRequest(sessionId: "s-1", attachment: image)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["sessionId"] as? String, "s-1")
        XCTAssertNil(object["attachmentId"], "the id must not be sent at the top level")
        let attachment = try XCTUnwrap(object["attachment"] as? [String: Any])
        XCTAssertEqual(attachment["attachmentId"] as? String, "att_1")
        XCTAssertEqual(attachment["mediaType"] as? String, "image/png")
        XCTAssertEqual(attachment["bytes"] as? Int, 2048)
        XCTAssertEqual(attachment["width"] as? Int, 320)
        XCTAssertEqual(attachment["height"] as? Int, 480)
        XCTAssertEqual(attachment["name"] as? String, "shot.png")
    }
}

@testable import DSHChatDomain
import DSHKit
import XCTest

/// 取图失败的分类（设计 §5 B2 / 用例 IMG-LOG-02）。
///
/// 分类只有这一份：设备日志发 `category` 短码，界面显示 `displayText`，链路是否
/// 还没就绪由 `isLinkNotReady` 判——三处都从这里派生。
final class AttachmentLoadFailureTests: XCTestCase {

    func testEveryTransportErrorMapsToItsStableCategory() {
        XCTAssertEqual(AttachmentLoadFailure.from(DSHTransportError.notConnected).category,
                       "not-connected")
        XCTAssertEqual(AttachmentLoadFailure.from(DSHTransportError.unreachable("dns")).category,
                       "unreachable")
        XCTAssertEqual(AttachmentLoadFailure.from(DSHTransportError.carrierClosed).category,
                       "carrier-closed")
        XCTAssertEqual(AttachmentLoadFailure.from(DSHTransportError.timedOut(method: "session/attachment")).category,
                       "timed-out")
        XCTAssertEqual(AttachmentLoadFailure.from(
            DSHTransportError.httpStatus(413, body: nil)).category, "http-413")
        XCTAssertEqual(AttachmentLoadFailure.from(
            DSHTransportError.notAuthenticated("revoked")).category, "not-authenticated")
        XCTAssertEqual(AttachmentLoadFailure.from(
            DSHTransportError.malformedResponse("no data")).category, "malformed")
        XCTAssertEqual(AttachmentLoadFailure.decode.category, "decode")
        XCTAssertEqual(AttachmentLoadFailure.unknown.category, "unknown")
    }

    func testTheCategoryNeverCarriesLocalizedProse() {
        let all: [AttachmentLoadFailure] = [
            .notConnected, .unreachable, .carrierClosed, .timedOut, .http(500),
            .notAuthenticated, .malformed, .decode, .unknown,
        ]
        for failure in all {
            let category = failure.category
            XCTAssertFalse(category.contains(" "), "短码里不许有空格：\(category)")
            XCTAssertTrue(category.allSatisfy { $0.isASCII }, "短码只用 ASCII：\(category)")
            // 文案与短码必须是两样东西：短码不会等于用户看到的那一句。
            XCTAssertNotEqual(category, failure.displayText)
        }
    }

    func testLinkNotReadyOnlyCoversTheThreeTransportCases() {
        XCTAssertTrue(AttachmentLoadFailure.notConnected.isLinkNotReady)
        XCTAssertTrue(AttachmentLoadFailure.unreachable.isLinkNotReady)
        XCTAssertTrue(AttachmentLoadFailure.carrierClosed.isLinkNotReady)
        XCTAssertFalse(AttachmentLoadFailure.timedOut.isLinkNotReady)
        XCTAssertFalse(AttachmentLoadFailure.http(500).isLinkNotReady)
        XCTAssertFalse(AttachmentLoadFailure.decode.isLinkNotReady)
    }
}

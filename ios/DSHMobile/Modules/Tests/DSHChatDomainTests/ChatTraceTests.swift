import XCTest
@testable import DSHChatDomain

/// 折叠/取页事件字段的纯函数：字段名与排序是解析侧的契约，不能随手改。
final class ChatTraceTests: XCTestCase {
    func testFoldFieldsSortReasons() {
        let fields = FoldTrace.fields(turns: 5, foldable: 3, running: 1, openCompleted: 1,
                                      reasons: ["noProcess": 2, "gap": 1])
        XCTAssertEqual(fields["turns"], "5")
        XCTAssertEqual(fields["foldable"], "3")
        XCTAssertEqual(fields["running"], "1")
        XCTAssertEqual(fields["open"], "1")
        XCTAssertEqual(fields["why"], "gap:1,noProcess:2")
    }

    func testFoldFieldsOmitWhyWhenNothingOpen() {
        let fields = FoldTrace.fields(turns: 2, foldable: 2, running: 0, openCompleted: 0, reasons: [:])
        XCTAssertNil(fields["why"])
    }

    func testPageFieldsOmitUnsetNumbers() {
        let start = PageTrace.fields(direction: "older", from: 10, to: 0, pages: 3)
        XCTAssertEqual(start, ["dir": "older", "from": "10", "pages": "3"])
        let done = PageTrace.fields(direction: "older", from: 10, to: 4, pages: 3,
                                    records: 6, elapsedMs: 220)
        XCTAssertEqual(done["to"], "4")
        XCTAssertEqual(done["records"], "6")
        XCTAssertEqual(done["ms"], "220")
    }
}

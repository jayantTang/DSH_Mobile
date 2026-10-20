import XCTest
@testable import DSHFoundation

/// `DSHLog.event` 的格式与出口：这是 OTA 诊断通道的唯一业务事件入口，
/// 格式错了会让解析侧（`scripts/dev/ios-logs.mjs`）读不出来。
final class EventLogTests: XCTestCase {
    override func tearDown() {
        DSHLog.sink = nil
        super.tearDown()
    }

    func testFormatSortsFieldsAndFlattensWhitespace() {
        let line = DSHLog.format("page.older.start", [
            "to": "10", "note": "a  b\nc", "dir": "older",
        ])
        XCTAssertEqual(line, "page.older.start dir=older note=a_b_c to=10")
    }

    func testFormatTruncatesLongValues() {
        let line = DSHLog.format("x", ["v": String(repeating: "x", count: 130)])
        XCTAssertEqual(line.count, "x v=".count + 120 + 1)
        XCTAssertTrue(line.hasSuffix("…"))
    }

    func testFormatWithNoFieldsIsJustTheKind() {
        XCTAssertEqual(DSHLog.format("fold.summary", [:]), "fold.summary")
    }

    func testEventWithoutSinkDoesNothing() {
        var seen: [String] = []
        DSHLog.event("x", ["a": "1"])
        XCTAssertTrue(seen.isEmpty)
        DSHLog.sink = { seen.append($0) }
        DSHLog.event("x", ["a": "1"])
        XCTAssertEqual(seen, ["x a=1"])
    }
}

import XCTest
@testable import DSHKit

final class SessionDigestMergeTests: XCTestCase {
    private func row(_ id: String, _ updatedAt: Double) -> SessionSummary {
        let json = """
        {"sessionId":"\(id)","updatedAt":\(updatedAt),"running":false,"blank":false}
        """
        return try! JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
    }

    func test_delta_replaces_and_removes_without_dropping_untouched_rows() {
        let current = [row("a", 3), row("b", 2), row("c", 1)]
        let value = SessionListValue(items: [row("b", 5)], removed: ["c"], version: "v2", full: false)
        let merged = SessionDigestMerge.apply(current: current, value: value)
        XCTAssertEqual(merged.map(\.sessionId), ["b", "a"])
        XCTAssertEqual(merged.first?.updatedAt, 5)
    }

    func test_full_response_replaces_everything() {
        let current = [row("a", 3), row("b", 2)]
        let value = SessionListValue(items: [row("d", 9)], removed: ["a"], version: "v9", full: true)
        let merged = SessionDigestMerge.apply(current: current, value: value)
        XCTAssertEqual(merged.map(\.sessionId), ["d"])
    }

    func test_legacy_response_without_version_is_treated_as_incremental() throws {
        let json = #"{"items":[{"sessionId":"a","updatedAt":1,"running":false,"blank":false}]}"#
        let value = try JSONDecoder().decode(SessionListValue.self, from: Data(json.utf8))
        XCTAssertNil(value.version)
        XCTAssertNil(value.full)
        XCTAssertNil(value.removed)
    }
}

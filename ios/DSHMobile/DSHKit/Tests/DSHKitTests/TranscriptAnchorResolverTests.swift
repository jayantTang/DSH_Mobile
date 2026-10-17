import XCTest
@testable import DSHKit

final class TranscriptAnchorResolverTests: XCTestCase {

    private func user(_ id: String, seq: Int) -> TimelineItem {
        TimelineItem(id: id, kind: .userMessage(text: "q", images: [], isSteering: false,
                                                isPending: false, isAgentSent: false), seq: seq)
    }

    private func header(_ id: String, start: Int, end: Int) -> TimelineItem {
        TimelineItem(id: id, kind: .processHeader(TimelineProcessHeader(
            id: id, scope: .turn, turn: 1, startSeq: start, endSeq: end,
            toolCount: 2, reasoningCount: 1, messageCount: 0, subagentCount: 0,
            activityCounts: [:], isExpanded: false, isFoldable: true, isRunning: false,
            endReason: "completed", duration: 1, hasFailure: false, isPartial: false)),
            seq: start)
    }

    func test_anchor_that_still_exists_is_returned_unchanged() {
        let rows = [user("u", seq: 1), header("h", start: 2, end: 4)]
        XCTAssertEqual(TranscriptAnchorResolver.resolve(anchorID: "u", anchorSeq: 1, in: rows), "u")
    }

    func test_hidden_row_maps_to_its_covering_process_node() {
        let rows = [user("u", seq: 1), header("h", start: 2, end: 4)]
        XCTAssertEqual(TranscriptAnchorResolver.resolve(anchorID: "tool-3", anchorSeq: 3, in: rows), "h")
    }

    func test_hidden_row_without_a_node_maps_to_the_next_row() {
        let rows = [user("u", seq: 1), user("v", seq: 5)]
        XCTAssertEqual(TranscriptAnchorResolver.resolve(anchorID: "gone", anchorSeq: 3, in: rows), "v")
    }

    func test_hidden_row_after_the_end_maps_to_the_previous_row() {
        let rows = [user("u", seq: 1), user("v", seq: 2)]
        XCTAssertEqual(TranscriptAnchorResolver.resolve(anchorID: "gone", anchorSeq: 9, in: rows), "v")
    }

    func test_empty_rows_resolve_to_nil() {
        XCTAssertNil(TranscriptAnchorResolver.resolve(anchorID: "x", anchorSeq: 1, in: []))
    }
}

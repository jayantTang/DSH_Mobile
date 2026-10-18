import XCTest
@testable import DSHKit

final class TimelineProcessHeaderTests: XCTestCase {

    private func headerRow(expanded: Bool = false) -> TimelineItem {
        TimelineItem(id: "turn-process:1", kind: .processHeader(TimelineProcessHeader(
            id: "turn-process:1", scope: .turn, turn: 1, startSeq: 2, endSeq: 8,
            toolCount: 3, reasoningCount: 2, messageCount: 1, subagentCount: 0,
            activityCounts: [.read: 2, .commands: 1], isExpanded: expanded,
            isFoldable: true, isRunning: false, endReason: "completed",
            duration: 12, hasFailure: false, isPartial: false)), seq: 2)
    }

    func test_header_identity_and_sequence_come_from_the_process_start() {
        let item = headerRow()
        XCTAssertEqual(item.id, "turn-process:1")
        XCTAssertEqual(item.seq, 2)
        XCTAssertTrue(item.kind.isContentRow)
        XCTAssertFalse(item.kind.covers(seq: 2))
    }

    func test_header_has_no_searchable_text() {
        let hits = TranscriptSearch.hits(in: [headerRow()], query: "读取")
        XCTAssertTrue(hits.isEmpty)
    }

    func test_header_has_no_heavy_payload_and_is_never_reclaimed() {
        var payload = TranscriptRowPayload(item: headerRow())
        XCTAssertEqual(payload.payloadBytes, 0)
        XCTAssertEqual(TranscriptRowPayload.kind(of: headerRow()), .processHeader)
        payload.reclaim()
        XCTAssertFalse(payload.isReclaimed)
        XCTAssertNotNil(payload.item)
    }

    func test_tool_names_classify_into_stable_activities() {
        XCTAssertEqual(TimelineProcessActivity.classify("read"), .read)
        XCTAssertEqual(TimelineProcessActivity.classify("read_image"), .read)
        XCTAssertEqual(TimelineProcessActivity.classify("bash"), .commands)
        XCTAssertEqual(TimelineProcessActivity.classify("subagent_control"), .subagents)
        XCTAssertEqual(TimelineProcessActivity.classify("something-new"), .tools)
    }

    func test_header_signature_changes_with_disclosure_state() {
        // The host must reload the cell when the chevron flips; id alone is not enough.
        let collapsed = TranscriptRowPayload(item: headerRow(expanded: false))
        let expanded = TranscriptRowPayload(item: headerRow(expanded: true))
        // `signature` is private to the host; the public fact is that the kind
        // carries the state and the id stays stable.
        XCTAssertEqual(collapsed.id, expanded.id)
        guard case .processHeader(let left) = collapsed.item?.kind,
              case .processHeader(let right) = expanded.item?.kind else {
            return XCTFail("expected process headers")
        }
        XCTAssertNotEqual(left.isExpanded, right.isExpanded)
    }

    func test_prefetch_status_advances_only_while_loading() {
        XCTAssertEqual(PrefetchStatus.loading(loaded: 0).advanced(by: 120), .loading(loaded: 120))
        XCTAssertEqual(PrefetchStatus.loading(loaded: 120).advanced(by: 0), .loading(loaded: 120))
        XCTAssertEqual(PrefetchStatus.failed.advanced(by: 50), .failed)
    }

    func test_header_with_prefetch_status_preserves_other_fields() {
        let header = TimelineProcessHeader(
            id: "fold-1-3", scope: .turn, turn: 1, startSeq: 3, endSeq: 7,
            toolCount: 230, reasoningCount: 16, messageCount: 1, subagentCount: 0,
            activityCounts: [:], isExpanded: false, isFoldable: true, isRunning: false,
            endReason: "done", duration: 660, hasFailure: false, isPartial: false,
            isPrefetched: true)
        let annotated = header.with(prefetchStatus: .loading(loaded: 150))
        XCTAssertEqual(annotated.prefetchStatus, .loading(loaded: 150))
        XCTAssertEqual(annotated.toolCount, 230)
        XCTAssertEqual(annotated.reasoningCount, 16)
        XCTAssertEqual(annotated.id, header.id)
        XCTAssertTrue(annotated.isPrefetched)
    }
}

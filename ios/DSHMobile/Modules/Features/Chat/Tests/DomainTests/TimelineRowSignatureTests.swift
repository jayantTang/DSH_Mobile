@testable import DSHChatDomain
import DSHKit
import XCTest

/// 列表宿主的**行内容签名**：每一类行的可见内容变了，签名就必须变。
///
/// 回归的现场：分组行/轮次行只带了计数与展开态，`isRunning`/`endReason` 没进签名，
/// 于是轮次结束后行不重载，屏幕上一直写着「正在分析请求」（TC-112 验收轮报的缺陷）。
final class TimelineRowSignatureTests: XCTestCase {

    private func header(scope: TimelineProcessHeader.Scope = .group,
                        isRunning: Bool,
                        endReason: String? = nil,
                        isExpanded: Bool = false) -> TimelineProcessHeader {
        TimelineProcessHeader(
            id: "g-1", scope: scope, turn: 1, startSeq: 3, endSeq: 5,
            toolCount: 1, reasoningCount: 0, messageCount: 0, subagentCount: 0,
            activityCounts: [.commands: 1], isExpanded: isExpanded, isFoldable: true,
            isRunning: isRunning, endReason: endReason, duration: nil,
            hasFailure: false, isPartial: false)
    }

    func test_a_header_signature_changes_when_it_stops_running() {
        let running = TimelineRowSignature.of(header(isRunning: true).item)
        let idle = TimelineRowSignature.of(header(isRunning: false).item)
        XCTAssertNotEqual(running, idle, "运行态变了必须重载，否则「正在分析请求」不消失")
    }

    func test_a_header_signature_changes_when_the_end_reason_arrives() {
        let cancelled = TimelineRowSignature.of(
            header(scope: .turn, isRunning: false, endReason: "interrupted").item)
        let completed = TimelineRowSignature.of(
            header(scope: .turn, isRunning: false, endReason: "completed").item)
        XCTAssertNotEqual(cancelled, completed)
        XCTAssertNotEqual(completed,
                          TimelineRowSignature.of(header(scope: .turn, isRunning: false).item))
    }

    func test_a_header_signature_changes_when_prefetch_progress_moves() {
        let base = header(isRunning: false)
        let loading = base.with(prefetchStatus: .loading(loaded: 10))
        XCTAssertNotEqual(TimelineRowSignature.of(base.item),
                          TimelineRowSignature.of(loading.item))
        XCTAssertNotEqual(TimelineRowSignature.of(loading.item),
                          TimelineRowSignature.of(loading.with(prefetchStatus: .failed).item))
    }

    func test_a_running_line_signature_follows_its_start_time() {
        let first = TimelineRowSignature.of(TimelineRunningLine(since: Date(timeIntervalSince1970: 100)).item)
        let second = TimelineRowSignature.of(TimelineRunningLine(since: Date(timeIntervalSince1970: 200)).item)
        XCTAssertNotEqual(first, second, "新的一轮要重载计时")
    }

    func test_a_step_signature_covers_the_expanded_state() {
        let step = TimelineProcessStep(
            id: "s-1", groupKey: "g-1", turn: 1, seq: 3, kind: .tools,
            name: "bash", preview: "swift build", status: .ok, resultSeq: 4, bytes: 900,
            body: .loaded(text: "OK", bytes: 2))
        let closed = TimelineRowSignature.of(step.with(body: step.body, isExpanded: false).item)
        let open = TimelineRowSignature.of(step.with(body: step.body, isExpanded: true).item)
        XCTAssertNotEqual(closed, open, "收起不重载就会一直停在展开态")
    }

    func test_a_step_signature_covers_the_fetched_body() {
        let step = TimelineProcessStep(
            id: "s-1", groupKey: "g-1", turn: 1, seq: 3, kind: .tools,
            name: "bash", preview: "swift build", status: .ok, resultSeq: 4, bytes: 900)
        let before = TimelineRowSignature.of(step.item)
        let loading = TimelineRowSignature.of(step.with(body: .loading).item)
        let loaded = TimelineRowSignature.of(step.with(body: .loaded(text: "OK", bytes: 2)).item)
        let tooLarge = TimelineRowSignature.of(step.with(body: .tooLarge).item)
        XCTAssertEqual(Set([before, loading, loaded, tooLarge]).count, 4)
    }
}

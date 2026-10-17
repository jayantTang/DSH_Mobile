import XCTest
@testable import DSHKit

/// 上行状态回标（`markSendStates`）：三种「未完成」状态的互斥关系。
///
/// 2026-10-17 之前的缺口：`.sent` 只清 `sendFailed`，`isPending` 从不被清；
/// 于是只要出现一次「状态转 sent 但没重折」的路径，行就永远停在「等待开始」。
/// 今天补上的第四态 `unconfirmed`（宿主撤单、轮次以错误结束）也必须让
/// 「等待开始」停下来，否则界面会宣称一个宿主永远不会开始的消息。
final class SendStateTests: XCTestCase {

    private func timelineWithUserMessage(seq: Int = 7) -> ChatTimeline {
        var timeline = ChatTimeline()
        let json = #"""
        {"type":"user/message","seq":\#(seq),"time":1789276358732,
         "data":{"content":[{"type":"text","text":"怎么样了"}],
                 "source":{"kind":"user","rpcId":"CDA9E63B-3CD5-4741-83EA-BDF6DF9A033F"},
                 "role":"user","id":"m-1"}}
        """#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        _ = timeline.apply(event)
        return timeline
    }

    private func flags(_ timeline: ChatTimeline, at index: Int = 0) -> (pending: Bool, failed: Bool, unconfirmed: Bool) {
        guard case .userMessage(_, _, _, let pending, _) = timeline.items[index].kind else {
            return (false, false, false)
        }
        return (pending, timeline.items[index].sendFailed, timeline.items[index].sendUnconfirmed)
    }

    func testPendingRowShowsOnlyTheWaitingBadge() {
        var timeline = timelineWithUserMessage()
        timeline.markSendStates([7: .pending])
        XCTAssertEqual(flags(timeline).pending, true)
        XCTAssertEqual(flags(timeline).failed, false)
        XCTAssertEqual(flags(timeline).unconfirmed, false)
    }

    /// 未确认不是「等待开始」：宿主不会开始它了，徽标必须换掉。
    func testUnconfirmedRowStopsReadingAsWaitingToStart() {
        var timeline = timelineWithUserMessage()
        timeline.markSendStates([7: .pending])
        timeline.markSendStates([7: .unconfirmed])
        XCTAssertEqual(flags(timeline).pending, false, "未确认的行不能继续显示「等待开始」")
        XCTAssertEqual(flags(timeline).unconfirmed, true)
        XCTAssertEqual(flags(timeline).failed, false, "未确认不等于没发出去，不能给重发入口")
    }

    /// 回归：进入 sent 必须把 pending / failed / unconfirmed 全部清掉。
    func testSentClearsEveryOtherFlag() {
        var timeline = timelineWithUserMessage()
        timeline.markSendStates([7: .unconfirmed])
        timeline.markSendStates([7: .sent])
        let state = flags(timeline)
        XCTAssertFalse(state.pending)
        XCTAssertFalse(state.failed)
        XCTAssertFalse(state.unconfirmed)
    }

    func testFailedRowIsNotPendingAndNotUnconfirmed() {
        var timeline = timelineWithUserMessage()
        timeline.markSendStates([7: .pending])
        timeline.markSendStates([7: .failed])
        XCTAssertEqual(flags(timeline).failed, true)
        XCTAssertEqual(flags(timeline).pending, false)
        XCTAssertEqual(flags(timeline).unconfirmed, false)
    }
}

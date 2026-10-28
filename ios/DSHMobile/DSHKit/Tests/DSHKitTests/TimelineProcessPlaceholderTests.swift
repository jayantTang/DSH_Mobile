import DSHKit
import Foundation
import XCTest

/// 过程区占位行（设计 `20261027-折叠抖动-方案A.md` M7）的外围口径：
/// 固定高度、三态、身份与排序键、不参与搜索/回收/窗口边界。
///
/// 这一行不是日志行：它是显示投影在「尾轮边界未确认」时输出的**唯一**一行，
/// 代表「这一轮的过程状态还不知道」。这些用例钉的是它对**外围系统**的承诺
/// （搜索、载荷预算、窗口下界），不是内部实现。
final class TimelineProcessPlaceholderTests: XCTestCase {

    private func placeholder(turn: Int = 7, startSeq: Int = 100,
                             state: TimelineProcessPlaceholder.State = .unresolved)
        -> TimelineProcessPlaceholder {
        TimelineProcessPlaceholder(turn: turn, startSeq: startSeq, state: state)
    }

    // MARK: - 形态

    func test_placeholder_height_is_fixed() {
        // 44pt 与缺口行同一纪律：首帧不许「先占位后变高」（设计 M7 / §6 第 7 条）。
        XCTAssertEqual(TimelineProcessPlaceholder.height, 44)
    }

    func test_placeholder_identity_and_seq_follow_the_turn_start() {
        let item = placeholder(turn: 7, startSeq: 100).item
        XCTAssertEqual(item.id, "process-unknown:100")
        XCTAssertEqual(item.seq, 100, "seq 取轮次起点，参与裁剪前缀比较")
    }

    func test_the_three_states_are_distinct() {
        let unresolved = placeholder(state: .unresolved)
        let resolving = placeholder(state: .resolving)
        let failed = placeholder(state: .failed(.read))
        XCTAssertNotEqual(unresolved, resolving)
        XCTAssertNotEqual(resolving, failed)
        XCTAssertNotEqual(failed, placeholder(state: .failed(.timeout)))
    }

    func test_with_state_keeps_identity() {
        let base = placeholder(turn: 3, startSeq: 42)
        let next = base.with(state: .failed(.hole))
        XCTAssertEqual(next.id, base.id, "状态变了行身份不许变")
        XCTAssertEqual(next.startSeq, 42)
        XCTAssertEqual(next.state, .failed(.hole))
    }

    // MARK: - 外围口径（M7：不参与搜索 / 回收 / 窗口边界）

    func test_placeholder_is_not_searchable() {
        let items = [placeholder(turn: 7, startSeq: 100).item]
        for query in ["过程区状态未确认", "Process status not confirmed", "process-unknown"] {
            XCTAssertTrue(TranscriptSearch.hits(in: items, query: query).isEmpty,
                          "占位行不进搜索：\(query)")
        }
    }

    func test_placeholder_is_never_reclaimed() {
        let row = placeholder().item
        var payload = TranscriptRowPayload(item: row, height: TimelineProcessPlaceholder.height)
        XCTAssertEqual(payload.payloadBytes, 0, "显示行没有磁盘正文，不计入预算")
        payload.reclaim()
        XCTAssertFalse(payload.isReclaimed, "显示行没有记录可水合，回收了也取不回来")
        guard case .processPlaceholder = row.kind else { return XCTFail("kind 不对") }
        XCTAssertEqual(TranscriptRowPayload.kind(of: row), .processPlaceholder)
    }

    func test_placeholder_is_not_a_content_row() {
        XCTAssertFalse(placeholder().item.kind.isContentRow,
                       "占位行与缺口行同列：不当窗口边界、不做命中归属")
        // 数据行仍是数据行：这条断言防止「一律 false」把窗口边界判定一起废掉。
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data("""
        {"type":"user/message","seq":200,"time":1789276358732,
         "data":{"content":[{"type":"text","text":"hi"}],
                 "source":{"kind":"user","rpcId":"r200"},"role":"user","id":"m200"}}
        """.utf8))
        var timeline = ChatTimeline()
        timeline.reset(with: [SessionRecord(event: event)])
        XCTAssertTrue(timeline.items[0].kind.isContentRow)
        XCTAssertEqual(timeline.firstContentSeq, 200)
    }
}

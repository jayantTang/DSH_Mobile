import DSHKit
import Foundation
import XCTest

/// 尾轮边界（`ChatTimeline.tail`）的三态状态机与 `reset` 的显式种子
/// （设计 `20261027-折叠抖动-方案A.md` M1 / §2.2 / §2.3）。
///
/// 这里钉的是**数据层事实**：边界只由宿主事件与调用方种子决定，不由
/// 「窗口里恰好有没有边界行」推断。旧实现的推断（`previousTurnOpen` +
/// `settlesTurn`）在本次改动里被删除，相应断言改写见改动记录。
final class TimelineTailTests: XCTestCase {

    // MARK: - 夹具

    private func event(_ json: String) throws -> SessionEvent {
        try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
    }

    private func record(_ json: String) throws -> SessionRecord {
        SessionRecord(event: try event(json))
    }

    private func turnStart(seq: Int, turn: Int, time: Double? = nil) throws -> SessionRecord {
        let stamp = time.map { ",\"time\":\($0)" } ?? ""
        return try record(#"{"type":"turn/start","seq":\#(seq)\#(stamp),"data":{"turn":\#(turn)}}"#)
    }

    private func turnEnd(seq: Int, turn: Int, reason: String = "completed") throws -> SessionRecord {
        try record("""
        {"type":"turn/end","seq":\(seq),"data":{"turn":\(turn),"reason":{"kind":"\(reason)"}}}
        """)
    }

    private func toolCall(seq: Int, turn: Int = 1, callId: String = "c1") throws -> SessionRecord {
        try record("""
        {"type":"tool/call","seq":\(seq),"data":{"turn":\(turn),"step":1,
         "callId":"\(callId)","name":"bash","arguments":"{}"}}
        """)
    }

    /// 一条 v2 概要：`endReason` 为 nil 表示「这一段还没结束」。
    private func summary(seq: Int, turn: Int, startSeq: Int, endSeq: Int,
                         startedAt: Double? = nil, endReason: String? = nil) throws -> SessionRecord {
        let start = startedAt.map { ",\"startedAt\":\($0)" } ?? ""
        let reason = endReason.map { ",\"endReason\":\"\($0)\"" } ?? ",\"endReason\":null"
        return try record("""
        {"type":"+link/fold","seq":\(seq),"data":{"v":2,"turn":\(turn),
         "startSeq":\(startSeq),"endSeq":\(endSeq)\(start)\(reason),
         "activities":{},
         "groups":[{"startSeq":\(startSeq),"endSeq":\(endSeq),"activities":{},
           "toolCount":1,"steps":[{"seq":\(startSeq),"kind":"tools","name":"bash",
             "preview":"swift build","status":"running"}]}]}}
        """)
    }

    // MARK: - reset 不再推断（旧行为被删除）

    func test_reset_does_not_infer_running_from_absent_boundary() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try turnStart(seq: 1, turn: 1).event)
        XCTAssertTrue(timeline.isTurnOpen, "前置：这一轮确实是开着的")

        // 窗口里只有过程行，没有任何轮次边界。调用方没给种子：不许再「记住上次开着」。
        _ = timeline.reset(with: [try toolCall(seq: 2)])

        XCTAssertFalse(timeline.isTurnOpen)
        XCTAssertEqual(timeline.tail.boundary, .unknown)
    }

    func test_reset_seeds_open_turn_from_caller() throws {
        let started = Date(timeIntervalSince1970: 1_789_276_358)
        var timeline = ChatTimeline()
        _ = timeline.reset(with: [try toolCall(seq: 2)],
                           seeding: .open(turn: 3, startedAt: started))

        XCTAssertTrue(timeline.isTurnOpen, "种子说开着就是开着")
        XCTAssertEqual(timeline.tail.boundary, .open(turn: 3, startedAt: started))
        XCTAssertEqual(timeline.openTurnStartedAt, started,
                       "计时起点取种子里的宿主时间，不拿「现在」顶替")
    }

    func test_replayed_weaker_evidence_cannot_overwrite_the_seed() throws {
        // 种子（调用方给的边界）在回放**之前**写；窗口里的概要只能补细节，
        // 不能用同一个轮的另一个 startedAt 把种子盖掉。
        let seeded = Date(timeIntervalSince1970: 1_000)
        var timeline = ChatTimeline()
        _ = timeline.reset(with: [try summary(seq: 3, turn: 2, startSeq: 3, endSeq: 4,
                                              startedAt: 2_000_000)],
                           seeding: .open(turn: 2, startedAt: seeded))
        XCTAssertEqual(timeline.tail.boundary, .open(turn: 2, startedAt: seeded))
        XCTAssertEqual(timeline.openTurnStartedAt, seeded)
    }

    // MARK: - 合并表（§2.2）

    func test_turn_start_then_end_closes_tail() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try turnStart(seq: 1, turn: 2).event)
        XCTAssertEqual(timeline.tail.boundary.turn, 2)
        XCTAssertTrue(timeline.tail.boundary.isOpen)

        _ = timeline.apply(try turnEnd(seq: 2, turn: 2).event)
        XCTAssertEqual(timeline.tail.boundary, .closed(turn: 2, reason: "completed"))
        XCTAssertFalse(timeline.isTurnOpen)
        XCTAssertNil(timeline.openTurnStartedAt)
    }

    func test_stale_turn_end_does_not_close_a_newer_open_turn() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try turnStart(seq: 1, turn: 3).event)
        // 重连重放：旧轮的结束晚到。旧的结束不得覆盖新的开始。
        _ = timeline.apply(try turnEnd(seq: 2, turn: 2).event)

        XCTAssertTrue(timeline.isTurnOpen)
        XCTAssertEqual(timeline.tail.boundary.turn, 3)
    }

    func test_summary_replay_cannot_reopen_a_closed_turn() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try turnStart(seq: 1, turn: 1).event)
        _ = timeline.apply(try turnEnd(seq: 2, turn: 1).event)
        XCTAssertEqual(timeline.tail.boundary, .closed(turn: 1, reason: "completed"))

        // 同一轮又开了一次：这是宿主的协议违规（重连重放），按 closed 处理。
        _ = timeline.apply(try summary(seq: 3, turn: 1, startSeq: 3, endSeq: 4,
                                       startedAt: 1_000).event)
        XCTAssertEqual(timeline.tail.boundary, .closed(turn: 1, reason: "completed"))
        XCTAssertFalse(timeline.isTurnOpen, "同一轮已结束是终态，重放的概要不得重开")

        // 更高轮次的开着的一段，才允许打开。
        _ = timeline.apply(try summary(seq: 5, turn: 2, startSeq: 5, endSeq: 6,
                                       startedAt: 2_000).event)
        XCTAssertTrue(timeline.isTurnOpen)
        XCTAssertEqual(timeline.tail.boundary.turn, 2)
        XCTAssertEqual(timeline.openTurnStartedAt,
                       Date(timeIntervalSince1970: 2))
    }

    func test_a_closed_summary_closes_the_tail() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(try summary(seq: 3, turn: 1, startSeq: 3, endSeq: 4,
                                       startedAt: 1_000, endReason: "completed").event)
        XCTAssertEqual(timeline.tail.boundary, .closed(turn: 1, reason: "completed"))
        XCTAssertFalse(timeline.isTurnOpen)
    }

    func test_streaming_start_opens_tail_without_started_at() throws {
        var timeline = ChatTimeline()
        _ = timeline.apply(AssistantStreamFrame.start(attemptId: "a", revision: 0,
                                                      turn: 5, step: 1, startedAfterSeq: 4))
        XCTAssertTrue(timeline.isTurnOpen)
        XCTAssertEqual(timeline.tail.boundary, .open(turn: 5, startedAt: nil))
        XCTAssertNil(timeline.openTurnStartedAt, "流式开始不带宿主时间：宁可为 nil，不拿「现在」顶替")
    }

    // MARK: - showsTail（窗口是否落在会话尾部）

    func test_reset_with_shows_tail_false_marks_detached_window() throws {
        var timeline = ChatTimeline()
        _ = timeline.reset(with: [try toolCall(seq: 20)],
                           seeding: .closed(turn: 1, reason: "completed"),
                           showsTail: false)
        XCTAssertFalse(timeline.tail.showsTail)
        XCTAssertEqual(timeline.tail.boundary, .closed(turn: 1, reason: "completed"),
                       "边界原样带过来：搜索窗口不改「这一轮到底结没结束」")
    }

    func test_live_events_and_snapshots_mark_the_window_as_the_tail() throws {
        var timeline = ChatTimeline()
        _ = timeline.reset(with: [try toolCall(seq: 20)], showsTail: false)
        XCTAssertFalse(timeline.tail.showsTail)

        _ = timeline.apply(try turnStart(seq: 21, turn: 2).event)
        XCTAssertTrue(timeline.tail.showsTail, "实时事件说明窗口底下就是尾部")

        _ = timeline.reset(with: [try toolCall(seq: 20)], showsTail: false)
        _ = timeline.merge(snapshot: [try toolCall(seq: 22, callId: "c2")])
        XCTAssertTrue(timeline.tail.showsTail, "跟尾快照同样说明窗口落在尾部")
    }

    func test_the_default_tail_is_unknown_and_shows_the_tail() {
        XCTAssertEqual(TranscriptTail.unknown.boundary, .unknown)
        XCTAssertTrue(TranscriptTail.unknown.showsTail)
        XCTAssertFalse(TranscriptTail.unknown.boundary.isOpen)
        XCTAssertFalse(TranscriptTail.unknown.boundary.isClosed)
        XCTAssertTrue(TranscriptTail.unknown.boundary.isUnknown)
    }
}

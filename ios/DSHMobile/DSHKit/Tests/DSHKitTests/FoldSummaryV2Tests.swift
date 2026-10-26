import Foundation
import XCTest

@testable import DSHKit

/// 概要 v2（能力 `history-fold-summary-v2`，`fold: "summary"`）的协议层。
///
/// 与 v1 的分界是记录里的 `v: 2`：v1 是一条过程段摘要（`foldedCount` 那套），
/// 时间线把它插成一行 `processHeader`；v2 是**整轮的元数据**（分组 + 步骤），
/// 解码成独立模型 `FoldSummaryV2`，不占任何可见行 —— 轮次/分组/步骤由投影生成。
final class FoldSummaryV2Tests: XCTestCase {

    // MARK: - 夹具（JSON，与连接器回包同形）

    /// 一轮的 v2 窗口：讲话 + 两条概要（中间夹一段讲话）+ 回答 + 轮次边界。
    private static let window = """
    {"records":[
      {"event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
      {"event":{"type":"user/message","seq":2,"time":1001,"data":{
        "id":"m-1",
        "source":{"kind":"user","rpcId":"r-1"},
        "content":[{"type":"text","text":"看一下构建"}]}}},
      {"event":{"type":"+link/fold","seq":3,"time":1002,"data":{
        "v":2,"turn":1,"startSeq":3,"endSeq":5,"durationMs":12345,"endReason":"completed",
        "activities":{"commands":1,"readImage":1,"mystery":3},
        "groups":[{"startSeq":3,"endSeq":5,"activities":{"commands":1},"toolCount":1,
          "steps":[
            {"seq":3,"kind":"tools","name":"bash","preview":"swift build","status":"ok","resultSeq":4,"bytes":900},
            {"seq":5,"kind":"reasoning","name":"thinking","preview":"","status":"ok","bytes":1500}]}]}}},
      {"event":{"type":"assistant/message","seq":6,"time":1005,"data":{
        "turn":1,"step":2,
        "message":{"role":"assistant","content":[{"type":"text","text":"先看包，再跑两条命令"}]}}}},
      {"event":{"type":"+link/fold","seq":7,"time":1006,"data":{
        "v":2,"turn":1,"startSeq":7,"endSeq":8,"durationMs":12345,"endReason":"completed",
        "activities":{"read":1},
        "groups":[{"startSeq":7,"endSeq":8,"activities":{"read":1},"toolCount":1,
          "steps":[
            {"seq":7,"kind":"tools","name":"read","preview":"{\\"path\\":\\"a.swift\\"}","status":"error","resultSeq":8,"bytes":12}]}]}}},
      {"event":{"type":"assistant/message","seq":9,"time":1009,"data":{
        "turn":1,"step":3,
        "message":{"role":"assistant","content":[{"type":"text","text":"构建通过"}]}}}},
      {"event":{"type":"turn/end","seq":10,"time":1010,"data":{"turn":1,"reason":{"kind":"completed"}}}}
    ],"startSeq":1,"endSeq":10,"hasMore":true}
    """

    private func window() throws -> HistoryWindowValue {
        try JSONDecoder().decode(HistoryWindowValue.self, from: Data(Self.window.utf8))
    }

    private func timeline() throws -> ChatTimeline {
        var timeline = ChatTimeline()
        timeline.reset(with: try window().records)
        return timeline
    }

    // MARK: - 解码

    func test_a_v2_record_decodes_groups_steps_and_activity_counts() throws {
        let value = try window()
        let foldRecords = value.records.filter { $0.event.type == "+link/fold" }
        XCTAssertEqual(foldRecords.count, 2)
        let first = try XCTUnwrap(FoldSummaryV2.decode(foldRecords[0].event))
        XCTAssertEqual(first.turn, 1)
        XCTAssertEqual(first.startSeq, 3)
        XCTAssertEqual(first.endSeq, 5)
        XCTAssertEqual(try XCTUnwrap(first.duration), 12.345, accuracy: 0.0001)
        XCTAssertEqual(first.endReason, "completed")
        // 线名 → 手机的活动类别：readImage 归 read，不认识的键按 tools 计（与工具名分类同口径）。
        XCTAssertEqual(first.activities[.commands], 1)
        XCTAssertEqual(first.activities[.read], 1)
        XCTAssertEqual(first.activities[.tools], 3)

        XCTAssertEqual(first.groups.count, 1)
        let group = try XCTUnwrap(first.groups.first)
        XCTAssertEqual(group.startSeq, 3)
        XCTAssertEqual(group.endSeq, 5)
        XCTAssertEqual(group.toolCount, 1)
        XCTAssertEqual(group.activities[.commands], 1)
        XCTAssertEqual(group.reasoningCount, 1)
        XCTAssertEqual(group.steps.count, 2)

        let tool = try XCTUnwrap(group.steps.first)
        XCTAssertEqual(tool.seq, 3)
        XCTAssertEqual(tool.kind, .tools)
        XCTAssertEqual(tool.name, "bash")
        XCTAssertEqual(tool.preview, "swift build")
        XCTAssertEqual(tool.status, .ok)
        XCTAssertEqual(tool.resultSeq, 4)
        XCTAssertEqual(tool.bytes, 900)

        let thinking = try XCTUnwrap(group.steps.last)
        XCTAssertEqual(thinking.kind, .reasoning)
        XCTAssertEqual(thinking.name, "thinking")
        XCTAssertTrue(thinking.preview.isEmpty)
        XCTAssertNil(thinking.resultSeq)

        let second = try XCTUnwrap(FoldSummaryV2.decode(foldRecords[1].event))
        let read = try XCTUnwrap(second.groups.first?.steps.first)
        XCTAssertEqual(read.name, "read")
        XCTAssertEqual(read.status, .error)
        XCTAssertEqual(read.resultSeq, 8)
        XCTAssertEqual(read.bytes, 12)
    }

    func test_a_v1_record_is_not_a_v2_summary() throws {
        // v1（`fold: true`）的记录没有 `v` 键，字段是 `foldedCount` 那一套；
        // 它必须继续走老的 processHeader 路径，不能被当成 v2。
        let json = """
        {"type":"+link/fold","seq":3,"data":{"turn":1,"startSeq":3,"endSeq":4,
          "toolCount":2,"reasoningCount":1,"messageCount":1,"subagentCount":0,
          "endReason":"done","durationMs":1200,"foldedCount":2}}
        """
        let event = try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        XCTAssertNil(FoldSummaryV2.decode(event))
    }

    // MARK: - 时间线：独立模型，不占可见行

    func test_a_v2_record_does_not_become_a_process_header() throws {
        let timeline = try timeline()
        XCTAssertEqual(timeline.foldSummaries.count, 2, "每段一条概要，按 seq 排好")
        XCTAssertEqual(timeline.foldSummaries.map(\.startSeq), [3, 7])
        XCTAssertFalse(timeline.items.contains { item in
            if case .processHeader = item.kind { return true }
            return false
        }, "v2 概要不是一行 processHeader；分组与步骤由投影生成")
        // 讲话与回答照旧是普通行。
        XCTAssertEqual(timeline.items.filter { item in
            if case .assistantText = item.kind { return true }
            return false
        }.count, 2)
    }

    func test_applying_the_same_v2_record_twice_keeps_one_summary_and_reset_clears_it() throws {
        var timeline = try timeline()
        let value = try window()
        let foldRecord = try XCTUnwrap(value.records.first { $0.event.type == "+link/fold" })
        timeline.apply(foldRecord.event)
        XCTAssertEqual(timeline.foldSummaries.count, 2, "同一段重放不能多一条概要")

        timeline.reset(with: [])
        XCTAssertTrue(timeline.foldSummaries.isEmpty)
    }

    func test_prepending_an_older_page_keeps_both_summaries_in_seq_order() throws {
        var timeline = try timeline()
        let olderJSON = """
        {"records":[
          {"event":{"type":"turn/start","seq":-4,"time":900,"data":{"turn":0}}},
          {"event":{"type":"user/message","seq":-3,"time":901,"data":{
            "source":{"kind":"user","rpcId":"r-0"},
            "content":[{"type":"text","text":"更早一句"}]}}},
          {"event":{"type":"+link/fold","seq":-2,"time":902,"data":{
            "v":2,"turn":0,"startSeq":-2,"endSeq":-1,"activities":{"commands":1},
            "groups":[{"startSeq":-2,"endSeq":-1,"activities":{"commands":1},"toolCount":1,
              "steps":[{"seq":-2,"kind":"tools","name":"bash","preview":"ls","status":"ok","resultSeq":-1,"bytes":3}]}]}}},
          {"event":{"type":"turn/end","seq":-1,"time":903,"data":{"turn":0,"reason":{"kind":"completed"}}}}
        ],"startSeq":-4,"endSeq":-1,"hasMore":false}
        """
        let older = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(olderJSON.utf8))
        timeline.prepend(older: older.records)
        XCTAssertEqual(timeline.foldSummaries.map(\.startSeq), [-2, 3, 7])
    }

    // MARK: - 步骤行（元数据行，正文按需取）

    func test_a_step_row_carries_no_body_and_points_at_the_record_to_fetch() throws {
        let step = TimelineProcessStep(
            id: "process-step:g:7-tools", groupKey: "g", turn: 1, seq: 7,
            kind: .tools, name: "read", preview: "a.swift", status: .ok,
            resultSeq: 8, bytes: 12)
        // 元数据行没有正文载荷，也不能被回收成占位（它不是重型行）。
        let payload = TranscriptRowPayload(item: step.item)
        XCTAssertEqual(payload.payloadBytes, 0)
        XCTAssertEqual(TranscriptRowPayload.kind(of: step.item), .processStep)
        var reclaimed = payload
        reclaimed.reclaim()
        XCTAssertFalse(reclaimed.isReclaimed)
        // 按需取数：正好盖住结果那一条（before 是开区间上界，limit 1，不再折）。
        let request = step.detailRequest(address: .session(sessionId: "s"), encoding: "deflate-raw")
        XCTAssertEqual(request.before, 9)
        XCTAssertEqual(request.limit, 1)
        XCTAssertNil(request.fold)
        XCTAssertEqual(request.encoding, "deflate-raw")

        let thinking = TimelineProcessStep(
            id: "process-step:g:5-reasoning", groupKey: "g", turn: 1, seq: 5,
            kind: .reasoning, name: "thinking", preview: "", status: .ok, bytes: 1500)
        XCTAssertEqual(thinking.bodySeq, 5, "思考正文就在自己那条记录里")
        XCTAssertNil(thinking.activity, "思考不是一种已完成的活动")
    }

    func test_pruning_drops_the_summaries_before_the_turn_aligned_cut() throws {
        var timeline = try timeline()
        XCTAssertEqual(timeline.foldSummaries.map(\.startSeq), [3, 7])
        // 裁剪线是留着那个轮次的起点（turn.startSeq），不是"第一条剩下的行"——
        // 一轮的过程可以整段都在概要里，窗口里没有行代表它。
        timeline.pruneFoldSummaries(before: 7)
        XCTAssertEqual(timeline.foldSummaries.map(\.startSeq), [7])
        timeline.pruneFoldSummaries(before: 7)
        XCTAssertEqual(timeline.foldSummaries.map(\.startSeq), [7], "重放同一条裁剪线必须幂等")
    }

    // MARK: - 图片（v2 概要页保留 attachment 元数据）

    func test_assistant_image_blocks_become_agent_sent_picture_rows() throws {
        // 概要 v2 的 `assistant/message` 会带 image 块（只有 attachment 元数据）。
        // 手机侧沿用「agent 发来的图片」那一种行：空正文 + 图片，不是用户气泡。
        let json = """
        {"type":"assistant/message","seq":8,"data":{"turn":1,"step":2,
          "message":{"role":"assistant","content":[
            {"type":"text","text":"图在下面"},
            {"type":"image","attachment":{"attachmentId":"att-1","mediaType":"image/png","bytes":1234,"width":640,"height":480}}]}}}
        """
        var timeline = ChatTimeline()
        timeline.apply(try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8)))
        let pictureRows = timeline.items.compactMap { item -> (String, [ContentBlock.ImageAttachment], Bool)? in
            guard case .userMessage(let text, let images, _, _, let isAgentSent) = item.kind,
                  !images.isEmpty else { return nil }
            return (text, images, isAgentSent)
        }
        XCTAssertEqual(pictureRows.count, 1, "一行图片，不是两行也不是零行")
        XCTAssertEqual(pictureRows.first?.0, "", "图片行正文为空；文字仍由正文行承担")
        XCTAssertEqual(pictureRows.first?.1.first?.attachmentId, "att-1")
        XCTAssertEqual(pictureRows.first?.1.first?.width, 640)
        XCTAssertEqual(pictureRows.first?.2, true, "助手发出的图片按 agent 侧显示")
    }

    func test_a_human_message_and_its_splice_echo_collapse_into_one_row() throws {
        // v2 页里同一条消息可能出现两次：`user/message` 与 `agent/inbox/spliced`
        // 的本地回声。两者带同一个 rpcId，必须合成一行，不能出现两张一样的图。
        // 两种先后都要成立：真实日志是回声在前、落定记录在后；窗口重读/合并时
        // 也可能把回声再放一次（不能覆盖已落定那一行）。
        let durable = """
        {"event":{"type":"user/message","seq":3,"data":{
          "source":{"kind":"user","rpcId":"r-7"},
          "content":[{"type":"text","text":"这张图"},
            {"type":"image","attachment":{"attachmentId":"att-7","mediaType":"image/png"}}]}}}
        """
        let echo = """
        {"event":{"type":"agent/inbox/spliced","seq":2,"data":{
          "target":"next-turn",
          "inserted":[{"source":{"kind":"user","rpcId":"r-7"},
            "content":[{"type":"image","attachment":{"attachmentId":"att-7","mediaType":"image/png"}}]}]}}}
        """
        for order in [[echo, durable], [durable, echo]] {
            let json = #"{"records":["# + order.joined(separator: ",")
                + #"],"startSeq":2,"endSeq":3,"hasMore":false}"#
            let value = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(json.utf8))
            var timeline = ChatTimeline()
            timeline.reset(with: value.records)
            let userRows = timeline.items.filter { item in
                if case .userMessage = item.kind { return true }
                return false
            }
            XCTAssertEqual(userRows.count, 1, "rpcId 相同的回声必须合并：\(timeline.items.map(\.id))")
            guard case .userMessage(let text, let images, _, _, _) = userRows[0].kind else {
                return XCTFail("expected a user message row")
            }
            XCTAssertEqual(text, "这张图")
            XCTAssertEqual(images.count, 1)
        }
    }
}

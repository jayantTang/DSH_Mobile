@testable import DSHChatDomain
import DSHKit
import XCTest

/// M6：概要 v2 的轮次/分组/步骤投影（纯函数，JSON 夹具，不连网）。
///
/// 口径来自设计 `20261025-过程折叠-对齐桌面` §3.4 / §4.4 / M6：
/// - 收起 = 轮次行 + 回答；中间讲话、工具、思考都不出现；
/// - 展开 = 分组行（来自 `groups`）+ 组内步骤行（来自 `steps` 元数据），
///   中间讲话按 seq 插在组之间；
/// - 步骤行只有元数据，正文为空、按需取；不伪造 tool/result 行；
/// - 图片回答（agent 代发的图片）按正式回答处理，收起态可见；
/// - v1（没有概要的旧页面）与默认调用完全不变。
final class TranscriptProcessFoldSummaryTests: XCTestCase {

    private func plan(_ timeline: ChatTimeline) -> TranscriptProcessFold.Plan {
        FoldSummaryV2Fixtures.plan(timeline)
    }

    private func headers(_ rows: [TimelineItem]) -> [TimelineProcessHeader] {
        rows.compactMap { item in
            if case .processHeader(let header) = item.kind { return header }
            return nil
        }
    }

    private func steps(_ rows: [TimelineItem]) -> [TimelineProcessStep] {
        rows.compactMap { item in
            if case .processStep(let step) = item.kind { return step }
            return nil
        }
    }

    private func texts(_ rows: [TimelineItem]) -> [String] {
        rows.compactMap { item in
            if case .assistantText(let text) = item.kind { return text }
            return nil
        }
    }

    // MARK: - 收起态

    func test_a_collapsed_summary_turn_is_one_turn_row_and_the_answer() throws {
        let timeline = try FoldSummaryV2Fixtures.timeline(FoldSummaryV2Fixtures.twoGroupWindow)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.summaries.count, 2, "同轮的两段概要都归这一轮")
        XCTAssertTrue(turn.isFoldable)

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertEqual(rows.count, 3, "收起态只有问题、轮次行、回答：\(rows.map(\.id))")
        guard case .userMessage = rows[0].kind else { return XCTFail("first row must be the question") }
        let header = try XCTUnwrap(self.headers(rows).first)
        XCTAssertEqual(header.scope, .turn)
        XCTAssertFalse(header.isExpanded)
        XCTAssertFalse(header.isPrefetched)
        XCTAssertEqual(header.endReason, "completed")
        XCTAssertEqual(header.toolCount, 2)
        XCTAssertEqual(header.reasoningCount, 1)
        XCTAssertEqual(header.duration ?? 0, 139, accuracy: 0.001)
        XCTAssertEqual(texts(rows), ["最终回答一"], "中间讲话在收起态必须隐藏")
        // 没有工具/思考/步骤行，也没有第二条「已完成」。
        XCTAssertFalse(rows.contains { item in
            switch item.kind {
            case .toolCall, .reasoning, .turnDivider, .processStep: return true
            default: return false
            }
        })
        XCTAssertEqual(self.headers(rows).filter { $0.scope == .group }.count, 0)
    }

    // MARK: - 展开态

    func test_expanding_the_turn_shows_group_rows_only() throws {
        let timeline = try FoldSummaryV2Fixtures.timeline(FoldSummaryV2Fixtures.twoGroupWindow)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true

        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        let groups = headers(rows).filter { $0.scope == .group }
        XCTAssertEqual(groups.count, 2, "展开轮次 = 两条分组行（来自 groups）")
        XCTAssertEqual(steps(rows).count, 0, "组默认收起，步骤行还不出现")
        // 中间讲话按 seq 排在两组之间：组 A(3) → 讲话(5) → 组 B(6) → 回答(8)。
        XCTAssertEqual(rows.map(\.id), [
            "user-r-1",
            "turn-process:1",
            "process-group:1:3",
            "assistant-5-0",
            "process-group:1:6",
            "assistant-8-0",
        ])
        XCTAssertEqual(texts(rows), ["中间讲话一", "最终回答一"])
        XCTAssertEqual(groups[0].activityCounts[.commands], 1)
        XCTAssertEqual(groups[1].activityCounts[.read], 1)
        XCTAssertEqual(groups[0].startSeq, 3)
        XCTAssertEqual(groups[0].endSeq, 4)
        XCTAssertTrue(groups[0].isFoldable)
    }

    func test_expanding_a_group_shows_its_step_rows_without_bodies() throws {
        let timeline = try FoldSummaryV2Fixtures.timeline(FoldSummaryV2Fixtures.twoGroupWindow)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.groups.count, 2)
        XCTAssertEqual(turn.groups.flatMap(\.steps).count, 3)

        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        for group in turn.groups { state.expandedGroups.insert(group.key) }
        let rows = TranscriptProcessFold.displayRows(plan, state: state)

        XCTAssertEqual(rows.map(\.id), [
            "user-r-1",
            "turn-process:1",
            "process-group:1:3",
            "process-step:process-group:1:3:3-tools",
            "process-step:process-group:1:3:4-reasoning",
            "assistant-5-0",
            "process-group:1:6",
            "process-step:process-group:1:6:6-tools",
            "assistant-8-0",
        ])
        let stepRows = steps(rows)
        XCTAssertEqual(stepRows.count, 3)
        XCTAssertEqual(stepRows.map(\.name), ["bash", "thinking", "read"])
        XCTAssertEqual(stepRows[0].preview, "swift build")
        XCTAssertEqual(stepRows[0].status, .ok)
        XCTAssertEqual(stepRows[0].bytes, 900)
        XCTAssertEqual(stepRows[0].resultSeq, 4)
        XCTAssertEqual(stepRows[0].groupKey, "process-group:1:3")
        XCTAssertEqual(stepRows[2].status, .error)
        XCTAssertEqual(stepRows[2].bytes, 12)
        // 步骤行没有正文，也不存在任何 tool/result 行。
        XCTAssertEqual(stepRows[0].bodySeq, 4)
        XCTAssertFalse(rows.contains { item in
            if case .toolCall = item.kind { return true }
            return false
        })
    }

    func test_a_step_projection_carries_its_expanded_state_and_changes_the_signature() throws {
        let timeline = try FoldSummaryV2Fixtures.timeline(FoldSummaryV2Fixtures.twoGroupWindow)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var open = TranscriptFoldState()
        open.manualTurn[turn.key] = true
        for group in turn.groups { open.expandedGroups.insert(group.key) }

        let closedRows = TranscriptProcessFold.displayRows(plan, state: open)
        let closedSteps = steps(closedRows)
        XCTAssertFalse(closedSteps.isEmpty)
        XCTAssertTrue(closedSteps.allSatisfy { !$0.isExpanded })
        let id = try XCTUnwrap(closedSteps.first?.id)
        let closedItem = try XCTUnwrap(closedRows.first { $0.id == id })

        var expanded = open
        expanded.expandedSteps.insert(id)
        let openedRows = TranscriptProcessFold.displayRows(plan, state: expanded)
        let openedItem = try XCTUnwrap(openedRows.first { $0.id == id })
        guard case .processStep(let openedStep) = openedItem.kind else {
            return XCTFail("expected a step row")
        }
        XCTAssertTrue(openedStep.isExpanded)
        XCTAssertNotEqual(TimelineRowSignature.of(closedItem), TimelineRowSignature.of(openedItem),
                          "收起/展开必须改变签名，否则列表不会重载，卡片关不掉")
    }

    func test_v2_turn_and_group_wording_matches_the_desktop_wording() throws {
        let timeline = try FoldSummaryV2Fixtures.timeline(FoldSummaryV2Fixtures.twoGroupWindow)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        let turnHeader = try XCTUnwrap(headers(rows).first { $0.scope == .turn })
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: turnHeader.endReason,
                                                 duration: turnHeader.duration),
                       "已完成，用时 2分19秒")
        let groups = headers(rows).filter { $0.scope == .group }
        XCTAssertEqual(groups.map { ProcessFoldText.groupTitle($0.activityCounts) },
                       ["执行了命令", "已读取文件"])
        // 步骤行的名称保留工具本名（卡片标题用它），不被翻译成活动类别。
        var open = state
        for group in turn.groups { open.expandedGroups.insert(group.key) }
        XCTAssertEqual(steps(TranscriptProcessFold.displayRows(plan, state: open)).map(\.name),
                       ["bash", "thinking", "read"])
    }

    func test_prose_before_the_first_group_stays_under_the_turn_row() throws {
        // 一轮可以先说一句再动手：那句讲话的 seq 比第一段概要还小，轮次行必须
        // 落在它上面（桌面也是"轮次行 → 中间讲话 → 分组"）。
        let json = """
        {"records":[
          {"event":{"type":"turn/start","seq":1,"data":{"turn":1}}},
          {"event":{"type":"user/message","seq":2,"data":{"source":{"kind":"user","rpcId":"r-1"},
            "content":[{"type":"text","text":"构建一下"}]}}},
          {"event":{"type":"assistant/message","seq":3,"data":{"turn":1,"step":1,
            "message":{"role":"assistant","content":[{"type":"text","text":"先看包结构"}]}}}},
          {"event":{"type":"+link/fold","seq":4,"data":{"v":2,"turn":1,"startSeq":4,"endSeq":5,
            "durationMs":3000,"endReason":"completed","activities":{"commands":1},
            "groups":[{"startSeq":4,"endSeq":5,"activities":{"commands":1},"toolCount":1,
              "steps":[{"seq":4,"kind":"tools","name":"bash","preview":"swift build","status":"ok","resultSeq":5,"bytes":9}]}]}}},
          {"event":{"type":"assistant/message","seq":6,"data":{"turn":1,"step":2,
            "message":{"role":"assistant","content":[{"type":"text","text":"构建通过"}]}}}},
          {"event":{"type":"turn/end","seq":7,"data":{"turn":1,"reason":{"kind":"completed"}}}}
        ],"startSeq":1,"endSeq":7,"hasMore":false}
        """
        let timeline = try FoldSummaryV2Fixtures.timeline(json)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        let collapsed = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertEqual(collapsed.map(\.id), ["user-r-1", "turn-process:1", "assistant-6-0"])

        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        state.expandedGroups.insert(try XCTUnwrap(turn.groups.first).key)
        XCTAssertEqual(TranscriptProcessFold.displayRows(plan, state: state).map(\.id), [
            "user-r-1",
            "turn-process:1",
            "assistant-3-0",
            "process-group:1:4",
            "process-step:process-group:1:4:4-tools",
            "assistant-6-0",
        ])
    }

    // MARK: - 图片回答

    func test_an_agent_sent_picture_answer_stays_visible_when_collapsed() throws {
        let timeline = try FoldSummaryV2Fixtures.timeline(FoldSummaryV2Fixtures.imageAnswerWindow)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isFoldable)
        XCTAssertEqual(turn.summaries.count, 1)

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        let pictures = rows.compactMap { item -> [ContentBlock.ImageAttachment]? in
            guard case .userMessage(_, let images, _, _, let isAgentSent) = item.kind,
                  isAgentSent, !images.isEmpty else { return nil }
            return images
        }
        XCTAssertEqual(pictures.count, 1, "图片回答必须在收起态可见：\(rows.map(\.id))")
        XCTAssertEqual(pictures.first?.first?.attachmentId, "att-9")
        XCTAssertEqual(headers(rows).filter { $0.scope == .group }.count, 0)

        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        let expanded = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertTrue(expanded.contains { item in
            if case .processHeader(let header) = item.kind, header.scope == .group { return true }
            return false
        })
        XCTAssertEqual(expanded.compactMap { item -> [ContentBlock.ImageAttachment]? in
            if case .userMessage(_, let images, _, _, _) = item.kind, !images.isEmpty { return images }
            return nil
        }.count, 1, "展开后图片仍只有一张")
    }

    // MARK: - 运行中

    func test_a_running_summary_turn_has_no_turn_row_and_names_the_running_step() throws {
        let timeline = try FoldSummaryV2Fixtures.timeline(FoldSummaryV2Fixtures.runningWindow)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isRunning)
        XCTAssertTrue(turn.isFoldable == false, "运行中的轮次没有轮次行")

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertFalse(headers(rows).contains { $0.scope == .turn }, "运行中没有轮次行")
        let groups = headers(rows).filter { $0.scope == .group }
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isRunning, "在跑的那条分组行要能被视图标成运行态")
        XCTAssertEqual(steps(rows).count, 0, "组默认收起")
        XCTAssertEqual(texts(rows), ["先把靶向用例跑起来"])

        // 运行中的当前动作来自概要步骤（v2 没有 tool 行可以扫）。
        let detail = try XCTUnwrap(TranscriptProcessFold.runningDetail(
            in: timeline.items, isTurnOpen: timeline.isTurnOpen,
            summaries: timeline.foldSummaries))
        XCTAssertEqual(detail.activity, .commands)
        XCTAssertEqual(detail.detail, "swift test --filter DSHChatDomainTests")
    }

    // MARK: - 关联（turn 缺失时按 startSeq）

    func test_a_summary_without_a_turn_number_attaches_by_start_seq() throws {
        let timeline = try FoldSummaryV2Fixtures.timeline(FoldSummaryV2Fixtures.nullTurnWindow)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.summaries.count, 1)
        XCTAssertTrue(turn.isFoldable)
        XCTAssertEqual(turn.groups.count, 1)

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertEqual(rows.count, 3, "问题 + 轮次行 + 回答：\(rows.map(\.id))")
        XCTAssertEqual(self.headers(rows).first?.scope, .turn)
        XCTAssertEqual(texts(rows), ["找到了"])

        var expanded = TranscriptFoldState()
        expanded.manualTurn[turn.key] = true
        expanded.expandedGroups.insert(turn.groups[0].key)
        let open = TranscriptProcessFold.displayRows(plan, state: expanded)
        XCTAssertEqual(steps(open).map(\.name), ["grep"])
        XCTAssertEqual(steps(open).first?.preview, "needle")
    }

    // MARK: - 概要覆盖段里的旧原始行 / 运行中的轮次

    func test_raw_process_rows_inside_a_summary_range_are_suppressed() throws {
        // 概要页拿回来之后，follow 快照可能又把同一段的原始工具行带进时间线
        //（快照是宿主的原始事件）。过程的事实来源只能是概要，两份留一份：
        // 否则同一轮会同时出现分组行与旧工具卡，计数也会翻倍。
        let json = """
        {"records":[
          {"event":{"type":"turn/start","seq":1,"data":{"turn":1}}},
          {"event":{"type":"user/message","seq":2,"data":{"source":{"kind":"user","rpcId":"r-1"},
            "content":[{"type":"text","text":"q"}]}}},
          {"event":{"type":"+link/fold","seq":3,"data":{"v":2,"turn":1,"startSeq":3,"endSeq":5,
            "durationMs":4000,"endReason":"completed","activities":{"commands":1},
            "groups":[{"startSeq":3,"endSeq":5,"activities":{"commands":1},"toolCount":1,
              "steps":[{"seq":3,"kind":"tools","name":"bash","preview":"swift build","status":"ok","resultSeq":4,"bytes":900},
                       {"seq":5,"kind":"reasoning","name":"thinking","preview":"","status":"ok","bytes":1500}]}]}}},
          {"event":{"type":"tool/call","seq":4,"data":{"turn":1,"step":1,"callId":"raw-1","name":"bash","arguments":"{}"}}},
          {"event":{"type":"tool/result","seq":5,"data":{"turn":1,"step":1,"message":{"source":{"callId":"raw-1"},
            "content":[{"type":"tool-result","toolCallId":"raw-1","isError":false,
              "content":[{"type":"text","text":"OLD OUTPUT"}]}]}}}},
          {"event":{"type":"assistant/message","seq":6,"data":{"turn":1,"step":2,
            "message":{"role":"assistant","content":[{"type":"text","text":"a"}]}}}},
          {"event":{"type":"turn/end","seq":7,"data":{"turn":1,"reason":{"kind":"completed"}}}}
        ],"startSeq":1,"endSeq":7,"hasMore":false}
        """
        let timeline = try FoldSummaryV2Fixtures.timeline(json)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertEqual(turn.groups.count, 1, "只保留概要那一组")
        XCTAssertTrue(turn.groups[0].isFromSummary)
        XCTAssertEqual(turn.toolCount, 1, "计数只认概要")

        let collapsed = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertEqual(collapsed.map(\.id), ["user-r-1", "turn-process:1", "assistant-6-0"])

        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        state.expandedGroups.insert(turn.groups[0].key)
        let expanded = TranscriptProcessFold.displayRows(plan, state: state)
        XCTAssertFalse(expanded.contains { item in
            switch item.kind {
            case .toolCall, .reasoning: return true
            default: return false
            }
        }, "概要覆盖段里的旧工具/思考行不能再出现")
        XCTAssertEqual(steps(expanded).count, 2)
    }

    func test_a_running_turn_keeps_the_summary_and_the_newer_live_rows() throws {
        // 运行中的一轮：概要是取数那一刻的快照，之后到达的实时行才是当前动作的
        // 真相。两份并存：概要范围里的旧行不显示，比概要新的实时行照常出现，
        // 当前动作从实时行算（不是概要里那条旧命令）。
        let page = """
        {"records":[
          {"event":{"type":"turn/start","seq":1,"data":{"turn":1}}},
          {"event":{"type":"user/message","seq":2,"data":{"source":{"kind":"user","rpcId":"r-1"},
            "content":[{"type":"text","text":"跑起来"}]}}},
          {"event":{"type":"+link/fold","seq":3,"data":{"v":2,"turn":1,"startSeq":3,"endSeq":3,
            "durationMs":null,"endReason":null,"activities":{"commands":1},
            "groups":[{"startSeq":3,"endSeq":3,"activities":{"commands":1},"toolCount":1,
              "steps":[{"seq":3,"kind":"tools","name":"bash","preview":"old command","status":"running"}]}]}}}
        ],"startSeq":1,"endSeq":3,"hasMore":false}
        """
        let window = try JSONDecoder().decode(HistoryWindowValue.self,
                                              from: Data(page.utf8))
        var timeline = ChatTimeline()
        timeline.reset(with: window.records)
        // 概要到手之后实时到达的一条工具调用（管道下行，不经过 reset 的"历史收尾"）。
        let live = """
        {"type":"tool/call","seq":4,"data":{"turn":1,"step":2,"callId":"live-1",
          "name":"read","arguments":"{}"}}
        """
        timeline.apply(try JSONDecoder().decode(SessionEvent.self, from: Data(live.utf8)))

        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isRunning)
        XCTAssertEqual(turn.summaries.count, 1, "概要不丢")
        XCTAssertEqual(turn.groups.count, 2, "概要一组 + 最新实时行一组")
        XCTAssertTrue(turn.groups[0].isFromSummary)
        XCTAssertFalse(turn.groups[1].isFromSummary)

        let rows = TranscriptProcessFold.displayRows(plan, state: TranscriptFoldState())
        XCTAssertFalse(headers(rows).contains { $0.scope == .turn }, "运行中没有轮次行")
        let groups = headers(rows).filter { $0.scope == .group }
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.last?.isRunning == true, "最后那条才是「正在…」的实时行")

        let detail = try XCTUnwrap(TranscriptProcessFold.runningDetail(
            in: timeline.items, isTurnOpen: timeline.isTurnOpen,
            summaries: timeline.foldSummaries.filter { $0.turn == timeline.currentTurn }))
        XCTAssertEqual(detail.activity, .read, "当前动作来自实时行，不是概要里的旧命令")
    }

    func test_a_cancelled_turn_treats_a_still_running_step_as_an_error() throws {
        // 中断/取消时没回来的工具仍在概要里标着 running；轮次已经结束，
        // 这一条不能再算"在跑"——否则分组行被固定成「正在分析请求」，取消后不回落。
        let json = """
        {"records":[
          {"event":{"type":"turn/start","seq":1,"data":{"turn":1}}},
          {"event":{"type":"user/message","seq":2,"data":{"source":{"kind":"user","rpcId":"r-1"},
            "content":[{"type":"text","text":"跑一下"}]}}},
          {"event":{"type":"+link/fold","seq":3,"data":{"v":2,"turn":1,"startSeq":3,"endSeq":3,
            "durationMs":null,"endReason":"interrupted","activities":{"commands":1},
            "groups":[{"startSeq":3,"endSeq":3,"activities":{"commands":1},"toolCount":1,
              "steps":[{"seq":3,"kind":"tools","name":"bash","preview":"sleep 999","status":"running"}]}]}}},
          {"event":{"type":"turn/end","seq":4,"data":{"turn":1,"reason":{"kind":"interrupted"}}}}
        ],"startSeq":1,"endSeq":4,"hasMore":false}
        """
        let timeline = try FoldSummaryV2Fixtures.timeline(json)
        let plan = plan(timeline)
        let turn = try XCTUnwrap(plan.turns.first)
        XCTAssertTrue(turn.isStopped)
        XCTAssertEqual(turn.groups.count, 1)
        let group = turn.groups[0]
        XCTAssertFalse(group.isRunning, "结束的轮次不能再有运行中的分组")
        XCTAssertEqual(group.steps.first?.status, .error, "没回来的工具按失败步骤显示")

        var state = TranscriptFoldState()
        state.manualTurn[turn.key] = true
        let rows = TranscriptProcessFold.displayRows(plan, state: state)
        let header = try XCTUnwrap(headers(rows).first { $0.scope == .group })
        XCTAssertFalse(header.isRunning)
        XCTAssertEqual(ProcessFoldText.groupTitle(header.activityCounts), "执行了命令")
        XCTAssertFalse(ProcessFoldText.runningGroupTitle(activity: .commands, detail: "sleep 999")
            == ProcessFoldText.groupTitle(header.activityCounts))
        XCTAssertNil(TranscriptProcessFold.runningDetail(
            in: timeline.items, isTurnOpen: false, summaries: timeline.foldSummaries))
    }

    // MARK: - v1 / 旧路径不受影响

    func test_a_timeline_without_summaries_projects_exactly_as_before() throws {
        let timeline = try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: 3,
                                               reasoning: 1, intermediate: true))
        let legacy = TranscriptProcessFold.plan(
            items: timeline.items, tail: timeline.tail,
            currentTurn: timeline.currentTurn)
        var state = TranscriptFoldState()
        state.manualTurn[try XCTUnwrap(legacy.turns.first).key] = true
        let before = TranscriptProcessFold.displayRows(legacy, state: state).map(\.id)

        let withEmpty = TranscriptProcessFold.plan(
            items: timeline.items, tail: timeline.tail,
            currentTurn: timeline.currentTurn, summaries: [])
        XCTAssertEqual(TranscriptProcessFold.displayRows(withEmpty, state: state).map(\.id), before)
        XCTAssertEqual(legacy.turns.first?.summaries.count, 0)
    }

    func test_a_summary_that_belongs_to_another_turn_never_attaches() throws {
        let timeline = try ProcessFoldFixtures.timeline(
            ProcessFoldFixtures.completedTurn(turn: 1, startSeq: 1, tools: 2, reasoning: 1))
        let stray = try JSONDecoder().decode(
            HistoryWindowValue.self,
            from: Data(FoldSummaryV2Fixtures.twoGroupWindow.utf8))
        // 拿真实的 v2 概要，但把轮次号改成 window 里没有的 99，seq 挪到窗口之外。
        let summaries = stray.records.compactMap { FoldSummaryV2.decode($0.event) }.map { summary in
            FoldSummaryV2(turn: 99, startSeq: summary.startSeq + 500,
                          endSeq: summary.endSeq + 500,
                          durationMs: summary.durationMs, endReason: summary.endReason,
                          activities: summary.activities, groups: summary.groups)
        }
        XCTAssertEqual(summaries.count, 2)
        let plan = TranscriptProcessFold.plan(
            items: timeline.items, tail: .unknown,
            currentTurn: timeline.currentTurn, summaries: summaries)
        XCTAssertEqual(plan.turns.count, 1)
        XCTAssertEqual(plan.turns[0].summaries.count, 0, "别的轮次的概要不能认领这一段")
    }
}

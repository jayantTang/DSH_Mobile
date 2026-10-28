@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// Integration of the process projection with the real `ChatModel` transport
/// seam: snapshot → fold → display rows → reader actions.
@MainActor
final class ChatModelProcessFoldTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!

    override func setUp() {
        super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        model = ChatModel()
    }

    override func tearDown() async throws {
        model.noteReaderTopRow(nil)
        await model.close()
        hub.stop()
        model = nil
        hub = nil
        carrier = nil
        try await super.tearDown()
    }

    #if DEBUG
    func test_the_ui_fixture_is_two_foldable_completed_turns() {
        var timeline = ChatTimeline()
        _ = timeline.reset(with: ProcessFoldFixture.records)
        let plan = TranscriptProcessFold.plan(items: timeline.items, tail: .unknown)
        XCTAssertEqual(plan.turns.count, 2)
        XCTAssertTrue(plan.turns.allSatisfy(\.isFoldable))
        XCTAssertGreaterThan(plan.turns[0].toolCount, 2)
        XCTAssertGreaterThan(plan.turns[0].groups.count, 0)
        let hits = TranscriptSearch.hits(in: timeline.items, query: "FIXTURE-TOOL-OUTPUT")
        XCTAssertFalse(hits.isEmpty, "the fixture tool output must be searchable")
    }
    #endif

    // MARK: - End-to-end snapshot

    func test_a_completed_turn_folds_on_the_model_surface_and_toggles_back() async throws {
        try await openWithOneCompletedTurn()
        let rows = await eventuallyRows { rows in
            rows.count == 3 && rows.contains(where: { if case .processHeader = $0.kind { return true }; return false })
        }
        // 一行轮次行 + 问题 + 回答：分隔行已并入轮次行。
        XCTAssertEqual(rows.count, 3, "folded rows: \(rows.map(\.id))")
        let header = try XCTUnwrap(rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind { return value }
            return nil
        }.first)
        XCTAssertEqual(header.scope, .turn)
        XCTAssertFalse(header.isExpanded)
        XCTAssertEqual(header.toolCount, 1)
        XCTAssertFalse(rows.map(\.id).contains("tool-call-1"))

        model.toggleProcess(turnKey: header.id)
        // 展开轮次先看到一条分组行；步骤卡要再展开那一组。
        let grouped = await eventuallyRows { rows in
            rows.contains { if case .processHeader(let h) = $0.kind, h.scope == .group { return true }; return false }
        }
        let group = try XCTUnwrap(grouped.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind, value.scope == .group { return value }
            return nil
        }.first)
        XCTAssertFalse(group.isExpanded)
        XCTAssertFalse(grouped.map(\.id).contains("tool-call-1"))

        model.toggleProcessGroup(groupKey: group.id)
        let expanded = await eventuallyRows { $0.map(\.id).contains("tool-call-1") }
        XCTAssertTrue(expanded.map(\.id).contains("tool-call-1"))

        model.toggleProcess(turnKey: header.id)
        let collapsed = await eventuallyRows { !$0.map(\.id).contains("tool-call-1") }
        XCTAssertFalse(collapsed.map(\.id).contains("tool-call-1"))
    }

    /// 旧行为已删除（2026-10-27 折叠抖动）：读者停在过程行上**不再持续**保住整轮。
    ///
    /// 原来每帧都用宿主回传的顶部行重判一次，而折叠结果又决定顶部行——两态互为输入，
    /// 不需要任何数据变化就每帧翻转。现在只在"轮次关闭"那一刻判定一次
    ///（`ChatModelTailHoldTests.test_reader_on_process_row_holds_the_turn_when_it_closes`），
    /// 一次已经结束的轮次不会因为读者停在哪里而展开。
    func test_reporting_a_top_row_never_holds_a_finished_turn_open() async throws {
        try await openWithOneCompletedTurn()
        model.noteReaderTopRow("tool-call-1")
        let rows = await eventuallyRows { $0.count == 3 }
        XCTAssertFalse(rows.map(\.id).contains("tool-call-1"),
                       "已结束的轮次不因读者位置而展开：\(rows.map(\.id))")
        XCTAssertTrue(model.foldState.manualTurn.isEmpty)
    }

    func test_search_reveal_expands_the_turn_and_returns_the_row() async throws {
        try await openWithOneCompletedTurn()
        _ = await eventuallyRows { rows in rows.count == 3 }
        let revealed = model.revealProcess(containingRowID: "tool-call-1")
        XCTAssertEqual(revealed, "tool-call-1")
        let rows = await eventuallyRows { $0.map(\.id).contains("tool-call-1") }
        XCTAssertTrue(rows.map(\.id).contains("tool-call-1"))
        XCTAssertNil(model.revealProcess(containingRowID: "not-here"))
    }

    // MARK: - 运行行（TC-112）

    func test_the_running_line_is_a_row_handed_to_both_list_hosts_and_disappears_when_done() async throws {
        carrier.registerLiveStream("session/follow")
        let fake = FakeLinkService(profiles: [TestFixtures.relayProfile()],
                                   state: .connected(hostHome: "/Users/tester"))
        fake.activeProfile = try XCTUnwrap(fake.profiles.first)
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        model.attach(store: fake, hub: hub)
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 3))
        await carrier.waitForLiveStream("session/follow")

        let running: [JSONValue] = [
            ChatSeam.turnStart(seq: 1, turn: 1),
            ChatSeam.userMessage(seq: 2, text: "q"),
            toolCall(seq: 3, callId: "c1", name: "bash"),
        ]
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 3, records: running))
        let shown = await eventuallyRows { rows in
            rows.contains { if case .runningLine = $0.kind { return true }; return false }
        }
        // 两个宿主（uikit 的 TranscriptListRepresentable / SwiftUI 的 stack）都只吃
        // `rowsFor` 这一份行：运行行在它里面，两边就都有；不在就只能靠尾部视图，
        // uikit 宿主一定看不到（TC-112 的根因）。
        let line = try XCTUnwrap(rowsForRunningLine(shown))
        XCTAssertEqual(line.id, "running-line", "稳定身份：一个会话只有一行运行状态")
        XCTAssertNotNil(line.since, "快照里已经在跑的一轮也要有计时起点")
        XCTAssertFalse(model.timeline.items.contains { item in
            if case .runningLine = item.kind { return true }
            return false
        }, "运行行是显示行，不是日志行")
        XCTAssertTrue(TranscriptSearch.hits(in: model.timeline.items, query: "深度求索").isEmpty,
                      "运行行不参与搜索")

        // 取消/结束：这一行消失（轮次行接管「已停止」）。
        let done = running + [ChatSeam.turnEnd(seq: 4, turn: 1, reason: "interrupted")]
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 4, records: done))
        let gone = await eventuallyRows { rows in
            !rows.contains { if case .runningLine = $0.kind { return true }; return false }
        }
        XCTAssertNil(rowsForRunningLine(gone), "结束之后不能再有运行行：\(gone.map(\.id))")
    }

    private func rowsForRunningLine(_ rows: [TimelineItem]) -> TimelineRunningLine? {
        rows.compactMap { item -> TimelineRunningLine? in
            if case .runningLine(let line) = item.kind { return line }
            return nil
        }.first
    }

    // MARK: - 概要 v2（M6）

    func test_a_v2_summary_window_folds_with_groups_and_step_rows_on_the_model_surface() async throws {
        carrier.registerLiveStream("session/follow")
        let fake = FakeLinkService(profiles: [TestFixtures.relayProfile()],
                                   state: .connected(hostHome: "/Users/tester"))
        let profile = try XCTUnwrap(fake.profiles.first)
        fake.activeProfile = profile
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        model.attach(store: fake, hub: hub)
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 6))
        await carrier.waitForLiveStream("session/follow")
        let records: [JSONValue] = [
            ChatSeam.turnStart(seq: 1, turn: 1),
            ChatSeam.userMessage(seq: 2, text: "q"),
            foldSummary(seq: 3, turn: 1, start: 3, end: 4),
            ChatSeam.assistantMessage(seq: 5, text: "a"),
            ChatSeam.turnEnd(seq: 6, turn: 1, reason: "completed"),
        ]
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 6, records: records))

        // 收起态：只有问题、轮次行、回答。过程行根本不在窗口里。
        let folded = await eventuallyRows { rows in
            rows.count == 3 && rows.contains { item in
                if case .processHeader(let h) = item.kind { return h.scope == .turn }
                return false
            }
        }
        XCTAssertEqual(folded.count, 3, "folded rows: \(folded.map(\.id))")
        let turnHeader = try XCTUnwrap(folded.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind, value.scope == .turn { return value }
            return nil
        }.first)
        XCTAssertEqual(turnHeader.toolCount, 1, "计数来自概要，不是行数")
        XCTAssertEqual(turnHeader.duration ?? 0, 139, accuracy: 0.001)
        XCTAssertFalse(turnHeader.isPrefetched, "v2 概要不出现在行里")

        // 展开轮次：一条分组行（来自 groups），步骤要再展开那一组。
        model.toggleProcess(turnKey: turnHeader.id)
        let grouped = await eventuallyRows { rows in
            rows.contains { item in
                if case .processHeader(let h) = item.kind { return h.scope == .group }
                return false
            }
        }
        let group = try XCTUnwrap(grouped.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind, value.scope == .group { return value }
            return nil
        }.first)
        XCTAssertFalse(group.isExpanded)
        XCTAssertFalse(grouped.contains { item in
            if case .processStep = item.kind { return true }
            return false
        })

        // 展开分组：步骤元数据行出现，正文为空（只有名称/预览/状态/字节数）。
        model.toggleProcessGroup(groupKey: group.id)
        let opened = await eventuallyRows { rows in
            rows.contains { item in
                if case .processStep = item.kind { return true }
                return false
            }
        }
        let step = try XCTUnwrap(opened.compactMap { item -> TimelineProcessStep? in
            if case .processStep(let value) = item.kind { return value }
            return nil
        }.first)
        XCTAssertEqual(step.name, "bash")
        XCTAssertEqual(step.preview, "swift build")
        XCTAssertEqual(step.status, .ok)
        XCTAssertEqual(step.bytes, 900)
        XCTAssertEqual(step.resultSeq, 4)
        XCTAssertEqual(TranscriptRowPayload(item: step.item).payloadBytes, 0)
    }

    func test_trimming_the_window_drops_the_v2_summaries_with_their_turns() async throws {
        carrier.registerLiveStream("session/follow")
        let fake = FakeLinkService(profiles: [TestFixtures.relayProfile()],
                                   state: .connected(hostHome: "/Users/tester"))
        let profile = try XCTUnwrap(fake.profiles.first)
        fake.activeProfile = profile
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        model.attach(store: fake, hub: hub)
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 12))
        await carrier.waitForLiveStream("session/follow")
        let filler = String(repeating: "x", count: 300)
        let answer = String(repeating: "y", count: 900)
        let records: [JSONValue] = [
            ChatSeam.turnStart(seq: 1, turn: 1),
            ChatSeam.userMessage(seq: 2, text: filler),
            foldSummary(seq: 3, turn: 1, start: 3, end: 4),
            ChatSeam.assistantMessage(seq: 5, text: answer),
            ChatSeam.turnEnd(seq: 6, turn: 1, reason: "completed"),
            ChatSeam.turnStart(seq: 7, turn: 2),
            ChatSeam.userMessage(seq: 8, text: filler),
            foldSummary(seq: 9, turn: 2, start: 9, end: 10),
            ChatSeam.assistantMessage(seq: 11, text: answer),
            ChatSeam.turnEnd(seq: 12, turn: 2, reason: "completed"),
        ]
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 12, records: records))
        _ = await eventuallyRows { $0.count >= 4 }
        XCTAssertEqual(model.timeline.foldSummaries.map(\.turn), [1, 2])

        let old = ChatProbe.shared.payloadBudgetKB
        ChatProbe.shared.payloadBudgetKB = 1
        defer { ChatProbe.shared.payloadBudgetKB = old }
        let plan = model.trimPlanForBudget(keepLast: 0)
        XCTAssertFalse(plan.isEmpty, "预算必须能裁掉第一轮")
        XCTAssertGreaterThan(model.applyTrim(plan), 0)
        XCTAssertEqual(model.timeline.foldSummaries.map(\.turn), [2],
                       "被裁掉的轮次的概要不能留下（否则投影出幽灵轮次）")
        // 还留着的第二轮照常折叠：一条轮次行 + 回答。
        let rows = model.rowsFor(screen: "s-1")
        XCTAssertTrue(rows.contains { item in
            if case .processHeader(let header) = item.kind { return header.scope == .turn }
            return false
        })
    }

    private func foldSummary(seq: Int, turn: Int, start: Int, end: Int) -> JSONValue {
        .object([
            "type": .string("+link/fold"), "seq": .int(seq),
            "data": .object([
                "v": .int(2), "turn": .int(turn),
                "startSeq": .int(start), "endSeq": .int(end),
                "durationMs": .int(139000), "endReason": .string("completed"),
                "activities": .object(["commands": .int(1)]),
                "groups": .array([
                    .object([
                        "startSeq": .int(start), "endSeq": .int(end),
                        "activities": .object(["commands": .int(1)]),
                        "toolCount": .int(1),
                        "steps": .array([
                            .object([
                                "seq": .int(start), "kind": .string("tools"),
                                "name": .string("bash"), "preview": .string("swift build"),
                                "status": .string("ok"),
                                "resultSeq": .int(end), "bytes": .int(900),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    func test_switching_sessions_resets_the_disclosure_state() async throws {
        try await openWithOneCompletedTurn()
        let rows = await eventuallyRows { $0.count == 3 }
        let header = try XCTUnwrap(rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind { return value }
            return nil
        }.first)
        model.toggleProcess(turnKey: header.id)
        XCTAssertFalse(model.foldState.manualTurn.isEmpty)

        await model.open(try ChatSeam.summary(id: "s-other", asOfSeq: 1))
        XCTAssertTrue(model.foldState.manualTurn.isEmpty)
        XCTAssertTrue(model.foldState.expandedGroups.isEmpty)
    }

    func test_an_error_turn_folds_on_the_model_surface() async throws {
        // M5：失败与正常完成同一套折叠（有箭头、可点、默认收起），文案另行区分。
        try await openWithOneCompletedTurn(reason: "error")
        let rows = await eventuallyRows { rows in
            rows.contains { if case .processHeader(let h) = $0.kind, h.scope == .turn { return true }; return false }
        }
        let header = try XCTUnwrap(rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind, value.scope == .turn { return value }
            return nil
        }.first)
        XCTAssertFalse(header.isExpanded)
        XCTAssertTrue(header.isFoldable)
        XCTAssertEqual(ProcessFoldText.turnLabel(endReason: header.endReason, duration: header.duration),
                       "处理失败")
        XCTAssertFalse(rows.map(\.id).contains("tool-call-1"))
    }

    func test_group_toggle_opens_only_that_group() async throws {
        try await openWithOneCompletedTurn(intermediate: true)
        let folded = await eventuallyRows { $0.count == 3 }
        let turnHeader = try XCTUnwrap(folded.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind, value.scope == .turn { return value }
            return nil
        }.first)
        model.toggleProcess(turnKey: turnHeader.id)
        let grouped = await eventuallyRows { rows in
            rows.contains { if case .processHeader(let h) = $0.kind, h.scope == .group { return true }; return false }
        }
        let groups = grouped.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind, value.scope == .group { return value }
            return nil
        }
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { !$0.isExpanded }, "groups start collapsed")

        model.toggleProcessGroup(groupKey: groups[0].id)
        let opened = await eventuallyRows { rows in
            rows.contains { if case .processHeader(let h) = $0.kind, h.id == groups[0].id, h.isExpanded { return true }; return false }
        }
        let state = opened.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind, value.scope == .group { return value }
            return nil
        }
        XCTAssertEqual(state.first { $0.id == groups[0].id }?.isExpanded, true)
        XCTAssertEqual(state.first { $0.id == groups[1].id }?.isExpanded, false,
                       "the other group must stay collapsed")

        model.toggleProcessGroup(groupKey: groups[0].id)
        let closed = await eventuallyRows { rows in
            rows.contains { if case .processHeader(let h) = $0.kind, h.id == groups[0].id, !h.isExpanded { return true }; return false }
        }
        XCTAssertTrue(closed.contains { if case .processHeader(let h) = $0.kind { return h.id == groups[0].id && !h.isExpanded }; return false })
    }

    func test_reopening_the_same_session_keeps_the_reader_state() async throws {
        try await openWithOneCompletedTurn()
        let rows = await eventuallyRows { $0.count == 3 }
        let header = try XCTUnwrap(rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind { return value }
            return nil
        }.first)
        model.toggleProcess(turnKey: header.id)
        let summary = try XCTUnwrap(model.session)
        await model.open(summary)
        XCTAssertEqual(model.foldState.manualTurn[header.id], true)
    }

    func test_trim_plan_never_cuts_a_turn_in_half() async throws {
        try await openWithOneCompletedTurn(toolOutputBytes: 4000)
        _ = await eventuallyRows { $0.count == 3 }
        let old = ChatProbe.shared.payloadBudgetKB
        ChatProbe.shared.payloadBudgetKB = 1
        defer { ChatProbe.shared.payloadBudgetKB = old }

        let plan = model.trimPlanForBudget(keepLast: 0)
        if !plan.isEmpty {
            XCTAssertGreaterThan(plan.rawCount, 0)
            XCTAssertEqual(plan.displayDropIDs.first, model.rowsFor(screen: "s-1").first?.id)
            let before = model.timeline.items.count
            let dropped = model.applyTrim(plan)
            XCTAssertEqual(dropped, plan.rawCount)
            XCTAssertLessThan(model.timeline.items.count, before)
        }
    }

    // MARK: - Fixtures

    private func openWithOneCompletedTurn(toolOutputBytes: Int = 0,
                                          reason: String = "completed",
                                          intermediate: Bool = false) async throws {
        carrier.registerLiveStream("session/follow")
        let fake = FakeLinkService(profiles: [TestFixtures.relayProfile()],
                                   state: .connected(hostHome: "/Users/tester"))
        let profile = try XCTUnwrap(fake.profiles.first)
        fake.activeProfile = profile
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        model.attach(store: fake, hub: hub)
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 6))
        await carrier.waitForLiveStream("session/follow")
        let output = String(repeating: "x", count: toolOutputBytes)
        var records: [JSONValue] = [
            ChatSeam.turnStart(seq: 1, turn: 1),
            ChatSeam.userMessage(seq: 2, text: "q"),
            toolCall(seq: 3, callId: "call-1", name: "bash"),
            toolResult(seq: 4, callId: "call-1", text: output),
        ]
        var seq = 5
        if intermediate {
            records.append(ChatSeam.assistantMessage(seq: seq, text: "still working"))
            seq += 1
            records.append(toolCall(seq: seq, callId: "call-2", name: "read"))
            seq += 1
            records.append(toolResult(seq: seq, callId: "call-2", text: "ok"))
            seq += 1
        }
        records.append(ChatSeam.assistantMessage(seq: seq, text: "a"))
        seq += 1
        records.append(ChatSeam.turnEnd(seq: seq, turn: 1, reason: reason))
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: seq, records: records))
        _ = await eventuallyRows { !$0.isEmpty }
    }

    private func toolCall(seq: Int, callId: String, name: String) -> JSONValue {
        .object([
            "type": .string("tool/call"), "seq": .int(seq),
            "data": .object([
                "turn": .int(1), "step": .int(1),
                "callId": .string(callId), "name": .string(name), "arguments": .string("{}"),
            ]),
        ])
    }

    private func toolResult(seq: Int, callId: String, text: String) -> JSONValue {
        .object([
            "type": .string("tool/result"), "seq": .int(seq),
            "data": .object([
                "turn": .int(1), "step": .int(1),
                "message": .object([
                    "source": .object(["callId": .string(callId)]),
                    "content": .array([
                        .object([
                            "type": .string("tool-result"),
                            "toolCallId": .string(callId),
                            "isError": .bool(false),
                            "content": .array([
                                .object(["type": .string("text"), "text": .string(text)]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    private func eventuallyRows(deadline: TimeInterval = 3,
                                _ condition: ([TimelineItem]) -> Bool) async -> [TimelineItem] {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let rows = model.rowsFor(screen: model.session?.sessionId ?? "s-1")
            if condition(rows) { return rows }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return model.rowsFor(screen: model.session?.sessionId ?? "s-1")
    }
}

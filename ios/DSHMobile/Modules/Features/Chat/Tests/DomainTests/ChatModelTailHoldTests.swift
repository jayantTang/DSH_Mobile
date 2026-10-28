@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// 模型层的尾轮边界：一次性保位、行稳定性、占位行裁剪、管道重建携带种子
/// （设计 `20261027-折叠抖动-方案A.md` M3/M4/M6/M7）。
///
/// 与 `ChatModelProcessFoldTests` 的分工：那份钉"折叠表面与读者动作"，这份钉
/// **边界事实进入模型之后的那几条路**（关闭那一刻、重复投递、首次打开、管道重建）。
@MainActor
final class ChatModelTailHoldTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!
    private var fake: FakeLinkService!
    private var layer: MessageLayer?
    private var directory: URL?
    /// 探针事件（`tail.boundary` 的现场证据）。只在断言里读，不参与产品逻辑。
    private var probeEvents: [(kind: String, fields: [String: String])] = []

    override func setUp() async throws {
        try await super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        model = ChatModel()
        fake = FakeLinkService(profiles: [TestFixtures.relayProfile()],
                               state: .connected(hostHome: "/Users/tester"))
        fake.activeProfile = try XCTUnwrap(fake.profiles.first)
        fake.clientOverride = HostClientFactory.make(carrier: carrier)
        carrier.registerLiveStream("session/follow")
        model.attach(store: fake, hub: hub)
        probeEvents = []
        ChatProbe.shared.probeNote = { [weak self] kind, fields, _ in
            self?.probeEvents.append((kind, fields))
        }
    }

    override func tearDown() async throws {
        // 探针是全局单例：本用例装上的收集器必须摘掉，否则会串到别的用例里。
        ChatProbe.shared.probeNote = nil
        await model.close()
        hub.stop()
        model = nil
        hub = nil
        fake = nil
        carrier = nil
        layer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    // MARK: - 夹具

    private func toolCall(seq: Int, callId: String, name: String = "bash") -> JSONValue {
        .object([
            "type": .string("tool/call"), "seq": .int(seq),
            "data": .object([
                "turn": .int(1), "step": .int(1),
                "callId": .string(callId), "name": .string(name), "arguments": .string("{}"),
            ]),
        ])
    }

    private func toolResult(seq: Int, callId: String, text: String = "ok") -> JSONValue {
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

    private func foldSummary(seq: Int, turn: Int, start: Int, end: Int,
                             endReason: String? = nil) -> JSONValue {
        var data: [String: JSONValue] = [
            "v": .int(2), "turn": .int(turn),
            "startSeq": .int(start), "endSeq": .int(end),
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
                            "status": .string(endReason == nil ? "running" : "ok"),
                            "resultSeq": .int(end), "bytes": .int(900),
                        ]),
                    ]),
                ]),
            ]),
        ]
        if let endReason { data["endReason"] = .string(endReason) }
        return .object(["type": .string("+link/fold"), "seq": .int(seq), "data": .object(data)])
    }

    /// 打开一个**正在跑**的会话：窗口里有 turn/start，过程行可见。
    private func openRunningTurn(withAnswer: Bool = false,
                                 withSummary: Bool = false) async throws {
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 4))
        await carrier.waitForLiveStream("session/follow")
        var records: [JSONValue] = [
            ChatSeam.turnStart(seq: 1, turn: 1),
            ChatSeam.userMessage(seq: 2, text: "q"),
        ]
        if withSummary {
            records.append(foldSummary(seq: 3, turn: 1, start: 3, end: 4))
            records.append(ChatSeam.assistantMessage(seq: 5, text: "a"))
        } else {
            records.append(toolCall(seq: 3, callId: "call-1"))
            records.append(toolResult(seq: 4, callId: "call-1"))
            if withAnswer {
                records.append(ChatSeam.assistantMessage(seq: 5, text: "a"))
            }
        }
        carrier.liveStreams["session/follow"]?.yield(
            ChatSeam.snapshot(cursor: records.count + 4, records: records))
        _ = await eventuallyRows { rows in
            rows.contains { if case .toolCall = $0.kind { return true }; return false }
                || rows.contains { if case .processStep = $0.kind { return true }; return false }
                || !rows.isEmpty
        }
        _ = await eventually { model.timeline.isTurnOpen }
    }

    /// 往同一条流里投一条 `turn/end`（关闭尾轮）。
    private func closeTurn(seq: Int, turn: Int = 1) async {
        carrier.liveStreams["session/follow"]?.yield(
            ChatSeam.eventFrame(ChatSeam.turnEnd(seq: seq, turn: turn)))
        // 等**落地证据**（那一轮的分隔行）而不是 `isTurnOpen`：边界本来就是 unknown 时，
        // `isTurnOpen` 在事件到达之前也已经是 false，用它会立刻"等到了"。
        _ = await eventually {
            self.model.timeline.items.contains { item in
                if case .turnDivider(let value, _, _) = item.kind { return value == turn }
                return false
            }
        }
    }

    private func boundaryProbes() -> [[String: String]] {
        probeEvents.filter { $0.kind == "tail.boundary" }.map(\.fields)
    }

    // MARK: - 一次性保位（M4）

    func test_reader_on_process_row_holds_the_turn_when_it_closes() async throws {
        try await openRunningTurn()
        model.noteReaderTopRow("tool-call-1")
        await closeTurn(seq: 6)

        let keys = Array(model.foldState.manualTurn.keys)
        XCTAssertEqual(keys.count, 1, "关闭那一刻恰好做一次保位判定：\(model.foldState.manualTurn)")
        XCTAssertEqual(keys.first.map { model.foldState.manualTurn[$0] }, true)
        XCTAssertTrue(model.rowsFor(screen: "s-1").map(\.id).contains("tool-call-1"),
                      "读者脚下的过程行不许在关闭那一刻被收走：\(model.rowsFor(screen: "s-1").map(\.id))")
        XCTAssertEqual(boundaryProbes().last?["hold"], "applied")
        XCTAssertEqual(boundaryProbes().last?["to"], "closed")
        XCTAssertEqual(boundaryProbes().last?["persisted"], "0",
                       "阶段一没有持久化副本（M2 属阶段二）")
    }

    func test_reader_on_answer_does_not_hold_turn_at_close() async throws {
        try await openRunningTurn(withAnswer: true)
        let answerRow = try XCTUnwrap(model.timeline.items.first { item in
            if case .assistantText = item.kind { return true }
            return false
        })
        model.noteReaderTopRow(answerRow.id)
        await closeTurn(seq: 7)

        XCTAssertTrue(model.foldState.manualTurn.isEmpty,
                      "顶部行是回答：不是过程细节，不保位：\(model.foldState.manualTurn)")
        XCTAssertEqual(boundaryProbes().last?["hold"], "skipped:notInTurn")
    }

    func test_reader_on_group_step_also_expands_that_group() async throws {
        try await openRunningTurn(withSummary: true)
        let group = try XCTUnwrap(model.timeline.foldSummaries.first?.groups.first)
        let step = try XCTUnwrap(group.steps.first)
        let stepRowID = "process-step:process-group:1:\(group.startSeq):\(step.seq)-\(step.kind.rawValue)"
        model.noteReaderTopRow(stepRowID)
        await closeTurn(seq: 6)

        let turnKey = try XCTUnwrap(model.foldState.manualTurn.keys.first)
        XCTAssertEqual(model.foldState.manualTurn[turnKey], true)
        XCTAssertEqual(model.foldState.expandedGroups, ["process-group:1:3"],
                       "命中步骤行时，它所在的那一组也要展开")
        XCTAssertEqual(boundaryProbes().last?["hold"], "applied")
    }

    func test_manual_collapse_is_not_overridden_at_close() async throws {
        try await openRunningTurn()
        // 读者先亲手收起这一轮（运行中的轮次还没有轮次行，键由计划给出）。
        let turnKey = try XCTUnwrap(model.processPlan().turns.first?.key)
        model.foldState.manualTurn[turnKey] = false
        model.noteReaderTopRow("tool-call-1")
        await closeTurn(seq: 6)

        XCTAssertEqual(model.foldState.manualTurn[turnKey], false, "已有手工状态一律不覆盖")
        XCTAssertEqual(boundaryProbes().last?["hold"], "skipped:manual")
        XCTAssertFalse(model.rowsFor(screen: "s-1").map(\.id).contains("tool-call-1"))
    }

    func test_duplicate_turn_end_is_idempotent() async throws {
        try await openRunningTurn()
        model.noteReaderTopRow("tool-call-1")
        await closeTurn(seq: 6)
        let afterFirst = model.foldState.manualTurn
        let probeCount = boundaryProbes().count

        await closeTurn(seq: 7)
        XCTAssertEqual(model.foldState.manualTurn, afterFirst, "同一条 turn/end 投两次不该再改动折叠态")
        XCTAssertEqual(boundaryProbes().count, probeCount, "边界没变就不该再记一条 tail.boundary")
    }

    func test_unknown_to_closed_also_holds() async throws {
        // 窗口被条数切开：里面没有任何 turn/start / turn/end，边界从 unknown 变 closed。
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 4))
        await carrier.waitForLiveStream("session/follow")
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 4, records: [
            ChatSeam.userMessage(seq: 2, text: "q"),
            toolCall(seq: 3, callId: "call-1"),
            toolResult(seq: 4, callId: "call-1"),
        ]))
        _ = await eventuallyRows { $0.map(\.id).contains("tool-call-1") }
        XCTAssertEqual(model.timeline.tail.boundary, .unknown, "前置：窗口里没有边界行")

        model.noteReaderTopRow("tool-call-1")
        await closeTurn(seq: 5)

        XCTAssertEqual(boundaryProbes().last?["from"], "unknown")
        XCTAssertEqual(boundaryProbes().last?["hold"], "applied")
        XCTAssertEqual(model.foldState.manualTurn.count, 1)
    }

    /// "没有顶部行"的两种形态必须能分开（设计 §8.4 欠项 6 / 本轮硬口径）：
    /// `noMeasurement` = 宿主还没报（等下一次），`notLocated` = 报上来了但计划里没有。
    func test_reader_hold_separates_a_missing_measurement_from_an_unmapped_row() async throws {
        try await openRunningTurn()
        // ① 宿主从没报过顶部行。
        await closeTurn(seq: 6)
        XCTAssertEqual(boundaryProbes().last?["hold"], "skipped:noMeasurement")

        // ② 新的一轮开起来之后，宿主报了一个计划里不存在的行 id。
        carrier.liveStreams["session/follow"]?.yield(
            ChatSeam.eventFrame(ChatSeam.turnStart(seq: 7, turn: 2)))
        _ = await eventually { self.model.timeline.isTurnOpen }
        model.noteReaderTopRow("row-that-is-not-in-the-plan")
        await closeTurn(seq: 8, turn: 2)
        XCTAssertEqual(boundaryProbes().last?["hold"], "skipped:notLocated")
    }

    func test_opening_a_session_never_holds() async throws {
        try await openRunningTurn()
        model.noteReaderTopRow("tool-call-1")
        // 打开流程还没走完（`pendingOpen` 还在）：这一刻的边界迁移不是读者的动作。
        model.pendingOpen = try ChatSeam.summary(id: "s-1", asOfSeq: 4)
        await closeTurn(seq: 6)

        XCTAssertTrue(model.foldState.manualTurn.isEmpty, "首次打开/播种期间永不保位")
        XCTAssertEqual(boundaryProbes().last?["hold"], "skipped:opening")
    }

    // MARK: - 抖动守门（M3/M4：投影不再吃测量值）

    func test_model_rows_are_stable_when_host_reports_first_row_as_top() async throws {
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 6))
        await carrier.waitForLiveStream("session/follow")
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 6, records: [
            ChatSeam.turnStart(seq: 1, turn: 1),
            ChatSeam.userMessage(seq: 2, text: "q"),
            toolCall(seq: 3, callId: "call-1"),
            toolResult(seq: 4, callId: "call-1"),
            ChatSeam.assistantMessage(seq: 5, text: "a"),
            ChatSeam.turnEnd(seq: 6, turn: 1),
        ]))
        let first = await eventuallyRows { !$0.isEmpty }
        XCTAssertFalse(first.isEmpty)

        var previous: [String]?
        for _ in 0..<10 {
            let rows = model.rowsFor(screen: "s-1")
            // 宿主每帧把"首行"当顶部可见行回报：模型只记测量值，不得写折叠态。
            model.noteReaderTopRow(rows.first?.id)
            let next = model.rowsFor(screen: "s-1").map(\.id)
            if let previous { XCTAssertEqual(previous, next, "行序列在自激循环下必须恒定") }
            previous = next
        }
        XCTAssertTrue(model.foldState.manualTurn.isEmpty,
                      "打开一个已完成的历史会话不许产生折叠动作：\(model.foldState.manualTurn)")
    }

    // MARK: - 占位行进入裁剪（M7）

    /// 占位行进入裁剪的口径（M7）：**不加新分支**，跟它所属的轮次一起被前缀规则处理。
    ///
    /// 需要注意的不变量是"别把占位行和它的轮次拆开"：占位行的 seq 就是这一轮的起点，
    /// 于是裁剪线按轮次对齐之后，它要么整行留在前缀里、要么跟整轮一起被留下——
    /// 不会出现"轮次还在、占位行被裁掉"（那会让这一段过程凭空消失）。
    func test_trim_plan_keeps_the_placeholder_with_its_turn() async throws {
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 6))
        await carrier.waitForLiveStream("session/follow")
        let big = String(repeating: "x", count: 4000)
        carrier.liveStreams["session/follow"]?.yield(ChatSeam.snapshot(cursor: 6, records: [
            ChatSeam.userMessage(seq: 2, text: "q"),
            toolCall(seq: 3, callId: "call-1"),
            toolResult(seq: 4, callId: "call-1", text: big),
            toolCall(seq: 5, callId: "call-2"),
            toolResult(seq: 6, callId: "call-2", text: big),
        ]))
        let rows = await eventuallyRows { rows in
            rows.contains { if case .processPlaceholder = $0.kind { return true }; return false }
        }
        let placeholder = try XCTUnwrap(rows.first { item in
            if case .processPlaceholder = item.kind { return true }
            return false
        })
        XCTAssertEqual(placeholder.seq, 3, "占位行的 seq 就是这一轮的起点")
        XCTAssertGreaterThanOrEqual(model.timeline.items.count, 3, "前置：原始行够多才谈得上丢前缀")

        let old = ChatProbe.shared.payloadBudgetKB
        ChatProbe.shared.payloadBudgetKB = 1
        defer { ChatProbe.shared.payloadBudgetKB = old }
        let plan = model.trimPlanForBudget(keepLast: 1)
        XCTAssertFalse(plan.isEmpty, "预算必须能裁掉那一大段工具输出")
        XCTAssertEqual(plan.displayDropIDs, ["user-message-2"],
                       "裁剪线按轮次对齐到 seq 3：只有它前面的那一行走前缀")
        XCTAssertFalse(plan.displayDropIDs.contains(placeholder.id),
                       "占位行跟着它的轮次留在窗口里")
        XCTAssertGreaterThan(model.applyTrim(plan), 0)
        XCTAssertTrue(model.rowsFor(screen: "s-1").map(\.id).contains(placeholder.id),
                      "裁完之后占位行仍在：\(model.rowsFor(screen: "s-1").map(\.id))")
    }

    // MARK: - 管道重建携带边界种子（M6）

    func test_pipeline_rebuild_keeps_tail_open_across_refold() async throws {
        try attachLayer()
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 4, running: true))
        await carrier.waitForLiveStream("session/follow")
        let bridge = try XCTUnwrap(model.pipelineBridge, "有消息层时管道必须接线")
        // 窗口切在轮次中间：管道里只有过程行，没有任何边界行。
        await bridge.absorb(records: [
            SessionRecord(event: try decode(toolCall(seq: 3, callId: "call-1"))),
        ])
        _ = await eventually { !self.model.timeline.items.isEmpty }
        XCTAssertTrue(model.timeline.isTurnOpen, "summary.running 播种：首帧就是运行中")

        for round in 0..<5 {
            bridge.refold(messagesChanged: true, gapsChanged: false)
            let running = await eventually {
                self.model.timeline.isTurnOpen
                    && self.model.rowsFor(screen: "s-1").contains { item in
                        if case .runningLine = item.kind { return true }
                        return false
                    }
            }
            XCTAssertTrue(running, "第 \(round + 1) 次 refold 之后仍然要在跑（边界不随窗口丢）")
        }
    }

    func test_pipeline_rebuild_keeps_closed_tail() async throws {
        try attachLayer()
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 6))
        await carrier.waitForLiveStream("session/follow")
        let bridge = try XCTUnwrap(model.pipelineBridge)
        await bridge.absorb(records: [
            SessionRecord(event: try decode(ChatSeam.turnStart(seq: 1, turn: 1))),
            SessionRecord(event: try decode(ChatSeam.userMessage(seq: 2, text: "q"))),
            SessionRecord(event: try decode(toolCall(seq: 3, callId: "call-1"))),
            SessionRecord(event: try decode(ChatSeam.turnEnd(seq: 4, turn: 1))),
        ])
        _ = await eventually { !self.model.timeline.isTurnOpen && !self.model.timeline.items.isEmpty }

        for _ in 0..<2 {
            bridge.refold(messagesChanged: true, gapsChanged: false)
            let stayedClosed = await eventually { !self.model.timeline.isTurnOpen }
            XCTAssertTrue(stayedClosed, "已结束的尾轮不许被重建改回运行中")
        }
    }

    // MARK: - 夹具与轮询

    private func attachLayer() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-tail-hold-tests-\(UUID().uuidString)")
        directory = dir
        let messageLayer = MessageLayer()
        let client = HostClientFactory.make(carrier: carrier)
        fake.clientOverride = client
        messageLayer.attach(client: { client },
                            storePath: dir.appendingPathComponent("messages.sqlite3"))
        guard messageLayer.isReady else {
            throw XCTSkip("MessageLayer could not open its message store in this environment")
        }
        layer = messageLayer
        model.attach(messageLayer: messageLayer)
    }

    private func decode(_ json: JSONValue) throws -> SessionEvent {
        let data = try JSONEncoder().encode(json)
        return try JSONDecoder().decode(SessionEvent.self, from: data)
    }

    private func eventuallyRows(deadline: TimeInterval = 3,
                                _ condition: ([TimelineItem]) -> Bool) async -> [TimelineItem] {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let rows = model.rowsFor(screen: "s-1")
            if condition(rows) { return rows }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return model.rowsFor(screen: "s-1")
    }

    private func eventually(_ condition: () -> Bool, deadline: TimeInterval = 3) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

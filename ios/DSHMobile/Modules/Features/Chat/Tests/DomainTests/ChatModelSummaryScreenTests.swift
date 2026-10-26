@testable import DSHChatDomain
import DSHConnectionAPI
import DSHCore
import DSHKit
import DSHTestingSupport
import XCTest

/// M6b：首屏概要取数、页级重试、缓存骨架与单条步骤取数（假传输层，不连网）。
@MainActor
final class ChatModelSummaryScreenTests: XCTestCase {

    private var carrier: FakeCarrier!
    private var hub: HostEventHub!
    private var model: ChatModel!
    private var fake: FakeLinkService!
    private var layer: MessageLayer?
    private var directory: URL?

    /// 概要页覆盖的一轮：讲话(2) + 概要(3) + 回答(6) + 轮次边界(7)。
    private static let asOfSeq = 7
    private static let stepID = "process-step:process-group:1:3:3-tools"
    private static let reasoningStepID = "process-step:process-group:1:3:5-reasoning"

    override func setUp() async throws {
        try await super.setUp()
        carrier = FakeCarrier()
        hub = HostEventHub()
        model = ChatModel()
        fake = FakeLinkService(profiles: [TestFixtures.relayProfile()],
                               state: .connected(hostHome: "/Users/tester"),
                               capabilities: [HistoryWindowWire.summaryFoldCapability])
        fake.activeProfile = try XCTUnwrap(fake.profiles.first)
        carrier.registerLiveStream("session/follow")
        model.attach(store: fake, hub: hub)
    }

    override func tearDown() async throws {
        await model.close()
        hub.stop()
        model = nil
        hub = nil
        fake = nil
        carrier = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        layer = nil
        directory = nil
        try await super.tearDown()
    }

    // MARK: - 请求与能力

    func test_first_screen_uses_summary_mode_with_turn_count_and_byte_budget() async throws {
        let client = makeClient(capabilities: [HistoryWindowWire.summaryFoldCapability])
        fake.clientOverride = client
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON())

        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        await carrier.waitForLiveStream("session/follow")
        let ready = await eventually { model.summaryScreenState == .ready }
        XCTAssertTrue(ready, "state: \(model.summaryScreenState)")

        let calls = summaryCalls()
        XCTAssertEqual(calls.count, 1)
        let args = try XCTUnwrap(calls.first?.args)
        XCTAssertEqual(args["fold"]?.stringValue, "summary")
        XCTAssertEqual(args["limit"]?.intValue, ChatModel.summaryScreenTurns)
        XCTAssertEqual(args["limit"]?.intValue, 12)
        XCTAssertEqual(args["maxBytes"]?.intValue, 256 * 1024)
        XCTAssertEqual(args["before"]?.intValue, Self.asOfSeq + 1, "从最新开始，before 是开区间上界")

        // 概要成为这一轮的元数据；收起态一行轮次行 + 回答。
        // 能力在时不走 v1：所有取页请求要么是概要，要么是不折（单条正文）。
        let v1Calls = carrier.calls(to: "_link/sessionWindow").filter { call in
            call.args?["fold"]?.boolValue == true
        }
        XCTAssertTrue(v1Calls.isEmpty, "有 v2 能力时不允许再发 fold:true")

        XCTAssertEqual(model.timeline.foldSummaries.count, 1)
        let rows = model.rowsFor(screen: "s-1")
        XCTAssertEqual(rows.count, 3, "rows: \(rows.map(\.id))")
        XCTAssertTrue(rows.contains { item in
            if case .processHeader(let header) = item.kind { return header.scope == .turn }
            return false
        })
    }

    func test_without_the_v2_capability_the_old_path_is_untouched() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.foldCapability])
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        await carrier.waitForLiveStream("session/follow")
        _ = await eventually { model.phase == .ready }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.summaryScreenState, .idle)
        XCTAssertTrue(carrier.calls(to: "_link/sessionWindow").isEmpty,
                      "没有 v2 能力时不发概要请求，旧路径照旧")
    }

    func test_an_empty_session_is_idle_and_never_shows_the_error_capsule() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.summaryFoldCapability])
        await model.open(try ChatSeam.summary(id: "s-empty", asOfSeq: 0))
        await carrier.waitForLiveStream("session/follow")
        _ = await eventually { model.phase == .ready }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.summaryScreenState, .idle)
        XCTAssertFalse(model.summaryScreenState.isFailed, "空会话不是错误")
        XCTAssertTrue(summaryCalls().isEmpty, "空会话没有可取的轮次，不发请求")
    }

    func test_an_empty_summary_page_is_idle_not_a_failure() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(.object([
            "records": .array([]), "startSeq": .int(0), "endSeq": .int(0),
            "hasMore": .bool(false),
        ]))
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 5))
        await carrier.waitForLiveStream("session/follow")
        let idle = await eventually { model.summaryScreenState == .idle }
        XCTAssertTrue(idle, "state: \(model.summaryScreenState)")
        XCTAssertFalse(model.summaryScreenState.isFailed)
        XCTAssertEqual(summaryCalls().count, 1, "请求发过，但空回包不落失败")
    }

    // MARK: - 缓存骨架

    func test_a_cached_skeleton_skips_the_request_and_asks_only_for_new_turns() async throws {
        try attachLayer(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON())
        let summary = try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq)
        await model.open(summary)
        _ = await eventually { model.summaryScreenState == .ready }
        XCTAssertEqual(summaryCalls().count, 1)
        await layer?.flushWrites()

        // 二次打开：概要记录已在本地库，先渲染骨架，不再为旧轮次发请求。
        await model.close()
        await model.open(summary)
        _ = await eventually { model.summaryScreenState == .ready }
        XCTAssertEqual(summaryCalls().count, 1,
                       "二次打开先渲染缓存骨架，不为旧轮次再发请求")
        XCTAssertEqual(model.timeline.foldSummaries.count, 1)

        // 宿主往后走了一轮（asOfSeq 变大）：只为新轮次再发一次。
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON(turn: 2))
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq + 1))
        _ = await eventually { summaryCalls().count == 2 }
        XCTAssertEqual(summaryCalls().count, 2)
        XCTAssertEqual(summaryCalls().last?.args?["limit"]?.intValue, 2,
                       "宿主前进时只为新轮次取（2 轮），不再整页重发 12 轮")
    }

    // MARK: - 搜索命中工具正文（D2）

    func test_a_search_hit_on_a_tool_body_expands_and_loads_its_step_row() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON())
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        _ = await eventually { model.summaryScreenState == .ready }

        // 命中的是工具的**结果**（seq 4），不是任何一条日志行。
        carrier.unaryResponses["_link/sessionWindow"] = .success(
            Self.stepBodyJSON(seq: 4, text: "HIT IN OUTPUT"))
        let hit = HistorySearchHit(seq: 4, role: "tool", snippet: "HIT IN OUTPUT",
                                   highlightStart: 0, highlightLength: 3)
        await model.loadContextForHits([hit])

        let loaded = await eventually {
            if case .loaded(let text, _) = model.stepBodies[Self.stepID] {
                return text == "HIT IN OUTPUT"
            }
            return false
        }
        XCTAssertTrue(loaded, "命中那一行要先按需取回正文：\(String(describing: model.stepBodies[Self.stepID]))")
        XCTAssertTrue(model.isProcessStepExpanded(Self.stepID),
                      "命中后步骤卡要展开：steps=\(model.foldState.expandedSteps) groups=\(model.foldState.expandedGroups) turns=\(model.foldState.manualTurn)")
        let rows = model.rowsFor(screen: "s-1")
        let target = TranscriptHitLocator.row(exactlyForSeq: 4, in: rows)
        XCTAssertEqual(target?.id, Self.stepID, "命中 seq 要能解析到步骤行")
        XCTAssertTrue(rows.contains { $0.id == Self.stepID })
    }

    // MARK: - link/too-large → 页级重试

    func test_too_large_lands_on_a_visible_page_level_retry() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .failure(
            DSHRPCFailure(code: "link/too-large", message: "one turn cannot be read in one page"))
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        let failed = await eventually {
            if case .failed(let tooLarge) = model.summaryScreenState { return tooLarge }
            return false
        }
        XCTAssertTrue(failed, "state: \(model.summaryScreenState)")
        XCTAssertTrue(model.summaryScreenState.isRetryable)

        // 重试：换一份成功回包，点重试条之后落到 ready，且只多一次请求。
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON())
        await model.retrySummaryScreen()
        XCTAssertEqual(model.summaryScreenState, .ready)
        XCTAssertEqual(carrier.calls(to: "_link/sessionWindow").count, 2)
        XCTAssertEqual(model.timeline.foldSummaries.count, 1)
    }

    // MARK: - 单条步骤取数

    func test_tapping_a_step_loads_its_body_and_reuses_the_cache() async throws {
        try attachLayer(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON())
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        _ = await eventually { model.summaryScreenState == .ready }
        expandTurnAndGroup()

        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.stepBodyJSON(seq: 4,
                                                                                  text: "BUILD OK"))
        model.toggleProcessStep(Self.stepID)
        XCTAssertTrue(model.isProcessStepExpanded(Self.stepID))
        let loaded = await eventually {
            if case .loaded(let text, _) = model.stepBodies[Self.stepID] { return text == "BUILD OK" }
            return false
        }
        XCTAssertTrue(loaded, "state: \(String(describing: model.stepBodies[Self.stepID]))")
        // 一张卡展开时正文贴到行上（投影只搬运模型状态）。
        let rows = model.rowsFor(screen: "s-1")
        let step = rows.compactMap { item -> TimelineProcessStep? in
            if case .processStep(let value) = item.kind { return value }
            return nil
        }.first { $0.id == Self.stepID }
        XCTAssertEqual(step?.body, .loaded(text: "BUILD OK", bytes: 8))
        XCTAssertEqual(step?.resultSeq, 4)

        // 二次打开：正文从磁盘 meta 缓存读回，不再发那一次单条请求。
        await model.close()
        let detailCallsBefore = detailCalls().count
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        _ = await eventually { model.summaryScreenState == .ready }
        expandTurnAndGroup()
        model.toggleProcessStep(Self.stepID)
        let cached = await eventually {
            if case .loaded(let text, _) = model.stepBodies[Self.stepID] { return text == "BUILD OK" }
            return false
        }
        XCTAssertTrue(cached, "缓存命中后应立即有正文")
        XCTAssertEqual(detailCalls().count, detailCallsBefore, "二次打开不再为同一条发请求")
    }

    func test_a_failed_step_only_fails_that_card_and_retry_fixes_it() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON())
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        _ = await eventually { model.summaryScreenState == .ready }
        expandTurnAndGroup()

        // 回包里没有那一条（宿主裁剪过日志）：失败只落在这一张卡。
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.otherRecordJSON())
        model.toggleProcessStep(Self.stepID)
        let failed = await eventually { model.stepBodies[Self.stepID] == .failed }
        XCTAssertTrue(failed, "state: \(String(describing: model.stepBodies[Self.stepID]))")
        XCTAssertNil(model.stepBodies[Self.reasoningStepID], "别的卡不受影响")

        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.stepBodyJSON(seq: 4,
                                                                                  text: "RETRY OK"))
        model.retryProcessStepBody(Self.stepID)
        let fixed = await eventually {
            if case .loaded(let text, _) = model.stepBodies[Self.stepID] { return text == "RETRY OK" }
            return false
        }
        XCTAssertTrue(fixed)
    }

    // MARK: - 旧页也走概要 v2（M6c）

    func test_older_pages_also_use_summary_mode_and_a_turn_aligned_cursor() async throws {
        try attachLayer(capabilities: [HistoryWindowWire.summaryFoldCapability])
        // 首屏 = 第 2 轮（seq 10…15）；旧页 = 第 1 轮（seq 1…6）。
        carrier.unaryResponses["_link/sessionWindow"] = .success(
            Self.windowJSON(turn: 2, start: 10, summaryStart: 12, summaryEnd: 13,
                            answerSeq: 14, endSeq: 15))
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 15))
        _ = await eventually { model.summaryScreenState == .ready }
        XCTAssertEqual(summaryCalls().count, 1)

        carrier.unaryResponses["_link/sessionWindow"] = .success(
            Self.windowJSON(turn: 1, start: 1, summaryStart: 3, summaryEnd: 4,
                            answerSeq: 5, endSeq: 6, hasMore: false))
        await model.loadOlder()
        let adopted = await eventually { model.timeline.foldSummaries.count == 2 }
        XCTAssertTrue(adopted, "旧页的概要也要并进时间线：\(model.timeline.foldSummaries.map(\.turn))")

        let calls = summaryCalls()
        XCTAssertEqual(calls.count, 2)
        let args = try XCTUnwrap(calls.last?.args)
        XCTAssertEqual(args["fold"]?.stringValue, "summary")
        XCTAssertEqual(args["before"]?.intValue, 10,
                       "before = 当前最早轮次的 startSeq（管道窗口里最早一条记录）")
        XCTAssertEqual(args["limit"]?.intValue, ChatModel.summaryOlderTurns)
        XCTAssertEqual(args["maxBytes"]?.intValue, 256 * 1024)

        // 两轮都是轮次行 + 回答；旧轮不出现 v1 工具行。
        let rows = model.rowsFor(screen: "s-1")
        XCTAssertEqual(rows.compactMap { item -> Int? in
            if case .processHeader(let header) = item.kind, header.scope == .turn {
                return header.turn
            }
            return nil
        }.sorted(), [1, 2])
        XCTAssertFalse(rows.contains { item in
            switch item.kind {
            case .toolCall, .reasoning: return true
            default: return false
            }
        }, "概要页不产生工具行")
        XCTAssertEqual(model.olderState, .exhausted, "hasMore=false + 覆盖到 seq 1 = 到最早")

        // 再翻一次：游标已经是 1，不再发概要请求（交给 v1 的「到最早」）。
        await model.loadOlder()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(summaryCalls().count, 2)
    }

    func test_without_the_v2_capability_older_paging_never_asks_for_a_summary_page() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.foldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(
            Self.windowJSON(turn: 1, start: 1, summaryStart: 3, summaryEnd: 5,
                            answerSeq: 6, endSeq: 7, hasMore: false))
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 7))
        _ = await eventually { model.phase == .ready }
        await model.loadOlder()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(summaryCalls().isEmpty, "没有 v2 能力时旧页不能发概要请求")
    }

    // MARK: - 概要旧页的状态归属（无管道/空页/管道停止）

    func test_older_summary_does_nothing_without_a_pipeline() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON())
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        _ = await eventually { model.summaryScreenState == .ready }
        let before = summaryCalls().count

        let handled = await model.loadOlderSummaryPage()
        XCTAssertFalse(handled, "没有管道就没有概要旧页")
        XCTAssertEqual(model.olderState, .idle)

        // 老路径的 loadOlder 也不再落「尚未连接」这类失败态。
        await model.loadOlder()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.olderState, .idle, "无管道时不上拉、也不失败")
        XCTAssertEqual(summaryCalls().count, before, "不发概要旧页请求")
    }

    func test_an_empty_older_page_without_a_confirmed_range_means_earliest() async throws {
        try attachLayer(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(
            Self.windowJSON(turn: 2, start: 10, summaryStart: 12, summaryEnd: 13,
                            answerSeq: 14, endSeq: 15))
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 15))
        _ = await eventually { model.summaryScreenState == .ready }

        // 空页、hasMore=true、没有任何"更早范围"的证据：这是到头，不是失败。
        carrier.unaryResponses["_link/sessionWindow"] = .success(.object([
            "records": .array([]), "hasMore": .bool(true),
        ]))
        await model.loadOlder()
        let earliest = await eventually { model.olderState == .exhausted }
        XCTAssertTrue(earliest, "state: \(model.olderState)")
        XCTAssertNotEqual(model.olderState, .failed(String(localized: "读取更早的记录失败，点按重试")))
    }

    func test_a_summary_older_failure_does_not_outlive_the_pipeline() async throws {
        try attachLayer(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(
            Self.windowJSON(turn: 2, start: 10, summaryStart: 12, summaryEnd: 13,
                            answerSeq: 14, endSeq: 15))
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: 15))
        _ = await eventually { model.summaryScreenState == .ready }

        carrier.unaryResponses["_link/sessionWindow"] = .failure(
            DSHRPCFailure(code: "link/too-large", message: "turn too large"))
        await model.loadOlder()
        let failed = await eventually {
            if case .failed = model.olderState { return true }
            return false
        }
        XCTAssertTrue(failed)

        // 管道一停，这条失败就没有归属了：非管道宿主不能继续画胶囊。
        model.stopPipelineSubscription()
        XCTAssertFalse(model.pipelineActive)
        XCTAssertEqual(model.olderState, .idle)
    }

    // MARK: - 单条正文超限（M6c）

    func test_a_step_whose_declared_size_is_over_the_limit_is_terminal_without_a_request() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(
            Self.summaryPageJSON(turn: 1,
                                 stepBytes: TimelineProcessStep.detailMaxBytes + 1))
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        _ = await eventually { model.summaryScreenState == .ready }
        expandTurnAndGroup()
        let before = detailCalls().count

        model.toggleProcessStep(Self.stepID)
        XCTAssertTrue(model.isProcessStepExpanded(Self.stepID))
        XCTAssertEqual(model.stepBodies[Self.stepID], .tooLarge)
        XCTAssertEqual(detailCalls().count, before, "概要已经给出大小，不再发请求")

        // 终态不重试：点了也只还是同一句话。
        model.retryProcessStepBody(Self.stepID)
        XCTAssertEqual(model.stepBodies[Self.stepID], .tooLarge)
        XCTAssertEqual(detailCalls().count, before)
    }

    func test_a_too_large_response_from_a_single_step_fetch_is_terminal() async throws {
        fake.clientOverride = makeClient(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON())
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        _ = await eventually { model.summaryScreenState == .ready }
        expandTurnAndGroup()
        let before = detailCalls().count

        carrier.unaryResponses["_link/sessionWindow"] = .failure(
            DSHRPCFailure(code: "link/too-large", message: "record too large"))
        model.toggleProcessStep(Self.stepID)
        let terminal = await eventually { model.stepBodies[Self.stepID] == .tooLarge }
        XCTAssertTrue(terminal, "state: \(String(describing: model.stepBodies[Self.stepID]))")
        let callsAfterFetch = detailCalls().count

        model.retryProcessStepBody(Self.stepID)
        XCTAssertEqual(model.stepBodies[Self.stepID], .tooLarge)
        XCTAssertEqual(detailCalls().count, callsAfterFetch, "超限终态不再发请求")
        XCTAssertGreaterThan(callsAfterFetch, before)
    }

    // MARK: - 管道路径（概要页整段记为已读，不生成缺口）

    func test_adopting_the_summary_page_through_the_pipeline_leaves_no_gaps() async throws {
        try attachLayer(capabilities: [HistoryWindowWire.summaryFoldCapability])
        carrier.unaryResponses["_link/sessionWindow"] = .success(Self.summaryPageJSON())
        await model.open(try ChatSeam.summary(id: "s-1", asOfSeq: Self.asOfSeq))
        let ready = await eventually { model.summaryScreenState == .ready }
        XCTAssertTrue(ready)
        _ = await eventually { model.pipelineBridge?.records.isEmpty == false }
        // 概要页折掉的 seq（4、5）不是缺口：整段 startSeq...endSeq 已读。
        let gaps = model.rowsFor(screen: "s-1").compactMap { item -> TimelineItem.GapStatus? in
            if case .gap(_, _, let status) = item.kind { return status }
            return nil
        }
        XCTAssertTrue(gaps.isEmpty, "summary page must not create gap rows")
        XCTAssertEqual(model.timeline.foldSummaries.count, 1)
    }

    // MARK: - 夹具

    private func makeClient(capabilities: Set<String>) -> any HostClient {
        // `_link/sessionWindow` 本身也要有 `history-window`：概要不走另一条通道。
        HostClientFactory.make(carrier: carrier,
                               capabilities: capabilities.union(["history-window"]))
    }

    private func attachLayer(capabilities: Set<String>) throws {
        fake.clientOverride = makeClient(capabilities: capabilities)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-summary-screen-tests-\(UUID().uuidString)")
        directory = dir
        let messageLayer = MessageLayer()
        let client = makeClient(capabilities: capabilities)
        messageLayer.attach(client: { client },
                            storePath: dir.appendingPathComponent("messages.sqlite3"))
        guard messageLayer.isReady else {
            throw XCTSkip("MessageLayer could not open its message store in this environment")
        }
        layer = messageLayer
        model.attach(messageLayer: messageLayer)
    }

    private func expandTurnAndGroup() {
        let plan = model.processPlan()
        guard let turn = plan.turns.first else { return XCTFail("no turn") }
        model.toggleProcess(turnKey: turn.key)
        for group in turn.groups { model.toggleProcessGroup(groupKey: group.key) }
    }

    /// 概要模式的首屏请求（`fold: "summary"`），与 v1/普通窗口区分开。
    private func summaryCalls() -> [FakeCarrier.RecordedCall] {
        carrier.calls(to: "_link/sessionWindow").filter { call in
            call.args?["fold"]?.stringValue == "summary"
        }
    }

    private func detailCalls() -> [FakeCarrier.RecordedCall] {
        carrier.calls(to: "_link/sessionWindow").filter { call in
            call.args?["limit"]?.intValue == 1 && call.args?["fold"] == nil
        }
    }

    /// 一页概要 v2 窗口（可指定轮次与各 seq，测试旧页/大正文时用）。
    private static func windowJSON(turn: Int, start: Int, summaryStart: Int, summaryEnd: Int,
                                   answerSeq: Int, endSeq: Int,
                                   hasMore: Bool = true, stepBytes: Int = 900,
                                   clamped: Bool = false) -> JSONValue {
        .object([
            "records": .array([
                .object(["event": .object([
                    "type": .string("turn/start"), "seq": .int(start),
                    "data": .object(["turn": .int(turn)]),
                ])]),
                .object(["event": .object([
                    "type": .string("user/message"), "seq": .int(start + 1),
                    "data": .object([
                        "source": .object(["kind": .string("user"),
                                           "rpcId": .string("r-\(turn)")]),
                        "content": .array([.object(["type": .string("text"),
                                                    "text": .string("问题\(turn)")])]),
                    ]),
                ])]),
                .object(["event": .object([
                    "type": .string("+link/fold"), "seq": .int(summaryStart),
                    "data": .object([
                        "v": .int(2), "turn": .int(turn),
                        "startSeq": .int(summaryStart),
                        "endSeq": .int(summaryEnd),
                        "durationMs": .int(4200), "endReason": .string("completed"),
                        "activities": .object(["commands": .int(1)]),
                        "groups": .array([
                            .object([
                                "startSeq": .int(summaryStart),
                                "endSeq": .int(summaryEnd),
                                "activities": .object(["commands": .int(1)]),
                                "toolCount": .int(1),
                                "steps": .array([
                                    .object([
                                        "seq": .int(summaryStart),
                                        "kind": .string("tools"), "name": .string("bash"),
                                        "preview": .string("swift build"),
                                        "status": .string("ok"),
                                        "resultSeq": .int(summaryStart + 1),
                                        "bytes": .int(stepBytes),
                                    ]),
                                    .object([
                                        "seq": .int(summaryEnd),
                                        "kind": .string("reasoning"),
                                        "name": .string("thinking"),
                                        "preview": .string(""),
                                        "status": .string("ok"), "bytes": .int(1500),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ])]),
                .object(["event": .object([
                    "type": .string("assistant/message"), "seq": .int(answerSeq),
                    "data": .object([
                        "turn": .int(turn), "step": .int(2),
                        "message": .object(["role": .string("assistant"), "content": .array([
                            .object(["type": .string("text"), "text": .string("回答\(turn)")]),
                        ])]),
                    ]),
                ])]),
                .object(["event": .object([
                    "type": .string("turn/end"), "seq": .int(endSeq),
                    "data": .object(["turn": .int(turn),
                                     "reason": .object(["kind": .string("completed")])]),
                ])]),
            ]),
            "startSeq": .int(start),
            "endSeq": .int(endSeq),
            "hasMore": .bool(hasMore),
            "clamped": .bool(clamped),
        ])
    }

    /// M6b 首屏用例的默认窗口（一轮：讲话 2 + 概要 3..5 + 回答 6 + 边界 7）。
    private static func summaryPageJSON(turn: Int = 1, stepBytes: Int = 900) -> JSONValue {
        turn == 1
            ? windowJSON(turn: 1, start: 1, summaryStart: 3, summaryEnd: 5,
                         answerSeq: 6, endSeq: 7, stepBytes: stepBytes)
            : windowJSON(turn: 2, start: 8, summaryStart: 10, summaryEnd: 12,
                         answerSeq: 13, endSeq: 14, stepBytes: stepBytes)
    }

    private static func stepBodyJSON(seq: Int, text: String) -> JSONValue {
        .object([
            "records": .array([
                .object(["event": .object([
                    "type": .string("tool/result"), "seq": .int(seq),
                    "data": .object([
                        "message": .object([
                            "source": .object(["callId": .string("c-1")]),
                            "content": .array([.object([
                                "type": .string("tool-result"),
                                "toolCallId": .string("c-1"),
                                "isError": .bool(false),
                                "content": .array([.object(["type": .string("text"),
                                                            "text": .string(text)])]),
                            ])]),
                        ]),
                    ]),
                ])]),
            ]),
            "startSeq": .int(seq), "endSeq": .int(seq), "hasMore": .bool(true),
        ])
    }

    private static func otherRecordJSON() -> JSONValue {
        .object([
            "records": .array([
                .object(["event": .object([
                    "type": .string("assistant/message"), "seq": .int(1),
                    "data": .object(["turn": .int(1), "step": .int(1),
                                     "message": .object(["role": .string("assistant"),
                                                         "content": .array([])])]),
                ])]),
            ]),
            "startSeq": .int(1), "endSeq": .int(1), "hasMore": .bool(true),
        ])
    }

    private func eventually(deadline: TimeInterval = 3,
                            _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

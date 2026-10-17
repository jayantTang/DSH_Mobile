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
        let plan = TranscriptProcessFold.plan(items: timeline.items, isTurnOpen: false)
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
            rows.count == 4 && rows.contains(where: { if case .processHeader = $0.kind { return true }; return false })
        }
        XCTAssertEqual(rows.count, 4, "folded rows: \(rows.map(\.id))")
        let header = try XCTUnwrap(rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind { return value }
            return nil
        }.first)
        XCTAssertEqual(header.scope, .turn)
        XCTAssertFalse(header.isExpanded)
        XCTAssertEqual(header.toolCount, 1)
        XCTAssertFalse(rows.map(\.id).contains("tool-call-1"))

        model.toggleProcess(turnKey: header.id)
        let expanded = await eventuallyRows { $0.map(\.id).contains("tool-call-1") }
        XCTAssertTrue(expanded.map(\.id).contains("tool-call-1"))

        model.toggleProcess(turnKey: header.id)
        let collapsed = await eventuallyRows { !$0.map(\.id).contains("tool-call-1") }
        XCTAssertFalse(collapsed.map(\.id).contains("tool-call-1"))
    }

    func test_reader_inside_the_process_keeps_it_open_then_collapses_after_leaving() async throws {
        try await openWithOneCompletedTurn()
        model.noteReaderTopRow("tool-call-1")
        let held = await eventuallyRows { $0.map(\.id).contains("tool-call-1") }
        XCTAssertTrue(held.map(\.id).contains("tool-call-1"),
                      "the turn collapsed under a reader who was inside its process")

        model.noteReaderTopRow(nil)
        let collapsed = await eventuallyRows { !$0.map(\.id).contains("tool-call-1") }
        XCTAssertFalse(collapsed.map(\.id).contains("tool-call-1"))
    }

    func test_search_reveal_expands_the_turn_and_returns_the_row() async throws {
        try await openWithOneCompletedTurn()
        _ = await eventuallyRows { rows in rows.count == 4 }
        let revealed = model.revealProcess(containingRowID: "tool-call-1")
        XCTAssertEqual(revealed, "tool-call-1")
        let rows = await eventuallyRows { $0.map(\.id).contains("tool-call-1") }
        XCTAssertTrue(rows.map(\.id).contains("tool-call-1"))
        XCTAssertNil(model.revealProcess(containingRowID: "not-here"))
    }

    func test_switching_sessions_resets_the_disclosure_state() async throws {
        try await openWithOneCompletedTurn()
        let rows = await eventuallyRows { $0.count == 4 }
        let header = try XCTUnwrap(rows.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind { return value }
            return nil
        }.first)
        model.toggleProcess(turnKey: header.id)
        XCTAssertFalse(model.foldState.manualTurn.isEmpty)

        await model.open(try ChatSeam.summary(id: "s-other", asOfSeq: 1))
        XCTAssertTrue(model.foldState.manualTurn.isEmpty)
        XCTAssertTrue(model.foldState.collapsedGroups.isEmpty)
    }

    func test_an_error_turn_stays_expanded_on_the_model_surface() async throws {
        try await openWithOneCompletedTurn(reason: "error")
        let rows = await eventuallyRows { $0.map(\.id).contains("tool-call-1") }
        XCTAssertTrue(rows.map(\.id).contains("tool-call-1"))
        XCTAssertFalse(rows.contains { if case .processHeader = $0.kind { return true }; return false })
    }

    func test_group_toggle_only_hides_that_group() async throws {
        try await openWithOneCompletedTurn(intermediate: true)
        let folded = await eventuallyRows { $0.count == 4 }
        let turnHeader = try XCTUnwrap(folded.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind, value.scope == .turn { return value }
            return nil
        }.first)
        model.toggleProcess(turnKey: turnHeader.id)
        let expanded = await eventuallyRows { rows in
            rows.contains { if case .processHeader(let h) = $0.kind, h.scope == .group { return true }; return false }
        }
        let group = try XCTUnwrap(expanded.compactMap { item -> TimelineProcessHeader? in
            if case .processHeader(let value) = item.kind, value.scope == .group { return value }
            return nil
        }.first)
        model.toggleProcessGroup(groupKey: group.id)
        let collapsedGroup = await eventuallyRows { rows in
            rows.contains { if case .processHeader(let h) = $0.kind, h.id == group.id, h.isExpanded == false { return true }; return false }
        }
        XCTAssertTrue(collapsedGroup.contains { if case .processHeader(let h) = $0.kind { return h.id == group.id && !h.isExpanded }; return false })
    }

    func test_reopening_the_same_session_keeps_the_reader_state() async throws {
        try await openWithOneCompletedTurn()
        let rows = await eventuallyRows { $0.count == 4 }
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
        _ = await eventuallyRows { $0.count == 4 }
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
        fake.clientOverride = DSHClient(carrier: carrier)
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

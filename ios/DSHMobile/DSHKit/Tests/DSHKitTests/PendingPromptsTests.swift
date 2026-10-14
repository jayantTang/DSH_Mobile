import XCTest

@testable import DSHKit

/// 待答集合的用例（spec 023 边界收敛：判定从 `HostEventHub` 抽进 DSHKit）。
///
/// 这一小段逻辑决定"用户在手机上看得见什么在等他"——本仓库反复踩过这类问题
/// （见 `maintainers/PENDING-WATERFALL-LOSS.md`），所以每条规则都钉住。
final class PendingPromptsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func waterfall(_ id: String, agent: String = "s1", event: String = "approval/asked") -> HostEvent {
        .waterfall(HostEvent.Waterfall(event: event, eventId: id, agentId: agent, request: .string("payload")))
    }

    // MARK: - 推进来

    func testWaterfallIsPromotedWithItsFields() {
        var pending = PendingPrompts()
        XCTAssertEqual(pending.apply(waterfall("e1"), now: t0), .changed)
        XCTAssertEqual(pending.count, 1)
        let item = pending.first
        XCTAssertEqual(item?.id, "e1")
        XCTAssertEqual(item?.event, "approval/asked")
        XCTAssertEqual(item?.agentId, "s1")
        XCTAssertEqual(item?.sessionId, "s1")
        XCTAssertEqual(item?.arrivedAt, t0, "到达时刻由调用方注入，用例才可判定")
        XCTAssertEqual(item?.request, .string("payload"))
    }

    func testDuplicateWaterfallDoesNotAppearTwice() {
        // 重连补投会再发一遍：集合里必须还是一条，否则用户看到两条一样的提问。
        var pending = PendingPrompts()
        pending.apply(waterfall("e1"), now: t0)
        XCTAssertEqual(pending.apply(waterfall("e1"), now: t0.addingTimeInterval(5)), .unchanged)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.arrivedAt, t0, "重复推送不改到达时刻")
    }

    func testDifferentIdsAreKeptInArrivalOrder() {
        var pending = PendingPrompts()
        pending.apply(waterfall("e1"), now: t0)
        pending.apply(waterfall("e2"), now: t0)
        pending.apply(waterfall("e3"), now: t0)
        XCTAssertEqual(pending.map(\.id), ["e1", "e2", "e3"])
    }

    // MARK: - 拿掉

    func testCancelledRemovesThatId() {
        var pending = PendingPrompts()
        pending.apply(waterfall("e1"), now: t0)
        pending.apply(waterfall("e2"), now: t0)
        XCTAssertEqual(pending.apply(.cancelled(eventId: "e1")), .changed)
        XCTAssertEqual(pending.map(\.id), ["e2"])
    }

    func testCancellingSomethingUnknownChangesNothing() {
        var pending = PendingPrompts()
        pending.apply(waterfall("e1"), now: t0)
        XCTAssertEqual(pending.apply(.cancelled(eventId: "nope")), .unchanged)
        XCTAssertEqual(pending.count, 1)
    }

    // MARK: - 无关事件

    func testOtherEventsNeverTouchTheSet() {
        var pending = PendingPrompts()
        pending.apply(waterfall("e1"), now: t0)
        XCTAssertEqual(pending.apply(.ready(clientId: "c", home: "/h")), .unchanged)
        XCTAssertEqual(pending.apply(.emit(event: "x", args: [])), .unchanged)
        XCTAssertEqual(pending.apply(.unknown(type: "t", raw: .null)), .unchanged)
        XCTAssertEqual(pending.count, 1)
    }

    func testOnlyTwoEventKindsChangeTheSet() {
        XCTAssertTrue(PendingPrompts.changesPending(waterfall("e")))
        XCTAssertTrue(PendingPrompts.changesPending(.cancelled(eventId: "e")))
        XCTAssertFalse(PendingPrompts.changesPending(.ready(clientId: "c", home: "")))
        XCTAssertFalse(PendingPrompts.changesPending(.emit(event: "x", args: [])))
        XCTAssertFalse(PendingPrompts.changesPending(.unknown(type: "t", raw: .null)))
    }

    // MARK: - 按会话 / 清空

    func testForSessionFiltersByAgent() {
        var pending = PendingPrompts()
        pending.apply(waterfall("e1", agent: "s1"), now: t0)
        pending.apply(waterfall("e2", agent: "s2"), now: t0)
        pending.apply(waterfall("e3", agent: "s1"), now: t0)
        XCTAssertEqual(pending.forSession("s1").map(\.id), ["e1", "e3"])
        XCTAssertTrue(pending.forSession("s3").isEmpty)
    }

    func testRemoveAndRemoveAll() {
        var pending = PendingPrompts()
        pending.apply(waterfall("e1"), now: t0)
        pending.apply(waterfall("e2"), now: t0)
        pending.remove(id: "e1")
        XCTAssertEqual(pending.map(\.id), ["e2"])
        pending.removeAll()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(pending.count, 0)
    }

    // MARK: - 当数组用的读取面

    func testItReadsLikeACollection() {
        var pending = PendingPrompts()
        pending.apply(waterfall("e1", agent: "s1"), now: t0)
        pending.apply(waterfall("e2", agent: "s2"), now: t0)
        XCTAssertEqual(pending.map(\.agentId), ["s1", "s2"])
        XCTAssertEqual(pending.first(where: { $0.id == "e2" })?.agentId, "s2")
        XCTAssertEqual(Array(pending).count, 2)
        XCTAssertEqual(pending[pending.startIndex].id, "e1")
        XCTAssertNil(PendingPrompts().first)
    }

    func testEqualityIsValueBased() {
        var a = PendingPrompts()
        var b = PendingPrompts()
        a.apply(waterfall("e1"), now: t0)
        b.apply(waterfall("e1"), now: t0)
        XCTAssertEqual(a, b)
        b.apply(.cancelled(eventId: "e1"))
        XCTAssertNotEqual(a, b)
    }
}

import XCTest
@testable import DSHMobile

/// 前后台计划的判定表：哪一档该冲写盘、补状态、重连、保活。
///
/// 这些分支原来散在 RootView 的 `.onChange(of: scenePhase)` 里，没有单测；
/// 抽成计划之后先在这里钉住，执行器只负责按计划发动作。
final class AppLifecyclePlanTests: XCTestCase {

    func testActiveConnectedRefreshesWithoutReconnecting() {
        let plan = AppLifecyclePlan.make(.init(
            phase: .active, isConnected: true, hasWorkInFlight: false))
        XCTAssertTrue(plan.noteForeground)
        XCTAssertTrue(plan.refreshAccountState)
        XCTAssertTrue(plan.refreshUpdates)
        XCTAssertTrue(plan.refreshFeedback)
        XCTAssertTrue(plan.refreshPushRegistration)
        XCTAssertTrue(plan.startFeedAndRefreshList)
        XCTAssertTrue(plan.syncTail)
        XCTAssertFalse(plan.reconnect)
        XCTAssertFalse(plan.flushTranscripts)
        XCTAssertFalse(plan.holdAwake)
    }

    func testActiveDisconnectedReconnects() {
        let plan = AppLifecyclePlan.make(.init(
            phase: .active, isConnected: false, hasWorkInFlight: false))
        XCTAssertTrue(plan.reconnect)
        XCTAssertFalse(plan.startFeedAndRefreshList)
        XCTAssertFalse(plan.syncTail)
    }

    func testBackgroundFlushesAndHoldsAwakeOnlyWithWork() {
        let withWork = AppLifecyclePlan.make(.init(
            phase: .background, isConnected: true, hasWorkInFlight: true))
        XCTAssertTrue(withWork.flushTranscripts)
        XCTAssertTrue(withWork.noteBackground)
        XCTAssertTrue(withWork.holdAwake)
        XCTAssertFalse(withWork.refreshUpdates)

        let idle = AppLifecyclePlan.make(.init(
            phase: .background, isConnected: true, hasWorkInFlight: false))
        XCTAssertTrue(idle.flushTranscripts)
        XCTAssertFalse(idle.holdAwake)
    }

    func testInactiveFlushesButDoesNotClaimForegroundOrBackground() {
        let plan = AppLifecyclePlan.make(.init(
            phase: .inactive, isConnected: true, hasWorkInFlight: true))
        XCTAssertTrue(plan.flushTranscripts)
        XCTAssertFalse(plan.noteForeground)
        XCTAssertFalse(plan.noteBackground)
        XCTAssertFalse(plan.refreshUpdates)
        XCTAssertFalse(plan.holdAwake)
    }
}

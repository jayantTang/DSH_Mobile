import XCTest

@testable import DSHKit

/// 连接监管状态机的用例（spec 023 / S2，T034–T035）。
///
/// 每条都对应 022 复盘里的一条结论：探活节拍分快慢、单次失败不改判、退避只在活得够久后清零、
/// 在飞拨号要合流。这些行为以前只能靠真机看，现在在 macOS 上就能断言。
final class LinkSupervisorTests: XCTestCase {

    // MARK: - 探活节拍

    func testProbeIntervalIsSlowWhenConnectedAndFastWhenNot() {
        let sup = LinkSupervisor()
        XCTAssertEqual(sup.probeInterval(isConnected: true), 20)
        XCTAssertEqual(sup.probeInterval(isConnected: false), 3)
        XCTAssertGreaterThan(sup.probeInterval(isConnected: true), sup.probeInterval(isConnected: false))
    }

    func testPolicyIsInjectable() {
        let sup = LinkSupervisor(policy: .init(heartbeat: 60, recoveryProbe: 1, failuresToDeclareDown: 3))
        XCTAssertEqual(sup.probeInterval(isConnected: true), 60)
        XCTAssertEqual(sup.probeInterval(isConnected: false), 1)
    }

    // MARK: - 两击判定

    func testSingleProbeFailureDoesNotDeclareTheLinkDown() {
        var sup = LinkSupervisor()
        XCTAssertEqual(sup.noteProbe(ok: false), .unchanged, "抖一下不该让界面闪「重连中」")
        XCTAssertEqual(sup.noteProbe(ok: false), .declareDown, "连续两次才判")
    }

    func testSuccessInBetweenResetsTheStrikeCount() {
        var sup = LinkSupervisor()
        XCTAssertEqual(sup.noteProbe(ok: false), .unchanged)
        XCTAssertEqual(sup.noteProbe(ok: true), .unchanged)
        XCTAssertEqual(sup.consecutiveProbeFailures, 0, "中间成功一次就重新数")
        XCTAssertEqual(sup.noteProbe(ok: false), .unchanged, "这是新一轮的第 1 次，不是第 3 次")
    }

    func testDeclareDownKeepsFiringWhileFailuresContinue() {
        var sup = LinkSupervisor()
        _ = sup.noteProbe(ok: false)
        XCTAssertEqual(sup.noteProbe(ok: false), .declareDown)
        XCTAssertEqual(sup.noteProbe(ok: false), .declareDown, "还在失败就继续判，不做一次性闸门")
    }

    func testRecoveryClearsTheStrikeCount() {
        var sup = LinkSupervisor()
        _ = sup.noteProbe(ok: false)
        sup.noteProbeRecovered()
        XCTAssertEqual(sup.consecutiveProbeFailures, 0)
        XCTAssertEqual(sup.noteProbe(ok: false), .unchanged)
    }

    // MARK: - 退避

    /// 排序要钉住：`noteLinkEnded` 是"**先自增、再给出下一次延迟**"，与 App 的循环一致
    /// （`ConnectionStore.startWatching`：note → `delay = nextDelay` → sleep）。
    /// 所以第一次失败后等的是 **2 秒**；而 `ReconnectBackoffTests` 是"先读 `nextDelay` 再 note"，
    /// 那里第一次是 1 秒。两者形状相同（倍增、封顶 30），只差一个相位——写清楚，
    /// 免得后来人以为哪一边算错了。
    func testShortLivedLinkDoesNotResetTheBackoff() {
        var sup = LinkSupervisor()
        XCTAssertEqual(sup.noteLinkEnded(livedFor: 0.8), 2, "第 1 次失败后等 2 秒（attempt 已自增到 1）")
        XCTAssertEqual(sup.attempt, 1)
        XCTAssertEqual(sup.noteLinkEnded(livedFor: 0.8), 4, "第 2 次：4 秒")
        XCTAssertEqual(sup.noteLinkEnded(livedFor: 0.8), 8, "第 3 次：8 秒")
    }

    func testStableLinkResetsTheBackoff() {
        var sup = LinkSupervisor()
        _ = sup.noteLinkEnded(livedFor: 0.5)
        _ = sup.noteLinkEnded(livedFor: 0.5)
        XCTAssertEqual(sup.attempt, 2)
        XCTAssertEqual(sup.noteLinkEnded(livedFor: ReconnectBackoff.stabilityWindow), 1,
                       "活满稳定窗口 → 清零 → 下一次回到 1 秒")
        XCTAssertEqual(sup.attempt, 0)
    }

    func testBackoffIsCapped() {
        var sup = LinkSupervisor()
        var delay: TimeInterval = 0
        for _ in 0..<12 { delay = sup.noteLinkEnded(livedFor: 0.1) }
        XCTAssertEqual(delay, 30, "封顶 30 秒")
    }

    // MARK: - 用户动作与单飞

    func testResetClearsBothBackoffAndStrikes() {
        var sup = LinkSupervisor()
        _ = sup.noteLinkEnded(livedFor: 0.2)
        _ = sup.noteProbe(ok: false)
        sup.reset()
        XCTAssertEqual(sup.attempt, 0)
        XCTAssertEqual(sup.consecutiveProbeFailures, 0)
        XCTAssertEqual(sup.noteLinkEnded(livedFor: 0.2), 2, "用户动作之后从最小档重新开始（同样先自增）")
    }

    func testDialIsSingleFlight() {
        let sup = LinkSupervisor()
        XCTAssertTrue(sup.shouldDial(isDialing: false))
        XCTAssertFalse(sup.shouldDial(isDialing: true), "已有在飞拨号 → 合流，不另起一拨（022 US3）")
    }

    /// 风暴场景的端到端口径（与 `ReconnectBackoffTests` 同一条 SC-001）：
    /// 2 分钟内接入次数 ≤8。这里走监管这一层，确认它没有把节奏放大回去。
    func testTwoMinuteStormStaysUnderEightAttaches() {
        var sup = LinkSupervisor()
        var elapsed: TimeInterval = 0
        var attaches = 0
        while elapsed < 120 {
            attaches += 1
            elapsed += 0.8
            elapsed += sup.noteLinkEnded(livedFor: 0.8)
        }
        XCTAssertLessThanOrEqual(attaches, 8, "两分钟内接入次数应 ≤8，实得 \(attaches)")
    }
}

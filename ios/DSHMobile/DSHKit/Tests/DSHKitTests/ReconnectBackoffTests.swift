import Testing
import Foundation
@testable import DSHKit

/// spec 022 FR-001/FR-002：退避只在链路**稳定存活**后清零。
///
/// 边界值直接照抄 2026-10-13 真机风暴现场（socket 只活 0.8 秒、两分钟接入 111 次），
/// 这样"改完还会不会每秒重连"在单测里就能回答，不必等真机复现。
@Suite("ReconnectBackoff")
struct ReconnectBackoffTests {

    @Test("0.8 秒就掉线的连接不清零，延迟逐次增长（风暴现场）")
    func shortLivedConnectionsGrowTheDelay() {
        var backoff = ReconnectBackoff()
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            delays.append(backoff.nextDelay)
            let reset = backoff.noteConnectionEnded(livedFor: 0.8)
            #expect(reset == false, "0.8 秒不算稳定，不该清零")
        }
        // 1 → 2 → 4 → 8 → 16 → 30：单调增长，不再是每秒一次
        let expected: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        for (got, want) in zip(delays, expected) {
            #expect(abs(got - want) < 1e-9, "第 \(delays.firstIndex(of: got) ?? 0) 次延迟应为 \(want)，实得 \(got)")
        }
    }

    @Test("风暴场景两分钟内的接入次数降到 8 次（SC-001；改前是 100+）")
    func stormCadenceIsBroken() {
        var backoff = ReconnectBackoff()
        var elapsed: TimeInterval = 0
        var attaches = 0
        // 模拟两分钟：每条连接活 0.8 秒，之后按 nextDelay 等待再拨
        while elapsed < 120 {
            attaches += 1
            elapsed += 0.8
            backoff.noteConnectionEnded(livedFor: 0.8)
            elapsed += backoff.nextDelay
        }
        #expect(attaches <= 8, "两分钟内接入次数应 ≤8（改前是 100+），实得 \(attaches)")
    }

    @Test("存活到 15 秒的连接把退避清零")
    func stableConnectionResetsTheBackoff() {
        var backoff = ReconnectBackoff()
        backoff.noteConnectionEnded(livedFor: 0.5)
        backoff.noteConnectionEnded(livedFor: 0.5)
        #expect(backoff.attempt == 2)
        #expect(backoff.noteConnectionEnded(livedFor: ReconnectBackoff.stabilityWindow) == true)
        #expect(backoff.attempt == 0)
        #expect(backoff.nextDelay == 1, "稳定之后恢复是一次快速重连（SC-002 ≤1 秒）")
    }

    @Test("稳定阈值边界：14.9 秒不算稳定，15 秒算")
    func stabilityBoundary() {
        var justUnder = ReconnectBackoff()
        justUnder.noteConnectionEnded(livedFor: 14.9)
        #expect(justUnder.attempt == 1)

        var exactly = ReconnectBackoff()
        exactly.noteConnectionEnded(livedFor: 15)
        #expect(exactly.attempt == 0)
    }

    @Test("延迟封顶：增长到 cap 后不再变")
    func delayIsCapped() {
        var backoff = ReconnectBackoff()
        for _ in 0..<40 { backoff.noteConnectionEnded(livedFor: 0.2) }
        #expect(backoff.nextDelay == 30)
    }

    @Test("显式 reset 立刻归零（用户主动动作 / 回前台 / 主动断开）")
    func explicitReset() {
        var backoff = ReconnectBackoff()
        for _ in 0..<5 { backoff.noteConnectionEnded(livedFor: 0.3) }
        #expect(backoff.nextDelay > 1)
        backoff.reset()
        #expect(backoff.attempt == 0)
        #expect(backoff.nextDelay == 1)
    }
}

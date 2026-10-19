import Foundation
import Testing

@testable import DSHKit

/// 一元调用的截止与并发：没有回包要按时失败，并发不能无限放大。
@Suite("Unary deadline and concurrency")
struct LinkCarrierUnaryDeadlineTests {

    private func configuration() -> LinkConfiguration {
        LinkConfiguration(
            relayURL: URL(string: "https://relay.test/dsh-link")!,
            agentId: "agt_1",
            deviceToken: "dt_1"
        )
    }

    private func reconnectPolicy() -> ReconnectPolicy {
        ReconnectPolicy(initial: .milliseconds(20), maximum: .milliseconds(20),
                        multiplier: 1, jitter: 0, heartbeat: .seconds(30))
    }

    private func eventually(_ timeout: Duration = .seconds(3),
                            _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("回包不来：按截止时间失败，不无限挂起")
    func unaryFailsAtItsDeadline() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .milliseconds(80),
            reconnect: reconnectPolicy(),
            makeSocket: { _ in factory.make() }
        )
        await carrier.connect()
        #expect(await eventually { !factory.sockets.isEmpty && factory.sockets[0].resumed })

        let started = ContinuousClock.now
        do {
            _ = try await carrier.unary(method: "x", args: JSONValue.object([:]), as: JSONValue.self)
            Issue.record("expected a timeout")
        } catch {
            // expected
        }
        #expect(ContinuousClock.now - started < .seconds(5), "截止后应立即返回，允许机器繁忙的余量")
    }

    @Test("并发一元调用不超过上限")
    func unaryConcurrencyIsCapped() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .seconds(1),
            unaryLimit: 2,
            reconnect: reconnectPolicy(),
            makeSocket: { _ in factory.make() }
        )
        await carrier.connect()
        #expect(await eventually { !factory.sockets.isEmpty && factory.sockets[0].resumed })
        let socket = try #require(factory.sockets.first)

        let calls = (0..<6).map { _ in
            Task { _ = try? await carrier.unary(method: "x", args: JSONValue.object([:]), as: JSONValue.self) }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(socket.sent.count <= 2, "并发上限是 2，排队者不能提前发帧")
        for call in calls { call.cancel() }
        for call in calls { _ = await call.value }
    }
}

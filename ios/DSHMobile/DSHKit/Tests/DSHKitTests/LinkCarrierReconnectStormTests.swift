import Foundation
import Testing

@testable import DSHKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 重连风暴的回归测试（spec 022 第二批）。
///
/// 钉住三件事：
///   1. **T019**：拨号成功但转眼就掉的连接也算失败轮次——attempt 必须随每次
///      短存活掉线递增。2026-10-14 两次复发的现场就是 attempt 永远 0、节奏钉死 1 秒。
///   2. **T020**：并发进入 `ensureConnected` 只拨一条（单飞），不再互相 cancel。
///   3. **T005b**：socket 三态流按 `reconnecting → up → reconnecting → closed` 播报。
@Suite("Reconnect storm regressions")
struct LinkCarrierReconnectStormTests {

    private func configuration() -> LinkConfiguration {
        LinkConfiguration(
            relayURL: URL(string: "https://relay.test/dsh-link")!,
            agentId: "agt_1",
            deviceToken: "dt_1"
        )
    }

    /// 退避压到毫秒级、无抖动：测试不等真实秒级退避，但保留倍增形状。
    private func policy() -> ReconnectPolicy {
        ReconnectPolicy(
            initial: .milliseconds(20),
            maximum: .seconds(2),
            multiplier: 2,
            jitter: 0,
            heartbeat: .seconds(30)
        )
    }

    private func eventually(
        _ timeout: Duration = .seconds(5),
        _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("socket 每次只活一瞬间就掉：attempt 逐次递增（不是永远 0）")
    func shortLivedSocketsEscalateTheBackoff() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .seconds(1),
            reconnect: policy(),
            makeSocket: { _ in factory.make() }
        )
        await carrier.connect()
        #expect(await eventually { factory.count == 1 })

        // 照抄风暴现场：每条 socket 建好后立刻被"顶掉"，连续四轮。
        for expectedCount in 2...5 {
            let current = try #require(factory.sockets.last)
            current.failReceive()
            #expect(await eventually { factory.count == expectedCount })
        }

        let events = await carrier.diagnostics.entries()
        let backoffs = events.filter { $0.kind == "link.backoff" }
        let attempts = backoffs.compactMap { $0.detail?["attempt"]?.intValue }
        #expect(attempts == [1, 2, 3, 4],
                "短存活掉线必须递增退避轮次；全 0 就是 2026-10-14 复发的那条 bug")
        let resets = backoffs.compactMap { $0.detail?["reset"]?.boolValue }
        #expect(resets.allSatisfy { $0 == false }, "没有一条链路灯过 15 秒，不许清零")
        let nextMs = backoffs.compactMap { $0.detail?["nextMs"]?.intValue }
        #expect(nextMs == nextMs.sorted(), "退避延迟必须单调不减")
        await carrier.close()
    }

    @Test("并发进入 ensureConnected：只拨一条（单飞），不互相 cancel")
    func concurrentEnsureConnectedDialsOnce() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .milliseconds(300),
            reconnect: policy(),
            makeSocket: { _ in factory.make() }
        )
        // 五条并发调用同时落在"还没连上"的 carrier 上：单飞闸只许一拨出门。
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await carrier.unary(
                        method: "session/list", args: JSONValue.object([:]), as: JSONValue.self)
                }
            }
        }
        #expect(factory.count == 1, "并发进入必须复用同一拨；多出一条就是互相顶替的现场")
        let first = try #require(factory.sockets.first)
        #expect(first.cancelCount == 0, "唯一一条 socket 不该被任何人 cancel")
        await carrier.close()
    }

    @Test("socket 三态流：连接上、断、关 各播报一次")
    func socketStateStreamReportsTransitions() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .seconds(1),
            reconnect: policy(),
            makeSocket: { _ in factory.make() }
        )
        var iterator = await carrier.socketStateStream().makeAsyncIterator()
        #expect(await iterator.next() == .reconnecting, "首帧回放当前状态：未连接")

        await carrier.connect()
        #expect(await eventually { factory.count == 1 })
        #expect(await iterator.next() == .up)

        let first = try #require(factory.sockets.first)
        first.failReceive()
        #expect(await iterator.next() == .reconnecting)

        await carrier.close()
        #expect(await iterator.next() == .closed)
        #expect(await iterator.next() == nil, "关闭后流必须收尾")
    }

    @Test("摘要通道传输类失败：退避重试后回退旧通道，并记 list.fallback")
    func digestTransportFallbackIsDiagnosed() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .seconds(5),
            reconnect: policy(),
            makeSocket: { _ in factory.make() }
        )
        await carrier.connect()
        #expect(await eventually { factory.count == 1 })
        let socket = try #require(factory.sockets.first)
        let client = HostClientFactory.make(carrier: carrier, capabilities: [HostClientFactory.sessionDigestCapability])

        let listTask = Task { try? await client.sessions() }
        // u1–u3：摘要通道连挂三次（传输类）；u4：旧通道应答。
        for step in [("u1", false), ("u2", false), ("u3", false), ("u4", true)] {
            let (id, ok) = step
            #expect(await eventually { socket.sent.contains { $0.contains("\"id\":\"\(id)\"") } },
                    "请求 \(id) 应该已经发出")
            if ok {
                socket.deliver(#"{"t":"res","id":"\#(id)","ok":true,"value":{"items":[]}}"#)
            } else {
                socket.deliver(#"{"t":"res","id":"\#(id)","ok":false,"error":{"code":"link/timeout","message":"boom"}}"#)
            }
        }
        let list = await listTask.value
        #expect(list != nil, "回退之后列表必须拿得到")

        let events = await carrier.diagnostics.entries()
        let fallbacks = events.filter { $0.kind == "list.fallback" }
        #expect(fallbacks.count == 1, "回退恰好记一次")
        #expect(fallbacks.first?.detail?["reason"] == .string("transport-after-retry"))
        await carrier.close()
    }
}

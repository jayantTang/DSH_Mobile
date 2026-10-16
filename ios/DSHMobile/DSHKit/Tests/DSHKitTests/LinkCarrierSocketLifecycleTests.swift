import Foundation
import Testing

@testable import DSHKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 可观测的 socket 替身。
///
/// 存在的理由见 `RelaySocketTask` 的注释：`URLSessionWebSocketTask` 在单测里造不出
/// 真连接，而 2026-10-12 线上那个问题恰恰出在"丢引用 ≠ 关连接"——引用丢了之后
/// URLSession 仍替它回 Pong，中转那边这条设备链路就一直挂着（实测 46 秒没死）。
/// 所以这里要能把 cancel 记下来、能替 socket 报告"我断了"和"我不能收发了"。
final class FakeRelaySocket: RelaySocketTask, @unchecked Sendable {
    struct Closed: Error {}

    private let lock = NSLock()
    private var cancelledCount = 0
    private var resumedFlag = false
    private var runningFlag = false
    private var sizeLimit = 0
    private var sentFrames: [String] = []
    private var waiting: [CheckedContinuation<URLSessionWebSocketTask.Message, any Error>] = []
    private var queued: [Result<URLSessionWebSocketTask.Message, any Error>] = []

    var cancelCount: Int { lock.withLock { cancelledCount } }
    var resumed: Bool { lock.withLock { resumedFlag } }
    var sent: [String] { lock.withLock { sentFrames } }

    var maximumMessageSize: Int {
        get { lock.withLock { sizeLimit } }
        set { lock.withLock { sizeLimit = newValue } }
    }

    var isRunning: Bool { lock.withLock { runningFlag } }

    func resume() {
        lock.withLock {
            resumedFlag = true
            runningFlag = true
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let waiters: [CheckedContinuation<URLSessionWebSocketTask.Message, any Error>] = lock.withLock {
            cancelledCount += 1
            runningFlag = false
            let pending = waiting
            waiting = []
            return pending
        }
        // 真实 URLSession 的行为：cancel 之后，正在等的 `receive()` 抛错。
        for waiter in waiters { waiter.resume(throwing: Closed()) }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if case .string(let text) = message { lock.withLock { sentFrames.append(text) } }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            var ready: Result<URLSessionWebSocketTask.Message, any Error>?
            lock.withLock {
                if queued.isEmpty {
                    waiting.append(continuation)
                } else {
                    ready = queued.removeFirst()
                }
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pongReceiveHandler(nil)
    }

    // MARK: - 测试推进用

    /// 投一条消息，等同于中转写来一帧。
    func deliver(_ text: String) {
        hand(.success(.string(text)))
    }

    /// 让在等的 `receive()` 失败，等同于这条 socket 自己断了。
    func failReceive(_ error: any Error = Closed()) {
        hand(.failure(error))
    }

    /// 报告"这条不能收发了"，逼 carrier 换一条（`ensureConnected` 的判据）。
    func markNotRunning() {
        lock.withLock { runningFlag = false }
    }

    private func hand(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        let waiter: CheckedContinuation<URLSessionWebSocketTask.Message, any Error>? = lock.withLock {
            waiting.isEmpty ? nil : waiting.removeFirst()
        }
        if let waiter {
            waiter.resume(with: result)
        } else {
            lock.withLock { queued.append(result) }
        }
    }
}

/// 每次造 socket 都发一条新替身，并记下来给测试断言。
final class FakeSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [FakeRelaySocket] = []

    var sockets: [FakeRelaySocket] { lock.withLock { created } }
    var count: Int { lock.withLock { created.count } }

    func make() -> FakeRelaySocket {
        let socket = FakeRelaySocket()
        lock.withLock { created.append(socket) }
        return socket
    }
}

@Suite("Relay socket lifecycle")
struct LinkCarrierSocketLifecycleTests {

    private func configuration() -> LinkConfiguration {
        LinkConfiguration(
            relayURL: URL(string: "https://relay.test/dsh-link")!,
            agentId: "agt_1",
            deviceToken: "dt_1"
        )
    }

    /// 把退避压到 20ms：测试不该等真实的 1s / 2s / 4s。
    private func policy() -> ReconnectPolicy {
        ReconnectPolicy(
            initial: .milliseconds(20),
            maximum: .milliseconds(20),
            multiplier: 1,
            jitter: 0,
            heartbeat: .seconds(30)
        )
    }

    /// 并发测试里没有回调可用，只能轮询等条件成立。
    private func eventually(
        _ timeout: Duration = .seconds(3),
        _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("socket 自己断了：那条 socket 必须被 cancel，之后才重连")
    func disconnectCancelsTheSocket() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .seconds(1),
            reconnect: policy(),
            makeSocket: { _ in factory.make() }
        )
        await carrier.connect()
        #expect(await eventually { factory.count == 1 })
        let first = try #require(factory.sockets.first)
        #expect(await eventually { first.resumed })

        first.failReceive()

        // 关键断言：不是"丢引用"就算完，必须真的 cancel 掉——中转那边只有收到关闭
        // 才会把这条设备链路放掉。
        #expect(await eventually { first.cancelCount == 1 })
        #expect(await eventually { factory.count == 2 })
        await carrier.close()
    }

    @Test("换 socket 先退旧的；旧 socket 迟到的错误不许拆掉新连接")
    func replacingSocketRetiresTheOldOne() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .milliseconds(200),
            reconnect: policy(),
            makeSocket: { _ in factory.make() }
        )
        await carrier.connect()
        #expect(await eventually { factory.count == 1 })
        let first = try #require(factory.sockets.first)
        #expect(await eventually { first.resumed })

        // 让 carrier 认为这条已经不能收发：下一次调用就会换一条。
        first.markNotRunning()
        _ = try? await carrier.unary(method: "session/list", args: JSONValue.object([:]), as: JSONValue.self)

        #expect(await eventually { factory.count == 2 })
        let second = try #require(factory.sockets.dropFirst().first)
        #expect(first.cancelCount == 1)

        // 旧 socket 的 `receive()` 因 cancel 抛错——这是残响。若没有归属判断，
        // 它会把这个刚建好的连接也 cancel 掉，并再拉起一条重连循环（于是第三条 socket）。
        try? await Task.sleep(for: .milliseconds(250))
        #expect(first.cancelCount == 1)
        #expect(second.cancelCount == 0)
        #expect(factory.count == 2)
        await carrier.close()
    }
}

// MARK: - 032：账户级状态推送

extension LinkCarrierSocketLifecycleTests {
    /// 中转推来的 `accountState` 必须原样到达订阅者。
    ///
    /// 这条用例守的是 `DLPFrames.agentToDevice` 那道**准入闸**：漏一个帧类型不报错，
    /// 只是把那一类推送静默丢掉——2026-10-16 真机上就是这么"一点反应都没有"的。
    /// `npm run check:contracts` 另有一条守卫比对它与 `docs/relay-contract.json`，
    /// 这里再钉一次"到了订阅者手里"的行为。
    @Test("accountState 帧到达订阅者")
    func accountStateFramesReachSubscribers() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .seconds(1),
            reconnect: policy(),
            makeSocket: { _ in factory.make() }
        )
        await carrier.connect()
        #expect(await eventually { factory.count == 1 })
        let socket = try #require(factory.sockets.first)

        let stream = await carrier.accountStateStream()
        var iterator = stream.makeAsyncIterator()
        socket.deliver(#"{"t":"accountState","keys":["alertPrefs","sessionRead.agt_1"]}"#)

        let keys = await iterator.next()
        #expect(keys == ["alertPrefs", "sessionRead.agt_1"])
    }

    /// 白名单之外的帧仍然要被丢掉（这道闸不能因为上面那条放宽成"什么都收"）。
    @Test("不在白名单里的帧不会到达订阅者")
    func unknownFramesStayDropped() async throws {
        let factory = FakeSocketFactory()
        let carrier = LinkCarrier(
            configuration: configuration(),
            timeout: .seconds(1),
            reconnect: policy(),
            makeSocket: { _ in factory.make() }
        )
        await carrier.connect()
        #expect(await eventually { factory.count == 1 })
        let socket = try #require(factory.sockets.first)

        let stream = await carrier.accountStateStream()
        var iterator = stream.makeAsyncIterator()
        socket.deliver(#"{"t":"somethingElse","keys":["alertPrefs"]}"#)
        // 紧跟一条合法的，用来判断"前面那条确实被丢了"而不是"还在排队"。
        socket.deliver(#"{"t":"accountState","keys":["after"]}"#)

        let keys = await iterator.next()
        #expect(keys == ["after"], "未知帧必须被丢掉，不能顶替")
    }
}

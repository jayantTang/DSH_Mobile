import XCTest
import DSHConnectionAPI
import DSHKit
@testable import DSHChatUI

/// 会话取图自愈（设计 §5 B1 / 用例 IMG-FLT-03、IMG-FLT-04）。
///
/// 单一改法：把"驱动结束"与"这张图已有字节"拆成两个事实。自动次数用尽只结束驱动，
/// flight 保留；`linkEstablished()` 因此仍有对象可重启。
///
/// 替身都写在本文件里：`DSHMobileTests` 不链接 `DSHTestingSupport`（那是模块包的
/// 测试支持库，只在包的测试目标里用）。
@MainActor
final class AttachmentSelfHealingTests: XCTestCase {

    /// 1×1 的 PNG（base64）：能真的解码，才走得到 `.loaded`。
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    /// 一次性闸门：`wait()` 挂起直到 `release()`（复现"请求在飞、链路恢复"的交错）。
    actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func release() {
            open = true
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    /// 假的取图实现：按**调用序号**给闸门与结果，并数调用次数（调用来自后台任务，加锁）。
    final class StubLoader: @unchecked Sendable {
        struct Step {
            var gate: Gate?
            var result: Result<JSONValue, any Error>

            static func hangs(_ gate: Gate, then result: Result<JSONValue, any Error>) -> Step {
                Step(gate: gate, result: result)
            }

            static func value(_ result: Result<JSONValue, any Error>) -> Step {
                Step(gate: nil, result: result)
            }
        }

        private let lock = NSLock()
        private var steps: [Step] = []
        private var calls = 0

        func script(_ steps: [Step]) {
            withLock {
                self.steps = steps
                calls = 0
            }
        }

        func count() -> Int { withLock { calls } }

        func load(_ sessionId: String, _ attachmentId: String) async throws -> JSONValue {
            let step: Step? = withLock {
                calls += 1
                return calls - 1 < steps.count ? steps[calls - 1] : nil
            }
            guard let step else {
                throw NSError(domain: "StubLoader", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no step for this call"])
            }
            try await step.gate?.wait()
            try Task.checkCancellation()
            switch step.result {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    /// 连接状态的最小替身：只需要 `chatHost` 与取图失败诊断。
    final class StubConnection: ConnectionStatus {
        var profiles: [ConnectionProfile] = []
        var activeProfile: ConnectionProfile?
        var state: ConnectionState = .disconnected
        var lastError: String?
        var capabilities: Set<String> = []
        var connectorVersion: String?
        var hostVersion: String?
        var hostHome: String?
        var activeBaseURL: URL? { nil }
        var scopeId: String? { "scope-self-heal" }
        var chatHost: (any ChatHosting)?
        var settingsHost: (any SettingsHosting)? { nil }
        var filesHost: (any FilesHosting)? { nil }
        var directoryHost: (any DirectoryHosting)? { nil }
        var activityHost: (any ActivityHosting)? { nil }
        var gitHost: (any GitHosting)? { nil }
        var showsOutdatedConnectorNotice = false
        func supports(_ capability: String) -> Bool { false }
        func dismissOutdatedConnectorNotice() {}

        private(set) var failures: [(id: String, attempt: Int, category: String)] = []
        func noteAttachmentLoadFailure(id: String, attempt: Int, category: String) async {
            failures.append((id, attempt, category))
        }
    }

    private var success: Result<JSONValue, any Error> {
        .success(.object(["data": .string(Self.pngBase64)]))
    }

    private var timedOut: Result<JSONValue, any Error> {
        .failure(DSHTransportError.timedOut(method: "session/attachment"))
    }

    private func makeSystem() -> (AttachmentImages, StubConnection, StubLoader) {
        let loader = StubLoader()
        let connection = StubConnection()
        let images = AttachmentImages(automaticAttemptLimit: 1,
                                      loader: { session, attachment in
                                          try await loader.load(session, attachment)
                                      })
        images.sessionId = "session-self-heal"
        images.attach(store: connection)
        return (images, connection, loader)
    }

    private func eventually(_ seconds: Double = 3,
                            _ condition: @escaping () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    func testAnExhaustedAttachmentLoadsAfterTheLinkComesBack() async {
        let (images, connection, loader) = makeSystem()
        // 附件 id 每次唯一：磁盘缓存按 (scope, id) 命中，复用 id 会让上一次运行留下的
        // 字节直接命中，测不到取图路径。
        let id = "at_self_heal_\(UUID().uuidString)"
        loader.script([.value(timedOut), .value(success)])

        await images.begin(id)
        guard case .failed = images.state(id) else {
            return XCTFail("an exhausted load must end in .failed, got \(images.state(id))")
        }
        XCTAssertEqual(loader.count(), 1)
        // B2：终态分类落设备日志（只发短码）。
        XCTAssertEqual(connection.failures.map(\.category), ["timed-out"])
        XCTAssertEqual(connection.failures.map(\.attempt), [1])

        // 链路回来：同一张图没有任何视图动作，应当自动再走一遍。
        images.linkEstablished()

        let loaded = await eventually { images.state(id) == .loaded }
        XCTAssertTrue(loaded, "the link coming back must load the picture, got \(images.state(id))")
        XCTAssertEqual(loader.count(), 2, "exactly one more fetch, not a request storm")
    }

    func testAManualRetryThenTheLinkDoesNotStartTwoDrivers() async {
        let (images, _connection, loader) = makeSystem()
        let id = "at_self_heal_\(UUID().uuidString)"
        loader.script([.value(.failure(DSHTransportError.notConnected)), .value(success)])

        await images.begin(id)
        guard case .failed = images.state(id) else {
            return XCTFail("an exhausted load must end in .failed, got \(images.state(id))")
        }
        let afterFirst = loader.count()

        images.retry(id)
        images.linkEstablished()

        let loaded = await eventually { images.state(id) == .loaded }
        XCTAssertTrue(loaded)
        let total = loader.count()
        XCTAssertGreaterThan(total, afterFirst)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(loader.count(), total, "no further fetch after it landed")
    }

    /// P0-1：**旧驱动还在飞**时链路恢复（不是"驱动已经结束"那种）。
    ///
    /// 复现路径：driver1 卡在网络上 → `linkEstablished()` 起 driver2 → driver1 被取消并
    /// 从 await 里回来（`.cancelled`）→ 若没有 token 守卫，它会 settle driver2 刚登记的
    /// flight、把状态改回 idle；driver2 用尽后 flight 已不在，链路恢复不再重跑。
    func testASupersededDriverCannotSettleTheNewFlightsTake() async {
        let (images, _connection, loader) = makeSystem()
        let id = "at_superseded_\(UUID().uuidString)"
        let firstGate = Gate()
        let secondGate = Gate()
        loader.script([
            .hangs(firstGate, then: timedOut),
            .hangs(secondGate, then: timedOut),
            .value(success),
        ])

        // driver1：卡在网络上（不 await begin，否则会等到第一次请求结束）。
        let first = Task { await images.begin(id) }
        let started = await eventually { loader.count() == 1 }
        XCTAssertTrue(started, "the first fetch should have started")

        // 链路恢复：起 driver2，也卡在网络上。
        images.linkEstablished()
        let second = await eventually { loader.count() == 2 }
        XCTAssertTrue(second, "a rebuilt link should start a second fetch")

        // driver1 这时才从 await 里回来（被取消 → .cancelled）。
        await firstGate.release()
        _ = await first.value
        try? await Task.sleep(for: .milliseconds(80))

        // driver2 用尽：停在失败态，flight 必须还在。
        await secondGate.release()
        let exhausted = await eventually {
            if case .failed = images.state(id) { return true }
            return false
        }
        XCTAssertTrue(exhausted, "an exhausted driver must end in .failed, got \(images.state(id))")

        // 再恢复一次：还有 flight 可重启，于是有第三次取图并成功。
        images.linkEstablished()
        let loaded = await eventually { images.state(id) == .loaded }
        XCTAssertTrue(loaded, "the stale driver must not settle the new flight, got \(images.state(id))")
        XCTAssertEqual(loader.count(), 3)
    }
}

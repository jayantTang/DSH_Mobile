import Foundation
import Testing

@testable import DSHKit

/// 可控时钟：单测要能精确控制事件的毫秒（也保证"顺序"不靠真实时间碰运气）。
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ start: Int) { value = start }
    func tick(_ delta: Int = 1) -> Int { lock.withLock { value += delta; return value } }
}

private func makeDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dsh-link-diagnostics-test-\(UUID().uuidString)")
    return url
}

@Suite("LinkDiagnostics")
struct LinkDiagnosticsTests {    @Test("环有上限，被挤掉的条数如实上报")
    func ringIsBounded() async {
        let diagnostics = LinkDiagnostics(now: { 1000 }, limit: 3)
        for index in 0..<5 {
            await diagnostics.record(kind: "app.scene", detail: ["phase": .string("background"), "i": .int(index)])
        }
        let entries = await diagnostics.entries()
        #expect(entries.count == 3)
        #expect(entries.map(\.seq) == [3, 4, 5], "留下的是最近的，序号不重置")
        #expect(await diagnostics.dropped == 2)
    }

    @Test("序号单调、at 是 ISO、ms 来自注入的时钟")
    func eventEnvelope() async {
        let clock = FakeClock(1_791_825_010_506)
        let diagnostics = LinkDiagnostics(now: { clock.tick(0) })
        let first = await diagnostics.record(kind: "app.dial", detail: ["phase": .string("start")])
        let second = await diagnostics.record(kind: "app.hello", detail: ["elapsedMs": .int(12)])
        #expect(second.seq == first.seq + 1)
        #expect(first.ms == 1_791_825_010_506)
        // `at` 一律是 **UTC** 的 ISO（与连接器流水同口径），采集侧才能直接解析比对。
        #expect(first.at == "2026-10-12T17:10:10.506Z", "ISO 口径要能被采集侧直接解析：\(first.at)")
        #expect(second.detail?["elapsedMs"] == .int(12))
    }

    @Test("落盘：一行一条 JSON，能读回来")
    func writesJsonLines() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = LinkDiagnostics(directory: directory, now: { 1_791_825_010_506 })
        await diagnostics.record(kind: "app.dial", detail: ["phase": .string("start")])
        await diagnostics.record(kind: "app.hello", detail: ["elapsedMs": .int(12)])
        let url = try #require(await diagnostics.logURL)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        let first = try decoder.decode(LinkDiagnostics.Event.self, from: Data(lines[0].utf8))
        #expect(first.kind == "app.dial")
        #expect(await diagnostics.fileErrors == 0)
    }

    @Test("超出单文件上限就滚动，只保两代")
    func rotatesOnce() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = LinkDiagnostics(directory: directory, now: { 1_791_825_010_506 }, maxBytes: 1024)
        for index in 0..<80 {
            await diagnostics.record(kind: "app.scene", detail: ["phase": .string("foreground"), "i": .int(index)])
        }
        let url = try #require(await diagnostics.logURL)
        let archived = URL(fileURLWithPath: url.path + ".1")
        #expect(FileManager.default.fileExists(atPath: archived.path), "滚走的那一代要在")
        let current = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(current < 2048, "现文件不该继续涨：\(current)")
        #expect(await diagnostics.fileErrors == 0)
    }

    @Test("跨启动：序号与已推水位活下来，环里能读回崩溃前的记录")
    func survivesRelaunch() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = LinkDiagnostics(directory: directory, now: { 1_000 })
        await first.record(kind: "app.dial", detail: ["phase": .string("start")])
        await first.record(kind: "app.hello", detail: ["elapsedMs": .int(5)])
        await first.markPushed(upTo: 1)

        let second = LinkDiagnostics(directory: directory, now: { 2_000 })
        #expect(await second.seq == 2, "序号不重置，否则增量推送会重发或漏发")
        #expect(await second.pushedUpTo == 1)
        #expect(await second.entries().count == 2, "崩溃前的两条要能读回来")
        let pending = await second.pending()
        #expect(pending.map(\.seq) == [2], "已推过的不再推")
    }

    @Test("增量导出：只给未推的，且单批不超过上限")
    func pendingRespectsBatch() async {
        let clock = FakeClock(1_000)
        let diagnostics = LinkDiagnostics(now: { clock.tick(1) }, batchBytes: 400)
        for index in 0..<20 {
            await diagnostics.record(kind: "app.scene", detail: ["phase": .string("foreground"), "i": .int(index)])
        }
        let batch = await diagnostics.pending()
        #expect(batch.count > 0 && batch.count < 20, "上限生效：\(batch.count)")
        #expect(batch.map(\.seq) == Array(1...batch.count))
        await diagnostics.markPushed(upTo: batch.count)
        let next = await diagnostics.pending()
        #expect(next.first?.seq == batch.count + 1)
        await diagnostics.markPushed(upTo: 1)
        #expect(await diagnostics.pushedUpTo == batch.count, "水位只前进不后退")
    }

    @Test("写失败不影响调用方，且只报一次")
    func writeFailureIsSwallowed() async {
        // 父路径是一个**文件**：建目录必然失败。
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-diag-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: blocker) }

        let diagnostics = LinkDiagnostics(directory: blocker.appendingPathComponent("sub"), now: { 1 })
        let event = await diagnostics.record(kind: "app.dial", detail: ["phase": .string("start")])
        #expect(event.kind == "app.dial", "落盘坏了不能让调用方拿不到事件")
        #expect(await diagnostics.entries().count == 1, "内存那份照旧可用")
        await diagnostics.record(kind: "app.hello", detail: [:])
        #expect(await diagnostics.fileErrors == 1, "第一次失败后停手，不刷屏")
    }
}

/// 等到 `predicate` 成立（回调是在 URLSession 的队列上异步记的）。
private func diagnosticsEventually(_ predicate: @Sendable () async -> Bool,
                                   timeout: TimeInterval = 2) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await predicate()
}

@Suite("LinkSocketObserver")
struct LinkSocketObserverTests {
    private func configuration() -> LinkConfiguration {
        LinkConfiguration(relayURL: URL(string: "wss://relay.test/dsh-link")!,
                          agentId: "agt_1", deviceToken: "dev_token")
    }

    @Test("系统回调 didOpen/didClose 各写一条 app.dial（传输建立与关闭）")
    func observerRecordsTransportPhases() async throws {
        let diagnostics = LinkDiagnostics(now: { 1_791_825_010_506 })
        let observer = LinkSocketObserver(diagnostics: diagnostics)
        let task = URLSession.shared.webSocketTask(with: URL(string: "wss://relay.test/link/device")!)

        observer.urlSession(URLSession.shared, webSocketTask: task, didOpenWithProtocol: "dlp")
        #expect(await diagnosticsEventually {
            await diagnostics.entries().contains { $0.kind == "app.dial" && $0.detail?["phase"] == .string("transport-up") }
        }, "didOpen 必须落成 transport-up——它就是「握手到底成没成」的唯一证据")

        observer.urlSession(URLSession.shared, webSocketTask: task,
                            didCloseWith: .goingAway, reason: Data("bye".utf8))
        #expect(await diagnosticsEventually {
            await diagnostics.entries().contains { entry in
                entry.detail?["phase"] == .string("transport-closed") && entry.detail?["code"] == .int(1001)
            }
        }, "didClose 必须带 close code")
    }

    @Test("carrier 的 session 上真的挂了观察者（漏挂就拿不到传输层结果）")
    func carrierInstallsObserver() async {
        let carrier = LinkCarrier(configuration: configuration())
        let installed = await carrier.socketObserverInstalled
        #expect(installed, "默认 init 必须把 LinkSocketObserver 挂上")
    }

    @Test("阶段事件带上「距起点多少毫秒」（契约里的 app.*.ms）")
    func noteSinceStartCarriesElapsed() async {
        let diagnostics = LinkDiagnostics(now: { 1_791_825_010_506 })
        let carrier = LinkCarrier(configuration: configuration(), diagnostics: diagnostics)
        let startedAt = Date(timeIntervalSinceNow: -0.05)
        await carrier.diagnosticsNote("app.hello", since: startedAt)
        let entry = await diagnostics.entries().first { $0.kind == "app.hello" }
        let elapsed = entry?.detail?["elapsedMs"]
        guard case .int(let ms)? = elapsed else {
            Issue.record("app.hello 必须带 elapsedMs（不叫 ms：那是信封上的时刻）")
            return
        }
        #expect(ms >= 40, "至少 40 毫秒（起点故意设在 50 毫秒前）：\(ms)")
    }
}

@Suite("LinkDiagnosticsUpload")
struct LinkDiagnosticsUploadTests {
    /// 只记账的 carrier 替身：把 `unary` 的 method/args 留下来，回答一个 ack。
    private final class RecordingCarrier: DSHCarrier, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var methods: [String] = []
        private(set) var lastArgs: Data?
        var reply: String = #"{"accepted":2,"lastSeq":2}"#

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String, args: Args, as valueType: Value.Type) async throws -> Value {
            lock.withLock { methods.append(method) }
            let encoded = try JSONEncoder().encode(args)
            lock.withLock { lastArgs = encoded }
            return try JSONDecoder().decode(Value.self, from: Data(reply.utf8))
        }

        func stream<Args: Encodable & Sendable>(endpoint: String,
                                               args: Args) async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func eventResult(_ result: JSONValue) async throws {}

        func close() async {}
    }

    @Test("推送走 _link/diagnostics，载荷带 sentAt/since/events/dropped")
    func requestShape() async throws {
        let carrier = RecordingCarrier()
        let client = DSHClient(carrier: carrier)
        let request = LinkDiagnosticsRequest(
            since: 4, sentAt: 1_791_825_010_506, dropped: 1,
            events: [LinkDiagnostics.Event(seq: 5, at: "2026-10-12T17:10:10.506Z", ms: 1_791_825_010_506,
                                          kind: "app.dial", detail: ["phase": .string("start")])],
            client: LinkDiagnosticsClient(name: "DSHMobile", version: "1.0", build: "20261013.0048"))
        let ack = try await client.pushDiagnostics(request)
        #expect(ack.accepted == 2)
        #expect(ack.lastSeq == 2)
        #expect(carrier.methods == ["_link/diagnostics"], "方法名是契约的一部分")
        let json = try #require(carrier.lastArgs)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["sentAt"] as? Int == 1_791_825_010_506)
        #expect(object["since"] as? Int == 4)
        #expect(object["dropped"] as? Int == 1)
        let events = try #require(object["events"] as? [[String: Any]])
        #expect(events.first?["kind"] as? String == "app.dial")
        let clientInfo = try #require(object["client"] as? [String: Any])
        #expect(clientInfo["build"] as? String == "20261013.0048")
    }

    @Test("连接器回 link/unsupported 时抛错，调用方据此静默跳过")
    func unsupportedThrows() async {
        let carrier = RecordingCarrier()
        carrier.reply = #"{"accepted":0}"#   // 少一个 lastSeq：解码失败 → 抛
        let client = DSHClient(carrier: carrier)
        var threw = false
        do {
            _ = try await client.pushDiagnostics(LinkDiagnosticsRequest(since: 0, sentAt: 1, dropped: 0, events: []))
        } catch {
            threw = true
        }
        #expect(threw, "形状不对要抛，而不是给一个默认 ack 让水位乱推")
    }
}

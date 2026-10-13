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
struct LinkDiagnosticsTests {
    @Test("环有上限，被挤掉的条数如实上报")
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
        let second = await diagnostics.record(kind: "app.hello", detail: ["ms": .int(12)])
        #expect(second.seq == first.seq + 1)
        #expect(first.ms == 1_791_825_010_506)
        // `at` 一律是 **UTC** 的 ISO（与连接器流水同口径），采集侧才能直接解析比对。
        #expect(first.at == "2026-10-12T17:10:10.506Z", "ISO 口径要能被采集侧直接解析：\(first.at)")
        #expect(second.detail?["ms"] == .int(12))
    }

    @Test("落盘：一行一条 JSON，能读回来")
    func writesJsonLines() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = LinkDiagnostics(directory: directory, now: { 1_791_825_010_506 })
        await diagnostics.record(kind: "app.dial", detail: ["phase": .string("start")])
        await diagnostics.record(kind: "app.hello", detail: ["ms": .int(12)])
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
        await first.record(kind: "app.hello", detail: ["ms": .int(5)])
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

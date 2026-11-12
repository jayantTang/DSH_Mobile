@testable import DSHConnectionDomain
import DSHConnectionAPI
import DSHKit
import DSHTestingSupport
import XCTest

/// 取图失败落设备日志（设计 §5 B2 / 用例 IMG-LOG-01）。
///
/// 只断言三件事：kind、字段最小集（恰好 `attachmentId` / `attempt` / `error`）、
/// 不改连接状态。诊断用临时目录，不碰用户现场。
@MainActor
final class ConnectionAttachmentDiagnosticsTests: XCTestCase {

    private func makeStore() -> (ConnectionStore, IsolatedDefaults, TempLinkDiagnostics) {
        let defaults = IsolatedDefaults(label: "connection-attachment-diagnostics")
        let diagnostics = TempLinkDiagnostics(label: "attachment-load")
        let store = ConnectionStore(defaults: defaults.defaults, diagnostics: diagnostics.value)
        return (store, defaults, diagnostics)
    }

    func testAnExhaustedAttachmentLoadLandsAsOneDiagnosticsEvent() async {
        let (store, defaults, diagnostics) = makeStore()
        defer {
            defaults.removeDomain()
            diagnostics.remove()
        }

        await store.noteAttachmentLoadFailure(id: "at_9f2", attempt: 8, category: "timed-out")

        let entries = await store.linkDiagnostics.entries()
        let last = entries.last
        XCTAssertEqual(last?.kind, "attachment.load")
        XCTAssertEqual(last?.detail?.keys.sorted(), ["attachmentId", "attempt", "error"])
        XCTAssertEqual(last?.detail?["attachmentId"], .string("at_9f2"))
        XCTAssertEqual(last?.detail?["attempt"], .int(8))
        XCTAssertEqual(last?.detail?["error"], .string("timed-out"))
        // 失败原因只是短码：不夹带文件名 / URL / 正文。
        XCTAssertEqual(store.state, .disconnected, "诊断不改连接状态")
    }

    func testTwoFailuresProduceTwoEvents() async {
        let (store, defaults, diagnostics) = makeStore()
        defer {
            defaults.removeDomain()
            diagnostics.remove()
        }

        await store.noteAttachmentLoadFailure(id: "a", attempt: 8, category: "not-connected")
        await store.noteAttachmentLoadFailure(id: "b", attempt: 8, category: "http-503")

        let kinds = await store.linkDiagnostics.entries().map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == "attachment.load" }.count, 2)
    }
}

/// 一份落在临时目录的 `LinkDiagnostics`（用例结束整个删掉）。
struct TempLinkDiagnostics {
    let url: URL

    init(label: String) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-link-diagnostics-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    var value: LinkDiagnostics { LinkDiagnostics(directory: url) }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

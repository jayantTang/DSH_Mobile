import XCTest

@testable import DSHKit

/// 链路能力的用例（spec 023 边界收敛：门面按能力给窄对象）。
///
/// 它自己不重连、不持连接，所以这里只钉两件事：**没有链路时的行为**（返回空流 / 抛错，
/// 而不是崩或永远等）与**那条 1.5 秒期限的判定**（原来写在设置页里、没有测试）。
@MainActor
final class LinkGatewayTests: XCTestCase {

    private func gateway(client: DSHClient? = nil,
                         statuses: [LinkGateway.HostStatus] = []) -> LinkGateway {
        LinkGateway(clientProvider: { client }, statusStreamProvider: {
            AsyncStream { continuation in
                for status in statuses { continuation.yield(status) }
                continuation.finish()
            }
        })
    }

    private func status(_ name: String?) -> LinkGateway.HostStatus {
        LinkGateway.HostStatus(online: true, info: name.map { .object(["name": .string($0)]) })
    }

    func testWithoutALinkNothingPretendsToBeConnected() {
        let gateway = gateway()
        XCTAssertFalse(gateway.isConnected)
        XCTAssertFalse(gateway.isRelay, "没有 client 就不该说是中转")
    }

    func testEventStreamFinishesImmediatelyWithoutALink() async throws {
        var sawEvent = false
        for try await _ in await gateway().hostEvents() { sawEvent = true }
        XCTAssertFalse(sawEvent, "没链路时订阅方应当立刻收到流结束，而不是挂着等")
    }

    func testOperationsThrowCarrierClosedWithoutALink() async {
        let gateway = gateway()
        do {
            try await gateway.answer(EventAnswer(clientId: "c", eventId: "e", outcome: .next))
            XCTFail("没有链路时回答应当抛错")
        } catch {
            XCTAssertTrue(error is DSHTransportError, "应当是传输类错误，实得 \(error)")
        }
        do {
            _ = try await gateway.sessions()
            XCTFail("没有链路时列会话应当抛错")
        } catch {
            XCTAssertTrue(error is DSHTransportError, "应当是传输类错误，实得 \(error)")
        }
        do {
            _ = try await gateway.workspaceFiles(scopeId: "s", path: ".")
            XCTFail("没有链路时列目录应当抛错")
        } catch {
            XCTAssertTrue(error is DSHTransportError, "应当是传输类错误，实得 \(error)")
        }
    }

    func testFileDownloaderNeedsALink() {
        XCTAssertNil(gateway().fileDownloader(), "没有链路就造不出下载器（调用方按「尚未连接」处理）")
    }

    // MARK: - 连接器状态的第一帧

    func testFirstHostStatusSkipsFramesWithoutInfo() async {
        // 空信息的帧（只报 online）不是设置页要的那一帧，要继续等。
        let gateway = gateway(statuses: [.init(online: true, info: nil), status("Jayant 的 MacBook")])
        let first = await gateway.firstHostStatus(deadline: .seconds(1))
        XCTAssertEqual(first?.info?["name"]?.stringValue, "Jayant 的 MacBook")
    }

    func testFirstHostStatusGivesUpAtTheDeadline() async {
        // 只有不带信息的帧：期限一到就返回 nil，不让设置页挂着。
        let started = Date()
        let gateway = gateway(statuses: [.init(online: true, info: nil)])
        let first = await gateway.firstHostStatus(deadline: .milliseconds(120))
        XCTAssertNil(first)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "期限必须生效，不能被更慢的那条分支拖住")
    }

    func testFirstHostStatusOnAnEmptyStreamIsNil() async {
        let first = await gateway().firstHostStatus(deadline: .milliseconds(50))
        XCTAssertNil(first)
    }
}

import DSHKit
import XCTest

/// 通道选择与"拒绝不等于没有结果"（spec 007 T037 的协议层部分）。
final class TranscriptSearchServiceTests: XCTestCase {

    private final class Recorder: DSHCarrier, @unchecked Sendable {
        var calls: [(method: String, args: String)] = []
        var value: HistorySearchValue?
        var error: Error?

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String, args: Args, as valueType: Value.Type
        ) async throws -> Value {
            calls.append((method, String(describing: args)))
            if let error { throw error }
            if let value = value as? Value { return value }
            throw TranscriptSearchService.Failure.localOnly
        }

        func stream<Args: Encodable & Sendable>(endpoint: String, args: Args) async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func eventResult(_ result: JSONValue) async throws {}
        func close() async {}
    }

    private func service(_ carrier: Recorder, capabilities: Set<String>) -> TranscriptSearchService {
        TranscriptSearchService(client: HostClientFactory.make(carrier: carrier),
                                address: .session(sessionId: "s1"),
                                capabilities: capabilities)
    }

    func testCapabilityChoosesTheSource() {
        let carrier = Recorder()
        XCTAssertEqual(service(carrier, capabilities: ["session-search"]).source, .connector)
        XCTAssertEqual(service(carrier, capabilities: ["git"]).source, .local)
        XCTAssertEqual(service(carrier, capabilities: []).source, .local)
    }

    func testLocalSourceRefusesInsteadOfReturningNothing() async {
        let carrier = Recorder()
        do {
            _ = try await service(carrier, capabilities: []).page(query: "needle", onlyMine: false)
            XCTFail("本地通道必须在协议层就被拒绝，不能让调用方以为'没有结果'")
        } catch {
            XCTAssertTrue(error is TranscriptSearchService.Failure)
            XCTAssertTrue(carrier.calls.isEmpty, "不该发出请求")
        }
    }

    func testConnectorSourceSendsTheRoleFilterAndCursor() async throws {
        let carrier = Recorder()
        carrier.value = HistorySearchValue(
            hits: [HistorySearchHit(seq: 12, role: "me", snippet: "a needle", highlightStart: 2, highlightLength: 6)],
            cursor: "10", hasMore: true, source: "scan"
        )
        let value = try await service(carrier, capabilities: ["session-search"])
            .page(query: "needle", onlyMine: true, cursor: "40", limit: 7)
        XCTAssertEqual(carrier.calls.count, 1)
        XCTAssertEqual(carrier.calls[0].method, "_link/sessionFind")
        XCTAssertTrue(carrier.calls[0].args.contains("\"me\""), "只看我的提问要带 roles=[me]")
        XCTAssertTrue(carrier.calls[0].args.contains("40"), "游标要原样带上")
        XCTAssertEqual(value.hits.first?.seq, 12)
        XCTAssertEqual(value.source, "scan")
    }

    func testARefusalBecomesAServiceFailureNotAnEmptyPage() async {
        struct Refused: Error {}
        let carrier = Recorder()
        carrier.error = Refused()
        do {
            _ = try await service(carrier, capabilities: ["session-search"]).page(query: "x", onlyMine: false)
            XCTFail("拒绝必须抛错")
        } catch let failure as TranscriptSearchService.Failure {
            XCTAssertTrue(failure.description.contains("Refused"), failure.description)
        } catch {
            XCTFail("错的错误类型：\(error)")
        }
    }
}

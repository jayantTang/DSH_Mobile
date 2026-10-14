import Foundation
import XCTest

@testable import DSHKit

/// `sessions()` 的回退分级（spec 022 FR-006 / T003-T004）。
///
/// 三类错误必须分开：
///   - 传输类（`link/timeout` 等）：摘要通道先退避重试（≤2 次），再败才回退；
///   - 能力类（`link/unsupported`）：直接回退，一次都不重试；
///   - 格式类（`malformedResponse`）：直接回退，一次都不重试。
/// 风暴期"一失败就换 20 倍大的通道"正是放大器，这里钉住调用序列。
final class SessionsFallbackTests: XCTestCase {

    private static let digestOK = #"{"encoding":"identity","value":{"items":[]}}"#
    private static let listOK = #"{"items":[]}"#

    private func transportError() -> any Error {
        DSHRPCFailure(code: "link/timeout", message: "boom")
    }

    func testTransportFailureRetriesDigestThenFallsBack() async throws {
        let carrier = ScriptedCarrier(results: [
            .failure(transportError()),
            .failure(transportError()),
            .failure(transportError()),
            .success(Self.listOK),
        ])
        let client = DSHClient(carrier: carrier, capabilities: [DSHClient.sessionDigestCapability])
        let list = try await client.sessions()
        XCTAssertEqual(list.items.count, 0)
        XCTAssertEqual(
            carrier.methods,
            ["_link/sessionDigest", "_link/sessionDigest", "_link/sessionDigest", "session/list"],
            "传输类失败：摘要通道重试 ≤2 次（共 3 次）再回退，不是一败就换大通道")
    }

    func testTransportFailureThenRecoveryStaysOnDigest() async throws {
        let carrier = ScriptedCarrier(results: [
            .failure(transportError()),
            .success(Self.digestOK),
        ])
        let client = DSHClient(carrier: carrier, capabilities: [DSHClient.sessionDigestCapability])
        _ = try await client.sessions()
        XCTAssertEqual(carrier.methods, ["_link/sessionDigest", "_link/sessionDigest"],
                       "重试成功就不许回退，更不能碰 session/list")
    }

    func testUnsupportedFallsBackWithoutRetry() async throws {
        let carrier = ScriptedCarrier(results: [
            .failure(DSHRPCFailure(code: "link/unsupported", message: "old connector")),
            .success(Self.listOK),
        ])
        let client = DSHClient(carrier: carrier, capabilities: [DSHClient.sessionDigestCapability])
        _ = try await client.sessions()
        XCTAssertEqual(carrier.methods, ["_link/sessionDigest", "session/list"],
                       "能力类失败重试无意义：必须直接回退（US4 AC2）")
    }

    func testFormatFailureFallsBackWithoutRetry() async throws {
        let carrier = ScriptedCarrier(results: [
            .failure(DSHTransportError.malformedResponse("bad digest frame")),
            .success(Self.listOK),
        ])
        let client = DSHClient(carrier: carrier, capabilities: [DSHClient.sessionDigestCapability])
        _ = try await client.sessions()
        XCTAssertEqual(carrier.methods, ["_link/sessionDigest", "session/list"],
                       "格式类失败重试无意义：必须直接回退")
    }

    // MARK: - 桩

    /// 按脚本逐次给结果的 carrier，记下每条被调用的方法名。
    private final class ScriptedCarrier: DSHCarrier, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<String, any Error>]
        private var recorded: [String] = []

        var methods: [String] { lock.withLock { recorded } }

        init(results: [Result<String, any Error>]) {
            self.results = results
        }

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String, args: Args, as valueType: Value.Type
        ) async throws -> Value {
            let result: Result<String, any Error> = lock.withLock {
                recorded.append(method)
                return results.isEmpty
                    ? .failure(DSHRPCFailure(code: "link/unsupported", message: "script exhausted"))
                    : results.removeFirst()
            }
            return try JSONDecoder().decode(Value.self, from: Data(result.get().utf8))
        }

        func stream<Args: Encodable & Sendable>(endpoint: String, args: Args)
            async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func eventResult(_ result: JSONValue) async throws {}
        func close() async {}
    }
}

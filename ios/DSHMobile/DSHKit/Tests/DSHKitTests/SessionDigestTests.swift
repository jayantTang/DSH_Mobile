import Foundation
import XCTest

@testable import DSHKit

/// `_link/sessionDigest` 的解码与通道选择（spec 021）。
///
/// 三件必须钉住的事：
///   1. 两种编码都能解出同一份 `SessionListValue`（`identity` 与 `deflate-raw`）；
///   2. 畸形响应（缺 `rawBytes`、越界、坏 base64、不认识的编码）**报错而不是崩**；
///   3. `sessions()` 按能力选通道，且**精简版失败必须回退**到 `session/list`（老连接器、
///      半路升级、格式对不上都不能让列表打不开）。
final class SessionDigestTests: XCTestCase {

    // 与连接器同一份数据的两种形态。压缩那份由 Node 的 `deflateRawSync` 生成（原始 DEFLATE）。
    private static let fixtureJSON = """
    {"items":[{"sessionId":"session-a","updatedAt":1791860000000,"running":true,"blank":false,"cwd":"/tmp/p","origin":"session","projections":{"asOfSeq":7,"values":{"title":"裁剪后的标题"}}},{"sessionId":"session-b","updatedAt":1791859000000,"running":false,"blank":true,"parentSessionId":"session-a","origin":"subagent","projections":{"asOfSeq":3,"values":{"title":"","subagent":{"mode":"one-shot"},"tokenUsage":{"uncachedInputTokens":1000,"outputTokens":234}}}}]}
    """

    private static let fixtureBase64 = """
    fZAxT8MwEIX/y82uSihQ6o2xE0NhQgxOcm1NE9vEZxgiD0hIiAUxIiYEG/+rQP8Fl7ZQJAKe7Od3T9+7GjRh6UGe1ODRe23NMAf5de8oEBBcrgjzAwKZ9AfJ/t7W6giogjHaTEBSFVBAWigzAzlWhedXdtkEdal0XccpttITbTbRLLnKnmFG/GCAGpQ/HI/wHGRfwIUqAi5V0lQgj328XM1vX+f3d++P129PN4vnB4gxinbstAV7d/ALe0265l6VcKpCQ6M/drFpEVI1YeM/NXptNdj/PcpyafNGtQY7fmoJogCyMzTHni2NIZhMZVPMh8YFOmq+OC5Z1rCBfmjbvR3eRzyNnw==
    """

    private static let uncompressedBytes = 467

    // MARK: - 解码

    func testIdentityEnvelopeDecodesTheSameList() throws {
        let envelope = try decode(#"{"encoding":"identity","value":\#(Self.fixtureJSON)}"#)
        let list = try decodeSessionDigest(envelope)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[0].sessionId, "session-a")
        XCTAssertEqual(list.items[0].displayTitle, "裁剪后的标题")
        XCTAssertEqual(list.items[1].address, .subagent(parentSessionId: "session-a",
                                                       childSessionId: "session-b", mode: .oneShot))
    }

    func testDeflateRawEnvelopeDecodesTheSameList() throws {
        let envelope = try decode(#"{"encoding":"deflate-raw","rawBytes":\#(Self.uncompressedBytes),"value":"\#(Self.fixtureBase64)"}"#)
        let list = try decodeSessionDigest(envelope)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[0].projections?.asOfSeq, 7)
        XCTAssertEqual(list.items[1].projections?.values?.tokenUsage?.totalTokens, 1234)
        XCTAssertEqual(list.items[0].displayTitle, "裁剪后的标题")
    }

    /// 两条路径必须解出同一份东西：这是"压缩无损"的机器判据。
    func testBothEncodingsAgree() throws {
        let plain = try decodeSessionDigest(try decode(#"{"encoding":"identity","value":\#(Self.fixtureJSON)}"#))
        let packed = try decodeSessionDigest(try decode(
            #"{"encoding":"deflate-raw","rawBytes":\#(Self.uncompressedBytes),"value":"\#(Self.fixtureBase64)"}"#))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(plain), try encoder.encode(packed),
                       "两条路径必须解出同一份东西")
    }

    // MARK: - 畸形响应

    func testMissingRawBytesIsReported() throws {
        let envelope = try decode(#"{"encoding":"deflate-raw","value":"\#(Self.fixtureBase64)"}"#)
        XCTAssertThrowsError(try decodeSessionDigest(envelope)) { error in
            XCTAssertEqual(error as? SessionDigestError, .missingRawBytes)
        }
    }

    func testOutOfRangeRawBytesIsReportedInsteadOfAllocating() throws {
        let envelope = try decode(#"{"encoding":"deflate-raw","rawBytes":999999999,"value":"\#(Self.fixtureBase64)"}"#)
        XCTAssertThrowsError(try decodeSessionDigest(envelope)) { error in
            XCTAssertEqual(error as? SessionDigestError, .rawBytesOutOfRange(999_999_999))
        }
    }

    func testBadBase64AndUnknownEncodingAreReported() throws {
        let badBase64 = try decode(#"{"encoding":"deflate-raw","rawBytes":10,"value":"!!!!not base64!!!!"}"#)
        XCTAssertThrowsError(try decodeSessionDigest(badBase64)) { error in
            XCTAssertEqual(error as? SessionDigestError, .badBase64)
        }
        let unknown = try decode(#"{"encoding":"zstd","rawBytes":10,"value":"AAAA"}"#)
        XCTAssertThrowsError(try decodeSessionDigest(unknown)) { error in
            XCTAssertEqual(error as? SessionDigestError, .unsupportedEncoding("zstd"))
        }
    }

    /// `rawBytes` 与实际解出来的长度不符 → 按解不开报（不许拿半截数据去解码）。
    func testWrongRawBytesLengthIsReported() throws {
        let envelope = try decode(#"{"encoding":"deflate-raw","rawBytes":\#(Self.uncompressedBytes + 8),"value":"\#(Self.fixtureBase64)"}"#)
        XCTAssertThrowsError(try decodeSessionDigest(envelope)) { error in
            XCTAssertEqual(error as? SessionDigestError, .inflateFailed)
        }
    }

    // MARK: - 通道选择

    func testSessionsUsesDigestWhenTheConnectorDeclaresTheCapability() async throws {
        let carrier = Recorder()
        carrier["_link/sessionDigest"] = #"{"encoding":"identity","value":\#(Self.fixtureJSON)}"#
        carrier["session/list"] = #"{"items":[]}"#
        let client = DSHClient(carrier: carrier, capabilities: [DSHClient.sessionDigestCapability])
        let list = try await client.sessions()
        XCTAssertEqual(list.items.count, 2, "该走精简版")
        XCTAssertEqual(carrier.methods, ["_link/sessionDigest"])
        XCTAssertTrue(carrier.args(for: "_link/sessionDigest")?.contains("\"deflate-raw\"") ?? false,
                      "要显式要求压缩，否则省不下字节")
    }

    func testSessionsFallsBackWhenTheDigestCallFails() async throws {
        let carrier = Recorder()
        carrier["session/list"] = #"{"items":[]}"#
        // 没给 `_link/sessionDigest` 的桩 → 那条调用会抛 `DSHRPCFailure`
        let client = DSHClient(carrier: carrier, capabilities: [DSHClient.sessionDigestCapability])
        let list = try await client.sessions()
        XCTAssertEqual(list.items.count, 0)
        XCTAssertEqual(carrier.methods, ["_link/sessionDigest", "session/list"],
                       "精简版失败要落到老方法上，而不是让列表打不开")
    }

    func testSessionsUsesTheLegacyPathWithoutTheCapability() async throws {
        let carrier = Recorder()
        carrier["*"] = #"{"items":[]}"#
        let client = DSHClient(carrier: carrier)
        _ = try await client.sessions()
        XCTAssertEqual(carrier.methods, ["session/list"], "没有能力声明就该走老路径（老连接器）")
    }

    // MARK: - 工具

    private func decode(_ json: String) throws -> SessionDigestEnvelope {
        try JSONDecoder().decode(SessionDigestEnvelope.self, from: Data(json.utf8))
    }

    private final class Recorder: DSHCarrier, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(String, String)] = []
        private var payloads: [String: String] = [:]


        var methods: [String] { lock.withLock { recorded.map(\.0) } }
        func args(for method: String) -> String? { lock.withLock { recorded.first { $0.0 == method }?.1 } }
        func setPayload(_ json: String, for method: String) { lock.withLock { payloads[method] = json } }

        subscript(key: String) -> String? {
            get { lock.withLock { payloads[key] } }
            set { lock.withLock { payloads[key] = newValue } }
        }

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String, args: Args, as valueType: Value.Type
        ) async throws -> Value {
            let text = String(data: try JSONEncoder().encode(args), encoding: .utf8) ?? ""
            lock.withLock { recorded.append((method, text)) }
            guard let json = self[method] ?? self["*"] else {
                throw DSHRPCFailure(code: "link/unsupported", message: "no payload for \(method)")
            }
            return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        }

        func stream<Args: Encodable & Sendable>(endpoint: String, args: Args)
            async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func eventResult(_ result: JSONValue) async throws {}
        func close() async {}
    }
}

import Foundation
import XCTest

@testable import DSHKit

/// `_link/sessionWindow` 的应用层压缩（能力 `history-compression`）。
///
/// 钉住四件事：
///   1. 未压缩的纯 JSON 仍按原样解（老连接器）；
///   2. `identity` / `deflate-raw` 两种信封都能解出同一个 `HistoryWindowValue`；
///   3. 畸形信封（缺 rawBytes、越界、坏 base64）报错而不是崩；
///   4. 只有连接器声明能力时才带 `encoding`，取页器两条路径都不漏。
final class HistoryWindowCompressionTests: XCTestCase {

    private static let plainJSON = """
    {"records":[{"event":{"type":"user/message","seq":1,"time":1700000000000,"data":{"text":"hello"}}},{"event":{"type":"assistant/message","seq":2,"time":1700000000001,"data":{"text":"world"}}}],"startSeq":1,"endSeq":2,"hasMore":true}
    """

    /// 由 Node 的 `deflateRawSync` 生成（与连接器 `history/compress.js` 同一编码）。
    private static let deflateBase64 = """
    bc7BCsIwEATQf5lzQONFyD946lE8LGaxhbTR3a1WSv7dKAXBOtdhHjND+JwlKsJxBt95MIQZ9rwyAkZl2fSsSheGg/INwTtY19fW77ffOEQy+kx5qgRaTimjlOLWLKl2ajTYr737Z/uV/ciS4ts+1Z2RWLMc4yE2i9OSHrJUymTk8gI=
    """
    private static let rawBytes = 231

    // MARK: - 解码

    func testPlainWindowStillDecodes() throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(Self.plainJSON.utf8))
        let value = try HistoryWindowWire.decode(raw)
        XCTAssertEqual(value.records.count, 2)
        XCTAssertEqual(value.startSeq, 1)
        XCTAssertEqual(value.hasMore, true)
    }

    func testIdentityEnvelopeDecodes() throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"encoding":"identity","value":\#(Self.plainJSON)}"#.utf8))
        let value = try HistoryWindowWire.decode(raw)
        XCTAssertEqual(value.records.map(\.event.seq), [1, 2])
    }

    func testDeflateRawEnvelopeDecodes() throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"encoding":"deflate-raw","rawBytes":\#(Self.rawBytes),"value":"\#(Self.deflateBase64)"}"#.utf8))
        let value = try HistoryWindowWire.decode(raw)
        XCTAssertEqual(value.records.count, 2)
        XCTAssertEqual(value.records[1].event.type, "assistant/message")
    }

    func testMalformedEnvelopesThrow() throws {
        func decode(_ json: String) throws -> HistoryWindowValue {
            let raw = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            return try HistoryWindowWire.decode(raw)
        }
        XCTAssertThrowsError(try decode(#"{"encoding":"deflate-raw","value":"\#(Self.deflateBase64)"}"#))
        XCTAssertThrowsError(try decode(#"{"encoding":"deflate-raw","rawBytes":999999999,"value":"\#(Self.deflateBase64)"}"#))
        XCTAssertThrowsError(try decode(#"{"encoding":"deflate-raw","rawBytes":10,"value":"!!!!not base64!!!!"}"#))
        XCTAssertThrowsError(try decode(#"{"encoding":"br","value":"x"}"#))
    }

    // MARK: - 请求侧

    func testEncodingOnlyRequestedWithTheCapability() {
        let plain = HostClientFactory.make(carrier: EmptyCarrier(), capabilities: ["history-window"])
        XCTAssertNil(plain.historyWindowEncoding)
        let compressed = HostClientFactory.make(carrier: EmptyCarrier(),
                                   capabilities: ["history-window", HistoryWindowWire.compressionCapability])
        XCTAssertEqual(compressed.historyWindowEncoding, HistoryWindowRequest.deflateRaw)
    }

    func testClientSendsEncodingAndDecodesTheEnvelope() async throws {
        let carrier = Recorder()
        carrier["_link/sessionWindow"] = #"{"encoding":"deflate-raw","rawBytes":\#(Self.rawBytes),"value":"\#(Self.deflateBase64)"}"#
        let client = HostClientFactory.make(carrier: carrier,
                               capabilities: [HistoryWindowWire.compressionCapability])
        let value = try await client.historyWindow(HistoryWindowRequest(
            address: .session(sessionId: "session-a"), before: 3,
            encoding: client.historyWindowEncoding))
        XCTAssertEqual(value.records.count, 2)
        XCTAssertTrue(carrier.args(for: "_link/sessionWindow")?.contains("deflate-raw") ?? false,
                      "声明了能力就必须要求压缩")
    }

    func testTranscriptPageFetcherRequestsCompressionOnTheExactChannel() async throws {
        let carrier = Recorder()
        carrier["_link/sessionWindow"] = #"{"encoding":"deflate-raw","rawBytes":\#(Self.rawBytes),"value":"\#(Self.deflateBase64)"}"#
        let client = HostClientFactory.make(carrier: carrier,
                               capabilities: ["history-window", HistoryWindowWire.compressionCapability])
        let fetcher = TranscriptPageFetcher(
            client: client, address: .session(sessionId: "session-a"), throughSeq: 99,
            capabilities: ["history-window", HistoryWindowWire.compressionCapability],
            pageSize: 50)
        _ = try await fetcher.page(before: 3)
        XCTAssertTrue(carrier.args(for: "_link/sessionWindow")?.contains("deflate-raw") ?? false)
    }

    // MARK: - 工具

    private final class EmptyCarrier: DSHCarrier, @unchecked Sendable {
        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String, args: Args, as valueType: Value.Type
        ) async throws -> Value {
            throw DSHRPCFailure(code: "link/unsupported", message: "not used")
        }
        func stream<Args: Encodable & Sendable>(endpoint: String, args: Args)
            async -> AsyncThrowingStream<JSONValue, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func eventResult(_ result: JSONValue) async throws {}
        func close() async {}
    }

    private final class Recorder: DSHCarrier, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(String, String)] = []
        private var payloads: [String: String] = [:]

        var methods: [String] { lock.withLock { recorded.map(\.0) } }
        func args(for method: String) -> String? {
            lock.withLock { recorded.first { $0.0 == method }?.1 }
        }
        subscript(key: String) -> String? {
            get { lock.withLock { payloads[key] } }
            set { lock.withLock { payloads[key] = newValue } }
        }

        func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
            method: String, args: Args, as valueType: Value.Type
        ) async throws -> Value {
            let text = String(data: try JSONEncoder().encode(args), encoding: .utf8) ?? ""
            lock.withLock { recorded.append((method, text)) }
            guard let json = self[method] else {
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

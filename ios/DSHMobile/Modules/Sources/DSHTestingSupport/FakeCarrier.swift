import DSHKit
import Foundation

/// 假传输层：按方法名路由到可编程响应，记录全部调用。
/// 供 Chat/Sessions 等 DomainTests 验证"发了什么 RPC、顺序如何"。
public final class FakeCarrier: DSHCarrier, @unchecked Sendable {
    public struct RecordedCall: Sendable, Equatable {
        public let method: String
        public init(method: String) { self.method = method }
    }

    public private(set) var calls: [RecordedCall] = []
    public var unaryResponses: [String: Result<JSONValue, Error>] = [:]
    public var streamResponses: [String: [JSONValue]] = [:]

    public init() {}

    public func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String, args: Args, as valueType: Value.Type
    ) async throws -> Value {
        calls.append(RecordedCall(method: method))
        guard let response = unaryResponses[method] else {
            throw NSError(domain: "FakeCarrier", code: 1, userInfo: [NSLocalizedDescriptionKey: "no stub for \(method)"])
        }
        switch response {
        case .success(let value):
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(Value.self, from: data)
        case .failure(let error):
            throw error
        }
    }

    public func stream<Args: Encodable & Sendable>(
        endpoint: String, args: Args
    ) async -> AsyncThrowingStream<JSONValue, any Error> {
        calls.append(RecordedCall(method: endpoint))
        let values = streamResponses[endpoint] ?? []
        return AsyncThrowingStream { continuation in
            for v in values { continuation.yield(v) }
            continuation.finish()
        }
    }

    public func eventResult(_ result: JSONValue) async throws {}

    public func close() async {}
}

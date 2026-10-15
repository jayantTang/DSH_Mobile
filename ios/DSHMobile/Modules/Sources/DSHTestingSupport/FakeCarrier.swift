import DSHKit
import Foundation

/// 假传输层：按方法名路由到可编程响应，记录全部调用（方法名 + 编码后的参数）。
/// 供 Chat/Sessions 等 DomainTests 验证"发了什么 RPC、带了什么参数、顺序如何"。
public final class FakeCarrier: DSHCarrier, @unchecked Sendable {
    public struct RecordedCall: Sendable, Equatable {
        public let method: String
        /// 参数按 wire 上的形状编成 JSON（`RequestArgs` 会包一层 `request`）。
        ///
        /// 记的是**编码结果**而不是原始值：被测代码写到线上的那一层才是契约，
        /// 泛型值本身也没法跨方法比较，看不出信封有没有包错。
        public let args: JSONValue?

        public init(method: String, args: JSONValue? = nil) {
            self.method = method
            self.args = args
        }
    }

    public private(set) var calls: [RecordedCall] = []
    public var unaryResponses: [String: Result<JSONValue, Error>] = [:]
    public var streamResponses: [String: [JSONValue]] = [:]

    public init() {}

    /// 按方法名筛记录：调用顺序里掺着后台任务，按下标取不稳。
    public func calls(to method: String) -> [RecordedCall] {
        calls.filter { $0.method == method }
    }

    /// 把一个 Encodable 参数编成 `JSONValue`；编不出来记 nil，不抛。
    static func encoded<Args: Encodable>(_ args: Args) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(args) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String, args: Args, as valueType: Value.Type
    ) async throws -> Value {
        calls.append(RecordedCall(method: method, args: Self.encoded(args)))
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
        calls.append(RecordedCall(method: endpoint, args: Self.encoded(args)))
        let values = streamResponses[endpoint] ?? []
        return AsyncThrowingStream { continuation in
            for v in values { continuation.yield(v) }
            continuation.finish()
        }
    }

    public func eventResult(_ result: JSONValue) async throws {}

    public func close() async {}
}

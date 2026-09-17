import Foundation

/// The `result` union carried by every DSH RPC response.
///
/// Decoded in one pass so the hot path never materializes an intermediate
/// dynamic value: the success payload goes straight into `T`.
public enum DSHRPCResult<Value: Decodable & Sendable>: Sendable {
    case ok(Value)
    case failure(DSHRPCFailure)
}

extension DSHRPCResult: Decodable {
    private enum CodingKeys: String, CodingKey {
        case ok, value, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        if ok {
            if Value.self == DSHEmpty.self,
               !container.contains(.value) || (try? container.decodeNil(forKey: .value)) == true {
                self = .ok(DSHEmpty() as! Value)
                return
            }
            self = .ok(try container.decode(Value.self, forKey: .value))
        } else {
            self = .failure(try container.decode(DSHRPCFailure.self, forKey: .error))
        }
    }
}

extension DSHRPCResult {
    /// The success payload, or the DSH failure raised as a Swift error.
    public func unwrapped() throws -> Value {
        switch self {
        case .ok(let value): return value
        case .failure(let failure): throw failure
        }
    }
}

/// Placeholder for endpoints whose success payload is absent or `null`.
public struct DSHEmpty: Codable, Sendable, Hashable {
    public init() {}
    public init(from decoder: any Decoder) throws {
        // DSH sends either an absent `value`, `null`, `{}`, or `true` for
        // endpoints with no meaningful result; accept all of them.
        _ = try? decoder.singleValueContainer()
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([String: String]())
    }
}

/// The response envelope for one unary RPC.
struct RPCResponseEnvelope<Value: Decodable & Sendable>: Decodable {
    let rpcId: String
    let result: DSHRPCResult<Value>

    private enum CodingKeys: String, CodingKey {
        case rpcId, result
    }
}

/// The request envelope for one unary RPC.
///
/// Shape: `{"type":"client-request","rpcId":…,"method":…,"payload":{"args":{…}}}`
/// where `args` is an object of *named* fields matching the endpoint descriptor.
struct RPCRequestEnvelope<Args: Encodable & Sendable>: Encodable {
    let type = "client-request"
    let rpcId: String
    let method: String
    let payload: Payload

    struct Payload: Encodable {
        let args: Args
    }
}

/// Arguments for endpoints that take no fields at all.
struct EmptyArgs: Encodable, Sendable {
    func encode(to encoder: any Encoder) throws {
        // A keyed container that never receives a key encodes as `{}`, which
        // is exactly what DSH's descriptor validation expects.
        let container = encoder.container(keyedBy: EmptyKeys.self)
        _ = container
    }
    private enum EmptyKeys: String, CodingKey { case unused }
}

/// Arguments for endpoints whose descriptor declares one field named `request`.
struct RequestArgs<Request: Encodable & Sendable>: Encodable {
    let request: Request
}

/// Arguments for `session/list`, whose single field is named `_request`.
struct UnderscoreRequestArgs<Request: Encodable & Sendable>: Encodable {
    let _request: Request

    private enum CodingKeys: String, CodingKey {
        case _request
    }
}

/// Arguments for endpoints whose descriptor declares a field named `ref`.
struct RefArgs<Ref: Encodable & Sendable>: Encodable {
    let ref: Ref
}

/// Mints correlation ids for RPC calls and logical streams.
///
/// DSH echoes `rpcId` back and the carrier asserts equality, so ids only need
/// to be unique within one connection — a monotonic counter is both cheaper
/// and easier to read in logs than a UUID.
actor CorrelationIds {
    private var counter: UInt64 = 0
    private let prefix: String

    init(prefix: String = "c") {
        self.prefix = prefix
    }

    func next() -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }
}

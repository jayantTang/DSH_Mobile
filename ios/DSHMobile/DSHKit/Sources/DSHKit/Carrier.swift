import Foundation

/// The transport contract the `DSHClient` speaks.
///
/// Two carriers implement it and are interchangeable above this line:
///
/// - `HTTPCarrier` talks to DSH directly over HTTP plus the mux WebSocket.
///   This is the fast path on the same LAN, and the only path in development.
/// - `LinkCarrier` tunnels the identical logical protocol through a single
///   relay WebSocket, which is what makes a machine without a public IP
///   reachable from a phone on cellular.
public protocol DSHCarrier: Sendable {
    /// Performs one unary RPC and decodes its success payload.
    ///
    /// - Parameters:
    ///   - method: the DSH endpoint name, e.g. `session/list`.
    ///   - args: a value whose encoded form is the endpoint's named-field
    ///     argument object.
    ///   - valueType: the expected success payload type.
    func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String,
        args: Args,
        as valueType: Value.Type
    ) async throws -> Value

    /// Opens one logical stream on the mux.
    func stream<Args: Encodable & Sendable>(
        endpoint: String,
        args: Args
    ) async -> AsyncThrowingStream<JSONValue, any Error>

    /// Answers a host `waterfall` event through `$events/result`.
    func eventResult(_ result: JSONValue) async throws

    /// Fails the carrier and releases every resource it owns.
    func close() async
}

extension DSHCarrier {
    /// Performs a unary RPC for an endpoint that takes no arguments.
    public func unary<Value: Decodable & Sendable>(
        method: String,
        as valueType: Value.Type
    ) async throws -> Value {
        try await unary(method: method, args: EmptyArgs(), as: valueType)
    }

    /// Performs a unary RPC whose result the caller discards.
    public func unary<Args: Encodable & Sendable>(method: String, args: Args) async throws {
        _ = try await unary(method: method, args: args, as: DSHEmpty.self)
    }

    /// Performs an argument-less unary RPC whose result the caller discards.
    public func unary(method: String) async throws {
        _ = try await unary(method: method, args: EmptyArgs(), as: DSHEmpty.self)
    }
}

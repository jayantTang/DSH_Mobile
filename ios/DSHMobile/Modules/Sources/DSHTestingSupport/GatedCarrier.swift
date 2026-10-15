import DSHKit
import Foundation

/// A `FakeCarrier` that can be parked inside a chosen call.
///
/// `FakeCarrier` answers every method the moment it is asked, which is what
/// makes it fast and deterministic — and also why an intermediate state such as
/// `SettingsModel.SaveState.saving` cannot be observed through it. A test that
/// needs that state installs ``hold`` and awaits `TestGate.wait()` there.
///
/// Everything else delegates to ``inner``, so the call log and the programmed
/// answers are the same objects a plain `FakeCarrier` would expose.
public final class GatedCarrier: DSHCarrier, @unchecked Sendable {
    /// Where the answers and the call log live.
    public let inner: FakeCarrier
    /// Awaited before a call is forwarded, for whichever method names it cares
    /// about (`nil` means "never hold", i.e. plain `FakeCarrier` behaviour).
    public var hold: (@Sendable (String) async -> Void)?

    public init(_ inner: FakeCarrier = FakeCarrier()) {
        self.inner = inner
    }

    public func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String, args: Args, as valueType: Value.Type
    ) async throws -> Value {
        if let hold { await hold(method) }
        return try await inner.unary(method: method, args: args, as: valueType)
    }

    public func stream<Args: Encodable & Sendable>(
        endpoint: String, args: Args
    ) async -> AsyncThrowingStream<JSONValue, any Error> {
        if let hold { await hold(endpoint) }
        return await inner.stream(endpoint: endpoint, args: args)
    }

    public func eventResult(_ result: JSONValue) async throws {
        try await inner.eventResult(result)
    }

    public func close() async {
        await inner.close()
    }
}

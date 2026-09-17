import Foundation

/// What the computer's connector says it can do.
///
/// The connector and the app are deployed separately, so the app asks instead
/// of assuming. The question rides the link as a reserved method the connector
/// answers itself — the HTTP status route only exists on the direct path, and
/// the direct path is not what users run.
public struct LinkHandshake: Decodable, Sendable {
    public let serverVersion: String?
    public let capabilities: [String]
    public let protocolVersion: Int?
    public let agentId: String?
    public let name: String?

    private enum CodingKeys: String, CodingKey {
        case serverVersion, capabilities, protocolVersion, agentId, name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverVersion = try? container.decodeIfPresent(String.self, forKey: .serverVersion)
        // A connector that reports nothing is treated as having nothing, which
        // is what makes the entry points hide rather than fail.
        capabilities = (try? container.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
        protocolVersion = try? container.decodeIfPresent(Int.self, forKey: .protocolVersion)
        agentId = try? container.decodeIfPresent(String.self, forKey: .agentId)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
    }

    public init(capabilities: [String], serverVersion: String? = nil, protocolVersion: Int? = nil) {
        self.capabilities = capabilities
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.agentId = nil
        self.name = nil
    }

    public func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    /// Names used on the wire.
    public enum Capability {
        public static let fileTransfer = "file-transfer"
        public static let events = "events"
        public static let sessionStreams = "session-streams"
        public static let pairCode = "pair-code"
    }
}

/// Asks the connector what it is.
public struct LinkHandshakeRequest: Encodable, Sendable {
    public init() {}
}

extension DSHClient {
    /// Fetches the connector's capabilities over the link.
    public func linkHandshake() async throws -> LinkHandshake {
        try await carrier.unary(
            method: "_link/hello",
            args: LinkHandshakeRequest(),
            as: LinkHandshake.self
        )
    }
}

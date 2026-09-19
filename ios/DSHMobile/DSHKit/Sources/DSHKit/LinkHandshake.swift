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

/// Asks the connector what it is, and says what is asking.
///
/// The client half used to be empty. That left the computer — and the relay
/// behind it — knowing only what a phone reported when it *paired*, so "is that
/// phone on the current build?" was unanswerable: the stored version could be
/// days old and nothing in the per-connection traffic contradicted it. These
/// three fields ride the one call that already happens once per connection.
///
/// All optional: an older client sends nothing, and the connector records
/// nothing rather than inventing a version.
public struct LinkHandshakeRequest: Encodable, Sendable {
    /// The app's name as the device shows it, e.g. `DSHMobile`.
    public let clientName: String?
    /// Marketing version, e.g. `1.0`.
    public let clientVersion: String?
    /// `CFBundleVersion` — the stamp that tells two builds of 1.0 apart.
    public let clientBuild: String?

    public init(clientName: String? = nil, clientVersion: String? = nil, clientBuild: String? = nil) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.clientBuild = clientBuild
    }
}

extension DSHClient {
    /// Fetches the connector's capabilities over the link.
    public func linkHandshake(
        client: LinkHandshakeRequest = LinkHandshakeRequest()
    ) async throws -> LinkHandshake {
        try await carrier.unary(
            method: "_link/hello",
            args: client,
            as: LinkHandshake.self
        )
    }
}

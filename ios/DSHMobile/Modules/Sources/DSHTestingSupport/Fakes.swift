import DSHConnectionAPI
import Foundation

/// 假连接服务：LinkService 的可编程实现，供各单元 DomainTests 注入。
@MainActor
public final class FakeLinkService: LinkService {
    public var profiles: [ConnectionProfile]
    public var activeProfile: ConnectionProfile?
    public var state: ConnectionState
    public var lastError: String?
    public var capabilities: Set<String>
    public var connectorVersion: String?

    public init(
        profiles: [ConnectionProfile] = [],
        state: ConnectionState = .disconnected,
        capabilities: Set<String> = []
    ) {
        self.profiles = profiles
        self.state = state
        self.capabilities = capabilities
    }

    public func supports(_ capability: String) -> Bool { capabilities.contains(capability) }
}

/// 常用夹具。
public enum TestFixtures {
    /// 一个中转形态的连接档案。
    public static func relayProfile(name: String = "Test Mac") -> ConnectionProfile {
        ConnectionProfile(
            name: name,
            transport: .relay(relayURL: URL(string: "https://relay.example.com/dsh-link")!, agentId: "agt_test")
        )
    }

    /// 一个直连形态的连接档案。
    public static func directProfile(name: String = "Local Mac") -> ConnectionProfile {
        ConnectionProfile(
            name: name,
            transport: .direct(baseURL: URL(string: "http://127.0.0.1:19387")!, cookieName: "dsh-auth-test")
        )
    }
}

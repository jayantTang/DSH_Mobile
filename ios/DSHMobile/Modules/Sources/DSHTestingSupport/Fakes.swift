import DSHConnectionAPI
import DSHKit
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

    public var hostHome: String?
    public var activeBaseURL: URL? {
        guard let t = activeProfile?.transport else { return nil }
        switch t {
        case .direct(let baseURL, _): return baseURL
        case .relay(let relayURL, _): return relayURL
        }
    }
    public var scopeId: String? { activeProfile?.id.uuidString }
    public var client: DSHClient? { nil }
    public var link: LinkGateway { fatalError("FakeLinkService.link: 测试不应走到这里") }

    public func supports(_ capability: String) -> Bool { capabilities.contains(capability) }
    public func uploadFile(fileURL: URL, name: String, sessionId: String) async throws -> StagedFile {
        throw NSError(domain: "FakeLinkService", code: 2, userInfo: [NSLocalizedDescriptionKey: "uploadFile not stubbed"])
    }
    public func fileTransferTarget() throws -> (relayURL: URL, deviceToken: String) {
        throw NSError(domain: "FakeLinkService", code: 2, userInfo: [NSLocalizedDescriptionKey: "no transfer target in fake"])
    }
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

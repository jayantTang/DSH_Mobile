import Foundation

/// One saved way to reach a DSH host.
public struct ConnectionProfile: Codable, Identifiable, Sendable, Hashable {
    /// How frames reach the host.
    public enum Transport: Codable, Sendable, Hashable {
        /// Straight to a DSH host on the same network. Fastest path: no relay
        /// hop, no server bandwidth, full WebSocket streaming.
        case direct(baseURL: URL, cookieName: String)
        /// Through the relay, which is what works from cellular.
        case relay(relayURL: URL, agentId: String)
    }

    public var id: UUID
    public var name: String
    public var transport: Transport
    /// The host's home directory, learned on first connect; used to shorten
    /// displayed paths the same way the desktop client does.
    public var hostHome: String?
    public var relayName: String?
    public var lastConnectedAt: Date?

    /// The version that made the user dismiss the "connector is out of date"
    /// notice on this profile, so it is not shown again for the same version.
    ///
    /// Optional on purpose: the synthesized `Codable` decoding treats a missing
    /// optional key as `nil`, so profiles already on disk keep decoding (a
    /// non-optional field here would fail the whole array and lose the user's
    /// connections). Storing the version — rather than a bare `Bool` — is what
    /// makes the notice come back when the app's baseline moves past it.
    public var outdatedNoticeDismissedFor: String?

    public init(
        id: UUID = UUID(),
        name: String,
        transport: Transport,
        hostHome: String? = nil,
        relayName: String? = nil,
        lastConnectedAt: Date? = nil,
        outdatedNoticeDismissedFor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.hostHome = hostHome
        self.relayName = relayName
        self.lastConnectedAt = lastConnectedAt
        self.outdatedNoticeDismissedFor = outdatedNoticeDismissedFor
    }

    /// Keychain account holding this profile's bearer secret.
    public var secretAccount: String { "profile-\(id.uuidString)" }

    /// Whether this path avoids the relay entirely.
    public var isDirect: Bool {
        if case .direct = transport { return true }
        return false
    }

    /// A short description for the connection list.
    public var subtitle: String {
        switch transport {
        case .direct(let baseURL, _):
            return baseURL.absoluteString
        case .relay(let relayURL, _):
            // The whole line is one key (`%@ · 中转`), not string concatenation:
            // this value is painted on the settings screen as「主机地址」, and an
            // English phone used to show the Chinese「中转」here.
            return String(localized: "\(relayURL.host() ?? relayURL.absoluteString) · 中转")
        }
    }
}

/// 连接状态（原 ConnectionStore.State，抽到协议层供 LinkService 与假实现共用）。
/// What the UI needs to know about the current link.
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting(String)
    case connected(hostHome: String?)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Whether this is a link that dropped after working, rather than a
    /// connection that was never established.
    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
}

public extension ConnectionProfile {
    /// 落盘的连接档案（UserDefaults 读取，纯数据解码）。
    ///
    /// 026：从 ConnectionStore 下沉——信箱等单元只需要读档案，不该依赖连接实现。
    static func persistedProfiles(defaults: UserDefaults = .standard) -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: "dsh.connection.profiles") else { return [] }
        return (try? JSONDecoder().decode([ConnectionProfile].self, from: data)) ?? []
    }
}

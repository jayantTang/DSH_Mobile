import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A phone paired to the same computer, as the relay knows it.
///
/// This is *not* part of the DSH protocol: devices live on the relay, which is
/// the only party that can tell one paired phone from another. The DSH host has
/// no idea it is being reached through a relay at all.
public struct RelayDevice: Sendable, Hashable, Identifiable, Decodable {
    public let deviceId: String
    public let name: String?
    public let model: String?
    public let createdAt: Date?
    public let lastSeenAt: Date?
    public let revoked: Bool
    /// Whether this is the phone making the request.
    public var isCurrent: Bool = false

    public var id: String { deviceId }

    /// What to show as the device's title.
    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "未命名设备" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, name, model, createdAt, lastSeenAt, revoked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        // The relay reports milliseconds since the epoch.
        createdAt = Self.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .createdAt))
        lastSeenAt = Self.date(fromMilliseconds: try? container.decodeIfPresent(Int.self, forKey: .lastSeenAt))
        revoked = (try? container.decodeIfPresent(Bool.self, forKey: .revoked)) ?? false
    }

    public init(
        deviceId: String,
        name: String? = nil,
        model: String? = nil,
        createdAt: Date? = nil,
        lastSeenAt: Date? = nil,
        revoked: Bool = false,
        isCurrent: Bool = false
    ) {
        self.deviceId = deviceId
        self.name = name
        self.model = model
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revoked = revoked
        self.isCurrent = isCurrent
    }

    static func date(fromMilliseconds value: Int??) -> Date? {
        guard let milliseconds = value ?? nil, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

/// One answer to `GET /devices`.
public struct RelayDeviceList: Sendable, Hashable {
    public let devices: [RelayDevice]
    public let currentDeviceId: String?

    public init(devices: [RelayDevice], currentDeviceId: String?) {
        self.currentDeviceId = currentDeviceId
        self.devices = devices.map { device in
            var copy = device
            copy.isCurrent = device.deviceId == currentDeviceId
            return copy
        }
    }

    /// The devices worth showing, newest pairing first.
    public var active: [RelayDevice] { devices.filter { !$0.revoked } }
}

/// Device management over the relay's HTTP API.
///
/// Listing and revoking pairings is a relay operation — the relay owns the
/// device rows — so it is a plain HTTPS call with the *device token*, not a DLP
/// method. A phone can therefore see and manage its own pairings without the
/// person running the relay, and without reaching the computer at all: a phone
/// whose Mac is asleep can still unpair itself.
public struct RelayDeviceAdmin: Sendable {
    /// Relay origin in HTTP form, including any mount prefix.
    public let relayURL: URL
    /// This phone's device credential.
    public let deviceToken: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(relayURL: URL, deviceToken: String, session: URLSession? = nil, timeout: TimeInterval = 20) {
        self.relayURL = relayURL
        self.deviceToken = deviceToken
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    private struct ListEnvelope: Decodable {
        let ok: Bool?
        let currentDeviceId: String?
        let devices: [RelayDevice]?
        let error: DSHRPCFailure?
    }

    private struct RevokeEnvelope: Decodable {
        let ok: Bool?
        let deviceId: String?
        let error: DSHRPCFailure?
    }

    /// Devices paired to the same computer as this phone.
    public func devices() async throws -> RelayDeviceList {
        let envelope: ListEnvelope = try await call(path: "/devices", method: "GET", body: nil)
        guard envelope.ok == true, let devices = envelope.devices else {
            throw envelope.error ?? DSHTransportError.malformedResponse("中转没有返回设备列表")
        }
        return RelayDeviceList(devices: devices, currentDeviceId: envelope.currentDeviceId)
    }

    /// Revokes one pairing.
    ///
    /// Revoking the device making the call is allowed and is how a phone signs
    /// itself out; its own token stops working immediately, so the caller has to
    /// be prepared to re-pair. The UI confirms first.
    @discardableResult
    public func revokeDevice(id: String) async throws -> String {
        let body = try JSONEncoder().encode(["deviceId": id])
        let envelope: RevokeEnvelope = try await call(path: "/devices/revoke", method: "POST", body: body)
        guard envelope.ok == true else {
            throw envelope.error ?? DSHTransportError.malformedResponse("中转没有确认撤销")
        }
        return envelope.deviceId ?? id
    }

    private func call<Envelope: Decodable>(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Envelope {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        // The relay may be mounted under a path prefix so it shares an existing
        // domain and certificate; the prefix is appended to, never replaced.
        components?.path = LinkConfiguration.appending(path: path, to: relayURL)
        components?.query = nil
        guard let url = components?.url else {
            throw DSHTransportError.unreachable("中转地址无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DSHTransportError.unreachable("无法连接中转：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw DSHTransportError.malformedResponse("中转响应无效")
        }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw DSHTransportError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }
}

extension LinkCarrier {
    /// Relay identity this carrier is using, when it is a relay connection.
    ///
    /// Device management is a relay call, so the UI needs the relay origin and
    /// this phone's device token. Exposing them here keeps the transport details
    /// inside the carrier instead of spreading them into the view layer.
    public nonisolated var relay: (url: URL, deviceToken: String, agentId: String)? {
        (configuration.relayURL, configuration.deviceToken, configuration.agentId)
    }

    /// A ready-made device administrator for this connection.
    public nonisolated func deviceAdmin() -> RelayDeviceAdmin {
        RelayDeviceAdmin(relayURL: configuration.relayURL, deviceToken: configuration.deviceToken)
    }
}

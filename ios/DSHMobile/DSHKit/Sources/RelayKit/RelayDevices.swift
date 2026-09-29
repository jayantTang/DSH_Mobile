import Foundation
import DSHKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which of Apple's two push hosts a device token belongs to.
///
/// The relay refuses anything else (`request/apns-env`): a token is minted by one
/// environment and rejected by the other with ``BadDeviceToken``, which from the
/// phone looks like "push is simply broken". A TestFlight or App Store build
/// gets a production token; a build installed straight from Xcode gets a sandbox
/// one, and this app's development channel is an OTA/ad-hoc build — hence the
/// default at the call site is read from the embedded provisioning profile
/// rather than guessed.
public enum RelayPushEnvironment: String, Sendable, CaseIterable {
    case sandbox
    case production
}

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

    private struct PushEnvelope: Decodable {
        let ok: Bool?
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

    /// Registers this phone's APNs token and reminder switches with the relay.
    ///
    /// The phone cannot reach the computer when it is away — that is the whole
    /// reason push exists — so this goes to the relay, which already holds the
    /// device ledger and the signing key. It is the same credential as the
    /// device list: the phone manages its own row and nobody else's.
    ///
    /// An empty ``token`` **clears** the registration, which is what the app
    /// sends when the user turns notification permission off. That is the only
    /// thing that actually stops the pushes, so it must be as reliable as
    /// registering.
    ///
    /// `env` is ``sandbox`` or ``production`` and is what tells the relay which
    /// of Apple's two hosts to use. A token minted by one is rejected by the
    /// other, so the pair travels together.
    public func registerPush(
        token: String,
        env: RelayPushEnvironment?,
        turnEnd: Bool,
        attention: Bool
    ) async throws {
        var fields: [String: Any] = [
            "apnsToken": token,
            "turnEnd": turnEnd,
            "attention": attention,
        ]
        // 空令牌＝清除登记；relay 此时忽略 env（它要求 env 只能是两个合法值之一），
        // 所以不带比带一个对的更安全。
        if !token.isEmpty, let env {
            fields["env"] = env.rawValue
        }
        let body = try JSONSerialization.data(withJSONObject: fields)
        let envelope: PushEnvelope = try await call(path: "/devices/push", method: "POST", body: body)
        guard envelope.ok == true else {
            throw envelope.error ?? DSHTransportError.malformedResponse("中转没有确认推送登记")
        }
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

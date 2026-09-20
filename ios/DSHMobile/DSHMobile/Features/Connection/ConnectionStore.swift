import DSHKit
import Foundation
import Observation

#if canImport(UIKit)
import UIKit
#endif

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

    public init(
        id: UUID = UUID(),
        name: String,
        transport: Transport,
        hostHome: String? = nil,
        relayName: String? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.hostHome = hostHome
        self.relayName = relayName
        self.lastConnectedAt = lastConnectedAt
    }

    /// Keychain account holding this profile's bearer secret.
    var secretAccount: String { "profile-\(id.uuidString)" }

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
            return "\(relayURL.host() ?? relayURL.absoluteString) · 中转"
        }
    }
}

/// The app's live connection to one DSH host.
///
/// Owns the profile list, the chosen transport, and the `DSHClient` that every
/// screen talks to. Connection state is surfaced as one enum so the UI can be
/// exhaustive about what it shows.
@MainActor
@Observable
public final class ConnectionStore {

    /// What the UI needs to know about the current link.
    public enum State: Sendable, Equatable {
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

    /// A DSH instance discovered through pairing, awaiting a name.
    public struct Pairing: Sendable {
        public let relayURL: URL
        public let agentId: String
        public let deviceToken: String
        public let agentName: String
    }

    public private(set) var profiles: [ConnectionProfile] = []
    public private(set) var state: State = .disconnected
    public private(set) var client: DSHClient?
    public private(set) var lastError: String?

    /// The connected host's home directory.
    ///
    /// Published by the host on its event stream; used to abbreviate paths the
    /// same way the desktop client does.
    public internal(set) var hostHome: String?

    /// The origin the desktop web UI would be served from, for the WebView
    /// fallback. Nil on a relay connection, where the reachable origin is the
    /// relay rather than the host.
    public var activeBaseURL: URL? {
        guard let activeProfile else { return nil }
        if case .direct(let baseURL, _) = activeProfile.transport { return baseURL }
        return nil
    }

    /// The profile currently connected, if any.
    public private(set) var activeProfile: ConnectionProfile?

    /// The profile to reconnect to when nothing is active: most recent first.
    private var preferredProfile: ConnectionProfile? {
        profiles
            .filter { hasSecret(for: $0) }
            .max { ($0.lastConnectedAt ?? .distantPast) < ($1.lastConnectedAt ?? .distantPast) }
    }

    /// What the computer's connector says it can do.
    ///
    /// Empty until asked, and empty is treated as "nothing" — a connector that
    /// predates a capability must hide that entry rather than accept a call
    /// that would come back as a 404 from the Host.
    public private(set) var capabilities: Set<String> = []


    private var carrier: (any DSHCarrier)?
    private var statusTask: Task<Void, Never>?
    /// Probes a live link and repairs a dropped one.
    private var watchTask: Task<Void, Never>?

    private let defaultsKey = "dsh.connection.profiles"

    public init() {
        profiles = Self.loadProfiles()
    }

    // MARK: - Persistence

    private static func loadProfiles() -> [ConnectionProfile] {
        guard let data = UserDefaults.standard.data(forKey: "dsh.connection.profiles") else { return [] }
        return (try? JSONDecoder().decode([ConnectionProfile].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Whether a profile has a usable secret in the keychain.
    public func hasSecret(for profile: ConnectionProfile) -> Bool {
        Keychain.get(profile.secretAccount) != nil
    }

    // MARK: - Profile management

    @discardableResult
    public func addProfile(_ profile: ConnectionProfile, secret: String) -> ConnectionProfile {
        try? Keychain.set(secret, for: profile.secretAccount)
        profiles.append(profile)
        persist()
        return profile
    }

    public func removeProfile(_ profile: ConnectionProfile) {
        Keychain.remove(profile.secretAccount)
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    public func rename(_ profile: ConnectionProfile, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = name
        persist()
    }

    private func recordConnection(_ profileId: UUID, hostHome: String?) {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[index].lastConnectedAt = Date()
        if let hostHome { profiles[index].hostHome = hostHome }
        persist()
    }

    // MARK: - Connecting

    /// Whether the connected connector offers a capability.
    public func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    /// Stages a file on the computer and returns where it landed.
    ///
    /// Exposed here rather than handing the carrier out: the transport is this
    /// store's business, and callers should not have to know which carrier is
    /// live to send a file.
    public func uploadFile(
        data: Data,
        name: String,
        sessionId: String
    ) async throws -> FileUploader.Staged {
        guard let carrier else { throw DSHTransportError.notConnected }
        return try await FileUploader(carrier: carrier).upload(
            data: data,
            name: name,
            sessionId: sessionId
        )
    }

    /// Connects using a saved profile, reusing its stored secret.
    public func connect(to profile: ConnectionProfile) async {
        // Re-resolved by the handshake: leftovers from another computer would
        // offer entries that host does not serve.
        capabilities = []
        guard let secret = Keychain.get(profile.secretAccount) else {
            state = .failed("此连接的凭据已丢失，请重新配对。")
            return
        }
        await connect(profile: profile, secret: secret)
    }

    /// Connects and verifies the link before reporting success.
    ///
    /// A relay socket can be up while the computer's connector is asleep, so
    /// "connected" is only claimed after a real request succeeds.
    ///
    /// Reconnecting the profile that is already active is a *repair*, not a new
    /// connection: nothing on screen is discarded, and a failed attempt leaves
    /// the app in `connecting` instead of throwing the user back to the pairing
    /// screen. A network that blinks should cost a status line, not the screen.
    public func connect(profile: ConnectionProfile, secret: String) async {
        let isRepair = activeProfile?.id == profile.id
        if !isRepair { await disconnect() }
        lastError = nil
        isConnecting = true
        defer { isConnecting = false }

        switch profile.transport {
        case .direct(let baseURL, let cookieName):
            state = .connecting("正在连接 \(baseURL.host() ?? "")…")
            let carrier = HTTPCarrier(
                baseURL: baseURL,
                credential: .cookie(name: cookieName, value: secret),
                // Short on purpose: this probe is the reachability test, and a
                // phone that left the network the host lives on should fail
                // over to the relay quickly rather than hang for a minute.
                timeout: 12
            )
            do {
                // A stale cookie is the common case after a DSH restart; the
                // carrier reports it so the UI can ask for a fresh token.
                let probe = try await DSHClient(carrier: carrier).sessions()
                await install(carrier: carrier, profile: profile, sampleCount: probe.items.count)
            } catch {
                await carrier.close()
                attemptFailed(error, repairing: isRepair)
            }

        case .relay(let relayURL, let agentId):
            state = .connecting(isRepair ? "连接中断，正在重连…" : "正在连接中转…")
            let configuration = LinkConfiguration(
                relayURL: relayURL,
                agentId: agentId,
                deviceToken: secret
            )
            let link = LinkCarrier(configuration: configuration)
            await link.connect()
            do {
                let probe = try await DSHClient(carrier: link).sessions()
                await install(carrier: link, profile: profile, sampleCount: probe.items.count)
                observeStatus(of: link)
            } catch {
                await link.close()
                attemptFailed(error, repairing: isRepair)
            }
        }
    }

    /// Decides what a failed attempt means for the screen.
    ///
    /// A repair keeps the workspace and leaves the link to the watcher; only a
    /// connection that was never established has nothing to show, and that is
    /// the one case the pairing screen is for.
    private func attemptFailed(_ error: any Error, repairing: Bool) {
        lastError = Self.describe(error)
        if repairing {
            state = .connecting("连接中断，正在重连…")
            startWatching()
        } else {
            state = .failed(lastError ?? "连接失败")
        }
    }

    /// What this build is, for the per-connection handshake.
    ///
    /// Read here rather than inside DSHKit: the package is platform-neutral and
    /// has no bundle of its own, so the app is the only place that knows.
    static var clientName: String? { Bundle.main.infoDictionary?["CFBundleName"] as? String }
    static var clientVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    static var clientBuild: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }

    private func install(carrier: any DSHCarrier, profile: ConnectionProfile, sampleCount: Int) async {
        let previous = self.carrier
        self.carrier = carrier
        let client = DSHClient(carrier: carrier)
        self.client = client
        self.activeProfile = profile
        self.hostHome = profile.hostHome
        // Asked once per connection. A failure is not fatal: it just means the
        // app falls back to showing nothing that depends on a capability.
        // Says who is asking, once per connection: the computer records it, and
        // the relay refreshes the device row with it, so "which build is that
        // phone on?" stops being a question only the phone can answer.
        let handshake = try? await client.linkHandshake(client: LinkHandshakeRequest(
            clientName: Self.clientName,
            clientVersion: Self.clientVersion,
            clientBuild: Self.clientBuild
        ))
        capabilities = Set(handshake?.capabilities ?? [])
        state = .connected(hostHome: profile.hostHome)
        recordConnection(profile.id, hostHome: profile.hostHome)
        startWatching()
        // What a repair replaced is closed only now, once the new link has
        // answered: had the repair failed, the old client would still have been
        // the only one the screen could use.
        if let previous { await previous.close() }
    }

    /// Mirrors the link's online state into the UI.
    ///
    /// Two different drops arrive as the same `online: false`: the relay socket
    /// went away, or the socket is fine and the computer's connector is asleep.
    /// They are worded differently because they call for different reactions.
    private func observeStatus(of link: LinkCarrier) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await status in await link.statusStream() {
                guard let self else { return }
                if !status.online, self.state.isConnected {
                    self.state = .connecting(status.info == nil
                        ? "连接中断，正在重连…"
                        : "电脑端连接器已离线，正在等待…")
                } else if status.online, self.state.isConnecting, self.client != nil {
                    // Back online: say so. Only ever setting the offline side
                    // left the app on "正在等待…" forever after a blip, which on
                    // a phone is every trip to the background.
                    self.state = .connected(hostHome: self.hostHome)
                }
            }
        }
    }

    // MARK: - Keeping the link honest

    /// How often a connected link is asked something cheap.
    ///
    /// A phone's link can die with nothing in flight — a Wi-Fi handover, a
    /// sleeping router, a relay restart — and the app would happily keep showing
    /// 已连接 over a dead socket. Twenty seconds is short enough that the user
    /// finds out from the chip rather than from a failed action.
    private static let heartbeat = Duration.seconds(20)

    /// Watches the link and puts it back when it goes away.
    ///
    /// Two jobs in one loop, because they are the same question asked at two
    /// moments. While connected it probes the host, so a silently dead link
    /// becomes a state the UI can show instead of a lie. While disconnected it
    /// repairs the link with backoff — the relay socket heals itself, but only
    /// the store knows whether the *host* is answering again, and only the store
    /// can hand the screens a new client once it is.
    private func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, self.activeProfile != nil else { break }

                if self.state.isConnected, let client = self.client {
                    try? await Task.sleep(for: Self.heartbeat)
                    if Task.isCancelled { break }
                    if (try? await client.sessions()) == nil, self.state.isConnected {
                        self.state = .connecting("连接中断，正在重连…")
                    }
                    continue
                }

                // Not connected: repair, backing off so a host that is off for
                // the night costs a request a minute rather than one a second.
                let delay = min(12, 0.6 * Double(attempt + 1))
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }
                guard !self.isConnecting,
                      let profile = self.activeProfile ?? self.preferredProfile,
                      let secret = Keychain.get(profile.secretAccount)
                else { continue }
                await self.connect(profile: profile, secret: secret)
                attempt = self.state.isConnected ? 0 : attempt + 1
            }
            self?.watchTask = nil
        }
    }

    private func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// Whether the app is re-establishing a link it already had.
    ///
    /// The distinction the UI needs: a reconnect keeps the workspace on screen
    /// with a quiet notice, while a first connection shows the pairing screen.
    public var isReconnecting: Bool {
        (state.isConnecting || isConnecting) && activeProfile != nil
    }

    /// Whether an attempt is in flight right now.
    public private(set) var isConnecting = false

    /// Reconnects the profile that was in use, if the link has dropped.
    ///
    /// Called when the app returns to the foreground. iOS suspends a backgrounded
    /// app and its sockets with it, so the link is often dead by the time the
    /// user looks again — this is what puts it back without asking them to pair
    /// again. Repairing rather than replacing is what keeps the current screen
    /// current: see `connect(profile:secret:)`.
    public func reconnectIfNeeded() async {
        guard !state.isConnected, !isConnecting, !isReconnecting else { return }
        guard let profile = activeProfile ?? preferredProfile else { return }
        await connect(to: profile)
    }

    public func disconnect() async {
        statusTask?.cancel()
        statusTask = nil
        stopWatching()
        await carrier?.close()
        carrier = nil
        client = nil
        activeProfile = nil
        hostHome = nil
        // What the previous host could do says nothing about the next one.
        capabilities = []
        state = .disconnected
    }

    // MARK: - Deep links

    #if DEBUG
    /// Drops the link the way a dead socket does, for the unattended run.
    ///
    /// A real network cut cannot be produced from inside the simulator, and
    /// "连接稍有波动" is exactly the repair path this exercises: the carrier is
    /// closed, the app is left non-connected with a profile still active, and
    /// everything after that — keeping the screen, reconnecting, refreshing the
    /// status — is the product's own code.
    func dropLinkForTesting() async {
        guard activeProfile != nil else { return }
        statusTask?.cancel()
        statusTask = nil
        await carrier?.close()
        carrier = nil
        client = nil
        state = .connecting("连接中断，正在重连…")
        // The same watcher a real drop ends up with, so the run exercises the
        // recovery the product actually performs.
        startWatching()
    }
    #endif

    /// Connects from a scanned or pasted link, returning a message on failure.
    ///
    /// Profiles are de-duplicated by their transport so re-scanning the same
    /// computer updates the existing entry instead of piling up copies.
    @discardableResult
    func connect(link: ConnectLink) async -> String? {
        switch link {
        case .pair(let relay, let code):
            do {
                let pairing = try await Self.claimPairingCode(
                    relayURL: relay,
                    code: code,
                    deviceName: Self.deviceName
                )
                let transport = ConnectionProfile.Transport.relay(
                    relayURL: pairing.relayURL,
                    agentId: pairing.agentId
                )
                let profile = existingProfile(matching: transport)
                    ?? addProfile(
                        ConnectionProfile(name: pairing.agentName, transport: transport),
                        secret: pairing.deviceToken
                    )
                if existingProfile(matching: transport) != nil {
                    try? Keychain.set(pairing.deviceToken, for: profile.secretAccount)
                }
                await connect(to: profile)
            } catch {
                return Self.describe(error)
            }

        case .direct(let baseURL, let launchToken):
            let carrier = HTTPCarrier(baseURL: baseURL, credential: .launchToken(launchToken), timeout: 30)
            do {
                try await carrier.authenticate()
                let cookie = await carrier.cookie
                await carrier.close()
                guard let cookie else { return "无法从启动令牌换取会话凭据。" }

                let transport = ConnectionProfile.Transport.direct(
                    baseURL: baseURL,
                    cookieName: cookie.name
                )
                let profile = existingProfile(matching: transport)
                    ?? addProfile(
                        ConnectionProfile(name: baseURL.host() ?? "DSH", transport: transport),
                        secret: cookie.value
                    )
                if existingProfile(matching: transport) != nil {
                    try? Keychain.set(cookie.value, for: profile.secretAccount)
                }
                await connect(to: profile)
            } catch {
                await carrier.close()
                return Self.describe(error)
            }

        #if DEBUG
        case .claimedRelay(let relayURL, let agentId, let deviceToken, let name):
            // The credential is already a device token: the caller claimed the
            // code (see `ConnectLink.claimedRelay`), so there is nothing to
            // trade here — only a profile to install or refresh.
            let transport = ConnectionProfile.Transport.relay(relayURL: relayURL, agentId: agentId)
            let profile = existingProfile(matching: transport)
                ?? addProfile(
                    ConnectionProfile(name: name ?? relayURL.host() ?? "DSH", transport: transport),
                    secret: deviceToken
                )
            try? Keychain.set(deviceToken, for: profile.secretAccount)
            await connect(to: profile)
        #endif
        }

        if case .failed(let message) = state { return message }
        return nil
    }

    /// Finds a saved profile with the same transport identity.
    private func existingProfile(matching transport: ConnectionProfile.Transport) -> ConnectionProfile? {
        profiles.first { candidate in
            switch (candidate.transport, transport) {
            case (.direct(let lhs, _), .direct(let rhs, _)):
                return lhs == rhs
            case (.relay(_, let lhs), .relay(_, let rhs)):
                return lhs == rhs
            default:
                return false
            }
        }
    }

    // MARK: - Pairing

    /// Claims a pairing code against a relay and returns the resulting link.
    ///
    /// This is the whole of the phone-side pairing flow: the computer shows a
    /// short code, the phone trades it for a long-lived device token.
    public static func claimPairingCode(
        relayURL: URL,
        code: String,
        deviceName: String
    ) async throws -> Pairing {
        // The relay address may be stored in either form; the claim is an HTTP
        // call, so it must be normalised before the URL is built.
        guard let httpRelay = ConnectLink.normalizedRelayURL(relayURL) else {
            throw DSHTransportError.unreachable("中转地址无效")
        }
        var components = URLComponents(url: httpRelay, resolvingAgainstBaseURL: false)
        // The relay can be mounted under a path prefix so it shares an existing
        // domain and certificate; the prefix is appended to, never replaced.
        components?.path = LinkConfiguration.appending(path: "/pair/claim", to: httpRelay)
        components?.query = nil
        guard let url = components?.url else {
            throw DSHTransportError.unreachable("中转地址无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "pairCode": code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines),
            "deviceName": deviceName,
            "deviceModel": Self.deviceModel,
            "appVersion": Self.appVersion,
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DSHTransportError.malformedResponse("配对响应无效")
        }

        struct Envelope: Decodable {
            let ok: Bool?
            let agentId: String?
            let deviceToken: String?
            let agentName: String?
            let error: DSHRPCFailure?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard http.statusCode == 200, let agentId = envelope.agentId, let token = envelope.deviceToken else {
            throw envelope.error ?? DSHTransportError.httpStatus(
                http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
        return Pairing(
            relayURL: relayURL,
            agentId: agentId,
            deviceToken: token,
            agentName: envelope.agentName ?? "我的电脑"
        )
    }

    // MARK: - Diagnostics

    public static func describe(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    static var deviceModel: String {
        #if canImport(UIKit)
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
        return machine
        #else
        return "macOS"
        #endif
    }

    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Device"
        #endif
    }
}

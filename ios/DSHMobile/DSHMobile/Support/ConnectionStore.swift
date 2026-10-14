import DSHKit
import Foundation
import Observation
import RelayKit

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
            // The whole line is one key (`%@ · 中转`), not string concatenation:
            // this value is painted on the settings screen as「主机地址」, and an
            // English phone used to show the Chinese「中转」here.
            return String(localized: "\(relayURL.host() ?? relayURL.absoluteString) · 中转")
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

    /// What identifies "the computer we are talking to", for caches that must
    /// not survive a switch: the agent id when there is one, otherwise the
    /// profile's own id (a profile that has not enrolled yet).
    public var scopeId: String? {
        guard let profile = activeProfile else { return nil }
        if case .relay(_, let agentId) = profile.transport, !agentId.isEmpty { return agentId }
        return profile.id.uuidString
    }

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

    /// The **connector** version the connected computer reports, from the handshake
    /// (`_link/hello`'s `serverVersion` = `dsh-plugin-mobile-link`'s package version).
    ///
    /// Kept only to tell the user when their connector is behind the baseline the
    /// app was built against (see `HostVersion`). It is **not** a gate: a
    /// connection is never refused because of this value, and an unreadable or
    /// missing version simply produces no notice. The baseline is a **connector**
    /// version too — see `ConnectorBaseline`; mixing it with the DSH host version
    /// (a different namespace) is what makes the notice never appear.
    public private(set) var connectorVersion: String? = nil


    private var carrier: (any DSHCarrier)?
    private var statusTask: Task<Void, Never>?
    private var socketStateTask: Task<Void, Never>?
    /// Store 拨号路径的单飞（T005d，US3）：同时最多一次 connect 在飞。
    /// 观望者（watcher）复用在飞那次；用户主动动作取消它并立刻新建（用户意图优先）。
    private var connectTask: Task<Void, Never>?
    private var connectTaskProfileId: UUID?
    /// 代数戳：被取消的在飞 connect 完成时不得再 `install()`，否则把新连接顶回去。
    private var connectGeneration = 0
    /// 重连节奏（spec 022）：只由 Store 自己的拨号路径使用；Carrier 自愈用同一形状的策略。
    private var backoff = ReconnectBackoff()
    /// 连续探活失败次数：**连续两次**才把链路判成断开（FR-004）。
    private var probeFailures = 0
    /// 上一次进入已连接的时刻，用于判断这次连接"活得够不够久"。
    private var connectedAt: Date?
    /// 最近一次列表采样条数（重装 client 时沿用它，不必为此再拉一次列表）。
    private var lastSampleCount = 0
    /// Probes a live link and repairs a dropped one.
    private var watchTask: Task<Void, Never>?

    /// App 的生命周期流水，**整个进程一份**。
    ///
    /// 为什么由 store 持有而不是每条 carrier 各建一个：修复连接时会换一个全新的 carrier，
    /// 而"上次为什么断、手机上几点发生的"必须跨 carrier 连起来看；每建一个就写一份文件
    /// 还会互相滚动覆盖。落在 App 容器的 Application Support 下（不是 `~/.dsh`）。
    private let linkDiagnostics: LinkDiagnostics = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let directory = base?.appendingPathComponent("link-diagnostics", isDirectory: true)
        return LinkDiagnostics(directory: directory)
    }()

    /// 前后台切换（spec 020 的 FR-009）。用来把"App 被系统挂起"与"拨号卡住"分开。
    public enum AppScene: String, Sendable { case foreground, background }

    /// 探针这一次列表调用带的能力。
    ///
    /// **乐观地先按"对方支持精简版"试**：探针跑在握手之前，此时还不知道能力；而探针恰好是
    /// 冷启动里最大的一次列表拉取（731 KB → 50 KB）。老连接器上这次调用会返回
    /// `status=unsupported`，`sessions()` 捕获后自动回退到 `session/list`，代价只是一次几百毫秒的往返。
    private var probeCapabilities: Set<String> { [DSHClient.sessionDigestCapability] }

    /// 记一条前后台切换。**不依赖 carrier**：链路还没建起来时更要记——
    /// "App 回到前台但一直没拨号"正是最需要看见的现场（记录走 store 自己那份流水）。
    public func noteScene(_ scene: AppScene, cold: Bool = false) async {
        await linkDiagnostics.record(kind: "app.scene", detail: [
            "phase": .string(scene.rawValue), "cold": .bool(cold),
        ])
        // 回到前台是"用户主动回来"，退避清零并立刻探一次（spec 022 FR-002）：
        // 用户等着的时候不该还在按退避倒计时。
        if scene == .foreground {
            backoff.reset()
            probeFailures = 0
        }
        // 回到前台顺手把攒下的记录推上去（后台期间可能攒了"挂起—恢复"这一串）。
        if scene == .foreground, let link = carrier as? LinkCarrier { await pushDiagnostics(link) }
    }

    /// 冷启动：进程从零起来并进入前台。与"从后台回来"必须分得开（现场诊断发现的缺口）。
    public func noteColdLaunch() async {
        await noteScene(.foreground, cold: true)
    }

    /// 首个内容真的画出来了（由会话行的 `onAppear` 调用）。一次拨号只记一条。
    public func noteFirstRender() async {
        await linkDiagnostics.markFirstRender()
        if let link = carrier as? LinkCarrier { await pushDiagnostics(link) }
    }

    /// 把 App 攒下的阶段记录增量推给连接器（spec 020 的 FR-011）。
    ///
    /// 三条纪律：
    ///   1. **失败当无事**（旧连接器回 `link/unsupported` 是预期内的），下次 install/回前台再试；
    ///   2. 只推 `pending()`（未推过的），水位按连接器确认的 `lastSeq` 前进——不重发也不漏发；
    ///   3. 绝不因为推送失败改变连接状态。
    func pushDiagnostics(_ link: LinkCarrier) async {
        let pending = await link.diagnostics.pending()
        guard !pending.isEmpty, let client else { return }
        let request = LinkDiagnosticsRequest(
            since: await link.diagnostics.pushedUpTo,
            sentAt: Int(Date().timeIntervalSince1970 * 1000),
            dropped: await link.diagnostics.dropped,
            events: pending,
            client: LinkDiagnosticsClient(name: Self.clientName,
                                          version: Self.clientVersion,
                                          build: Self.clientBuild)
        )
        guard let ack = try? await client.pushDiagnostics(request) else { return }
        await link.diagnostics.markPushed(upTo: ack.lastSeq)
    }

    /// 只在两次动作之间记录**首个**交互的耗时（FR-010）：第一个数据请求发出与它的响应到达。
    private var firstInteractionRecorded = false

    /// 记首个数据交互的耗时与字节（由消息管道在收到首个响应时调用）。
    public func noteFirstInteraction(method: String, ms: Int, bytes: Int) async {
        guard !firstInteractionRecorded, let link = carrier as? LinkCarrier else { return }
        firstInteractionRecorded = true
        await link.diagnosticsNote("app.first-response", detail: [
            "method": .string(method), "elapsedMs": .int(ms), "bytes": .int(bytes),
        ])
    }

    private let defaultsKey = "dsh.connection.profiles"

    public init() {
        profiles = Self.loadProfiles()
    }

    // MARK: - Persistence

    private static func loadProfiles() -> [ConnectionProfile] {
        guard let data = UserDefaults.standard.data(forKey: "dsh.connection.profiles") else { return [] }
        return (try? JSONDecoder().decode([ConnectionProfile].self, from: data)) ?? []
    }

    /// The saved pairings, readable without an instance.
    ///
    /// Push registration needs to find "the relay this phone is paired to" at
    /// moments when no `ConnectionStore` is in scope and no link is up — a
    /// `didRegisterForRemoteNotifications` callback arrives whenever Apple feels
    /// like it, including for a phone that has been offline for a day. Reading
    /// the same store the live object persists to keeps the two in step without
    /// a second copy of the profile list.
    public static func persistedProfiles() -> [ConnectionProfile] {
        loadProfiles()
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

    // MARK: - Host version notice

    /// Whether to show "the computer's connector is out of date".
    ///
    /// **This never gates anything** — the connection is already up by the time
    /// it can be true, and a stale connector keeps working, just with fewer
    /// capabilities. It is a hint the user can act on, so it is shown only when
    /// we are sure (`HostVersion.isOlder`, which refuses to guess) and it stays
    /// hidden once dismissed for that same reported version.
    public var showsOutdatedConnectorNotice: Bool {
        guard let reported = connectorVersion,
              HostVersion.isOlder(reported, than: ConnectorBaseline.minVersion) else { return false }
        return activeProfile?.outdatedNoticeDismissedFor != reported
    }

    /// Remembers that the user dismissed the notice, for this profile and this
    /// reported version. A later baseline (or a different computer) shows it again.
    public func dismissOutdatedConnectorNotice() {
        guard let reported = connectorVersion,
              let id = activeProfile?.id,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].outdatedNoticeDismissedFor = reported
        activeProfile = profiles[index]
        persist()
    }

    /// Stages a file the caller has as a URL.
    ///
    /// **One route, one attempt, no fallback.** Every file — 1 KB or 400 MB —
    /// goes over the relay's HTTPS surface as a file-based **background** task,
    /// so the system finishes it after the app is suspended. There used to be a
    /// size threshold with a WSS chunked path below it, and a `catch` that
    /// re-sent the whole file over WSS whenever the HTTPS attempt failed; both
    /// are gone. The `catch` was the direct cause of the R-1 incident: an upload
    /// that had transferred every byte and been answered `200` was discarded as
    /// `malformedResponse` and re-sent over the socket, so the phone showed an
    /// upload that never ended for a file the computer already had.
    ///
    /// A failure here is reported as a failure. `fileTransferTarget()` says which
    /// of the "there is no route from here" cases applies, and anything else
    /// propagates untouched — the caller shows it and the person can send again.
    public func uploadFile(
        fileURL: URL,
        name: String,
        sessionId: String
    ) async throws -> StagedFile {
        let target = try fileTransferTarget()
        return try await RelayFileTransfer(
            relayURL: target.relayURL, deviceToken: target.deviceToken
        ).upload(fileURL: fileURL, name: name, sessionId: sessionId).asStaged
    }

    /// The target of a file transfer — relay origin plus device credential — or
    /// the reason there is no route from here.
    ///
    /// **Shared by both directions on purpose.** Upload and download must agree
    /// on what "cannot transfer" means, and a second copy of this policy is
    /// exactly how the two directions drifted apart before. The four ways it can
    /// fail are statements about the *connection*, not a choice between
    /// transports: none of them falls through to another route, because there
    /// isn't one.
    ///
    /// `throws` rather than returning `nil`: a `nil` is what made the old code
    /// silently take the WSS path.
    public func fileTransferTarget() throws -> (relayURL: URL, deviceToken: String) {
        guard case .relay(let relayURL, _)? = activeProfile?.transport else {
            // `.direct` (`dsh://direct`) is the DEBUG-only test channel; the
            // product has exactly one connection method. It stays usable, but it
            // cannot carry file bytes — and saying so beats quietly using a
            // different path than the product does.
            throw RelayFileTransfer.Unavailable.noRelay
        }
        guard supports(RelayFileTransfer.capability) else {
            throw RelayFileTransfer.Unavailable.connectorTooOld
        }
        guard let httpRelay = ConnectLink.normalizedRelayURL(relayURL) else {
            throw RelayFileTransfer.Unavailable.relayAddressInvalid
        }
        guard let profile = activeProfile, let secret = Keychain.get(profile.secretAccount) else {
            throw RelayFileTransfer.Unavailable.credentialMissing
        }
        return (httpRelay, secret)
    }

    /// Connects using a saved profile, reusing its stored secret.
    public func connect(to profile: ConnectionProfile) async {
        // Re-resolved by the handshake: leftovers from another computer would
        // offer entries that host does not serve.
        capabilities = []
        connectorVersion = nil
        guard let secret = Keychain.get(profile.secretAccount) else {
            state = .failed("此连接的凭据已丢失，请重新配对。")
            return
        }
        await connect(profile: profile, secret: secret)
    }

    /// 拨号单飞的入口（T005d，US3 AC1）。
    ///
    /// - `join`（watcher 等后台路径）：同目标的 connect 在飞就等它出结果，不再拨第二次；
    /// - 用户主动动作（点连接、手动重连）：取消在飞的那次并立刻新建——用户意图优先
    ///   （plan 风险表），被取消的那次靠 `connectGeneration` 在完成时弃权。
    private func connectSingleFlight(profile: ConnectionProfile, secret: String, join: Bool) async {
        if join, let task = connectTask, connectTaskProfileId == profile.id {
            await task.value
            return
        }
        connectTask?.cancel()
        connectGeneration += 1
        let generation = connectGeneration
        let task = Task { @MainActor in
            await self.performConnect(profile: profile, secret: secret, generation: generation)
        }
        connectTask = task
        connectTaskProfileId = profile.id
        await task.value
        if connectTaskProfileId == profile.id {
            connectTask = nil
            connectTaskProfileId = nil
        }
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
        await connectSingleFlight(profile: profile, secret: secret, join: false)
    }

    /// 真正拨号的那一半（`connectSingleFlight` 保证同时只有一个在飞）。
    private func performConnect(profile: ConnectionProfile, secret: String, generation: Int) async {
        let isRepair = activeProfile?.id == profile.id
        if !isRepair { await disconnect(invalidateConnects: false) }
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
                let probe = try await DSHClient(carrier: carrier, capabilities: probeCapabilities).sessions()
                guard generation == connectGeneration else { await carrier.close(); return }
                await install(carrier: carrier, profile: profile, sampleCount: probe.items.count)
            } catch {
                await carrier.close()
                guard generation == connectGeneration else { return }
                attemptFailed(error, repairing: isRepair)
            }

        case .relay(let relayURL, let agentId):
            state = .connecting(isRepair ? "连接中断，正在重连…" : "正在连接中转…")
            let configuration = LinkConfiguration(
                relayURL: relayURL,
                agentId: agentId,
                deviceToken: secret
            )
            // 拨号起点：`install()` 里要用它算"从拨号到握手/到首屏各多少毫秒"。
            let dialStartedAt = Date()
            let link = LinkCarrier(configuration: configuration, diagnostics: linkDiagnostics)
            await link.connect()
            do {
                let probe = try await DSHClient(carrier: link, capabilities: probeCapabilities).sessions()
                // 这次拨号已被更新的一次取代（用户换了目标或点了重连）：安静弃权，
                // 连同自己刚建的 socket 一起收掉，别把新连接顶回去。
                guard generation == connectGeneration else { await link.close(); return }
                await install(carrier: link, profile: profile, sampleCount: probe.items.count,
                              dialStartedAt: dialStartedAt)
                observeStatus(of: link)
            } catch {
                await link.close()
                guard generation == connectGeneration else { return }
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

    /// - Parameter closePrevious: 用**同一个** carrier 重装（链路自愈后的恢复）时必须传
    ///   `false`：否则末尾那条"关掉上一个"会把刚恢复的 socket 自己关掉，当场又掉一次
    ///   （spec 022 的振荡现场就是这么来的）。
    private func install(carrier: any DSHCarrier, profile: ConnectionProfile, sampleCount: Int,
                         dialStartedAt: Date? = nil, closePrevious: Bool = true) async {
        let previous = self.carrier
        self.carrier = carrier
        lastSampleCount = sampleCount
        // 带着**上一次**握手得到的能力建 client：同一台电脑的能力不会变，于是这次连接里
        // 最早的几次列表调用也能走精简版（若连接器换了/降级，`sessions()` 会回退到 `session/list`）。
        let client = DSHClient(carrier: carrier, capabilities: capabilities)
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
        // 握手完成的时刻（spec 020）：有它才谈得上"连上耗时卡在哪一段"。
        if let link = carrier as? LinkCarrier {
            await link.diagnosticsNote("app.hello", since: dialStartedAt)
        }
        capabilities = Set(handshake?.capabilities ?? [])
        // 用刚拿到的能力重建 client（DSHClient 是值类型，换一份即可，carrier 不变）：
        // 从这一刻起的列表调用都会走精简版。
        self.client = DSHClient(carrier: carrier, capabilities: capabilities)
        // Recorded for the out-of-date notice only; never used to refuse the link.
        connectorVersion = handshake?.serverVersion
        state = .connected(hostHome: profile.hostHome)
        // 连上了：探活失败计数与退避都归零（spec 022 FR-001/FR-004）。
        connectedAt = Date()
        probeFailures = 0
        backoff.reset()
        // 首屏就绪：状态机已切到 connected，屏幕可以渲染了（与"握手完成"是两个时刻）。
        if let link = carrier as? LinkCarrier {
            firstInteractionRecorded = false
            await link.diagnosticsNote("app.first-screen", since: dialStartedAt)
            // 推送在后台跑：它是一次网络往返，**不许**挂在连接主路径上（FR-011）。
            Task { await self.pushDiagnostics(link) }
        }
        recordConnection(profile.id, hostHome: profile.hostHome)
        startWatching()
        // What a repair replaced is closed only now, once the new link has
        // answered: had the repair failed, the old client would still have been
        // the only one the screen could use.
        if closePrevious, let previous { await previous.close() }
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
        // socket 三态（T005b）：Carrier 自愈成功（`.up`）时立刻探活重装，
        // 不必等下一个 2 秒探活周期——恢复延迟从"最坏 2 秒"缩到"即刻"。
        socketStateTask?.cancel()
        socketStateTask = Task { [weak self] in
            for await socketState in await link.socketStateStream() {
                guard let self else { return }
                guard socketState == .up, !self.state.isConnected,
                      let client = self.client,
                      let carrier = self.carrier as? LinkCarrier, carrier === link,
                      let profile = self.activeProfile
                else { continue }
                await self.probeHost(client: client, carrier: carrier, profile: profile)
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
    /// Watches the link and puts it back when it goes away.
    ///
    /// Two jobs in one loop, because they are the same question asked at two
    /// moments. While connected it probes the host, so a silently dead link
    /// becomes a state the UI can show instead of a lie. While disconnected it
    /// repairs the link with backoff — the relay socket heals itself, but only
    /// the store knows whether the *host* is answering again, and only the store
    /// can hand the screens a new client once it is.
    /// 心跳探活的周期（已连接时）。
    private static let heartbeat = Duration.seconds(20)
    /// 未连接时的探活周期：Carrier 自愈通常在一两秒内完成，探得太慢恢复就慢。
    private static let recoveryProbe = Duration.seconds(2)

    /// Watches the link and puts it back when it goes away.
    ///
    /// **重连只有一个所有者**（spec 022 FR-005）：socket 掉了由 `LinkCarrier` 自己按
    /// `ReconnectPolicy` 自愈，Store 在 carrier 还活着时**不建新 socket**——2026-10-13 的
    /// 每秒重连风暴就是两边各自建 socket、互相顶掉造成的（85 次 `app.dial`、12 次"上一个
    /// 还开着就再接入"）。Store 只做两件事：探活（`_link/hello`，轻量、不搬列表），
    /// 以及链路回来之后把 client 重新装上。
    ///
    /// 只有没有 carrier 时（首次连接、换档案、carrier 已关闭）才由 Store 拨号，
    /// 这时才用 `backoff`，避免"主机整夜关着"变成一秒一次的请求。
    private func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeProfile != nil else { break }

                if let client = self.client, let carrier = self.carrier,
                   let profile = self.activeProfile ?? self.preferredProfile {
                    // 已连接：慢心跳探活；未连接：快探活等 Carrier 自愈回来。
                    let interval = self.state.isConnected ? Self.heartbeat : Self.recoveryProbe
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { break }
                    await self.probeHost(client: client, carrier: carrier, profile: profile)
                    continue
                }

                // 没有 carrier：这才轮到 Store 拨号。
                if let connectedAt = self.connectedAt {
                    // 上一条链路活了多久，决定退避是否清零（FR-001）。
                    self.backoff.noteConnectionEnded(livedFor: Date().timeIntervalSince(connectedAt))
                    self.connectedAt = nil
                }
                let delay = self.backoff.nextDelay
                await self.linkDiagnostics.record(kind: "link.backoff", detail: [
                    "attempt": .int(self.backoff.attempt),
                    "nextMs": .int(Int(delay * 1000)),
                    "reason": .string("store-dial"),
                ])
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }
                guard !self.isConnecting,
                      let profile = self.activeProfile ?? self.preferredProfile,
                      let secret = Keychain.get(profile.secretAccount)
                else { continue }
                // 后台恢复路径：同目标的在飞拨号直接复用（US3 AC1），不另起一拨。
                await self.connectSingleFlight(profile: profile, secret: secret, join: true)
            }
            self?.watchTask = nil
        }
    }

    /// 轻量探活 + 恢复。
    ///
    /// 探活用 `_link/hello`（实测 ~134 ms、几百字节，连接器本地应答），**不**用
    /// `client.sessions()`：那条路会拉整份会话列表，失败时还会回退到 734 KB 的旧通道，
    /// 于是"列表慢"被误判成"链路死"，正是风暴的放大器（research §二①②）。
    private func probeHost(client: DSHClient, carrier: any DSHCarrier,
                           profile: ConnectionProfile) async {
        let started = Date()
        do {
            _ = try await client.linkHandshake(client: LinkHandshakeRequest(
                clientName: Self.clientName,
                clientVersion: Self.clientVersion,
                clientBuild: Self.clientBuild
            ))
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            probeFailures = 0
            await linkDiagnostics.record(kind: "link.probe", detail: [
                "ok": .bool(true), "ms": .int(ms), "fails": .int(0),
            ])
            if !state.isConnected {
                // Carrier 已经把 socket 自愈回来了：同一个 carrier 重装 client，
                // 不建新 socket（FR-005）。
                await install(carrier: carrier, profile: profile,
                              sampleCount: lastSampleCount, closePrevious: false)
            }
        } catch {
            probeFailures += 1
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            await linkDiagnostics.record(kind: "link.probe", detail: [
                "ok": .bool(false), "ms": .int(ms), "fails": .int(probeFailures),
            ])
            // 单次失败不判断开（FR-004）：链路抖一下不该让界面闪"重连中"。
            if probeFailures >= 2, state.isConnected {
                state = .connecting("连接中断，正在重连…")
            }
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
    /// 冷启动时沿用上次那台电脑：把最近用过的 profile 设为活动，然后照常去连。
    ///
    /// 为什么要有这一步：列表页只在"有活动连接"之后才出现，于是冷启动永远先落在
    /// 连接页——手机上有缓存也只能干等用户点一下「连接」。用户要的是微信那种
    /// "打开就是上次的样子"，所以启动就把上次那台电脑认下来：连上了直接是实时数据，
    /// 连不上也是**列表 + 缓存行 + 未连接提示**，而不是一个空白的选择页。
    ///
    /// - Returns: 是否认下了某个 profile（没有历史/没有密钥时为 false，仍然显示连接页）。
    @discardableResult
    public func adoptPreferredProfile() -> Bool {
        guard activeProfile == nil else { return true }
        guard let profile = preferredProfile else {
            // 没有可用的历史（首次安装、或密钥被清）：仍然显示连接页。留一行日志，
            // 排查"为什么没直接进列表"时不用再猜。
            ViewportProbe.note("adopt.none", [
                "profiles": String(profiles.count),
                "withSecret": String(profiles.filter { hasSecret(for: $0) }.count),
            ], force: true)
            return false
        }
        activeProfile = profile
        state = .connecting("正在连接…")
        return true
    }

    /// Called when the app returns to the foreground. iOS suspends a backgrounded
    /// app and its sockets with it, so the link is often dead by the time the
    /// user looks again — this is what puts it back without asking them to pair
    /// again. Repairing rather than replacing is what keeps the current screen
    /// current: see `connect(profile:secret:)`.
    public func reconnectIfNeeded() async {
        guard !state.isConnected, !isConnecting, !isReconnecting else { return }
        guard let profile = activeProfile ?? preferredProfile else { return }
        // 用户主动动作：不等退避（FR-002）。
        backoff.reset()
        probeFailures = 0
        await connect(to: profile)
    }

    /// - Parameter invalidateConnects: 外部（用户/换档案）调用必须为 `true`：把在飞的
    ///   connect 取消并使它的 `install()` 弃权；`performConnect` 内部的换档案清理传
    ///   `false`，否则会把刚起步的自己一并作废。
    public func disconnect(invalidateConnects: Bool = true) async {
        if invalidateConnects {
            connectTask?.cancel()
            connectTask = nil
            connectTaskProfileId = nil
            connectGeneration += 1
        }
        statusTask?.cancel()
        statusTask = nil
        socketStateTask?.cancel()
        socketStateTask = nil
        stopWatching()
        await carrier?.close()
        carrier = nil
        client = nil
        activeProfile = nil
        hostHome = nil
        // What the previous host could do says nothing about the next one.
        capabilities = []
        connectorVersion = nil
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
        socketStateTask?.cancel()
        socketStateTask = nil
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

    /// Turns a transport failure into something a person can act on.
    ///
    /// The relay and connector already speak in codes; showing those raw is how
    /// "DSh 响应格式异常：中转没有返回落盘路径" ended up in front of a user. Every
    /// branch below answers "what happened, and what can I do" — and the last one
    /// deliberately keeps the original wording rather than flattening an unknown
    /// failure into a generic sentence.
    public static func describe(_ error: any Error) -> String {
        if let failure = error as? DSHRPCFailure {
            switch failure.code {
            case "file/unsupported":
                // 连接器没有桥接帧（版本旧）：relay 已经在给这个语义，这里与
                // `RelayFileTransfer.Unavailable.connectorTooOld` 共用同一条文案键。
                return String(localized: "电脑上的连接器版本过旧，请更新后重发")
            case "host/offline":
                return String(localized: "电脑上的连接器不在线，请确认电脑开着 DSH 后再试")
            case "auth/invalid-token", "auth/unauthorized":
                return String(localized: "这个连接的凭据已失效，请重新配对")
            // 配对失败原来只有一句"配对码无效、已用或过期"，用户没法判断是打错了
            // 还是拿着屏幕上那张旧码又扫了一次。中转现在把三种原因分开报（`pair/...`），
            // 这里各给一句话，而且都说清下一步：回电脑刷新二维码页。
            case "pair/used-code":
                return String(localized: "这个配对码已经用过了，请在电脑「移动端连接」里点「换一张」，再扫新出现的那张")
            case "pair/expired-code":
                return String(localized: "这个配对码已经过期，请在电脑「移动端连接」里点「换一张」，再扫新出现的那张")
            case "pair/invalid-code":
                return String(localized: "配对码不对，请核对电脑上显示的配对码")
            default:
                break
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut:
                return String(localized: "网络超时，可以再点一次发送")
            case .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dataNotAllowed:
                return String(localized: "网络中断，可以再点一次发送")
            default:
                break
            }
        }
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

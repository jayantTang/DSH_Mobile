import DSHKit
import Foundation
import Observation
import RelayKit

/// Loads, edits and saves the DSH settings document.
///
/// Writes are debounced and partial: a field edit marks its top-level key dirty
/// and a short pause later one `settings/update` carries just those keys. A
/// reset (returning a field to the deployment default) cannot be expressed as a
/// merge, so that path replaces the whole section instead.
@MainActor
@Observable
final class SettingsModel {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The subtle inline state shown beside a namespace title.
    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)

        var label: String? {
            switch self {
            case .idle: return nil
            case .saving: return String(localized: "保存中…")
            case .saved: return String(localized: "已保存")
            case .failed: return String(localized: "保存失败")
            }
        }
    }

    /// One credential the host reports through `credentials/describe`.
    struct CredentialRow: Identifiable, Sendable {
        let ref: String
        let configured: Bool
        let source: String?
        let writable: Bool
        /// Where the settings document uses this reference, for context.
        let usedBy: [String]

        var id: String { ref }
    }

    /// How the phone reaches the host.
    enum Transport: Equatable {
        case direct
        case relay
        case unknown

        var label: String {
            switch self {
            case .direct: return String(localized: "局域网直连")
            case .relay: return String(localized: "中转")
            case .unknown: return String(localized: "未确定")
            }
        }
    }

    /// The facts the "关于" section renders.
    struct About: Sendable {
        var appVersion: String
        var hostVersion: String?
        var hostHome: String?
        var endpoint: String?
        var transport: Transport
        var connectorName: String?
        var connectorPort: Int?
        var writable: Bool
        var hasDocument: Bool

        static let empty = About(
            appVersion: "—",
            hostVersion: nil,
            hostHome: nil,
            endpoint: nil,
            transport: .unknown,
            connectorName: nil,
            connectorPort: nil,
            writable: false,
            hasDocument: false
        )
    }

    private(set) var phase: Phase = .idle
    private(set) var document: SettingsDocument?
    private(set) var saveStates: [String: SaveState] = [:]
    private(set) var credentials: [CredentialRow] = []
    private(set) var credentialsPhase: Phase = .idle
    private(set) var about: About = .empty
    private(set) var isRefreshing = false

    // MARK: - Paired devices

    /// Devices paired to this computer, as the relay knows them.
    private(set) var devices: [RelayDevice] = []
    private(set) var devicesPhase: Phase = .idle
    /// Set while one revoke is in flight, so its row can show a spinner and the
    /// rest can disable rather than queue up competing revocations.
    private(set) var revokingDeviceId: String?
    private(set) var devicesError: String?
    /// Whether device management is even possible: it is a relay operation, so
    /// a direct (DEBUG) connection has nowhere to send it.
    private(set) var devicesAvailable = false
    /// Set when the deployment refuses writes, so every control can disable.
    private(set) var isReadOnly = false

    /// The edited copy of each namespace's section root.
    private var drafts: [String: JSONValue] = [:]
    private var dirtyKeys: [String: Set<String>] = [:]
    private var resetKeys: [String: Set<String>] = [:]
    private var saveTasks: [String: Task<Void, Never>] = [:]

    private weak var store: ConnectionStore?

    /// How long typing pauses before a write goes out.
    private let debounce = Duration.milliseconds(650)

    var namespaces: [SettingsNamespace] { document?.namespaces ?? [] }

    var isEmpty: Bool { document != nil && namespaces.isEmpty }

    // MARK: - Lifecycle

    func attach(to store: ConnectionStore) {
        self.store = store
    }

    /// The screen's read, in flight at most once at a time.
    ///
    /// The sheet calls this at launch and again when the link comes up
    /// (`SettingsView`'s `onChange`), and the two overlap by construction: the
    /// launch read is still waiting for the client at the moment the handshake
    /// installs it. A second call therefore **joins** the read already running
    /// rather than fetching everything beside it, and `runReads` is what makes
    /// that join sufficient — it reads a second time when the first pass's
    /// bounded waits gave up just before the link landed.
    private var readTask: Task<Void, Never>?

    func start() async {
        await readScreen()
    }

    /// Reads both halves of the screen: the document from the computer, then the
    /// device list from the relay.
    private func readScreen() async {
        if let readTask {
            await readTask.value
            // The read we joined can have finished a moment before the link
            // landed. One more pass here — bounded, and skipped whenever the
            // document is already in — closes that ordering gap rather than
            // relying on who woke first.
            if document == nil, store?.client != nil { await runReads() }
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runReads()
        }
        readTask = task
        await task.value
        readTask = nil
    }

    /// One read, plus one more pass if the link arrived too late for it.
    ///
    /// Both `load()` and `loadDevices()` wait for the link with a cap, so a
    /// handshake slower than the cap can land in the gap between "the waits gave
    /// up" and "the read finished": the document would stay missing while the
    /// device list (which was still waiting) came back. A second pass, now that
    /// there is a client, closes that gap. Bounded to two passes on purpose —
    /// this is a repair for a late link, not a retry loop.
    private func runReads() async {
        await load()
        await loadDevices()
        if document == nil, store?.client != nil {
            await load()
            await loadDevices()
        }
    }

    func stop() {
        for task in saveTasks.values { task.cancel() }
        saveTasks.removeAll()
    }

    /// Writes every pending edit immediately.
    ///
    /// Called when the screen goes away so a keystroke inside the debounce window
    /// is not dropped on dismissal.
    func flushPendingSaves() async {
        let pending = dirtyKeys.filter { !$0.value.isEmpty }.map(\.key).sorted()
        for ns in pending {
            saveTasks[ns]?.cancel()
            saveTasks[ns] = nil
            await save(namespace: ns)
        }
    }

    /// Reads the settings document, waiting out the launch window first.
    ///
    /// The sheet follows the connection instead of waiting for it, so this can
    /// run before the handshake has installed a client: launched straight into
    /// settings (`-DSHOpenScreen settings`), and for anyone who taps the gear
    /// while the link is still coming up, `start()` runs with `store.client`
    /// still nil. Failing here left the screen showing「已连接」beside
    ///「连接方式 未确定」with the address, home directory, credentials and about
    /// rows all missing, and nothing retried — only「刷新」brought them back.
    /// That is the same launch race that used to hide the device section, one
    /// function over; waiting is free once the link is up, because the first
    /// check finds the client and no sleep happens.
    ///
    /// The wait is bounded, so the screen is read again when the link comes up
    /// (`start()`, which the sheet's `onChange` calls): a handshake slower than
    /// the cap, or one that failed and was retried by the store's watcher, then
    /// fills the page on its own.
    func load() async {
        guard let client = await waitForClient() else {
            phase = .failed(String(localized: "尚未连接"))
            return
        }
        if document == nil { phase = .loading }
        do {
            let raw = try await client.settings()
            let loaded = SettingsDocument(raw: raw)
            adopt(loaded)
            isReadOnly = !loaded.writable
            phase = .loaded
            await loadCredentials()
        } catch {
            if document == nil {
                phase = .failed(Self.describe(error))
            }
        }
        await loadAbout()
    }

    /// Waits for the client the handshake installs, up to a short cap.
    ///
    /// Deliberately the same shape as `loadDevices`: one interval, one cap, and
    /// the same early exit — a handshake that has already failed has no client
    /// coming right now, so stop waiting and leave the original「尚未连接」in
    /// place rather than inventing a new message. The store's watcher keeps
    /// retrying, and the next `readScreen` picks the link up when it lands.
    private func waitForClient(retries: Int = 20, interval: Duration = .milliseconds(250)) async -> DSHClient? {
        var attempt = 0
        while attempt < retries, !Task.isCancelled {
            if let client = store?.client { return client }
            if let state = store?.state, case .failed = state { return nil }
            try? await Task.sleep(for: interval)
            attempt += 1
        }
        return store?.client
    }

    /// Pull-to-refresh: keeps the edited draft of a namespace the user is still
    /// typing into, and adopts everything else from the host.
    ///
    /// The device list is re-read too: it comes from the relay rather than from
    /// the computer, so `load()` cannot bring it back, and a section that gave up
    /// while the link was still coming up would otherwise stay gone until the
    /// sheet was closed and reopened.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await readScreen()
    }

    // MARK: - Paired devices

    /// The relay administrator for the live connection, when there is one.
    ///
    /// Built from the carrier's relay identity rather than from a method on the
    /// carrier: the client lives in `RelayKit`, which depends on `DSHKit`, so
    /// `DSHKit` cannot return one without a dependency cycle.
    private var deviceAdmin: RelayDeviceAdmin? {
        guard let link = store?.client?.carrier as? LinkCarrier,
              let relay = link.relay else { return nil }
        return RelayDeviceAdmin(relayURL: relay.url, deviceToken: relay.deviceToken)
    }

    /// Reads the pairing list from the relay.
    ///
    /// Separate from `load()` on purpose: the settings document comes from the
    /// computer, the device list comes from the relay. One being slow or broken
    /// must not blank the other.
    ///
    /// Whether the section can be shown at all is a property of the **transport**,
    /// not of the handshake: a direct (DEBUG) link has nowhere to send the
    /// request, while a relay link can answer it as soon as its carrier is up.
    /// The sheet follows the connection instead of waiting for it, so deciding
    /// this from the live carrier made the section appear only when the
    /// connection happened to be up before the sheet opened — that is the race
    /// that made TC-UI-01's step 8 fail three runs in a row. Reading the resolved
    /// profile (available before the handshake) shows the section straight away,
    /// with a spinner until the list arrives.
    func loadDevices(retries: Int = 20, interval: Duration = .milliseconds(250)) async {
        showDevicesWhenManageable()

        // The carrier only appears once the handshake finishes, so wait for it
        // rather than concluding "this transport has no devices" from a link
        // that is still connecting.
        var admin = deviceAdmin
        var attempt = 0
        while admin == nil, attempt < retries, !Task.isCancelled {
            // A failed handshake is terminal — no carrier is coming — so stop
            // waiting and hide the section rather than spinning forever.
            if let state = store?.state, case .failed = state { break }
            // The profile can be adopted a beat after the sheet opens (both are
            // launch-time tasks), so keep re-checking instead of deciding once.
            showDevicesWhenManageable()
            try? await Task.sleep(for: interval)
            admin = deviceAdmin
            attempt += 1
        }
        guard let admin else {
            devicesAvailable = false
            devices = []
            devicesPhase = .idle
            return
        }
        do {
            let list = try await admin.devices()
            devices = list.active
            devicesError = nil
            devicesPhase = .loaded
        } catch {
            devicesError = Self.describe(error)
            devicesPhase = .failed(Self.describe(error))
        }
    }

    /// Shows the device section once this link is known to be able to manage
    /// devices, and puts it into its loading state the first time.
    private func showDevicesWhenManageable() {
        guard !devicesAvailable, Self.canManageDevices(store) else { return }
        devicesAvailable = true
        if devices.isEmpty { devicesPhase = .loading }
    }

    /// Whether paired devices can be managed at all.
    ///
    /// Device management is a relay operation, so the answer is exactly "the
    /// resolved transport is the relay". `endpoint(from:)` already resolves which
    /// profile this phone is on — including the fallback to a single saved
    /// profile before the handshake — so the two cannot drift apart.
    private static func canManageDevices(_ store: ConnectionStore?) -> Bool {
        if case .relay = endpoint(from: store).transport { return true }
        return false
    }

    /// Revokes one pairing and drops it from the list.
    ///
    /// Revoking the phone you are holding is allowed: it is how someone signs a
    /// device out. The caller confirms first, because that token stops working
    /// immediately and re-pairing needs the computer.
    func revoke(_ device: RelayDevice) async {
        guard let admin = deviceAdmin else { return }
        revokingDeviceId = device.deviceId
        devicesError = nil
        defer { revokingDeviceId = nil }
        do {
            try await admin.revokeDevice(id: device.deviceId)
            devices.removeAll { $0.deviceId == device.deviceId }
            devicesPhase = .loaded
        } catch {
            devicesError = Self.describe(error)
        }
    }

    /// A device row's "last seen" text.
    func lastSeenLabel(for device: RelayDevice) -> String {
        guard let seen = device.lastSeenAt else { return String(localized: "尚未连接过") }
        let formatter = RelativeDateTimeFormatter()
        // `Locale.current`, not a hardcoded `zh_Hans_CN`: the row read on an
        // English phone used to say「3分钟前」.
        formatter.unitsStyle = .short
        return String(localized: "最后在线 \(formatter.localizedString(for: seen, relativeTo: Date()))")
    }

    private func adopt(_ loaded: SettingsDocument) {
        document = loaded
        let live = Set(loaded.namespaces.map(\.ns))
        drafts = drafts.filter { live.contains($0.key) && !(dirtyKeys[$0.key]?.isEmpty ?? true) }
        dirtyKeys = dirtyKeys.filter { live.contains($0.key) }
        resetKeys = resetKeys.filter { live.contains($0.key) }
        saveStates = saveStates.filter { live.contains($0.key) }
    }

    // MARK: - Reading

    /// The namespace's current section root: the draft while editing, else the
    /// host's resolved value.
    func section(for ns: String) -> JSONValue {
        if let draft = drafts[ns] { return draft }
        return document?.namespace(ns)?.value ?? .object([:])
    }

    func value(namespace ns: String, path: [String]) -> JSONValue? {
        SettingsPath.value(in: section(for: ns), path: path)
    }

    func isOverridden(namespace ns: String, path: [String]) -> Bool {
        document?.namespace(ns)?.isOverridden(at: path) ?? false
    }

    func saveState(for ns: String) -> SaveState { saveStates[ns] ?? .idle }

    var overriddenCount: Int {
        namespaces.reduce(0) { total, ns in
            let user = ns.user?.objectValue ?? [:]
            return total + user.count
        }
    }

    /// Credentials that any namespace's secret slot points at.
    var credentialRows: [CredentialRow] { credentials }

    // MARK: - Editing

    func setValue(namespace ns: String, path: [String], value: JSONValue) {
        guard !path.isEmpty else { return }
        let updated = SettingsPath.setting(section(for: ns), path: path, to: value)
        drafts[ns] = updated
        markDirty(namespace: ns, path: path)
        scheduleSave(namespace: ns)
    }

    /// Returns a field to the deployment default by dropping the user override.
    ///
    /// A merge cannot delete a key, so this records the intent and lets the save
    /// path replace the section.
    func resetField(namespace ns: String, path: [String]) {
        guard !path.isEmpty else { return }
        let updated = SettingsPath.removing(section(for: ns), path: path)
        drafts[ns] = updated
        if let top = path.first { resetKeys[ns, default: []].insert(top) }
        markDirty(namespace: ns, path: path)
        scheduleSave(namespace: ns)
    }

    /// Reverts every local edit in a namespace back to what the host served.
    func discardEdits(namespace ns: String) {
        saveTasks[ns]?.cancel()
        saveTasks[ns] = nil
        drafts[ns] = nil
        dirtyKeys[ns] = nil
        resetKeys[ns] = nil
        saveStates[ns] = .idle
    }

    private func markDirty(namespace ns: String, path: [String]) {
        guard let top = path.first else { return }
        dirtyKeys[ns, default: []].insert(top)
        saveStates[ns] = .idle
    }

    private func scheduleSave(namespace ns: String) {
        saveTasks[ns]?.cancel()
        saveTasks[ns] = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .milliseconds(650))
            guard !Task.isCancelled else { return }
            await self?.save(namespace: ns)
        }
    }

    // MARK: - Saving

    /// Writes one namespace's pending edits.
    func save(namespace ns: String) async {
        // Only a namespace the host still serves can be written.
        guard let client = store?.client, document?.namespace(ns) != nil else { return }
        let dirty = dirtyKeys[ns] ?? []
        guard !dirty.isEmpty else { return }
        guard document?.writable == true else {
            saveStates[ns] = .failed(String(localized: "本部署的设置为只读。"))
            return
        }

        saveStates[ns] = .saving
        let section = section(for: ns)
        let resets = resetKeys[ns] ?? []

        do {
            if !resets.isEmpty || section.objectValue == nil {
                // Dropping a user override needs a whole-section write, and a
                // non-object root has no patch to merge into.
                try await client.replaceSettings(namespace: ns, section: section)
            } else {
                var patch: [String: JSONValue] = [:]
                for key in dirty {
                    patch[key] = section[key] ?? .null
                }
                try await client.updateSettings(namespace: ns, patch: .object(patch))
            }
            dirtyKeys[ns] = nil
            resetKeys[ns] = nil
            drafts[ns] = nil
            saveStates[ns] = .saved
            // Read the section back so revision and resolved values stay honest.
            // Skipped while another namespace is still mid-edit to avoid
            // disturbing drafts.
            if (dirtyKeys.values.allSatisfy(\.isEmpty)) {
                await reloadDocument()
            }
        } catch {
            saveStates[ns] = .failed(Self.describe(error))
        }
    }

    private func reloadDocument() async {
        guard let client = store?.client else { return }
        guard let raw = try? await client.settings() else { return }
        adopt(SettingsDocument(raw: raw))
    }

    // MARK: - Credentials

    private func loadCredentials() async {
        guard let client = store?.client else { return }
        let uses = credentialUses()
        guard !uses.isEmpty else {
            credentials = []
            credentialsPhase = .loaded
            return
        }
        if credentials.isEmpty { credentialsPhase = .loading }
        do {
            var described: [JSONValue: JSONValue] = [:]
            let names = uses.keys.sorted()
            // describeCredential caps a single call at 64 references.
            for chunk in stride(from: 0, to: names.count, by: 64).map({ Array(names[$0 ..< min($0 + 64, names.count)]) }) {
                let answer = try await client.describeCredentials(refs: chunk.map { .string($0) })
                for (key, value) in answer.objectValue ?? [:] {
                    described[.string(key)] = value
                }
            }
            credentials = names.map { name in
                let info = described[.string(name)] ?? .object([:])
                return CredentialRow(
                    ref: name,
                    configured: info["configured"]?.boolValue ?? false,
                    source: info["source"]?.stringValue,
                    writable: info["writable"]?.boolValue ?? false,
                    usedBy: uses[name] ?? []
                )
            }
            credentialsPhase = .loaded
        } catch {
            credentialsPhase = .failed(Self.describe(error))
        }
    }

    /// Maps each credential reference to the settings rows that use it.
    private func credentialUses() -> [String: [String]] {
        var uses: [String: [String]] = [:]
        for namespace in namespaces {
            for slot in namespace.secrets {
                guard let ref = namespace.credentialRef(forSecretAt: slot.path) else { continue }
                uses[ref.name, default: []].append("\(namespace.title) · \(slot.path.joined(separator: "."))")
            }
        }
        return uses
    }

    /// Stores a credential value. The value never round-trips back.
    func setCredential(ref: String, value: String) async throws {
        guard let client = store?.client else { throw DSHTransportError.notAuthenticated(String(localized: "尚未连接")) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DSHTransportError.malformedResponse(String(localized: "密钥不能为空")) }
        try await client.setCredential(ref: .string(ref), value: trimmed)
        await loadCredentials()
        await reloadDocument()
    }

    func clearCredential(ref: String) async throws {
        guard let client = store?.client else { throw DSHTransportError.notAuthenticated(String(localized: "尚未连接")) }
        try await client.unsetCredential(ref: .string(ref))
        await loadCredentials()
        await reloadDocument()
    }

    // MARK: - About

    private func loadAbout() async {
        var facts = About.empty
        facts.appVersion = ConnectionStore.appVersion
        facts.writable = document?.writable ?? false
        facts.hasDocument = document?.hasDocument ?? false
        // The host publishes its home on the event stream, so prefer that and
        // fall back to whatever the connection recorded.
        if let home = store?.hostHome, !home.isEmpty {
            facts.hostHome = home
        } else if case .connected(let home) = store?.state {
            facts.hostHome = home
        }

        let derived = Self.endpoint(from: store)
        facts.endpoint = derived.endpoint
        facts.transport = derived.transport

        // A relay connector reports its own identity and the local DSH port on
        // its status stream, which is the closest thing to an endpoint the
        // protocol exposes.
        if let link = store?.client?.carrier as? LinkCarrier {
            facts.transport = .relay
            if let status = await Self.firstStatus(from: link) {
                facts.connectorName = status.info?["name"]?.stringValue
                facts.connectorPort = status.info?["dshPort"]?.intValue
                facts.hostVersion = Self.version(in: status.info)
            }
        }
        about = facts
    }

    /// Reads the first status frame that carries host information, with a short
    /// deadline so a silent connector cannot hold up the screen.
    private static func firstStatus(from link: LinkCarrier) async -> LinkCarrier.HostStatus? {
        let stream = await link.statusStream()
        return await withTaskGroup(of: LinkCarrier.HostStatus?.self) { group in
            group.addTask {
                for await status in stream where status.info != nil {
                    return status
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1.5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Finds a version-looking string in a relay status payload.
    ///
    /// DSH does not currently expose a host version over the client protocol, so
    /// this searches for one anyway: a future connector that reports `version`
    /// shows up here instead of being dropped.
    private static func version(in info: JSONValue?) -> String? {
        guard let object = info?.objectValue else { return nil }
        for (key, value) in object where key.lowercased().contains("version") {
            if let text = value.stringValue, !text.isEmpty { return text }
        }
        for value in object.values {
            if let nested = value.objectValue {
                for (key, inner) in nested where key.lowercased().contains("version") {
                    if let text = inner.stringValue, !text.isEmpty { return text }
                }
            }
        }
        return nil
    }

    /// The endpoint the phone is talking to.
    ///
    /// `ConnectionStore.activeProfile` is authoritative once connected; before
    /// that, a single saved profile is unambiguous enough to name, and anything
    /// less is reported as undetermined rather than guessed.
    private static func endpoint(from store: ConnectionStore?) -> (endpoint: String?, transport: Transport) {
        guard let store else { return (nil, .unknown) }
        if let active = store.activeProfile {
            return (store.activeBaseURL?.absoluteString ?? active.subtitle, active.isDirect ? .direct : .relay)
        }
        let profiles = store.profiles
        let used = profiles.filter { $0.lastConnectedAt != nil }
        let candidate: ConnectionProfile?
        if used.count == 1 {
            candidate = used.first
        } else if used.isEmpty, profiles.count == 1 {
            candidate = profiles.first
        } else {
            candidate = nil
        }
        guard let candidate else { return (nil, .unknown) }
        return (candidate.subtitle, candidate.isDirect ? .direct : .relay)
    }

    // MARK: - Failure copy

    /// Maps a DSH failure onto the desktop client's wording for the same case.
    static func describe(_ error: any Error) -> String {
        if let failure = error as? DSHRPCFailure {
            switch failure.code {
            case "settings-conflict":
                return String(localized: "设置已在其他位置更新。请刷新后重试。")
            case "settings-rejected", "gateway/bad-request", "bad-request":
                return String(localized: "本部署没有接受这些值：\(failure.message)")
            case "credentials/credential-rejected", "credential-rejected":
                return String(localized: "提供方拒绝了这次凭据写入：\(failure.message)")
            case "gateway/lookup-not-found", "settings/unavailable":
                return String(localized: "本部署没有可用的设置提供方。")
            default:
                return failure.message
            }
        }
        return ConnectionStore.describe(error)
    }
}

import DSHKit
import Foundation
import Observation

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
            case .saving: return "保存中…"
            case .saved: return "已保存"
            case .failed: return "保存失败"
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
            case .direct: return "局域网直连"
            case .relay: return "中转"
            case .unknown: return "未确定"
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

    func start() async {
        await load()
        await loadDevices()
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

    func load() async {
        guard let client = store?.client else {
            phase = .failed("尚未连接")
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

    /// Pull-to-refresh: keeps the edited draft of a namespace the user is still
    /// typing into, and adopts everything else from the host.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await load()
    }

    // MARK: - Paired devices

    /// The relay administrator for the live connection, when there is one.
    private var deviceAdmin: RelayDeviceAdmin? {
        guard let link = store?.client?.carrier as? LinkCarrier else { return nil }
        return link.deviceAdmin()
    }

    /// Reads the pairing list from the relay.
    ///
    /// Separate from `load()` on purpose: the settings document comes from the
    /// computer, the device list comes from the relay. One being slow or broken
    /// must not blank the other.
    ///
    /// The section can be opened before the relay connection is up (the sheet
    /// follows the connection, it does not wait for it), so a missing carrier is
    /// retried briefly instead of being treated as "this transport has no
    /// devices" — that distinction is what keeps a direct connection from
    /// showing an empty list.
    func loadDevices(retries: Int = 20, interval: Duration = .milliseconds(250)) async {
        var admin = deviceAdmin
        var attempt = 0
        while admin == nil, attempt < retries, !Task.isCancelled {
            if case .connected = store?.state {} else { break }
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
        devicesAvailable = true
        if devices.isEmpty { devicesPhase = .loading }
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
        guard let seen = device.lastSeenAt else { return "尚未连接过" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return "最后在线 " + formatter.localizedString(for: seen, relativeTo: Date())
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
            saveStates[ns] = .failed("本部署的设置为只读。")
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
        guard let client = store?.client else { throw DSHTransportError.notAuthenticated("尚未连接") }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DSHTransportError.malformedResponse("密钥不能为空") }
        try await client.setCredential(ref: .string(ref), value: trimmed)
        await loadCredentials()
        await reloadDocument()
    }

    func clearCredential(ref: String) async throws {
        guard let client = store?.client else { throw DSHTransportError.notAuthenticated("尚未连接") }
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
                return "设置已在其他位置更新。请刷新后重试。"
            case "settings-rejected", "gateway/bad-request", "bad-request":
                return "本部署没有接受这些值：\(failure.message)"
            case "credentials/credential-rejected", "credential-rejected":
                return "提供方拒绝了这次凭据写入：\(failure.message)"
            case "gateway/lookup-not-found", "settings/unavailable":
                return "本部署没有可用的设置提供方。"
            default:
                return failure.message
            }
        }
        return ConnectionStore.describe(error)
    }
}

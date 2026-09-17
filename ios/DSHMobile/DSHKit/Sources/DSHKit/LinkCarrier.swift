import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How to reach a DSH host through a relay.
public struct LinkConfiguration: Sendable, Hashable {
    /// Relay origin, e.g. `https://relay.example.com`.
    public var relayURL: URL
    /// The agent (computer) to route to.
    public var agentId: String
    /// The long-lived device credential minted by pairing.
    public var deviceToken: String

    public init(relayURL: URL, agentId: String, deviceToken: String) {
        self.relayURL = relayURL
        self.agentId = agentId
        self.deviceToken = deviceToken
    }

    /// The WebSocket endpoint frames are tunnelled over.
    ///
    /// The relay may be mounted under a path prefix (for example
    /// `https://host/dsh-link`) so it can share an existing domain and its
    /// certificate without a DNS change. The prefix is therefore *appended to*,
    /// never replaced.
    var socketURL: URL? {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        components?.scheme = relayURL.scheme == "https" ? "wss" : "ws"
        components?.path = Self.appending(path: "/link/device", to: relayURL)
        components?.queryItems = [URLQueryItem(name: "agentId", value: agentId)]
        return components?.url
    }

    /// Joins a relay-relative path onto the configured base path.
    ///
    /// A relay addressed as `https://host` and one addressed as
    /// `https://host/prefix` both produce a correct endpoint URL.
    public static func appending(path suffix: String, to base: URL) -> String {
        let prefix = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !prefix.isEmpty else { return suffix }
        return "/\(prefix)\(suffix)"
    }

    /// Normalises a relay address into its HTTP form.
    ///
    /// A relay advertises its WebSocket origin (`wss://…`) because that is what
    /// the connector dials, but the same host also serves the pairing HTTP API.
    /// Storing one canonical form means `socketURL` and the pairing call always
    /// agree on the mount prefix, and only the scheme is mapped per use.
    public static func normalizedRelayURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        case "http", "https": break
        case .none: components.scheme = "https"
        default: return nil
        }
        return components.url
    }
}

/// Carrier that tunnels the DSH protocol through a relay.
///
/// This is the path that makes a machine without a public IP reachable: the
/// computer's connector dials out to the relay, the phone dials out to the same
/// relay, and the relay forwards frames between them. From the `DSHClient`'s
/// point of view this carrier is indistinguishable from `HTTPCarrier`.
///
/// One WebSocket carries everything — unary calls and every logical stream —
/// so a phone on cellular pays one connection setup instead of one per request.
public actor LinkCarrier: DSHCarrier {
    /// Frames the host half sends.
    private struct IncomingFrame: Decodable {
        let t: String
        let id: String?
        let ok: Bool?
        let value: JSONValue?
        let error: DSHRPCFailure?
        let info: JSONValue?
        let code: String?
        let message: String?
        let fatal: Bool?
    }

    private struct RequestFrame<Args: Encodable & Sendable>: Encodable {
        let t = "req"
        let id: String
        let method: String
        let args: Args
    }

    private struct OpenFrame<Args: Encodable & Sendable>: Encodable {
        let t = "open"
        let id: String
        let endpoint: String
        let args: Args
    }

    private struct IdFrame: Encodable {
        let t: String
        let id: String
    }

    private struct EventResultFrame: Encodable {
        let t = "eventResult"
        let id: String
        let result: JSONValue
    }

    /// How the connector last reported itself, for the connection UI.
    public struct HostStatus: Sendable, Hashable {
        public var online: Bool
        public var info: JSONValue?
    }

    /// The relay identity this carrier dials with. `nonisolated` so the device-admin
    /// helper can be built without hopping onto the actor.
    nonisolated let configuration: LinkConfiguration
    private let session: URLSession
    private let timeout: Duration
    private let reconnect: ReconnectPolicy

    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeatLoop: Task<Void, Never>?
    private var connectWaiters: [CheckedContinuation<Void, any Error>] = []

    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var streams: [String: AsyncThrowingStream<JSONValue, any Error>.Continuation] = [:]
    private var counter: UInt64 = 0
    private var isClosed = false

    private var statusObservers: [UUID: AsyncStream<HostStatus>.Continuation] = [:]
    private var lastStatus = HostStatus(online: false, info: nil)

    /// - Parameters:
    ///   - configuration: relay origin, target agent, and device credential.
    ///   - session: injected for tests; a dedicated ephemeral session by default.
    ///   - timeout: deadline for one unary call.
    ///   - reconnect: backoff schedule applied when the relay connection drops.
    public init(
        configuration: LinkConfiguration,
        session: URLSession? = nil,
        timeout: Duration = .seconds(60),
        reconnect: ReconnectPolicy = .default
    ) {
        self.configuration = configuration
        self.timeout = timeout
        self.reconnect = reconnect
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Starts connecting without waiting, so the UI can render immediately.
    public func connect() {
        guard !isClosed else { return }
        Task { try? await ensureConnected() }
    }

    /// A stream of the connector's online/offline state.
    ///
    /// A relay connection can be up while the computer's connector is down;
    /// the UI needs to distinguish "no network" from "your Mac is asleep".
    public func statusStream() -> AsyncStream<HostStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HostStatus>.makeStream()
        statusObservers[id] = continuation
        continuation.yield(lastStatus)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStatusObserver(id) }
        }
        return stream
    }

    private func removeStatusObserver(_ id: UUID) {
        statusObservers[id] = nil
    }

    // MARK: - DSHCarrier

    public func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String,
        args: Args,
        as valueType: Value.Type
    ) async throws -> Value {
        let value = try await performUnary(method: method, args: args)
        let data = try JSONEncoder().encode(value)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw DSHTransportError.malformedResponse(
                "\(method): could not decode \(Value.self) from \(data.count) bytes — \(error)"
            )
        }
    }

    public func stream<Args: Encodable & Sendable>(
        endpoint: String,
        args: Args
    ) async -> AsyncThrowingStream<JSONValue, any Error> {
        do {
            try await ensureConnected()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        counter += 1
        let streamId = "r\(counter)"
        let (stream, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        streams[streamId] = continuation
        continuation.onTermination = { [weak self] reason in
            guard let self else { return }
            // A caller-driven cancel must reach the host so the session stops
            // being observed; a normal finish has already ended it host-side.
            if case .cancelled = reason {
                Task { await self.sendCancel(streamId: streamId) }
            } else {
                Task { await self.forgetStream(streamId: streamId) }
            }
        }

        do {
            let frame = OpenFrame(id: streamId, endpoint: endpoint, args: args)
            try await send(frame)
        } catch {
            streams[streamId] = nil
            continuation.finish(throwing: error)
        }
        return stream
    }

    public func eventResult(_ result: JSONValue) async throws {
        // The connector correlates results by its own bookkeeping, so an id is
        // only needed to keep the frame shape uniform.
        counter += 1
        try await send(EventResultFrame(id: "e\(counter)", result: result))
    }

    public func close() async {
        isClosed = true
        receiveLoop?.cancel()
        heartbeatLoop?.cancel()
        receiveLoop = nil
        heartbeatLoop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        let outstandingPending = pending
        pending.removeAll()
        for (_, continuation) in outstandingPending {
            continuation.resume(throwing: DSHTransportError.carrierClosed)
        }
        let outstandingStreams = streams
        streams.removeAll()
        for (_, continuation) in outstandingStreams {
            continuation.finish(throwing: DSHTransportError.carrierClosed)
        }
        for observer in statusObservers.values {
            observer.finish()
        }
        statusObservers.removeAll()
        session.invalidateAndCancel()
    }

    // MARK: - Internals

    private func performUnary<Args: Encodable & Sendable>(
        method: String,
        args: Args
    ) async throws -> JSONValue {
        try await ensureConnected()

        counter += 1
        let id = "u\(counter)"
        let frame = RequestFrame(id: id, method: method, args: args)
        let deadline = timeout

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
            Task {
                // Register before sending: the connector can answer within the
                // same runloop turn, and a reply for an unregistered id would
                // otherwise be dropped and hang the caller.
                await self.registerPending(id: id, continuation: continuation)
                Task { [weak self] in
                    try? await Task.sleep(for: deadline)
                    await self?.failPending(id: id, error: DSHTransportError.timedOut(method: method))
                }
                do {
                    try await self.send(frame)
                } catch {
                    await self.failPending(id: id, error: error)
                }
            }
        }
    }

    private func registerPending(id: String, continuation: CheckedContinuation<JSONValue, any Error>) {
        // A deadline may have already fired between registration and send.
        guard !isClosed else {
            continuation.resume(throwing: DSHTransportError.carrierClosed)
            return
        }
        pending[id] = continuation
    }

    private func removePending(id: String) {
        pending[id] = nil
    }

    /// Resumes one pending call exactly once, failing it with `error`.
    private func failPending(id: String, error: any Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func send(_ frame: some Encodable) async throws {
        guard let socket else {
            throw DSHTransportError.unreachable("relay connection is not established")
        }
        let data = try JSONEncoder().encode(frame)
        // The relay speaks JSON text frames; binary frames are reserved.
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func sendCancel(streamId: String) async {
        streams[streamId] = nil
        try? await send(IdFrame(t: "cancel", id: streamId))
    }

    private func forgetStream(streamId: String) {
        streams[streamId] = nil
    }

    private func ensureConnected() async throws {
        if isClosed { throw DSHTransportError.carrierClosed }
        if let socket, socket.state == .running { return }
        try await openSocket()
    }

    private func openSocket() async throws {
        guard let url = configuration.socketURL else {
            throw DSHTransportError.unreachable("relay URL is not usable: \(configuration.relayURL)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.deviceToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        // Session history snapshots arrive as one large frame; the 1 MiB
        // default would drop them with an opaque "Message too long".
        task.maximumMessageSize = MuxConnection.maximumMessageSize
        task.resume()
        socket = task
        startReceiveLoop(on: task)
        startHeartbeat(on: task)
    }

    private func startReceiveLoop(on task: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        await self.handle(Data(text.utf8))
                    case .data(let data):
                        await self.handle(data)
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self else { return }
                    if await self.isClosed { return }
                    await self.handleDisconnect(reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func startHeartbeat(on task: URLSessionWebSocketTask) {
        heartbeatLoop?.cancel()
        heartbeatLoop = Task { [weak self] in
            guard let interval = self?.reconnect.heartbeat else { return }
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                tick += 1
                await self?.sendPing(tick: tick)
            }
        }
    }

    private func sendPing(tick: Int) {
        socket?.sendPing { _ in }
        if tick % 3 == 0 {
            Task { try? await send(PingFrame(ts: Date().timeIntervalSince1970)) }
        }
    }

    private struct PingFrame: Encodable {
        let t = "ping"
        let ts: TimeInterval
    }

    private func handleDisconnect(reason: String) async {
        receiveLoop = nil
        heartbeatLoop?.cancel()
        heartbeatLoop = nil
        socket = nil
        updateStatus(HostStatus(online: false, info: nil))

        let outstandingPending = pending
        pending.removeAll()
        for (_, continuation) in outstandingPending {
            continuation.resume(throwing: DSHTransportError.unreachable(reason))
        }
        let outstandingStreams = streams
        streams.removeAll()
        for (_, continuation) in outstandingStreams {
            continuation.finish(throwing: DSHTransportError.unreachable(reason))
        }

        // Re-establish in the background so the next user action is not the one
        // that pays for the reconnect.
        guard !isClosed else { return }
        Task {
            var attempt = 0
            while !Task.isCancelled && !isClosed {
                let delay = reconnect.delay(forAttempt: attempt)
                try? await Task.sleep(for: delay)
                if isClosed { return }
                do {
                    try await openSocket()
                    return
                } catch {
                    attempt += 1
                }
            }
        }
    }

    private func updateStatus(_ status: HostStatus) {
        lastStatus = status
        for observer in statusObservers.values {
            observer.yield(status)
        }
    }

    private func handle(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(IncomingFrame.self, from: data) else { return }

        switch frame.t {
        case "res":
            guard let id = frame.id, let continuation = pending.removeValue(forKey: id) else { return }
            if frame.ok == true {
                continuation.resume(returning: frame.value ?? .null)
            } else {
                continuation.resume(
                    throwing: frame.error ?? DSHRPCFailure(code: "relay/failed", message: "the connector reported a failure")
                )
            }

        case "item":
            guard let id = frame.id, let continuation = streams[id] else { return }
            continuation.yield(frame.value ?? .null)

        case "end":
            guard let id = frame.id, let continuation = streams.removeValue(forKey: id) else { return }
            continuation.finish()

        case "streamError":
            guard let id = frame.id, let continuation = streams.removeValue(forKey: id) else { return }
            continuation.finish(
                throwing: DSHTransportError.streamFailed(
                    frame.error ?? DSHRPCFailure(code: "relay/stream-failed", message: "stream failed")
                )
            )

        case "event":
            // Broadcast host events are fanned out to whichever `$events`
            // stream this device opened.
            for continuation in streams.values {
                continuation.yield(frame.value ?? .null)
            }

        case "hostStatus":
            var online = false
            if let flag = frame.info?["online"]?.boolValue { online = flag }
            updateStatus(HostStatus(online: online, info: frame.info))

        case "pong", "ping":
            break

        case "error":
            let failure = DSHRPCFailure(
                code: frame.code ?? "relay/error",
                message: frame.message ?? "the relay reported an error"
            )
            if frame.fatal == true {
                Task { await self.handleDisconnect(reason: failure.message) }
            }

        default:
            break
        }
    }
}

/// Backoff schedule for re-establishing a dropped relay connection.
public struct ReconnectPolicy: Sendable, Hashable {
    public var initial: Duration
    public var maximum: Duration
    public var multiplier: Double
    public var jitter: Double
    public var heartbeat: Duration

    public init(
        initial: Duration = .seconds(1),
        maximum: Duration = .seconds(30),
        multiplier: Double = 2,
        jitter: Double = 0.2,
        heartbeat: Duration = .seconds(20)
    ) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
        self.jitter = jitter
        self.heartbeat = heartbeat
    }

    public static let `default` = ReconnectPolicy()

    /// The delay before reconnect attempt `attempt` (zero-based).
    public func delay(forAttempt attempt: Int) -> Duration {
        let base = initial.seconds * pow(multiplier, Double(attempt))
        let capped = min(base, maximum.seconds)
        let spread = capped * jitter
        let offset = Double.random(in: -spread...spread)
        return .seconds(max(0.1, capped + offset))
    }
}

extension Duration {
    /// This duration in seconds, for arithmetic on backoff schedules.
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

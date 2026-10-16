import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// DLP v1 帧类型词表 —— 与 `docs/relay-contract.json` 同步（测试 `DLPContractTests` 钉住）。
///
/// 这张表是**活的**：它既被编码侧引用（下面几个 `Encodable` 结构体的 `t`），
/// 也被解码侧当成过滤器。给 device 方向增加一个能处理的帧类型，必须同时更新这里，
/// 而这里被契约测试钉住，契约又被三端共享。
enum DLPFrames {
    static let request = "req"
    static let open = "open"
    static let cancel = "cancel"
    static let eventResult = "eventResult"
    static let ping = "ping"
    static let deviceToAgent: Set<String> = [request, open, cancel, eventResult, ping, "hello"]
    static let agentToDevice: Set<String> = ["res", "item", "end", "streamError", "event", "hostStatus", "pong", "error"]
    static let idFrames: Set<String> = [request, open, cancel, "res", "item", "end", "streamError", eventResult]
}

/// DLP 协议版本（`relay/dlp.py:PROTOCOL_VERSION`）。
let dlpProtocolVersion = 1

/// 单帧字节上限，与 DSH 的图片附件上限对齐（`relay/dlp.py:MAX_FRAME_BYTES`）。
let dlpMaxFrameBytes = 32 * 1024 * 1024

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

/// 这条 carrier 真正用到的那几个 socket 能力。
///
/// 抽出来只为一件事：**"断开时必须 cancel" 得能被单测钉住**。
/// `URLSessionWebSocketTask` 在单测里造不出真连接，而 2026-10-12 线上那个问题
/// 恰恰出在"丢引用 ≠ 关连接"——引用没了，URLSession 仍替它回 Pong，中转那边这条
/// 设备链路就一直挂着（实测：丢引用后 46 秒没死，跨过 3 个心跳）。断开一次留一条
/// 僵尸链路，重连一次再多一条，中转到设备的下行帧按 deviceId 归到最后一条，
/// 于是就出现"一个 deviceId 十几条 socket、同毫秒一起被关"。
protocol RelaySocketTask: AnyObject, Sendable {
    /// 是否已经可以收发（`URLSessionWebSocketTask.state == .running`）。
    var isRunning: Bool { get }
    var maximumMessageSize: Int { get set }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: RelaySocketTask {
    var isRunning: Bool { state == .running }
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
        let t = DLPFrames.request
        let id: String
        let method: String
        let args: Args
    }

    private struct OpenFrame<Args: Encodable & Sendable>: Encodable {
        let t = DLPFrames.open
        let id: String
        let endpoint: String
        let args: Args
    }

    private struct IdFrame: Encodable {
        let t: String
        let id: String
    }

    private struct EventResultFrame: Encodable {
        let t = DLPFrames.eventResult
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
    /// internal（不是 private）：同一模块的诊断半边要问它「观察者挂上了没有」。
    let session: URLSession
    private let timeout: Duration
    private let reconnect: ReconnectPolicy
    /// 造 socket 的工厂。线上是 `session.webSocketTask(with:)`；单测注入替身，
    /// 这样"断开时有没有 cancel"可以被断言（见 `RelaySocketTask`）。
    private let makeSocket: @Sendable (URLRequest) -> any RelaySocketTask

    private var socket: (any RelaySocketTask)?
    /// 跨掉线保留的重连轮次（spec 022 FR-001）：只有**稳定存活过**的链路才清零。
    /// 2026-10-13 真机风暴里每条 socket 只活 0.8 秒，每次掉线都从 0 重开会把节奏钉在 1 秒一次。
    private var reconnectAttempt = 0
    /// 当前这条 socket 是什么时候建起来的，用于判断"活得够不够久"。
    private var socketOpenedAt: Date?
    /// 是否有一拨正在飞（T020 单飞）：在飞期间进 `ensureConnected` 的调用挂进
    /// `connectWaiters` 等同一个结果，而不是各开一条 socket 互相顶替。
    private var dialInFlight = false
    /// Puts back a frame the relay wrote as several WebSocket messages.
    private var assembler = FrameAssembler()
    private var receiveLoop: Task<Void, Never>?
    private var heartbeatLoop: Task<Void, Never>?
    private var connectWaiters: [CheckedContinuation<Void, any Error>] = []

    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var streams: [String: AsyncThrowingStream<JSONValue, any Error>.Continuation] = [:]
    private var counter: UInt64 = 0
    private var isClosed = false

    private var statusObservers: [UUID: AsyncStream<HostStatus>.Continuation] = [:]
    private var lastStatus = HostStatus(online: false, info: nil)

    /// socket 自身的三态（T005b，US3）：与 `HostStatus`（连接器活没活）分开——
    /// Store 靠它等 Carrier 自愈，而不是抢着拨号。
    public enum SocketState: Sendable, Equatable {
        case up
        case reconnecting
        case closed
    }

    private var socketStateObservers: [UUID: AsyncStream<SocketState>.Continuation] = [:]
    private var lastSocketState: SocketState = .reconnecting

    /// App 侧的生命周期流水（`app.*`）。**永远不参与连接主路径**：记录失败只记一次，
    /// 调用点不 await 结果、也不因为它改变状态（spec 020 的 FR-011/FR-018）。
    public let diagnostics: LinkDiagnostics

    /// - Parameters:
    ///   - configuration: relay origin, target agent, and device credential.
    ///   - session: injected for tests; a dedicated ephemeral session by default.
    ///   - timeout: deadline for one unary call.
    ///   - reconnect: backoff schedule applied when the relay connection drops.
    ///   - diagnostics: 生命周期流水；不传就只留内存（不落盘时不该悄悄写文件）。
    public init(
        configuration: LinkConfiguration,
        session: URLSession? = nil,
        timeout: Duration = .seconds(60),
        reconnect: ReconnectPolicy = .default,
        diagnostics: LinkDiagnostics = LinkDiagnostics()
    ) {
        self.configuration = configuration
        self.timeout = timeout
        self.reconnect = reconnect
        self.diagnostics = diagnostics
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            // 带上观察者：`transport-up` / `transport-closed` 只有系统回调能给（见
            // LinkCarrier+Diagnostics.swift 的说明）。它只持有 diagnostics，不持有 carrier。
            self.session = URLSession(configuration: configuration,
                                      delegate: LinkSocketObserver(diagnostics: diagnostics),
                                      delegateQueue: nil)
        }
        let session = self.session
        self.makeSocket = { session.webSocketTask(with: $0) }
    }

    /// 单测入口：注入 socket 工厂（`@testable import DSHKit` 可见）。
    ///
    /// 存在的理由见 `RelaySocketTask`：断开路径是否真的 cancel 了 socket，
    /// 只有把 socket 换成可观测的替身才断言得了。
    init(
        configuration: LinkConfiguration,
        timeout: Duration = .seconds(60),
        reconnect: ReconnectPolicy = .default,
        diagnostics: LinkDiagnostics = LinkDiagnostics(),
        makeSocket: @escaping @Sendable (URLRequest) -> any RelaySocketTask
    ) {
        self.configuration = configuration
        self.timeout = timeout
        self.reconnect = reconnect
        self.diagnostics = diagnostics
        self.session = URLSession(configuration: .ephemeral)
        self.makeSocket = makeSocket
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

    /// 订阅 socket 三态（T005b）。首帧回放当前状态，与 `statusStream()` 同约定。
    public func socketStateStream() -> AsyncStream<SocketState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SocketState>.makeStream()
        socketStateObservers[id] = continuation
        continuation.yield(lastSocketState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSocketStateObserver(id) }
        }
        return stream
    }

    private func removeSocketStateObserver(_ id: UUID) {
        socketStateObservers[id] = nil
    }

    private func updateSocketState(_ state: SocketState) {
        lastSocketState = state
        for observer in socketStateObservers.values {
            observer.yield(state)
        }
    }

    // MARK: - DSHCarrier

    public func unary<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String,
        args: Args,
        as valueType: Value.Type
    ) async throws -> Value {
        // 诊断计时（spec 020 的 FR-010）：只影响流水，不影响这条调用本身。
        // 失败也要记（不记的话"看不见的超时"就还是看不见）。
        let startedAt = Date()
        await diagnostics.beginInteraction(method: method)
        do {
            let value = try await performUnary(method: method, args: args)
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(Value.self, from: data)
            await diagnosticsNoteInteraction(method: method,
                                             elapsedMs: Self.elapsedMs(since: startedAt),
                                             bytes: data.count, ok: true)
            return decoded
        } catch {
            // 失败也要留痕，而且**要能分辨**：`ok: false` + 错误码，而不是一个 bytes: 0 的谜。
            let code = (error as? DSHRPCFailure)?.code ?? String(describing: type(of: error))
            await diagnosticsNoteInteraction(method: method,
                                             elapsedMs: Self.elapsedMs(since: startedAt), bytes: 0,
                                             ok: false, errorCode: code)
            if let error = error as? DecodingError {
                throw DSHTransportError.malformedResponse(
                    "\(method): could not decode \(Value.self) — \(error)"
                )
            }
            throw error
        }
    }

    /// 毫秒取整（诊断用；不与任何判断挂钩）。
    static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
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
        // 显式关闭：这是主动动作，退避清零（spec 022 FR-002）。
        reconnectAttempt = 0
        socketOpenedAt = nil
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
        updateSocketState(.closed)
        for observer in socketStateObservers.values {
            observer.finish()
        }
        socketStateObservers.removeAll()
        // 还在等一拨结果的调用：关门了，别让它们吊着（T020）。
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: DSHTransportError.carrierClosed)
        }
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
                    guard let self else { return }
                    await self.failPending(id: id, error: DSHTransportError.timedOut(method: method))
                    // A frame that was still arriving when its call gave up
                    // cannot be un-arrived: the relay keeps writing the rest of
                    // it, and those messages would be glued onto the next frame
                    // — after which nothing on this socket parses. Dropping the
                    // connection is the only way back to a known boundary, and
                    // the caller's retry resumes from what it already saved.
                    await self.dropIfHoldingPartialFrame(
                        reason: "\(method) timed out while a frame was still arriving"
                    )
                }
                do {
                    try await self.send(frame)
                } catch {
                    await self.failPending(id: id, error: error)
                }
            }
        }
    }

    /// Drops a connection whose frame boundary is no longer knowable.
    private func dropIfHoldingPartialFrame(reason: String) async {
        guard assembler.isHoldingPartialFrame else { return }
        await handleDisconnect(reason: reason)
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
        try? await send(IdFrame(t: DLPFrames.cancel, id: streamId))
    }

    private func forgetStream(streamId: String) {
        streams[streamId] = nil
    }

    private func ensureConnected() async throws {
        if isClosed { throw DSHTransportError.carrierClosed }
        if let socket, socket.isRunning { return }
        try await openSocketSingleFlight()
    }

    /// 拨号单飞（T020，US3 AC1）：一拨在飞时，再进来的调用挂起等同一个结果，
    /// 不再各开一条 socket。`openSocket()` 在 `await diagnosticsDialStarted()` 有悬停点，
    /// 没有这道闸，自愈 Task、探活与用户请求会并发进入、互相 cancel 对方刚建好的
    /// socket——中转记 attach-again、两边收 1001，正是 2026-10-14 复发的点火器。
    private func openSocketSingleFlight() async throws {
        if dialInFlight {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connectWaiters.append(continuation)
            }
            return
        }
        dialInFlight = true
        do {
            try await openSocket()
            dialInFlight = false
            let waiters = connectWaiters
            connectWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        } catch {
            dialInFlight = false
            let waiters = connectWaiters
            connectWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: error) }
            throw error
        }
    }

    private func openSocket() async throws {
        guard let url = configuration.socketURL else {
            throw DSHTransportError.unreachable("relay URL is not usable: \(configuration.relayURL)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.deviceToken)", forHTTPHeaderField: "Authorization")
        // 换 socket 之前先把旧的退掉。**丢引用不等于关连接**：`URLSessionWebSocketTask`
        // 只被丢引用时会一直活着（并继续替我们回 Pong），中转会把同一个 deviceId 记成
        // 又一条 attach，旧的那条就变成僵尸链路——2026-10-12 线上一个 deviceId 攒到 14 条。
        socket?.cancel(with: .goingAway, reason: nil)
        // 拨号开始的时刻必须在 `resume()` 之前记：这是"连上耗时"的起点，
        // 也是判断"拨号卡住"（有 start 没有 transport-up）的唯一依据。
        await diagnosticsDialStarted()
        let task = makeSocket(request)
        // Session history snapshots arrive as one large frame; the 1 MiB
        // default would drop them with an opaque "Message too long".
        task.maximumMessageSize = MuxConnection.maximumMessageSize
        task.resume()
        socket = task
        assembler.reset()
        startReceiveLoop(on: task)
        startHeartbeat(on: task)
        socketOpenedAt = Date()
        updateSocketState(.up)
        #if DEBUG
        scheduleFlapIfRequested()
        #endif
    }

    #if DEBUG
    /// `-DSHLinkFlap <次数>`：连着之后按次数把链路**从这一侧**掐断，用来在仿真器里
    /// 复现"链路抖动"（仿真器没有蜂窝/Wi-Fi 切换，真实断链只能这样造）。
    ///
    /// 为什么放在协议层而不是 App：`-DSHInterruptDownload` 已经在 `DSHFilesDomain`
    /// 里读过启动参数，同一口径；而"断链后能不能自己接回来、会不会叠出第二条 socket"
    /// 正是 `LinkCarrier` 自己的契约，用例要压的就是它。
    ///
    /// 每次掐断间隔 1.5 秒：让界面先走到"已连接"，再观察它掉线、重拨、恢复。
    private func scheduleFlapIfRequested() {
        let wanted = Self.flapBudget()
        guard wanted > 0 else { return }
        let done = Self.flapDone.withLock { count -> Int in
            count += 1
            return count
        }
        guard done <= wanted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            await self.handleDisconnect(reason: "flap-hook \(done)/\(wanted)")
        }
    }

    /// 读取 `-DSHLinkFlap <次数>`；没有就是 0。
    static func flapBudget() -> Int {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-DSHLinkFlap"),
              index + 1 < arguments.count,
              let value = Int(arguments[index + 1])
        else { return 0 }
        return max(0, value)
    }

    private static let flapDone = LockedCounter()
    #endif

    private func startReceiveLoop(on task: any RelaySocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        await self.receive(Data(text.utf8))
                    case .data(let data):
                        // The relay speaks JSON text frames and reserves binary
                        // ones; half a reassembled frame followed by binary means
                        // the stream cannot be trusted.
                        await self.receiveBinary(data)
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self else { return }
                    if await self.isClosed { return }
                    // 这条 loop 守的 socket 已经不是当前那条了（比如它已经被
                    // `handleDisconnect` 退掉、新 socket 也建起来了）。这只是旧
                    // socket 的残响，拿它去动链路状态会把刚建好的新连接一起拆掉，
                    // 还会再拉一条重连循环——两条重连循环各自开一条 socket，正是
                    // 这次要修的那种泄漏。
                    if await !self.isCurrent(task) { return }
                    await self.handleDisconnect(reason: error.localizedDescription, from: task)
                    return
                }
            }
        }
    }

    private func startHeartbeat(on task: any RelaySocketTask) {
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
        let t = DLPFrames.ping
        let ts: TimeInterval
    }

    /// 这条 loop 守的 socket 还是当前那条吗。
    private func isCurrent(_ task: any RelaySocketTask) -> Bool {
        socket === task
    }

    /// 收掉一条链路并安排重连。
    ///
    /// `from` 是"谁报告自己断了"：只有当前那条 socket 的断开才算数，旧 socket 迟到的
    /// 错误（它的 `receive()` 在 `cancel` 之后才抛）必须被忽略，否则会把新连接拆掉
    /// 并叠加出第二条重连循环。`nil` 表示调用方是当前 socket 自己的收发路径。
    private func handleDisconnect(reason: String, from task: (any RelaySocketTask)? = nil) async {
        if let task, socket !== task { return }
        assembler.reset()
        receiveLoop = nil
        heartbeatLoop?.cancel()
        heartbeatLoop = nil
        // **必须 cancel**：只置 nil 的话这条 `URLSessionWebSocketTask` 会继续活着，
        // 中转那边同 deviceId 的旧链路就一直挂着（丢引用实测能活过 46 秒、跨 3 个心跳）。
        socket?.cancel(with: .goingAway, reason: nil)
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
        // **退避跨掉线保留，只有稳定存活过才清零**（spec 022 FR-001）。
        // 现场数据：每条 socket 只活约 0.8 秒；若照旧"每次掉线从 attempt 0 重开"，
        // 节奏永远是初始的 1 秒，两分钟内能接入 100+ 次（2026-10-13 实测 111 次）。
        let livedFor: TimeInterval? = socketOpenedAt.map { Date().timeIntervalSince($0) }
        socketOpenedAt = nil
        if let livedFor {
            let wasStable = livedFor >= ReconnectBackoff.stabilityWindow
            // T019：拨号**成功**但转眼就掉的连接也算一次失败轮次。旧逻辑只在拨号抛错时
            // 递增 attempt——风暴恰恰是"每次都能拨通、0.8 秒后被顶掉"，于是 attempt 永远 0、
            // 节奏钉死在 1 秒（2026-10-14 11:18/11:24 两次复发，每条 link.backoff 都是 attempt:0）。
            reconnectAttempt = wasStable ? 0 : reconnectAttempt + 1
            let nextDelay = reconnect.delay(forAttempt: reconnectAttempt)
            await diagnostics.record(kind: "link.backoff", detail: [
                "attempt": .int(reconnectAttempt),
                "livedMs": .int(Int(livedFor * 1000)),
                "nextMs": .int(Int(nextDelay.seconds * 1000)),
                "reset": .bool(wasStable),
            ])
        }
        guard !isClosed else { return }
        updateSocketState(.reconnecting)
        Task {
            while !Task.isCancelled && !isClosed {
                let delay = reconnect.delay(forAttempt: reconnectAttempt)
                try? await Task.sleep(for: delay)
                if isClosed { return }
                // 睡醒先看：退避期间探活/用户请求可能已经通过单飞把链路拨回来了，
                // 这时再开一条就是把刚恢复的 socket 顶掉（T020 的另一半）。
                if let socket, socket.isRunning { return }
                do {
                    try await openSocketSingleFlight()
                    return
                } catch {
                    reconnectAttempt += 1
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

    /// Feeds one WebSocket message to the assembler and handles what it completes.
    ///
    /// A message is usually a whole frame. A large one may be a fragment: the
    /// relay writes any device-bound frame over 512 KB as several messages once
    /// the device is over its rate, on the assumption that the client puts the
    /// frame back together. Without this the fragment is dropped as malformed
    /// JSON and its call hangs until its deadline with nothing to show for it.
    ///
    /// A stream that cannot be reassembled is a broken connection, not a reason
    /// to keep buffering: the socket is dropped with a stated reason so every
    /// call waiting on it fails visibly and the reconnect starts.
    private func receive(_ message: Data) async {
        do {
            if let frame = try assembler.feed(message) {
                handle(frame)
            }
        } catch {
            assembler.reset()
            await handleDisconnect(reason: "relay frame could not be reassembled")
        }
    }

    private func receiveBinary(_ message: Data) async {
        if assembler.isHoldingPartialFrame {
            assembler.reset()
            await handleDisconnect(reason: "relay sent binary inside a split frame")
            return
        }
        handle(message)
    }

    private func handle(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(IncomingFrame.self, from: data) else { return }
        // 契约：docs/relay-contract.json。未知 kind 照旧忽略（与 default: break 等价）。
        guard DLPFrames.agentToDevice.contains(frame.t) else { return }

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


#if DEBUG
/// 只在 `-DSHLinkFlap` 下用到的计数器（进程级，跨重拨累计）。放在文件级是因为
/// `LinkCarrier` 的 `#if DEBUG` 成员需要一个类型，而它没有别的用途。
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func withLock<T>(_ body: (inout Int) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
#endif

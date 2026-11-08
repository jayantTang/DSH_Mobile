#if os(iOS)
import DSHConnectionAPI
import DSHCore
import Foundation
import Observation
import UIKit
import DSHKit
import DSHChatDomain

/// Loads and caches the image bytes a session refers to.
///
/// Message and tool-result content carry only a reference — an id, a media
/// type and a size — so something has to fetch the actual bytes and keep them.
/// Before this existed the transcript drew a filename with a photo icon and
/// never showed the picture at all.
/// 025 阶段4b：随聊天单元搬进 `DSHChatUI`。它是转写页（以及它自己的缩略图）读图片的
/// 那一层，装配层只是建一个、放进 environment，所以类型与那四个入口（`attach` /
/// `linkEstablished` / `reset` / `clearAllCached`）是 public。
///
/// **一张图的状态只有一个所有者**：`AttachmentLoadMachine`。这里只负责驱动它——
/// 发起取图、按退避计时、把结局写成 `State`。视图读 `state(_:)`，不读时钟、
/// 不自己判断"该不该再试"。
///
/// 为什么改成这样：旧实现把失败记成一个时间戳（`failures`），界面在渲染时算
/// 「距上次失败不足 15 秒」——15 秒之后没有任何东西叫醒界面，于是一次偶发失败
/// 就把整屏图片永久钉在「图片加载失败」；点重试也只是把同一个请求再发一遍，
/// 上一次若还挂着，await 的仍是那个旧任务。
@MainActor
@Observable
public final class AttachmentImages {

    public init() {}

    /// What the transcript should draw for one picture.
    public enum State: Equatable, Sendable {
        /// Nothing running, nothing failed — a row that just appeared.
        case idle
        /// An attempt is running, or the next one is scheduled.
        case loading
        /// The bytes are decoded and in the cache.
        case loaded
        /// The last attempt failed. `reason` is for diagnostics and the a11y label.
        case failed(reason: String)
    }

    /// The session whose attachments are being shown.
    ///
    /// Assigning it switches to that session's own cache — it does not throw the
    /// pictures away. An earlier version cleared everything here, which was safe
    /// but made every return to a conversation re-download its images; the ids
    /// are content hashes, so keeping them per session is both correct (a
    /// session only ever reads its own bucket) and instant on the way back.
    var sessionId: String? {
        didSet {
            guard sessionId != oldValue else { return }
            pruneSessions()
        }
    }

    /// 解码结果内存 LRU（T029）：key 是 "session|attachmentId"，cost 是位图字节数，
    /// 总量按字节封顶——解码后的位图才是内存大头，按张数限会漏掉「全是 4K 截图」
    /// 的情形。逐出策略交给 NSCache（线程安全，且内存紧张时系统可代为回收）。
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// session → attachment id → what to draw. Written only by the driver below.
    private var states: [String: [String: State]] = [:]

    /// "session|attachment" → the task that owns this picture's retry loop.
    private var drivers: [String: Task<Void, Never>] = [:]
    /// The same key → which attachment and variant that driver is for, so a link
    /// rebuild can restart it without the view being involved.
    private var flights: [String: Flight] = [:]
    /// Guards against a finished driver clearing a newer one's bookkeeping.
    private var driverTokens: [String: Int] = [:]

    private struct Flight {
        let attachmentId: String
        let variant: String?
    }

    /// 解码过的附件的真实像素宽高（T029）：协议事件没带宽高时，首帧按 4:3 占位，
    /// 解码完成把真实尺寸记进这里，下次同一附件直接定高。持久化在 DSHKit 侧。
    private let dimensions = AttachmentDimensions()

    /// 状态桶的会话上限（图片本身由 NSCache 按字节管，不再需要按会话清）。
    private static let sessionLimit = 6

    private var key: String { sessionId ?? "" }

    private func bucketKey(_ session: String, _ attachmentId: String) -> String {
        "\(session)|\(attachmentId)"
    }

    private weak var store: (any ConnectionStatus)?

    public func attach(store: any ConnectionStatus) {
        self.store = store
    }

    /// The decoded image, when it has already been loaded.
    func cached(_ attachmentId: String) -> UIImage? {
        cache.object(forKey: bucketKey(key, attachmentId) as NSString)
    }

    /// The size a previous decode established, when the wire metadata didn't
    /// say — the second source `AttachmentThumbnail` sizes its box from.
    func knownSize(_ attachmentId: String) -> AttachmentDimensions.Size? {
        dimensions.size(scope: scopeId, attachmentId: attachmentId)
    }

    /// What to draw for this picture. A cached bitmap always wins: it is the
    /// truth, and the state map is only the road to it.
    func state(_ attachmentId: String) -> State {
        if cached(attachmentId) != nil { return .loaded }
        return states[key]?[attachmentId] ?? .idle
    }

    /// 丢掉所有内存里的图片（「清除本地缓存」时用；磁盘那份由设置页删）。
    public func clearAllCached() {
        cancelAllDrivers()
        cache.removeAllObjects()
        dimensions.clearAll()
        states.removeAll()
        flights.removeAll()
    }

    /// 链路重建：断线期间的失败不算数，正在退避的尝试也不必等计时器。
    ///
    /// 不再需要「链路代数」当视图 task 的身份：状态机自己会被重启，而状态可观察，
    /// 重绘由状态变化触发。
    public func linkEstablished() {
        var pending: [String: Flight] = [:]
        for (flightKey, flight) in flights {
            switch state(flight.attachmentId) {
            case .loaded: continue
            case .idle, .loading, .failed: pending[flightKey] = flight
            }
        }
        restart(pending)
    }

    /// 取图入口：视图出现（或同一行的附件变了）时调用一次。
    ///
    /// 同一个附件已经在驱动中就等那一个，不另起第二条通路。视图的 `.task` 被
    /// 取消（行滚出屏幕）时驱动随之取消——退避的等待也跟着停，不在后台空转。
    ///
    /// `variant` 标识这份**内容**（大小与媒体类型）：附件 id 是宿主的，若它复用
    /// 同一个 id 换了图，不同的 variant 就是不同的缓存条目，而不是永远拿旧图。
    func begin(_ attachmentId: String, variant: String? = nil) async {
        guard !attachmentId.isEmpty, let sessionId else { return }
        if cached(attachmentId) != nil {
            states[sessionId, default: [:]][attachmentId] = .loaded
            return
        }
        let flightKey = bucketKey(sessionId, attachmentId)
        if let existing = drivers[flightKey] {
            await existing.value
            return
        }
        let driver = startDriver(
            attachmentId: attachmentId, variant: variant, in: sessionId, flightKey: flightKey)
        // 行离屏 → 视图的 task 被取消 → 驱动一起停（退避的等待也停）。
        await withTaskCancellationHandler {
            await driver.value
        } onCancel: {
            driver.cancel()
        }
    }

    /// 用户点了「点按重试」。
    ///
    /// 不是"再发一次同样的请求"：先取消上一次尝试（它可能还挂在网络上），把状态机
    /// 重置成第一次尝试，再立即重来。界面从失败态切回转圈，点下去当场有反馈。
    func retry(_ attachmentId: String) {
        guard let sessionId else { return }
        let flightKey = bucketKey(sessionId, attachmentId)
        let variant = flights[flightKey]?.variant
        states[sessionId, default: [:]][attachmentId] = .idle
        _ = startDriver(attachmentId: attachmentId, variant: variant, in: sessionId, flightKey: flightKey)
    }

    /// 起一条驱动：换 token、取消旧的、登记新的。
    @discardableResult
    private func startDriver(
        attachmentId: String, variant: String?, in session: String, flightKey: String
    ) -> Task<Void, Never> {
        nextToken(for: flightKey)
        drivers[flightKey]?.cancel()
        let token = driverTokens[flightKey] ?? 0
        flights[flightKey] = Flight(attachmentId: attachmentId, variant: variant)
        let driver = Task { [weak self] in
            guard let self else { return }
            await self.drive(attachmentId, variant: variant, in: session, token: token)
        }
        drivers[flightKey] = driver
        return driver
    }

    /// 取当前可用的宿主客户端。DEBUG 钩子 `-DSHHoldAttachmentLink <秒>` 会在第一次
    /// 取图时把「链路未就绪」固定下来，并在 N 秒后走同一条 `linkEstablished` 恢复，
    /// 用来验证「未连接时渲染 → 链路恢复后自动重试」。Release 里没有这个分支。
    private func chatHostForLoad() -> (any ChatHosting)? {
        guard let client = store?.chatHost else { return nil }
        guard Self.holdLinkSeconds > 0 else { return client }
        if holdLinkDeadline == nil {
            holdLinkDeadline = Date().addingTimeInterval(Self.holdLinkSeconds)
            scheduleHoldRelease()
        }
        if let deadline = holdLinkDeadline, Date() < deadline { return nil }
        return client
    }

    /// `-DSHHoldAttachmentLink <秒>`：DEBUG 钩子，把「链路未就绪」固定成 N 秒。
    ///
    /// 注入的只是「客户端不可用」这个条件；N 秒后走的是与真实重连相同的
    /// `linkEstablished`，之后的重跑、缓存、下载与解码都是真实路径。Release 里恒为 0。
    private static let holdLinkSeconds: Double = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHHoldAttachmentLink"),
              index + 1 < arguments.count,
              let seconds = Double(arguments[index + 1])
        else { return 0 }
        return max(0, seconds)
        #else
        return 0
        #endif
    }()

    private var holdLinkDeadline: Date?
    private var holdLinkCountdown: Task<Void, Never>?

    private func scheduleHoldRelease() {
        holdLinkCountdown?.cancel()
        let seconds = Self.holdLinkSeconds
        holdLinkCountdown = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.linkEstablished()
        }
    }

    /// 图片的落盘层：进程一没，内存桶就空了，冷启动会把每张图都重下一遍。
    private let diskCache = AttachmentDiskCache()

    private var scopeId: String { store?.scopeId ?? "unknown" }

    // MARK: - The driver

    /// 一张图的整条生命周期：尝试 → 失败 → 按退避再试 → … → 成功或次数用尽。
    ///
    /// 只有这里写 `states`。失败不是终态：只要还有自动尝试次数就继续；用尽后停在
    /// `.failed`，把「点按重试」留给用户。
    private func drive(_ attachmentId: String, variant: String?, in session: String, token: Int) async {
        let flightKey = bucketKey(session, attachmentId)
        var machine = AttachmentLoadMachine(automaticAttemptLimit: Self.automaticAttemptLimit)

        while !Task.isCancelled {
            machine.begin()
            setState(.loading, for: attachmentId, in: session)

            switch await fetchOnce(attachmentId, variant: variant, in: session) {
            case .image(let image):
                store(image, for: attachmentId, in: session)
                machine.succeed()
                setState(.loaded, for: attachmentId, in: session)
                finishDriver(flightKey, token: token)
                return

            case .cancelled:
                setState(.idle, for: attachmentId, in: session)
                finishDriver(flightKey, token: token)
                return

            case .notReady:
                // 链路还没就绪：继续转圈，只退避，不算一次可见的失败。
                guard let delay = machine.stall() else {
                    setState(.failed(reason: String(localized: "未连接")), for: attachmentId, in: session)
                    finishDriver(flightKey, token: token)
                    return
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    finishDriver(flightKey, token: token)
                    return
                }

            case .failure(let reason):
                setState(.failed(reason: reason), for: attachmentId, in: session)
                ChatProbe.shared.probeNote?(
                    "attachment.failed",
                    ["id": attachmentId, "attempt": String(machine.attempt), "reason": reason],
                    true)
                guard let delay = machine.fail(reason: reason) else {
                    // 自动次数用尽：停在失败态，等用户点。
                    finishDriver(flightKey, token: token)
                    return
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // 被取消（行离屏、手动重试、整链重置）：不动状态，交给新的驱动。
                    finishDriver(flightKey, token: token)
                    return
                }
            }
        }
        finishDriver(flightKey, token: token)
    }

    /// One attempt. The decode half runs off the main actor: `preparingForDisplay`
    /// is expensive and must not land on the render thread.
    private func fetchOnce(
        _ attachmentId: String, variant: String?, in session: String
    ) async -> FetchOutcome {
        if let image = cached(attachmentId) { return .image(image) }

        let scope = scopeId
        let disk = diskCache

        // 内存没有先问磁盘：同一个会话翻回去看时，图不该再走一遍网络。
        if let data = disk.load(scope: scope, attachmentId: attachmentId, variant: variant),
           let image = Self.decode(data) {
            await ChatProbe.shared.probeNote?("attachment.disk", ["id": attachmentId], true)
            return .image(image)
        }

        guard let client = chatHostForLoad() else { return .notReady }
        if shouldInjectFailure(for: attachmentId) { return .failure(String(localized: "注入的失败")) }

        let outcome: RemoteOutcome = await Task.detached {
            do {
                let value = try await client.attachment(
                    sessionId: session, attachmentId: attachmentId)
                guard let encoded = value["data"]?.stringValue,
                      let data = Data(base64Encoded: encoded)
                else { return .failure(String(localized: "返回的字节无法解码")) }
                return .data(data)
            } catch {
                if Self.isLinkNotReady(error) { return .notReady }
                return .failure((error as NSError).localizedDescription)
            }
        }.value

        if Task.isCancelled { return .cancelled }
        switch outcome {
        case .notReady:
            return .notReady
        case .data(let data):
            guard let image = Self.decode(data) else { return .failure(String(localized: "字节不是可显示的图片")) }
            // 下到了就留一份：下次冷启动不必再为这张图跑一趟中转。
            disk.save(data, scope: scope, attachmentId: attachmentId, variant: variant)
            return .image(image)
        case .failure(let reason):
            return .failure(reason)
        }
    }

    private enum FetchOutcome {
        case image(UIImage)
        case failure(String)
        case notReady
        case cancelled
    }

    /// 一次网络尝试的结果。`String` 不是 `Error`，所以不复用 `Result`。
    private enum RemoteOutcome {
        case data(Data)
        case failure(String)
        case notReady
    }

    /// 这几类错误说明"链路不在"，不是"这次请求有错"：界面该继续转圈，
    /// 等链路回来再试，而不是把用户引到一个点了也没用的重试按钮上。
    private nonisolated static func isLinkNotReady(_ error: any Error) -> Bool {
        guard let transport = error as? DSHTransportError else { return false }
        switch transport {
        case .notConnected, .unreachable, .carrierClosed: return true
        case .httpStatus, .malformedResponse, .notAuthenticated, .streamFailed, .timedOut: return false
        }
    }

    /// 后台解码：`UIImage(data:)` 本身是惰性的，不强制的话真正的解码会推迟到
    /// 渲染那一帧、发生在主线程上。`preparingForDisplay` 在后台把位图落出来。
    private nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    /// Clears everything, for every session.
    ///
    /// Called when the connection itself changes: the pictures belong to the
    /// computer that served them, and session ids are unique per host, not
    /// across hosts. Switching *sessions* does not come here — that just changes
    /// which bucket is read.
    public func reset() {
        cancelAllDrivers()
        cache.removeAllObjects()
        states.removeAll()
        flights.removeAll()
    }

    // MARK: - State bookkeeping

    private func setState(_ state: State, for attachmentId: String, in session: String) {
        guard sessionId == session else { return }
        states[session, default: [:]][attachmentId] = state
    }

    private func nextToken(for flightKey: String) {
        driverTokens[flightKey] = (driverTokens[flightKey] ?? 0) + 1
    }

    /// 结束一条驱动。只有当前 token 的主人能清理——手动重试会先换 token，
    /// 旧驱动退出时不得把新驱动登记的信息删掉。
    private func finishDriver(_ flightKey: String, token: Int) {
        guard driverTokens[flightKey] == token else { return }
        drivers[flightKey] = nil
        flights[flightKey] = nil
    }

    private func cancelAllDrivers() {
        for (flightKey, driver) in drivers {
            nextToken(for: flightKey)
            driver.cancel()
        }
        drivers.removeAll()
    }

    /// 链路恢复后重来：仍然没有图的那些重新走一遍第一次尝试。
    private func restart(_ pending: [String: Flight]) {
        let session = key
        for (flightKey, flight) in pending {
            _ = startDriver(
                attachmentId: flight.attachmentId, variant: flight.variant,
                in: session, flightKey: flightKey)
        }
    }

    /// `-DSHFailAttachmentLoad <n>`: make the first n attempts per picture fail.
    ///
    /// A run cannot wait for a real network failure to prove the retry path, and
    /// the failure that matters here (a socket that was down when the row
    /// appeared) is exactly the one that is hardest to stage. Injected failure
    /// only; everything after it — the placeholder, the backoff, the reload — is
    /// the real code.
    ///
    /// **Release 里恒为 0**（等于没有这个钩子），所以 `shouldInjectFailure`
    /// 也恒为 false，发布产物没有任何注入口。
    /// `-DSHAttachmentAttempts <n>`：DEBUG 钩子，把自动尝试次数调小。
    ///
    /// 只改"允许自动重试几次"这一个参数，重试本身、退避、状态流转都是真实代码；
    /// 有了它，一次运行内就能看到"次数用尽 → 停在失败态 → 点重试才恢复"。
    /// Release 里恒为默认上限。
    private static let automaticAttemptLimit: Int = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHAttachmentAttempts"),
              index + 1 < arguments.count,
              let count = Int(arguments[index + 1]), count > 0
        else { return AttachmentLoadMachine.maxAutomaticAttempts }
        return count
        #else
        return AttachmentLoadMachine.maxAutomaticAttempts
        #endif
    }()

    private static let injectedFailures: Int = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DSHFailAttachmentLoad"),
              index + 1 < arguments.count,
              let count = Int(arguments[index + 1])
        else { return 0 }
        return max(0, count)
        #else
        return 0
        #endif
    }()

    private var injectedAttempts: [String: Int] = [:]

    private func shouldInjectFailure(for attachmentId: String) -> Bool {
        guard Self.injectedFailures > 0 else { return false }
        let attempts = (injectedAttempts[attachmentId] ?? 0) + 1
        injectedAttempts[attachmentId] = attempts
        return attempts <= Self.injectedFailures
    }

    private func store(_ image: UIImage, for attachmentId: String, in session: String) {
        // cost = 解码后位图的字节数，配合 totalCostLimit 按内存压力逐出。
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
        cache.setObject(
            image, forKey: bucketKey(session, attachmentId) as NSString, cost: max(cost, 1))
        // T029：真实像素宽高落进尺寸缓存——协议事件没带宽高的附件，
        // 下次渲染直接用这里的值定行高，不再经过 4:3 占位。
        if let pixels = image.cgImage {
            dimensions.record(
                scope: scopeId, attachmentId: attachmentId,
                size: .init(width: pixels.width, height: pixels.height))
        }
    }

    /// Keeps at most `sessionLimit` sessions' state buckets, oldest first.
    private func pruneSessions() {
        guard states.count > Self.sessionLimit else { return }
        let oldest = states.keys.prefix(states.count - Self.sessionLimit)
        for session in oldest { states.removeValue(forKey: session) }
    }
}
#endif

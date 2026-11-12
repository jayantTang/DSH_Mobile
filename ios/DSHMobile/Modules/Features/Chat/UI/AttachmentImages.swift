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

    /// 取一次字节的实际实现（`sessionId, attachmentId` → `session/attachment` 的回包）。
    ///
    /// 生产不注入：走 `store.chatHost.attachment(...)`。单测注入一个假实现——
    /// 与 ``FeedbackAttachmentCache/Fetch`` 同一种做法（依赖从构造器进来，不是运行时开关）。
    public typealias AttachmentLoader =
        @Sendable (_ sessionId: String, _ attachmentId: String) async throws -> JSONValue

    /// 测试可以注入一个很小的自动尝试次数（生产仍是 `-DSHAttachmentAttempts` 或 8）。
    ///
    /// 它不是运行时开关：不读环境、不改退避表，只改"允许自动重试几次"这一个数字。
    public init(automaticAttemptLimit: Int = AttachmentImages.productionAttemptLimit,
                loader: AttachmentLoader? = nil) {
        self.automaticAttemptLimit = max(1, automaticAttemptLimit)
        self.loader = loader
    }

    private let automaticAttemptLimit: Int
    private let loader: AttachmentLoader?

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
    /// "这张图还没有字节、链路恢复时应当重来"——与 `drivers` 是两个事实（设计 §5 B1）。
    ///
    /// 自动次数用尽只结束驱动，**不**结算 flight；所以 `linkEstablished()` 仍有对象
    /// 可重启，用户不必手动点重试。只有"已加载"与"用户取消 / 重置"才结案。
    private var flights = AttachmentFlights()
    /// Guards against a finished driver clearing a newer one's bookkeeping.
    private var driverTokens: [String: Int] = [:]

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
        guard let sessionId else { return }
        // 待办只有一份：`AttachmentFlights`。用尽自动次数的那张图也在这里，
        // 所以链路回来之后它会重新走一遍完整的自动重试周期。
        let pending = flights.awaiting(session: sessionId)
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
            // 字节已经在手上：这条待办结案，不该再被链路恢复重跑一次。
            flights.settle(id: attachmentId, session: sessionId)
            return
        }
        let flightKey = bucketKey(sessionId, attachmentId)
        if let existing = drivers[flightKey] {
            await existing.value
            return
        }
        let driver = startDriver(
            attachmentId: attachmentId, variant: variant, in: sessionId, flightKey: flightKey)
        // 驱动的寿命**不跟着视图的 task 走**：UICollectionView 回收/重配一次单元格，
        // SwiftUI 就会取消这个 task，而取消之后没有任何东西会再把它叫起来——张张图
        // 都会停在转圈。驱动由本对象持有：重试有上限（约两分钟），会话切换与重置
        // （`reset` / `clearAllCached` / 手动重试）才是它的终止条件。
        await driver.value
    }

    /// 用户点了「点按重试」。
    ///
    /// 不是"再发一次同样的请求"：先取消上一次尝试（它可能还挂在网络上），把状态机
    /// 重置成第一次尝试，再立即重来。界面从失败态切回转圈，点下去当场有反馈。
    func retry(_ attachmentId: String) {
        guard let sessionId else { return }
        let flightKey = bucketKey(sessionId, attachmentId)
        let variant = flights.variant(id: attachmentId, session: sessionId)
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
        // 起驱动 = 这张图还没有字节：登记（或刷新）待办。
        flights.register(id: attachmentId, variant: variant, session: session)
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
        var machine = AttachmentLoadMachine(automaticAttemptLimit: automaticAttemptLimit)

        while !Task.isCancelled {
            machine.begin()
            guard isCurrentDriver(flightKey, token: token) else { return }
            setState(.loading, for: attachmentId, in: session)

            switch await fetchOnce(attachmentId, variant: variant, in: session) {
            case .image(let image):
                // 旧驱动（手动重试 / 链路恢复换过 token）不许再写状态、更不许结案：
                // 新驱动可能正在飞，结案会把它的 flight 删掉，重新变成"不自愈"。
                guard isCurrentDriver(flightKey, token: token) else { return }
                store(image, for: attachmentId, in: session)
                machine.succeed()
                setState(.loaded, for: attachmentId, in: session)
                settleFlight(attachmentId, in: session)
                finishDriver(flightKey, token: token)
                return

            case .cancelled:
                // 被换掉的驱动只退出，不动状态也不结案（P0-1 的那条守卫）。
                guard isCurrentDriver(flightKey, token: token) else { return }
                setState(.idle, for: attachmentId, in: session)
                settleFlight(attachmentId, in: session)
                finishDriver(flightKey, token: token)
                return

            case .notReady:
                // 链路还没就绪：继续转圈，只退避，不算一次可见的失败。
                guard let delay = machine.stall() else {
                    guard isCurrentDriver(flightKey, token: token) else { return }
                    setState(.failed(reason: String(localized: "未连接")), for: attachmentId, in: session)
                    reportExhausted(attachmentId: attachmentId, attempt: machine.attempt,
                                    category: AttachmentLoadFailure.notConnected.category)
                    // 用尽只结束驱动：flight 留着，链路恢复后会重跑。
                    finishDriver(flightKey, token: token)
                    return
                }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    finishDriver(flightKey, token: token)
                    return
                }

            case .failure(let failure):
                guard isCurrentDriver(flightKey, token: token) else { return }
                setState(.failed(reason: failure.displayText), for: attachmentId, in: session)
                ChatProbe.shared.probeNote?(
                    "attachment.failed",
                    ["id": attachmentId, "attempt": String(machine.attempt),
                     "reason": failure.category],
                    true)
                guard let delay = machine.fail(reason: failure.displayText) else {
                    // 自动次数用尽：停在失败态，等用户点；**flight 不结算**，
                    // 链路恢复时仍会自动重跑一遍（设计 §5 B1 的单一改法）。
                    // 终态分类落设备日志（B2）：只发短码与 id。
                    reportExhausted(attachmentId: attachmentId, attempt: machine.attempt,
                                    category: failure.category)
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

        let host: (any ChatHosting)?
        if loader == nil {
            host = chatHostForLoad()
            guard host != nil else { return .notReady }
        } else {
            host = nil
        }
        if shouldInjectFailure(for: attachmentId) { return .failure(.unknown) }

        // 网络与解码都在后台：`preparingForDisplay` 对一张截图是几十毫秒到上百毫秒，
        // 落主线程就是掉帧。
        let loader = self.loader
        let outcome: RemoteOutcome = await Task.detached {
            do {
                let value: JSONValue
                if let loader {
                    value = try await loader(session, attachmentId)
                } else {
                    value = try await host!.attachment(
                        sessionId: session, attachmentId: attachmentId)
                }
                guard let encoded = value["data"]?.stringValue,
                      let data = Data(base64Encoded: encoded)
                else { return .failure(.malformed) }
                guard let image = Self.decode(data) else {
                    return .failure(.decode)
                }
                return .image(image, data)
            } catch {
                let failure = AttachmentLoadFailure.from(error)
                if failure.isLinkNotReady { return .notReady }
                return .failure(failure)
            }
        }.value

        if Task.isCancelled { return .cancelled }
        switch outcome {
        case .notReady:
            return .notReady
        case .image(let image, let data):
            // 下到了就留一份：下次冷启动不必再为这张图跑一趟中转。
            disk.save(data, scope: scope, attachmentId: attachmentId, variant: variant)
            return .image(image)
        case .failure(let reason):
            return .failure(reason)
        }
    }

    private enum FetchOutcome {
        case image(UIImage)
        case failure(AttachmentLoadFailure)
        case notReady
        case cancelled
    }

    /// 一次网络尝试的结果：失败一律是分类枚举（文案与短码都从它派生）。
    private enum RemoteOutcome {
        case image(UIImage, Data)
        case failure(AttachmentLoadFailure)
        case notReady
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

    /// 这次写状态 / 结案是否还算数：`retry` 与 `linkEstablished` 都会换 token。
    ///
    /// 旧驱动在取消之后可能还在某个 await 上；它恢复时不许改状态、不许 settle flight，
    /// 否则会把新驱动刚登记的待办清掉（2026-11-12 评审 P0-1）。
    private func isCurrentDriver(_ flightKey: String, token: Int) -> Bool {
        driverTokens[flightKey] == token
    }

    /// 结束一条驱动：**只**清 `drivers`。
    ///
    /// flight 的生死由 ``settleFlight`` 决定。旧实现把"循环结束"当成"请求结案"，
    /// 于是失败终态也删掉了链路恢复所需的记录——这就是不自愈的根因。
    private func finishDriver(_ flightKey: String, token: Int) {
        guard driverTokens[flightKey] == token else { return }
        drivers[flightKey] = nil
    }

    /// 结案：字节已经拿到，或用户取消 / 重置。这是 flight 唯一的删除入口。
    private func settleFlight(_ attachmentId: String, in session: String) {
        flights.settle(id: attachmentId, session: session)
    }

    /// 自动次数用尽：把"哪张图、第几次、哪类错误"落到连接器的设备日志（B2）。
    ///
    /// 只传稳定的短码与 id，不传文件名 / URL / 正文；失败当无事，不改连接状态。
    private func reportExhausted(attachmentId: String, attempt: Int, category: String) {
        guard let store else { return }
        Task { @MainActor in
            await store.noteAttachmentLoadFailure(id: attachmentId, attempt: attempt,
                                                  category: category)
        }
    }

    private func cancelAllDrivers() {
        for (flightKey, driver) in drivers {
            nextToken(for: flightKey)
            driver.cancel()
        }
        drivers.removeAll()
    }

    /// 链路恢复后重来：仍然没有图的那些重新走一遍第一次尝试。
    ///
    /// `pending` 的键已经是 `session|attachmentId`；每条 flight 自带会话，所以不再
    /// 依赖"当前会话"（旧实现跨会话重启，会把别的会话的图也拉起来）。
    private func restart(_ pending: [String: AttachmentFlights.Flight]) {
        for (flightKey, flight) in pending {
            _ = startDriver(
                attachmentId: flight.attachmentId, variant: flight.variant,
                in: flight.session, flightKey: flightKey)
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
    /// 生产默认：`-DSHAttachmentAttempts`（DEBUG）或状态机的上限（Release）。
    public static var productionAttemptLimit: Int { defaultAttemptLimit }

    static let defaultAttemptLimit: Int = {
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
        // 状态桶被裁掉的会话，待办也一起裁掉：没有状态可写的驱动不该继续登记。
        flights.prune(sessions: Set(states.keys))
    }
}
#endif

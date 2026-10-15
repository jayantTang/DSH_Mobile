#if os(iOS)
import DSHConnectionDomain
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
/// `clearFailures` / `reset` / `clearAllCached`）是 public。
@MainActor
@Observable
public final class AttachmentImages {

    public init() {}

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
    /// session → attachment id → when it last failed.
    ///
    /// A timestamp rather than a set, because "failed" must not mean "forever":
    /// a picture that lost its race with a reconnecting socket used to stay
    /// broken for the rest of the session, with no way for anyone to ask again.
    private var failures: [String: [String: Date]] = [:]
    /// "session|attachment" → the load in progress, so the same picture asked
    /// for twice in one session coalesces while two sessions never share one.
    private var inFlight: [String: Task<(image: UIImage?, attemptedNetwork: Bool), Never>] = [:]
    /// 解码过的附件的真实像素宽高（T029）：协议事件没带宽高时，首帧按 4:3 占位，
    /// 解码完成把真实尺寸记进这里，下次同一附件直接定高。持久化在 DSHKit 侧。
    private let dimensions = AttachmentDimensions()

    /// 失败时间戳的会话桶上限（图片本身由 NSCache 按字节管，不再需要按会话清）。
    private static let sessionLimit = 6

    private var key: String { sessionId ?? "" }

    private func bucketKey(_ session: String, _ attachmentId: String) -> String {
        "\(session)|\(attachmentId)"
    }

    private weak var store: ConnectionStore?

    public func attach(store: ConnectionStore) {
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

    /// How long a failure keeps a re-rendering view from asking again.
    ///
    /// The guard is against a tight loop, not against trying later: past this
    /// window the next render retries by itself, and a tap retries immediately.
    static let retryAfter: TimeInterval = 15

    /// True when this attachment failed and is still inside the quiet window.
    func hasFailed(_ attachmentId: String) -> Bool {
        guard let at = failures[key]?[attachmentId] else { return false }
        return Date().timeIntervalSince(at) < Self.retryAfter
    }

    /// How many attachments are sitting in a failed state, for diagnostics.
    var failureCount: Int { (failures[key] ?? [:]).count }

    /// 丢掉所有内存里的图片（「清除本地缓存」时用；磁盘那份由设置页删）。
    public func clearAllCached() {
        cache.removeAllObjects()
        dimensions.clearAll()
        inFlight.removeAll()
        failures.removeAll()
    }

    /// Forgets every failure, so the next render tries again.
    ///
    /// Called when the link is re-established: whatever failed during the
    /// outage was failing because there was no connection, not because the
    /// request was wrong.
    public func clearFailures() {
        guard !failures.isEmpty else { return }
        // Every session, not just this one: what failed during the outage was
        // failing because there was no connection.
        failures.removeAll()
    }

    /// 图片的落盘层：进程一没，内存桶就空了，冷启动会把每张图都重下一遍。
    private let diskCache = AttachmentDiskCache()

    private var scopeId: String { store?.scopeId ?? "unknown" }

    /// Fetches the bytes once, coalescing everyone who asks for the same image.
    ///
    /// `variant` identifies the *content* as far as the wire tells us (size and
    /// media type). Attachment ids are the host's; if it ever reuses one for a
    /// different picture, a different variant means a different cache entry
    /// rather than the old picture forever.
    ///
    /// T029：磁盘读取、网络下载与**解码**全部在后台任务里完成
    /// （`preparingForDisplay` 强制位图落出来），主线程只拿现成的 UIImage——
    /// 行高早已按元数据定死，这里只负责把内容填进去。
    @discardableResult
    func load(_ attachmentId: String, variant: String? = nil) async -> UIImage? {
        let session = key
        let flightKey = bucketKey(session, attachmentId)
        if let cached = cache.object(forKey: flightKey as NSString) { return cached }
        if let running = inFlight[flightKey] { return await running.value.image }
        guard !attachmentId.isEmpty, let sessionId, let client = store?.client else { return nil }

        let scope = scopeId
        let disk = diskCache
        let task = Task<(image: UIImage?, attemptedNetwork: Bool), Never>.detached {
            [weak self] in
            // 内存没有先问磁盘：同一个会话翻回去看时，图不该再走一遍网络。
            // 磁盘命中不触网，也就不受失败静默窗约束。
            if let data = disk.load(scope: scope, attachmentId: attachmentId, variant: variant),
               let image = Self.decode(data) {
                await ChatProbe.shared.probeNote?("attachment.disk", ["id": attachmentId], true)
                return (image, false)
            }
            if await self?.shouldInjectFailure(for: attachmentId) == true { return (nil, true) }
            if await self?.hasFailed(attachmentId) == true { return (nil, false) }
            do {
                let value = try await client.attachment(
                    sessionId: sessionId,
                    attachmentId: attachmentId
                )
                guard let encoded = value["data"]?.stringValue,
                      let data = Data(base64Encoded: encoded),
                      let image = Self.decode(data)
                else { return (nil, true) }
                // 下到了就留一份：下次冷启动不必再为这张图跑一趟中转。
                disk.save(data, scope: scope, attachmentId: attachmentId, variant: variant)
                return (image, true)
            } catch {
                return (nil, true)
            }
        }
        inFlight[flightKey] = task

        let result = await task.value
        inFlight[flightKey] = nil
        if let image = result.image {
            store(image, for: attachmentId, in: session)
            failures[session]?.removeValue(forKey: attachmentId)
        } else if result.attemptedNetwork {
            failures[session, default: [:]][attachmentId] = Date()
        }
        return result.image
    }

    /// 后台解码：`UIImage(data:)` 本身是惰性的，不强制的话真正的解码会推迟到
    /// 渲染那一帧、发生在主线程上。`preparingForDisplay` 在后台把位图落出来。
    private nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    /// The person asked for this picture again.
    ///
    /// The one path that ignores the quiet window: a tap is not a loop.
    @discardableResult
    func retry(_ attachmentId: String) async -> UIImage? {
        failures[key]?.removeValue(forKey: attachmentId)
        return await load(attachmentId)
    }

    /// Clears everything, for every session.
    ///
    /// Called when the connection itself changes: the pictures belong to the
    /// computer that served them, and session ids are unique per host, not
    /// across hosts. Switching *sessions* does not come here — that just changes
    /// which bucket is read.
    public func reset() {
        cache.removeAllObjects()
        failures.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    /// `-DSHFailAttachmentLoad <n>`: make the first n attempts per picture fail.
    ///
    /// A run cannot wait for a real network failure to prove the retry path, and
    /// the failure that matters here (a socket that was down when the row
    /// appeared) is exactly the one that is hardest to stage. Injected failure
    /// only; everything after it — the placeholder, the tap, the reload — is the
    /// real code.
    ///
    /// **Release 里恒为 0**（等于没有这个钩子），所以 `shouldInjectFailure`
    /// 也恒为 false，发布产物没有任何注入口。
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

    /// Keeps at most `sessionLimit` sessions' failure buckets, oldest first.
    private func pruneSessions() {
        guard failures.count > Self.sessionLimit else { return }
        let oldest = failures.keys.prefix(failures.count - Self.sessionLimit)
        for session in oldest { failures.removeValue(forKey: session) }
    }
}
#endif

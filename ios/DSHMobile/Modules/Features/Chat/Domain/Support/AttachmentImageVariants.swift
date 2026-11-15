import CryptoKit
import DSHConnectionAPI
import DSHKit
import Foundation
import Observation

/// 图片原图变体的状态机（契约 §2.4 / SR-02.11 / SR-08.02）。
///
/// **预览与原图是两条独立的路**：列表、首帧、模型输入只用预览；原图只有用户主动
/// 点「查看原图」才会查元数据、才会下载。所以这里没有任何"打开会话就预热原图"的
/// 入口——它只被显式的 `lookupOriginal` / `downloadOriginal` 驱动。
///
/// 放在 Domain（Foundation + DSHKit）而不是 UIKit 扩展里，有三个直接原因：
/// 1. `swift test` 在 macOS 上跑得到：状态迁移、分片拼接、SHA-256 校验与"不可用
///    不重试"都能用真实字节断言，不需要仿真器；
/// 2. 原图缓存与预览缓存共用 ``AttachmentDiskCache``，但用不同 variant：同一张图
///    的两份字节永远不会互相覆盖；下载失败只写状态，**不落任何文件**；
/// 3. 失败与不可用是两种结局：`missing` / `cleaned` / `unsupported` 是终态，
///    不再自动重试；网络失败落成 `.failed`，由用户下一次点按重试。
@MainActor
@Observable
public final class AttachmentImageVariants {

    /// 一次分片的字节数（契约 §1.3 的默认值）。顺序取，直到 `eof`。
    public static let chunkBytes = 512 * 1024

    /// 一张原图的状态。`ready` 表示元数据已知且原图可用——字节是否已下载由
    /// ``originalData(sessionId:attachmentId:)`` 回答（只读已校验的磁盘缓存）。
    public enum State: Equatable, Sendable {
        case idle
        /// 正在查元数据或下载；进度是已取字节 / 原图总字节。
        case loading(progress: Double)
        /// 元数据已知，原图可用。
        case ready(ImageOriginalMetadata)
        /// 原图不可用（`missing` / `cleaned` / `unsupported`），不重试。
        case unavailable(reason: String)
        /// 网络或校验失败，可手动重试；预览不受影响。
        case failed(message: String)
    }

    public typealias LookupLoader =
        @Sendable (_ attachmentId: String) async throws -> ImageOriginalLookup
    public typealias ChunkLoader =
        @Sendable (_ attachmentId: String, _ offset: Int, _ length: Int) async throws -> ImageOriginalChunk

    private let diskCache: AttachmentDiskCache
    private let lookupLoader: LookupLoader?
    private let chunkLoader: ChunkLoader?
    /// 测试注入的 scope；生产由 `attach(store:)` 提供的连接档案决定。
    private let fixedScope: String
    private weak var store: (any ConnectionStatus)?

    private var states: [String: State] = [:]
    private var metadata: [String: ImageOriginalMetadata] = [:]
    private var activeDownloads: Set<String> = []
    /// 清空/重置的代数：在飞的下载恢复后不许再把旧状态写回来。
    private var generation = 0

    public init(
        diskCache: AttachmentDiskCache = AttachmentDiskCache(),
        scope: String = "unknown",
        lookupLoader: LookupLoader? = nil,
        chunkLoader: ChunkLoader? = nil
    ) {
        self.diskCache = diskCache
        self.fixedScope = scope
        self.lookupLoader = lookupLoader
        self.chunkLoader = chunkLoader
    }

    /// 由 `AttachmentImages` 在 `attach(store:)` 时一起转交连接服务。
    public func attach(store: any ConnectionStatus) {
        self.store = store
    }

    private var scopeId: String { store?.scopeId ?? fixedScope }

    private func bucket(_ sessionId: String?, _ attachmentId: String) -> String {
        "\(sessionId ?? "")|\(attachmentId)"
    }

    // MARK: - 读状态

    public func state(sessionId: String?, attachmentId: String) -> State {
        states[bucket(sessionId, attachmentId)] ?? .idle
    }

    /// 已经查到的原图元数据（`ready` 之后不为 nil）。
    public func originalMetadata(sessionId: String?, attachmentId: String) -> ImageOriginalMetadata? {
        metadata[bucket(sessionId, attachmentId)]
    }

    /// 只读**已校验**的磁盘缓存；没下载、失败或校验不通过时为 nil。
    public func originalData(sessionId: String?, attachmentId: String) -> Data? {
        let key = bucket(sessionId, attachmentId)
        guard let meta = metadata[key] else { return nil }
        return diskCache.load(
            scope: scopeId, attachmentId: attachmentId, variant: Self.cacheVariant(meta)
        )
    }

    // MARK: - 查元数据

    /// 只查元数据，绝不下载字节。`missing` / `cleaned` / `unsupported` 落成
    /// `.unavailable`，之后任何自动调用都不会再发请求。
    public func lookupOriginal(sessionId: String?, attachment: ContentBlock.ImageAttachment) async {
        let attachmentId = attachment.attachmentId
        guard !attachmentId.isEmpty else { return }
        let key = bucket(sessionId, attachmentId)
        switch states[key] {
        case .ready, .unavailable, .loading:
            return
        default:
            break
        }
        let token = generation
        setState(.loading(progress: 0), key: key, token: token)
        do {
            let lookup = try await loadLookup(attachmentId)
            guard generation == token else { return }
            switch lookup {
            case .available(let value):
                metadata[key] = value
                setState(.ready(value), key: key, token: token)
            case .unavailable(let reason):
                metadata[key] = nil
                setState(.unavailable(reason: reason), key: key, token: token)
            }
        } catch {
            guard generation == token else { return }
            setState(Self.failureState(for: error), key: key, token: token)
        }
    }

    // MARK: - 下载原图

    /// 按 512 KiB 顺序取完整原图，进度写进状态，完成后 SHA-256 必须等于
    /// `original.attachmentId`；不一致按失败处理，**不写**磁盘缓存。
    ///
    /// 不可用状态直接返回（不自动重试）；`.failed` 可以再次调用，这是唯一的重试入口。
    public func downloadOriginal(sessionId: String?, attachment: ContentBlock.ImageAttachment) async {
        let attachmentId = attachment.attachmentId
        guard !attachmentId.isEmpty else { return }
        let key = bucket(sessionId, attachmentId)
        if case .unavailable = states[key] { return }
        if let known = metadata[key],
           diskCache.load(scope: scopeId, attachmentId: attachmentId,
                          variant: Self.cacheVariant(known)) != nil {
            setState(.ready(known), key: key, token: generation)
            return
        }
        guard !activeDownloads.contains(key) else { return }
        let token = generation
        activeDownloads.insert(key)
        defer { activeDownloads.remove(key) }

        var meta = metadata[key]
        // 上次失败后用户再点一次：元数据也要重查。索引可能刚被修好（换名、重新
        // 落盘、连接器升级），拿着旧元数据重试只会把同一个失败再演一遍。
        if let state = states[key], case .failed = state {
            metadata[key] = nil
            meta = nil
        }
        if meta == nil {
            setState(.loading(progress: 0), key: key, token: token)
            do {
                let lookup = try await loadLookup(attachmentId)
                guard generation == token else { return }
                switch lookup {
                case .available(let value):
                    meta = value
                    metadata[key] = value
                case .unavailable(let reason):
                    setState(.unavailable(reason: reason), key: key, token: token)
                    return
                }
            } catch {
                guard generation == token else { return }
                setState(Self.failureState(for: error), key: key, token: token)
                return
            }
        }
        guard let meta else {
            setState(.failed(message: Self.retryText), key: key, token: token)
            return
        }

        setState(.loading(progress: 0), key: key, token: token)
        var assembled = Data()
        do {
            while assembled.count < meta.bytes {
                guard generation == token else { return }
                // 查看器关掉 / 用户点取消：停在"元数据已知、字节还没下"的状态，
                // 下次点开还能重来，而不是留下一个永远转圈的 loading。
                if Task.isCancelled {
                    setState(.ready(meta), key: key, token: token)
                    return
                }
                let length = min(Self.chunkBytes, meta.bytes - assembled.count)
                // **分片按预览 id 取**：连接器的索引键是预览的 attachmentId，
                // 原图的附件 id 只是校验用的摘要。传错了会被当成"没有这张原图"，
                // 症状是永远停在加载中或直接"原图不可用"（2026-11-15 仿真器实测）。
                let chunk = try await loadChunk(attachmentId, assembled.count, length)
                guard generation == token else { return }
                // 连接器回错区间就停下：拼错区间的字节比失败更糟（SR-08.02）。
                guard chunk.offset == assembled.count, !chunk.data.isEmpty else {
                    setState(.failed(message: Self.retryText), key: key, token: token)
                    return
                }
                guard chunk.bytes == meta.bytes else {
                    setState(.failed(message: Self.retryText), key: key, token: token)
                    return
                }
                assembled.append(chunk.data)
                guard assembled.count <= meta.bytes else {
                    setState(.failed(message: Self.retryText), key: key, token: token)
                    return
                }
                setState(
                    .loading(progress: Double(assembled.count) / Double(max(meta.bytes, 1))),
                    key: key, token: token
                )
                if chunk.eof { break }
            }
        } catch is CancellationError {
            guard generation == token else { return }
            setState(.ready(meta), key: key, token: token)
            return
        } catch {
            guard generation == token else { return }
            setState(Self.failureState(for: error), key: key, token: token)
            return
        }

        guard assembled.count == meta.bytes else {
            // 截断：没到 `bytes` 就结束，一律不落"已下载"。
            setState(.failed(message: Self.retryText), key: key, token: token)
            return
        }
        guard Self.matches(originalId: meta.attachmentId, data: assembled) else {
            // 校验不通过：不写缓存，也不把状态推成 ready。
            setState(.failed(message: Self.retryText), key: key, token: token)
            return
        }
        diskCache.save(
            assembled, scope: scopeId, attachmentId: attachmentId,
            variant: Self.cacheVariant(meta)
        )
        setState(.ready(meta), key: key, token: token)
    }

    /// 为「保存原图」取字节：已下载就给，未下载先按需下载，不可用/失败返回 nil。
    ///
    /// 需求 SR-02.11：保存原图点击时按需下载，用户不必先点过「原图」。复用同一条
    /// 下载与校验路径（分片、进度、SHA-256），失败绝不返回预览字节。
    public func dataForSaving(sessionId: String?, attachment: ContentBlock.ImageAttachment) async -> Data? {
        let attachmentId = attachment.attachmentId
        guard !attachmentId.isEmpty else { return nil }
        if let data = originalData(sessionId: sessionId, attachmentId: attachmentId) {
            return data
        }
        if case .unavailable = state(sessionId: sessionId, attachmentId: attachmentId) {
            return nil
        }
        await downloadOriginal(sessionId: sessionId, attachment: attachment)
        return originalData(sessionId: sessionId, attachmentId: attachmentId)
    }

    /// 丢掉内存里的状态与元数据（磁盘那份由设置页统一清理）。
    public func clearMemory() {
        generation += 1
        states.removeAll()
        metadata.removeAll()
        activeDownloads.removeAll()
    }

    /// 连接整体重建时与 ``clearMemory()`` 同义：图片属于上一台电脑。
    public func reset() {
        clearMemory()
    }

    // MARK: - Loaders / 状态写入口

    private func loadLookup(_ attachmentId: String) async throws -> ImageOriginalLookup {
        if let lookupLoader {
            return try await lookupLoader(attachmentId)
        }
        guard let host = store?.chatHost else { throw DSHTransportError.notConnected }
        return try await host.imageOriginal(attachmentId: attachmentId)
    }

    private func loadChunk(_ attachmentId: String, _ offset: Int, _ length: Int) async throws -> ImageOriginalChunk {
        if let chunkLoader {
            return try await chunkLoader(attachmentId, offset, length)
        }
        guard let host = store?.chatHost else { throw DSHTransportError.notConnected }
        return try await host.imageOriginalChunk(
            attachmentId: attachmentId, offset: offset, length: length
        )
    }

    /// 状态只经这里写；代数变了的旧任务写得再晚也落不下来。
    private func setState(_ state: State, key: String, token: Int) {
        guard generation == token else { return }
        states[key] = state
    }

    // MARK: - 分类

    /// 不可用与失败必须分开：前者不重试，后者等用户点。
    static func failureState(for error: any Error) -> State {
        if error is ImageVariantsUnsupported {
            return .unavailable(reason: "unsupported")
        }
        if let unavailable = error as? ImageOriginalUnavailable {
            return .unavailable(reason: unavailable.reason)
        }
        if let failure = error as? DSHRPCFailure {
            switch failure.code {
            case "link/unsupported":
                return .unavailable(reason: "unsupported")
            case "image-original/missing":
                return .unavailable(reason: "missing")
            case "image-original/cleaned":
                return .unavailable(reason: "cleaned")
            default:
                break
            }
        }
        return .failed(message: LinkErrors.describe(error))
    }

    /// 失败文案与其他取图失败共用同一句：可重试，不致于把预览也弄丢。
    static var retryText: String {
        String(localized: "原图下载失败，点按重试")
    }

    // MARK: - 校验与缓存 key

    /// 原图与预览的缓存文件用不同 variant：同一个附件 id 下两份字节不会互相覆盖。
    static func cacheVariant(_ metadata: ImageOriginalMetadata) -> String {
        "original-\(metadata.attachmentId)"
    }

    static func matches(originalId: String, data: Data) -> Bool {
        let expected = originalId.hasPrefix("sha256:")
            ? String(originalId.dropFirst("sha256:".count))
            : originalId
        return sha256Hex(data).caseInsensitiveCompare(expected) == .orderedSame
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

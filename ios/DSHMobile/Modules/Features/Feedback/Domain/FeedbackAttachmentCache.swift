import DSHConnectionAPI
import DSHFoundation
import Foundation
import ImageIO
import RelayKit
import UniformTypeIdentifiers

/// 附件的字节与加载状态：**唯一所有者**。
///
/// 每个 `(sha256, variant)` 有自己的状态机与在飞任务：
///
///     idle → loading(received,total) → loaded
///                                    → failed(原因)
///     loading → idle（用户取消）
///
/// 视图只读 ``state(for:variant:)``、发 `load` / `requestOriginal` / `cancelOriginal`；
/// 视图里不再有 `@State isDownloading` / `hasFailed` / 本地进度副本（设计 §2.3）。
///
/// 字节只在 ``FeedbackAttachmentDisk``（下载缓存 + 缩略图缓存）里，一个字节都不进
/// `inbox.json`。下载成功必须用元数据里的 sha256 复核；复核失败不写缓存。
@MainActor
@Observable
public final class FeedbackAttachmentCache {

    /// 一个逻辑附件的哪一份字节（与 wire 的 `preview` / 主对象一一对应）。
    public enum LoadVariant: String, Sendable, Equatable, CaseIterable {
        /// 列表与缩略图用：有 `preview` 就是预览，否则是主对象（旧信件）。
        case preview
        /// 全屏的「原图」：主对象。
        case original
        /// 旧信件的本地缩略图（长边 ≤320 的 JPEG，由预览 / 主对象现算一次）。
        case thumbnail
    }

    /// 一次加载的状态（四种结局 + 进行中）。
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading(received: Int, total: Int?)
        case loaded
        case failed(String)
    }

    /// 失败原因的分类（不写本地化文案，文案由 UI 从分类派生）。
    public enum LoadError: Error, Equatable {
        case client(FeedbackClientError)
        case digestMismatch(expected: String, actual: String)
        case notAnImage
    }

    /// 取字节的实现（由 `FeedbackCenter` 注入：它才知道地址与令牌）。
    public typealias Fetch = @MainActor (String, (@Sendable (Int, Int?) -> Void)?) async throws -> Data

    private struct Key: Hashable {
        let sha256: String
        let variant: LoadVariant
    }

    private let disk: FeedbackAttachmentDisk
    private let fetch: Fetch
    /// 同一个 `(sha256, variant)` 的并发请求只发一次。
    private var inFlight: [Key: Task<Data, any Error>] = [:]
    private var states: [Key: LoadState] = [:]
    /// 每个键的"第几次在飞"。任务完成时只有代数没变才允许写状态——
    /// 取消后立刻重试时，旧任务晚到的结局不许覆盖新任务（评审 P1-4）。
    private var generations: [Key: Int] = [:]

    public init(disk: FeedbackAttachmentDisk, fetch: @escaping Fetch) {
        self.disk = disk
        self.fetch = fetch
    }

    // MARK: - 读

    public func state(for attachment: FeedbackAttachment, variant: LoadVariant) -> LoadState {
        states[key(attachment, variant: variant)] ?? .idle
    }

    /// 已经在磁盘上的字节（UI 可以先画出来，避免闪烁）；没有就 `nil`。
    public func cached(_ attachment: FeedbackAttachment, variant: LoadVariant = .preview) -> Data? {
        let key = key(attachment, variant: variant)
        return diskBytes(key)
    }

    /// 加载一份字节：命中缓存直接 `loaded`；否则取一次、复核摘要、落缓存。
    ///
    /// 失败（网络 / 摘要不符 / 取不到图）落到 `.failed`，下一次 `load` 会重试。
    /// 取消（`cancelOriginal`）落到 `.idle`，不写缓存。
    @discardableResult
    public func load(_ attachment: FeedbackAttachment, variant: LoadVariant) async -> Data? {
        let key = key(attachment, variant: variant)
        if let cached = diskBytes(key) {
            states[key] = .loaded
            return cached
        }
        if let running = inFlight[key] {
            return await value(of: running, key: key, generation: generations[key] ?? 0)
        }
        let source = source(for: attachment, variant: variant)
        states[key] = .loading(received: 0, total: nil)
        let generation = (generations[key] ?? 0) + 1
        generations[key] = generation
        let task = Task { [fetch] () -> Data in
            let progress: @Sendable (Int, Int?) -> Void = { [weak self] received, total in
                Task { @MainActor in
                    self?.noteProgress(key: key, received: received, total: total)
                }
            }
            let raw = try await fetch(source.attachmentId, progress)
            let bytes = variant == .thumbnail ? try Self.thumbnail(from: raw) : raw
            // 摘要核对的对象始终是**下载下来的原始字节**（缩略图是我们自己生成的）。
            let actual = FeedbackOutgoingAttachment.sha256Hex(raw)
            if !source.sha256.isEmpty, actual != source.sha256 {
                throw LoadError.digestMismatch(expected: source.sha256, actual: actual)
            }
            if variant == .thumbnail {
                // 原始字节落下载缓存（缩略图另存一份），全屏原图可以直接命中。
                disk.storeCache(raw, sha256: source.sha256)
            }
            return bytes
        }
        inFlight[key] = task
        return await value(of: task, key: key, generation: generation)
    }

    /// 全屏的「原图」按钮：等价于 `load(variant: .original)`。
    public func requestOriginal(_ attachment: FeedbackAttachment) async {
        await load(attachment, variant: .original)
    }

    /// 取消在飞的原图下载：状态回 `.idle`，不写缓存，可以再点一次。
    public func cancelOriginal(_ attachment: FeedbackAttachment) {
        cancel(attachment, variant: .original)
    }

    /// 取消某个 variant 的在飞任务（`cancelOriginal` 之外，缩略图/预览也用它）。
    public func cancel(_ attachment: FeedbackAttachment, variant: LoadVariant) {
        let key = key(attachment, variant: variant)
        // 换一代：在飞的任务晚到的成功/失败/取消都不再算数（它已经不属于当前请求）。
        generations[key] = (generations[key] ?? 0) + 1
        inFlight[key]?.cancel()
        inFlight[key] = nil
        if case .loading = states[key] ?? .idle {
            states[key] = .idle
        }
    }

    /// 清缓存（与镜像、暂存同一个入口：`FeedbackCenter.clearLocalMirror()`）。
    public func clear() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        generations.removeAll()
        states.removeAll()
        disk.clear()
    }

    // MARK: - 内部

    private func key(_ attachment: FeedbackAttachment, variant: LoadVariant) -> Key {
        Key(sha256: source(for: attachment, variant: variant).sha256, variant: variant)
    }

    /// 某个 variant 实际要取的 `(attachmentId, sha256)`。
    ///
    /// 三种读法只在这一个函数里（设计 §4.2）：有 `preview` 时预览子对象是列表那一份，
    /// 主对象是原图；`compressed`（只有预览）两者都读主对象；旧信件主对象就是原图。
    private func source(for attachment: FeedbackAttachment,
                        variant: LoadVariant) -> (attachmentId: String, sha256: String) {
        switch variant {
        case .original:
            return (attachment.attachmentId, attachment.sha256)
        case .preview, .thumbnail:
            if let preview = attachment.preview, !attachment.compressed {
                return (preview.attachmentId, preview.sha256)
            }
            return (attachment.attachmentId, attachment.sha256)
        }
    }

    private func diskBytes(_ key: Key) -> Data? {
        switch key.variant {
        case .thumbnail:
            return disk.cachedThumbnail(sha256: key.sha256)
        case .preview, .original:
            return disk.cachedBytes(sha256: key.sha256)
        }
    }

    /// 进度只往 `.loading` 上写：落地之后再迟到的进度不许把状态拽回"加载中"。
    private func noteProgress(key: Key, received: Int, total: Int?) {
        guard case .loading(let previous, _) = states[key] ?? .idle, received >= previous else {
            return
        }
        states[key] = .loading(received: received, total: total)
    }

    private func value(of task: Task<Data, any Error>, key: Key,
                       generation: Int) async -> Data? {
        /// 这次结局还算不算数：取消 / 重试会换一代，旧任务的结局到此为止。
        func isCurrent() -> Bool { generations[key] == generation }

        do {
            let bytes = try await task.value
            guard isCurrent() else { return nil }
            if key.variant == .thumbnail {
                // 缩略图是派生件；原始字节同样落下载缓存——全屏打开原图时直接命中，
                // 不必为同一份字节再下一遍（设计 §5 A5 的"第二次直接命中"）。
                disk.storeThumbnail(bytes, sha256: key.sha256)
            } else {
                disk.storeCache(bytes, sha256: key.sha256)
            }
            states[key] = .loaded
            inFlight[key] = nil
            return bytes
        } catch is CancellationError {
            // 取消不是失败：回 idle，让用户还能再点一次。
            guard isCurrent() else { return nil }
            if case .loading = states[key] ?? .idle { states[key] = .idle }
            inFlight[key] = nil
            return nil
        } catch {
            guard isCurrent() else { return nil }
            states[key] = .failed(Self.describe(error))
            inFlight[key] = nil
            return nil
        }
    }

    /// 失败原因的标准文本：摘要不符与"取不到图"各一句，其余走协议层的描述。
    private static func describe(_ error: any Error) -> String {
        if let loadError = error as? LoadError {
            switch loadError {
            case .digestMismatch:
                return String(localized: "字节校验失败")
            case .notAnImage:
                return String(localized: "这张图打不开")
            case .client(let clientError):
                return LinkErrors.describe(clientError)
            }
        }
        return LinkErrors.describe(error)
    }

    /// 生成长边 ≤320 的 JPEG 缩略图（旧信件的列表用；预览本身已经是小图）。
    nonisolated private static func thumbnail(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw LoadError.notAnImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw LoadError.notAnImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw LoadError.notAnImage }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LoadError.notAnImage }
        return output as Data
    }

    /// 列表缩略图的长边（设计 §5 A5：≤320）。
    nonisolated public static let thumbnailMaxEdge = 320
}

/// 全屏该显示哪一份、原图入口该不该出现——**一个**派生口径，视图只读它。
///
/// 为什么单独成类型：`cached(...)` 本身不是可观察量，视图只看它会在下载完成之后
/// 不重画（评审 P1-2）；而"磁盘上已经有原图"与"这次刚下载完"又都算已就绪（P2-6）。
/// 判据固定为 `(state, hasCachedOriginal)` 两个输入的纯函数，用例可以直接钉住。
public enum FeedbackAttachmentOriginalDisplay {
    /// 原图已经可用：状态是 `loaded`，或状态还没动过但磁盘上已经有那份字节。
    ///
    /// `loading` / `failed` 一律不算——失败时继续显示预览，加载中也不该闪。
    public static func isAvailable(state: FeedbackAttachmentCache.LoadState,
                                   hasCachedOriginal: Bool) -> Bool {
        switch state {
        case .loaded: return true
        case .idle: return hasCachedOriginal
        case .loading, .failed: return false
        }
    }

    /// 全屏当前该展示的 variant：原图可用就展示原图，否则展示列表那一份。
    public static func shownVariant(previewVariant: FeedbackAttachmentCache.LoadVariant,
                                    state: FeedbackAttachmentCache.LoadState,
                                    hasCachedOriginal: Bool) -> FeedbackAttachmentCache.LoadVariant {
        isAvailable(state: state, hasCachedOriginal: hasCachedOriginal) ? .original : previewVariant
    }
}

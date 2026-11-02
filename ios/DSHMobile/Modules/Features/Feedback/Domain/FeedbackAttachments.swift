import CryptoKit
import DSHFoundation
import Foundation
import RelayKit

/// 一封信里待上传的附件（还没到服务端）。
///
/// 字节由调用方给出（UI 轮的选择器 + 规范化器产出），本类型只负责"它是谁、多长、
/// 摘要是什么"。`slot` 不在这里：序号是**一次发送**里排出来的，由
/// ``FeedbackSendJob`` 分配并保持不变（重试不改序号）。
public struct FeedbackOutgoingAttachment: Sendable, Equatable {
    public let name: String
    public let contentType: String
    public let data: Data
    /// 仅图片：占位尺寸（服务端只当参考，不做可信依据）。
    public let width: Int?
    public let height: Int?

    public init(name: String, contentType: String, data: Data,
                width: Int? = nil, height: Int? = nil) {
        self.name = name
        self.contentType = contentType
        self.data = data
        self.width = width
        self.height = height
    }

    public var byteSize: Int { data.count }

    /// 服务端按它复核落盘字节；下载端也按它复核（客户端唯一需要的摘要算法）。
    public var sha256: String { Self.sha256Hex(data) }

    /// 小写十六进制 SHA-256。
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 一条"传过但还没绑进信"的附件记录（跨重启可重试的那一份）。
///
/// 归集键是**信件级 `clientRef`**（与 ``FeedbackSendJob`` 同一个）：草稿由服务端
/// 按 `(clientRef, slot)` 幂等，重试时先 `begin` 拿回同一行——已 `stored` 的就
/// 不再重传字节。
public struct FeedbackPendingUpload: Codable, Sendable, Equatable {
    public var slot: Int
    /// `begin` 之后拿到的 id；重试用它继续（`upload` 也按它幂等）。
    public var attachmentId: String?
    /// 服务端回的 `state`：`stored` 表示字节已经在服务端，重试不必再传。
    public var state: String
    public var name: String
    public var contentType: String
    public var byteSize: Int
    public var sha256: String
    public var width: Int?
    public var height: Int?
    /// 这一条是何时开始传的：7 天后由清扫丢掉（与草稿 TTL 对齐）。
    public var createdAt: Date

    public init(slot: Int, attachmentId: String? = nil, state: String = "pending",
                name: String, contentType: String, byteSize: Int, sha256: String,
                width: Int? = nil, height: Int? = nil, createdAt: Date) {
        self.slot = slot
        self.attachmentId = attachmentId
        self.state = state
        self.name = name
        self.contentType = contentType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.width = width
        self.height = height
        self.createdAt = createdAt
    }

    /// 字节已经在服务端：重试时只需要 `begin` 复核，不再 `upload`。
    public var isStored: Bool { state == "stored" }
}

/// 本机待上传队列：`clientRef → [FeedbackPendingUpload]`，一封信一组。
///
/// 存 `Caches/feedback/pending-uploads.json`（与镜像分开、但不进镜像）；字节在
/// ``FeedbackAttachmentDisk`` 的暂存区。两个目录由同一个 `clear()` 一起清。
public struct FeedbackPendingUploads: Codable, Sendable, Equatable {
    public var letters: [String: [FeedbackPendingUpload]]

    /// 待上传记录保留多久：与草稿 TTL 对齐（设计 §3.3 的 7 天）。
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    public init(letters: [String: [FeedbackPendingUpload]] = [:]) {
        self.letters = letters
    }

    public var clientRefs: [String] { letters.keys.sorted() }

    /// 一封信的队列，按 slot 升序（提交时服务端也按 slot 排）。
    public func queue(for clientRef: String) -> [FeedbackPendingUpload] {
        (letters[clientRef] ?? []).sorted { $0.slot < $1.slot }
    }

    /// 有几封信还挂着未完成的附件（界面上"还有 N 封没发完"用它）。
    public var letterCount: Int { letters.values.filter { !$0.isEmpty }.count }

    public mutating func put(_ upload: FeedbackPendingUpload, for clientRef: String) {
        var items = letters[clientRef] ?? []
        if let index = items.firstIndex(where: { $0.slot == upload.slot }) {
            items[index] = upload
        } else {
            items.append(upload)
        }
        letters[clientRef] = items.sorted { $0.slot < $1.slot }
    }

    public mutating func remove(clientRef: String) {
        letters.removeValue(forKey: clientRef)
    }

    /// 丢掉过期的记录（7 天）：返回被丢掉的那些 `clientRef`，调用方据此删暂存字节。
    public mutating func prune(now: Date = Date()) -> [String] {
        var dropped: [String] = []
        for (clientRef, items) in letters {
            let kept = items.filter { now.timeIntervalSince($0.createdAt) < Self.retention }
            if kept.isEmpty {
                letters.removeValue(forKey: clientRef)
                dropped.append(clientRef)
            } else if kept.count != items.count {
                letters[clientRef] = kept
            }
        }
        return dropped
    }
}

/// 本机附件字节的唯一所有者：**下载缓存**与**发送暂存**都归它。
///
/// 两个子目录分开（缓存可丢、暂存要跨重启），但**清理入口只有一个**
/// （``clear()``，`FeedbackCenter.clearLocalMirror()` 调它）。
/// 镜像 `inbox.json` 只存元数据，一个字节都不放进去。
public struct FeedbackAttachmentDisk: Sendable {
    public let root: URL?

    public init(root: URL? = nil) {
        self.root = root
    }

    /// 下载缓存：`Caches/feedback/attachments/<sha256>`（按摘要分桶，命中即不再请求）。
    var cacheDirectory: URL {
        (root ?? FeedbackLocalStore.defaultRoot).appendingPathComponent("attachments", isDirectory: true)
    }

    /// 发送暂存：`Application Support/feedback/outgoing/<clientRef>/<slot>.bin`。
    ///
    /// **不写 Caches**：Caches 会被系统在后台清掉，而这份字节要跨重启重试
    /// （设计 §3.6）。测试传 `root` 时两处都落在同一个临时根下。
    var outgoingDirectory: URL {
        (root ?? Self.defaultStorageRoot).appendingPathComponent("outgoing", isDirectory: true)
    }

    /// 生产是 `Application Support/feedback`（跨重启可重试的那类数据）。
    static var defaultStorageRoot: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["DSH_FEEDBACK_STORE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("feedback", isDirectory: true)
    }

    func cacheURL(sha256: String) -> URL {
        cacheDirectory.appendingPathComponent(sha256)
    }

    func stagedURL(clientRef: String, slot: Int) -> URL {
        outgoingDirectory
            .appendingPathComponent(clientRef, isDirectory: true)
            .appendingPathComponent("\(slot).bin")
    }

    // MARK: - 下载缓存

    /// 写一份下载缓存（同摘要覆盖，内容一致所以幂等）。
    public func storeCache(_ data: Data, sha256: String) {
        let url = cacheURL(sha256: sha256)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func cachedBytes(sha256: String) -> Data? {
        try? Data(contentsOf: cacheURL(sha256: sha256))
    }

    // MARK: - 发送暂存

    /// 把要上传的字节写到暂存区；重试时从这里读，不必再让用户选一次。
    @discardableResult
    public func stage(_ attachment: FeedbackOutgoingAttachment, clientRef: String, slot: Int) -> Bool {
        let url = stagedURL(clientRef: clientRef, slot: slot)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try attachment.data.write(to: url, options: .atomic)
            return true
        } catch {
            feedbackLog("attachment stage failed: \(error)")
            return false
        }
    }

    public func stagedBytes(clientRef: String, slot: Int) -> Data? {
        try? Data(contentsOf: stagedURL(clientRef: clientRef, slot: slot))
    }

    /// 一封信的暂存字节全部删掉（提交成功、或用户放弃时）。
    public func removeStaged(clientRef: String) {
        try? FileManager.default.removeItem(
            at: outgoingDirectory.appendingPathComponent(clientRef, isDirectory: true))
    }

    /// 丢掉没有待上传记录认领的暂存文件（7 天前的）：启动时调一次。
    public func pruneStaged(keeping clientRefs: Set<String>, now: Date = Date(),
                            retention: TimeInterval = FeedbackPendingUploads.retention) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: outgoingDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let stale = now.timeIntervalSince(modification(of: entry) ?? now) >= retention
            if !clientRefs.contains(entry.lastPathComponent) || stale {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    #if DEBUG
    /// 截图钩子（`-DSHFeedbackSeedMirror`）：把目录下以 `<sha256>` 命名的文件逐个
    /// 拷进下载缓存（同名覆盖）。失败只记日志——截图是调试路径，不弹窗也不中断。
    func seedCache(from directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            feedbackLog("seed attachments: no directory at \(directory.path)")
            return
        }
        for entry in entries where !entry.hasDirectoryPath {
            guard let data = try? Data(contentsOf: entry) else { continue }
            storeCache(data, sha256: entry.lastPathComponent)
        }
    }
    #endif

    /// **唯一的清理入口**：下载缓存 + 发送暂存一起清（设置页"清除本地缓存"调）。
    public func clear() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.removeItem(at: outgoingDirectory)
    }

    private func modification(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// 待上传队列的落盘（`Caches/feedback/pending-uploads.json`）。
public struct FeedbackPendingUploadStore: Sendable {
    public let root: URL?

    public init(root: URL? = nil) {
        self.root = root
    }

    var url: URL {
        (root ?? FeedbackAttachmentDisk.defaultStorageRoot)
            .appendingPathComponent("pending-uploads.json")
    }

    public func load() -> FeedbackPendingUploads {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? Self.decoder.decode(FeedbackPendingUploads.self, from: data)
        else { return FeedbackPendingUploads() }
        return decoded
    }

    public func save(_ uploads: FeedbackPendingUploads) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.encoder.encode(uploads).write(to: url, options: .atomic)
        } catch {
            feedbackLog("pending uploads save failed: \(error)")
        }
    }

    /// 一封信的待上传记录（按 slot 升序）。
    public func queue(for clientRef: String) -> [FeedbackPendingUpload] {
        load().queue(for: clientRef)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

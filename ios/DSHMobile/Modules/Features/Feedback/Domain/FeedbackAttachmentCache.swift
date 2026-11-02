import DSHFoundation
import Foundation
import RelayKit

/// 附件的加载器：`fetch` → 用元数据里的 sha256 自校验 → 落缓存 → 复用。
///
/// 这是 §5.1-8 的客户端半边：**服务端只在写入时核摘要**，磁盘上的文件若被外部改坏成
/// 同样大小，`fetch` 会如实送出坏字节；所以客户端必须自己算一遍。校验不过按失败态
/// 返回（调用方给重试入口），而且**不写缓存**——坏字节进了缓存就再也不会重取。
///
/// 同一个 sha256 的并发请求合并成一次；命中缓存不再发请求。字节只在
/// ``FeedbackAttachmentDisk`` 的缓存目录里，一个字节都不进 `inbox.json`。
@MainActor
@Observable
public final class FeedbackAttachmentCache {

    /// 一次加载的失败原因：要么是协议层错误，要么是"字节与摘要不符"。
    public enum LoadError: Error, Equatable {
        case client(FeedbackClientError)
        case digestMismatch(expected: String, actual: String)
    }

    private let disk: FeedbackAttachmentDisk
    /// 真正去取字节的实现（由 `FeedbackCenter` 注入：它才知道地址与令牌）。
    private let fetch: @MainActor (String) async throws -> Data
    /// 同一个摘要的并发请求只发一次（UI 的两个缩略图同时出现时也只取一次）。
    private var inFlight: [String: Task<Data, Error>] = [:]

    public init(disk: FeedbackAttachmentDisk,
                fetch: @escaping @MainActor (String) async throws -> Data) {
        self.disk = disk
        self.fetch = fetch
    }

    /// 命中缓存直接给字节；否则取一次、校验摘要、落缓存。
    public func data(for attachment: FeedbackAttachment) async throws -> Data {
        let digest = attachment.sha256
        if !digest.isEmpty, let cached = disk.cachedBytes(sha256: digest) {
            return cached
        }
        if let running = inFlight[digest] {
            return try await value(of: running)
        }
        let task = Task { [fetch] in
            let bytes = try await fetch(attachment.attachmentId)
            let actual = FeedbackOutgoingAttachment.sha256Hex(bytes)
            guard digest.isEmpty || actual == digest else {
                throw LoadError.digestMismatch(expected: digest, actual: actual)
            }
            return bytes
        }
        inFlight[digest] = task
        defer { inFlight[digest] = nil }
        let bytes = try await value(of: task)
        if !digest.isEmpty {
            disk.storeCache(bytes, sha256: digest)
        }
        return bytes
    }

    /// 缓存里有没有（UI 可以先画占位，避免闪烁）。
    public func cached(_ attachment: FeedbackAttachment) -> Data? {
        disk.cachedBytes(sha256: attachment.sha256)
    }

    /// 清缓存（与镜像、暂存同一个入口：`FeedbackCenter.clearLocalMirror()`）。
    public func clear() {
        disk.clear()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private func value(of task: Task<Data, Error>) async throws -> Data {
        do {
            return try await task.value
        } catch let error as LoadError {
            throw error
        } catch let error as FeedbackClientError {
            throw LoadError.client(error)
        } catch {
            throw LoadError.client(.network(String(describing: error)))
        }
    }
}

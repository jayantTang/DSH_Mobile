import Foundation

// MARK: - 图片原图变体（契约 §2.1）
//
// 一张消息图片在电脑上可能有两份字节：Host 归一化后的**预览**（模型真正收到的
// 那张），以及用户原封不动上传的**原图**（只在用户主动「查看原图」时才下载）。
// 连接器自己回答 `_link/imageOriginal*`，把两者的关联持久化在 Host 侧，所以重装
// App、重新配对、换设备之后仍能取回。这里只有线上形状；状态机在 Chat 域。

/// 预览图片对应的原图元数据（连接器索引里的一行）。
public struct ImageOriginalMetadata: Sendable, Equatable, Hashable, Decodable {
    /// 原图字节的 SHA-256（`sha256:<hex>`），下载后必须逐字节校验。
    public let attachmentId: String
    public let name: String
    public let bytes: Int
    public let mediaType: String?

    public init(attachmentId: String, name: String, bytes: Int, mediaType: String? = nil) {
        self.attachmentId = attachmentId
        self.name = name
        self.bytes = bytes
        self.mediaType = mediaType
    }
}

/// 查一次原图：有就说清元数据，没有就说清是哪一类"没有"。
///
/// `reason` 是稳定短码（`missing` / `cleaned` / `unsupported`），**不是**给用户看的
/// 文案：界面按它显示「原图不可用」，并且不再自动重试。
public enum ImageOriginalLookup: Sendable, Equatable {
    case available(ImageOriginalMetadata)
    /// `missing`：索引里没有（旧数据、Host 已清理）；`cleaned`：有索引但对象文件没了；
    /// `unsupported`：连接器没注入图片变体服务（旧连接器）。
    case unavailable(reason: String)
}

extension ImageOriginalLookup: Decodable {
    private enum CodingKeys: String, CodingKey {
        case available, original, reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let available = (try? container.decode(Bool.self, forKey: .available)) ?? false
        if available, let original = try? container.decode(ImageOriginalMetadata.self, forKey: .original) {
            self = .available(original)
            return
        }
        self = .unavailable(
            reason: (try? container.decode(String.self, forKey: .reason)) ?? "missing"
        )
    }
}

/// 原图的一小段字节。`bytes` 是**整张原图**的大小，`eof` 只在最后一段为 true。
///
/// 连接器按区间读文件，一次默认 512 KiB，所以原图永远不会整份进内存。
public struct ImageOriginalChunk: Sendable, Equatable {
    public let data: Data
    public let offset: Int
    public let eof: Bool
    /// 原图总字节数（不是本段长度）。
    public let bytes: Int

    public init(data: Data, offset: Int, eof: Bool, bytes: Int) {
        self.data = data
        self.offset = offset
        self.eof = eof
        self.bytes = bytes
    }
}

extension ImageOriginalChunk: Decodable {
    private enum CodingKeys: String, CodingKey {
        case data, offset, eof, bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode(String.self, forKey: .data)
        guard let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                forKey: .data, in: container, debugDescription: "chunk data is not base64"
            )
        }
        self.init(
            data: data,
            offset: try container.decode(Int.self, forKey: .offset),
            eof: try container.decode(Bool.self, forKey: .eof),
            bytes: try container.decode(Int.self, forKey: .bytes)
        )
    }
}

/// `_link/imageCommit` 的结果：预览收据 + 可选原图 + 可选文件收据。
public struct ImageCommitValue: Sendable, Equatable {
    public struct Preview: Sendable, Equatable {
        public let receiptId: String
        /// Host 归一化后的预览引用（宽高、字节数、媒体类型由 Host 回填）。
        public let image: ContentBlock.ImageAttachment
    }

    /// 预览提交结果；**nil 表示这张图没有预览**（预览生成失败，按文件发送）。
    public let preview: Preview?
    /// 成功保存了原图变体时的元数据；按文件发送或没有原图时为 nil。
    public let original: ImageOriginalMetadata?
    /// `sendOriginalAsFile` 时原图作为普通文件上传后的收据（prompt 里再加一个
    /// `.file(receiptId:)`，用户就能下载原图）。
    public let fileReceiptId: String?
    /// 原图没能成为变体的原因（`tooLarge` / `undecodable` / `failed` / `unsupported`）。
    public let originalReason: String?
}

extension ImageCommitValue: Decodable {
    private enum CodingKeys: String, CodingKey {
        case preview, original, fileReceiptId, originalReason
    }

    private struct PreviewPayload: Decodable {
        let receiptId: String
        let image: ImagePayload
    }

    private struct ImagePayload: Decodable {
        let attachmentId: String?
        let mediaType: String?
        let bytes: Int?
        let width: Int?
        let height: Int?
        let name: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preview = try container.decodeIfPresent(PreviewPayload.self, forKey: .preview).map { payload in
            Preview(
                receiptId: payload.receiptId,
                image: ContentBlock.ImageAttachment(
                    attachmentId: payload.image.attachmentId ?? "",
                    mediaType: payload.image.mediaType ?? "image/jpeg",
                    bytes: payload.image.bytes,
                    width: payload.image.width,
                    height: payload.image.height,
                    name: payload.image.name
                )
            )
        }
        original = try container.decodeIfPresent(ImageOriginalMetadata.self, forKey: .original)
        fileReceiptId = try container.decodeIfPresent(String.self, forKey: .fileReceiptId)
        originalReason = try container.decodeIfPresent(String.self, forKey: .originalReason)
    }
}

/// 暂存在**电脑上**的一份待提交字节（预览或原图）。
///
/// `path` 由 relay 上传回包（`StagedFile.path`）给出，连接器只接受
/// `$DSH_HOME/inbox/<sessionId>/` 下的文件；越界会得到 `image/invalid-path`。
public struct ImageVariantUpload: Encodable, Sendable, Equatable {
    public let path: String
    public let mediaType: String
    public let name: String

    public init(path: String, mediaType: String, name: String) {
        self.path = path
        self.mediaType = mediaType
        self.name = name
    }
}

// MARK: - Errors

/// 旧连接器没有 `_link/imageCommit` / `_link/imageOriginal*`。
///
/// 发送路径**必须**据此回退到内联预览；查看原图路径据此显示「原图不可用」。
/// 它不是网络失败，重试多少次结果都一样。
public struct ImageVariantsUnsupported: Error, Sendable, Equatable, LocalizedError {
    /// 能力探测在**调用之前**就判定不支持时，由调用方直接抛出这个错误
    /// （`AttachmentImageVariants` 的降级判定，IR-10）：与连接器回 `link/unsupported`
    /// 是同一种结局，用户看到同一句「原图不可用」。
    public init() {}

    public var errorDescription: String? {
        String(localized: "电脑上的连接器版本过旧，请更新后重发")
    }
}

/// 原图已不可取回（索引缺失或对象文件已清理）。
///
/// 稳定短码与 ``ImageOriginalLookup/unavailable(reason:)`` 同一套；调用方据此
/// 落成 `.unavailable`，不要当成网络失败去重试。
public struct ImageOriginalUnavailable: Error, Sendable, Equatable, LocalizedError {
    public let reason: String

    public var errorDescription: String? {
        String(localized: "原图下载失败，点按重试")
    }
}

// MARK: - Wire argument shapes

/// `_link/imageCommit` 的 args（契约 §1.1）。`sendOriginalAsFile` 只在 true 时出现：
/// 连接器把缺省当 false，显式 `false` 与缺省同义，少发一个字段就少一处漂移。
struct ImageCommitArgs: Encodable, Sendable {
    let sessionId: String
    /// 预览缺席＝这张图只有原图（预览生成失败），按文件发送。
    let preview: ImageVariantUpload?
    let original: ImageVariantUpload?
    let sendOriginalAsFile: Bool?
}

struct ImageOriginalArgs: Encodable, Sendable {
    let attachmentId: String
}

struct ImageOriginalChunkArgs: Encodable, Sendable {
    let attachmentId: String
    let offset: Int
    let length: Int
}

// MARK: - Client

extension DSHClient {

    /// 把一份预览（以及可选的原图）提交给连接器（`_link/imageCommit`）。
    ///
    /// `preview.path` / `original.path` 必须是 relay 刚落在电脑上的暂存文件路径。
    /// 连接器负责：预览交给 Host 归一化、原图写进索引（或按文件上传）、最后删掉
    /// 自己用过的暂存文件。旧连接器回 `link/unsupported`，这里翻成
    /// ``ImageVariantsUnsupported``，发送路径据此回退内联预览。
    public func commitImage(
        sessionId: String,
        preview: ImageVariantUpload?,
        original: ImageVariantUpload?,
        sendOriginalAsFile: Bool
    ) async throws -> ImageCommitValue {
        do {
            return try await carrier.unary(
                method: "_link/imageCommit",
                args: ImageCommitArgs(
                    sessionId: sessionId,
                    preview: preview,
                    original: original,
                    sendOriginalAsFile: sendOriginalAsFile ? true : nil
                ),
                as: ImageCommitValue.self
            )
        } catch {
            throw Self.mapImageVariantError(error)
        }
    }

    /// 只查元数据，不读字节（`_link/imageOriginal`）。
    ///
    /// `missing` / `cleaned` **不是**错误：它们是"原图不可用"的两个正常结局，
    /// 直接落成 `.unavailable`，免得调用方把一次查询失败写进网络重试。
    public func imageOriginal(attachmentId: String) async throws -> ImageOriginalLookup {
        do {
            return try await carrier.unary(
                method: "_link/imageOriginal",
                args: ImageOriginalArgs(attachmentId: attachmentId),
                as: ImageOriginalLookup.self
            )
        } catch let failure as DSHRPCFailure {
            switch failure.code {
            case "image-original/missing":
                return .unavailable(reason: "missing")
            case "image-original/cleaned":
                return .unavailable(reason: "cleaned")
            case "link/unsupported":
                throw ImageVariantsUnsupported()
            default:
                throw failure
            }
        }
    }

    /// 按区间取原图字节（`_link/imageOriginalChunk`）。
    ///
    /// 连接器只读请求区间，`length` 缺省 512 KiB、上限 1 MiB（这里总是显式传，
    /// 让分片大小只有一个来源）。索引/对象缺失翻成 ``ImageOriginalUnavailable``。
    public func imageOriginalChunk(
        attachmentId: String,
        offset: Int,
        length: Int
    ) async throws -> ImageOriginalChunk {
        do {
            return try await carrier.unary(
                method: "_link/imageOriginalChunk",
                args: ImageOriginalChunkArgs(
                    attachmentId: attachmentId, offset: offset, length: length
                ),
                as: ImageOriginalChunk.self
            )
        } catch {
            throw Self.mapImageVariantError(error)
        }
    }

    private static func mapImageVariantError(_ error: any Error) -> any Error {
        guard let failure = error as? DSHRPCFailure else { return error }
        switch failure.code {
        case "link/unsupported":
            return ImageVariantsUnsupported()
        case "image-original/missing":
            return ImageOriginalUnavailable(reason: "missing")
        case "image-original/cleaned":
            return ImageOriginalUnavailable(reason: "cleaned")
        default:
            return error
        }
    }
}

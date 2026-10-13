import Compression
import Foundation

/// `_link/sessionDigest` 的响应信封（spec 021）。
///
/// 连接器把宿主那份 `session/list` 裁掉 App 侧零读取点的字段后，按调用方要求选择编码：
/// `identity`（直接给 JSON）或 `deflate-raw`（RFC1951 原始 DEFLATE 的 base64）。
///
/// **为什么是原始 DEFLATE**：Apple 的 `Compression` 框架（`COMPRESSION_ZLIB`）一行就能解它，
/// gzip 包装它不认（那样得引 libz 的 `inflateInit2(MAX_WBITS+16)` 做 C 互操作）。
/// 连接器侧实测两者压缩比相同（239 KiB → 36.8 KiB）。
public struct SessionDigestEnvelope: Sendable, Decodable {
    public let encoding: String
    /// `identity` 时是列表值本身，`deflate-raw` 时是 base64 字符串；两种形态都可能出现。
    public let value: JSONValue
    /// 解压后的字节长度：`compression_decode_buffer` 必须预先给足输出缓冲区，
    /// 连接器带上它，这里就能一次分配到位，不必"猜容量、失败再翻倍重试"。
    public let rawBytes: Int?
}

/// 解信封时可能出的问题。
public enum SessionDigestError: Error, Equatable {
    /// 连接器回了一种这个版本不认识的编码（协议往前走了或中间被改写）。
    case unsupportedEncoding(String)
    /// base64 不是合法 base64。
    case badBase64
    /// 没有 `rawBytes`，无法给解压分配缓冲区。
    case missingRawBytes
    /// `rawBytes` 超出合理范围（防御：别为一份畸形响应分配几百 MB）。
    case rawBytesOutOfRange(Int)
    /// DEFLATE 解不开（或解出来的长度与 `rawBytes` 不符）。
    case inflateFailed
}

/// 把信封解成 `SessionListValue`。
///
/// `identity` 走"重编码再解码"这条既有路径（与 `LinkCarrier.unary` 同一手法）；
/// `deflate-raw` 先 base64 解码，再用 `Compression` 一次性解到 `rawBytes` 大小的缓冲区。
///
/// 上限 32 MiB 与中转的帧上限一致：比这更大的 `rawBytes` 是畸形响应，不是大盘数据。
public func decodeSessionDigest(_ envelope: SessionDigestEnvelope,
                                limit: Int = 32 * 1024 * 1024) throws -> SessionListValue {
    switch envelope.encoding {
    case "identity":
        let data = try JSONEncoder().encode(envelope.value)
        return try JSONDecoder().decode(SessionListValue.self, from: data)
    case "deflate-raw":
        guard let rawBytes = envelope.rawBytes else { throw SessionDigestError.missingRawBytes }
        guard rawBytes > 0, rawBytes <= limit else {
            throw SessionDigestError.rawBytesOutOfRange(rawBytes)
        }
        guard case .string(let base64) = envelope.value, let packed = Data(base64Encoded: base64) else {
            throw SessionDigestError.badBase64
        }
        return try decodeInflated(packed, rawBytes: rawBytes)
    default:
        throw SessionDigestError.unsupportedEncoding(envelope.encoding)
    }
}

/// 原始 DEFLATE → `SessionListValue`。
private func decodeInflated(_ packed: Data, rawBytes: Int) throws -> SessionListValue {
    var out = Data(count: rawBytes)
    let written = out.withUnsafeMutableBytes { destination -> Int in
        packed.withUnsafeBytes { source -> Int in
            guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                  let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dst, rawBytes, src, packed.count, nil, COMPRESSION_ZLIB)
        }
    }
    // `compression_decode_buffer` 回 0 表示"解不开或缓冲区不够"；带上 rawBytes 之后
    // 缓冲区不够不该发生，所以这里一律按解不开报。
    guard written == rawBytes else { throw SessionDigestError.inflateFailed }
    return try JSONDecoder().decode(SessionListValue.self, from: out)
}

/**
 * `_link/sessionWindow` 的可选压缩（能力 `history-compression`）。
 *
 * 为什么在应用层压：中转的 WebSocket 关闭了 permessage-deflate（`compress=False`），
 * iOS 的 `URLSessionWebSocketTask` 也不支持协商压缩。要在不动中转的前提下减少
 * 公网字节，只能在连接器把 value 压成 DEFLATE、手机侧自己解（与 spec 021 的
 * `_link/sessionDigest` 同一套信封与同一种编码）。
 *
 * 编码选 `deflate-raw`（RFC1951）而不是 gzip：Apple `Compression` 框架的
 * `COMPRESSION_ZLIB` 直接解原始 DEFLATE，gzip 包装还得引 libz。
 *
 * 兼容：不传 `encoding` 或传了不认识的值时原样返回 JSON，老 App 行为不变；
 * 新 App 只在 `_link/hello` 声明了 `history-compression` 时才请求压缩。
 */

import { deflateRawSync } from 'node:zlib'

/// 与 `session-digest.js` 的 `DEFLATE_ENCODING` 同一词表（协议里只能有一个名字）。
export const HISTORY_COMPRESSION_ENCODING = 'deflate-raw'

/// 能力名：连接器在 `_link/hello` 里声明，手机据此决定要不要请求压缩。
export const HISTORY_COMPRESSION_CAPABILITY = 'history-compression'

/// 把一页的值包成 `{encoding, value(base64), rawBytes}` 信封。
///
/// `rawBytes` 是解压后的字节数：`compression_decode_buffer` 必须先知道输出多大，
/// 让连接器一次给足，手机就不用"猜容量、失败再翻倍"。
export function compressHistoryValue(value) {
  const raw = Buffer.from(JSON.stringify(value ?? null), 'utf8')
  return {
    encoding: HISTORY_COMPRESSION_ENCODING,
    value: deflateRawSync(raw).toString('base64'),
    rawBytes: raw.length,
  }
}

/// 按调用方要求决定压不压。只有明确要 `deflate-raw` 才压。
export function maybeCompressHistoryValue(value, encoding) {
  return encoding === HISTORY_COMPRESSION_ENCODING ? compressHistoryValue(value) : value
}

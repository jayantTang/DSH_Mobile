/**
 * `_link/sessionDigest`：`session/list` 的精简同形副本（spec 021）。
 *
 * 为什么要有它：`session/list` 占经中转下行字节的 **96%**，一次固定 714 KB，而中转出口实测只有
 * 16–112 KB/s（2026-10-13 现场诊断）。其中 **58.8% 的字节是 App/DSHKit 从来不读的字段**
 * （逐字段扫 79 个源文件核对，清单见 `contracts/session-digest.md` §4）。
 *
 * 三条硬约束：
 *   1. **不动 `session/list`**：老 App 只认它，字段删掉就没有回退路径。
 *   2. **不改入参**：宿主返回什么就基于它生成新对象，方便"同一份数据两条路径"逐字节对比。
 *   3. **只删名单里的**：名单之外的字段（包括以后宿主新增的）一律原样透传，避免"裁剪"变成"猜"。
 */

import { deflateRawSync } from 'node:zlib'

/** 方法名（设备发起，中转不校验方法名，所以不需要中转改动）。 */
export const SESSION_DIGEST_METHOD = '_link/sessionDigest'

/** 会话项里剔掉的字段：零读取点（`agentAvailable` 1.8%）。 */
export const DROPPED_ITEM_KEYS = Object.freeze(['agentAvailable'])

/**
 * 投影键里剔掉的字段（合计 56.7%）。
 *
 * 每一条都能在 App/DSHKit 里复查"零读取点"：
 * `turnOutline` 33.4%（每轮 prompt/response 原文）、`imageLimits` 6.2%（上传限制）、
 * `sessionStats` 4.2%、`todos` 2.6%、`subagentCatalog` 2.6%、`contextBreakdown` 2.5%、
 * `sessionListMetadata` 1.9%（唯一被读的 `blank` 在顶层已有同名字段）、
 * `subagentTiming` 1.5%、`agentPreset` 0.8%（`SessionCreateRequest.agentPreset` 是请求字段）。
 */
export const DROPPED_PROJECTION_KEYS = Object.freeze([
  'turnOutline', 'imageLimits', 'sessionStats', 'todos', 'subagentCatalog',
  'contextBreakdown', 'sessionListMetadata', 'subagentTiming', 'agentPreset',
])

/**
 * 只接受的压缩编码；其它一律按不压缩处理（保守，不因为多写一个字段就让调用方失败）。
 *
 * `deflate-raw` = RFC1951 原始 DEFLATE，**不带** gzip/zlib 包装。选它而不是 gzip 的原因是
 * 手机侧：Apple 的 `Compression` 框架（`COMPRESSION_ZLIB`）一行 `compression_decode_buffer`
 * 就能解开原始 DEFLATE，而 gzip 包装它不认，得引 libz 的 `inflateInit2(MAX_WBITS+16)` 做 C 互操作。
 * 两者压缩比实测相同（239 KiB → 36.8 KiB）。
 */
export const DEFLATE_ENCODING = 'deflate-raw'
export const IDENTITY_ENCODING = 'identity'

/** 按原键序复制并跳过剔除名单：键序稳定才能做"逐字节对比"。 */
function omit(source, dropped) {
  const out = {}
  for (const key of Object.keys(source)) {
    if (dropped.has(key)) continue
    out[key] = source[key]
  }
  return out
}

/**
 * 裁剪一份会话列表的**值**（`{ items: [...] }`）。
 *
 * 认两种输入（与 `trimHistoryPageForWire` 同款）：宿主信封 `{ ok, value: { items } }`，
 * 以及直接给的 `{ items }`。**返回的始终是列表值本身**，调用方不需要再猜信封在哪一层
 * （曾经因为这里保留信封、外面又包一层，响应成了 `{encoding, value:{ok, value:{items}}}`）。
 *
 * 结构不是预期的样子就**原样返回入参**——裁剪不许把"看不懂"变成"删掉"。
 *
 * @param {unknown} result 宿主响应或其 `value`
 * @returns {unknown} 裁剪后的列表值；不合法时原样返回入参
 */
export function digestSessionList(result) {
  if (result === null || typeof result !== 'object') return result
  const container = Array.isArray(result.items) ? result : result.value
  if (container === null || typeof container !== 'object' || !Array.isArray(container.items)) {
    return result
  }
  return { ...container, items: container.items.map(digestItem) }
}

/** 单条会话：剔顶层字段与投影键；`projections` 缺失或形状不对就原样留着。 */
function digestItem(item) {
  if (item === null || typeof item !== 'object') return item
  const out = omit(item, new Set(DROPPED_ITEM_KEYS))
  const projections = item.projections
  if (projections === null || typeof projections !== 'object') return out
  // `kind: "sequenced"` 是信封常量，App 侧模型没解码它（1.3%）。
  const envelope = omit(projections, new Set(['kind']))
  const values = projections.values
  if (values !== null && typeof values === 'object') {
    envelope.values = omit(values, new Set(DROPPED_PROJECTION_KEYS))
  }
  out.projections = envelope
  return out
}

/**
 * 按调用方要求编码裁剪后的值。
 *
 * **只在应用层压**：中转的 `WebSocketResponse(compress=False)`，手机侧
 * `URLSessionWebSocketTask` 也不支持 permessage-deflate，所以 WS 层压缩救不了手机那一跳。
 * 压缩后的字节 base64 放进 JSON 文本帧（与 `_link/diagnostics` 同款），中转不需要任何改动。
 *
 * `rawBytes` 是**解压后的字节长度**：Apple 的 `compression_decode_buffer` 必须预先给足输出缓冲区，
 * 带上它调用方就能一次分配到位，不必"猜容量、失败再翻倍重试"。
 *
 * @param {unknown} value 裁剪后的值
 * @param {unknown} encoding 调用方要求；只认 `"deflate-raw"`
 * @returns {{encoding: string, value: unknown, rawBytes?: number}} 带回执，调用方据此决定解不解压
 */
export function encodeDigest(value, encoding) {
  if (encoding !== DEFLATE_ENCODING) return { encoding: IDENTITY_ENCODING, value }
  const json = JSON.stringify(value ?? null)
  const raw = Buffer.from(json, 'utf8')
  return {
    encoding: DEFLATE_ENCODING,
    value: deflateRawSync(raw).toString('base64'),
    rawBytes: raw.length,
  }
}

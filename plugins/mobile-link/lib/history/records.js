/**
 * `_link/sessionWindow` / `_link/sessionFind` 共用的事件→记录件。
 *
 * 抽出来的理由与 `shared.js` 同一条（spec 007 T065）：窗口扫描、检索、探针三块
 * 都要按角色归类事件、都要按字节预算裁剪，放在 `history.js` 里会把那个文件撑到
 * 读不动，也确实漏过一次导入（`probe.js` 里 `bytesOf`/`summarizeEvents` 一直是
 * 未定义的名字）。
 *
 * 这里只有纯函数：没有 IO、没有服务状态。
 */

/// Host hard cap: `readEvent` rejects `before > 50` (`before must be an integer
/// between 0 and 50`). One chunk therefore yields at most 51 raw events.
export const WINDOW_CHUNK = 50

/// Defaults for one page. The phone may override both; the byte budget wins when
/// they disagree (measured: 51 raw events can already be 253KB on a long session).
export const DEFAULT_LIMIT = 60
export const DEFAULT_MAX_BYTES = 256 * 1024

/// Ceiling on how much one call reads, so a page request can never pin the
/// connector's serial inbox (measured: ~30ms per chunk on a 2.3k session).
export const MAX_CHUNKS_PER_CALL = 12

export function bytesOf(value) {
  try {
    return Buffer.byteLength(JSON.stringify(value), 'utf8')
  } catch {
    return -1
  }
}

export function summarizeEvents(events) {
  if (!Array.isArray(events) || events.length === 0) {
    return { count: 0, firstSeq: null, lastSeq: null, types: [] }
  }
  const types = [...new Set(events.map((event) => event?.type).filter(Boolean))].slice(0, 8)
  return {
    count: events.length,
    firstSeq: events[0]?.seq ?? null,
    lastSeq: events[events.length - 1]?.seq ?? null,
    types,
  }
}

export function toRecord(event) {
  return { type: 'event', event }
}

/// 去掉一条记录里**只用于诊断、渲染不读**的宿主模型输出日志。
///
/// 口径只有一份，写在这里由三条回包路径共用（精确窗口 / 搜索 / 旧分页），
/// 见 `specs/016-history-load-perf/contracts/history-record-trim.md`。
///
/// 为什么删：实测该字段占样本会话报文约 60%、占 assistant 记录 75.7%、
/// 占手机侧解码耗时约 94%（`specs/016-history-load-perf/research.md` §0），
/// 而产品路径没有任何消费者（`DSHKit` 里只有一句"不能拿它当流式判据"的注释）。
///
/// 两条纪律：
/// - **不就地改写**：宿主回包可能仍被别处引用（测试与探针都会再看一眼），
///   所以带该键时产生新的 `data` 对象，不带时按原对象返回（不复制、不白花时间）。
/// - **只删这一个键**：`message` / `usage` / `meta` / `arguments` 等一律原样，
///   删它们就是丢屏幕上要显示的内容。
export function trimRecordForWire(record) {
  const event = record?.event
  const data = event?.data
  if (data === null || typeof data !== 'object' || !('stream' in data)) return record
  const { stream: _dropped, ...rest } = data
  return { ...record, event: { ...event, data: rest } }
}

/// 一整页记录的同一条清洗（顺序与长度不变）。
export function trimRecordsForWire(records) {
  if (!Array.isArray(records)) return records
  return records.map(trimRecordForWire)
}

export function bytesOfRecords(records) {
  return bytesOf(records)
}

/// Drop the **oldest** end until the page fits. The newest edge must stay exact
/// (it is the seq the phone's window abuts), so trimming only ever happens here.
export function trimToBytes(records, maxBytes) {
  let truncated = false
  while (records.length > 1 && bytesOfRecords(records) > maxBytes) {
    records.shift()
    truncated = true
  }
  return truncated
}

/// Which of the three transcript roles one event belongs to (the phone's own
/// `TranscriptSearchHit.Role`).
///
/// `user/message` only counts as **me** when the event really came from the
/// user: measured on a real session, ~24% of `user/message` events are
/// plugin/system injections (`data.source.kind` other than `"user"`), and
/// agent-relayed ones carry a `data.source.rpcId` starting with `agent-`.
/// Events with no `data.source` at all predate the marker and stay `me`
/// (old-data compatibility). Non-`me` user messages return `undefined` —
/// they remain visible to full-text search, they just never enter the
/// "my questions" set (spec 009 T031).
export function roleOf(event) {
  const type = event?.type
  if (type === 'user/message') {
    const source = event?.data?.source
    if (source !== undefined && source !== null && typeof source === 'object') {
      if (source.kind !== undefined && source.kind !== 'user') return undefined
      if (typeof source.rpcId === 'string' && source.rpcId.startsWith('agent-')) return undefined
    }
    return 'me'
  }
  if (type === 'assistant/message') return 'agent'
  if (type === 'tool/call' || type === 'tool/result') return 'tool'
  return undefined
}

/// What the search hit is *displayed* as. Injected/relayed user messages are
/// not "me" for the curated set, but they are still user speech in full-text
/// search (spec 009: excluded from "我的提问", not from the corpus), so an
/// unfiltered search shows them under the user bucket.
export function displayRoleOf(event) {
  return roleOf(event) ?? (event?.type === 'user/message' ? 'me' : undefined)
}

/**
 * `_link/sessionWindow` 的**角色过滤**扫描（spec 016 的"来回次数"一条）。
 *
 * 为什么单独一条路径：未过滤的浏览翻页要的是"按 seq 精确的一段原始事件"，`readEvent`
 * 一次 51 条正合适；但**按角色过滤**（"只看我的提问"灌库、只看工具/助手）时，命中往往很稀疏，
 * 用 `readEvent` 就是"扫 12 块、每块 51 条、回 1 条"——实测一页 2.5–4.1 秒，而且随会话变长而变慢。
 *
 * 宿主另有一个按 seq 段过滤的接口（`sessionQuery.filterEvents`），**一次能覆盖 2000 个 seq**
 * （实测 420–500 ms，约 0.22 ms/seq，而 `readEvent` 是 4.4 ms/seq），返回的是**消息类文档**
 * （`user/message`、`assistant/message`、`tool/call`、`tool/result` 等），带 `seq` 与 `type`、
 * `data.source`——足够判断角色。所以：
 *
 *   1. 用 `filterEvents` 按 2000 seq 的块从新到旧定位**命中的 seq**；
 *   2. 把命中 seq 合并成 ≤51 宽的簇，**只对命中的那几簇** `readEvent` 取完整记录。
 *
 * 两点必须守住：
 * - **对外语义不变**：本模块返回的形状与 `scanOlder` 完全一致（`events` / `truncatedBy` /
 *   `clamped` / `exhausted` / `scannedFloor`），裁剪与分页仍由 `pageFrom` 一处决定。
 * - **`scanBoundary` 的承诺不破**：没取回来的命中必须能被下一页重新扫到，所以提前收工时
 *   `scannedFloor` 落在"真正取到的那一段"的最老 seq 上（见下）。
 */

import { MAX_CHUNKS_PER_CALL } from './records.js'

/// 一个 `filterEvents` 块覆盖多少 seq。实测 2000 seq ≈ 420–500 ms（含宿主侧过滤）。
export const FILTER_CHUNK = 2000

/// 一次调用最多扫几个 `filterEvents` 块：6 × 2000 = 12000 seq。
/// 取这个数是因为一块 ~0.5 s，六块 ~3 s，仍在宿主调用 8 s 预算内，且远小于一次超时。
export const MAX_FILTER_CHUNKS_PER_CALL = 6

/// 一次调用最多做几次"定向取完整记录"。命中稀疏时簇会多，这里封顶免得一次调用打太多来回。
export const MAX_FILTER_READS_PER_CALL = 8

/// `readEvent` 的 `before` 上限（宿主硬约束），一个簇因此最多覆盖 51 个 seq。
const READ_SPAN = MAX_CHUNKS_PER_CALL === 12 ? 50 : 50

/**
 * 把命中 seq 合并成"一次 `readEvent` 能覆盖"的簇。
 *
 * 升序返回 `[{from, to}]`，每个簇宽度 ≤ 51（`to - from ≤ 50`），
 * 这样 `readEvent({seq: to, before: 50})` 一定涵盖 `[from, to]`。
 */
export function clusterSeqs(seqs) {
  const sorted = [...new Set(seqs)].sort((a, b) => a - b)
  const clusters = []
  for (const seq of sorted) {
    const last = clusters[clusters.length - 1]
    if (last !== undefined && seq - last.from <= READ_SPAN) last.to = seq
    else clusters.push({ from: seq, to: seq })
  }
  return clusters
}

/**
 * 角色过滤扫描。与 `scanOlder` 同形返回。
 *
 * @param {object} input
 * @param {(sessionId: string, from: number, to: number) => Promise<{docs: Array, clamped?: boolean}>} input.readFilterChunk
 * @param {(sessionId: string, seq: number) => Promise<{window: {events: Array}, clamped?: boolean}>} input.readRecords
 * @param {string} input.sessionId
 * @param {number} input.before 最新边界（不含）
 * @param {number|undefined} input.through 下界（含）
 * @param {number} input.limit 目标记录条数
 * @param {Set<string>} input.roles 角色白名单
 * @param {(doc: unknown) => string|undefined} input.roleOf 角色判定（与原始事件同一份口径）
 *
 * 字节预算不在这里裁：命中记录要取回来才知道大小，统一交给 `pageFrom`（它同时负责
 * `truncatedBy='bytes'` 与 `scanBoundary` 的收口，与未过滤路径共用同一处规则）。
 */
export async function filteredScan({
  readFilterChunk, readRecords, newestSeq, sessionId, before, through, limit, roles, roleOf,
}) {
  let cursor = Math.min(before - 1, through ?? Number.MAX_SAFE_INTEGER)
  const matched = []
  let truncatedBy = null
  let clamped = false
  let exhausted = false
  let scannedFloor = null

  // **必须自己 clamp**：`filterEvents` 对越界的 seq 段**不报错、只回空数组**（`readEvent` 会抛
  // "has no event at seq"）。不 clamp 的后果实测过：某个日志只到 1208 的会话，App 传来的游标是
  // 投影的 asOfSeq（101473），新路径于是扫了六段空区间、返回空页并把 `scanBoundary` 推到 89474，
  // 调用方从这里往回读会**整段跳过**真实历史。`newestSeq` 与旧路径共用（会话内 5 秒缓存）。
  if (typeof newestSeq === 'function') {
    const newest = await newestSeq(sessionId)
    if (Number.isInteger(newest) && newest >= 0 && cursor > newest) {
      cursor = newest
      clamped = true
    }
  }

  if (cursor < 0) return { events: [], truncatedBy: null, clamped, exhausted: true, scannedFloor: 0 }

  for (let chunk = 0; chunk < MAX_FILTER_CHUNKS_PER_CALL && cursor >= 0; chunk += 1) {
    const from = Math.max(0, cursor - FILTER_CHUNK + 1)
    const { docs = [], clamped: thisClamped } = await readFilterChunk(sessionId, from, cursor)
    clamped = clamped || thisClamped === true
    scannedFloor = scannedFloor === null ? from : Math.min(scannedFloor, from)
    // 文档升序；从后往前插到队首，保持升序（与 scanOlder 同一手法）。
    for (let index = docs.length - 1; index >= 0; index -= 1) {
      const doc = docs[index]
      if (!Number.isInteger(doc?.seq) || doc.seq < from || doc.seq > cursor) continue
      if (!roles.has(roleOf(doc))) continue
      matched.unshift(doc)
    }
    if (matched.length >= limit) { truncatedBy = 'count'; break }
    const next = from - 1
    if (next < 0) { exhausted = true; break }
    cursor = next
  }

  // 命中 seq → 簇 → 只取命中那几簇的完整记录。簇太多时**只取最新的一段**，
  // 并把 `scannedFloor` 收到这一段的最老 seq：下一页会从这里往回扫，丢掉的命中还能被重新找到
  // （`pageFrom` 对过滤页用的正是 `scan.scannedFloor`）。
  const all = clusterSeqs(matched.map((doc) => doc.seq))
  const kept = all.slice(Math.max(0, all.length - MAX_FILTER_READS_PER_CALL))
  const wanted = new Set(matched.map((doc) => doc.seq))
  const events = []
  for (const cluster of kept) {
    const { window: result, clamped: thisClamped } = await readRecords(sessionId, cluster.to)
    clamped = clamped || thisClamped === true
    for (const event of Array.isArray(result?.events) ? result.events : []) {
      // **必须同时卡簇边界**：相邻簇的 `readEvent` 窗口会重叠（`before: 50` 往前多取 50 个 seq），
      // 只按 `wanted` 过滤会把上一个簇里的命中重复收进来（实测 48 号记录进了两页，两页并集少一条）。
      if (event?.seq >= cluster.from && event?.seq <= cluster.to && wanted.has(event.seq)) {
        events.push(event)
      }
    }
  }
  events.sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0))

  if (all.length > kept.length) {
    truncatedBy = truncatedBy ?? 'count'
    exhausted = false
    scannedFloor = kept.length > 0 ? kept[0].from : scannedFloor
  }

  return { events, truncatedBy, clamped, exhausted, scannedFloor }
}

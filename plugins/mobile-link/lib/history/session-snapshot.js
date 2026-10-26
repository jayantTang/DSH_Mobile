/**
 * 会话日志快照（spec 016 "来回次数"一条的第二步）。
 *
 * A1 把"扫描"从 `readEvent`（51 事件/块）换成 `filterEvents`（2000 seq/块）之后，单会话成本
 * 仍停在"每条命中一次 `readEvent`"这道墙上：实测 163 条命中 ≈ 163 个簇 × ~225 ms ≈ 37 秒。
 * 根因是宿主的**每次调用地板价**，不是扫描算法。
 *
 * 宿主另有一条 `readSession(sessionId)`：一次返回整份日志（2026-10-08 spike 实测 13k 会话
 * 116–315 ms，冷会话可用、不激活 Agent）。于是"要全量用户输入"这件事的正确做法是：
 *
 *   1. 一个会话**读一次**整份日志；
 *   2. 在连接器里按角色过滤（同一份 `roleOf` 口径）；
 *   3. 之后这个会话的每一页都从这份快照出，**不再打宿主**。
 *
 * 三条护栏（都是防"为了省几次调用把进程拖垮"）：
 * - **事件数上限**：超过 `MAX_EVENTS` 的会话不做快照，退回 A1 的分块路径（那些会话本来就少）。
 * - **条目上限 + TTL**：同时只留 `MAX_ENTRIES` 份、`TTL_MS` 到期即弃。灌库是串行的、搜索面板是
 *   单会话的，所以留一两份就够；过期即弃避免刚发出去的消息被旧快照盖住。
 * - **失败即弃**：宿主没有这个接口、抛错、或返回形状不对，一律返回 undefined（调用方退回 A1）。
 */

import { bytesOfRecords, toRecord } from './records.js'

/// 一份快照最多装多少条事件。超过就不快照（内存护栏）。
export const SNAPSHOT_MAX_EVENTS = 20_000
/// 同时留几份。灌库串行、面板单会话，两份足够覆盖"两台设备交替看"。
export const SNAPSHOT_MAX_ENTRIES = 2
/// 快照寿命（毫秒）。短一点，避免刚发出的提问被旧快照挡住。
export const SNAPSHOT_TTL_MS = 90_000

/**
 * 建一个按会话的快照缓存。
 *
 * @param {object} input
 * @param {(sessionId: string) => Promise<{events?: Array}>} input.readSession 宿主的整份读接口
 * @param {() => number} [input.now]
 */
export function createSnapshotCache({
  readSession, maxEvents = SNAPSHOT_MAX_EVENTS, maxEntries = SNAPSHOT_MAX_ENTRIES,
  ttlMs = SNAPSHOT_TTL_MS, now = Date.now,
} = {}) {
  const entries = new Map()

  /// 同一会话的并发读只打一次宿主（预热与首屏可能同时到）。
  const loading = new Map()

  function fresh(sessionId) {
    const cached = entries.get(sessionId)
    if (cached === undefined || now() - cached.at >= ttlMs) return undefined
    // LRU：命中后挪到队尾。
    entries.delete(sessionId)
    entries.set(sessionId, cached)
    return cached
  }

  async function load(sessionId) {
    if (typeof readSession !== 'function') return undefined
    let snapshot
    try {
      snapshot = await readSession(sessionId)
    } catch {
      return undefined
    }
    const events = snapshot?.events
    if (!Array.isArray(events) || events.length > maxEvents) return undefined
    const entry = {
      events,
      newestSeq: events.length > 0 ? events[events.length - 1].seq : -1,
      at: now(),
    }
    entries.set(sessionId, entry)
    while (entries.size > maxEntries) entries.delete(entries.keys().next().value)
    return entry
  }

  return {
    /** 命中且新鲜就返回；否则读一次；读不到/超限/形状不对一律 undefined。 */
    async get(sessionId) {
      const cached = fresh(sessionId)
      if (cached !== undefined) return cached
      const pending = loading.get(sessionId)
      if (pending !== undefined) return pending
      const task = load(sessionId).finally(() => loading.delete(sessionId))
      loading.set(sessionId, task)
      return task
    },
    /** 只看缓存，不读宿主（浏览翻页第一次请求用它，避免首屏多付一次整份读）。 */
    peek(sessionId) { return fresh(sessionId) },
    /** 后台预热：不阻塞当前请求，下一次翻页就能命中。 */
    warm(sessionId) {
      if (fresh(sessionId) !== undefined) return
      if (loading.has(sessionId)) return
      void this.get(sessionId)
    },
    invalidate(sessionId) { entries.delete(sessionId) },
    get size() { return entries.size },
  }
}

/**
 * 快照上的「再往旧读一批」读取器（概要 v2 用）：`(cursor) => {events, floorSeq, exhausted, clamped}`。
 *
 * 与 `scanSnapshot` 的区别只在职责：`scanSnapshot` 是"过滤 + 交给 `pageFrom` 裁一页"，
 * 这里只回答"seq ≤ cursor 的原始事件有哪些"，因为概要 v2 的分页单位是**整轮**，
 * 裁剪由 `summary-window.js` 按轮做。事件已经在内存里，所以这一层是同步的。
 */
export function snapshotOlderReader(snapshot) {
  const events = Array.isArray(snapshot?.events) ? snapshot.events : []
  const newest = Number.isInteger(snapshot?.newestSeq) ? snapshot.newestSeq : -1
  return (cursor) => {
    const batch = []
    for (const event of events) {
      if (!Number.isInteger(event?.seq)) continue
      if (event.seq > cursor) break
      batch.push(event)
    }
    const floorSeq = batch.length > 0 ? batch[0].seq : 0
    return {
      events: batch,
      floorSeq,
      // 日志被裁剪过时第一条的 seq 可能不是 0；下一次读到空批就自然收敛（见调用方）。
      exhausted: floorSeq === 0,
      clamped: cursor > newest,
    }
  }
}

/**
 * 从快照扫一页。**纯函数**，返回形状与 `scanOlder` / `filteredScan` 完全一致，
 * 于是裁剪与分页仍然由 `pageFrom` 一处决定。
 *
 * 与分块路径的差别只在"看了多少"：快照里我们已经拥有整段，所以 `scannedFloor` 是**这段区间的
 * 下界**（而不是"扫到第几块就停"），空页因此能一次推进到底。
 */
export function scanSnapshot(snapshot, { before, through, limit, maxBytes = 256 * 1024, roles, roleOf }) {
  // `through` 与 `scanOlder` 同义：它只**封顶新边**（`cursor = min(before-1, through)`），
  // 不是下界——扫描一律往下走到 seq 0。
  const requested = Math.min(before - 1, through ?? Number.MAX_SAFE_INTEGER)
  const newest = Number.isInteger(snapshot?.newestSeq) ? snapshot.newestSeq : -1
  const clamped = requested > newest
  const upper = clamped ? newest : requested
  if (upper < 0) {
    return { events: [], truncatedBy: null, clamped, exhausted: true, scannedFloor: 0 }
  }
  const matches = []
  for (const event of snapshot.events ?? []) {
    const seq = event?.seq
    if (!Number.isInteger(seq) || seq > upper) continue
    if (roles !== undefined && !roles.has(roleOf(event))) continue
    matches.push(event)
  }
  matches.sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0))

  // **裁剪只由 `pageFrom` 一处做**（模块契约）：这里把区间内全部命中交出去，另给三个信号。
  //
  // `exhausted` 的含义与 `scanOlder` 对齐：它表示"这道区间里所有命中都交出去了、下面没有了"，
  // 而不是"我看过整段"。不这么定就会出错：快照一次就能看到全部命中，若直接设 true，
  // `pageFrom` 按条数裁掉一部分后会给出 `hasMore=false`，调用方停手，被裁掉的命中永远拿不到。
  // 而 `scannedFloor` 保持 0（= 真下界）也只在"没被裁"时才被 `pageFrom` 当作 `scanBoundary`；
  // 一旦裁剪发生，`pageFrom` 会改用页内最老记录，调用方据此续读，不重不漏。
  const moreThanOnePage = matches.length > limit
    || bytesOfRecords(matches.map(toRecord)) >= maxBytes
  return {
    events: matches,
    truncatedBy: moreThanOnePage ? (matches.length > limit ? 'count' : 'bytes') : null,
    clamped,
    exhausted: !moreThanOnePage,
    scannedFloor: 0,
  }
}

/**
 * 概要 v2 的**整轮切页**（能力 `history-fold-summary-v2`）。
 *
 * 规格（`maintainers/设计/20261025-过程折叠-对齐桌面.md` §3.4 第 5 条）：
 * 窗口**从轮次边界开始、到轮次边界结束**；一页装不下整轮就少给轮次，不能给半轮。
 * 这样手机侧不再出现"记录不完整"与"连续孤立摘要"两种 UI（设计 §5 G9）。
 *
 * 唯一的 IO 是调用方给的 `readOlder(cursor)`，返回 `seq ≤ cursor` 的原始事件
 * （升序）+ `floorSeq` / `exhausted` / `clamped`。两个实现（会话快照 / 分块回读）
 * 形状相同，所以这里可以纯逻辑地单测。
 *
 * 三条不变量，任何改动都不许破坏：
 * 1. **绝不下发半轮**：一轮的事件没读全（到了调用上限或时间预算）就整轮丢掉；
 *    连最新一轮都读不全时回可重试错误，而不是给一段残缺的过程。
 * 2. **至少给一轮**：`limit` 比一轮投影后的记录数还小也照给这一轮——否则翻页会卡在
 *    同一处永远前进不了（客户端按 `startSeq` 当游标）。
 * 3. **游标落在轮次边界**：`startSeq` 永远是某个 `turn/start`（或日志真正的起点），
 *    下一次请求 `before = startSeq` 正好落在上一轮的 `turn/end` 之后。
 */

import { projectTurnUnit } from './fold-summary.js'

/// 一次调用最多回读多少批原始事件。分块路径一批 51 条（宿主 `readEvent` 的上限），
/// 64 批 ≈ 3264 条 ≈ 1.5–2 s；快照路径一批就是整份日志，用不到这个数。
export const SUMMARY_MAX_BATCHES = 64
/// 一次调用最多花多久在"往回读"上（毫秒）。到点即按"没读全"处理，绝不下发半轮。
export const SUMMARY_DEADLINE_MS = 6000
/// 一页最多塞多少轮。防"预算设得极大 + 会话极长"时把一页做成整份日志。
export const SUMMARY_MAX_UNITS = 200

const EMPTY_PAGE = {
  records: [], summaries: [], startSeq: null, endSeq: null,
  hasMore: false, truncatedBy: null, clamped: false,
}

/**
 * 从 `upper` 往回按整轮取一页。
 *
 * @param {object} input
 * @param {(cursor: number) => ({events?: Array<object>, floorSeq?: number, exhausted?: boolean, clamped?: boolean})
 *   | Promise<object>} input.readOlder 往回读一批（`seq ≤ cursor`）
 * @param {number} input.upper 本页最新一条的 seq（含）
 * @param {number} input.limit 本页最多几**轮**（本模式的页单位是轮；普通窗口里它是记录条数）
 * @param {number} input.maxBytes 字节预算（按**投影后**的下发记录算）
 * @param {boolean} [input.clamped] 调用方已经把上界夹到日志最新（越界请求）
 * @param {number} [input.maxBatches] 回读批数上限
 * @param {number} [input.deadlineMs] 回读时间上限
 * @param {() => number} [input.now] 时钟（测试用）
 * @returns {Promise<object>} 页；`{error:{code,message}}` 表示这一页取不出来
 */
export async function readSummaryPage({
  readOlder,
  upper,
  limit,
  maxBytes,
  clamped: upperClamped = false,
  maxBatches = SUMMARY_MAX_BATCHES,
  deadlineMs = SUMMARY_DEADLINE_MS,
  now = Date.now,
}) {
  if (!Number.isInteger(upper) || upper < 0) return { ...EMPTY_PAGE }
  const startedAt = now()
  const stack = []
  let nextRead = upper
  let exhausted = false
  let capped = false
  let clamped = upperClamped === true
  let batches = 0

  const budgetSpent = () => batches >= maxBatches || now() - startedAt >= deadlineMs

  async function fill() {
    if (stack.length > 0 || exhausted) return
    if (budgetSpent()) { capped = true; return }
    const batch = await readOlder(nextRead)
    batches += 1
    if (batch?.clamped === true) clamped = true
    const events = Array.isArray(batch?.events) ? batch.events : []
    for (const event of events) {
      if (!Number.isInteger(event?.seq) || event.seq > nextRead) continue
      stack.push(event)
    }
    const floorSeq = Number.isInteger(batch?.floorSeq)
      ? batch.floorSeq
      : (events[0]?.seq ?? 0)
    if (batch?.exhausted === true || floorSeq <= 0 || events.length === 0) exhausted = true
    nextRead = Math.min(nextRead, floorSeq) - 1
  }

  /// 读一轮：往回读到 `turn/start`（含）为止。`complete` 为假表示没读全（上限/没数据），
  /// 调用方必须整轮丢掉。
  async function readUnit() {
    const events = []
    while (true) {
      await fill()
      if (stack.length === 0) return { events: events.reverse(), complete: exhausted }
      const event = stack.pop()
      events.push(event)
      if (event.type === 'turn/start') return { events: events.reverse(), complete: true }
    }
  }

  const kept = []
  let byteCount = 0
  let unitsSeen = 0
  let droppedHalf = false
  let stop = null

  for (let index = 0; index < SUMMARY_MAX_UNITS; index += 1) {
    const { events, complete } = await readUnit()
    if (events.length === 0) { stop ??= 'done'; break }
    unitsSeen += 1
    if (!complete) {
      // 半轮：整轮丢掉（最新一轮也不破例，宁可报错让客户端重试）。
      droppedHalf = true
      stop = 'incomplete'
      break
    }
    const projected = projectTurnUnit(events)
    if (projected.records.length > 0) {
      // 字节预算只约束"较旧的那些轮"：最新的这一轮无论如何都要给全（宁可超一点，
      // 也不给半轮、也不让客户端永远看不到当前轮）。
      if (kept.length > 0 && byteCount + projected.bytes > maxBytes) { stop = 'bytes'; break }
      // 页边界取**整轮原始事件**的首尾，不是首尾下发记录：一轮起点前的
      // `request/header` 之类虽然在 v2 里不下发，但它们确实属于这一页的 seq 段，
      // 游标必须越过它们，否则下一次请求会把同一段重扫一遍。
      kept.push({
        ...projected,
        unitStartSeq: events[0].seq,
        unitEndSeq: events[events.length - 1].seq,
      })
      byteCount += projected.bytes
    }
    if (kept.length >= limit) { stop = 'count'; break }
    if (byteCount >= maxBytes) { stop = 'bytes'; break }
    if (exhausted && stack.length === 0) { stop = 'done'; break }
  }
  if (stop === null) stop = 'units'

  if (kept.length === 0) {
    if (droppedHalf && unitsSeen > 0) {
      return {
        error: {
          code: 'link/too-large',
          message: 'one turn cannot be read within a single page; retry',
        },
      }
    }
    return { ...EMPTY_PAGE, clamped }
  }

  const ordered = [...kept].reverse()
  const records = ordered.flatMap((unit) => unit.records)
  const summaries = ordered.flatMap((unit) => unit.summaries)
  return {
    records,
    summaries,
    startSeq: ordered[0].unitStartSeq,
    endSeq: ordered[ordered.length - 1].unitEndSeq,
    // "还有更早的"只由"往回读到底没有"回答：预算停下、或者被回读上限截住，
    // 都还有更早的轮次。游标永远是 `startSeq`（一轮的起点），不靠猜。
    hasMore: !(exhausted && stack.length === 0),
    truncatedBy: stop === 'count' ? 'count' : stop === 'bytes' ? 'bytes' : null,
    clamped,
    batches,
    units: ordered.length,
  }
}

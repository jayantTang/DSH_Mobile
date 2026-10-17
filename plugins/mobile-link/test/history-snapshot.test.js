/**
 * A2（会话快照）的专测。
 *
 * 这一层的价值主张只有一条：**把"每条命中一次宿主调用"换成"一个会话读一次"**。
 * 所以测试不能只断言"页对了"，还要断言宿主调用次数——否则等于没测到这个改动。
 */

import test from 'node:test'
import assert from 'node:assert/strict'

import { createHistoryService, WINDOW_METHOD } from '../lib/history.js'
import {
  SNAPSHOT_MAX_ENTRIES, createSnapshotCache, scanSnapshot,
} from '../lib/history/session-snapshot.js'
import { pageFrom, scanOlder } from '../lib/history/window.js'
import { roleOf, DEFAULT_LIMIT } from '../lib/history/records.js'

const MESSAGE_TYPES = new Set(['user/message', 'assistant/message', 'tool/call', 'tool/result'])
const ADDRESS = { kind: 'session', sessionId: 'session-snapshot' }

/** 每 4 条一个 me；其余 assistant（与过滤路径的测试同一形状）。 */
function makeLog(count) {
  return Array.from({ length: count }, (_, seq) => ({
    type: seq % 4 === 0 ? 'user/message' : 'assistant/message',
    seq,
    time: 1_700_000_000_000 + seq,
    data: { text: `event ${seq}` },
  }))
}

/** 带 `readSession` 的假宿主；记下每种调用次数。 */
function fakeQuery(log, { withReadSession = true, failRead = false, readSessionDelayMs = 0 } = {}) {
  const calls = { readEvent: 0, filterEvents: 0, listEvents: 0, readSession: 0 }
  const query = {
    calls,
    async readEvent({ sessionId, seq, before }) {
      calls.readEvent += 1
      if (before < 0 || before > 50) throw new Error('before must be an integer between 0 and 50')
      if (seq < 0 || seq >= log.length) throw new Error(`session "${sessionId}" has no event at seq ${seq}`)
      const start = Math.max(0, seq - before)
      return { sessionId, events: log.slice(start, seq + 1), startSeq: start, endSeq: seq }
    },
    async listEvents() {
      calls.listEvents += 1
      return log.map(({ seq, type, time }) => ({ seq, type, time }))
    },
    async filterEvents(sessionId, filters) {
      calls.filterEvents += 1
      const range = (filters ?? []).find((filter) => filter.kind === 'seq')
      if (range === undefined) return []
      return log
        .filter((event) => event.seq >= range.from && event.seq <= range.to && MESSAGE_TYPES.has(event.type))
        .map(({ seq, type, time, data }) => ({ sessionId, seq, type, time, data }))
    },
  }
  if (withReadSession) {
    query.readSession = async (sessionId) => {
      calls.readSession += 1
      if (readSessionDelayMs > 0) await new Promise((resolve) => setTimeout(resolve, readSessionDelayMs))
      if (failRead) throw new Error('readSession is unavailable')
      return { sessionId, events: log, startSeq: 0, endSeq: log.length - 1 }
    }
  }
  return query
}

function bound(query) {
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  service.bindQuery(query)
  return service
}

/** 旧路径（分块扫描 + 同一处裁剪）：等价性对照。 */
async function legacyPage(log, args) {
  const query = fakeQuery(log, { withReadSession: false })
  const roles = args.roles === undefined ? undefined : new Set(args.roles)
  const scan = await scanOlder({
    readChunk: (sessionId, seq) => query.readEvent({ sessionId, seq, before: 50, after: 0 })
      .then((window) => ({ window, clamped: false })),
    sessionId: ADDRESS.sessionId,
    before: args.before,
    through: args.through,
    limit: args.limit ?? DEFAULT_LIMIT,
    maxBytes: args.maxBytes ?? 256 * 1024,
    roles,
  })
  return pageFrom(scan, { limit: args.limit ?? DEFAULT_LIMIT, maxBytes: args.maxBytes ?? 256 * 1024, roles })
}

// ── 缓存本身 ────────────────────────────────────────────────────────────────

test('快照缓存：命中不重读，TTL 到期重读', async () => {
  let clock = 1_000
  let reads = 0
  const cache = createSnapshotCache({
    readSession: async () => { reads += 1; return { events: makeLog(10) } },
    ttlMs: 1_000, now: () => clock,
  })
  await cache.get('a')
  await cache.get('a')
  assert.equal(reads, 1, 'TTL 内只读一次')
  clock += 1_001
  await cache.get('a')
  assert.equal(reads, 2, '过期要重读')
})

test('快照缓存：事件数超过护栏就不缓存（返回 undefined，调用方退回分块路径）', async () => {
  const cache = createSnapshotCache({
    readSession: async () => ({ events: makeLog(100) }), maxEvents: 50,
  })
  assert.equal(await cache.get('big'), undefined)
  assert.equal(cache.size, 0)
})

test('快照缓存：读失败、没有该接口、形状不对都只是 undefined（不许抛）', async () => {
  assert.equal(await createSnapshotCache({ readSession: async () => { throw new Error('boom') } }).get('a'), undefined)
  assert.equal(await createSnapshotCache({}).get('a'), undefined)
  assert.equal(await createSnapshotCache({ readSession: async () => ({ nope: true }) }).get('a'), undefined)
})

test('快照缓存：条目上限生效（LRU 淘汰最旧）', async () => {
  const cache = createSnapshotCache({ readSession: async (id) => ({ events: makeLog(5), id }), maxEntries: 2 })
  await cache.get('a'); await cache.get('b'); await cache.get('c')
  assert.equal(cache.size, SNAPSHOT_MAX_ENTRIES)
  assert.equal(cache.size, 2)
})

// ── 快照扫描 ────────────────────────────────────────────────────────────────

test('scanSnapshot：区间、角色、clamp 与空区间都对', () => {
  const snapshot = { events: makeLog(20), newestSeq: 19 }
  const roles = new Set(['me'])
  const page = scanSnapshot(snapshot, { before: 20, through: undefined, limit: 60, roles, roleOf })
  assert.deepEqual(page.events.map((event) => event.seq), [0, 4, 8, 12, 16])
  assert.equal(page.exhausted, true, '看到日志开头')
  assert.equal(page.scannedFloor, 0)
  assert.equal(page.clamped, false)

  const clamped = scanSnapshot(snapshot, { before: 999, through: undefined, limit: 60, roles, roleOf })
  assert.equal(clamped.clamped, true, '游标越过日志要如实报 clamped')
  assert.equal(clamped.events.length, page.events.length)

  // `through` 只封顶新边（与 scanOlder 同义），扫描仍一路走到 seq 0。
  const bounded = scanSnapshot(snapshot, { before: 20, through: 8, limit: 60, roles, roleOf })
  assert.deepEqual(bounded.events.map((event) => event.seq), [0, 4, 8])
  assert.equal(bounded.exhausted, true)
})

test('scanSnapshot：区间为空时不抛，如实报"扫过这里、没有更早"', () => {
  const page = scanSnapshot({ events: [], newestSeq: -1 }, { before: 10, through: undefined, limit: 60, roles: new Set(['me']), roleOf })
  assert.deepEqual(page.events, [])
  assert.equal(page.exhausted, true)
})

// ── 与旧路径等价 + 宿主调用次数 ──────────────────────────────────────────────

test('快照路径与旧路径逐条等价（记录/顺序/分页元数据）', async () => {
  const log = makeLog(600)
  const cases = [
    { before: 600, limit: 10, roles: ['me'] },
    { before: 300, limit: 25, roles: ['me'] },
    { before: 137, limit: 7, roles: ['me'] },
    { before: 600, limit: 200, maxBytes: 64 * 1024, roles: ['me'] },
  ]
  for (const args of cases) {
    const service = bound(fakeQuery(log))
    const fresh = await service.handle(WINDOW_METHOD, { address: ADDRESS, ...args })
    const legacy = await legacyPage(log, args)
    assert.equal(fresh.ok, true)
    const label = JSON.stringify(args)
    assert.deepEqual(fresh.value.records, legacy.records, `${label} 记录必须一致`)
    assert.equal(fresh.value.startSeq, legacy.startSeq, `${label} startSeq`)
    assert.equal(fresh.value.endSeq, legacy.endSeq, `${label} endSeq`)
    assert.equal(fresh.value.hasMore, legacy.hasMore, `${label} hasMore`)
    assert.equal(fresh.value.truncatedBy, legacy.truncatedBy, `${label} truncatedBy`)
    assert.equal(fresh.value.clamped, legacy.clamped, `${label} clamped`)
  }
})

test('核心主张：扫完一个会话只打一次宿主（对比旧路径的十几次）', async () => {
  const log = makeLog(12_000)
  const query = fakeQuery(log)
  const service = bound(query)
  let before = 12_000
  let pages = 0
  let records = 0
  for (let i = 0; i < 40; i += 1) {
    const result = await service.handle(WINDOW_METHOD,
      { address: ADDRESS, before, limit: 200, maxBytes: 256 * 1024, roles: ['me'] })
    assert.equal(result.ok, true)
    pages += 1
    records += result.value.records.length
    if (!result.value.hasMore) break
    before = result.value.scanBoundary ?? result.value.startSeq
    if (!before || before <= 0) break
  }
  assert.equal(records, 3_000, '12k 条日志里每 4 条一个 me')
  assert.equal(query.calls.readSession, 1, `整会话只该读一次快照，实际 ${query.calls.readSession}`)
  assert.equal(query.calls.readEvent, 0, '快照齐了就不该再逐簇取数')
  assert.equal(query.calls.filterEvents, 0, '也不该再分块定位')
  assert.ok(pages <= 20, `页数应当不多（limit 200 / 3000 条命中），实际 ${pages}`)
})

test('宿主没有 readSession 时退回分块路径（老宿主仍可用）', async () => {
  const log = makeLog(400)
  const query = fakeQuery(log, { withReadSession: false })
  const service = bound(query)
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 400, limit: 10, roles: ['me'] })
  assert.equal(page.ok, true)
  assert.deepEqual(page.value.records.map((record) => record.event.seq), [360, 364, 368, 372, 376, 380, 384, 388, 392, 396])
  assert.ok(query.calls.filterEvents > 0, '应当走 filterEvents 分块路径')
})

test('readSession 失败时退回分块路径，结果仍然正确', async () => {
  const log = makeLog(400)
  const query = fakeQuery(log, { failRead: true })
  const service = bound(query)
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 400, limit: 10, roles: ['me'] })
  assert.equal(page.ok, true)
  assert.equal(page.value.records.length, 10)
  assert.ok(query.calls.filterEvents > 0, '读快照失败要落到分块路径')
  assert.ok(query.calls.readEvent > 0)
})

test('未过滤路径：当前页仍实时读，后台预热；之后的更早页从快照出', async () => {
  const log = makeLog(300)
  const query = fakeQuery(log)
  const service = bound(query)
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 10 })
  const legacy = await legacyPage(log, { before: 300, limit: 10 })
  assert.deepEqual(page.value.records, legacy.records)
  assert.equal(page.value.scanBoundary, legacy.scanBoundary)
  // 首屏仍在实时窗口读（不能等整份快照）；预热是后台的，允许 0 或 1 次。
  assert.ok(query.calls.readSession <= 1)
  await new Promise((resolve) => setTimeout(resolve, 10))

  const beforeReads = query.calls.readEvent
  const older = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 280, limit: 10 })
  assert.ok(older.value.records.length > 0)
  assert.equal(query.calls.readEvent, beforeReads, '更早的页不该再逐块读宿主')
  assert.ok(query.calls.readSession >= 1, '后台预热应该已经读过一次整份日志')
})

test('快照路径天然按原始事件判角色：注入消息不会被算成"我"', async () => {
  const log = makeLog(40).map((event, seq) => {
    if (seq % 4 !== 0) return event
    return {
      ...event,
      data: seq === 8
        ? { text: 'injected', source: { kind: 'agent-instructions', form: 'instructions' } }
        : { text: 'mine', source: { kind: 'user', rpcId: `R-${seq}` } },
    }
  })
  const service = bound(fakeQuery(log))
  const page = await service.handle(WINDOW_METHOD,
    { address: ADDRESS, before: 40, limit: 50, maxBytes: 256 * 1024, roles: ['me'] })
  const seqs = page.value.records.map((record) => record.event.seq)
  assert.ok(!seqs.includes(8), `注入消息不该出现：${seqs.join(',')}`)
  assert.deepEqual(seqs, [0, 4, 12, 16, 20, 24, 28, 32, 36])
})

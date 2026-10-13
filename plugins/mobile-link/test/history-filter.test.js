/**
 * 过滤路径（spec 016 "来回次数"一条）的专测。
 *
 * 最重要的一条是**新旧等价**：同样的日志、同样的参数，新路径（`filterEvents` 定位 + 定向
 * `readEvent`）与旧路径（`readEvent` 51 条/块扫到底）必须给出**同一批记录、同一顺序**；
 * 分页元数据里只有 `scanBoundary` 允许不同（它的定义是"这次真正扫过的最老 seq"，块大小一变
 * 数值必然变），但"从它往回续读不重不漏"这个承诺必须两边都成立。
 */

import test from 'node:test'
import assert from 'node:assert/strict'

import { createHistoryService, WINDOW_METHOD } from '../lib/history.js'
import { clusterSeqs, FILTER_CHUNK, MAX_FILTER_CHUNKS_PER_CALL } from '../lib/history/filter-scan.js'
import { pageFrom, scanOlder } from '../lib/history/window.js'
import { roleOf, toRecord, DEFAULT_LIMIT } from '../lib/history/records.js'

const MESSAGE_TYPES = new Set(['user/message', 'assistant/message', 'tool/call', 'tool/result'])
const ADDRESS = { kind: 'session', sessionId: 'session-filter' }

/** 合成日志：每 4 条一个 me、每 7 条一个 tool/call，其余 assistant。 */
function makeLog(count) {
  return Array.from({ length: count }, (_, seq) => {
    const type = seq % 4 === 0 ? 'user/message' : seq % 7 === 0 ? 'tool/call' : 'assistant/message'
    return { type, seq, time: 1_700_000_000_000 + seq, data: { text: `event ${seq}` } }
  })
}

/** 宿主：`readEvent` 硬上限 50、`filterEvents` 只回消息类文档（按 seq 段）。 */
function fakeQuery(log, { withFilter = true } = {}) {
  const query = {
    async readEvent({ sessionId, seq, before }) {
      if (!Number.isInteger(before) || before < 0 || before > 50) {
        throw new Error('before must be an integer between 0 and 50')
      }
      if (!Number.isInteger(seq) || seq < 0 || seq >= log.length) {
        throw new Error(`session "${sessionId}" has no event at seq ${seq}`)
      }
      const start = Math.max(0, seq - before)
      return { sessionId, events: log.slice(start, seq + 1), startSeq: start, endSeq: seq }
    },
    async listEvents() { return log.map(({ seq, type, time }) => ({ seq, type, time })) },
  }
  if (withFilter) {
    query.filterEvents = async (sessionId, filters) => {
      const range = (filters ?? []).find((filter) => filter.kind === 'seq')
      if (range === undefined) return []
      // **照真实宿主：文档不带 `data`**（只有 seq/type/text）。角色判定必须回到原始事件上做，
      // 否则 `data.source` 缺失会让注入消息被算成 `me`——这条差异真机上发生过。
      return log
        .filter((event) => event.seq >= range.from && event.seq <= range.to && MESSAGE_TYPES.has(event.type))
        .map(({ seq, type, time }) => ({ sessionId, seq, type, time }))
    }
  }
  return query
}

function bound(query) {
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  service.bindQuery(query)
  return service
}

/** 旧路径（未过滤的扫描 + 同一处裁剪）：等价性对照。 */
async function legacyPage(log, args) {
  const query = fakeQuery(log)
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

test('clusterSeqs：一个簇不超过一次 readEvent 能覆盖的宽度', () => {
  assert.deepEqual(clusterSeqs([5, 6, 7]), [{ from: 5, to: 7 }])
  assert.deepEqual(clusterSeqs([0, 50, 51]), [{ from: 0, to: 50 }, { from: 51, to: 51 }],
    '跨度超过 50 就必须断开（readEvent 的 before 上限是 50）')
  assert.deepEqual(clusterSeqs([3, 3, 3]), [{ from: 3, to: 3 }], '去重')
  assert.deepEqual(clusterSeqs([]), [])
})

test('新旧等价：同样的日志与参数，记录与顺序逐条一致（scanBoundary 允许不同）', async () => {
  const log = makeLog(600)
  const cases = [
    { before: 600, limit: 10, roles: ['me'] },
    { before: 600, limit: 25, roles: ['me'] },
    { before: 300, limit: 10, roles: ['me'] },
    { before: 600, limit: 10, roles: ['tool'] },
    { before: 600, limit: 40, roles: ['me', 'tool'] },
    { before: 137, limit: 7, roles: ['me'] },
  ]
  for (const args of cases) {
    const service = bound(fakeQuery(log))
    const fresh = await service.handle(WINDOW_METHOD, { address: ADDRESS, ...args })
    const legacy = await legacyPage(log, args)
    assert.equal(fresh.ok, true, `${JSON.stringify(args)} 应当成功`)
    const label = JSON.stringify(args)
    assert.deepEqual(fresh.value.records.map((record) => record.event.seq),
      legacy.records.map((record) => record.event.seq), `${label} 的 seq 序列必须一致`)
    assert.deepEqual(fresh.value.records, legacy.records, `${label} 的记录内容必须一致`)
    assert.equal(fresh.value.startSeq, legacy.startSeq, `${label} startSeq`)
    assert.equal(fresh.value.endSeq, legacy.endSeq, `${label} endSeq`)
    assert.equal(fresh.value.hasMore, legacy.hasMore, `${label} hasMore`)
    assert.equal(fresh.value.truncatedBy, legacy.truncatedBy, `${label} truncatedBy`)
    assert.equal(fresh.value.clamped, legacy.clamped, `${label} clamped`)
  }
})

test('新旧等价：连续翻到日志开头，两边的整体序列一致（不重不漏）', async () => {
  const log = makeLog(400)
  const collect = async (fetch) => {
    const seqs = []
    let before = 400
    for (let page = 0; page < 40; page += 1) {
      const value = await fetch(before)
      if (value.records.length === 0 && !value.hasMore) break
      seqs.push(...value.records.map((record) => record.event.seq))
      if (!value.hasMore) break
      before = value.scanBoundary ?? value.startSeq
      if (before === null || before === undefined || before <= 0) break
    }
    return seqs
  }
  const service = bound(fakeQuery(log))
  const fresh = await collect(async (before) => {
    const result = await service.handle(WINDOW_METHOD,
      { address: ADDRESS, before, limit: 10, roles: ['me'] })
    assert.equal(result.ok, true)
    return result.value
  })
  // 旧路径按同样的续读规则走一遍
  const legacySeqs = []
  let before = 400
  for (let page = 0; page < 40; page += 1) {
    const value = await legacyPage(log, { before, limit: 10, roles: ['me'] })
    if (value.records.length === 0 && !value.hasMore) break
    legacySeqs.push(...value.records.map((record) => record.event.seq))
    if (!value.hasMore) break
    before = value.scanBoundary ?? value.startSeq
    if (before === null || before === undefined || before <= 0) break
  }
  assert.deepEqual(fresh, legacySeqs, '整条续读序列必须一致')
  // 记录在**页内升序**返回，整条续读序列按页拼接，所以不是全局降序；这里比"集合与条数"。
  assert.equal(fresh.length, new Set(fresh).size, '不能重复')
  assert.deepEqual([...fresh].sort((a, b) => a - b),
    makeLog(400).map((event) => event.seq).filter((seq) => seq % 4 === 0),
    '正好是全部 me，一条不漏')
})

test('宿主没有 filterEvents 时退回分块扫描（老宿主不能因此不可用）', async () => {
  const log = makeLog(300)
  const service = bound(fakeQuery(log, { withFilter: false }))
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 5, roles: ['me'] })
  assert.equal(page.ok, true)
  // 页内升序（老到新）：最老 280，最新 296。
  assert.deepEqual(page.value.records.map((record) => record.event.seq), [280, 284, 288, 292, 296])
})

test('长会话：一次调用扫不完时边界前进，续读能把剩下的找回来', async () => {
  const count = FILTER_CHUNK * (MAX_FILTER_CHUNKS_PER_CALL + 2)
  const log = makeLog(count).map((event) => ({ ...event, type: 'assistant/message' }))
  log[10] = { ...log[10], type: 'user/message' }
  const service = bound(fakeQuery(log))
  const first = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: count, limit: 10, roles: ['me'] })
  assert.equal(first.ok, true)
  assert.deepEqual(first.value.records, [], '第一次调用扫不到 seq 10')
  assert.ok(first.value.scanBoundary > 0, '边界必须前进')
  assert.equal(first.value.hasMore, true)
  const second = await service.handle(WINDOW_METHOD,
    { address: ADDRESS, before: first.value.scanBoundary, limit: 10, roles: ['me'] })
  assert.deepEqual(second.value.records.map((record) => record.event.seq), [10], '续读把那条找回来')
})

test('未过滤路径不受影响：记录、边界与老口径逐字一致', async () => {
  const log = makeLog(300)
  const service = bound(fakeQuery(log))
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 10 })
  const legacy = await legacyPage(log, { before: 300, limit: 10 })
  assert.deepEqual(page.value.records, legacy.records)
  assert.equal(page.value.scanBoundary, legacy.scanBoundary)
  assert.equal(page.value.hasMore, legacy.hasMore)
})

test('未过滤路径的字节预算仍按老口径裁（roles 缺省时走 scanOlder）', async () => {
  const log = makeLog(300).map((event, seq) => ({ ...event, data: { text: 'x'.repeat(seq % 3 === 0 ? 4000 : 10) } }))
  const service = bound(fakeQuery(log))
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 60, maxBytes: 8 * 1024 })
  const legacy = await legacyPage(log, { before: 300, limit: 60, maxBytes: 8 * 1024 })
  assert.deepEqual(page.value.records.map((r) => r.event.seq), legacy.records.map((r) => r.event.seq))
  assert.equal(page.value.truncatedBy, legacy.truncatedBy)
})

test('角色判定用的是同一份口径（toRecord/roleOf 与过滤路径一致）', () => {
  const log = makeLog(20)
  const me = log.filter((event) => roleOf(event) === 'me')
  assert.deepEqual(me.map((event) => event.seq), [0, 4, 8, 12, 16])
  assert.equal(toRecord(log[0]).event.seq, 0)
})

test('游标远大于日志（投影 asOfSeq 的情形）必须 clamp，不能扫地空转', async () => {
  // 真实现场：会话投影报 asOfSeq 101473，而日志只到 1208。`filterEvents` 对越界段不报错只回空，
  // 不 clamp 就会扫六段空区间、给出空页与一个虚高的 scanBoundary，调用方从这里往回读会整段跳过。
  const log = makeLog(1208)
  const service = bound(fakeQuery(log))
  const page = await service.handle(WINDOW_METHOD,
    { address: ADDRESS, before: 101474, limit: 10, roles: ['me'] })
  assert.equal(page.ok, true)
  assert.equal(page.value.clamped, true, '越界必须如实报 clamped')
  assert.deepEqual(page.value.records.map((record) => record.event.seq),
    [1168, 1172, 1176, 1180, 1184, 1188, 1192, 1196, 1200, 1204],
    'clamp 之后要给的是日志最新的那批 me（页内升序）')
  assert.ok(page.value.scanBoundary <= 1168, `边界必须落在真实范围内，实得 ${page.value.scanBoundary}`)
  assert.equal(page.value.hasMore, true)
})

test('注入型消息不许被算成"我"（doc 不带 data 时尤其要守住）', async () => {
  // seq 8 是一条 `user/message`，但来源是宿主注入（source.kind = agent-instructions），
  // 与"用户本人提问"必须区分开——spec 009 修过的就是这个（实测占 user/message 的 24%）。
  const log = makeLog(60).map((event, seq) => {
    if (seq % 4 !== 0) return event
    const injected = seq === 8
    return {
      ...event,
      data: injected
        ? { text: 'injected', source: { kind: 'agent-instructions', form: 'instructions' } }
        : { text: 'mine', source: { kind: 'user', rpcId: `R-${seq}` } },
    }
  })
  const service = bound(fakeQuery(log))
  const page = await service.handle(WINDOW_METHOD,
    { address: ADDRESS, before: 60, limit: 50, maxBytes: 256 * 1024, roles: ['me'] })
  assert.equal(page.ok, true)
  const seqs = page.value.records.map((record) => record.event.seq)
  assert.ok(!seqs.includes(8), `注入消息不该出现：${seqs.join(',')}`)
  assert.deepEqual(seqs, [0, 4, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56])
})

import test from 'node:test'
import assert from 'node:assert/strict'

import {
  WINDOW_METHOD, FIND_METHOD, WINDOW_CHUNK, DEFAULT_MAX_BYTES,
  createHistoryService, isHistoryMethod,
} from '../lib/history.js'

/// A synthetic log: one event per seq, `0 .. count - 1`.
function makeLog(count, { bigAt = new Map() } = {}) {
  return Array.from({ length: count }, (_, seq) => ({
    seq,
    type: seq % 3 === 0 ? 'user/message' : 'assistant/message',
    time: 1_700_000_000_000 + seq,
    data: bigAt.has(seq) ? { text: 'x'.repeat(bigAt.get(seq)) } : { text: `event ${seq}` },
  }))
}

/// The Host's own service, with the two behaviours the spike measured: a hard
/// cap of 50 on `before`, and a thrown error when the seq does not exist.
function fakeQuery(log, { delayMs = 0, onCall } = {}) {
  const calls = []
  return {
    calls,
    async readEvent({ sessionId, seq, before, after }) {
      calls.push({ method: 'readEvent', sessionId, seq, before, after })
      if (onCall) await onCall({ seq })
      if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs))
      if (!Number.isInteger(before) || before < 0 || before > 50) {
        throw new Error('before must be an integer between 0 and 50')
      }
      if (!Number.isInteger(seq) || seq < 0 || seq >= log.length) {
        throw new Error(`session "${sessionId}" has no event at seq ${seq}`)
      }
      const start = Math.max(0, seq - before)
      const events = log.slice(start, seq + 1)
      return { sessionId, events, startSeq: start, endSeq: seq }
    },
    async listEvents(sessionId) {
      calls.push({ method: 'listEvents', sessionId })
      return log.map((event) => ({ sessionId, seq: event.seq, type: event.type, time: event.time }))
    },
    /// 宿主的"按 seq 段过滤"接口：实测只回**消息类**文档（user/assistant/tool 那一族），
    /// 带 seq/type/data.source，足够判断角色。这里照这个口径模拟。
    async filterEvents(sessionId, filters) {
      calls.push({ method: 'filterEvents', sessionId, filters })
      if (onCall) await onCall({ filterEvents: true })
      const range = (filters ?? []).find((filter) => filter.kind === 'seq')
      if (range === undefined) return []
      return log
        .filter((event) => event.seq >= range.from && event.seq <= range.to)
        .filter((event) => MESSAGE_TYPES.has(event.type))
        .map((event) => ({ sessionId, seq: event.seq, type: event.type, time: event.time, data: event.data }))
    },
  }
}

/// 宿主 `filterEvents` 会回的消息类事件（其余 step/turn/goal 之类不在其中）。
const MESSAGE_TYPES = new Set(['user/message', 'assistant/message', 'tool/call', 'tool/result'])

const ADDRESS = { kind: 'session', sessionId: 'session-test' }

function bound(service, query) {
  service.bindQuery(query)
  return service
}

test('isHistoryMethod only claims the two reserved methods', () => {
  assert.equal(isHistoryMethod(WINDOW_METHOD), true)
  assert.equal(isHistoryMethod(FIND_METHOD), true)
  assert.equal(isHistoryMethod('session/page'), false)
})

test('without an injected service the answer is link/unsupported', async () => {
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 100 })
  assert.equal(result.ok, false)
  assert.equal(result.error.code, 'link/unsupported')
})

test('a window ends exactly at before-1 and is contiguous', async () => {
  const log = makeLog(500)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 60 })
  assert.equal(result.ok, true)
  const { records, startSeq, endSeq, hasMore } = result.value
  assert.equal(endSeq, 299, 'the newest edge is the seq the phone asked to end before')
  assert.equal(records[records.length - 1].event.seq, 299)
  assert.equal(records[0].event.seq, startSeq)
  assert.equal(records.length, 60, 'limit bounds the page')
  assert.equal(hasMore, true)
  const seqs = records.map((record) => record.event.seq)
  assert.deepEqual(seqs, Array.from({ length: 60 }, (_, index) => startSeq + index), 'no holes')
})

test('the log start is reported as "no more" instead of a hole', async () => {
  const log = makeLog(20)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 20, limit: 60 })
  assert.equal(result.value.startSeq, 0)
  assert.equal(result.value.endSeq, 19)
  assert.equal(result.value.hasMore, false)
})

test('the byte budget trims the oldest end and keeps the newest edge exact', async () => {
  // One huge event sits at the oldest end of the page; it must be the one dropped.
  const log = makeLog(120, { bigAt: new Map([[60, DEFAULT_MAX_BYTES]]) })
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 100, limit: 60 })
  const { records, endSeq, startSeq, truncatedBy } = result.value
  assert.equal(endSeq, 99)
  assert.equal(records[records.length - 1].event.seq, 99)
  assert.ok(startSeq > 41, `the oversized oldest event should be gone (startSeq=${startSeq})`)
  assert.equal(truncatedBy, 'bytes')
})

test('a request past a trimmed log clamps to the newest seq and says so', async () => {
  const log = makeLog(30)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 5000, limit: 10 })
  assert.equal(result.ok, true)
  assert.equal(result.value.endSeq, 29, 'clamped to the newest event the Host still has')
  assert.equal(result.value.clamped, true, 'the phone must be able to tell a trimmed log from a hole')
})

test('a normal page is not marked as clamped', async () => {
  const log = makeLog(200)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 100, limit: 10 })
  assert.equal(result.value.clamped, false)
})

test('a second window on the same session is refused as busy, not queued', async () => {
  const log = makeLog(500)
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const service = bound(
    createHistoryService({ logger: { warn() {}, info() {} } }),
    fakeQuery(log, { onCall: () => gate }),
  )
  const first = service.handle(WINDOW_METHOD, { address: ADDRESS, before: 400, limit: 10 })
  const second = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 10 })
  assert.equal(second.ok, false)
  assert.equal(second.error.code, 'link/busy')
  release()
  assert.equal((await first).ok, true)
})

test('a host call that never answers becomes link/timeout', async () => {
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  service.bindQuery({
    readEvent: () => new Promise(() => {}),
    listEvents: async () => [],
  })
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 10, limit: 5 })
  assert.equal(result.ok, false)
  assert.equal(result.error.code, 'link/timeout')
})

test('bad arguments are rejected before any host call', async () => {
  const log = makeLog(50)
  const query = fakeQuery(log)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  assert.equal((await service.handle(WINDOW_METHOD, { address: { kind: 'session' }, before: 10 })).error.code, 'gateway/bad-request')
  assert.equal((await service.handle(WINDOW_METHOD, { address: ADDRESS, before: -1 })).error.code, 'gateway/bad-request')
  assert.equal(query.calls.length, 0, 'nothing reached the Host')
})

test('an unknown session is reported as session/unknown', async () => {
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  service.bindQuery({
    readEvent: async () => { throw new Error('session "x" not found') },
    listEvents: async () => [],
  })
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 10 })
  assert.equal(result.error.code, 'session/unknown')
})

test('a subagent address reads the child session', async () => {
  const log = makeLog(80)
  const query = fakeQuery(log)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  await service.handle(WINDOW_METHOD, {
    address: { kind: 'subagent', parentSessionId: 'p', childSessionId: 'child', mode: 'unknown' },
    before: 60,
    limit: 5,
  })
  assert.equal(query.calls[0].sessionId, 'child')
})

test('chunking never asks the Host for more than its own cap', async () => {
  const log = makeLog(600)
  const query = fakeQuery(log)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 400, limit: 120 })
  assert.equal(result.ok, true)
  assert.equal(result.value.records.length, 120)
  for (const call of query.calls.filter((entry) => entry.method === 'readEvent')) {
    assert.ok(call.before <= WINDOW_CHUNK, `asked for ${call.before}, cap is ${WINDOW_CHUNK}`)
  }
})

test('in-session search is answered once the service is bound', async () => {
  const log = makeLog(50)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  // `fakeQuery` 没有 `filterEvents`：能力在但这条调用会炸，因此必须回可重试的错误，
  // 而不是"未实现"那一类。
  const result = await service.handle(FIND_METHOD, { address: ADDRESS, query: 'xx' })
  assert.notEqual(result.error?.code, 'link/not-implemented')
})

// ---------------------------------------------------------------------------
// _link/sessionFind（spec 007 T034/T035）
// ---------------------------------------------------------------------------

/// The Host service with an event corpus and `filterEvents` implementing the
/// "seq range AND literal text" semantics the connector relies on.
function fakeSearchQuery(log, { searchEvents } = {}) {
  return {
    async readEvent() { throw new Error('unused') },
    async listEvents(sessionId) {
      return log.map((event) => ({ sessionId, seq: event.seq, type: event.type, time: event.time }))
    },
    async filterEvents(_sessionId, filters) {
      const range = filters.find((f) => f.kind === 'seq')
      const text = filters.find((f) => f.kind === 'text')?.text ?? ''
      // 两种正文形态：老形态 `data.text`，真实形态 `data.message.content[].text`（016 的
      // 样本记录用后者，所以桩要能认，否则会把"搜不到"误读成清洗删掉了正文）。
      const textOf = (event) => String(
        event.data?.text
        ?? (event.data?.message?.content ?? []).map((block) => block?.text ?? '').join(''),
      )
      return log
        .filter((event) => event.seq >= range.from && event.seq <= range.to)
        .filter((event) => textOf(event).toLowerCase().includes(text.toLowerCase()))
        .map((event) => ({ seq: event.seq, type: event.type, time: event.time, text: textOf(event), data: event.data }))
    },
    ...(searchEvents === undefined ? {} : { searchEvents }),
  }
}

/// One searchable event per seq: every 4th is a user message mentioning `needle`.
function searchLog(count) {
  return Array.from({ length: count }, (_, seq) => ({
    seq,
    type: seq % 4 === 0 ? 'user/message' : (seq % 4 === 1 ? 'assistant/message' : 'tool/result'),
    time: 1_700_000_000_000 + seq,
    data: { text: seq % 4 === 0 ? `question ${seq} about needle` : `answer ${seq} about needle` },
  }))
}

const FIND_ARGS = { address: ADDRESS, query: 'needle' }

test('sessionFind returns hits with seq, role and highlight offsets', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(40)))
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 3, chunk: 40 })
  assert.equal(result.ok, true)
  assert.equal(result.value.hits.length, 3)
  assert.equal(result.value.source, 'scan')
  for (const hit of result.value.hits) {
    assert.ok(Number.isSafeInteger(hit.seq))
    assert.ok(['me', 'agent', 'tool'].includes(hit.role))
    assert.equal(hit.snippet.slice(hit.highlightStart, hit.highlightStart + hit.highlightLength), 'needle')
  }
  const seqs = result.value.hits.map((hit) => hit.seq)
  assert.deepEqual(seqs, [...seqs].sort((a, b) => b - a), '新的在前')
})

test('sessionFind pages older hits through the cursor', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(40)))
  const first = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 4, chunk: 10 })
  assert.equal(first.ok, true)
  assert.equal(first.value.hits.length, 4)
  assert.equal(first.value.hasMore, true)
  assert.ok(first.value.cursor !== null)
  // 进度：40 条 seq、片宽 10 → 4 片；一页扫了一片，还剩 3 片。
  assert.equal(first.value.totalChunks, 4, '片数由日志最新 seq 算出，第一页就该是精确的')
  assert.equal(first.value.remainingChunks, 3, '第一页扫完还剩 3 片')
  const second = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 4, chunk: 10, cursor: first.value.cursor })
  assert.equal(second.ok, true)
  const seqs = [...first.value.hits, ...second.value.hits].map((hit) => hit.seq)
  assert.equal(new Set(seqs).size, seqs.length, '两页不重复')
  assert.ok(Math.max(...second.value.hits.map((h) => h.seq)) < Math.min(...first.value.hits.map((h) => h.seq)),
    '第二页更旧')
  assert.equal(second.value.totalChunks, 4, '总数不随翻页变')
  assert.equal(second.value.remainingChunks, 2, '第二页之后还剩 2 片')
})

test('sessionFind reports the scan as finished only when it reached the oldest chunk', async () => {
  // 界面只有在 `hasMore === false` 时才敢写"已搜全部历史"；这里钉住这个前提。
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(5)))
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 50, chunk: 10 })
  assert.equal(result.ok, true)
  assert.equal(result.value.totalChunks, 1, '5 条 seq → 1 片')
  assert.equal(result.value.remainingChunks, 0, '扫完最老一片之后剩余为 0')
  assert.equal(result.value.hasMore, false, '到底了才允许界面说"全部历史"')
})

test('sessionFind honours the role filter (only my own questions)', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(40)))
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, roles: ['me'], limit: 20, chunk: 40 })
  assert.equal(result.ok, true)
  assert.ok(result.value.hits.length > 0)
  assert.ok(result.value.hits.every((hit) => hit.role === 'me'))
})

test('sessionFind accepts a single-character query, with progress to go with it', async () => {
  // owner 2026-10-17 把下限从 2 个字降到 1：一个字也搜全量，「命中太多」靠分页与片数进度兜住。
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(20)))
  const result = await service.handle(FIND_METHOD, { address: ADDRESS, query: 'q', limit: 3, chunk: 10 })
  assert.equal(result.ok, true)
  assert.ok(result.value.hits.length > 0, '一个字也要能搜出命中')
  assert.equal(result.value.totalChunks, 2, '片数照报')
  assert.ok(result.value.remainingChunks <= 2, '剩余片数照报')
})

test('sessionFind uses the index when the deployment has one', async () => {
  let calls = 0
  const query = fakeSearchQuery(searchLog(40), {
    searchEvents: async () => {
      calls += 1
      return { items: [{ seq: 12, type: 'user/message', snippet: 'a needle here', time: 1 }], hasMore: false }
    },
  })
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 5 })
  assert.equal(result.ok, true)
  assert.equal(result.value.source, 'index')
  assert.equal(calls, 1)
  assert.equal(result.value.hits[0].seq, 12)
})

test('sessionFind falls back to scanning when the index is closed', async () => {
  const query = fakeSearchQuery(searchLog(40), {
    searchEvents: async () => { throw new Error('session search is disabled') },
  })
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 3, chunk: 40 })
  assert.equal(result.ok, true)
  assert.equal(result.value.source, 'scan')
  assert.equal(result.value.hits.length, 3)
})

test('sessionFind caps how much it scans per call', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(2000)))
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 1000, chunk: 10 })
  assert.ok(result.value.scannedChunks <= 4, `扫了 ${result.value.scannedChunks} 块，上限是 4`)
  assert.equal(result.value.hasMore, true)
})

// 浏览模式（spec 008 的真机反馈修复）：没有关键词、只带 roles ⇒ 列出"我问过的全部提问"。
test('sessionFind 在无关键词 + roles 时列出提问（浏览模式）', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(40)))
  const result = await service.handle(FIND_METHOD, { address: ADDRESS, query: '', roles: ['me'], limit: 20, chunk: 40 })
  assert.equal(result.ok, true)
  assert.ok(result.value.hits.length > 0, '应该列出提问')
  assert.ok(result.value.hits.every((hit) => hit.role === 'me'), '只留我的提问')
  assert.equal(result.value.source, 'scan')
})

test('sessionFind 无关键词又无 roles 仍然拒绝（没有范围的扫描没有意义）', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(20)))
  const result = await service.handle(FIND_METHOD, { address: ADDRESS, query: '' })
  assert.equal(result.ok, false)
  assert.equal(result.error.code, 'link/query-too-short')
})

// ---------------------------------------------------------------------------
// spec 009 T031：roleOf 的 source 判定 + sessionWindow 的 roles 过滤
// ---------------------------------------------------------------------------

/// user/message 事件的三种来源：真用户（无 source，老数据）、插件注入、代理代发。
function sourcedLog() {
  const at = (seq, type, source) => ({
    seq,
    type,
    time: 1_700_000_000_000 + seq,
    data: { text: `event ${seq} needle`, ...(source === undefined ? {} : { source }) },
  })
  return [
    at(0, 'user/message', undefined),                            // 老数据：me
    at(1, 'user/message', { kind: 'plugin' }),                   // 插件注入：不算 me
    at(2, 'user/message', { kind: 'user', rpcId: 'agent-42' }),  // 代理代发：不算 me
    at(3, 'user/message', { kind: 'user', rpcId: 'rpc-7' }),     // 真用户：me
    at(4, 'assistant/message', undefined),
    at(5, 'user/message', { kind: 'system' }),                   // 系统注入：不算 me
    at(6, 'user/message', { kind: 'user' }),                     // 真用户：me
  ]
}

test('plugin 注入与 agent- 代发的 user/message 不算 me，缺省 source 的老数据算 me', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(sourcedLog()))
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, roles: ['me'], limit: 20, chunk: 40 })
  assert.equal(result.ok, true)
  const seqs = result.value.hits.map((hit) => hit.seq).sort((a, b) => a - b)
  assert.deepEqual(seqs, [0, 3, 6], '只留真用户的提问')
})

test('roles 缺省时全文搜索仍能看到插件注入的消息', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(sourcedLog()))
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 20, chunk: 40 })
  assert.equal(result.ok, true)
  const seqs = result.value.hits.map((hit) => hit.seq)
  assert.ok(seqs.includes(1) && seqs.includes(2) && seqs.includes(5), '不带 roles 不过滤')
})

test('sessionWindow 的 roles 过滤只改返回内容，不改 seq 边界', async () => {
  // 0..29：seq%3===0 是真用户提问，其余是 assistant；过滤后一页 10 条跨 30 个 seq。
  const log = makeLog(30)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 30, limit: 10, roles: ['me'] })
  assert.equal(page.ok, true)
  const { records, startSeq, endSeq, hasMore } = page.value
  assert.equal(records.length, 10)
  assert.ok(records.every((record) => record.event.type === 'user/message'))
  assert.equal(endSeq, 27, '最新的匹配是 seq 27，窗口右缘仍按 before 定')
  assert.equal(startSeq, 0, '10 条 me 恰好铺满整个日志')
  assert.equal(hasMore, false, '已经扫到日志开头')
})

test('sessionWindow roles 过滤的分页：hasMore 反映"更早还有匹配"，游标按 startSeq 续', async () => {
  const log = makeLog(100) // seq%3===0 是 me（0,3,…,99 → 34 条）
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const first = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 100, limit: 10, roles: ['me'] })
  assert.equal(first.ok, true)
  assert.equal(first.value.records.length, 10)
  assert.equal(first.value.hasMore, true, '日志更深处还有 me')
  assert.equal(first.value.endSeq, 99)
  const second = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: first.value.startSeq, limit: 10, roles: ['me'],
  })
  assert.equal(second.ok, true)
  const firstSeqs = first.value.records.map((record) => record.event.seq)
  const secondSeqs = second.value.records.map((record) => record.event.seq)
  assert.equal(new Set([...firstSeqs, ...secondSeqs]).size, firstSeqs.length + secondSeqs.length, '两页不重复')
  assert.ok(Math.max(...secondSeqs) < Math.min(...firstSeqs), '第二页更旧')
})

test('sessionWindow 拒绝未知的 role 词', async () => {
  const log = makeLog(10)
  const query = fakeQuery(log)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 10, roles: ['me', 'alien'] })
  assert.equal(result.ok, false)
  assert.equal(result.error.code, 'gateway/bad-request')
  assert.equal(query.calls.length, 0, '坏参数不该触达 Host')
})

test('sessionWindow 带 roles 但整页无匹配时返回空页且 hasMore 如实', async () => {
  const log = makeLog(10).map((event) => ({ ...event, type: 'assistant/message' }))
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 10, roles: ['me'] })
  assert.equal(result.ok, true)
  assert.equal(result.value.records.length, 0)
  assert.equal(result.value.hasMore, false, '已扫到日志开头，没有更多')
})

// ---------------------------------------------------------------------------
// spec 009 T039：扫描边界 scanBoundary（回填游标按"扫到哪"推进，空页不卡）
// ---------------------------------------------------------------------------

/// 1000 条里只有 seq 0 是 me：一次调用能把 12 个 chunk（612 个 seq）扫完，
/// 一个匹配都没有，但扫描确实往前走了一大截。
test('sessionWindow 整页被过滤为空时 scanBoundary 仍然前进（T039）', async () => {
  // 场景 A：整份日志没有一条 me —— 空页必须把边界推到日志开头并如实说"没有更早的了"。
  const none = makeLog(1000).map((event) => ({ ...event, type: 'assistant/message' }))
  const empty = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(none))
  const page = await empty.handle(WINDOW_METHOD, { address: ADDRESS, before: 1000, limit: 10, roles: ['me'] })
  assert.equal(page.ok, true)
  assert.deepEqual(page.value.records, [], '整页被滤空')
  assert.equal(page.value.startSeq, null, '空页给不出返回记录的边界（老口径不变）')
  assert.equal(page.value.scanBoundary, 0, '扫到了日志开头')
  assert.equal(page.value.hasMore, false, '确实没有更早的了')

  // 场景 B：唯一一条 me 在 seq 0，而日志比一次调用的扫描预算更长 ——
  // 空页仍必须**前进**（边界落在这轮真正扫过的下界），否则"我问过的"回填会在原地卡死。
  const long = makeLog(20000).map((event) => ({ ...event, type: 'assistant/message' }))
  long[0] = { ...long[0], type: 'user/message' }
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(long))
  const first = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 20000, limit: 10, roles: ['me'] })
  assert.equal(first.ok, true)
  assert.deepEqual(first.value.records, [], '这轮扫过的范围内没有 me')
  assert.ok(first.value.scanBoundary > 0 && first.value.scanBoundary < 20000,
    `边界要前进且不能跳过没看过的地方，实得 ${first.value.scanBoundary}`)
  assert.equal(first.value.hasMore, true, '更早还有没扫过的地方')
  const second = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: first.value.scanBoundary, limit: 10, roles: ['me'],
  })
  assert.equal(second.ok, true)
  assert.deepEqual(second.value.records.map((record) => record.event.seq), [0],
    '按边界续读要能找回剩下那条 me（不重不漏）')
})

test('sessionWindow 有返回时 scanBoundary 与页对齐，下一页不重不漏（T039）', async () => {
  // seq%5===0 是 me：一个 chunk（51 个 seq）里正好 10 条匹配，页满即停。
  const log = makeLog(300).map((event, seq) => ({ ...event, type: seq % 5 === 0 ? 'user/message' : 'assistant/message' }))
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const first = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 10, roles: ['me'] })
  assert.equal(first.ok, true)
  assert.equal(first.value.records.length, 10)
  assert.equal(first.value.startSeq, 250, '最老的一条返回记录')
  // 老口径这里是 249（旧 51 事件块的块头）；过滤路径按 2000 seq 分块后下界更靠下，但**定义与
  // 承诺不变**：`scanBoundary` 之下才是没看过的地方，从它往回续读不会重也不会漏（下面逐条断言）。
  assert.ok(first.value.scanBoundary <= first.value.startSeq, '扫描边界不高于页内最老记录')
  const second = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: first.value.scanBoundary, limit: 10, roles: ['me'],
  })
  assert.equal(second.ok, true)
  const firstSeqs = first.value.records.map((record) => record.event.seq)
  const secondSeqs = second.value.records.map((record) => record.event.seq)
  assert.ok(Math.max(...secondSeqs) < Math.min(...firstSeqs), '第二页严格更旧')
  assert.deepEqual(
    [...secondSeqs, ...firstSeqs],
    Array.from({ length: 20 }, (_, index) => 200 + index * 5),
    '两页接起来正好是 200..295 的全部 me，不重不漏')
})

test('sessionWindow 因 limit 截断丢记录时 scanBoundary 退回最老返回记录（不跳条）', async () => {
  // 全是 me：一个 chunk 51 条匹配 > limit 10，最老端被裁掉，那些被裁的记录
  // 没有回给手机，下一页必须重新扫到它们。
  const log = makeLog(1000).map((event) => ({ ...event, type: 'user/message' }))
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const first = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 1000, limit: 10, roles: ['me'] })
  assert.equal(first.ok, true)
  assert.equal(first.value.truncatedBy, 'count')
  assert.equal(first.value.startSeq, 990)
  assert.equal(first.value.scanBoundary, first.value.startSeq, '被裁掉的记录要留给下一页，边界不能越过它们')
  const second = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: first.value.scanBoundary, limit: 10, roles: ['me'],
  })
  assert.equal(second.value.records[second.value.records.length - 1].event.seq, 989, '紧接着上一页最老记录往下')
})

test('sessionWindow 不带 roles 时旧字段与老口径逐字不变（T039 兼容）', async () => {
  const log = makeLog(500)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 60 })
  assert.equal(page.ok, true)
  const { records, startSeq, endSeq, hasMore, clamped } = page.value
  assert.equal(endSeq, 299)
  assert.equal(startSeq, 240)
  assert.equal(records.length, 60)
  assert.equal(hasMore, true)
  assert.equal(clamped, false)
  assert.equal(page.value.scanBoundary, startSeq, '不带过滤时 scanBoundary 与 startSeq 同值（老客户端读的字段一字不改）')
  // 整页无匹配也不带 roles：老口径照旧（空页 + hasMore=false）。
  const empty = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 0, limit: 10 })
  assert.equal(empty.value.records.length, 0)
  assert.equal(empty.value.hasMore, false)
  assert.equal(empty.value.startSeq, null)
  assert.equal(empty.value.scanBoundary, null)
})

// ── 016 历史记录清洗：宿主原始模型输出日志不再下发 ──────────────────────────
// 口径见 specs/016-history-load-perf/contracts/history-record-trim.md。
// 为什么删：那份日志占样本会话报文约六成、占手机侧解码耗时约九成，而渲染不读它
// （证据：specs/016-history-load-perf/research.md §0）。

/// 一条**带**宿主模型输出日志的 assistant 记录（真实形状的缩小版）。
function recordWithStream(seq) {
  return {
    type: 'event',
    event: {
      type: 'assistant/message',
      seq,
      time: 1_700_000_000_000 + seq,
      surfaceOp: { kind: 'append' },
      data: {
        turn: 1,
        step: 1,
        message: { role: 'assistant', content: [{ type: 'text', text: `答案 ${seq}` }] },
        usage: { totalTokens: 12 },
        stream: [
          { type: 'chunk', time: 1, chunk: { type: 'block-start', index: 0, blockType: 'text' } },
          { type: 'chunk', time: 2, chunk: { type: 'text-chunks', index: 0, texts: ['答案'] } },
        ],
      },
    },
  }
}

test('trimRecordForWire 只删 data.stream，其余字段与壳层逐位不变', async () => {
  const { trimRecordForWire } = await import('../lib/history/records.js')
  const original = recordWithStream(7)
  const snapshot = structuredClone(original)
  const trimmed = trimRecordForWire(original)

  assert.deepEqual(original, snapshot, '不得就地改写连接器持有的记录')
  assert.notEqual(trimmed, original, '带日志的记录要产生新对象（浅拷贝）')
  assert.equal('stream' in trimmed.event.data, false)
  assert.deepEqual(Object.keys(trimmed.event.data).sort(), ['message', 'step', 'turn', 'usage'])
  assert.deepEqual(trimmed.event.data.message, snapshot.event.data.message)
  assert.deepEqual(trimmed.event.data.usage, snapshot.event.data.usage)
  assert.equal(trimmed.event.type, original.event.type)
  assert.equal(trimmed.event.seq, original.event.seq)
  assert.equal(trimmed.event.time, original.event.time)
  assert.deepEqual(trimmed.event.surfaceOp, original.event.surfaceOp)
})

test('trimRecordForWire 对没有日志的记录返回原对象（不复制、不动）', async () => {
  const { trimRecordForWire } = await import('../lib/history/records.js')
  const plain = { type: 'event', event: { type: 'user/message', seq: 3, data: { content: [{ type: 'text', text: '问' }] } } }
  assert.equal(trimRecordForWire(plain), plain)
  const noData = { type: 'event', event: { type: 'step/start', seq: 4 } }
  assert.equal(trimRecordForWire(noData), noData)
  const nullData = { type: 'event', event: { type: 'step/end', seq: 5, data: null } }
  assert.equal(trimRecordForWire(nullData), nullData)
})

test('sessionWindow 的回包不含 data.stream，且分页元数据与页内 seq 不变', async () => {
  const log = Array.from({ length: 200 }, (_, seq) => recordWithStream(seq).event)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 120, limit: 20 })
  assert.equal(page.ok, true)
  assert.equal(page.value.endSeq, 119)
  assert.equal(page.value.records.length, 20)
  assert.equal(page.value.startSeq, 100)
  for (const record of page.value.records) {
    assert.equal('stream' in record.event.data, false, `seq ${record.event.seq} 仍带着宿主日志`)
    assert.equal(typeof record.event.seq, 'number')
    assert.ok(record.event.data.message, '剔除不得动到 message 正文')
  }
  assert.deepEqual(
    page.value.records.map((record) => record.event.seq),
    Array.from({ length: 20 }, (_, index) => 100 + index),
    '页内顺序与 seq 逐位不变',
  )
  // 宿主侧的原始事件**没有被就地改写**（下一次读同一段仍应看到完整事件）。
  assert.ok(log[119].data.stream, 'fakeQuery 持有的日志被改写了')
})

test('roles 过滤页与 scanBoundary 语义不受清洗影响', async () => {
  // 每 3 条掺一条人类提问（`assistant/*` 记录永远不是 me），这样过滤页是真有命中的。
  const log = Array.from({ length: 200 }, (_, seq) => {
    const record = recordWithStream(seq)
    if (seq % 3 === 0) {
      record.event.type = 'user/message'
      record.event.data = { content: [{ type: 'text', text: `问 ${seq}` }], source: { kind: 'user' } }
    }
    return record.event
  })
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const page = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 120, limit: 10, roles: ['me'] })
  assert.equal(page.ok, true)
  assert.ok(page.value.records.length > 0, '每 3 条一条 user/message，按 me 过滤应有命中')
  for (const record of page.value.records) {
    assert.equal(record.event.type, 'user/message')
    assert.equal('stream' in record.event.data, false)
  }
  // 本次扫到 seq 69 就凑满了 limit（更早的还没看过）→ 有更早的；页内被裁掉的是**新**
  // 那一端之后的多余命中，边界因此与最老返回记录同值（window.js 的既有口径）。
  assert.equal(page.value.scanBoundary, page.value.records[0].event.seq)
  assert.equal(page.value.hasMore, true)
  assert.equal(page.value.records.length, 10, 'limit 生效')
})

test('会话内搜索（_link/sessionFind）的回包字段不受清洗影响', async () => {
  const log = Array.from({ length: 200 }, (_, seq) => recordWithStream(seq).event)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(log))
  const found = await service.handle(FIND_METHOD, { address: ADDRESS, query: '答案', limit: 5 })
  assert.equal(found.ok, true)
  assert.ok(found.value.hits.length > 0, '应能在正文里搜到（snippet 来自文本，不来自那份日志）')
  for (const hit of found.value.hits) {
    assert.equal(typeof hit.seq, 'number')
    assert.equal(typeof hit.role, 'string')
    assert.equal(typeof hit.snippet, 'string')
    assert.equal('event' in hit, false, '命中项不带记录本身')
  }
})

test('旧分页通道 session/page 的回包同样不含 data.stream（router 层）', async () => {
  const { DeviceRouter } = await import('../lib/router.js')
  const sent = []
  const hostPage = {
    records: [recordWithStream(11), recordWithStream(12)],
    hasMore: true,
  }
  const router = new DeviceRouter({
    dsh: {
      ensureMux: async () => 1, openStream() {}, cancelStream() {},
      rpc: async () => ({ ok: true, value: hostPage }),
      on() {}, off() {},
    },
    send: (deviceId, frame) => sent.push(frame),
    logger: {},
  })
  await router.attachDevice('dev_1')
  await router.handleRequest('dev_1', {
    t: 'req', id: 'r1', method: 'session/page', args: { address: ADDRESS, beforeSeq: 13 },
  })
  const reply = sent.find((frame) => frame.t === 'res')
  assert.ok(reply, `没有收到 res 帧：${JSON.stringify(sent.map((frame) => frame.t))}`)
  assert.equal(reply.ok, true)
  const values = reply.value.records
  assert.equal(values.length, 2)
  assert.deepEqual(values.map((record) => record.event.seq), [11, 12], '顺序与 seq 不变')
  for (const record of values) {
    assert.equal('stream' in record.event.data, false, `seq ${record.event.seq} 仍带着宿主日志`)
    assert.ok(record.event.data.message, '正文必须还在')
  }
  assert.equal(reply.value.hasMore, true)
  assert.equal(hostPage.records[0].event.data.stream !== undefined, true, '宿主的原始回包不得被就地改写')
})

test('旧分页清洗认两种回包形态（信封与裸页），其余方法一律不碰', async () => {
  const { trimHistoryPageForWire } = await import('../lib/router.js')
  const pageShape = { records: [recordWithStream(1)], hasMore: true }

  const bare = trimHistoryPageForWire('session/page', pageShape)
  assert.equal('stream' in bare.records[0].event.data, false)
  assert.equal(bare.hasMore, true)
  assert.equal('stream' in pageShape.records[0].event.data, true, '入参不得被就地改写')

  const enveloped = trimHistoryPageForWire('session/page', { ok: true, value: pageShape })
  assert.equal(enveloped.ok, true)
  assert.equal('stream' in enveloped.value.records[0].event.data, false)
  assert.equal(enveloped.value.hasMore, true)
  assert.equal('stream' in pageShape.records[0].event.data, true, '入参不得被就地改写')

  const other = { records: [recordWithStream(1)], hasMore: true }
  assert.equal(trimHistoryPageForWire('session/list', other), other, '别的方法原样返回')
  const shapeless = { ok: true, value: 'nope' }
  assert.equal(trimHistoryPageForWire('session/page', shapeless), shapeless)
})

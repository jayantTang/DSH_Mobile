/**
 * 概要 v2 的**窗口层**测试（能力 `history-fold-summary-v2`，`fold: "summary"`）。
 *
 * 需求见 `maintainers/设计/20261025-过程折叠-对齐桌面.md` §3.4 / §4.4 / M6 / §十一：
 * - 首屏只拿讲话 + 概要 + 正式回答；
 * - 每个过程段一条 `+link/fold` v2；
 * - 按整轮切页（页首/页尾都是轮次边界，不出现半轮）；
 * - 老 `fold: true` 的回包逐字节不变；
 * - 概要体积 ≤ 全量的 5%。
 */

import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { inflateRawSync } from 'node:zlib'

import { createHistoryService, WINDOW_METHOD } from '../lib/history.js'
import { FOLD_RECORD_TYPE } from '../lib/history/fold.js'

const ADDRESS = { kind: 'session', sessionId: 'session-fold-summary' }
const BIG = 100 * 1024 * 1024
const SMALL_BYTES = 512 * 1024

const REASONING = '思考正文：先看清目录结构再动手。'
const INTERMEDIATE = '中间讲话：先看目录结构。'
const ANSWER = '正式回答：目录里有两个文件。'
const RESULT_PREFIX = '命令输出：'

/**
 * 一段会话夹具：每轮 = turn/start、用户提问、（可选）中间讲话、思考、工具调用、
 * 工具结果、正式回答、turn/end。`intermediate` 打开时每轮多一段过程（两段 = 两条
 * `+link/fold`）。`resultBytes` / `reasoningBytes` 用来放大"全量 vs 概要"的差距。
 */
function buildSession({
  turns = 3, resultBytes = 0, reasoningBytes = 0, intermediate = false, stepsPerTurn = 1,
} = {}) {
  const log = []
  let seq = 0
  const push = (type, data) => {
    log.push({ seq, type, time: 1_700_000_000_000 + seq * 10, data })
    seq += 1
  }
  for (let turn = 1; turn <= turns; turn += 1) {
    push('turn/start', { turn })
    push('user/message', {
      content: [{ type: 'text', text: `第 ${turn} 问：看下目录` }],
      source: { kind: 'user', rpcId: `r${turn}` },
    })
    push('step/start', { turn, step: 1 })
    push('assistant/message', {
      turn, step: 1,
      message: { role: 'assistant', content: [{ type: 'reasoning', text: REASONING + 'x'.repeat(reasoningBytes) }] },
    })
    for (let step = 1; step <= stepsPerTurn; step += 1) {
      const name = step % 2 === 0 ? 'grep' : 'bash'
      push('tool/call', {
        turn, step: 1, callId: `c${turn}_${step}`, name,
        arguments: `{"command":"ls -la /tmp/dir${turn}/step${step}"}`,
      })
      push('tool/result', {
        turn, step: 1,
        message: {
          role: 'tool', toolCallId: `c${turn}_${step}`,
          content: [{ type: 'text', text: `${RESULT_PREFIX}${turn}/${step}\n${'r'.repeat(resultBytes)}` }],
        },
      })
    }
    push('step/end', { turn, step: 1 })
    if (intermediate) {
      push('assistant/message', {
        turn, step: 2,
        message: { role: 'assistant', content: [{ type: 'text', text: `${INTERMEDIATE}#${turn}` }] },
      })
      push('step/start', { turn, step: 2 })
      push('tool/call', { turn, step: 2, callId: `c${turn}b`, name: 'grep', arguments: `{"pattern":"TODO(${turn})"}` })
      push('tool/result', {
        turn, step: 2,
        message: { role: 'tool', toolCallId: `c${turn}b`, content: [{ type: 'text', text: 'no matches' }] },
      })
      push('step/end', { turn, step: 2 })
    }
    push('assistant/message', {
      turn, step: 3,
      message: { role: 'assistant', content: [{ type: 'text', text: `${ANSWER}#${turn}` }] },
    })
    push('turn/end', { turn, reason: { kind: 'completed' } })
  }
  return log
}

/// 假宿主：`readSession` 打开时走快照路径（生产主路径），关掉就走分块扫描回退路径。
function fakeQuery(log, { withReadSession = true } = {}) {
  const calls = { readEvent: 0, listEvents: 0, readSession: 0 }
  const query = {
    calls,
    async readEvent({ sessionId, seq, before }) {
      calls.readEvent += 1
      if (!Number.isInteger(before) || before < 0 || before > 50) {
        throw new Error('before must be an integer between 0 and 50')
      }
      if (!Number.isInteger(seq) || seq < 0 || seq >= log.length) {
        throw new Error(`session "${sessionId}" has no event at seq ${seq}`)
      }
      const start = Math.max(0, seq - before)
      return { sessionId, events: log.slice(start, seq + 1), startSeq: start, endSeq: seq }
    },
    async listEvents() {
      calls.listEvents += 1
      return log.map(({ seq, type, time }) => ({ seq, type, time }))
    },
    async filterEvents() { return [] },
  }
  if (withReadSession) {
    query.readSession = async () => {
      calls.readSession += 1
      return { events: log }
    }
  }
  return query
}

function serviceFor(log, options) {
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  const query = fakeQuery(log, options)
  service.bindQuery(query)
  return { service, query }
}

const typesOf = (value) => value.records.map((record) => record.event.type)
const foldsOf = (value) => value.records
  .filter((record) => record.event.type === FOLD_RECORD_TYPE)
  .map((record) => record.event.data)

test('fold:"summary" 只回讲话 + 概要 + 正式回答：没有 tool 事件，也没有 folds 副本', async () => {
  const log = buildSession({ turns: 3 })
  const { service } = serviceFor(log)
  const result = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 60, maxBytes: SMALL_BYTES, fold: 'summary',
  })
  assert.equal(result.ok, true)
  const types = typesOf(result.value)
  assert.deepEqual(types, [
    'turn/start', 'user/message', FOLD_RECORD_TYPE, 'assistant/message', 'turn/end',
    'turn/start', 'user/message', FOLD_RECORD_TYPE, 'assistant/message', 'turn/end',
    'turn/start', 'user/message', FOLD_RECORD_TYPE, 'assistant/message', 'turn/end',
  ])
  assert.deepEqual(types.filter((type) => type.startsWith('tool/')), [])
  assert.equal(result.value.folds, undefined, '概要已经随记录下发，不再重复一份 folds')
  const folds = foldsOf(result.value)
  assert.equal(folds.length, 3)
  for (const fold of folds) {
    assert.equal(fold.v, 2)
    assert.equal(typeof fold.turn, 'number')
    assert.equal(fold.durationMs, 80, '夹具里一轮 9 条事件，相邻 10ms → 80ms')
    assert.equal(fold.endReason, 'completed')
    assert.deepEqual(fold.activities, { commands: 1 })
    assert.equal(fold.groups.length, 1)
    assert.equal(fold.groups[0].toolCount, 1)
    assert.equal(fold.groups[0].steps.length, 2)
  }
})

test('中间讲话保留、reasoning 正文不传、tool 正文不传（每个过程段一条摘要）', async () => {
  const log = buildSession({ turns: 2, intermediate: true })
  const { service } = serviceFor(log)
  const result = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 60, maxBytes: SMALL_BYTES, fold: 'summary',
  })
  assert.equal(result.ok, true)
  assert.deepEqual(typesOf(result.value), [
    'turn/start', 'user/message', FOLD_RECORD_TYPE, 'assistant/message', FOLD_RECORD_TYPE,
    'assistant/message', 'turn/end',
    'turn/start', 'user/message', FOLD_RECORD_TYPE, 'assistant/message', FOLD_RECORD_TYPE,
    'assistant/message', 'turn/end',
  ])
  const wire = JSON.stringify(result.value)
  assert.equal(wire.includes(REASONING), false, 'reasoning 正文不许进回包')
  assert.equal(wire.includes(RESULT_PREFIX), false, '工具结果正文不许进回包')
  assert.equal(wire.includes('"arguments"'), false, '完整 args 不许进回包')
  // 中间讲话按 seq 留在两段摘要之间，正式回答也在
  const speech = result.value.records
    .filter((record) => record.event.type === 'assistant/message')
    .map((record) => record.event.data.message.content.map((block) => block.text).join(''))
  assert.deepEqual(speech, [
    `${INTERMEDIATE}#1`, `${ANSWER}#1`, `${INTERMEDIATE}#2`, `${ANSWER}#2`,
  ])
  assert.deepEqual(foldsOf(result.value).map((fold) => fold.turn), [1, 1, 2, 2])
})

test('按整轮切页：页首页尾都是轮次边界，翻完正好覆盖每一轮且不重叠', async () => {
  const turns = 6
  const log = buildSession({ turns })
  const { service } = serviceFor(log)
  const pages = []
  let before = log.length
  for (let guard = 0; guard < 50; guard += 1) {
    // 这个模式里 limit 是**轮数**：一页一轮，翻到底要 6 页。
    const result = await service.handle(WINDOW_METHOD, {
      address: ADDRESS, before, limit: 1, maxBytes: SMALL_BYTES, fold: 'summary',
    })
    assert.equal(result.ok, true)
    const value = result.value
    assert.ok(value.records.length > 0, '空页会让翻页永远推进不下去')
    assert.equal(typesOf(value)[0], 'turn/start', `页首要落在轮次边界，page=${pages.length}`)
    assert.equal(typesOf(value).at(-1), 'turn/end', `页尾要落在轮次边界，page=${pages.length}`)
    assert.equal(value.startSeq, value.records[0].event.seq)
    assert.equal(value.endSeq, value.records.at(-1).event.seq)
    pages.push(value)
    if (value.hasMore !== true) break
    assert.ok(value.startSeq < before, '游标必须前进，否则永远翻不完')
    before = value.startSeq
  }
  assert.equal(pages.length, turns, 'limit=1（轮）时一页一轮')
  for (let index = 1; index < pages.length; index += 1) {
    assert.equal(pages[index].endSeq, pages[index - 1].startSeq - 1,
      '两页之间不许有空隙、也不许重叠')
  }
  const seen = pages
    .flatMap((value) => value.records
      .filter((record) => record.event.type === 'turn/start')
      .map((record) => record.event.data.turn))
    .sort((a, b) => a - b)
  assert.deepEqual(seen, [1, 2, 3, 4, 5, 6], '每一轮恰好出现一次')
  assert.equal(pages.at(-1).hasMore, false)
  assert.equal(pages.at(-1).startSeq, 0)
})

test('页首那次请求（before 越过最新）也按轮对齐：endSeq 落在 turn/end 上', async () => {
  const log = buildSession({ turns: 2 })
  const { service } = serviceFor(log)
  const lastTurnEnd = log.filter((event) => event.type === 'turn/end').at(-1).seq
  const result = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: 9_007_199_254_740_991, limit: 60, maxBytes: SMALL_BYTES, fold: 'summary',
  })
  assert.equal(result.ok, true)
  assert.equal(result.value.endSeq, lastTurnEnd)
  assert.equal(result.value.clamped, true, '越过最新如实标 clamped')
})

test('最新一轮还在跑：整轮给到最新事件，步骤标 running，时长与结束原因是 null', async () => {
  const log = buildSession({ turns: 2 })
  const runningStart = log.length
  log.push({ seq: runningStart, type: 'turn/start', time: 1_700_000_001_000, data: { turn: 3 } })
  log.push({
    seq: runningStart + 1, type: 'user/message', time: 1_700_000_001_010,
    data: { content: [{ type: 'text', text: '第三问' }], source: { kind: 'user', rpcId: 'r3' } },
  })
  log.push({
    seq: runningStart + 2, type: 'tool/call', time: 1_700_000_001_020,
    data: { turn: 3, callId: 'c3', name: 'bash', arguments: '{"command":"npm test"}' },
  })
  const { service } = serviceFor(log)
  const result = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 60, maxBytes: SMALL_BYTES, fold: 'summary',
  })
  assert.equal(result.ok, true)
  assert.deepEqual(typesOf(result.value).slice(-3), ['turn/start', 'user/message', FOLD_RECORD_TYPE])
  assert.equal(result.value.endSeq, runningStart + 2, '运行中的轮次以最新事件收尾')
  const running = foldsOf(result.value).at(-1)
  assert.equal(running.turn, 3)
  assert.equal(running.durationMs, null)
  assert.equal(running.endReason, null)
  assert.deepEqual(running.groups[0].steps, [{
    seq: runningStart + 2, kind: 'tools', name: 'bash',
    preview: '{"command":"npm test"}', status: 'running',
  }])
  assert.equal(result.value.hasMore, false, '三整轮都被这一页装下了，不假装还有更早的')
})

test('日志被裁剪（页首落在一轮中间）：照给这一轮，且 hasMore 不会假装还有更早的', async () => {
  // 会话日志最早的一条不是 turn/start：真实场景是日志被裁剪过。这一轮"开始得早"，
  // 不是我们切出来的半轮，所以照给；但不能因此永远声称更早还有内容。
  const log = [
    { seq: 0, type: 'tool/call', time: 1_700_000_000_000, data: { callId: 'c1', name: 'bash', arguments: '{}' } },
    { seq: 1, type: 'tool/result', time: 1_700_000_000_010, data: { message: { toolCallId: 'c1', content: [{ type: 'text', text: '输出' }] } } },
    { seq: 2, type: 'assistant/message', time: 1_700_000_000_020, data: { message: { content: [{ type: 'text', text: '尾巴' }] } } },
    { seq: 3, type: 'turn/end', time: 1_700_000_000_030, data: { turn: 7, reason: { kind: 'completed' } } },
  ]
  const { service } = serviceFor(log, { withReadSession: false })
  const result = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 60, maxBytes: SMALL_BYTES, fold: 'summary',
  })
  assert.equal(result.ok, true)
  assert.deepEqual(typesOf(result.value), [FOLD_RECORD_TYPE, 'assistant/message', 'turn/end'])
  assert.equal(result.value.startSeq, 0)
  assert.equal(result.value.endSeq, 3)
  assert.equal(result.value.hasMore, false, '读到底了就不许再声称更早还有')
  assert.equal(foldsOf(result.value)[0].turn, 7, '轮次号取最近一条带 turn 的事件，不编造')
})

test('图片回答（agent 代发 + 图文）一路保留到概要页：元数据在、内联字节不在', async () => {
  const image = {
    type: 'image',
    attachment: {
      attachmentId: 'sha256:dd33',
      mediaType: 'image/webp',
      bytes: 260_374,
      width: 2048,
      height: 2048,
      name: 'diagram.png',
      data: 'C'.repeat(100_000),
    },
  }
  const log = [
    { seq: 0, type: 'turn/start', time: 1_000, data: { turn: 1 } },
    {
      seq: 1, type: 'user/message', time: 1_010,
      data: { content: [{ type: 'text', text: '把图发我' }], source: { kind: 'user', rpcId: 'r1' } },
    },
    { seq: 2, type: 'tool/call', time: 1_020, data: { turn: 1, callId: 'c1', name: 'bash', arguments: '{"command":"ls"}' } },
    {
      seq: 3, type: 'tool/result', time: 1_030,
      data: { turn: 1, message: { toolCallId: 'c1', content: [{ type: 'text', text: '工具输出' }] } },
    },
    {
      seq: 4, type: 'agent/inbox/spliced', time: 1_040,
      data: {
        target: 'next-turn',
        inserted: [{
          role: 'user', id: 'm1', source: { kind: 'agent', rpcId: 'agent-1' }, content: [image],
        }],
      },
    },
    {
      seq: 5, type: 'assistant/message', time: 1_050,
      data: { turn: 1, message: { role: 'assistant', content: [{ type: 'text', text: '图在附件里' }, image] } },
    },
    { seq: 6, type: 'turn/end', time: 1_060, data: { turn: 1, reason: { kind: 'completed' } } },
  ]
  const { service } = serviceFor(log, { withReadSession: false })
  const result = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 10, maxBytes: SMALL_BYTES, fold: 'summary',
  })
  assert.equal(result.ok, true)
  assert.deepEqual(typesOf(result.value), [
    'turn/start', 'user/message', FOLD_RECORD_TYPE, 'agent/inbox/spliced', 'assistant/message', 'turn/end',
  ])
  const wire = JSON.stringify(result.value)
  assert.equal(wire.includes('C'.repeat(1000)), false, '图片字节不许进回包')
  assert.equal(wire.includes('工具输出'), false, '工具正文仍不许进回包')
  // 两条图片都带着元数据
  assert.equal(wire.split('sha256:dd33').length - 1, 2, 'splice 与 assistant 两条消息各带一份图片元数据')
  const spliced = result.value.records.find((record) => record.event.type === 'agent/inbox/spliced')
  assert.equal(spliced.event.data.inserted[0].content[0].attachment.bytes, 260_374)
  assert.equal(spliced.event.data.inserted[0].content[0].attachment.mediaType, 'image/webp')
})

test('快照路径（readSession）与分块回退路径给同一页', async () => {
  const log = buildSession({ turns: 15 })
  const args = {
    address: ADDRESS, before: log.length, limit: 200, maxBytes: BIG, fold: 'summary',
  }
  const snapshotted = await serviceFor(log, { withReadSession: true }).service.handle(WINDOW_METHOD, args)
  const chunked = await serviceFor(log, { withReadSession: false }).service.handle(WINDOW_METHOD, args)
  assert.equal(snapshotted.ok, true)
  assert.equal(chunked.ok, true)
  assert.deepEqual(chunked.value, snapshotted.value)
  assert.equal(foldsOf(snapshotted.value).length, 15)
})

test('快照比请求上界旧时不夹上界：改走实时读，最新一轮不许漏', async () => {
  const log = buildSession({ turns: 3 })
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  // 快照只到第 1 轮（模拟"刚发出去一条消息、快照还没跟上"）。
  service.bindQuery({
    async readSession() { return { events: log.slice(0, 5) } },
    async listEvents() { return log.map(({ seq, type, time }) => ({ seq, type, time })) },
    async readEvent({ sessionId, seq, before }) {
      const start = Math.max(0, seq - before)
      return { sessionId, events: log.slice(start, seq + 1), startSeq: start, endSeq: seq }
    },
    async filterEvents() { return [] },
  })
  const result = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 10, maxBytes: SMALL_BYTES, fold: 'summary',
  })
  assert.equal(result.ok, true)
  assert.equal(result.value.clamped, false, '快照旧不等于日志变短')
  assert.deepEqual(foldsOf(result.value).map((fold) => fold.turn), [1, 2, 3])
})

test('老 fold:true 的回包与改动前逐字节一致（黄金夹具）', async () => {
  // 夹具与 `test/helpers/fold-v1-golden.json` 同源：那份文件由**改动前**的代码生成，
  // 是 v1 回包的合同。v2 只加开关，不许改这 3062 字节里的任何一个字段。
  const log = JSON.parse(readFileSync(new URL('./helpers/fold-v1-log.json', import.meta.url), 'utf8'))
  const golden = JSON.parse(readFileSync(new URL('./helpers/fold-v1-golden.json', import.meta.url), 'utf8'))
  const { service } = serviceFor(log, { withReadSession: false })
  const result = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 200, maxBytes: BIG, fold: true,
  })
  assert.equal(result.ok, true)
  assert.equal(JSON.stringify(result.value), JSON.stringify(golden))
})

test('概要体积 ≤ 全量的 5%（同一段会话、同一轮次范围）', async () => {
  // 夹具对齐设计 §十一 的真实样本量级：一轮 6 步、每步结果 12 KB、思考 1.5 KB
  // （本机 10.9–44 MB 的会话平均一轮 100 KB 以上），否则"全量"本身太小，
  // 比值只会反映固定开销、反映不了取数模式。
  const log = buildSession({ turns: 10, stepsPerTurn: 6, resultBytes: 12_000, reasoningBytes: 1500 })
  const { service } = serviceFor(log)
  const full = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 1000, maxBytes: BIG,
  })
  const summary = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 1000, maxBytes: BIG, fold: 'summary',
  })
  assert.equal(full.ok, true)
  assert.equal(summary.ok, true)
  const fullBytes = Buffer.byteLength(JSON.stringify(full.value), 'utf8')
  const summaryBytes = Buffer.byteLength(JSON.stringify(summary.value), 'utf8')
  const ratio = summaryBytes / fullBytes
  console.log(`[概要 v2] 全量 ${fullBytes} B → 概要 ${summaryBytes} B（${(ratio * 100).toFixed(2)}%）`)
  assert.ok(ratio <= 0.05, `概要必须 ≤ 全量的 5%：实得 ${summaryBytes}/${fullBytes} = ${(ratio * 100).toFixed(2)}%`)
})

test('fold:"summary" 与 roles / coverage 的组合明确拒绝（不静默改成别的语义）', async () => {
  const log = buildSession({ turns: 2 })
  const { service } = serviceFor(log)
  for (const extra of [{ roles: ['me'] }, { coverage: true }]) {
    const result = await service.handle(WINDOW_METHOD, {
      address: ADDRESS, before: log.length, limit: 20, fold: 'summary', ...extra,
    })
    assert.equal(result.ok, false)
    assert.equal(result.error.code, 'gateway/bad-request')
  }
})

test('概要回包同样走压缩信封，解压后与明文一致', async () => {
  const log = buildSession({ turns: 3, resultBytes: 2000 })
  const { service } = serviceFor(log)
  const args = { address: ADDRESS, before: log.length, limit: 200, maxBytes: BIG, fold: 'summary' }
  const plain = await service.handle(WINDOW_METHOD, args)
  const packed = await service.handle(WINDOW_METHOD, { ...args, encoding: 'deflate-raw' })
  assert.equal(packed.value.encoding, 'deflate-raw')
  const raw = inflateRawSync(Buffer.from(packed.value.value, 'base64'))
  assert.deepEqual(JSON.parse(raw.toString('utf8')), plain.value)
  assert.equal(packed.value.rawBytes, Buffer.byteLength(JSON.stringify(plain.value), 'utf8'))
})

test('其他 fold 取值不改变老语义（只有 true 与 "summary" 有含义）', async () => {
  const log = buildSession({ turns: 1 })
  const { service } = serviceFor(log)
  const unknown = await service.handle(WINDOW_METHOD, {
    address: ADDRESS, before: log.length, limit: 60, fold: 'v2',
  })
  assert.equal(unknown.ok, true)
  assert.deepEqual(typesOf(unknown.value), [
    'turn/start', 'user/message', 'step/start', 'assistant/message', 'tool/call',
    'tool/result', 'step/end', 'assistant/message', 'turn/end',
  ])
  assert.equal(unknown.value.folds, undefined)
})

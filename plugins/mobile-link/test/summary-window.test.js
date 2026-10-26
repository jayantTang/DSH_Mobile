/**
 * 概要 v2 的**整轮切页**层单测（`lib/history/summary-window.js`）。
 *
 * 页这一层的三条不变量（设计 §3.4 第 5 条 + "不能给半轮"）：
 * 1. 绝不下发半轮：往回读被上限/时间预算截住时，没读全的那一轮整轮丢掉；
 * 2. 至少给一轮：`limit` 比一轮还小也照给这一轮，否则游标永远前进不了；
 * 3. 读不全连一轮都没有时，回可重试错误，而不是一段残缺过程。
 */

import test from 'node:test'
import assert from 'node:assert/strict'

import { readSummaryPage } from '../lib/history/summary-window.js'
import { FOLD_RECORD_TYPE } from '../lib/history/fold.js'

/// 每轮 5 条事件：turn/start、user、tool/call、assistant text、turn/end。
function turnLog(turns) {
  const log = []
  for (let turn = 1; turn <= turns; turn += 1) {
    const base = (turn - 1) * 5
    log.push({ seq: base, type: 'turn/start', time: 1_000 + base, data: { turn } })
    log.push({
      seq: base + 1, type: 'user/message', time: 1_001 + base,
      data: { content: [{ type: 'text', text: `问 ${turn}` }], source: { kind: 'user' } },
    })
    log.push({
      seq: base + 2, type: 'tool/call', time: 1_002 + base,
      data: { turn, callId: `c${turn}`, name: 'bash', arguments: '{"command":"ls"}' },
    })
    log.push({
      seq: base + 3, type: 'assistant/message', time: 1_003 + base,
      data: { turn, message: { content: [{ type: 'text', text: `答 ${turn}` }] } },
    })
    log.push({ seq: base + 4, type: 'turn/end', time: 1_004 + base, data: { turn, reason: { kind: 'completed' } } })
  }
  return log
}

/// 假读取器：每次最多回 `batchSize` 条（模拟宿主一批 51 条的硬上限）。
function reader(log, { batchSize = 5 } = {}) {
  const calls = []
  return {
    calls,
    readOlder(cursor) {
      calls.push(cursor)
      const batch = log.filter((event) => event.seq <= cursor).slice(-batchSize)
      const floorSeq = batch.length > 0 ? batch[0].seq : 0
      return { events: batch, floorSeq, exhausted: floorSeq === 0, clamped: false }
    },
  }
}

const recordsOf = (page) => page.records.map((record) => `seq${record.event.seq}:${record.event.type}`)

test('limit 在这个模式里是"轮数"：limit=1 一页一轮，页首页尾都是轮次边界', async () => {
  const log = turnLog(3)
  const page = await readSummaryPage({
    readOlder: reader(log).readOlder, upper: log.length - 1, limit: 1, maxBytes: 1024 * 1024,
  })
  assert.equal(page.error, undefined)
  assert.equal(page.units, 1)
  assert.equal(page.startSeq, 10, '页首落在第三轮的 turn/start')
  assert.equal(page.endSeq, 14, '页尾落在第三轮的 turn/end')
  assert.deepEqual(recordsOf(page), [
    'seq10:turn/start', 'seq11:user/message', `seq12:${FOLD_RECORD_TYPE}`,
    'seq13:assistant/message', 'seq14:turn/end',
  ])
  assert.equal(page.truncatedBy, 'count')
  assert.equal(page.hasMore, true)
})

test('字节预算连一轮都装不下：照给这一轮（游标必须能前进）', async () => {
  const log = turnLog(3)
  const page = await readSummaryPage({
    readOlder: reader(log).readOlder, upper: log.length - 1, limit: 100, maxBytes: 10,
  })
  assert.equal(page.error, undefined)
  assert.equal(page.units, 1)
  assert.equal(page.startSeq, 10)
  assert.equal(page.endSeq, 14)
  assert.equal(page.hasMore, true)
})

test('字节预算按"投影后"算：超了就少给更旧的轮次，不切半轮', async () => {
  const log = turnLog(3)
  const tight = await readSummaryPage({
    readOlder: reader(log).readOlder, upper: log.length - 1, limit: 100, maxBytes: 400,
  })
  assert.equal(tight.error, undefined)
  assert.equal(tight.units, 1, '400 B 只装得下一轮')
  assert.equal(tight.truncatedBy, 'bytes')
  assert.equal(tight.hasMore, true)
  assert.equal(tight.startSeq, 10)
})

test('回读被批数上限截住：没读全的那一轮整轮丢掉，页尾仍是轮次边界', async () => {
  const log = turnLog(4)
  // 每批 3 条、只允许 2 批（6 条）：第一轮要 5 条读全了，第二轮只读到 1 条 → 丢掉。
  const page = await readSummaryPage({
    readOlder: reader(log, { batchSize: 3 }).readOlder,
    upper: log.length - 1, limit: 100, maxBytes: 1024 * 1024, maxBatches: 2,
  })
  assert.equal(page.error, undefined)
  assert.equal(page.units, 1)
  assert.deepEqual(recordsOf(page), [
    'seq15:turn/start', 'seq16:user/message', `seq17:${FOLD_RECORD_TYPE}`,
    'seq18:assistant/message', 'seq19:turn/end',
  ])
  assert.equal(page.startSeq, 15)
  assert.equal(page.endSeq, 19)
  assert.equal(page.hasMore, true)
})

test('连最新一轮都读不全：回可重试错误，绝不下发半轮', async () => {
  const log = turnLog(2)
  const page = await readSummaryPage({
    readOlder: reader(log, { batchSize: 3 }).readOlder,
    upper: log.length - 1, limit: 100, maxBytes: 1024 * 1024, maxBatches: 1,
  })
  assert.equal(page.records, undefined)
  assert.equal(page.error.code, 'link/too-large')
})

test('时间预算到点与批数上限同效：丢半轮，给整轮', async () => {
  const log = turnLog(3)
  let clock = 0
  const page = await readSummaryPage({
    readOlder: reader(log, { batchSize: 4 }).readOlder,
    upper: log.length - 1, limit: 100, maxBytes: 1024 * 1024,
    deadlineMs: 20, now: () => { clock += 5; return clock },
  })
  assert.equal(page.error, undefined)
  assert.ok(page.units >= 1, '至少给一整轮')
  assert.ok([0, 5, 10].includes(page.startSeq), `页首必须是 turn/start，实得 ${page.startSeq}`)
  assert.ok([4, 9, 14].includes(page.endSeq), `页尾必须是 turn/end，实得 ${page.endSeq}`)
  assert.equal(recordsOf(page).at(-1), `seq${page.endSeq}:turn/end`)
  assert.equal(page.hasMore, true, '到点截断时不许声称读到底了')
})

test('读到底：hasMore 为假、页首是日志第一条', async () => {
  const log = turnLog(2)
  const page = await readSummaryPage({
    readOlder: reader(log).readOlder, upper: log.length - 1, limit: 100, maxBytes: 1024 * 1024,
  })
  assert.equal(page.units, 2)
  assert.equal(page.startSeq, 0)
  assert.equal(page.endSeq, 9)
  assert.equal(page.hasMore, false)
  assert.equal(page.truncatedBy, null)
})

test('空会话（upper 为负或没有事件）回空页而不是报错', async () => {
  const empty = await readSummaryPage({
    readOlder: reader([]).readOlder, upper: -1, limit: 10, maxBytes: 1024,
  })
  assert.deepEqual(empty.records, [])
  assert.equal(empty.hasMore, false)

  const noEvents = await readSummaryPage({
    readOlder: reader([]).readOlder, upper: 5, limit: 10, maxBytes: 1024,
  })
  assert.deepEqual(noEvents.records, [])
  assert.equal(noEvents.hasMore, false)
})

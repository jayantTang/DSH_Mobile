/**
 * `lib/diagnostics.js` 的单测（tasks.md T007/T016/T032）。
 *
 * 这份文件要钉住三条"判读会不会出错"的性质：
 *   1. 未发生的阶段是 `null` + 进 `missing`，**不是 0**；
 *   2. 一次接入的额外记录条数是**常数级**（不随请求数增长）；
 *   3. 阈值边界（等于阈值不算慢、`slowRequestMs: 0` 一条都不记）。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import {
  DeviceTimeline, RESERVOIR_SIZE, SUMMARY_EVERY, TOP_SLOWEST,
} from '../lib/diagnostics.js'

/** 装一个记录了全部事件的 timeline（事件只进数组，不碰 journal）。 */
function makeTimeline({ slowRequestMs = 2000, startedAt = 1000 } = {}) {
  const events = []
  let clock = startedAt
  const timeline = new DeviceTimeline({
    deviceId: 'dev_1',
    slowRequestMs,
    now: () => clock,
    onEvent: (kind, detail) => events.push({ kind, detail }),
  })
  return {
    timeline,
    events,
    /** 把一个请求从 `startedAt` 推进 `ms` 毫秒后收尾。 */
    request(method, ms, bytes = 10) {
      const startedAt = clock
      clock += ms
      timeline.noteRequest({ method, startedAt, ms, bytes })
    },
    kinds: () => events.map((entry) => entry.kind),
    last: (kind) => [...events].reverse().find((entry) => entry.kind === kind)?.detail,
  }
}

test('一次请求都没有就断开：三个阶段全是 null 并进 missing，绝不记 0', () => {
  const { timeline } = makeTimeline()
  const phase = timeline.phaseDetail()
  assert.deepEqual(phase.phases, { helloMs: null, firstRequestMs: null, firstResponseMs: null })
  assert.deepEqual(phase.missing, ['hello', 'first-request', 'first-response'])
})

test('只到握手：hello 有毫秒，另两段仍是 null', () => {
  const { timeline } = makeTimeline()
  timeline.noteHello(1000)
  const phase = timeline.phaseDetail()
  assert.equal(phase.phases.helloMs, 0)
  assert.equal(phase.phases.firstRequestMs, null)
  assert.deepEqual(phase.missing, ['first-request', 'first-response'])
})

test('四段齐全时只写一条阶段事件（首个数据请求的响应之后），后续请求不再重复', () => {
  const { timeline, events, request, kinds } = makeTimeline()
  timeline.noteHello(1010)
  request('_link/hello', 5)
  assert.equal(kinds().filter((kind) => kind === 'device.phase').length, 0,
    '只有握手时还不写：那时的 first-request / first-response 都还没发生')
  request('session/list', 30, 2048)
  assert.equal(kinds().filter((kind) => kind === 'device.phase').length, 1)
  request('session/page', 20)
  assert.equal(kinds().filter((kind) => kind === 'device.phase').length, 1)
  const phase = events.find((entry) => entry.kind === 'device.phase').detail
  assert.deepEqual(phase.missing, [])
  assert.equal(phase.phases.helloMs, 10, '接入后 10ms 收到握手')
  assert.equal(phase.phases.firstRequestMs, 5, '首个数据请求在握手响应之后立刻发出（接入后 5ms）')
  assert.equal(phase.phases.firstResponseMs, 35, '首个数据响应＝该请求发出后再 30ms')
  assert.ok(phase.phases.firstResponseMs >= phase.phases.firstRequestMs, '三段必须单调')
})

test('阈值边界：等于阈值不算慢，超过才算；关闭时一条都不记', () => {
  const slow = makeTimeline({ slowRequestMs: 2000 })
  slow.request('session/list', 2000)
  assert.equal(slow.kinds().includes('request.slow'), false, '等于阈值不算慢')
  slow.request('session/list', 2001)
  assert.equal(slow.kinds().filter((kind) => kind === 'request.slow').length, 1)
  assert.deepEqual(slow.last('request.slow'),
    { deviceId: 'dev_1', method: 'session/list', elapsedMs: 2001, bytes: 10 },
    '耗时字段叫 elapsedMs：叫 ms 会把信封上的时刻冲掉')

  const off = makeTimeline({ slowRequestMs: 0 })
  for (let index = 0; index < 5; index += 1) off.request('session/list', 9000)
  assert.equal(off.kinds().includes('request.slow'), false, 'slowRequestMs: 0 表示关闭逐条慢请求')
})

test('水库与 top3 都不随请求数增长', () => {
  const { timeline } = makeTimeline()
  for (let index = 0; index < 1000; index += 1) {
    const startedAt = 1000 + index
    timeline.noteRequest({ method: 'session/page', startedAt, ms: index % 97, bytes: 100 })
  }
  assert.equal(timeline._samples.length, RESERVOIR_SIZE, '水库必须定长')
  assert.equal(timeline.summaryDetail().top3.length, TOP_SLOWEST)
  const top = timeline.summaryDetail().top3
  assert.deepEqual(top.map((entry) => entry.ms), [...top.map((entry) => entry.ms)].sort((a, b) => b - a))
})

test('汇总条数是常数级：每 200 个请求一条 + 断开时一条', () => {
  const { timeline, kinds } = makeTimeline()
  for (let index = 0; index < 450; index += 1) {
    timeline.noteRequest({ method: 'session/page', startedAt: 1000 + index, ms: 1, bytes: 1 })
  }
  assert.equal(kinds().filter((kind) => kind === 'device.summary').length, 2, '450 个请求 → 2 条（200/400）')
  timeline.finish()
  const summaries = kinds().filter((kind) => kind === 'device.summary').length
  assert.equal(summaries, 3, '断开时再补一条')
  const perHundred = summaries - 1
  assert.ok(perHundred <= 1 + 450 / SUMMARY_EVERY, '额外条数不得超过 1 + requests/200')
})

test('没有请求就不写汇总（断开时也不写）', () => {
  const { timeline, kinds } = makeTimeline()
  timeline.finish()
  assert.equal(kinds().includes('device.summary'), false)
  assert.deepEqual(kinds(), ['device.phase'], '阶段事件照写（让人看到"接进来了但什么都不发"）')
})

test('分位数在样本极少时仍给出可核对的数', () => {
  const { timeline } = makeTimeline()
  for (const ms of [100, 200, 300, 400]) {
    timeline.noteRequest({ method: 'session/page', startedAt: 1000, ms, bytes: 1 })
  }
  const summary = timeline.summaryDetail()
  assert.equal(summary.requests, 4)
  assert.equal(summary.p50Ms, 200, '最近秩：ceil(0.5×4)=2 → 第 2 小')
  assert.equal(summary.p95Ms, 400)
  assert.equal(summary.maxMs, 400)
})

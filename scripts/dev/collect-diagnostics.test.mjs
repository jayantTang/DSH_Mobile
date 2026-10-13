/**
 * `scripts/dev/collect-diagnostics.mjs` 的离线单测（tasks.md T013/T029/T040）。
 *
 * 全程用仓库内的 fixture 与临时目录，**不读真实 `~/.dsh`**（宪法 III），也不 ssh、不发网络请求：
 * 需要 IO 的那几条把 `DSH_HOME` 指到临时目录。要钉住的性质：
 *   * 参数与窗口解析（未知参数必须报错，而不是默默忽略）；
 *   * 中转日志行的解析（契约 §4 的八种行 + 未匹配的行必须被计数而不是瞎猜）；
 *   * 时钟偏移的三条路（`common-event` / `stats-rtt` / `none`）与优先级；
 *   * `offset: null` 时**不写** timeline（只按来源分节）。
 */

import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  bundleName, chooseOffset, computeAppOffset, computeOffsetFromCommonEvents, computeOffsetFromStats,
  dshHome, mergeTimeline, parseArgs, parseRelayJsonRecord, parseRelayLines, parseRelayMessage,
  parseSince, readConnectorJournal, sliceByWindow,
} from './collect-diagnostics.mjs'

const AT = Date.parse('2026-10-13T01:10:10.506Z')

test('parseArgs 默认值', () => {
  const options = parseArgs([])
  assert.equal(options.since, '30m')
  assert.equal(options.relay, true)
  assert.equal(options.json, false)
  assert.deepEqual(options.devices, [])
})

test('parseArgs 接受窗口、输出目录、设备与开关', () => {
  const options = parseArgs(['--since', '6h', '--out', '/tmp/x', '--device', 'dev_1',
    '--device', 'dev_2', '--no-relay', '--json'])
  assert.equal(options.since, '6h')
  assert.equal(options.out, '/tmp/x')
  assert.deepEqual(options.devices, ['dev_1', 'dev_2'])
  assert.equal(options.relay, false)
  assert.equal(options.json, true)
})

test('parseArgs 对未知参数报错（不许静默忽略）', () => {
  assert.throws(() => parseArgs(['--nope']), /未知参数/)
})

test('parseSince 认相对窗口与 ISO 时刻，其余一律报错', () => {
  assert.equal(parseSince('30m', AT).sinceMs, AT - 30 * 60_000)
  assert.equal(parseSince('6h', AT).sinceMs, AT - 6 * 3_600_000)
  assert.equal(parseSince('2d', AT).sinceMs, AT - 2 * 86_400_000)
  const iso = parseSince('2026-10-13T00:00:00Z', AT)
  assert.equal(iso.sinceMs, Date.parse('2026-10-13T00:00:00Z'))
  assert.equal(iso.untilMs, AT)
  assert.throws(() => parseSince('last tuesday', AT), /无法解析窗口/)
})

test('sliceByWindow 只留窗口内（含边界），时刻非数字的一律丢', () => {
  const events = [{ ms: 100 }, { ms: 200 }, { ms: 300 }, { at: 'x' }]
  assert.deepEqual(sliceByWindow(events, { sinceMs: 200, untilMs: 300 }).map((event) => event.ms), [200, 300])
})

test('八种中转日志行都能解析（契约 §4）', () => {
  const cases = [
    ['relay: device dev_1 (iPhone) attached to agent agt_1', 'relay.device-attach'],
    ['relay: device dev_1 detached (socket closed)', 'relay.device-detach'],
    ['relay: device dev_1 attached again while its previous socket is still open — replacing the registration; the old socket is now untracked and its close will not notify the connector', 'relay.device-replaced'],
    ['relay: device dev_1 closed a socket that had already been replaced; no detach notification sent for it', 'relay.device-superseded-close'],
    ['relay: device dev_1 socket error: No PONG received after 15.0 seconds', 'relay.pong-timeout'],
    ['relay: agent agt_1 connected (Jayant MacBook Pro), 1 device(s) re-adopted', 'relay.agent-connect'],
    ['relay: agent agt_1 disconnected', 'relay.agent-disconnect'],
    ['relay: agent agt_1 superseded by a new connection', 'relay.agent-superseded'],
  ]
  for (const [message, kind] of cases) {
    const event = parseRelayMessage(message, AT)
    assert.equal(event?.kind, kind, message)
    assert.equal(event.ms, AT)
  }
})

test('未匹配的行返回 null（调用方要计数，不许猜）', () => {
  assert.equal(parseRelayMessage('relay: something we never emitted', AT), null)
  assert.equal(parseRelayMessage('', AT), null)
})

test('journald JSON 记录用 __REALTIME_TIMESTAMP（微秒）而不是本地时间字符串', () => {
  const event = parseRelayJsonRecord({
    __REALTIME_TIMESTAMP: String(AT * 1000),
    MESSAGE: 'relay: device dev_9 (iPhone) attached to agent agt_9',
  })
  assert.equal(event.ms, AT, '猜服务器的时区会让整条时间线偏 8 小时')
  assert.equal(event.deviceId, 'dev_9')
  assert.equal(parseRelayJsonRecord({ MESSAGE: 'x' }), null, '没有时间戳的记录不猜')
})

test('parseRelayLines 计数读了多少行、跳过了多少行，并按设备/agent 过滤', () => {
  const lines = [
    JSON.stringify({ __REALTIME_TIMESTAMP: String(AT * 1000), MESSAGE: 'relay: device dev_1 (iPhone) attached to agent agt_1' }),
    JSON.stringify({ __REALTIME_TIMESTAMP: String((AT + 1000) * 1000), MESSAGE: 'relay: device dev_2 (iPhone) attached to agent agt_1' }),
    JSON.stringify({ __REALTIME_TIMESTAMP: String((AT + 2000) * 1000), MESSAGE: 'relay: nothing we parse' }),
    'not json at all',
    '',
  ].join('\n')
  const all = parseRelayLines(lines)
  assert.equal(all.readLines, 4, '空行不算')
  assert.equal(all.events.length, 2)
  assert.equal(all.unmatched, 2, '一条不含 event、一条不是 JSON')
  const onlyOne = parseRelayLines(lines, { deviceIds: ['dev_1'] })
  assert.deepEqual(onlyOne.events.map((event) => event.deviceId), ['dev_1'])
  const otherAgent = parseRelayLines(lines, { agentIds: ['agt_9'] })
  assert.equal(otherAgent.events.length, 0)
})

test('computeOffsetFromStats 取 RTT 最小的那次采样（并如实带出 rtt）', () => {
  const offset = computeOffsetFromStats([
    { now: 1_000_000, t0: 0, t1: 900 },      // RTT 900ms，噪声大
    { now: 1_000_100, t0: 0, t1: 100 },      // RTT 100ms，用这次
  ])
  assert.equal(offset.method, 'stats-rtt')
  assert.equal(offset.rttMs, 100)
  assert.equal(offset.offsetMs, 1_000_050, 'now - (t0 + rtt/2)')
  assert.equal(offset.samples, 2)
  assert.equal(computeOffsetFromStats([]), null)
  assert.equal(computeOffsetFromStats([{ now: 1 }]), null)
})

test('computeOffsetFromCommonEvents 用中位数，且在只有一条或散布过大时放弃', () => {
  const connector = [{ kind: 'device.attach', deviceId: 'dev_1', ms: 1000 },
    { kind: 'device.attach', deviceId: 'dev_2', ms: 2000 }]
  const relay = [{ kind: 'relay.device-attach', deviceId: 'dev_1', ms: 1200 },
    { kind: 'relay.device-attach', deviceId: 'dev_2', ms: 2210 }]
  const offset = computeOffsetFromCommonEvents(connector, relay)
  assert.equal(offset.method, 'common-event')
  assert.equal(offset.offsetMs, 205, '两条差 200 与 210 → 中位数 205')

  assert.equal(computeOffsetFromCommonEvents(connector, [relay[0]]), null, '只有一条匹配不算数')
  const wild = [{ kind: 'relay.device-attach', deviceId: 'dev_1', ms: 1200 },
    { kind: 'relay.device-attach', deviceId: 'dev_2', ms: 99_000 }]
  assert.equal(computeOffsetFromCommonEvents(connector, wild), null, '散布过大说明配错了事件')
})

test('chooseOffset：共同事件优先；都没有时是 none（不合并时间线）', () => {
  const common = { source: 'relay', offsetMs: 205, method: 'common-event', rttMs: null, samples: 2 }
  const stats = { source: 'relay', offsetMs: 300, method: 'stats-rtt', rttMs: 120, samples: 2 }
  const chosen = chooseOffset({ common, stats })
  assert.equal(chosen.method, 'common-event')
  assert.deepEqual(chosen.alternatives, [stats], '另一种口径要留下来供交叉核对')

  const none = chooseOffset({})
  assert.equal(none.method, 'none')
  assert.equal(none.offsetMs, null)
})

test('computeAppOffset 取最近一条推送的 skewMs（手机是第三个时钟）', () => {
  const offset = computeAppOffset([
    { kind: 'app.push', skewMs: 120, ms: 1 },
    { kind: 'device.attach', ms: 2 },
    { kind: 'app.push', skewMs: 90, ms: 3 },
  ])
  assert.equal(offset.method, 'push-skew')
  assert.equal(offset.offsetMs, 90, '手机时钟可能被改过，越新越可信')
  assert.equal(offset.samples, 2)
  assert.equal(computeAppOffset([{ kind: 'app.push' }]).method, 'none', '没有 skew 就不编一个')
})

test('mergeTimeline：把中转侧与手机侧都换算到本机时钟并排序；拿不到偏移的来源不硬塞', () => {
  const offsetRelay = { source: 'relay', offsetMs: 200, method: 'common-event', rttMs: null, samples: 2 }
  const offsetApp = { source: 'app', offsetMs: 100, method: 'push-skew', rttMs: null, samples: 1 }
  const merged = mergeTimeline({
    connector: [{ kind: 'device.attach', deviceId: 'dev_1', ms: 1000 }],
    relay: [{ kind: 'relay.device-attach', deviceId: 'dev_1', ms: 1200 }],
    app: [{ kind: 'app.dial', ms: 1100, phase: 'start' }],
    offsetRelay,
    offsetApp,
  })
  assert.deepEqual(merged.mergedSources, ['connector', 'app', 'relay'])
  assert.deepEqual(merged.rows.map((row) => row.kind), ['device.attach', 'app.dial', 'relay.device-attach'])
  assert.deepEqual(merged.rows.map((row) => row.source), ['connector', 'app', 'relay'])
  for (const row of merged.rows) assert.equal(row.localMs, 1000, '三条指的是同一件事，换算后必须落在同一毫秒')

  // 手机的偏移拿不到：只在时间线里排除 app 那部分，并如实说明——绝不用猜的偏移对齐。
  const partial = mergeTimeline({
    connector: [{ kind: 'device.attach', ms: 1000 }],
    relay: [{ kind: 'relay.device-attach', ms: 1200 }],
    app: [{ kind: 'app.dial', ms: 900, phase: 'start' }],
    offsetRelay,
    offsetApp: { source: 'app', offsetMs: null, method: 'none' },
  })
  assert.deepEqual(partial.mergedSources, ['connector', 'relay'])
  assert.equal(partial.rows.some((row) => row.source === 'app'), false)
})

test('readConnectorJournal 认 .1 那一代，并把坏行计入 droppedEarlier', () => {
  const home = mkdtempSync(join(tmpdir(), 'dsh-diag-test-'))
  const dir = join(home, 'mobile-link')
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'link-events.jsonl.1'), `${JSON.stringify({ at: 'a', ms: 1, kind: 'link.start' })}\n`)
  writeFileSync(join(dir, 'link-events.jsonl'),
    `${JSON.stringify({ at: 'b', ms: 2, kind: 'device.attach', deviceId: 'dev_1' })}\n{ broken\n`)
  const read = readConnectorJournal({ dshHome: home })
  assert.equal(read.counts.archived, 1)
  assert.equal(read.counts.current, 1)
  assert.equal(read.counts.droppedEarlier, 1, '坏行要被如实计数，不许当成事件')
  assert.deepEqual(read.events.map((event) => event.kind), ['link.start', 'device.attach'])
})

test('DSH_HOME 与环境默认值', () => {
  const previous = process.env.DSH_HOME
  process.env.DSH_HOME = '/tmp/isolated-dsh'
  try {
    assert.equal(dshHome(), '/tmp/isolated-dsh')
  } finally {
    if (previous === undefined) delete process.env.DSH_HOME
    else process.env.DSH_HOME = previous
  }
})

test('bundleName 形状稳定（便于按名字排序与找最近一次）', () => {
  assert.equal(bundleName(new Date('2026-10-13T01:10:10.506Z')), 'diagnostics-20261013-011010')
})

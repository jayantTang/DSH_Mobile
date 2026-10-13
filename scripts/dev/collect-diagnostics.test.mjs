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
  debugDeviceIds, dshHome, journalSince, mergeTimeline, parseArgs, parseRelayJsonRecord,
  parseRelayLines, parseRelayMessage, parseSince, readConnectorJournal, scopeRelayEvents,
  sliceByWindow, summarizeAttaches,
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

test('共同事件按"最近的同类事件"配对：远处那条 attach 不许污染偏移', () => {
  // 真实数据里踩到的坑：连接器只在**首次**接入写 `device.attach`，之后同一设备再接入写的是
  // `device.attach-again`。若拿"连接器的第一条"去配每一条中转 attach，差值会散布到十几分钟。
  const connector = [
    { kind: 'device.attach', deviceId: 'dev_1', ms: 1_000_000 },
    { kind: 'device.attach-again', deviceId: 'dev_1', ms: 1_600_000 },
    { kind: 'device.reattach', deviceId: 'dev_1', ms: 1_900_000 },
  ]
  const relay = [
    { kind: 'relay.device-attach', deviceId: 'dev_1', ms: 1_000_120 },
    { kind: 'relay.device-attach', deviceId: 'dev_1', ms: 1_600_090 },
    { kind: 'relay.device-attach', deviceId: 'dev_1', ms: 1_900_130 },
    // 距离任何连接器事件都超过 5 秒：不该参与计算
    { kind: 'relay.device-attach', deviceId: 'dev_1', ms: 1_500_000 },
  ]
  const offset = computeOffsetFromCommonEvents(connector, relay)
  assert.equal(offset.samples, 3, '只认 5 秒内的最近配对')
  assert.equal(offset.offsetMs, 120, '取中位数：(120, 90, 130) → 120')
})

test('journalSince 把窗口标签翻成 journalctl 认的写法', () => {
  assert.equal(journalSince('30m'), '-30m', 'journalctl 不认裸的 30m（实测 Failed to parse timestamp）')
  assert.equal(journalSince('6h'), '-6h')
  assert.equal(journalSince('2d'), '-2d')
  assert.equal(journalSince('2026-10-13T00:00:00Z'), '2026-10-13T00:00:00Z', 'ISO 原样传')
})

test('debugDeviceIds：名字以 DSH- 开头的设备整条不进包', () => {
  const ids = debugDeviceIds({
    events: [{ kind: 'device.attach', deviceId: 'dev_a', name: 'DSH-Test' },
      { kind: 'device.attach', deviceId: 'dev_b', name: 'iPhone' }],
    status: { devices: [{ deviceId: 'dev_c', name: 'DSH-Runner' }] },
  })
  assert.deepEqual([...ids].sort(), ['dev_a', 'dev_c'])
  // owner 显式点名时不排除（自验仿真器设备就靠这一条）。
  assert.deepEqual([...debugDeviceIds({
    events: [{ deviceId: 'dev_a', name: 'DSH-Test' }], explicit: ['dev_a'],
  })], [])
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

// ── US2：把一次接入的两侧阶段合成一张表 ──────────────────────────────────────

test('summarizeAttaches 按接入分组，缺的阶段进 missing 而不是 0', () => {
  const connector = [
    { kind: 'device.attach', deviceId: 'dev_1', ms: 10_000, name: 'iPhone' },
    { kind: 'device.phase', deviceId: 'dev_1', ms: 31_000,
      phases: { helloMs: 19_109, firstRequestMs: 246, firstResponseMs: 487 }, missing: [] },
  ]
  const app = [
    // App 的拨号早于连接器记到的接入（实测领先约 150ms）
    { kind: 'app.dial', deviceId: 'dev_1', ms: 9_850, phase: 'start' },
    { kind: 'app.dial', deviceId: 'dev_1', ms: 10_020, phase: 'transport-up' },
    { kind: 'app.first-request', deviceId: 'dev_1', ms: 10_100, method: 'session/list' },
    { kind: 'app.first-response', deviceId: 'dev_1', ms: 10_400, method: 'session/list', bytes: 700 },
    { kind: 'app.hello', deviceId: 'dev_1', ms: 29_400, elapsedMs: 19_325 },
    { kind: 'app.first-screen', deviceId: 'dev_1', ms: 29_403 },
  ]
  const relay = [{ kind: 'relay.device-attach', deviceId: 'dev_1', ms: 10_030 }]
  const rows = summarizeAttaches({ connector, app, relay })
  assert.equal(rows.length, 1)
  const row = rows[0]
  assert.equal(row.deviceId, 'dev_1')
  assert.equal(row.appStages.dialMs, 0, 'App 侧一律相对拨号起点')
  assert.equal(row.appStages.transportUpMs, 170)
  assert.equal(row.appStages.helloMs, 19_550)
  assert.equal(row.appStages.firstScreenMs, 19_553)
  assert.deepEqual(row.appMissing, [], '六个阶段都到了就不该有 missing')
  assert.equal(row.connectorPhases.helloMs, 19_109)
  assert.equal(row.relayAttachMs, 10_030)
  // 两侧对「接入→握手」的读数接近（App 从拨号起算，连接器从接入起算，差一个 150ms 的领先）
  assert.ok(Math.abs(row.helloSkewMs) < 300, `两侧读数该接近：${row.helloSkewMs}`)
})

test('summarizeAttaches：没握手的那次接入把 hello 记成 missing', () => {
  const connector = [
    { kind: 'device.attach', deviceId: 'dev_2', ms: 1_000 },
    { kind: 'device.phase', deviceId: 'dev_2', ms: 2_000,
      phases: { helloMs: null, firstRequestMs: 50, firstResponseMs: 200 }, missing: ['hello'] },
  ]
  const app = [
    { kind: 'app.dial', deviceId: 'dev_2', ms: 900, phase: 'start' },
    { kind: 'app.dial', deviceId: 'dev_2', ms: 1_050, phase: 'transport-up' },
  ]
  const [row] = summarizeAttaches({ connector, app })
  assert.equal(row.appStages.helloMs, null, '没发生就是 null')
  assert.notEqual(row.appStages.helloMs, 0, '0 与"没发生"是两回事')
  assert.ok(row.appMissing.includes('hello'))
  assert.ok(row.appMissing.includes('first-request'))
  assert.deepEqual(row.connectorMissing, ['hello'])
  assert.equal(row.helloSkewMs, null, '两侧缺一段就不算差值')
})

test('summarizeAttaches：两次接入分成两段，互不串味', () => {
  const connector = [
    { kind: 'device.attach', deviceId: 'dev_3', ms: 1_000 },
    { kind: 'device.attach', deviceId: 'dev_3', ms: 100_000 },
  ]
  const app = [
    { kind: 'app.dial', deviceId: 'dev_3', ms: 900, phase: 'start' },
    { kind: 'app.dial', deviceId: 'dev_3', ms: 99_900, phase: 'start' },
  ]
  const rows = summarizeAttaches({ connector, app })
  assert.equal(rows.length, 2)
  assert.equal(rows[0].appStages.dialMs, 0)
  assert.equal(rows[1].appStages.dialMs, 0, '第二段的拨号相对第二段自己的起点')
})

// ── US6：中转切片必须只含自己的设备 ────────────────────────────────────────

test('parseRelayMessage 取行尾的 (agent …)，且不把归属混进错误文本', () => {
  const detach = parseRelayMessage('relay: device dev_x detached (socket closed) (agent agt_y)', 1)
  assert.equal(detach.agentId, 'agt_y')
  assert.equal(detach.reason, 'socket closed')

  const pong = parseRelayMessage('relay: device dev_x socket error: No PONG received after 15.0 seconds (agent agt_y)', 1)
  assert.equal(pong.agentId, 'agt_y')
  assert.equal(pong.error, 'No PONG received after 15.0 seconds', '归属不能混进错误文本')

  const legacy = parseRelayMessage('relay: device dev_x detached (socket closed)', 1)
  assert.equal(legacy.agentId, undefined, '没有后缀的老行按"归属未知"处理')
})

test('scopeRelayEvents：别的账号的行一律丢，认得的老设备行留下', () => {
  const events = [
    { kind: 'relay.device-attach', deviceId: 'dev_mine', agentId: 'agt_me' },
    { kind: 'relay.agent-connect', agentId: 'agt_me' },
    { kind: 'relay.device-detach', deviceId: 'dev_other', agentId: 'agt_other' },
    { kind: 'relay.device-detach', deviceId: 'dev_mine' },
    { kind: 'relay.device-replaced', deviceId: 'dev_stranger' },
  ]
  const scoped = scopeRelayEvents(events, { agentId: 'agt_me', deviceIds: ['dev_mine', 'dev_mine_old'] })
  assert.deepEqual(scoped.kept.map((e) => e.kind),
    ['relay.device-attach', 'relay.agent-connect', 'relay.device-detach'], '只留自己的')
  assert.equal(scoped.excludedOtherAgent, 1, '带别人 agentId 的算"别的账号"')
  assert.equal(scoped.excludedUnknownDevice, 1, '不认识又没归属的单独计数')
})

test('scopeRelayEvents：没有 agentId 可比时（老部署）仍按设备清单收窄', () => {
  const events = [
    { kind: 'relay.device-detach', deviceId: 'dev_mine' },
    { kind: 'relay.device-detach', deviceId: 'dev_other' },
  ]
  const scoped = scopeRelayEvents(events, { deviceIds: ['dev_mine'] })
  assert.deepEqual(scoped.kept.map((e) => e.deviceId), ['dev_mine'])
  assert.equal(scoped.excludedUnknownDevice, 1)
})

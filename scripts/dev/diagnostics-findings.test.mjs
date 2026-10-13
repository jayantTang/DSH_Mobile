/**
 * 自动判读的单测（spec 020 的 US9 / T069）。
 *
 * 重点不是"规则跑得动"，而是：**四类现场各能产出对应 finding；健康现场 0 告警**
 * （SC-012），以及每条 finding 的 evidence 都能追到包内文件。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import {
  FINDING_THRESHOLDS, buildFindings, connectorRestartFindings, collectorScopeFindings,
  duplicateSocketFindings, linkAbnormalFindings, noDialFindings, phoneSlowFindings,
  slowSideSummary, stageMissingFindings,
} from './diagnostics-findings.mjs'

/** 造一个"接入段"：默认是健康的一次（各段齐全、两侧都快）。 */
function attach(overrides = {}) {
  return {
    deviceId: 'dev_1',
    attachAt: '2026-10-13T02:40:21.941Z',
    attachMs: 1000,
    appStages: {
      dialMs: 0, transportUpMs: 153, firstRequestMs: 412,
      firstResponseMs: 10065, helloMs: 10150, firstScreenMs: 10152,
    },
    appMissing: [],
    appBytes: 731072,
    connectorPhases: { helloMs: 9928, firstRequestMs: 309, firstResponseMs: 555 },
    connectorMissing: [],
    connectorHandlingMs: 246,
    phoneHandlingMs: 9455,
    phoneHandlingNegative: false,
    relayEvents: { attach: 1, replaced: 0, detach: 0, supersededClose: 0, pongTimeout: 0 },
    afterConnectorRestartMs: null,
    helloSkewMs: 48,
    ...overrides,
  }
}

const appEvent = (ms, kind = 'app.dial') => ({ kind, deviceId: 'dev_1', ms })

test('phone-slow：手机侧慢一个量级就报，且带上两侧耗时与响应大小', () => {
  const findings = phoneSlowFindings([attach()], FINDING_THRESHOLDS)
  assert.equal(findings.length, 1)
  assert.equal(findings[0].id, 'phone-slow')
  assert.equal(findings[0].level, 'warn')
  assert.match(findings[0].summary, /9455 ms/)
  assert.match(findings[0].summary, /246 ms/)
  assert.match(findings[0].summary, /714 KiB/, '要说清是多大一份响应')
})

test('phone-slow：两侧都在同一量级时不报（不能把两边都慢只算到手机头上）', () => {
  const findings = phoneSlowFindings([attach({ phoneHandlingMs: 900, connectorHandlingMs: 246 })],
    FINDING_THRESHOLDS)
  assert.deepEqual(findings, [])
})

test('stage-missing：接入之后这台设备在记录，缺阶段才是告警', () => {
  const broken = attach({ appMissing: ['hello'] })
  assert.equal(stageMissingFindings([broken], [appEvent(2000)]).length, 1)
  // 接入之后完全没有手机侧记录（老构建/重装前后）：不该报成告警，那是 no-dial 的事
  assert.deepEqual(stageMissingFindings([broken], []), [])
  assert.deepEqual(stageMissingFindings([broken], [{ kind: 'app.dial', deviceId: 'dev_1', ms: 500 }]), [],
    '记录发生在接入之前不算"当时在记"')
})

test('duplicate-socket：连接器侧 attach-again 与中转侧 replaced 都算，且给出次数', () => {
  const connector = [{ kind: 'device.attach-again', deviceId: 'dev_1', ms: 1100 }]
  const relay = [{ kind: 'relay.device-replaced', deviceId: 'dev_1', ms: 1105 }]
  const findings = duplicateSocketFindings(connector, relay)
  assert.equal(findings.length, 1)
  assert.match(findings[0].summary, /attach-again 1 次/)
  assert.match(findings[0].summary, /replaced 1 次/)
  assert.equal(findings[0].evidence.length, 2, '两侧证据都要留')
})

test('link-closed-abnormally：1006 报，正常关闭不报', () => {
  const abnormal = linkAbnormalFindings([
    { kind: 'link.close', reason: 'relay closed the socket (1006 )', at: 'x' },
  ])
  assert.equal(abnormal.length, 1)
  assert.match(abnormal[0].summary, /没有系统错误文本/, '要顺带说明这次没留下系统错误')

  const withText = linkAbnormalFindings([
    { kind: 'link.close', reason: 'relay closed the socket (1006 )', socketError: 'ECONNRESET', at: 'x' },
  ])
  assert.match(withText[0].summary, /ECONNRESET/, '有系统错误就要带出来')

  assert.deepEqual(linkAbnormalFindings([{ kind: 'link.close', reason: 'agent stopped', at: 'x' }]), [])
})

test('no-dial 与 connector-restart：都归提示级，解释"为什么这段缺"', () => {
  const noDial = noDialFindings([attach({ attachMs: 5000 })], [appEvent(1000)])
  assert.equal(noDial.length, 1)
  assert.equal(noDial[0].level, 'info', '没在记录不是故障')

  const restarted = connectorRestartFindings([attach({ afterConnectorRestartMs: 0 })])
  assert.equal(restarted[0].id, 'connector-restart')
  assert.equal(restarted[0].level, 'info')
  assert.deepEqual(connectorRestartFindings([attach()]), [], '不是重启后的接入就不出这条')
})

test('collector-scope：收窄生效就如实记账（含排除数）', () => {
  const findings = collectorScopeFindings({ relay: { kept: 9, excludedOtherAgent: 0, excludedUnknownDevice: 102, knownDevices: 2 } })
  assert.equal(findings[0].id, 'collector-scope')
  assert.match(findings[0].summary, /排除别的账号 0 条、归属不明 102 条/)
  assert.deepEqual(collectorScopeFindings({ relay: { kept: 9 } }), [], '一条都没排除就别报')
})

test('SC-012：健康现场 0 条告警', () => {
  const healthy = attach({ phoneHandlingMs: 300, connectorHandlingMs: 246 })
  const findings = buildFindings({
    attaches: [healthy],
    appEvents: [appEvent(2000)],
    connectorEvents: [{ kind: 'link.close', reason: 'agent stopped' }],
    relayEvents: [],
    coverage: { relay: { kept: 5, excludedOtherAgent: 3, excludedUnknownDevice: 0, knownDevices: 1 } },
  })
  assert.deepEqual(findings.filter((item) => item.level === 'warn'), [], `健康现场不该有告警：${JSON.stringify(findings)}`)
})

test('四类现场各能产出对应 finding，且 evidence 指得到包内文件', () => {
  const findings = buildFindings({
    attaches: [attach(), attach({ attachAt: '2026-10-13T02:35:02.117Z', attachMs: 900, appMissing: ['hello'] })],
    appEvents: [appEvent(2000)],
    connectorEvents: [
      { kind: 'device.attach-again', deviceId: 'dev_1', ms: 1100 },
      { kind: 'link.close', reason: 'relay closed the socket (1006 )', at: 'x' },
    ],
    relayEvents: [{ kind: 'relay.device-replaced', deviceId: 'dev_1', ms: 1105 }],
    coverage: { relay: { kept: 9, excludedOtherAgent: 0, excludedUnknownDevice: 102, knownDevices: 2 } },
  })
  const ids = new Set(findings.map((item) => item.id))
  for (const id of ['phone-slow', 'stage-missing', 'duplicate-socket', 'link-closed-abnormally']) {
    assert.ok(ids.has(id), `缺 ${id}：${[...ids].join(',')}`)
  }
  for (const item of findings) {
    assert.ok(item.evidence.length > 0, `${item.id} 没有证据`)
    for (const ref of item.evidence) {
      assert.match(ref, /^(attaches|timeline|coverage|sources\/)/, `证据要指到包内文件：${ref}`)
    }
  }
})

test('slowSideSummary：给出"哪一侧慢"的一句话，且与阈值同源', () => {
  const slow = slowSideSummary([attach()])
  assert.match(slow, /慢在\*\*手机侧\*\*/)
  assert.match(slow, /9455 ms vs 连接器 246 ms/)
  const even = slowSideSummary([attach({ phoneHandlingMs: 400, connectorHandlingMs: 246 })])
  assert.match(even, /同一量级/)
  assert.equal(slowSideSummary([attach({ phoneHandlingMs: null })]), null, '没有可比数字就不编结论')
})

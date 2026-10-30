/**
 * `/mobile-link/status` 的载荷契约（`contracts/status-endpoint.md`）。
 *
 * 这里只测**纯函数** `statusSnapshot()`：它是对外契约，最容易在"顺手加字段"时被破坏，
 * 所以用最小假 agent 把"老字段一个不少、新字段只增"钉住——不需要起 agent、也没有网络。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { DSH_HINTS, statusSnapshot } from '../lib/status.js'
import { SERVER_VERSION } from '../lib/hello.js'

/** 最小假 agent：只有 statusSnapshot 真正读到的字段。 */
function fakeAgent(overrides = {}) {
  return {
    enabled: true,
    hostForm: 'web',
    needsEnroll: false,
    identity: { agentId: 'agt_1', agentName: 'my mac', relayUrl: 'ws://relay.test', stateFile: '/tmp/agent.json' },
    config: { relayUrl: 'ws://relay.test', agentId: 'agt_1', stateFile: '/tmp/agent.json' },
    state: 'connected',
    dsh: { endpoint: { base: 'http://127.0.0.1:19387', source: 'host-service', port: 19387 }, cookie: 'dsh-auth-x=1', muxReady: true },
    dshError: undefined,
    router: { snapshot: () => [{ deviceId: 'dev_1' }] },
    devices: new Set(['dev_1']),
    streams: new Set(['ev:dev_1']),
    dedupe: new Set(),
    failure: undefined,
    startedAt: 1,
    connectedAt: 2,
    reconnectAttempts: 0,
    enrollHint: () => 'dsh plugin ...',
    ...overrides,
  }
}

test('every field the contract promises is present', () => {
  const status = statusSnapshot(fakeAgent())
  assert.equal(status.ok, true)
  assert.equal(status.host, 'web')
  assert.equal(status.protocolVersion, 1)
  assert.ok(Array.isArray(status.capabilities))
  assert.equal(status.enroll.registered, true)
  assert.equal(status.connected, true)
  assert.equal(status.dsh.source, 'host-service')
  assert.equal(status.dsh.port, 19387)
  assert.equal(status.dsh.authenticated, true)
  assert.equal(status.dsh.muxUp, true)
  assert.equal(status.deviceCount, 1)
  assert.equal(status.openStreams, 1)
})

test('the pre-existing fields keep their names and types (only additions allowed)', () => {
  const status = statusSnapshot(fakeAgent())
  for (const key of ['endpoint', 'source', 'port', 'authenticated', 'muxUp', 'error']) {
    assert.ok(key in status.dsh, `老字段 dsh.${key} 不见了`)
  }
  for (const key of ['state', 'connected', 'relayUrl', 'agentId', 'agentName', 'stateFile',
    'devices', 'deviceCount', 'openStreams', 'pendingWaterfalls', 'lastError',
    'startedAt', 'connectedAt', 'reconnectAttempts', 'enroll', 'protocolVersion',
    'serverVersion', 'capabilities', 'enabled', 'ok']) {
    assert.ok(key in status, `老字段 ${key} 不见了`)
  }
})

test('状态里同时给出连接器与宿主 DSH 的版本', () => {
  // 两个命名空间：`serverVersion` 是连接器，`hostVersion` 是跑它的 DSH。
  // 直接跑 DSH 时后者来自进程环境 `DSH_CLIENT_VERSION`；取不到如实给 null。
  const before = process.env.DSH_CLIENT_VERSION
  process.env.DSH_CLIENT_VERSION = '0.2.0-rc.2'
  try {
    const status = statusSnapshot(fakeAgent())
    assert.equal(status.serverVersion, SERVER_VERSION)
    assert.equal(status.hostVersion, '0.2.0-rc.2')
    delete process.env.DSH_CLIENT_VERSION
    assert.equal(statusSnapshot(fakeAgent()).hostVersion, null)
  } finally {
    if (before === undefined) delete process.env.DSH_CLIENT_VERSION
    else process.env.DSH_CLIENT_VERSION = before
  }
})

test('the lifecycle journal rides along as an added field', () => {
  // 新增字段：`lastError` 只有最后一条，而"为什么连不上"往往要看之前发生过什么。
  const withJournal = statusSnapshot(fakeAgent({
    journal: {
      path: '/tmp/link-events.jsonl',
      recorded: 9,
      dropped: 2,
      fileErrors: 0,
      recent: (count) => [{ kind: 'link.close', reason: 'watchdog' }].slice(-count),
    },
  }))
  assert.equal(withJournal.journal.path, '/tmp/link-events.jsonl')
  assert.equal(withJournal.journal.recorded, 9)
  assert.equal(withJournal.journal.dropped, 2)
  assert.equal(withJournal.journal.recent[0].kind, 'link.close')

  // 老调用方（假 agent、更早的接线）没有流水对象时给空块，不是 undefined：
  // 读者不用为了新增字段做判空。
  assert.deepEqual(statusSnapshot(fakeAgent()).journal,
    { path: null, recorded: 0, dropped: 0, fileErrors: 0, recent: [] })
})

test('a healthy link reports null classification and no hint', () => {
  const status = statusSnapshot(fakeAgent())
  assert.equal(status.dsh.errorKind, null)
  assert.equal(status.dsh.hint, null)
  assert.equal(status.dsh.docAnchor, null)
})

test('a failure carries classification + sentence + anchor together (FR-012)', () => {
  const agent = fakeAgent({ dshError: 'no DSH launch token found (looked at default)' })
  agent.dsh.errorKind = 'host-service'
  const status = statusSnapshot(agent)
  assert.equal(status.dsh.errorKind, 'host-service')
  assert.equal(status.dsh.hint, DSH_HINTS['host-service'].hint)
  assert.equal(status.dsh.docAnchor, '装在哪里：档案与插件入口')
})

test('an unknown classification still yields an actionable hint, never undefined', () => {
  const agent = fakeAgent({ dshError: 'boom' })
  agent.dsh.errorKind = undefined
  const status = statusSnapshot(agent)
  assert.equal(status.dsh.errorKind, 'unreachable')
  assert.match(status.dsh.hint, /确认宿主正在运行/)
})

test('the enrollment hint only appears while enrollment is pending', () => {
  const pending = statusSnapshot(fakeAgent({ needsEnroll: true, identity: undefined }))
  assert.equal(pending.enroll.needsEnroll, true)
  assert.match(pending.enroll.hint, /还没有登记到中转/)
  assert.equal(pending.enroll.command, 'dsh plugin ...')
  const done = statusSnapshot(fakeAgent())
  assert.equal(done.enroll.hint, null)
  assert.equal(done.enroll.command, null)
})

test('the host form carries its own sentence and doc anchor (FR-012)', async () => {
  const { HOST_HINTS } = await import('../lib/status.js')
  for (const [form, entry] of Object.entries(HOST_HINTS)) {
    const status = statusSnapshot(fakeAgent({ hostForm: form }))
    assert.equal(status.host, form)
    assert.equal(status.hostHint, entry.hint)
    assert.equal(status.hostDocAnchor, entry.docAnchor)
    assert.ok(status.hostHint && status.hostDocAnchor, `${form} 缺少提示或锚点`)
  }
})

test('an unrecognised host form still gets the "unknown" sentence, never undefined', () => {
  const status = statusSnapshot(fakeAgent({ hostForm: 'something-new' }))
  assert.equal(status.host, 'something-new', '原始取值照实上报，不篡改')
  assert.match(status.hostHint, /无法识别当前宿主/)
  assert.equal(status.hostDocAnchor, '排查：连不上时看这里')
})

test('the doc anchors this payload promises really exist in ONBOARDING', async () => {
  // 契约说锚点标题"逐字存在"，这里真的去核对一次，避免改了文档名而状态接口没跟上。
  const { readFileSync } = await import('node:fs')
  const { join } = await import('node:path')
  const doc = readFileSync(join(import.meta.dirname, '..', '..', '..', 'docs', 'ONBOARDING.md'), 'utf8')
  const titles = new Set([...statusSnapshot(fakeAgent({ dshError: 'x' })).hostDocAnchor
    ? [statusSnapshot(fakeAgent({ hostForm: 'desktop' })).hostDocAnchor,
       statusSnapshot(fakeAgent({ hostForm: 'web' })).hostDocAnchor,
       statusSnapshot(fakeAgent({ hostForm: 'unknown' })).hostDocAnchor]
    : []])
  for (const title of titles) {
    assert.ok(doc.includes(`## ${title}`), `ONBOARDING 里没有小节「${title}」`)
  }
})

test('the enrollment block exposes a safe relay prefill and its lock', () => {
  const configured = statusSnapshot(fakeAgent({
    needsEnroll: true,
    identity: undefined,
    config: { relayUrl: 'wss://relay.test/dsh-link', stateFile: '/tmp/agent.json' },
  }))
  assert.equal(configured.enroll.panel, true)
  assert.equal(configured.enroll.relayPrefill, 'wss://relay.test/dsh-link')
  assert.equal(configured.enroll.relayLocked, true)
  assert.equal(configured.enroll.relayUrl, 'wss://relay.test/dsh-link')

  const placeholder = statusSnapshot(fakeAgent({
    needsEnroll: true,
    identity: undefined,
    config: { relayUrl: 'wss://relay.example.com/dsh-link', stateFile: '/tmp/agent.json' },
  }))
  assert.equal(placeholder.enroll.relayPrefill, null, 'the placeholder is "unset", never a prefill')
  assert.equal(placeholder.enroll.relayLocked, false)
  assert.equal(placeholder.enroll.relayUrl, null, 'the placeholder must not be reported as a real relay')

  const registered = statusSnapshot(fakeAgent())
  assert.equal(registered.enroll.relayUrl, 'ws://relay.test')
  assert.equal(registered.enroll.relayLocked, true)

  const formDefault = statusSnapshot(fakeAgent({
    needsEnroll: true,
    identity: undefined,
    config: {
      relayUrl: 'wss://relay.example.com/dsh-link',
      defaultRelayUrl: 'wss://relay.test/dsh-link',
      stateFile: '/tmp/agent.json',
    },
  }))
  assert.equal(formDefault.enroll.relayPrefill, 'wss://relay.test/dsh-link',
    'a form default prefill must not require a real relayUrl')
  assert.equal(formDefault.enroll.relayLocked, false, 'the form default stays editable')
  assert.equal(formDefault.enroll.relayUrl, null,
    'the form default is not an authoritative relay address')
})

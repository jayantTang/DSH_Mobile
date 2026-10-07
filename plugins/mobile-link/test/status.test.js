/**
 * `/mobile-link/status` 的载荷契约（`contracts/status-endpoint.md`）。
 *
 * 这里只测**纯函数** `statusSnapshot()`：它是对外契约，最容易在"顺手加字段"时被破坏，
 * 所以用最小假 agent 把"老字段一个不少、新字段只增"钉住——不需要起 agent、也没有网络。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { DSH_HINTS, statusSnapshot } from '../lib/status.js'

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

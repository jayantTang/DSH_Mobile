/**
 * Routing tests for the DLP agent. A fake relay socket and a fake DSH client
 * drive `handleRelayFrame`, so no network or DSH instance is involved.
 */

import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { readFileSync, rmSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { MobileLinkAgent } from '../lib/link.js'

class FakeSocket {
  constructor() {
    this.sent = []
    this.closed = false
    this.closeCode = undefined
  }

  send(text) {
    this.sent.push(JSON.parse(text))
  }

  close(code) {
    this.closed = true
    this.closeCode = code
  }

  frames(type) {
    return this.sent.filter((frame) => frame.t === type)
  }

  last(type) {
    const frames = this.frames(type)
    return frames[frames.length - 1]
  }
}

class FakeDsh extends EventEmitter {
  constructor() {
    super()
    this.calls = []
    this.muxReady = true
    this.cookie = 'dsh-auth-test=v1'
    this.endpoint = { base: 'http://127.0.0.1:54499', port: 54499, source: 'test' }
    this.responses = new Map()
    this.rpcError = undefined
  }

  async ensureMux() {
    return { closed: false }
  }

  openStream(muxId, endpoint, args) {
    this.calls.push({ kind: 'open', muxId, endpoint, args })
  }

  cancelStream(muxId) {
    this.calls.push({ kind: 'cancel', muxId })
  }

  async rpc(method, args) {
    this.calls.push({ kind: 'rpc', method, args })
    if (this.rpcError) throw this.rpcError
    return this.responses.get(method) ?? { ok: true, value: { items: [] } }
  }

  close() {
    this.closed = true
  }

  opens() {
    return this.calls.filter((call) => call.kind === 'open')
  }

  cancels() {
    return this.calls.filter((call) => call.kind === 'cancel')
  }
}

function makeAgent({ responses } = {}) {
  const dsh = new FakeDsh()
  if (responses) for (const [method, value] of Object.entries(responses)) dsh.responses.set(method, value)
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({ dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1' })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test', agentName: 'test mac' }
  const socket = new FakeSocket()
  agent.socket = socket
  return { agent, dsh, socket }
}

const attach = (deviceId = 'dev_1') => ({ t: 'deviceAttach', deviceId, device: { name: 'iPhone', model: 'iPhone17,1' } })
const ready = (clientId = 'client_1') => ({ type: 'ready', clientId, host: { home: '/Users/x' } })

test('deviceAttach opens one $events stream per device', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(attach('dev_2'))
  const opens = dsh.opens()
  assert.deepEqual(opens.map((call) => call.muxId).sort(), ['ev:dev_1', 'ev:dev_2'])
  assert.deepEqual(opens[0].args, {})
  assert.equal(agent.devices.size, 2)

  // A duplicate attach is ignored (the relay re-attaches only after a reconnect).
  await agent.handleRelayFrame(attach('dev_1'))
  assert.equal(dsh.opens().length, 2)
})

test('the ready frame records the per-device clientId and is forwarded', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('client_9'))
  assert.equal(agent.devices.get('dev_1').clientId, 'client_9')
  assert.deepEqual(socket.last('event').value, { type: 'ready', clientId: 'client_9', host: { home: '/Users/x' } })
})

test('$events items become `event` frames until the device opens the stream', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'session/updated', args: [1] })
  assert.equal(socket.frames('event').length, 2)
  assert.equal(socket.frames('item').length, 0)

  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'session/updated', args: [2] })
  const item = socket.last('item')
  assert.equal(item.id, '2')
  assert.equal(item.deviceId, 'dev_1')
  assert.equal(item.value.args[0], 2)
  assert.equal(socket.frames('event').length, 2)
})

test('req is answered with res, preserving id and addressing', async () => {
  const { agent, dsh, socket } = makeAgent({
    responses: { 'session/list': { ok: true, value: { items: [{ sessionId: 's-1' }] } } },
  })
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'req', id: '1', method: 'session/list', args: { _request: {} }, deviceId: 'dev_1' })
  const res = socket.last('res')
  assert.equal(res.id, '1')
  assert.equal(res.deviceId, 'dev_1')
  assert.equal(res.ok, true)
  assert.deepEqual(res.value.items, [{ sessionId: 's-1' }])
  assert.deepEqual(dsh.calls.filter((call) => call.kind === 'rpc')[0].args, { _request: {} })
})

test('a failing DSH call becomes res ok:false with the DSH error shape', async () => {
  const { agent, socket } = makeAgent({
    responses: { 'session/page': { ok: false, error: { code: 'session/unknown', message: 'no such session', details: { id: 'x' } } } },
  })
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'req', id: '7', method: 'session/page', args: {}, deviceId: 'dev_1' })
  const res = socket.last('res')
  assert.equal(res.ok, false)
  assert.deepEqual(res.error, { code: 'session/unknown', message: 'no such session', details: { id: 'x' } })
})

test('an unreachable DSH turns into a host/unavailable error, not a crash', async () => {
  const { agent, dsh, socket } = makeAgent()
  dsh.rpcError = new Error('connect ECONNREFUSED')
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'req', id: '8', method: 'session/list', args: {}, deviceId: 'dev_1' })
  const res = socket.last('res')
  assert.equal(res.ok, false)
  assert.equal(res.error.code, 'host/unavailable')
})

test('open allocates a per-device mux stream; cancel tears it down', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach())
  const open = { t: 'open', id: '2', endpoint: 'session/follow',
    args: { request: { address: { kind: 'session', sessionId: 's-1' } } }, deviceId: 'dev_1' }
  await agent.handleRelayFrame(open)
  const forwarded = dsh.opens().find((call) => call.endpoint === 'session/follow')
  assert.equal(forwarded.muxId, 's:dev_1:2')
  assert.deepEqual(forwarded.args, open.args)

  agent.onStreamItem(forwarded.muxId, { type: 'snapshot' })
  assert.deepEqual(agent.socket.last('item'), { t: 'item', id: '2', deviceId: 'dev_1', value: { type: 'snapshot' } })

  await agent.handleRelayFrame({ t: 'cancel', id: '2', deviceId: 'dev_1' })
  assert.deepEqual(dsh.cancels().at(-1), { kind: 'cancel', muxId: 's:dev_1:2' })
})

test('two devices may reuse the same DLP stream id', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(attach('dev_2'))
  const open = (deviceId) => ({ t: 'open', id: '5', endpoint: 'session/follow', args: {}, deviceId })
  await agent.handleRelayFrame(open('dev_1'))
  await agent.handleRelayFrame(open('dev_2'))
  const muxIds = dsh.opens().filter((call) => call.endpoint === 'session/follow').map((call) => call.muxId)
  assert.deepEqual(muxIds.sort(), ['s:dev_1:5', 's:dev_2:5'])
})

test('a duplicate open id is refused with streamError', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach())
  const open = { t: 'open', id: '5', endpoint: 'session/follow', args: {}, deviceId: 'dev_1' }
  await agent.handleRelayFrame(open)
  await agent.handleRelayFrame(open)
  assert.equal(socket.last('streamError').error.code, 'stream/duplicate')
})

test('stream error and end are mapped back to the owning device only', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(attach('dev_2'))
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: 'session/follow', args: {}, deviceId: 'dev_1' })
  const muxId = 's:dev_1:2'
  agent.onStreamError(muxId, { code: 'gateway/input-invalid', message: 'bad', details: { f: 1 } })
  const failure = socket.last('streamError')
  assert.equal(failure.id, '2')
  assert.equal(failure.deviceId, 'dev_1')
  assert.equal(failure.error.code, 'gateway/input-invalid')

  await agent.handleRelayFrame({ t: 'open', id: '3', endpoint: 'session/follow', args: {}, deviceId: 'dev_2' })
  agent.onStreamEnd('s:dev_2:3')
  assert.deepEqual(socket.last('end'), { t: 'end', id: '3', deviceId: 'dev_2' })
})

test('detaching a device cancels every stream it owned', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: 'session/follow', args: {}, deviceId: 'dev_1' })
  await agent.handleRelayFrame({ t: 'open', id: '3', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  const cancelled = dsh.cancels().map((call) => call.muxId).sort()
  assert.deepEqual(cancelled, ['ev:dev_1', 's:dev_1:2'])
  assert.equal(agent.devices.size, 0)
  assert.equal(agent.streams.size, 0)
})

test('eventResult answers $events/result with this device clientId, first answer wins', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(attach('dev_2'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  agent.onStreamItem('ev:dev_2', ready('c2'))

  const answer = (deviceId, eventId) => agent.handleRelayFrame({
    t: 'eventResult', id: '3', deviceId,
    result: { clientId: 'ignored', eventId, outcome: { kind: 'result', value: { answers: ['a'] } } },
  })
  await answer('dev_1', 'evt_1')
  await answer('dev_2', 'evt_1')
  const calls = dsh.calls.filter((call) => call.kind === 'rpc' && call.method === '$events/result')
  assert.equal(calls.length, 1)
  assert.deepEqual(calls[0].args, {
    clientId: 'c1', eventId: 'evt_1', outcome: { kind: 'result', value: { answers: ['a'] } },
  })
})

test('eventResult is refused before the $events stream is ready', async () => {
  const { agent, socket, dsh } = makeAgent()
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'eventResult', id: '3', deviceId: 'dev_1', result: { eventId: 'e', outcome: { kind: 'next' } } })
  assert.equal(socket.last('error').code, 'events/not-ready')
  assert.equal(dsh.calls.filter((call) => call.method === '$events/result').length, 0)
})

test('a rejected waterfall answer is released so another device may retry', async () => {
  const { agent, dsh } = makeAgent()
  dsh.rpcError = new Error('boom')
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  await agent.handleRelayFrame({ t: 'eventResult', id: '3', deviceId: 'dev_1', result: { eventId: 'e1', outcome: { kind: 'next' } } })
  assert.equal(agent.dedupe.has('e1'), false)
  dsh.rpcError = undefined
  await agent.handleRelayFrame({ t: 'eventResult', id: '3', deviceId: 'dev_1', result: { eventId: 'e1', outcome: { kind: 'next' } } })
  assert.equal(agent.dedupe.has('e1'), true)
})

test('unknown frame types and unaddressed frames are ignored', async () => {
  const { agent, socket, dsh } = makeAgent()
  await agent.handleRelayFrame({ t: 'somethingNew', deviceId: 'dev_1' })
  await agent.handleRelayFrame({ t: 'req', id: '1', method: 'session/list' })
  await agent.handleRelayFrame(undefined)
  assert.equal(socket.sent.length, 0)
  assert.equal(dsh.calls.length, 0)
})

test('malformed device frames produce a protocol error instead of a DSH call', async () => {
  const { agent, socket, dsh } = makeAgent()
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'req', deviceId: 'dev_1' })
  assert.equal(socket.last('error').code, 'protocol/bad-frame')
  assert.equal(dsh.calls.filter((call) => call.kind === 'rpc').length, 0)
})

test('relay ping is answered and pong refreshes liveness', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame({ t: 'ping', ts: 42 })
  assert.deepEqual(socket.last('pong'), { t: 'pong', ts: 42 })
  const before = agent._lastPong
  await agent.handleRelayFrame({ t: 'pong', ts: 43 })
  assert.ok(agent._lastPong >= before)
})

test('a fatal relay error closes the socket', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame({ t: 'error', code: 'auth/invalid-agent', message: 'nope', fatal: true })
  assert.equal(socket.closed, true)
  assert.equal(socket.closeCode, 4002)
  assert.match(agent.lastError, /auth\/invalid-agent/)
})

test('mux-down notifies devices and re-arms their $events streams', async () => {
  const { agent, socket, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: 'session/follow', args: {}, deviceId: 'dev_1' })
  agent.onMuxDown('socket closed')
  const failure = socket.last('streamError')
  assert.equal(failure.id, '2')
  assert.equal(failure.error.code, 'host/unavailable')
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(agent.devices.get('dev_1').eventsMuxId, 'ev:dev_1')
  assert.ok(dsh.opens().some((call) => call.muxId === 'ev:dev_1'))
})

test('opening $events later replays the ready item so the device learns its clientId', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  // The ready item arrived before the device opened the stream (as an `event`).
  assert.equal(socket.last('event').value.clientId, 'c1')
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  const replayed = socket.last('item')
  assert.equal(replayed.id, '2')
  assert.equal(replayed.value.type, 'ready')
  assert.equal(replayed.value.clientId, 'c1')
})

test('status() reports connection, devices and streams', async () => {
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  const status = agent.status()
  assert.equal(status.connected, false)
  assert.equal(status.state, 'idle')
  assert.equal(status.agentId, 'agt_1')
  assert.equal(status.deviceCount, 1)
  assert.equal(status.devices[0].eventsReady, true)
  assert.equal(status.devices[0].name, 'iPhone')
  assert.equal(status.dsh.port, 54499)
  assert.equal(status.protocolVersion, 1)
})

test('file transfers are answered locally and never reach the Host', async () => {
  // The Host has no upload endpoint, so the link carries the bytes itself. If
  // these calls were forwarded they would fail as unknown methods — and the
  // whole point is that the relay and protocol stay unchanged.
  const { agent, dsh, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))

  const sessionId = `link-test-${process.pid}`
  const body = Buffer.from('hello from the phone, in bytes: \u0000\u0001\u0002')
  const transferId = 'tr-1'

  const send = (id, method, args) =>
    agent.handleRelayFrame({ t: 'req', id, method, args, deviceId: 'dev_1' })

  await send('1', '_link/fileBegin', {
    transferId, sessionId, name: 'notes.txt', bytes: body.length,
  })
  await send('2', '_link/fileChunk', { transferId, seq: 0, data: body.toString('base64') })
  await send('3', '_link/fileEnd', { transferId })

  const replies = socket.frames('res').filter((f) => ['1', '2', '3'].includes(f.id))
  assert.equal(replies.length, 3, 'the device did not get an answer for every call')
  assert.ok(replies.every((f) => f.ok === true), `a file call failed: ${JSON.stringify(replies)}`)

  // Selected by id rather than by position: the replies are not guaranteed to
  // arrive in the order the assertions in this file happen to assume.
  const done = replies.find((frame) => frame.id === '3')
  assert.ok(done?.value, `fileEnd replied without a value: ${JSON.stringify(replies)}`)
  assert.equal(done.value.bytes, body.length)
  assert.match(done.value.path, /notes\.txt$/)
  assert.ok(readFileSync(done.value.path).equals(body), 'the staged bytes differ')

  // Nothing was asked of the Host.
  assert.deepEqual(
    dsh.calls.filter((call) => String(call.method).startsWith('_link/')),
    [],
    'a file call was forwarded to the Host',
  )

  rmSync(join(homedir(), '.dsh', 'inbox', sessionId), { recursive: true, force: true })
})

test('_link/hello reports what this connector can do, without asking the Host', async () => {
  // The app feature-detects from this answer. It has to come over the link
  // rather than the HTTP status route, because the status route only exists on
  // the direct path and users run through the relay.
  const { agent, dsh, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'req', id: 'h1', method: '_link/hello', args: {}, deviceId: 'dev_1' })

  const reply = socket.frames('res').find((frame) => frame.id === 'h1')
  assert.ok(reply?.ok, `hello failed: ${JSON.stringify(reply)}`)
  assert.ok(reply.value.serverVersion, 'no server version reported')
  assert.ok(Array.isArray(reply.value.capabilities), 'no capability list reported')
  // The one the app gates its file entry on.
  assert.ok(reply.value.capabilities.includes('file-transfer'))
  assert.equal(reply.value.protocolVersion, 1)
  assert.deepEqual(
    dsh.calls.filter((call) => call.method === '_link/hello'),
    [],
    'hello was forwarded to the Host',
  )
})

test('the phone naming its build is recorded, and visible in the device snapshot', async () => {
  // The relay's device row is written at pairing and never again, so this frame
  // is the only place the *client's* build travels after that. Recording it is
  // what makes "did that phone update?" answerable.
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'req', id: 'h1', method: '_link/hello', deviceId: 'dev_1',
    args: { clientName: 'DSHMobile', clientVersion: '1.0', clientBuild: '20260919.0005' },
  })

  const record = agent.router.snapshot().find((entry) => entry.deviceId === 'dev_1')
  assert.equal(record.client.name, 'DSHMobile')
  assert.equal(record.client.build, '20260919.0005')
  assert.equal(record.client.label, 'DSHMobile 1.0 (20260919.0005)')
  // And the connector still answers the app's question.
  assert.ok(socket.frames('res').find((frame) => frame.id === 'h1')?.ok)
})

test('a phone that says nothing about itself reports nothing', async () => {
  // Older builds send `{}`. Inventing a version here would be worse than
  // admitting we do not know one.
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'req', id: 'h1', method: '_link/hello', args: {}, deviceId: 'dev_1' })
  const record = agent.router.snapshot().find((entry) => entry.deviceId === 'dev_1')
  assert.equal(record.client, null)
})

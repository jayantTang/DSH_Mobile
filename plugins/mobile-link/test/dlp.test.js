import assert from 'node:assert/strict'
import test from 'node:test'

import {
  MAX_FRAME_BYTES, PLACEHOLDER_RELAY_URL, StreamTable, WaterfallDedupe, agentEndpoint, decodeFrame,
  deviceFrameError, deviceIdOf, encodeFrame, isPlaceholderRelayUrl, joinRelayPath, nextBackoff,
  normalizeRelayUrl, pairCodeEndpoint, pongFor, qrPayload, resultFrame,
} from '../lib/dlp.js'

test('decodeFrame accepts a well-formed frame', () => {
  const frame = decodeFrame('{"t":"req","id":"1","method":"session/list","args":{"_request":{}}}')
  assert.equal(frame.t, 'req')
  assert.deepEqual(frame.args, { _request: {} })
})

test('decodeFrame keeps unknown frame types (forward compatibility)', () => {
  assert.equal(decodeFrame('{"t":"somethingNew","x":1}').t, 'somethingNew')
})

test('decodeFrame rejects unusable payloads', () => {
  for (const raw of ['nope', '[]', '3', '{"id":"1"}', '{"t":""}', '{"t":5}', null, undefined, 42]) {
    assert.equal(decodeFrame(raw), undefined)
  }
})

test('decodeFrame rejects oversized frames', () => {
  const huge = `{"t":"item","value":"${'x'.repeat(MAX_FRAME_BYTES)}"}`
  assert.equal(decodeFrame(huge), undefined)
})

test('encodeFrame round-trips through decodeFrame', () => {
  const frame = { t: 'pong', ts: 7, 标题: '值' }
  assert.deepEqual(decodeFrame(encodeFrame(frame)), frame)
})

test('deviceFrameError only complains about device frames', () => {
  assert.equal(deviceFrameError({ t: 'req', id: '1', method: 'session/list' }), undefined)
  assert.match(deviceFrameError({ t: 'req', method: 'session/list' }), /missing `id`/)
  assert.match(deviceFrameError({ t: 'req', id: '1' }), /missing `method`/)
  assert.match(deviceFrameError({ t: 'open', id: '1' }), /missing `endpoint`/)
  assert.equal(deviceFrameError({ t: 'hostStatus', info: {} }), undefined)
})

test('deviceIdOf ignores blank ids', () => {
  assert.equal(deviceIdOf({ deviceId: 'dev_1' }), 'dev_1')
  assert.equal(deviceIdOf({ deviceId: '' }), undefined)
  assert.equal(deviceIdOf({}), undefined)
})

test('nextBackoff doubles, caps and jitters within ±20%', () => {
  const noJitter = { random: () => 0.5 }
  assert.equal(nextBackoff(0, noJitter), 1000)
  assert.equal(nextBackoff(1, noJitter), 2000)
  assert.equal(nextBackoff(2, noJitter), 4000)
  assert.equal(nextBackoff(10, noJitter), 30000)
  assert.equal(nextBackoff(0, { random: () => 0 }), 800)
  assert.equal(nextBackoff(0, { random: () => 1 }), 1200)
  assert.equal(nextBackoff(-5, noJitter), 1000)
})

test('normalizeRelayUrl maps schemes and paths', () => {
  const secure = normalizeRelayUrl('wss://relay.example.com')
  assert.equal(secure.httpBase, 'https://relay.example.com')
  assert.equal(secure.wsBase, 'wss://relay.example.com')
  assert.equal(secure.secure, true)

  const local = normalizeRelayUrl('http://127.0.0.1:8787/prefix/')
  assert.equal(local.httpBase, 'http://127.0.0.1:8787/prefix')
  assert.equal(local.wsBase, 'ws://127.0.0.1:8787/prefix')

  assert.equal(normalizeRelayUrl('relay.example.com').wsBase, 'wss://relay.example.com')
  assert.throws(() => normalizeRelayUrl(''))
  assert.throws(() => normalizeRelayUrl('ftp://host'))
})

test('isPlaceholderRelayUrl spots the sentinel in any spelling, and only it', () => {
  // The placeholder means "not configured", so it has to be recognised however
  // it is written down — and a real address must never be mistaken for it.
  for (const raw of [
    PLACEHOLDER_RELAY_URL,
    'wss://relay.example.com/dsh-link/',
    'https://relay.example.com/dsh-link',
    'relay.example.com/dsh-link',
  ]) {
    assert.equal(isPlaceholderRelayUrl(raw), true, `${raw} is the placeholder`)
  }
  for (const raw of [
    'wss://relay.example.com',
    'wss://relay.example.com/other',
    'wss://real.example/dsh-link',
    'ws://127.0.0.1:8787',
    '',
    undefined,
    42,
  ]) {
    assert.equal(isPlaceholderRelayUrl(raw), false, `${String(raw)} is a real address`)
  }
})

test('normalizeRelayUrl keeps a path prefix and drops a trailing slash', () => {
  const plain = normalizeRelayUrl('wss://relay.example.com/dsh-link')
  assert.equal(plain.wsBase, 'wss://relay.example.com/dsh-link')
  assert.equal(plain.httpBase, 'https://relay.example.com/dsh-link')

  const trailing = normalizeRelayUrl('wss://relay.example.com/dsh-link/')
  assert.equal(trailing.wsBase, 'wss://relay.example.com/dsh-link')

  const nested = normalizeRelayUrl('https://host/a/b///')
  assert.equal(nested.wsBase, 'wss://host/a/b')
  assert.equal(nested.httpBase, 'https://host/a/b')

  const root = normalizeRelayUrl('wss://host/')
  assert.equal(root.wsBase, 'wss://host')
  assert.equal(agentEndpoint('wss://host/'), 'wss://host/link/agent')
})

test('joinRelayPath appends without replacing the prefix', () => {
  assert.equal(joinRelayPath('wss://host/dsh-link', '/link/agent'), 'wss://host/dsh-link/link/agent')
  assert.equal(joinRelayPath('wss://host/dsh-link/', 'link/agent'), 'wss://host/dsh-link/link/agent')
  assert.equal(joinRelayPath('wss://host', '/link/agent'), 'wss://host/link/agent')
  assert.equal(joinRelayPath('', '/healthz'), '/healthz')
})

test('the connector and pairing endpoints keep the configured prefix', () => {
  assert.equal(agentEndpoint('wss://relay.example.com/dsh-link'),
    'wss://relay.example.com/dsh-link/link/agent')
  assert.equal(agentEndpoint('wss://relay.example.com/dsh-link/'),
    'wss://relay.example.com/dsh-link/link/agent')
  assert.equal(agentEndpoint('ws://127.0.0.1:8787'), 'ws://127.0.0.1:8787/link/agent')
  assert.equal(pairCodeEndpoint('wss://relay.example.com/dsh-link'),
    'https://relay.example.com/dsh-link/pair/code')
  assert.equal(pairCodeEndpoint('ws://127.0.0.1:8787/'), 'http://127.0.0.1:8787/pair/code')
})

test('qrPayload is a stable dsh:// deep link carrying the prefixed relay URL', () => {
  const payload = qrPayload({ relay: 'wss://relay.example.com/dsh-link', code: '7F3K-9Q2M' })
  assert.equal(payload,
    'dsh://pair?relay=wss%3A%2F%2Frelay.example.com%2Fdsh-link&code=7F3K-9Q2M')
  const parsed = new URL(payload.replace('dsh://', 'https://'))
  assert.equal(parsed.searchParams.get('relay'), 'wss://relay.example.com/dsh-link')
  assert.equal(parsed.searchParams.get('code'), '7F3K-9Q2M')
})

test('pongFor mirrors ts even when absent', () => {
  assert.deepEqual(pongFor({ t: 'ping', ts: 5 }), { t: 'pong', ts: 5 })
  assert.deepEqual(pongFor({ t: 'ping' }), { t: 'pong', ts: undefined })
})

test('resultFrame maps both DSH result branches', () => {
  assert.deepEqual(resultFrame('1', { ok: true, value: { items: [] } }, 'dev_1'),
    { t: 'res', id: '1', deviceId: 'dev_1', ok: true, value: { items: [] } })
  assert.deepEqual(resultFrame('2', { ok: false, error: { code: 'x', message: 'y', details: { a: 1 } } }, 'dev_1'),
    { t: 'res', id: '2', deviceId: 'dev_1', ok: false, error: { code: 'x', message: 'y', details: { a: 1 } } })
  assert.deepEqual(resultFrame('3', undefined, 'dev_1').error.code, 'gateway/failed')
})

test('StreamTable keeps identical DLP ids on different devices apart', () => {
  const table = new StreamTable()
  assert.equal(table.add({ deviceId: 'dev_1', dlpId: '2', muxId: 'a', endpoint: 'session/follow' }), true)
  assert.equal(table.add({ deviceId: 'dev_2', dlpId: '2', muxId: 'b', endpoint: 'session/follow' }), true)
  assert.equal(table.add({ deviceId: 'dev_1', dlpId: '2', muxId: 'c', endpoint: 'session/follow' }), false)
  assert.equal(table.muxOf('dev_1', '2'), 'a')
  assert.equal(table.muxOf('dev_2', '2'), 'b')
  assert.equal(table.size, 2)
  assert.equal(table.removeByDlp('dev_1', '2'), 'a')
  assert.equal(table.entryOfMux('a'), undefined)
  assert.equal(table.muxOf('dev_2', '2'), 'b')
})

test('StreamTable.removeDevice returns every mux stream of one device', () => {
  const table = new StreamTable()
  table.add({ deviceId: 'dev_1', dlpId: '1', muxId: 'm1', endpoint: 'x' })
  table.add({ deviceId: 'dev_1', dlpId: '2', muxId: 'm2', endpoint: 'y' })
  table.add({ deviceId: 'dev_1', dlpId: '', muxId: 'ev', endpoint: '$events' })
  table.add({ deviceId: 'dev_2', dlpId: '1', muxId: 'o1', endpoint: 'x' })
  assert.deepEqual(table.removeDevice('dev_1').sort(), ['ev', 'm1', 'm2'])
  assert.equal(table.size, 1)
  assert.equal(table.muxOf('dev_2', '1'), 'o1')
})

test('WaterfallDedupe is first-answer-wins with TTL cleanup', () => {
  let clock = 1000
  const dedupe = new WaterfallDedupe({ ttlMs: 100, now: () => clock })
  assert.equal(dedupe.claim('evt_1'), true)
  assert.equal(dedupe.claim('evt_1'), false)
  assert.equal(dedupe.has('evt_1'), true)
  assert.equal(dedupe.claim(''), false)
  clock += 101
  assert.equal(dedupe.claim('evt_1'), true)
})

test('WaterfallDedupe.release hands a failed answer back', () => {
  const dedupe = new WaterfallDedupe()
  assert.equal(dedupe.claim('evt_2'), true)
  dedupe.release('evt_2')
  assert.equal(dedupe.has('evt_2'), false)
  assert.equal(dedupe.claim('evt_2'), true)
})

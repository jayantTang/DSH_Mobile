/**
 * Wiring tests for the cordis plugin half: route registration, the request
 * fence, and the promise that the link never depends on a DSH service.
 *
 * A fake context stands in for DSH, so no server is started.
 */

import assert from 'node:assert/strict'
import test from 'node:test'

// Point the harness home at a throwaway directory before the plugin is
// imported. Without this the plugin persists the fixture identity below over
// the real `~/.dsh/mobile-link/agent.json` — which silently replaced a working
// connector's credentials with `agt_test`/`as_test` and broke its reconnection.
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const TEST_HOME = mkdtempSync(join(tmpdir(), 'mobile-link-plugin-test-'))
process.env.DSH_HOME = TEST_HOME
process.on('exit', () => rmSync(TEST_HOME, { recursive: true, force: true }))

import * as plugin from '../lib/index.js'

const BASE_CONFIG = {
  enabled: false,
  relayUrl: 'ws://127.0.0.1:9',
  agentId: 'agt_test',
  agentSecret: 'as_test',
}

function fakeResponse() {
  return {
    statusCode: 200,
    headers: {},
    chunks: [],
    ended: false,
    setHeader(name, value) {
      this.headers[name.toLowerCase()] = value
    },
    end(chunk) {
      this.ended = true
      if (chunk !== undefined) this.chunks.push(String(chunk))
    },
    get body() {
      return this.chunks.join('')
    },
  }
}

function fakeRequest(method = 'GET', body, url = '/') {
  return {
    method,
    url,
    headers: {},
    async *[Symbol.asyncIterator]() {
      if (body !== undefined) yield Buffer.from(JSON.stringify(body))
    },
  }
}

/**
 * @param {'allow'|'missing'|number} fence  how DSH's connection service behaves
 */
function fakeContext({ fence = 'allow', injectable = true } = {}) {
  const routes = new Map()
  const effects = []
  const injected = []
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const webServer = {
    register(route) {
      routes.set(route.path, route)
      return () => routes.delete(route.path)
    },
  }
  const connection = fence === 'missing'
    ? undefined
    : { requestRejection: () => (fence === 'allow' ? null : fence) }
  const get = (service) => (service === 'connection'
    ? connection
    : service === 'webServer' ? webServer : undefined)
  const scope = { webServer, get, effect: (fn, label) => effects.push([label, fn()]) }
  const ctx = {
    logger,
    get,
    effect: (fn, label) => effects.push([label, fn()]),
    inject(services, callback) {
      injected.push(services)
      if (!injectable) throw new Error('service injection is unavailable')
      return callback(scope)
    },
  }
  return { ctx, routes, effects, injected, webServer, logger }
}

test('the plugin advertises no required services', () => {
  assert.equal(plugin.name, 'mobile-link')
  assert.equal(plugin.inject, undefined, 'a DSH service must never be able to block the link')
})

test('apply registers every route through ctx.inject and starts the agent', () => {
  const { ctx, routes, effects, injected } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  assert.deepEqual([...routes.keys()].sort(), ['/mobile-link/pair-code', '/mobile-link/qr', '/mobile-link/status'])
  assert.deepEqual(injected, [['webServer']])
  assert.ok(effects.some(([label]) => label.includes('DLP agent')))
})

test('apply survives a missing webServer service', () => {
  const { ctx, routes } = fakeContext({ injectable: false })
  assert.doesNotThrow(() => plugin.apply(ctx, BASE_CONFIG))
  assert.equal(routes.size, 0)
})

test('a rejected request is passed through with the fence status', async () => {
  const { ctx, routes } = fakeContext({ fence: 403 })
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('GET'), res)
  assert.equal(res.statusCode, 403)
  assert.equal(res.body, '')

  const refused = fakeResponse()
  await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', {}), refused)
  assert.equal(refused.statusCode, 403)
})

test('GET /mobile-link/status answers a JSON snapshot', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('GET'), res)
  assert.equal(res.statusCode, 200)
  assert.equal(res.headers['content-type'], 'application/json; charset=utf-8')
  const status = JSON.parse(res.body)
  assert.equal(status.ok, true)
  assert.equal(status.enabled, false)
  assert.equal(status.state, 'disabled')
  assert.equal(status.agentId, 'agt_test')
  assert.deepEqual(status.devices, [])
  assert.equal(status.protocolVersion, 1)
})

test('GET /mobile-link/status stays readable when the fence service is missing', async () => {
  const { ctx, routes } = fakeContext({ fence: 'missing' })
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('GET'), res)
  assert.equal(res.statusCode, 200)
  assert.equal(JSON.parse(res.body).ok, true)
})

test('POST /mobile-link/pair-code refuses to mint without the fence service', async () => {
  const { ctx, routes } = fakeContext({ fence: 'missing' })
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', {}), res)
  assert.equal(res.statusCode, 403)
  assert.match(res.body, /connection service is unavailable/)
})

test('POST /mobile-link/pair-code reports an unreachable relay without throwing', async () => {
  // The fence is satisfied; only the relay is unreachable (discard port 9).
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', { ttlMs: 60000 }), res)
  assert.equal(res.statusCode, 502)
  const body = JSON.parse(res.body)
  assert.equal(body.ok, false)
  assert.equal(body.code, 'relay/unavailable')
  assert.match(body.message, /fetch failed|ECONNREFUSED|connect/i)
})

test('wrong HTTP methods get a 405 with Allow', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const status = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('POST', {}), status)
  assert.equal(status.statusCode, 405)
  assert.equal(status.headers.allow, 'GET')

  const pair = fakeResponse()
  await routes.get('/mobile-link/pair-code').handler(fakeRequest('GET'), pair)
  assert.equal(pair.statusCode, 405)
  assert.equal(pair.headers.allow, 'POST')
})

// ── GET /mobile-link/qr ────────────────────────────────────────────────────
//
// The pairing screen is one URL: open it, see a scannable code, with no desktop
// client involvement. `?format=json` is the same content for the tests.
//
// The relay is unreachable here, so `mintPairCode` is stubbed on the prototype:
// the routes call exactly that one method, and standing up a fake relay would
// test the relay instead of the route.

/** Runs `fn` with every agent's `mintPairCode` replaced. */
async function withMint(stub, fn) {
  const original = plugin.MobileLinkAgent.prototype.mintPairCode
  plugin.MobileLinkAgent.prototype.mintPairCode = stub
  try {
    return await fn()
  } finally {
    plugin.MobileLinkAgent.prototype.mintPairCode = original
  }
}

const MINTED = {
  code: 'JKMN-PQRS-TUVW-XYZ2',
  expiresAt: Date.now() + 600_000,
  ttlMs: 600_000,
  relayUrl: 'wss://relay.test/dsh-link',
  agentId: 'agt_x',
  qrPayload: 'dsh://pair?relay=wss%3A%2F%2Frelay.test%2Fdsh-link&code=JKMN-PQRS-TUVW-XYZ2',
}

test('GET /mobile-link/qr renders an SVG when the relay mints a code', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await withMint(async () => MINTED, () =>
    routes.get('/mobile-link/qr').handler(fakeRequest('GET', undefined, '/mobile-link/qr'), res))

  assert.equal(res.statusCode, 200)
  assert.equal(res.headers['content-type'], 'image/svg+xml; charset=utf-8')
  assert.equal(res.headers['cache-control'], 'no-store')
  assert.match(res.body, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/)
  assert.match(res.body, /<path d="M/)
})

test('GET /mobile-link/qr?format=json returns the payload and the SVG', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await withMint(async () => MINTED, () =>
    routes.get('/mobile-link/qr').handler(
      fakeRequest('GET', undefined, '/mobile-link/qr?format=json'), res))

  assert.equal(res.statusCode, 200)
  const body = JSON.parse(res.body)
  assert.equal(body.ok, true)
  assert.equal(body.code, MINTED.code)
  assert.equal(body.qrPayload, MINTED.qrPayload)
  assert.match(body.svg, /^<svg /)
})

test('GET /mobile-link/qr fails closed when the relay is unreachable', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await withMint(async () => { throw new Error('fetch failed') }, () =>
    routes.get('/mobile-link/qr').handler(fakeRequest('GET', undefined, '/mobile-link/qr'), res))

  assert.equal(res.statusCode, 502)
  assert.equal(JSON.parse(res.body).code, 'relay/unavailable')
})

test('GET /mobile-link/qr refuses to mint without the DSH fence', async () => {
  const { ctx, routes } = fakeContext({ fence: 'missing' })
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/qr').handler(fakeRequest('GET', undefined, '/mobile-link/qr'), res)
  assert.equal(res.statusCode, 403)
})

test('GET /mobile-link/qr rejects other methods', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/qr').handler(fakeRequest('POST', {}), res)
  assert.equal(res.statusCode, 405)
  assert.equal(res.headers.allow, 'GET')
})

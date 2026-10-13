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
    port: 52430,
    register(route) {
      routes.set(route.path, route)
      return () => routes.delete(route.path)
    },
  }
  const connection = fence === 'missing'
    ? undefined
    : {
      // DSH 的真实契约：拒绝时给状态码，**放行时给 undefined**
      // （`Connection.requestRejection` 的实现就是 `isAuthenticated ? undefined : 401`）。
      // 夹具必须照抄这一点——用 null 表示放行曾把一个真 bug 藏了起来：
      // 插件把 undefined 当成"没有栅栏服务"，于是所有需要栅栏的路由对
      // 已认证的浏览器请求一律 403，配对页和 `POST /pair-code` 谁都用不了。
      requestRejection: () => (fence === 'allow' ? undefined : fence),
      authenticatedUrl: (base) => `${base}/?token=test-token`,
    }
  const get = (service) => (service === 'connection'
    ? connection
    : service === 'webServer' ? webServer : undefined)
  const scope = { webServer, connection, get, effect: (fn, label) => effects.push([label, fn()]) }
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
  assert.deepEqual([...routes.keys()].sort(), ['/mobile-link/pair-code', '/mobile-link/status'])
  // `sessionQuery` is injected **optionally**: history reads fall back to
  // `session/page` when the Host does not have the service (spec 007 FR-002).
  assert.deepEqual(injected, [['webServer'], ['webServer', 'connection'], ['sessionQuery']])
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

// ── POST /mobile-link/pair-code ────────────────────────────────────────────
//
// This one route now serves the pairing panel in the DSH client (spec 010): the
// code, its QR payload and the symbol come back together. There is no browser
// pairing page any more, so the properties that used to belong to it — "the
// picture and the code are the same", "a code that was spent is never shown
// again" — are properties of this response.
//
// The relay is unreachable here, so `mintPairCode` is stubbed on the prototype:
// the route calls exactly that one method, and standing up a fake relay would
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

/** Calls the pair-code route with its stub in place and parses the answer. */
function pairBody(routes, stub = async () => ({ ...MINTED })) {
  const res = fakeResponse()
  return withMint(stub, async () => {
    await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', {}), res)
    return { res, body: res.body ? JSON.parse(res.body) : undefined }
  })
}

test('POST /mobile-link/pair-code returns the symbol with the code it belongs to', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const { res, body } = await pairBody(routes)

  assert.equal(res.statusCode, 200)
  assert.equal(res.headers['content-type'], 'application/json; charset=utf-8')
  assert.equal(body.ok, true)
  assert.equal(body.code, MINTED.code)
  assert.equal(body.qrPayload, MINTED.qrPayload)
  assert.equal(body.expiresAt, MINTED.expiresAt)
  // The pre-existing field set, unchanged (宪法原则 IV): an older App reads
  // exactly these. `svg` above is the only addition.
  assert.equal(body.ttlMs, MINTED.ttlMs)
  assert.equal(body.relayUrl, MINTED.relayUrl)
  assert.equal(body.agentId, MINTED.agentId)
  assert.deepEqual(Object.keys(body).sort(),
    ['agentId', 'code', 'expiresAt', 'ok', 'qrPayload', 'relayUrl', 'svg', 'ttlMs'])
  // Same answer, same symbol: the panel must never show a picture from one
  // response and a code from another.
  assert.match(body.svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/)
  assert.match(body.svg, /<path d="M/)
})

test('the symbol carries no caption (the panel runs its own countdown)', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const { body } = await pairBody(routes)
  assert.equal(body.svg.includes('<text'), false, '服务端渲染的"还剩 N 分钟"会随窗口打开而失真')
})

test('every call mints a fresh code, so a spent one is never handed out again', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  let mints = 0
  const stub = async () => {
    mints += 1
    return { ...MINTED, code: `CODE-000${mints}`, qrPayload: `${MINTED.qrPayload}-${mints}` }
  }

  const first = await pairBody(routes, stub)
  const second = await pairBody(routes, stub)
  assert.equal(mints, 2, '取码接口不许复用上一张：复用正是"扫到废码"的来源')
  assert.equal(first.body.code, 'CODE-0001')
  assert.equal(second.body.code, 'CODE-0002')
  assert.notEqual(first.body.svg, second.body.svg, '换码必须换图')
})

test('POST /mobile-link/pair-code fails closed when the relay is unreachable', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const { res, body } = await pairBody(routes, async () => { throw new Error('fetch failed') })

  assert.equal(res.statusCode, 502)
  assert.equal(body.ok, false)
  assert.equal(body.code, 'relay/unavailable')
  assert.equal(body.svg, undefined, '拿不到码就不许给半张图')
})

test('detectHostForm reads evidence from the process, never from inherited env', () => {
  // 官方桌面版：入口脚本是私有的 dsh-desktop-host，或可执行文件在应用包里。
  assert.equal(plugin.detectHostForm({ argv: ['node', '/x/@deepseek-ai/dsh-desktop-host/lib/index.js'], execPath: '/usr/bin/node' }), 'desktop')
  assert.equal(plugin.detectHostForm({ argv: ['node', '/x/bin/dsh', 'web'], execPath: '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness' }), 'desktop')
  // 命令行 web 版：普通 node + dsh 入口。
  assert.equal(plugin.detectHostForm({ argv: ['node', '/x/bin/dsh', 'web'], execPath: '/opt/homebrew/bin/node' }), 'web')
})

test('a web host started from inside the desktop app is NOT misdetected as desktop', () => {
  // 回归：从桌面版宿主里敲 `dsh web` 会继承 ELECTRON_RUN_AS_NODE 之类的环境变量；
  // 早期实现据此判断，结果把 web 宿主报成 desktop（慢闸实测抓到）。
  const inherited = { ELECTRON_RUN_AS_NODE: '1', DSH_HOME: '/tmp/x' }
  const form = plugin.detectHostForm({ ...inherited, argv: ['node', '/opt/homebrew/bin/dsh', 'web'], execPath: '/opt/homebrew/Cellar/node/25.5.0/bin/node' })
  assert.equal(form, 'web', '不能因为继承来的环境变量就判定成桌面版')
})

test('setHostService wires (and clears) the in-process resolver', () => {
  const agent = new plugin.MobileLinkAgent({ enabled: false, relayUrl: 'ws://127.0.0.1:9', logger: console })
  const resolver = () => 'http://127.0.0.1:19387/?token=t'
  agent.setHostService(resolver)
  assert.equal(agent.dsh.hostService, resolver)
  assert.equal(agent.dsh.hostService(), 'http://127.0.0.1:19387/?token=t')
  agent.setHostService(undefined)
  assert.equal(agent.dsh.hostService, undefined)
})

test('the status snapshot carries the host form the plugin set', () => {
  const agent = new plugin.MobileLinkAgent({ enabled: false, relayUrl: 'ws://127.0.0.1:9', logger: console })
  agent.setHostForm('desktop')
  assert.equal(agent.status().host, 'desktop')
  agent.setHostForm('nonsense')
  assert.equal(agent.status().host, 'unknown', '认不出的形态必须落到 unknown，而不是照抄')
})

test('with no connection service the routes stay registered and the privileged ones fail closed', async () => {
  const { ctx, routes } = fakeContext({ fence: 'missing' })
  assert.doesNotThrow(() => plugin.apply(ctx, BASE_CONFIG))
  assert.equal(routes.size, 2, 'connection 缺失不该让路由消失')

  const status = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('GET'), status)
  assert.equal(status.statusCode, 200, '/status 是诊断用的，栅栏缺失时仍要能读')

  const pair = fakeResponse()
  await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', {}), pair)
  assert.equal(pair.statusCode, 403, '铸造凭据的路由必须失败关闭')
  assert.match(pair.body, /connection service is unavailable/)
})

test('a fence that says yes (undefined) is a pass, not a missing service', async () => {
  // 回归：DSH 放行时返回 undefined。以前这条被当成"栅栏服务不存在"，
  // 结果是浏览器带着正确凭据打开配对页面永远 403。
  const { ctx, routes } = fakeContext({ fence: 'allow' })
  plugin.apply(ctx, BASE_CONFIG)
  await withMint(async () => ({ ...MINTED }), async () => {
    const pair = fakeResponse()
    await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', {}), pair)
    assert.equal(pair.statusCode, 200, '栅栏放行就必须放行')
    assert.match(JSON.parse(pair.body).svg, /^<svg /)
  })
})

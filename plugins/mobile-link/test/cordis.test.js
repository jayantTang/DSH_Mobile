/**
 * Loads the plugin through the *real* cordis runtime that DSH ships, instead of
 * the hand-rolled fake context in `plugin.test.js`. This is what proves that
 * `ctx.effect`, `ctx.inject([...])`, `ctx.get('connection')` and
 * `webServer.register` are used correctly, and that the DLP agent does not need
 * any DSH service to load.
 *
 * Skipped when the DSH installation cannot be resolved (CI without DSH).
 */

import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { apply, name as pluginName } from '../lib/index.js'
import { dshAnchors } from './dsh-install.js'

const PACKAGE_DIR = fileURLToPath(new URL('..', import.meta.url))

async function loadFromDsh(specifier) {
  for (const anchor of dshAnchors()) {
    try {
      const require = createRequire(anchor)
      return await import(require.resolve(specifier))
    } catch {
      /* try the next anchor */
    }
  }
  return undefined
}

const loadCordis = () => loadFromDsh('@deepseek-ai/cordis')

function fakeLogger() {
  const lines = []
  const push = (level) => (...args) => lines.push([level, args.map(String).join(' ')])
  return {
    lines,
    debug: push('debug'),
    info: push('info'),
    warn: push('warn'),
    error: push('error'),
  }
}

const CONFIG = { enabled: false, relayUrl: 'ws://127.0.0.1:9', agentId: 'agt_x', agentSecret: 'as_x' }

test('DSH recognises the package as a profile bundle', async (t) => {
  const boot = await loadFromDsh('@deepseek-ai/dsh-app-boot')
  if (!boot) return t.skip('no DSH install to borrow its manifest reader from')

  const manifest = boot.readProfileManifest('dsh', PACKAGE_DIR)
  assert.equal(manifest.name, 'dsh-plugin-mobile-link')
  const patch = manifest.dsh?.bundle?.patch
  assert.equal(patch, './cordis.patch.yml')
  assert.ok(existsSync(resolve(PACKAGE_DIR, patch)), 'the bundle patch file must exist')
  const yml = readFileSync(resolve(PACKAGE_DIR, patch), 'utf8')
  assert.match(yml, /- insert:/)
  assert.match(yml, /name: '\.\/lib\/index\.js'/)
})

test('the plugin joins a real cordis tree and registers its routes', async (t) => {
  const cordis = await loadCordis()
  if (!cordis) return t.skip('no DSH install to borrow cordis from')

  const routes = new Map()
  const logger = fakeLogger()
  const root = new cordis.Context()
  root.provide('webServer', {
    register(route) {
      routes.set(route.path, route)
      return () => routes.delete(route.path)
    },
  })
  root.provide('connection', { requestRejection: () => null })
  root.provide('logger', logger)

  const fiber = await root.plugin({ name: pluginName, apply }, CONFIG)
  assert.deepEqual([...routes.keys()].sort(), ['/mobile-link/pair-code', '/mobile-link/qr', '/mobile-link/status'])

  const res = {
    statusCode: 200,
    headers: {},
    setHeader(key, value) {
      this.headers[key] = value
    },
    end(body) {
      this.body = body
    },
  }
  await routes.get('/mobile-link/status').handler({ method: 'GET', headers: {} }, res)
  assert.equal(res.statusCode, 200)
  assert.equal(JSON.parse(res.body).state, 'disabled')

  await fiber.dispose()
  assert.equal(routes.size, 0, 'disposing the plugin removes its routes')
})

test('the DLP agent loads with no DSH service available at all', async (t) => {
  const cordis = await loadCordis()
  if (!cordis) return t.skip('no DSH install to borrow cordis from')

  const routes = new Map()
  const root = new cordis.Context()
  root.provide('logger', fakeLogger())

  // No webServer / connection: `ctx.inject` simply parks the routes until the
  // service shows up, and the link itself must still come up.
  const fiber = await root.plugin({ name: pluginName, apply }, CONFIG)
  assert.equal(routes.size, 0)

  await fiber.dispose()
})

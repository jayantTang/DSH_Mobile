/**
 * 热插拔契约（003）：插件被禁用时，它挂在宿主上的每一样东西都必须撤干净；再启用要能原样回来。
 *
 * 走真实的 `apply` + 官方语义的 stub（`effect` 收集清理函数、路由注册返回 disposer）——
 * 也就是宿主禁用插件时驱动的那条路径的镜像。注意 `enabled: false`：这条用例不该去碰网络。
 */

import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

// 与 plugin.test.js 同样的隔离：不让用例碰到真实的 ~/.dsh/mobile-link/agent.json。
const TEST_HOME = mkdtempSync(join(tmpdir(), 'mobile-link-hotplug-'))
process.env.DSH_HOME = TEST_HOME
process.on('exit', () => rmSync(TEST_HOME, { recursive: true, force: true }))

import * as plugin from '../lib/index.js'

const BASE_CONFIG = {
  enabled: false,
  relayUrl: 'ws://127.0.0.1:9',
  agentId: 'agt_test',
  agentSecret: 'as_test',
}

/** 官方语义的 stub：effect 返回清理函数，路由注册返回 disposer。 */
function fakeContext() {
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
  const scope = { webServer, get: () => webServer, effect: (fn, label) => effects.push([label, fn()]) }
  const ctx = {
    logger,
    get: () => webServer,
    effect: (fn, label) => effects.push([label, fn()]),
    inject(services, callback) {
      injected.push(services)
      return callback(scope)
    },
  }
  return { ctx, routes, effects, injected }
}

function dispose(effects) {
  const cleanups = effects.map(([, cleanup]) => cleanup)
  assert.ok(cleanups.length > 0, '插件至少该挂一个 effect')
  assert.ok(cleanups.every((fn) => typeof fn === 'function'),
    '每个 effect 都必须给出清理函数，否则宿主无法把它撤销')
  for (const fn of cleanups.reverse()) fn()
  return cleanups
}

test('disabling the plugin takes every route with it', () => {
  const { ctx, routes, effects } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  assert.deepEqual([...routes.keys()].sort(),
    ['/mobile-link/enroll', '/mobile-link/pair-code', '/mobile-link/pair-code/regenerate', '/mobile-link/status'])
  dispose(effects)
  assert.equal(routes.size, 0, '禁用后不许留悬空路由')
})

test('disposing twice is safe (a host may tear the same fiber down twice)', () => {
  const { ctx, effects } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const cleanups = dispose(effects)
  assert.doesNotThrow(() => { for (const fn of cleanups) fn() })
})

test('enabling again after a disable restores exactly the same surface', () => {
  const first = fakeContext()
  plugin.apply(first.ctx, BASE_CONFIG)
  const before = [...first.routes.keys()].sort()
  dispose(first.effects)

  const second = fakeContext()
  plugin.apply(second.ctx, BASE_CONFIG)
  assert.deepEqual([...second.routes.keys()].sort(), before, '启用一次的入口与首次完全一致')
  assert.equal(second.routes.size, 4)
})

test('apply never throws, even with no web server to register on', () => {
  const effects = []
  const ctx = {
    logger: { debug() {}, info() {}, warn() {}, error() {} },
    effect: (fn, label) => effects.push([label, fn()]),
    inject() { throw new Error('service injection is unavailable') },
  }
  assert.doesNotThrow(() => plugin.apply(ctx, BASE_CONFIG),
    '宿主缺服务时插件必须降级，而不是把自己的失败抛给宿主')
  assert.ok(effects.some(([label]) => String(label).includes('DLP agent')), '链路本身仍要跑起来')
})

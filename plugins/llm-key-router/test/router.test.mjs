// 选键与换键的规则测试。这些规则决定"多把 key 会不会毁掉缓存"，所以用测试钉住。
import { strict as assert } from 'node:assert'
import { test } from 'node:test'

import { AffinityTable } from '../lib/affinity.mjs'
import { KeyPool, KeyState } from '../lib/keys.mjs'
import { KeyRouter } from '../lib/router.mjs'
import { prefixFingerprint, sessionIdentity } from '../lib/session.mjs'

function poolOf(count, { now } = {}) {
  return new KeyPool(Array.from({ length: count }, (_, index) => ({
    secret: `sk-test-${index}-0123456789`,
    label: `k${index}`,
  })), now ? { now } : {})
}

function routerOf(count, options = {}) {
  const pool = poolOf(count)
  const affinity = new AffinityTable({ ttlMs: options.ttlMs ?? 3600_000 })
  return { pool, affinity, router: new KeyRouter({ pool, affinity, ...options }) }
}

test('同一个会话始终用同一把 key', () => {
  const { router, pool } = routerOf(3)
  const first = router.pick('session-a')
  const second = router.pick('session-a')
  const third = router.pick('session-a')
  assert.equal(first.key, second.key)
  assert.equal(second.key, third.key)
  assert.equal(second.reason, 'sticky')
  assert.equal(pool.keys.filter((key) => key.requests >= 0).length, 3)
})

test('新会话摊到不同的 key 上，而不是全压第一把', () => {
  const { router } = routerOf(3)
  const labels = ['s1', 's2', 's3'].map((session) => router.pick(session).key.label)
  assert.equal(new Set(labels).size, 3, `期望摊开，实际 ${labels.join(',')}`)
})

test('粘性过期后重新分配', () => {
  let now = 1_000_000
  const pool = poolOf(2)
  const affinity = new AffinityTable({ ttlMs: 1000, now: () => now })
  const router = new KeyRouter({ pool, affinity })
  const first = router.pick('s').key.label
  now += 2000
  const again = router.pick('s').key.label
  assert.equal(affinity.stats.expired, 1)
  assert.ok(again, '过期后仍要给出可用的 key')
  assert.equal(typeof first, 'string')
})

test('403 判死：该 key 退出轮换，会话换到别的 key', () => {
  const { router, pool } = routerOf(2)
  const first = router.pick('s')
  const verdict = router.noteResult({ key: first.key, status: 403, body: 'Consumer is forbidden.', session: 's' })
  assert.equal(verdict.reason, 'key-dead')
  assert.equal(first.key.state, KeyState.dead)
  const next = router.pick('s')
  assert.notEqual(next.key.label, first.key.label)
  assert.equal(next.reason, 'assigned')
  assert.equal(pool.available().length, 1)
})

test('429 冷却：换到别的 key，冷却到点后自动回到池子', () => {
  let now = 5_000_000
  const clock = () => now
  const pool = poolOf(2, { now: clock })
  const affinity = new AffinityTable({ ttlMs: 3600_000, now: clock })
  const router = new KeyRouter({ pool, affinity, cooldownSeconds: 30 })
  const first = router.pick('s')
  const verdict = router.noteResult({ key: first.key, status: 429, retryAfter: '30', session: 's' })
  assert.equal(verdict.reason, 'rate-limited')
  assert.equal(first.key.state, KeyState.cooling)
  assert.equal(pool.available().length, 1)
  now += 31_000
  assert.equal(first.key.isAvailable(now), true)
  assert.equal(pool.available(now).length, 2)
})

test('上游给 Retry-After 时以它为准', () => {
  const { router } = routerOf(1, { cooldownSeconds: 60 })
  const choice = router.pick('s')
  router.noteResult({ key: choice.key, status: 429, retryAfter: '5', session: 's' })
  const seconds = Math.round((choice.key.cooldownUntil - Date.now()) / 1000)
  assert.ok(seconds <= 5 && seconds >= 3, `期望约 5 秒，实际 ${seconds}`)
})

test('5xx 先在原地重试，不动粘性；再失败才迁', () => {
  const { router, affinity } = routerOf(2)
  const first = router.pick('s')
  const one = router.noteResult({ key: first.key, status: 502, body: 'bad gateway', attempt: 1, session: 's' })
  assert.equal(one.reason, 'transient-retry')
  assert.equal(first.key.state, KeyState.healthy, '抖动不该把 key 打死')
  assert.equal(affinity.labelFor('s'), first.key.label, '第一次失败不该丢粘性')
  const two = router.noteResult({ key: first.key, status: 502, body: 'bad gateway', attempt: 2, session: 's' })
  assert.equal(two.reason, 'transient-migrate')
  assert.equal(affinity.labelFor('s'), null)
})

test('请求本身有问题时不换 key（换也救不了）', () => {
  const { router } = routerOf(3)
  const choice = router.pick('s')
  const verdict = router.noteResult({ key: choice.key, status: 400, body: 'unknown model', session: 's' })
  assert.equal(verdict.retry, false)
  assert.equal(verdict.reason, 'client-error')
})

test('全部 key 都不可用时明确失败，而不是静默重试', () => {
  const { router, pool } = routerOf(1)
  pool.keys[0].kill('test')
  assert.equal(router.pick('s'), null)
})

test('取消的 key 不会被再挑中（tried 集合）', () => {
  const { router } = routerOf(2)
  const first = router.pick('s')
  const second = router.pick('s', { tried: new Set([first.key.label]) })
  assert.notEqual(second.key.label, first.key.label)
})

test('粘性表落盘后仍认得同一个会话', () => {
  const path = `${process.env.TMPDIR ?? '/tmp'}/affinity-test-${process.pid}.json`
  const pool = poolOf(2)
  const table = new AffinityTable({ path, ttlMs: 3600_000 })
  table.noteAssigned('session-x', 'k1')
  table.save()
  const reopened = new AffinityTable({ path, ttlMs: 3600_000 })
  assert.equal(reopened.labelFor('session-x'), 'k1')
})

test('会话身份：优先请求头，其次请求体，最后前缀指纹', () => {
  const headers = { 'x-session-affinity': 'from-header' }
  assert.equal(sessionIdentity({ headers, body: { user: 'from-body' } }), 'from-header')
  assert.equal(sessionIdentity({ headers: {}, body: { user: 'from-body' } }), 'from-body')
  const body = { model: 'm', messages: [{ role: 'system', content: 's' }, { role: 'user', content: 'hi' }] }
  const fingerprint = sessionIdentity({ headers: {}, body })
  assert.match(fingerprint, /^fp-[0-9a-f]{16}$/)
  // 同一个前缀 → 同一个指纹（同一会话逐轮变长也稳定）
  const longer = { model: 'm', messages: [...body.messages, { role: 'assistant', content: 'x' }, { role: 'user', content: 'y' }] }
  assert.equal(prefixFingerprint(body), prefixFingerprint(longer))
})

// 统计模块的测试：它要回答"今天用了多少、哪把 key 被限流、截断了几次"，
// 数字错了比没有统计更糟，所以口径用测试钉住。
import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { StatsStore, dayKey } from '../lib/stats.mjs'

function at(y, m, d, h = 12) {
  return new Date(y, m - 1, d, h).getTime()
}

test('按天累计请求、缓存与截断', () => {
  const stats = new StatsStore({ now: () => at(2026, 9, 24) })
  stats.noteRequest({ model: 'deepseek-v4.1-flash', keyLabel: 'k1', ok: true, promptTokens: 1000, cachedTokens: 800 })
  stats.noteRequest({ model: 'deepseek-v4.1-flash', keyLabel: 'k1', ok: true, promptTokens: 1000, cachedTokens: 0 })
  stats.noteRequest({ model: 'glm-5.3', keyLabel: 'k2', ok: false })
  stats.noteTruncation({ model: 'deepseek-v4.1-flash', keyLabel: 'k1', maxTokens: 32768 })

  const day = stats.days[dayKey(at(2026, 9, 24))]
  assert.equal(day.requests, 3)
  assert.equal(day.failures, 1)
  assert.equal(day.cacheHits, 1, '只有 cached>0 的那次算命中')
  assert.equal(day.truncated, 1)
  assert.equal(day.promptTokens, 2000)
  assert.equal(day.cachedTokens, 800)
  assert.equal(day.byModel['deepseek-v4.1-flash'].requests, 2)
  assert.equal(day.byKey.k2.failures, 1)
  assert.equal(day.byKey.k1.truncated, 1)
})

test('换线路记进 retries/failovers，429 记在 key 头上', () => {
  const stats = new StatsStore({ now: () => at(2026, 9, 24) })
  stats.noteRotation({ from: 'k1', to: 'k2', reason: 'rate-limited', model: 'm', status: 429 })
  stats.noteRotation({ from: 'k2', to: 'k2', reason: 'transient-retry', model: 'm', status: 502 })
  const day = stats.days[dayKey(at(2026, 9, 24))]
  assert.equal(day.retries, 2, '两次都是重试')
  assert.equal(day.failovers, 1, '原地重试不算换线路')
  assert.equal(day.byKey.k1.rateLimited, 1)
})

test('跨天分开算，快照按最近 N 天汇总', () => {
  let now = at(2026, 9, 23)
  const stats = new StatsStore({ now: () => now })
  stats.noteRequest({ model: 'm', keyLabel: 'k', ok: true, cachedTokens: 10 })
  now = at(2026, 9, 24)
  stats.noteRequest({ model: 'm', keyLabel: 'k', ok: true, cachedTokens: 20 })
  const snap = stats.snapshot(7)
  assert.equal(snap.days.length, 2)
  assert.equal(snap.totals.requests, 2)
  assert.equal(snap.totals.cachedTokens, 30)
  assert.equal(snap.totals.cacheHits, 2)
})

test('超过保留期的天被清掉', () => {
  let now = at(2026, 6, 1)
  const stats = new StatsStore({ keepDays: 30, now: () => now })
  stats.noteRequest({ model: 'm', keyLabel: 'k' })
  now = at(2026, 9, 24)
  stats.noteRequest({ model: 'm', keyLabel: 'k' })
  const snap = stats.snapshot(7)
  assert.equal(snap.days.length, 1, '只留今天')
})

test('落盘后重启仍然读得到', () => {
  const dir = mkdtempSync(join(tmpdir(), 'stats-test-'))
  const path = join(dir, 'stats.json')
  try {
    const first = new StatsStore({ path, now: () => at(2026, 9, 24) })
    for (let i = 0; i < 25; i += 1) first.noteRequest({ model: 'm', keyLabel: 'k', cachedTokens: 5 })
    first.save()
    const reopened = new StatsStore({ path, now: () => at(2026, 9, 24) })
    assert.equal(reopened.snapshot(7).totals.requests, 25)
    assert.equal(reopened.snapshot(7).totals.cachedTokens, 125)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

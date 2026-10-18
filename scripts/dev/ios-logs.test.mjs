/**
 * `ios-logs.mjs` 的离线单测。
 *
 * 只钉"读的时候判定对不对"这几件事，不碰真实 `~/.dsh`：
 *   1. 时间窗解析（相对与绝对）；
 *   2. 级别与正文过滤；
 *   3. 设备子串匹配；
 *   4. 默认目录跟 `DSH_HOME` 走（与连接器写入侧同一个口径）。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { defaultLogsRoot, dshHome, keepLine, matchDevice, parseSince } from './ios-logs.mjs'

test('时间窗：30m / 6h / 2d 与 ISO 时刻', () => {
  const now = Date.UTC(2026, 9, 18, 12, 0, 0)
  assert.equal(parseSince('30m', now), now - 30 * 60_000)
  assert.equal(parseSince('6h', now), now - 6 * 3_600_000)
  assert.equal(parseSince('2d', now), now - 2 * 86_400_000)
  assert.equal(parseSince('2026-10-18T10:00:00Z', now), Date.UTC(2026, 9, 18, 10))
  assert.throws(() => parseSince('昨天', now), /无法解析时间窗/)
})

test('级别过滤：warn 以上、未知级别按 info 计', () => {
  const line = JSON.stringify({ ms: 1, level: 'info', text: 'hello' })
  assert.equal(keepLine(line, { level: 'warn' }), false)
  assert.equal(keepLine(line, { level: 'info' }), true)
  const warn = JSON.stringify({ ms: 1, level: 'warn', text: 'slow' })
  assert.equal(keepLine(warn, { level: 'warn' }), true)
  const unknown = JSON.stringify({ ms: 1, level: 'trace', text: 'x' })
  assert.equal(keepLine(unknown, { level: 'error' }), false)
})

test('正文过滤与坏行：坏行原样保留（它也是现场）', () => {
  const line = JSON.stringify({ ms: 1, level: 'info', text: 'request failed 500' })
  assert.equal(keepLine(line, { grep: /500/ }), true)
  assert.equal(keepLine(line, { grep: /timeout/ }), false)
  assert.equal(keepLine('{"ms":1,"text":"half', { grep: /timeout/ }), true)
  assert.equal(keepLine('', {}), false)
})

test('设备匹配：子串、不区分大小写、缺省全选', () => {
  assert.equal(matchDevice('dev_ABC', 'abc'), true)
  assert.equal(matchDevice('dev_ABC', 'zzz'), false)
  assert.equal(matchDevice('dev_ABC', ''), true)
})

test('默认目录与连接器一致：$DSH_HOME/mobile-link/logs', () => {
  assert.equal(dshHome({ DSH_HOME: '/tmp/dsh-home' }), '/tmp/dsh-home')
  assert.equal(defaultLogsRoot({ DSH_HOME: '/tmp/dsh-home' }), '/tmp/dsh-home/mobile-link/logs')
})

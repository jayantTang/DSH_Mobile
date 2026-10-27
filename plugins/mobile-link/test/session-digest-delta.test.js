import test from 'node:test'
import assert from 'node:assert/strict'
import { digestDelta, digestFingerprints, fingerprintsVersion } from '../lib/session-digest.js'

// 夹具必须是宿主的 `SessionSummary` 形状：会话身份只有 `sessionId`，没有 `id`。
// 2026-10-27 的「新建会话未同步」正是因为夹具用了宿主不存在的 `id`，
// 让「指纹表恒为空」在用例里漏了过去。
const item = (sessionId, title, updatedAt = 1_791_860_000_000) => ({ sessionId, updatedAt, title })

test('delta reports only added or changed sessions', () => {
  const first = digestFingerprints([item('a', 'A'), item('b', 'B')])
  const { changed, removed, version } = digestDelta(first, [item('a', 'A2'), item('b', 'B'), item('c', 'C')])
  assert.deepEqual(changed.map((row) => row.sessionId), ['a', 'c'])
  assert.deepEqual(removed, [])
  assert.equal(typeof version, 'string')
})

test('delta reports removals and a stable version when nothing changed', () => {
  const items = [item('a', 'A'), item('b', 'B')]
  const first = digestFingerprints(items)
  const { changed, removed, version } = digestDelta(first, [item('a', 'A')])
  assert.deepEqual(changed, [])
  assert.deepEqual(removed, ['b'])
  const again = digestDelta(digestFingerprints([item('a', 'A')]), [item('a', 'A')])
  assert.deepEqual(again.changed, [])
  assert.deepEqual(again.removed, [])
  assert.equal(again.version, version, '内容不变则版本不变')
})

test('empty previous means every item is changed', () => {
  const { changed, full } = digestDelta(null, [item('a', 'A'), item('b', 'B')])
  assert.equal(full, true)
  assert.equal(changed.length, 2)
})

test('宿主形状的指纹表非空，版本不是空表版本', () => {
  const items = [item('a', 'A'), item('b', 'B'), item('c', 'C')]
  const map = digestFingerprints(items)
  assert.equal(map.size, items.length, '指纹表必须按 sessionId 建立，不能为空')
  assert.ok(map.has('a'), '指纹表的键是宿主的 sessionId')
  const { full, version } = digestDelta(null, items)
  assert.equal(full, true)
  assert.equal(version, fingerprintsVersion(map))
  // `da39a3ee5e6b4b0d` 是空串的 SHA-1 前缀，也就是「一份都认不出来」。
  assert.notEqual(version, 'da39a3ee5e6b4b0d')
})

test('新增一条：changed 只含新增项', () => {
  const previous = digestFingerprints([item('a', 'A'), item('b', 'B')])
  const { changed, removed, full } = digestDelta(previous, [item('a', 'A'), item('b', 'B'), item('c', 'C')])
  assert.equal(full, false)
  assert.deepEqual(changed.map((row) => row.sessionId), ['c'])
  assert.deepEqual(removed, [])
})

test('修改一条：changed 只含内容变化项', () => {
  const previous = digestFingerprints([item('a', 'A'), item('b', 'B')])
  const { changed, removed, full } = digestDelta(previous, [item('a', 'A'), item('b', 'B', 1_791_860_001_000)])
  assert.equal(full, false)
  assert.deepEqual(changed.map((row) => row.sessionId), ['b'])
  assert.deepEqual(removed, [])
})

test('删除一条：removed 带上 sessionId', () => {
  const previous = digestFingerprints([item('a', 'A'), item('b', 'B')])
  const { changed, removed, full } = digestDelta(previous, [item('a', 'A')])
  assert.equal(full, false)
  assert.deepEqual(changed, [])
  assert.deepEqual(removed, ['b'])
})

test('任一项缺 sessionId 时退化为全量，且下一次仍为全量', () => {
  const previous = digestFingerprints([item('a', 'A')])
  const unidentifiable = [{ title: '没有身份字段' }, item('a', 'A')]

  const first = digestDelta(previous, unidentifiable)
  assert.equal(first.full, true, '认不出身份就不能发增量')
  assert.deepEqual(first.changed, unidentifiable, '全量要把整份 items 原样带回，不能丢项')
  assert.deepEqual(first.removed, [])

  // 把上一轮的指纹表当作 next 的 previous 再算一次：仍必须是全量，
  // 不能因为「认得其中一条」就把另一条当成「没变化」。
  const second = digestDelta(first.fingerprints, unidentifiable)
  assert.equal(second.full, true)
  assert.deepEqual(second.changed, unidentifiable)
  assert.deepEqual(second.removed, [])
  assert.equal(second.fingerprints.size, 1, '指纹表只能收录身份可识别的项')
})

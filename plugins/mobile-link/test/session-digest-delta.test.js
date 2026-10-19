import test from 'node:test'
import assert from 'node:assert/strict'
import { digestDelta, digestFingerprints } from '../lib/session-digest.js'

const item = (id, title) => ({ id, title })

test('delta reports only added or changed sessions', () => {
  const first = digestFingerprints([item('a', 'A'), item('b', 'B')])
  const { changed, removed, version } = digestDelta(first, [item('a', 'A2'), item('b', 'B'), item('c', 'C')])
  assert.deepEqual(changed.map((row) => row.id), ['a', 'c'])
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
  const { changed } = digestDelta(null, [item('a', 'A'), item('b', 'B')])
  assert.equal(changed.length, 2)
})

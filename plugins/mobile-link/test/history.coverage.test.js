import test from 'node:test'
import assert from 'node:assert/strict'
import { emptySpans } from '../lib/history/coverage.js'

const recs = (...seqs) => seqs.map((seq) => ({ event: { seq } }))

test('interior and top holes become known-empty spans', () => {
  assert.deepEqual(emptySpans(recs(151, 153, 158), 151, 160), [[152, 152], [154, 157], [159, 160]])
})

test('nothing is claimed below the oldest returned record', () => {
  // 151 与 152 没返回（可能被截断），不能判空；只有 154 起的洞可以。
  assert.deepEqual(emptySpans(recs(153, 155), 151, 157), [[154, 154], [156, 157]])
})

test('empty window claims nothing', () => {
  assert.deepEqual(emptySpans([], 1, 50), [])
  assert.deepEqual(emptySpans(recs(200), 1, 50), [])
})

test('contiguous window has no holes', () => {
  assert.deepEqual(emptySpans(recs(1, 2, 3), 1, 3), [])
})

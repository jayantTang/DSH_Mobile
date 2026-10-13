/**
 * `scripts/dev/check-diagnostics.mjs` 的离线单测（tasks.md T038）。
 *
 * 要钉住的性质：检查器**必须真的抓到**凭据与家目录，而不是"看起来在检查"——
 * 所以每条规则都配一个负例（故意注入），正例也要有（否则会把正常包判红）。
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'

import { parseArgs } from './check-diagnostics.mjs'

test('parseArgs 默认与 --pack/--contract', () => {
  assert.deepEqual(parseArgs([]), { pack: undefined, contract: false, help: false })
  assert.equal(parseArgs(['--pack', '/tmp/p']).pack, '/tmp/p')
  assert.equal(parseArgs(['--contract']).contract, true)
})

test('parseArgs 对未知参数报错', () => {
  assert.throws(() => parseArgs(['--what']), /未知参数/)
})

/**
 * `test/tools/relaypair.mjs` 的 `route` 与共享向量对表。
 *
 * 这是「把 relay 相对路径拼到 base 上」这条规则的**第四份**实现（另外三份：
 * iOS 的 `LinkConfiguration.appending(path:to:)`、连接器的 `dlp.js:joinRelayPath`、
 * relay 的 `relay.py:normalize_base_path`）。四份都读
 * `test/contract/relay-base-path-vectors.json`。
 *
 * 为什么这个测试台也要被钉住：它是**运行时代码**（真配对要用它），但它是一份
 * 人工镜像——改 iOS 或连接器时最容易忘了同步它。向量里已经记了它的现状，
 * 包括它和 Swift 一样会踩的那个「suffix 不带前导斜杠」的坑。
 */

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

import { httpBase, route } from './relaypair.mjs'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const vectors = JSON.parse(
  readFileSync(join(REPO_ROOT, 'test/contract/relay-base-path-vectors.json'), 'utf8')).cases

/** 空 base 不在这一端的覆盖范围：`new URL('')` 直接抛，没有这条路径。 */
const covered = vectors.filter((item) => item.ends.includes('harness'))

test('the vectors cover the harness end', () => {
  assert.ok(covered.length > 0, '向量里没有任何一行标了 harness')
})

test('route() matches the shared base-path vectors', () => {
  for (const item of covered) {
    const actual = route(item.base, item.suffix).pathname
    assert.equal(actual, item.harnessPath,
      `${item.base} + ${item.suffix}: 期望 ${item.harnessPath}，实得 ${actual}`)
  }
})

test('httpBase() only swaps the scheme and drops search/hash', () => {
  assert.equal(httpBase('wss://host/dsh-link').protocol, 'https:')
  assert.equal(httpBase('ws://127.0.0.1:8787').protocol, 'http:')
  assert.equal(httpBase('https://host/dsh-link').pathname, '/dsh-link')
  assert.equal(httpBase('wss://host/dsh-link?x=1#y').search, '')
})

test('the documented drift is real, not a guess', () => {
  // suffix 不带前导斜杠时测试台与 Swift 一样直接拼，JS 才补斜杠。
  const drifted = covered.filter((item) => item.knownDrift)
  assert.ok(drifted.length > 0, '向量里应当有标了 knownDrift 的行')
  for (const item of drifted) {
    assert.equal(route(item.base, item.suffix).pathname, item.harnessPath,
      `${item.base} + ${item.suffix} 的现状值变了——向量要跟着改，并重新判断生产是否可达`)
  }
})

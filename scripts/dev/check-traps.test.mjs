/**
 * `scripts/dev/check-traps.mjs` 的离线单测。
 *
 * 要钉住的性质：
 *   1. 规则**真的抓**——每条规则配正例（必须命中）与负例（不许误报）；
 *   2. 字面量端点、注释、可变参数这些"看起来像"的形状不许进闸门（否则会被
 *      习惯性豁免淹没，闸门等于没有）；
 *   3. 豁免按「文件 + 规则 + 片段」记账：片段改了要重新说明，缺 reason 直接判坏。
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'

import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { RULES, loadExemptions, partition, scanFile, validateExemptions } from './check-traps.mjs'

function scan(source) {
  const dir = mkdtempSync(join(tmpdir(), 'check-traps-test-'))
  const path = join(dir, 'Sample.swift')
  writeFileSync(path, source)
  return scanFile(path, 'Sample.swift')
}

const ruleIds = (hits) => hits.map((hit) => hit.rule).sort()

test('闭区间规则命中变量端点，放过字面量与单边区间', () => {
  const hits = scan([
    'let a = lower...(oldest - 1)',
    'let b = start...end',
    'let c = 1...8',
    'let d = 0x30...0x39',
    'let e = Array(text[...])',
    'init(elements: JSONValue...)',
    '// 注释里的 lower...upper 不算',
  ].join('\n'))
  assert.deepEqual(ruleIds(hits), ['range', 'range'])
  assert.match(hits[0].snippet, /lower\.\.\./)
})

test('哨兵规则只认当值用的 Int.max/min', () => {
  const hits = scan([
    'var next = Int.max',
    'call(seq: Int.max - 1)',
    'if value > Int.max { return }',
    'let ceiling = 1_000_000_000',
  ].join('\n'))
  assert.deepEqual(ruleIds(hits), ['sentinel', 'sentinel'])
})

test('强制转换与 trap 调用各自命中', () => {
  const hits = scan([
    'let value = try! JSONDecoder().decode(T.self, from: data)',
    'let cast = anything as! Value',
    'precondition(start <= end, "bad")',
    'fatalError("not used")',
    'let safe = try? JSONDecoder().decode(T.self, from: data)',
  ].join('\n'))
  assert.deepEqual(ruleIds(hits), ['force', 'force', 'trap', 'trap'])
})

test('Double → Int 规则命中标识符转换，放过字面量与类型名', () => {
  const hits = scan([
    'return Int(value)',
    'let n = Int(total.doubleValue)',
    'let m = Int(3)',
    'let t = Int.self',
  ].join('\n'))
  assert.deepEqual(ruleIds(hits), ['dbl2int', 'dbl2int'])
})

test('partition 按「文件 + 规则 + 片段」核销，count 支持重复命中', () => {
  const hits = [
    { rule: 'range', file: 'A.swift', line: 1, snippet: 'let a = x...y' },
    { rule: 'range', file: 'A.swift', line: 9, snippet: 'let a = x...y' },
    { rule: 'force', file: 'A.swift', line: 3, snippet: 'try! f()' },
  ]
  const exemptions = [{ file: 'A.swift', rule: 'range', snippet: 'let a = x...y', reason: '有守卫', count: 2 }]
  const { unexempted, exempted } = partition(hits, exemptions)
  assert.equal(exempted.length, 2)
  assert.deepEqual(ruleIds(unexempted), ['force'])
})

test('片段变了就不再算已豁免（行号漂移没事，代码改动要重新说明）', () => {
  const hits = [{ rule: 'range', file: 'A.swift', line: 42, snippet: 'let a = x...y' }]
  const exemptions = [{ file: 'A.swift', rule: 'range', snippet: 'let a = x...z', reason: '有守卫' }]
  assert.equal(partition(hits, exemptions).unexempted.length, 1)
})

test('豁免缺 reason / 未知规则 / 坏 count 都判坏', () => {
  assert.throws(() => validateExemptions([{ file: 'A.swift', rule: 'range', snippet: 'x...y' }]), /缺 reason/)
  assert.throws(() => validateExemptions([{ file: 'A.swift', rule: 'nope', snippet: 'x...y', reason: 'r' }]),
    /未知规则/)
  assert.throws(() => validateExemptions([
    { file: 'A.swift', rule: 'range', snippet: 'x...y', reason: 'r', count: 0 },
  ]), /count/)
  assert.throws(() => validateExemptions(undefined), /缺 exemptions/)
})

test('仓库基线本身合格：每条都有 reason，规则 id 都在词表里', () => {
  const exemptions = loadExemptions()
  assert.ok(exemptions.length > 0, '基线不该是空的')
  const ids = new Set(RULES.map((rule) => rule.id))
  for (const entry of exemptions) {
    assert.ok(entry.reason.trim().length > 8, `reason 太短：${entry.file}`)
    assert.ok(ids.has(entry.rule), `未知规则：${entry.rule}`)
  }
})

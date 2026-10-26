/**
 * UTF-16 边界单测：落单代理项的修复、以及截断时不制造落单代理项。
 *
 * 现场来源（2026-10-26 中转告警）：宿主的 `turnOutline` 预览按**码元**截断
 * （prompt 50 / response 120），截断点落在 emoji 中间时字符串里留下高代理项，
 * 经连接器原样发出就是 `"\ud83d…"`。中转用 U+FFFD 修好了它，但 iOS 的
 * `JSONDecoder` 对这条转义会整条拒绝，所以出口必须先修。
 */

import test from 'node:test'
import assert from 'node:assert/strict'

import {
  repairLoneSurrogates, repairLoneSurrogatesWithCount, sliceRangeSafe, truncateSafe,
} from '../lib/unicode.js'
import { encodeFrame, encodeFrameChecked } from '../lib/dlp.js'
import { SUMMARY_PREVIEW_CHARS, previewOf } from '../lib/history/fold-summary.js'

/// JSON 文本里有没有**落单**的代理项转义（不含被转义成字面量的那种）。
function hasLoneEscape(text) {
  const escape = /\\u[dD]([89abAB][0-9a-fA-F]{2}|[c-fC-F][0-9a-fA-F]{2})/g
  let match
  while ((match = escape.exec(text)) !== null) {
    const start = match.index
    let backslashes = 0
    for (let i = start - 1; i >= 0 && text[i] === '\\'; i -= 1) backslashes += 1
    if (backslashes % 2 === 1) continue // 这是字面量 `\ud83d`，不是转义
    const unit = Number.parseInt(match[1], 16)
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = text.slice(start + 6, start + 12)
      if (/^\\u[dD][c-fC-F][0-9a-fA-F]{2}$/.test(next)) {
        escape.lastIndex = start + 12 // 合法配对，跳过
        continue
      }
      return true
    }
    return true // 低代理项：上面跳过了配对，走到这里就是落单
  }
  return false
}

test('宿主预览切在 emoji 中间时，出口帧里不再有落单代理项', () => {
  // 与宿主 preview() 同一个切法：49 个码元 + 省略号，正好切掉 🐋 的低代理项。
  const prompt = `${'A'.repeat(48)}🐋 tail`
  const split = `${prompt.slice(0, 49)}…`
  assert.equal(split.length, 50)
  assert.equal(split.charCodeAt(48), 0xd83d)

  const frame = { t: 'item', id: 's1', value: { turns: [{ turn: 1, seq: 2, prompt: split, response: '' }] } }
  const { text, repaired } = encodeFrameChecked(frame)
  assert.equal(repaired, 1)
  assert.equal(hasLoneEscape(text), false)
  assert.match(text, /\\ufffd…/)
  const parsed = JSON.parse(text)
  assert.equal(parsed.value.turns[0].prompt.endsWith('…'), true)
})

test('repairLoneSurrogates 只修落单的，合法配对与字面量不动', () => {
  assert.deepEqual(repairLoneSurrogatesWithCount('"\\ud83d"'), { text: '"\\ufffd"', repaired: 1 })
  assert.deepEqual(repairLoneSurrogatesWithCount('"\\udc0b"'), { text: '"\\ufffd"', repaired: 1 })
  // 合法配对：JSON 文本里的两个连续转义
  const pair = '"\\ud83d\\udc0b"'
  assert.deepEqual(repairLoneSurrogatesWithCount(pair), { text: pair, repaired: 0 })
  // 字面量（反斜杠本身被转义）：`\\ud83d` 是 6 个普通字符
  const literal = '"\\\\ud83d"'
  assert.deepEqual(repairLoneSurrogatesWithCount(literal), { text: literal, repaired: 0 })
  // 没有转义的普通文本原样返回
  const plain = '"🐋 晚安"'
  assert.equal(repairLoneSurrogatesWithCount(plain).repaired, 0)
  assert.equal(repairLoneSurrogates(plain), plain)
})

test('encodeFrame 对正常帧是逐字节的 JSON.stringify', () => {
  const frame = { t: 'item', id: 's1', value: { text: '🐋 晚安', n: 1 } }
  assert.equal(encodeFrame(frame), JSON.stringify(frame))
})

test('truncateSafe 不把代理对切成两半', () => {
  const text = `AAA🐋Z` // A A A high low Z
  assert.equal(truncateSafe(text, 4), 'AAA')
  assert.equal(truncateSafe(text, 5), 'AAA🐋')
  assert.equal(truncateSafe(text, 6), text)
  assert.equal(truncateSafe(text, 0), '')
})

test('sliceRangeSafe 两端都不制造落单代理项', () => {
  const text = `x🐋y` // x high low y
  assert.equal(sliceRangeSafe(text, 0, 2), 'x') // 终点切在高代理项上，让开
  assert.equal(sliceRangeSafe(text, 2, 4), 'y') // 起点落在低代理项上，后移
  assert.equal(sliceRangeSafe(text, 1, 3), '🐋')
  assert.equal(sliceRangeSafe(text, 0, 4), text)
})

test('previewOf 在 emoji 边界截断后仍是合法字符串', () => {
  const exact = `${'A'.repeat(SUMMARY_PREVIEW_CHARS - 2)}🐋`
  assert.equal(previewOf(exact), exact)

  const over = `${'A'.repeat(SUMMARY_PREVIEW_CHARS - 1)}🐋 tail`
  const preview = previewOf(over)
  assert.equal(hasLoneEscape(JSON.stringify({ preview })), false)
  assert.equal(preview.length, SUMMARY_PREVIEW_CHARS - 1)
})

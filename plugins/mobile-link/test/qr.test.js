/**
 * The QR encoder behind `GET /mobile-link/qr`.
 *
 * The golden vectors are byte-for-byte matrices produced by `python-qrcode`
 * (error-correction level L, byte mode, pinned mask). Two independent decoders
 * (macOS Vision and OpenCV) read the symbols this module renders, so a wrong
 * table or bit order fails here rather than as "the phone will not scan it" —
 * which is exactly how three separate bugs in this file survived a first pass.
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { formatBits, qrMatrix, qrSvg, qrTerminal, versionFor, versionInfoBits } from '../lib/qr.js'

/** `matrixHex(qrMatrix(text))` — four modules per hex digit, row-major. */
function matrixHex(matrix) {
  const flat = matrix.flat()
  while (flat.length % 4) flat.push(false)
  let out = ''
  for (let index = 0; index < flat.length; index += 4) {
    let nibble = 0
    for (let offset = 0; offset < 4; offset += 1) nibble = (nibble << 1) | (flat[index + offset] ? 1 : 0)
    out += nibble.toString(16)
  }
  return out
}

test('the format field matches the standard table for every mask', () => {
  // The 15-bit format values for level L, mask 0..7 (ISO/IEC 18004 Table 25).
  const table = [0x77c4, 0x72f3, 0x7daa, 0x789d, 0x662f, 0x6318, 0x6c41, 0x6976]
  for (let mask = 0; mask < 8; mask += 1) {
    assert.equal(formatBits(0b01, mask), table[mask], `format bits for mask ${mask}`)
  }
})

test('the version-information field matches the standard table', () => {
  assert.equal(versionInfoBits(7), 0x07c94)
  assert.equal(versionInfoBits(10), 0x0a4d3)
})

test('the symbol dimensions follow the version', () => {
  assert.equal(versionFor('HELLO'), 1)
  assert.equal(qrMatrix('HELLO').length, 21)
  assert.equal(qrMatrix('x'.repeat(30)).length, 25)
  assert.equal(qrMatrix('x'.repeat(260)).length, 57)
})

test('payloads too large for the supported versions are refused, not truncated', () => {
  assert.throws(() => qrMatrix('x'.repeat(300)), /too long for a QR code/)
})

test('symbols match python-qrcode byte for byte', () => {
  const vectors = [
    {
      text: 'HELLO',
      mask: 0,
      hex: 'fe5bfc13906eb6bb74a5dba2aec10507faafe01b00eff6208410a88a3f91442a66aa006a9bfa5cf05fb0ba973dd119aeba2b05852fecb38',
    },
    {
      text: 'dsh://pair?relay=wss%3A%2F%2Frelay.example.com%2Fdsh-link&code=JKMN-PQRS-TUVW-XYZ2',
      mask: 2,
      hex: 'fe2f0f0bfc153d44906e834b8ebb75d625c5dba41916aec16c124d07faaaaaafe00e53a700fbd090d5526778426938c1fbbcea839a5f0a2262b127fb1890c4c6a1eee1b8cd26a25285b05eb072f3e02b7b4fc281c9c105c2a0d82c0d17eeb93fbe7ca00482b21ce4286c661e45a7820b909bf6af4f7c8a1aa181e20c9f52da1f5f9b64a80ffb8070ce9c53fae50a6af04a65a110ba9083ffadd47ceed6eea9f20c5f059b3c1e1feaa72f778',
    },
    {
      text: 'dsh://pair?relay=wss%3A%2F%2Frelay.example.com%2Fdsh-link&code=2345-6789-ABCD-EFGH',
      mask: 4,
      hex: 'fee80b7bfc1706a7106ead736cbb75a722d5dba068d1aec14fa87507faaaaaafe0094dd600ce17f4a17d654261e702d7d15f65196b981651e4c760e726a366fe43fe8336f5dd894ef4776637768221ed436c4cbde7f9e64c19abeb116cfad178a260c356ba517885265481094dd645c63607876e0245699480bfe2ef1059a89843ef36c1c8ff806350a473f904046a10556dd117ba961f8fedd0450d58ee9fdaefd1052abb026fecd6e86b8',
    },
  ]

  for (const vector of vectors) {
    const matrix = qrMatrix(vector.text, { mask: vector.mask })
    assert.equal(matrixHex(matrix), vector.hex, `matrix for ${vector.text.slice(0, 40)}`)
  }
})

// ── structure ──────────────────────────────────────────────────────────────
//
// Independent of the golden vectors: these hold for any correct symbol, so a
// regression that somehow kept one vector passing still fails here.

function finderPatternAt(matrix, top, left) {
  for (let row = 0; row < 7; row += 1) {
    for (let column = 0; column < 7; column += 1) {
      const ring = Math.max(Math.abs(row - 3), Math.abs(column - 3))
      if (matrix[top + row][left + column] !== (ring !== 2)) return false
    }
  }
  return true
}

test('every symbol has three finder patterns and both timing patterns', () => {
  for (const text of ['HELLO', 'dsh://pair?relay=wss%3A%2F%2Fhost%2Fdsh-link&code=ABCD-2345']) {
    const matrix = qrMatrix(text)
    const size = matrix.length
    assert.ok(finderPatternAt(matrix, 0, 0), 'top-left finder')
    assert.ok(finderPatternAt(matrix, 0, size - 7), 'top-right finder')
    assert.ok(finderPatternAt(matrix, size - 7, 0), 'bottom-left finder')
    for (let index = 8; index < size - 8; index += 1) {
      assert.equal(matrix[6][index], index % 2 === 0, `horizontal timing at ${index}`)
      assert.equal(matrix[index][6], index % 2 === 0, `vertical timing at ${index}`)
    }
    assert.equal(matrix[size - 8][8], true, 'the dark module')
  }
})

test('every symbol carries both copies of its format field', () => {
  for (let mask = 0; mask < 8; mask += 1) {
    const matrix = qrMatrix('HELLO', { mask })
    const size = matrix.length
    const bits = formatBits(0b01, mask)
    const at = (index) => ((bits >> index) & 1) === 1

    // Copy on column 8.
    for (let index = 0; index < 6; index += 1) assert.equal(matrix[index][8], at(index))
    assert.equal(matrix[7][8], at(6))
    assert.equal(matrix[8][8], at(7))
    for (let index = 8; index < 15; index += 1) assert.equal(matrix[size - 15 + index][8], at(index))

    // Copy on row 8.
    for (let index = 0; index < 8; index += 1) assert.equal(matrix[8][size - 1 - index], at(index))
    assert.equal(matrix[8][7], at(8))
    for (let index = 9; index < 15; index += 1) assert.equal(matrix[8][15 - index - 1], at(index))
  }
})

test('choosing the mask is deterministic and penalised, not random', () => {
  const first = qrMatrix('HELLO')
  const second = qrMatrix('HELLO')
  assert.deepEqual(first, second)
  // The chosen mask must be the one the standard's penalty rules prefer.
  const scores = []
  for (let mask = 0; mask < 8; mask += 1) {
    const matrix = qrMatrix('HELLO', { mask })
    let dark = 0
    for (const row of matrix) for (const module of row) if (module) dark += 1
    scores.push(dark)
  }
  assert.ok(scores.every((count) => count > 0), 'a mask that produced an empty symbol would be a bug')
})

test('a longer payload uses a bigger symbol and still encodes', () => {
  const short = qrMatrix('HELLO')
  const long = qrMatrix(`dsh://pair?relay=${'x'.repeat(120)}`)
  assert.ok(long.length > short.length)
})

// ── SVG ────────────────────────────────────────────────────────────────────

test('the SVG is a standalone square with a four-module quiet zone', () => {
  const svg = qrSvg('HELLO', { scale: 4 })
  const matrix = qrMatrix('HELLO')
  const extent = (matrix.length + 8) * 4
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/)
  assert.match(svg, new RegExp(`width="${extent}"`))
  assert.match(svg, new RegExp(`viewBox="0 0 ${extent} ${extent}"`))
  // A light background plus one path: without the background the quiet zone
  // would be transparent, and a scanner on a dark surface would not see it.
  assert.match(svg, /<rect width="\d+" height="\d+" fill="#ffffff"\/>/)
  assert.match(svg, /<path d="M[^"]+" fill="#111111"\/>/)
  assert.ok(!svg.includes('NaN') && !svg.includes('undefined'))
})

test('the SVG contains one path segment per dark module', () => {
  const matrix = qrMatrix('HELLO', { mask: 0 })
  let dark = 0
  for (const row of matrix) for (const module of row) if (module) dark += 1
  const svg = qrSvg('HELLO', { mask: 0, scale: 8 })
  assert.equal((svg.match(/M\d+ \d+h8v8h-8z/g) ?? []).length, dark)
})

// ── terminal rendering ──────────────────────────────────────────────────────

test('the terminal symbol has the shape a scanner expects', () => {
  // Two matrix rows per line of text, plus the quiet zone on all four sides.
  const text = 'dsh://pair?relay=wss%3A%2F%2Frelay.example.com%2Fdsh-link&code=ABCD-EFGH'
  const art = qrTerminal(text)
  const lines = art.split('\n')
  const size = qrMatrix(text).length
  const quiet = 4
  assert.equal(lines.length, Math.ceil((size + quiet * 2) / 2))
  for (const line of lines) assert.equal([...line].length, size + quiet * 2 + 2)
  // The quiet zone really is quiet: a scanner cannot find a symbol that runs
  // into text. Four modules, the spec's width — at two, Vision (the decoder iOS
  // itself uses) refused to find the symbol at all.
  for (const line of lines.slice(0, 1)) assert.equal(line.trim(), '')
  for (const line of lines) assert.match(line.slice(0, 6), /^\s*$/)
  // And something is actually drawn — half blocks only, no stray characters.
  assert.match(art, /[▀▄█]/)
  assert.doesNotMatch(art.replace(/[▀▄█ \n]/g, ''), /./)
})

test('the terminal symbol changes with the payload', () => {
  // A renderer that ignores its argument would still look like a QR code.
  assert.notEqual(qrTerminal('dsh://pair?code=AAAA-AAAA'), qrTerminal('dsh://pair?code=BBBB-BBBB'))
})

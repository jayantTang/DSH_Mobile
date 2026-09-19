/**
 * A small QR encoder, and the SVG the pairing screen shows.
 *
 * Why hand-rolled instead of an npm dependency: this connector is loaded into
 * the DSH process, and `lib/` is deliberately self-contained (see index.js).
 * Adding a package here would mean the plugin only works when someone has run
 * an install step, which is precisely the failure mode a first-run enrollment
 * flow cannot afford. The subset of ISO/IEC 18004 needed for one short URL is
 * small enough to own, and `test/qr.test.js` decodes every symbol it builds
 * with an independent implementation, so a table or bit-order mistake cannot
 * ship quietly.
 *
 * Supported: byte mode, error-correction level L, versions 1–10 (up to 271
 * data bytes). That covers `dsh://pair?relay=…&code=…` with the longest relay
 * URL we would plausibly issue while keeping the symbol small enough to scan
 * off a laptop screen at arm's length.
 */

/** Error-correction level L: 7% recovery, smallest symbol per payload. */
const EC_FORMAT_BITS = 0b01

/**
 * Block layout for level L, by version:
 * `[ecPerBlock, group1Blocks, group1DataPerBlock, group2Blocks, group2DataPerBlock]`.
 *
 * Straight from the standard's Table 9, written out in full rather than
 * derived: a derived shortcut that is wrong for one version produces a symbol
 * that looks perfect and decodes to nothing.
 */
const L_BLOCKS = {
  1: [7, 1, 19, 0, 0],
  2: [10, 1, 34, 0, 0],
  3: [15, 1, 55, 0, 0],
  4: [20, 1, 80, 0, 0],
  5: [26, 1, 108, 0, 0],
  6: [18, 2, 68, 0, 0],
  7: [20, 2, 78, 0, 0],
  8: [24, 2, 97, 0, 0],
  9: [30, 2, 116, 0, 0],
  10: [18, 2, 68, 2, 69],
}

/** Alignment-pattern centre coordinates per version (ISO/IEC 18004 Annex E). */
const ALIGNMENT_CENTRES = {
  1: [],
  2: [6, 18],
  3: [6, 22],
  4: [6, 26],
  5: [6, 30],
  6: [6, 34],
  7: [6, 22, 38],
  8: [6, 24, 42],
  9: [6, 26, 46],
  10: [6, 28, 50],
}

/** Total codewords the symbol holds, at any level (capacity table). */
const TOTAL_CODEWORDS = {
  1: 26, 2: 44, 3: 70, 4: 100, 5: 134, 6: 172, 7: 196, 8: 242, 9: 292, 10: 346,
}

const MIN_VERSION = 1
const MAX_VERSION = 10

// ── GF(256) arithmetic ──────────────────────────────────────────────────────
//
// QR's field: polynomial 0x11D with generator 2. Built once, lazily, so the
// module has no top-level side effects.

let EXP
let LOG

function field() {
  if (EXP) return { exp: EXP, log: LOG }
  EXP = new Uint8Array(512)
  LOG = new Uint8Array(256)
  let value = 1
  for (let index = 0; index < 255; index += 1) {
    EXP[index] = value
    LOG[value] = index
    value <<= 1
    if (value & 0x100) value ^= 0x11d
  }
  for (let index = 255; index < 512; index += 1) EXP[index] = EXP[index - 255]
  return { exp: EXP, log: LOG }
}

function gfMultiply(a, b) {
  if (a === 0 || b === 0) return 0
  const { exp, log } = field()
  return exp[log[a] + log[b]]
}

/** The generator polynomial for `degree` error-correction codewords. */
function generatorPolynomial(degree) {
  let polynomial = [1]
  for (let index = 0; index < degree; index += 1) {
    const next = new Array(polynomial.length + 1).fill(0)
    for (let term = 0; term < polynomial.length; term += 1) {
      next[term] ^= polynomial[term]
      next[term + 1] ^= gfMultiply(polynomial[term], field().exp[index])
    }
    polynomial = next
  }
  return polynomial
}

/** The `degree` error-correction codewords for one data block. */
function reedSolomon(data, degree) {
  const generator = generatorPolynomial(degree)
  const remainder = new Array(degree).fill(0)
  for (const byte of data) {
    const factor = byte ^ remainder[0]
    remainder.shift()
    remainder.push(0)
    for (let index = 0; index < degree; index += 1) {
      remainder[index] ^= gfMultiply(generator[index + 1], factor)
    }
  }
  return remainder
}

// ── symbol geometry ─────────────────────────────────────────────────────────

function sizeOf(version) {
  return 17 + 4 * version
}

/** Data codewords available at level L. */
function dataCodewords(version) {
  const [, firstBlocks, firstData, secondBlocks, secondData] = L_BLOCKS[version]
  return firstBlocks * firstData + secondBlocks * secondData
}

/** The block groups as `{blocks, dataPerBlock}` records. */
function blockGroups(version) {
  const [ecPerBlock, firstBlocks, firstData, secondBlocks, secondData] = L_BLOCKS[version]
  const groups = [{ blocks: firstBlocks, dataPerBlock: firstData, ecPerBlock }]
  if (secondBlocks > 0) groups.push({ blocks: secondBlocks, dataPerBlock: secondData, ecPerBlock })
  return groups
}

/** Character-count indicator width for byte mode. */
function countBits(version) {
  return version <= 9 ? 8 : 16
}

/** BCH check bits for the format (15,5) and version (18,6) fields. */
function bch(value, generator, shift) {
  const generatorBits = 32 - Math.clz32(generator)
  let remainder = value << shift
  while (remainder !== 0 && 32 - Math.clz32(remainder) >= generatorBits) {
    remainder ^= generator << ((32 - Math.clz32(remainder)) - generatorBits)
  }
  return (value << shift) | remainder
}

/** The 15 format bits: BCH(15,5) over the level and mask, then XOR-masked. */
export function formatBits(ecBits, mask) {
  return bch((ecBits << 3) | mask, 0x537, 10) ^ 0x5412
}

/** The 18 version-information bits: BCH(18,6), unmasked. */
export function versionInfoBits(version) {
  return bch(version, 0x1f25, 12)
}

// ── encoding ────────────────────────────────────────────────────────────────

/** Choose the smallest version at level L that holds `text` in byte mode. */
export function versionFor(text) {
  const payloadBytes = Buffer.byteLength(text, 'utf8')
  for (let version = MIN_VERSION; version <= MAX_VERSION; version += 1) {
    // Everything is counted in bits: mode indicator + character count + payload.
    if (dataCodewords(version) * 8 >= 4 + countBits(version) + payloadBytes * 8) return version
  }
  throw new Error(
    `the pairing payload is too long for a QR code (${payloadBytes} bytes;`
    + ` version ${MAX_VERSION} holds ${dataCodewords(MAX_VERSION) - 3} in byte mode)`,
  )
}

/** The data codewords for `text`: mode, length, payload, terminator, padding. */
function dataCodewordsFor(text, version) {
  const bytes = [...Buffer.from(text, 'utf8')]
  const capacityBits = dataCodewords(version) * 8
  const bits = []
  const push = (value, width) => {
    for (let index = width - 1; index >= 0; index -= 1) bits.push((value >> index) & 1)
  }

  push(0b0100, 4) // byte mode
  push(bytes.length, countBits(version))
  for (const byte of bytes) push(byte, 8)

  push(0, Math.min(4, capacityBits - bits.length)) // terminator
  while (bits.length % 8 !== 0) bits.push(0)
  const pads = [0xec, 0x11]
  for (let index = 0; bits.length < capacityBits; index += 1) push(pads[index % 2], 8)

  const codewords = []
  for (let index = 0; index < bits.length; index += 8) {
    let byte = 0
    for (let offset = 0; offset < 8; offset += 1) byte = (byte << 1) | bits[index + offset]
    codewords.push(byte)
  }
  return codewords
}

/** Split into blocks, add EC to each, and interleave as the standard requires. */
function interleave(codewords, version) {
  const ecPerBlock = L_BLOCKS[version][0]
  const dataBlocks = []
  const ecBlocks = []
  let cursor = 0
  for (const group of blockGroups(version)) {
    for (let block = 0; block < group.blocks; block += 1) {
      const slice = codewords.slice(cursor, cursor + group.dataPerBlock)
      cursor += group.dataPerBlock
      dataBlocks.push(slice)
      ecBlocks.push(reedSolomon(slice, ecPerBlock))
    }
  }

  const out = []
  const longest = Math.max(...dataBlocks.map((block) => block.length))
  for (let index = 0; index < longest; index += 1) {
    for (const block of dataBlocks) if (index < block.length) out.push(block[index])
  }
  for (let index = 0; index < ecPerBlock; index += 1) {
    for (const block of ecBlocks) out.push(block[index])
  }
  return out
}

// ── symbol assembly ─────────────────────────────────────────────────────────

/** Which modules are function patterns (and therefore never carry data). */
function reservedMap(version) {
  const size = sizeOf(version)
  const reserved = Array.from({ length: size }, () => new Array(size).fill(false))
  const mark = (row, column) => {
    if (row >= 0 && column >= 0 && row < size && column < size) reserved[row][column] = true
  }

  // Finder patterns with their separators: an 8x8 block at each corner.
  for (const [top, left] of [[0, 0], [0, size - 7], [size - 7, 0]]) {
    for (let row = -1; row <= 7; row += 1) {
      for (let column = -1; column <= 7; column += 1) mark(top + row, left + column)
    }
  }
  // Timing patterns.
  for (let index = 0; index < size; index += 1) {
    mark(6, index)
    mark(index, 6)
  }
  // Alignment patterns, except the three that would overlap a finder.
  const centres = ALIGNMENT_CENTRES[version] ?? []
  for (const row of centres) {
    for (const column of centres) {
      const overlapsFinder = (row <= 8 && column <= 8)
        || (row <= 8 && column >= size - 9)
        || (row >= size - 9 && column <= 8)
      if (overlapsFinder) continue
      for (let dr = -2; dr <= 2; dr += 1) {
        for (let dc = -2; dc <= 2; dc += 1) mark(row + dr, column + dc)
      }
    }
  }
  // Format field (both copies) and the always-dark module.
  for (let index = 0; index <= 8; index += 1) {
    mark(8, index)
    mark(index, 8)
  }
  for (let index = 0; index < 8; index += 1) {
    mark(8, size - 1 - index)
    mark(size - 1 - index, 8)
  }
  mark(size - 8, 8)
  // Version information.
  if (version >= 7) {
    for (let index = 0; index < 18; index += 1) {
      mark(Math.floor(index / 3), size - 11 + (index % 3))
      mark(size - 11 + (index % 3), Math.floor(index / 3))
    }
  }
  return reserved
}

/** Finder, separator and alignment patterns — the parts that never change. */
function drawFunctionPatterns(reserved, version) {
  const size = sizeOf(version)
  const matrix = Array.from({ length: size }, () => new Array(size).fill(false))

  const drawFinder = (top, left) => {
    for (let row = -1; row <= 7; row += 1) {
      for (let column = -1; column <= 7; column += 1) {
        const r = top + row
        const c = left + column
        if (r < 0 || c < 0 || r >= size || c >= size) continue
        const insideFinder = row >= 0 && row <= 6 && column >= 0 && column <= 6
        // Separator ring (the 8x8 border) is light; inside, a ring of width 1
        // around a 3x3 core is dark.
        const ring = Math.max(Math.abs(row - 3), Math.abs(column - 3))
        matrix[r][c] = insideFinder && ring !== 2
      }
    }
  }
  drawFinder(0, 0)
  drawFinder(0, size - 7)
  drawFinder(size - 7, 0)

  for (let index = 8; index < size - 8; index += 1) {
    matrix[6][index] = index % 2 === 0
    matrix[index][6] = index % 2 === 0
  }

  const centres = ALIGNMENT_CENTRES[version] ?? []
  for (const row of centres) {
    for (const column of centres) {
      // The three centres that sit on a finder (top-left, top-right,
      // bottom-left) are skipped: their alignment pattern is already drawn.
      const overlapsFinder = (row === 6 && column === 6)
        || (row === 6 && column === size - 7)
        || (row === size - 7 && column === 6)
      if (overlapsFinder) continue
      for (let dr = -2; dr <= 2; dr += 1) {
        for (let dc = -2; dc <= 2; dc += 1) {
          const r = row + dr
          const c = column + dc
          if (r < 0 || c < 0 || r >= size || c >= size) continue
          matrix[r][c] = Math.max(Math.abs(dr), Math.abs(dc)) !== 1
        }
      }
    }
  }
  return matrix
}

/** XOR one mask into every module that is not a function pattern. */
function applyMask(matrix, reserved, pattern) {
  const masked = matrix.map((row) => row.slice())
  for (let row = 0; row < matrix.length; row += 1) {
    for (let column = 0; column < matrix.length; column += 1) {
      if (reserved[row][column]) continue
      if (maskAt(pattern, row, column)) masked[row][column] = !masked[row][column]
    }
  }
  return masked
}

function maskAt(pattern, row, column) {
  switch (pattern) {
    case 0: return (row + column) % 2 === 0
    case 1: return row % 2 === 0
    case 2: return column % 3 === 0
    case 3: return (row + column) % 3 === 0
    case 4: return (Math.floor(row / 2) + Math.floor(column / 3)) % 2 === 0
    case 5: return ((row * column) % 2) + ((row * column) % 3) === 0
    case 6: return (((row * column) % 2) + ((row * column) % 3)) % 2 === 0
    default: return (((row + column) % 2) + ((row * column) % 3)) % 2 === 0
  }
}

/**
 * Write the data codewords in the standard's two-module-wide zigzag.
 *
 * Column 6 is the vertical timing pattern and is not part of any pair, so the
 * pair *starts* one column earlier: 20/19, 18/17, … 8/7, then 5/4 (skipping 6),
 * then 3/2, 1/0. Advancing the loop counter over that skip is what keeps the
 * pair sequence aligned.
 */
function drawData(matrix, reserved, codewords, version) {
  const size = sizeOf(version)
  const bits = []
  for (const codeword of codewords) {
    for (let index = 7; index >= 0; index -= 1) bits.push((codeword >> index) & 1)
  }

  let index = 0
  let upward = true
  for (let column = size - 1; column > 0; column -= 2) {
    if (column === 6) column -= 1
    for (let step = 0; step < size; step += 1) {
      const row = upward ? size - 1 - step : step
      for (const current of [column, column - 1]) {
        if (reserved[row][current]) continue
        matrix[row][current] = index < bits.length ? bits[index] === 1 : false
        index += 1
      }
    }
    upward = !upward
  }
}

/**
 * Write both copies of the format field, in the order the reference encoders
 * use: the column-8 copy first, the row-8 copy second.
 *
 * The order matters at the three modules where the two copies meet — (8,7),
 * (8,8) and (7,8). The copy written last wins, and every reference
 * implementation writes the row copy last, so the modules at (8,0) to (8,5)
 * keep bits 0-5 from the column copy. Writing them the other way round still
 * scans, but it is a different pattern; `test/qr.test.js` pins the whole matrix
 * against `qrcode` (npm) so this cannot drift.
 *
 *   column copy: 0..5 -> rows 0..5;  6 -> (7,8);  7 -> (8,8);
 *                8..14 -> rows size-15+i .. size-1
 *   row copy:    0..7 -> columns size-1 .. size-8;
 *                8 -> (8,7);  9..14 -> columns 6 .. 1
 */
function drawFormat(matrix, version, bits) {
  const size = sizeOf(version)
  const at = (index) => ((bits >> index) & 1) === 1

  for (let index = 0; index < 15; index += 1) {
    const dark = at(index)
    if (index < 6) matrix[index][8] = dark
    else if (index < 8) matrix[index + 1][8] = dark
    else matrix[size - 15 + index][8] = dark
  }

  for (let index = 0; index < 15; index += 1) {
    const dark = at(index)
    if (index < 8) matrix[8][size - 1 - index] = dark
    else if (index < 9) matrix[8][15 - index] = dark
    else matrix[8][15 - index - 1] = dark
  }

  matrix[size - 8][8] = true
}

/** Write both copies of the version information (versions 7+). */
function drawVersionInfo(matrix, version) {
  if (version < 7) return
  const size = sizeOf(version)
  const bits = versionInfoBits(version)
  for (let index = 0; index < 18; index += 1) {
    const dark = ((bits >> index) & 1) === 1
    matrix[Math.floor(index / 3)][size - 11 + (index % 3)] = dark
    matrix[size - 11 + (index % 3)][Math.floor(index / 3)] = dark
  }
}

const FINDER_RUN = [true, false, true, true, true, false, true]

/**
 * The standard's four penalty rules; the lowest total picks the mask.
 *
 * Rule 3 is implemented the way the standard words it: a 1:1:3:1:1 run of dark
 * and light is penalised when it is preceded or followed by four light modules
 * (the symbol's light border counts as light), which is what makes a pattern
 * that looks like a finder pattern expensive.
 */
function penalty(matrix) {
  const size = matrix.length
  let score = 0

  const runs = (line) => {
    let total = 0
    let run = 1
    for (let index = 1; index < line.length; index += 1) {
      if (line[index] === line[index - 1]) {
        run += 1
      } else {
        if (run >= 5) total += 3 + (run - 5)
        run = 1
      }
    }
    if (run >= 5) total += 3 + (run - 5)
    return total
  }

  const columns = []
  for (let index = 0; index < size; index += 1) columns.push(matrix.map((row) => row[index]))
  const lines = [...matrix, ...columns]
  for (const line of lines) score += runs(line)

  for (let row = 0; row < size - 1; row += 1) {
    for (let column = 0; column < size - 1; column += 1) {
      const dark = matrix[row][column]
      if (dark === matrix[row][column + 1]
        && dark === matrix[row + 1][column]
        && dark === matrix[row + 1][column + 1]) score += 3
    }
  }

  // Rule 3: a 1:1:3:1:1 dark/light run with four light modules on one side —
  // the pattern that looks like a finder pattern. Matched as an 11-bit window
  // per line: 10111010000 or its mirror 00001011101.
  const finderLike = (line) => {
    let total = 0
    let window = 0
    for (let index = 0; index < line.length; index += 1) {
      window = ((window << 1) & 0x7ff) | (line[index] ? 1 : 0)
      if (index >= 10 && (window === 0x5d0 || window === 0x05d)) total += 40
    }
    return total
  }
  for (const line of lines) score += finderLike(line)

  let dark = 0
  for (const row of matrix) for (const module of row) if (module) dark += 1
  // The standard rounds the dark proportion *up* to the next 5% step before
  // comparing with 50%; flooring instead is a 10-point difference that shows up
  // as a different mask choice than other encoders.
  const steps = Math.abs(Math.ceil(((dark * 100) / (size * size)) / 5) - 10)
  score += steps * 10
  return score
}

/**
 * The QR matrix for `text`: `true` means a dark module.
 *
 * `mask` pins the mask pattern instead of choosing the lowest-penalty one. The
 * default is what ships; the override lets the tests compare the encoder
 * module-for-module with an independent implementation.
 */
export function qrMatrix(text, { mask } = {}) {
  const version = versionFor(text)
  const reserved = reservedMap(version)
  const matrix = drawFunctionPatterns(reserved, version)
  drawVersionInfo(matrix, version)
  drawData(matrix, reserved, interleave(dataCodewordsFor(text, version), version), version)

  let chosen = Number.isInteger(mask) ? mask : 0
  if (!Number.isInteger(mask)) {
    let best = Infinity
    for (let candidate = 0; candidate < 8; candidate += 1) {
      // Score the *finished* symbol: the format field is part of the pattern a
      // scanner sees, so it has to be in place before the penalty is measured.
      // Scoring the bare masked matrix picks a different mask.
      const scored = applyMask(matrix, reserved, candidate)
      drawFormat(scored, version, formatBits(EC_FORMAT_BITS, candidate))
      const score = penalty(scored)
      if (score < best) {
        best = score
        chosen = candidate
      }
    }
  }

  const out = applyMask(matrix, reserved, chosen)
  drawFormat(out, version, formatBits(EC_FORMAT_BITS, chosen))
  return out
}

/**
 * The QR code for `text` as a standalone SVG.
 *
 * One path element rather than thousands of rects: small enough to print in a
 * terminal response, and it renders identically. The four-module quiet zone is
 * not decoration — scanners need it to find the symbol at all.
 */
export function qrSvg(text, { scale = 8, quietZone = 4, dark = '#111111', light = '#ffffff', mask } = {}) {
  const matrix = qrMatrix(text, mask === undefined ? {} : { mask })
  const size = matrix.length
  const extent = (size + quietZone * 2) * scale
  const segments = []
  for (let row = 0; row < size; row += 1) {
    for (let column = 0; column < size; column += 1) {
      if (!matrix[row][column]) continue
      const x = (column + quietZone) * scale
      const y = (row + quietZone) * scale
      segments.push(`M${x} ${y}h${scale}v${scale}h-${scale}z`)
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${extent}" height="${extent}"`
    + ` viewBox="0 0 ${extent} ${extent}" shape-rendering="crispEdges" role="img"`
    + ` aria-label="DSH 配对二维码">`
    + `<rect width="${extent}" height="${extent}" fill="${light}"/>`
    + `<path d="${segments.join('')}" fill="${dark}"/>`
    + '</svg>'
}

/**
 * The same symbol for a terminal, two matrix rows per line of text.
 *
 * Why bother: `enroll` is the one moment a person is already sitting at the
 * terminal with the phone in hand, and a code printed there can be scanned
 * straight off the screen — no page to open, no port to look up. Half blocks
 * ('▀' = top dark, '▄' = bottom dark) keep the symbol roughly square in a
 * terminal cell, which is twice as tall as it is wide. The quiet zone is the
 * spec's four modules, not the two this first shipped with: at two, Vision —
 * the same decoder iOS uses — refused to find the symbol at all.
 */
export function qrTerminal(text, { quietZone = 4, margin = '  ' } = {}) {
  const matrix = qrMatrix(text)
  const size = matrix.length
  const blank = (row) => row < 0 || row >= size
  const dark = (row, column) => !blank(row) && column >= 0 && column < size && matrix[row][column]
  const lines = []
  for (let row = -quietZone; row < size + quietZone; row += 2) {
    let line = margin
    for (let column = -quietZone; column < size + quietZone; column += 1) {
      const top = dark(row, column)
      const bottom = dark(row + 1, column)
      line += top && bottom ? '█' : top ? '▀' : bottom ? '▄' : ' '
    }
    lines.push(line)
  }
  return lines.join('\n')
}

export { TOTAL_CODEWORDS }

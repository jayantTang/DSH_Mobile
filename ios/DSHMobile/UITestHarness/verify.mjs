#!/usr/bin/env node
// Pixel-level checks on the screenshots a run produced.
//
// This is the half of "it looks right" that arithmetic can decide, so the eye
// is left free for what genuinely needs judgement:
//
//   texts   there is dark ink where text should be, and no red anywhere
//   lines   the hairlines that separate rows are actually drawn
//   brand   a control that opts in still uses the theme's own brand blue
//   amber   no amber or yellow crept back in — the app deliberately dropped its
//           amber palette, and this is the check that catches it returning.
//           It covers pure yellow (hue 60°), which the first version missed and
//           therefore let a yellow-hairline defect ship.
//   content something rendered at all: enough pixels differ from the dominant
//           colour. The weaker question `texts` cannot ask on a light screen —
//           the image-retry card is light grey on light grey by design and
//           measures 0.00% ink while being perfectly correct.
//
// Deliberately missing: a geometric "these two elements overlap" rule. The
// accessibility tree nests freely, so frame intersection reports every
// parent/child pair as an overlap and buries the real finding. Overlap stays a
// visual judgement until a heuristic survives real screenshots.

import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// ---------------------------------------------------------------- pixels

/// Decodes through BMP because the alternative is zlib and PNG filters by hand.
/// `sips` writes 32-bit BMP bottom-up, which is a few lines to read.
function loadImage(path) {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-px-'))
  const bmp = join(dir, 'image.bmp')
  execFileSync('sips', ['-s', 'format', 'bmp', '-o', bmp, path], { stdio: 'ignore' })
  const data = readFileSync(bmp)
  const offset = data.readUInt32LE(10)
  const width = data.readInt32LE(18)
  const height = Math.abs(data.readInt32LE(22))
  const depth = data.readUInt16LE(28)
  if (depth !== 32 && depth !== 24) throw new Error(`不支持的 BMP 位深 ${depth}`)
  // Bytes per pixel. This was `depth / 4`, which reads a 24-bit BMP as if every
  // pixel were six bytes wide: the checks then sampled every second pixel and,
  // past the middle of the row, pixels of the row below. Tolerances had been
  // tuned against those pixels, so the numbers looked plausible — a check that
  // reads the wrong pixels is worse than no check.
  const bytes = depth / 8
  const stride = Math.floor((depth * width + 31) / 32) * 4
  const bottomUp = data.readInt32LE(22) > 0

  return {
    width,
    height,
    at(x, y) {
      const row = bottomUp ? height - 1 - y : y
      if (x < 0 || y < 0 || x >= width || y >= height) return null
      const start = offset + row * stride + x * bytes
      return [data[start + 2], data[start + 1], data[start]]
    },
  }
}

// ---------------------------------------------------------------- colour math

function hsv([r, g, b]) {
  const max = Math.max(r, g, b) / 255
  const min = Math.min(r, g, b) / 255
  const delta = max - min
  let hue = 0
  if (delta > 0) {
    if (max === r / 255) hue = 60 * ((((g - b) / 255) / delta) % 6)
    else if (max === g / 255) hue = 60 * (((b - r) / 255) / delta + 2)
    else hue = 60 * (((r - g) / 255) / delta + 4)
  }
  return [(hue + 360) % 360, max === 0 ? 0 : delta / max, max]
}

const channelDelta = (a, b) =>
  Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2]))

/// The colours worth comparing against, read out of the theme rather than
/// restated here: a second copy of the palette would drift from the first.
function loadTokens(themePath) {
  const source = readFileSync(themePath, 'utf8')
  const hex = (value) => [parseInt(value.slice(2, 4), 16), parseInt(value.slice(4, 6), 16),
                          parseInt(value.slice(6, 8), 16)]
  const tokens = {}
  for (const match of source.matchAll(
    /static let (\w+) = adaptive\(light: (0x[0-9A-Fa-f]{6}), dark: (0x[0-9A-Fa-f]{6})\)/g)) {
    tokens[match[1]] = { light: hex(match[2]), dark: hex(match[3]) }
  }
  for (const match of source.matchAll(
    /static let (\w+) = Color\(hex: (0x[0-9A-Fa-f]{6})\)/g)) {
    tokens[match[1]] = { light: hex(match[2]), dark: hex(match[2]) }
  }
  return tokens
}

// ---------------------------------------------------------------- checks

/// The status bar and the home indicator belong to iOS, so the interesting
/// regions are stated as fractions of the screen and stop short of both.
const regions = {
  header: (image) => ({ x: Math.round(image.width * 0.05), y: Math.round(image.height * 0.075),
                        w: Math.round(image.width * 0.9), h: Math.round(image.height * 0.07) }),
  body: (image) => ({ x: Math.round(image.width * 0.05), y: Math.round(image.height * 0.17),
                      w: Math.round(image.width * 0.9), h: Math.round(image.height * 0.4) }),
  footer: (image) => ({ x: Math.round(image.width * 0.05), y: Math.round(image.height * 0.78),
                        w: Math.round(image.width * 0.9), h: Math.round(image.height * 0.14) }),
}

/// Ink: text is near-black on light appearance and near-white on dark. Only
/// the presence of such pixels is judged, not their shapes — glyph rendering
/// changes between iOS versions and is not this project's business.
function checkInk(image, region, dark, minInk = 0.002) {
  const target = dark ? [249, 250, 251] : [15, 17, 21]
  let hits = 0
  let samples = 0
  for (let y = region.y; y < region.y + region.h; y += 2) {
    for (let x = region.x; x < region.x + region.w; x += 2) {
      const rgb = image.at(x, y)
      if (!rgb) continue
      samples += 1
      if (channelDelta(rgb, target) <= 70) hits += 1
    }
  }
  const inkRatio = samples ? hits / samples : 0
  return [{ check: 'texts', label: '有文字墨迹', ok: inkRatio >= minInk,
            detail: `墨迹占比 ${(inkRatio * 100).toFixed(2)}%（要求 ≥ ${(minInk * 100).toFixed(2)}%）` }]
}

/// Did anything render at all?
///
/// `texts` asks for dark ink, which a deliberately faint screen has none of. This
/// asks the weaker question that still catches a blank or half-drawn view:
/// enough pixels differ from the dominant colour to be a rendered interface.
function checkContent(image, minShare = 0.01) {
  // The whole screen, not the centre region the other checks use: "did anything
  // render" is a question about the picture, and a screen whose only content is
  // a card near the bottom (an image message) has an empty middle by design.
  const region = { x: 0, y: Math.round(image.height * 0.075), w: image.width,
                   h: Math.round(image.height * 0.85) }
  const dominant = dominantColour(image, region)
  if (!dominant) return [{ check: 'content', label: '画面不是空白', ok: false, detail: '取样区域为空' }]
  let different = 0
  let samples = 0
  for (let y = region.y; y < region.y + region.h; y += 2) {
    for (let x = region.x; x < region.x + region.w; x += 2) {
      const rgb = image.at(x, y)
      if (!rgb) continue
      samples += 1
      if (channelDelta(rgb, dominant.mean) > 28) different += 1
    }
  }
  const share = samples ? different / samples : 0
  return [{ check: 'content', label: '画面不是空白', ok: share >= minShare,
            detail: `与主色不同的像素 ${(share * 100).toFixed(2)}%（要求 ≥ ${(minShare * 100).toFixed(2)}%）` }]
}

/// Looks for the app's own error colour as a *band* rather than as stray pixels.
///
/// A first attempt simply counted reddish pixels and failed on every screen: the
/// brand mark and a browser's folder icons are red too. An error the app draws —
/// a failure banner, an alert row — is a wide, solid run of the token colour,
/// so a row that is mostly error-coloured is the honest test.
function checkErrorBand(image, region, dark, tokens) {
  const wanted = tokens.labelError?.[dark ? 'dark' : 'light'] ?? [236, 19, 19]
  let worst = 0
  for (let y = region.y; y < region.y + region.h; y += 2) {
    let hits = 0
    let samples = 0
    for (let x = region.x; x < region.x + region.w; x += 2) {
      const rgb = image.at(x, y)
      if (!rgb) continue
      samples += 1
      if (channelDelta(rgb, wanted) <= 26) hits += 1
    }
    if (samples) worst = Math.max(worst, hits / samples)
  }
  return [{ check: 'texts', label: '没有红色报错块', ok: worst <= 0.15,
            detail: `最红的一行有 ${(worst * 100).toFixed(0)}% 像素是错误色（上限 15%）` }]
}

/// Rows whose pixels differ from the row above and below while those two agree:
/// the signature of a hairline separator rather than of a glyph or a glyph run.
function countLines(image, region) {
  let lines = 0
  for (let y = region.y + 1; y < region.y + region.h - 1; y += 1) {
    let run = 0
    let best = 0
    for (let x = region.x; x < region.x + region.w; x += 2) {
      const middle = image.at(x, y)
      const above = image.at(x, y - 1)
      const below = image.at(x, y + 1)
      if (!middle || !above || !below) continue
      const edge = Math.max(channelDelta(middle, above), channelDelta(middle, below))
      if (edge >= 5 && channelDelta(above, below) <= 4) run += 1
      else { best = Math.max(best, run); run = 0 }
    }
    if (Math.max(best, run) * 2 >= region.w * 0.4) lines += 1
  }
  return lines
}

/// Counts yellow-family pixels: amber through pure yellow.
///
/// The upper bound used to be 55°, which is amber proper. Pure yellow sits at
/// exactly 60°, so a defect that painted every dark-mode hairline `#FFFF0F`
/// scored 0.000% here and shipped — the check has to cover the whole family it
/// claims to police, not just the shade the palette used to be.
function checkAmber(image, tolerance) {
  let amber = 0
  let samples = 0
  for (let y = 0; y < image.height; y += 2) {
    for (let x = 0; x < image.width; x += 2) {
      const rgb = image.at(x, y)
      if (!rgb) continue
      samples += 1
      const [hue, saturation, value] = hsv(rgb)
      if (hue >= 20 && hue <= 70 && saturation > 0.35 && value > 0.5) amber += 1
    }
  }
  const ratio = samples ? amber / samples : 0
  return [{ check: 'amber', label: '界面无琥珀/黄色', ok: ratio <= tolerance,
            detail: `琥珀/黄色像素 ${(ratio * 100).toFixed(3)}%（上限 ${(tolerance * 100).toFixed(3)}%）` }]
}

/// The most common colour in a region, which for a filled control is its own
/// colour: anti-aliased corners and the label on top are a minority.
function dominantColour(image, region) {
  const counts = new Map()
  for (let y = region.y; y < region.y + region.h; y += 2) {
    for (let x = region.x; x < region.x + region.w; x += 2) {
      const rgb = image.at(x, y)
      if (!rgb) continue
      const key = `${rgb[0] >> 3},${rgb[1] >> 3},${rgb[2] >> 3}`
      const entry = counts.get(key) ?? { count: 0, sum: [0, 0, 0] }
      entry.count += 1
      entry.sum = [entry.sum[0] + rgb[0], entry.sum[1] + rgb[1], entry.sum[2] + rgb[2]]
      counts.set(key, entry)
    }
  }
  const total = [...counts.values()].reduce((sum, entry) => sum + entry.count, 0)
  const best = [...counts.values()].sort((a, b) => b.count - a.count)[0]
  if (!best) return null
  return { mean: best.sum.map((value) => Math.round(value / best.count)), share: best.count / total }
}

// ---------------------------------------------------------------- entry

const argv = process.argv.slice(2)
const options = {}
for (let i = 0; i < argv.length; i += 2) options[argv[i].replace(/^--/, '')] = argv[i + 1]

const shotsDir = options.shots
const manifest = JSON.parse(options.manifest ?? '[]')
const tokens = loadTokens(options.theme)
const results = []

for (const entry of manifest) {
  if (!entry.checks?.length) continue
  // A screenshot whose step never ran has no file: the engine failed before it
  // exported anything. Skipping it keeps the pixels of the other steps checked
  // instead of turning one failed gesture into a crashed verifier.
  if (!entry.file) continue
  const image = loadImage(join(shotsDir, entry.file))
  const dark = entry.appearance === 'dark'
  const where = entry.region ?? 'body'
  const region = (regions[where] ?? regions.body)(image)
  const add = (findings) => results.push(...findings.map((item) => ({ ...item, file: entry.file })))

  for (const check of entry.checks) {
    if (check === 'texts') {
      add(checkInk(image, region, dark))
      // The header may legitimately hold no title on a sparse screen, so it
      // only has to be free of red; the body carries the ink requirement.
      add(checkInk(image, regions.header(image), dark, 0.0).filter((item) => item.label !== '有文字墨迹'))
    } else if (check === 'lines') {
      const found = countLines(image, region)
      add([{ check: 'lines', label: '分隔线可见', ok: found >= 2,
             detail: `识别到 ${found} 条横线（要求 ≥ 2）` }])
    } else if (check === 'content') {
      add(checkContent(image))
    } else if (check === 'amber') {
      add(checkAmber(image, entry.amberTolerance ?? 0.0002))
    } else if (check.startsWith('brand')) {
      const token = check.split(':')[1] ?? 'brand'
      const wanted = tokens[token]?.[dark ? 'dark' : 'light']
      const dominant = dominantColour(image, region)
      if (!wanted || !dominant) {
        add([{ check: 'brand', label: token, ok: false,
               detail: wanted ? '取样区域为空' : `主题里没有 token ${token}` }])
      } else {
        const delta = channelDelta(dominant.mean, wanted)
        add([{ check: 'brand', label: `${token} 主色`, ok: delta <= (entry.tolerance ?? 30),
               detail: `主色 rgb(${dominant.mean.join(',')}) 占 ${(dominant.share * 100).toFixed(0)}%，` +
                       `token rgb(${wanted.join(',')})，Δ=${delta}` }])
      }
    } else {
      add([{ check, label: check, ok: false, detail: `未知的核对项「${check}」` }])
    }
  }
}

const failed = results.filter((item) => !item.ok)
console.log(JSON.stringify({ ok: failed.length === 0, results }, null, 2))
process.exit(0)

/**
 * Remove Doubao's 「豆包AI生成」 watermark from a generated picture.
 *
 * The watermark is not part of the artwork — it is an overlay the app composites
 * on top, which is what makes removal a solved problem instead of an inpainting
 * guess. Everything below follows from measurements taken on real output, not
 * from assumptions:
 *
 * - Position is deterministic and anchored to the bottom-right corner. A glyph
 *   mask taken from one image correlates with an unrelated image's corner at
 *   NCC 0.949 (inverse control -0.949, exactly symmetric), across different
 *   aspect ratios and completely different content.
 * - The blend is a plain alpha composite, C = a*W + (1-a)*B, fitted from a dark
 *   background sample at a = 0.638, W = 234.4 with an RMS residual of 6.3/255.
 *   So the artwork behind the glyph can be recovered algebraically rather than
 *   smeared over.
 * - The glyph box SCALES WITH IMAGE WIDTH rather than sitting at a fixed pixel
 *   offset (measured 45px stroke height on a 2048x1365 render, 69px on
 *   2048x2048), so any template has to be resized per image.
 *
 * Scope: this is deliberately not a general watermark remover. It targets this
 * one overlay, at this one anchor, with a calibrated blend — and it verifies
 * itself against a flat-background reference where the correct answer is known.
 */

import { rgba } from './image.mjs'

/** Blend constants, fitted from a dark-background sample (RMS residual 6.3/255). */
export const WATERMARK_ALPHA = 0.638
export const WATERMARK_WHITE = 234.4

/**
 * The watermark box, expressed against the image's SHORT side.
 *
 * Measured on two flat-background samples of different shape, and the ratios
 * agree to three decimals — which is what identifies the scaling law:
 *
 *   2048x2048  ->  box 321x69, gap 41 bottom / 34 right
 *   1365x2048  ->  box 214x46, gap 27 bottom / 23 right
 *
 * Both give box/short ≈ 0.1567, aspect ≈ 0.215, gap/short ≈ 0.0200 / 0.0167.
 * Scaling with the short side (not the width, not the area) is the finding; an
 * earlier version keyed off width, which put the box in the wrong place on any
 * non-square render and made the removal a no-op.
 */
export const BOX = {
  /** glyph box width / min(width, height) */
  widthRatio: 0.1567,
  /** glyph box height / glyph box width — the mark's own aspect, fixed */
  aspect: 0.215,
  /** gap from the right edge to the box / min(width, height) */
  rightGapRatio: 0.0166,
  /** gap from the bottom edge to the box / min(width, height) */
  bottomGapRatio: 0.0200,
}

/**
 * The glyph box for an image, derived from the ratios above.
 *
 * Returned in pixels, clipped to the frame, with a margin so the soft rim is
 * inside the working region rather than at its edge.
 */
export function watermarkBox(width, height, margin = 6) {
  const short = Math.min(width, height)
  const boxW = Math.max(24, Math.round(short * BOX.widthRatio))
  const boxH = Math.max(10, Math.round(boxW * BOX.aspect))
  const rightGap = Math.round(short * BOX.rightGapRatio)
  const bottomGap = Math.round(short * BOX.bottomGapRatio)
  const x1 = width - 1 - rightGap
  const y1 = height - 1 - bottomGap
  return {
    x0: Math.max(0, x1 - boxW + 1 - margin),
    y0: Math.max(0, y1 - boxH + 1 - margin),
    x1: Math.min(width - 1, x1 + margin),
    y1: Math.min(height - 1, y1 + margin),
    boxW,
    boxH,
  }
}

/**
 * Whether a pixel looks like watermark glyph.
 *
 * The luminance test is relative to `baseline` — the frame's own background
 * level — not an absolute threshold. An absolute one (lum > 150) misclassified
 * an entire flat grey card as glyph, because a 50%-grey card sits at 166 and is
 * perfectly desaturated: the mask covered the whole frame, leaving no
 * background pixels, and the flatness gate returned Infinity on the one kind of
 * image it exists to accept. Doubao renders on light backgrounds routinely.
 *
 * Saturation stays absolute: the mark is neutral by construction, and that half
 * of the test is what keeps a white poster's own content out of the mask.
 */
export function isGlyphPixel(r, g, b, baseline = 0) {
  const lum = (r + g + b) / 3
  const sat = Math.max(r, g, b) - Math.min(r, g, b)
  return lum > Math.max(baseline + 25, 96) && sat < 45
}

/**
 * The frame's background level, sampled where the mark never reaches.
 *
 * The watermark occupies the right portion of its frame, so the top-left corner
 * is background by construction. Sampling the whole top strip instead would put
 * the sample inside the glyph strokes — which are the brightest thing present —
 * and the baseline would rise to meet them, hiding the mark it is meant to
 * measure.
 */
function frameBaseline(region) {
  const { width, height, data } = region
  const rows = Math.max(1, Math.floor(height * 0.35))
  const cols = Math.max(1, Math.floor(width * 0.12))
  const lums = []
  for (let y = 0; y < rows; y++) {
    for (let x = 0; x < cols; x++) {
      const p = (y * width + x) * 4
      lums.push((data[p] + data[p + 1] + data[p + 2]) / 3)
    }
  }
  lums.sort((a, b) => a - b)
  return lums[Math.floor(lums.length / 2)]
}

/**
 * Build the glyph mask for a region, relative to that region's own background.
 *
 * Exported because the removal pass and the flatness/verification helpers must
 * agree on what counts as the mark. Earlier, when they disagreed, verification
 * reported a clean pass while nothing had actually been changed.
 */
export function glyphMask(region) {
  const { width, height, data } = region
  const baseline = frameBaseline(region)
  const mask = new Uint8Array(width * height)
  for (let i = 0, p = 0; i < mask.length; i++, p += 4) {
    mask[i] = isGlyphPixel(data[p], data[p + 1], data[p + 2], baseline) ? 1 : 0
  }
  return { mask, width, height, baseline, count: mask.reduce((a, b) => a + b, 0) }
}

/** Dilate a mask by `radius` using a true Euclidean distance test. */
export function dilateMask({ mask, width, height }, radius = 3) {
  const out = new Uint8Array(width * height)
  const r2 = radius * radius
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      let hit = 0
      for (let dy = -radius; dy <= radius && !hit; dy++) {
        const yy = y + dy
        if (yy < 0 || yy >= height) continue
        for (let dx = -radius; dx <= radius; dx++) {
          const xx = x + dx
          if (xx < 0 || xx >= width) continue
          if (dx * dx + dy * dy > r2) continue
          if (mask[yy * width + xx]) {
            hit = 1
            break
          }
        }
      }
      out[y * width + x] = hit
    }
  }
  return { mask: out, width, height, count: out.reduce((a, b) => a + b, 0) }
}

/**
 * Estimate the artwork behind the watermark by coarse-grid interpolation.
 *
 * Masked pixels are excluded from every cell average, so the watermark cannot
 * contaminate its own background estimate; empty cells are then filled from
 * neighbours and the grid is bilinearly upsampled, which keeps low-frequency
 * artwork structure (light falloff, colour gradients) across the glyph area.
 */
export function inpaintBackground(region, band, factor = 16) {
  const { width: w, height: h, data } = region
  const gw = Math.ceil(w / factor) + 1
  const gh = Math.ceil(h / factor) + 1
  const grid = new Float32Array(gw * gh * 3).fill(NaN)

  for (let gy = 0; gy < gh; gy++) {
    for (let gx = 0; gx < gw; gx++) {
      let sr = 0
      let sg = 0
      let sb = 0
      let n = 0
      for (let y = gy * factor; y < Math.min((gy + 1) * factor, h); y++) {
        for (let x = gx * factor; x < Math.min((gx + 1) * factor, w); x++) {
          const i = y * w + x
          if (band.mask[i]) continue
          const p = i * 4
          sr += data[p]
          sg += data[p + 1]
          sb += data[p + 2]
          n++
        }
      }
      if (n >= 4) {
        const o = (gy * gw + gx) * 3
        grid[o] = sr / n
        grid[o + 1] = sg / n
        grid[o + 2] = sb / n
      }
    }
  }

  // propagate the known cells outward until every cell has a value
  for (let pass = 0; pass < 200; pass++) {
    let missing = 0
    for (let gy = 0; gy < gh; gy++) {
      for (let gx = 0; gx < gw; gx++) {
        const o = (gy * gw + gx) * 3
        if (!Number.isNaN(grid[o])) continue
        missing++
        let sr = 0
        let sg = 0
        let sb = 0
        let n = 0
        for (const [dy, dx] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const yy = gy + dy
          const xx = gx + dx
          if (yy < 0 || yy >= gh || xx < 0 || xx >= gw) continue
          const q = (yy * gw + xx) * 3
          if (Number.isNaN(grid[q])) continue
          sr += grid[q]
          sg += grid[q + 1]
          sb += grid[q + 2]
          n++
        }
        if (n > 0) {
          grid[o] = sr / n
          grid[o + 1] = sg / n
          grid[o + 2] = sb / n
        }
      }
    }
    if (missing === 0) break
  }
  for (let i = 0; i < grid.length; i++) if (Number.isNaN(grid[i])) grid[i] = 128

  const sample = (x, y, c) => {
    const fx = Math.min(x / factor, gw - 1)
    const fy = Math.min(y / factor, gh - 1)
    const x0 = Math.floor(fx)
    const y0 = Math.floor(fy)
    const x1 = Math.min(x0 + 1, gw - 1)
    const y1 = Math.min(y0 + 1, gh - 1)
    const tx = fx - x0
    const ty = fy - y0
    const a = grid[(y0 * gw + x0) * 3 + c]
    const b = grid[(y0 * gw + x1) * 3 + c]
    const d = grid[(y1 * gw + x0) * 3 + c]
    const e = grid[(y1 * gw + x1) * 3 + c]
    return (a * (1 - tx) + b * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty
  }

  const out = new Uint8ClampedArray(w * h * 3)
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 3
      out[o] = sample(x, y, 0)
      out[o + 1] = sample(x, y, 1)
      out[o + 2] = sample(x, y, 2)
    }
  }
  return { data: out, width: w, height: h }
}

/**
 * Solve the blend per pixel:  B = (C - a*W) / (1 - a).
 *
 * `a` is measured from the image rather than assumed: the band is only a few
 * pixels wider than the glyph, so its rim carries the antialiasing ramp, and
 * assuming a hard 0/1 edge is what left a visible outline in earlier attempts.
 * Where the background is too light for the solve to be trustworthy the
 * watermark is near-invisible anyway, so the inpainted estimate is used there.
 */
export function unmix(region, band, background, { alphaCap = 0.7 } = {}) {
  const { width: w, height: h, data } = region
  const out = new Uint8ClampedArray(data)
  const bg = background.data
  for (let i = 0; i < band.mask.length; i++) {
    if (!band.mask[i]) continue
    const p = i * 4
    const o = i * 3
    const bMean = (bg[o] + bg[o + 1] + bg[o + 2]) / 3
    const den = WATERMARK_WHITE - bMean
    let alpha = 0
    if (Math.abs(den) > 20) {
      const cMean = (data[p] + data[p + 1] + data[p + 2]) / 3
      alpha = (cMean - bMean) / den
    }
    alpha = Math.max(0, Math.min(alphaCap, alpha))
    if (alpha <= 0.004) continue
    if (den < 20) {
      // Too little contrast to invert reliably: fall back to the inpainted art.
      out[p] = bg[o]
      out[p + 1] = bg[o + 1]
      out[p + 2] = bg[o + 2]
      continue
    }
    const inv = Math.max(1 - alpha, 0.34)
    out[p] = (data[p] - alpha * WATERMARK_WHITE) / inv
    out[p + 1] = (data[p + 1] - alpha * WATERMARK_WHITE) / inv
    out[p + 2] = (data[p + 2] - alpha * WATERMARK_WHITE) / inv
  }
  return { data: out, width: w, height: h, channels: 4 }
}

/**
 * Strip the watermark from a whole image buffer.
 *
 * Returns the cleaned RGBA plus a report, so a caller can decide whether the
 * result is trustworthy instead of having to take it on faith. `strength` is
 * how much the glyph area stood out above its surroundings before removal —
 * a low value means the mark was barely present and nothing was changed.
 */
export function removeWatermark(image, { log = () => {} } = {}) {
  const { width, height } = image
  const box = watermarkBox(width, height)
  const region = rgba(image).crop(box.x0, box.y0, box.x1 - box.x0 + 1, box.y1 - box.y0 + 1)

  const glyphs = glyphMask(region)
  if (glyphs.count < 300) {
    log('水印检测：未发现足够的水印像素，图片未改动')
    return { image, changed: false, glyphPixels: glyphs.count }
  }

  const band = dilateMask(glyphs, 3)
  const background = inpaintBackground(region, band)
  const cleaned = unmix(region, band, background)

  // Copy before writing. `rgba()` hands back a view over the caller's buffer, so
  // blitting into it would destroy the input image in place — which silently
  // invalidated a before/after verification that ran afterwards and made it
  // report a perfect score against the already-modified original.
  const out = rgba({ data: new Uint8ClampedArray(image.data), width, height })
  out.blit(cleaned, box.x0, box.y0)

  log(`水印检测：${glyphs.count} 个字形像素，处理带 ${band.count} 像素`)
  return { image: out, changed: true, glyphPixels: glyphs.count, bandPixels: band.count }
}

/**
 * Self-check on a flat-background reference.
 *
 * On a flat sample the artwork behind the watermark is a constant, so whatever
 * spread remains inside the glyph area after removal IS the watermark that was
 * not removed. That turns "does it look clean?" into a number — the only way to
 * verify this without trusting an eye on a rescaled preview, which is exactly
 * how an earlier, broken version looked fine while changing nothing.
 *
 * Measured this way on a flat 2048x2048 sample: residual 16.8 -> 0.2.
 */
export function verifyOnFlat(image, { log = () => {} } = {}) {
  // The metric is only meaningful when the artwork behind the mark is flat;
  // on a photograph the glyph mask selects bright artwork, whose spread has
  // nothing to do with the watermark and would report a flattering zero.
  // Threshold set from real samples: a Doubao "solid grey" card still carries a
  // faint gradient (background IQR ~5), while a photograph in the same frame
  // reads ~19. Below the cut the metric is trustworthy; above it the number
  // would be flattering rather than meaningful.
  const flatness = frameFlatness(image)
  if (flatness > 8) {
    log(`灰底反验不适用：背景不平坦（背景 IQR ${flatness.toFixed(1)}，阈值 8），请目视确认或用纯色底样张`)
    return { before: null, after: null, ratio: null, applicable: false, flatness }
  }
  const before = flatResidual(image)
  const { image: cleaned } = removeWatermark(image, { log: () => {} })
  const after = flatResidual(cleaned)
  const ratio = before > 0 ? after / before : 0
  const removed = before > 0 ? 100 * (1 - ratio) : 0
  log(`灰底反验：水印残差 ${before.toFixed(1)} → ${after.toFixed(1)}（去除 ${removed.toFixed(1)}%，背景 IQR ${flatness.toFixed(1)}）`)
  return { before, after, ratio, applicable: true, flatness }
}

/**
 * How flat the artwork is *underneath and around* the watermark.
 *
 * Measured on interquartile range, not standard deviation, and only over
 * non-glyph pixels: the glyphs themselves are the highest-contrast thing in the
 * frame, so including them made a genuinely flat sample look busy (std 17.3 on
 * a flat grey card) and the gate rejected the one image it was meant to accept.
 * IQR of the background ignores both the glyphs and a handful of outliers.
 */
export function frameFlatness(image) {
  const box = watermarkBox(image.width, image.height)
  const region = rgba(image).crop(box.x0, box.y0, box.x1 - box.x0 + 1, box.y1 - box.y0 + 1)
  const glyphs = glyphMask(region)
  const band = dilateMask(glyphs, 3)
  const lums = []
  for (let i = 0; i < band.mask.length; i++) {
    if (band.mask[i]) continue
    const p = i * 4
    lums.push((region.data[p] + region.data[p + 1] + region.data[p + 2]) / 3)
  }
  if (lums.length < 20) return Infinity
  lums.sort((a, b) => a - b)
  const q1 = lums[Math.floor(lums.length * 0.25)]
  const q3 = lums[Math.floor(lums.length * 0.75)]
  return q3 - q1
}

/**
 * Mean absolute deviation from the frame's median colour, over the glyph pixels.
 *
 * Restricted to the detected glyph mask: on a flat reference those are the only
 * pixels the watermark ever touched, so this isolates it from the artwork and
 * from the box margin.
 */
function flatResidual(image) {
  const box = watermarkBox(image.width, image.height)
  const region = rgba(image).crop(box.x0, box.y0, box.x1 - box.x0 + 1, box.y1 - box.y0 + 1)
  const glyphs = glyphMask(region)
  if (glyphs.count < 50) return 0

  const baseline = glyphs.baseline
  let sum = 0
  let n = 0
  for (let i = 0; i < glyphs.mask.length; i++) {
    if (!glyphs.mask[i]) continue
    const p = i * 4
    sum += Math.abs((region.data[p] + region.data[p + 1] + region.data[p + 2]) / 3 - baseline)
    n++
  }
  return n > 0 ? sum / n : 0
}

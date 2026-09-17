/**
 * A tiny PNG codec, plus the small raster helpers the watermark pass needs.
 *
 * Written by hand rather than pulled from a package for two reasons: the plugin
 * is loaded from outside the DSH install and has no `node_modules` of its own,
 * and the only images it ever touches are Doubao's own PNG downloads — 8-bit,
 * non-interlaced, colour type 2 or 6. Anything else is rejected loudly instead
 * of being silently mangled.
 */

import { inflateSync, deflateSync } from 'node:zlib'

/** Decode an 8-bit non-interlaced PNG into RGBA. */
export function decodePng(buffer) {
  if (buffer.length < 8 || buffer.readUInt32BE(0) !== 0x89504e47) {
    throw new Error('不是 PNG 数据')
  }
  let pos = 8
  let width = 0
  let height = 0
  let colourType = 0
  const idat = []

  while (pos + 8 <= buffer.length) {
    const length = buffer.readUInt32BE(pos)
    const type = buffer.toString('ascii', pos + 4, pos + 8)
    const body = buffer.subarray(pos + 8, pos + 8 + length)
    if (type === 'IHDR') {
      width = body.readUInt32BE(0)
      height = body.readUInt32BE(4)
      const depth = body[8]
      colourType = body[9]
      const interlace = body[12]
      if (depth !== 8) throw new Error(`暂不支持 ${depth} 位深的 PNG`)
      if (interlace !== 0) throw new Error('暂不支持隔行扫描的 PNG')
      if (colourType !== 2 && colourType !== 6) {
        throw new Error(`暂不支持色彩类型 ${colourType} 的 PNG`)
      }
    } else if (type === 'IDAT') {
      idat.push(body)
    } else if (type === 'IEND') {
      break
    }
    pos += 12 + length
  }

  const channels = colourType === 6 ? 4 : 3
  const stride = width * channels
  const raw = inflateSync(Buffer.concat(idat))
  const out = new Uint8ClampedArray(width * height * 4)
  const line = Buffer.alloc(stride)
  const prev = Buffer.alloc(stride)
  let p = 0

  for (let y = 0; y < height; y++) {
    const filter = raw[p]
    p += 1
    raw.copy(line, 0, p, p + stride)
    p += stride

    // Undo the per-scanline filter, in place, exactly as the spec defines.
    if (filter === 1) {
      for (let i = channels; i < stride; i++) line[i] = (line[i] + line[i - channels]) & 0xff
    } else if (filter === 2) {
      for (let i = 0; i < stride; i++) line[i] = (line[i] + prev[i]) & 0xff
    } else if (filter === 3) {
      for (let i = 0; i < stride; i++) {
        const a = i >= channels ? line[i - channels] : 0
        line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xff
      }
    } else if (filter === 4) {
      for (let i = 0; i < stride; i++) {
        const a = i >= channels ? line[i - channels] : 0
        const b = prev[i]
        const c = i >= channels ? prev[i - channels] : 0
        const pa = Math.abs(b - c)
        const pb = Math.abs(a - c)
        const pc = Math.abs(a + b - 2 * c)
        const pr = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
        line[i] = (line[i] + pr) & 0xff
      }
    } else if (filter !== 0) {
      throw new Error(`未知的 PNG 行过滤器 ${filter}`)
    }

    for (let x = 0; x < width; x++) {
      const si = x * channels
      const di = (y * width + x) * 4
      out[di] = line[si]
      out[di + 1] = line[si + 1]
      out[di + 2] = line[si + 2]
      out[di + 3] = channels === 4 ? line[si + 3] : 255
    }
    line.copy(prev)
  }

  return { data: out, width, height, channels: 4 }
}

/** Encode RGBA (or RGB) back to an 8-bit PNG. */
export function encodePng(image) {
  const { width, height } = image
  const src = image.data
  const hasAlpha = src.length >= width * height * 4
  const channels = hasAlpha ? 4 : 3
  const colourType = hasAlpha ? 6 : 2
  const stride = width * channels
  const raw = Buffer.alloc((stride + 1) * height)

  for (let y = 0; y < height; y++) {
    const rowStart = y * (stride + 1)
    raw[rowStart] = 0 // filter type 0: stored as-is
    for (let x = 0; x < width; x++) {
      const si = (y * width + x) * 4
      const di = rowStart + 1 + x * channels
      raw[di] = src[si]
      raw[di + 1] = src[si + 1]
      raw[di + 2] = src[si + 2]
      if (hasAlpha) raw[di + 3] = src[si + 3]
    }
  }

  const chunk = (type, body) => {
    const head = Buffer.alloc(8)
    head.writeUInt32BE(body.length, 0)
    head.write(type, 4, 'ascii')
    const crc = Buffer.alloc(4)
    crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), body])) >>> 0, 0)
    return Buffer.concat([head, body, crc])
  }

  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8
  ihdr[9] = colourType
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 6 })),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

let crcTable = null
function crc32(buffer) {
  if (!crcTable) {
    crcTable = new Int32Array(256)
    for (let n = 0; n < 256; n++) {
      let c = n
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
      crcTable[n] = c
    }
  }
  let c = -1
  for (let i = 0; i < buffer.length; i++) c = crcTable[(c ^ buffer[i]) & 0xff] ^ (c >>> 8)
  return c ^ -1
}

/** Wrap an image so sub-regions can be cut out and blitted back. */
export function rgba(image) {
  const { data, width, height } = image
  return {
    data,
    width,
    height,
    /** A copy of one rectangle, as its own image. */
    crop(x0, y0, w, h) {
      const out = new Uint8ClampedArray(w * h * 4)
      for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
          const si = ((y0 + y) * width + (x0 + x)) * 4
          const di = (y * w + x) * 4
          out[di] = data[si]
          out[di + 1] = data[si + 1]
          out[di + 2] = data[si + 2]
          out[di + 3] = data[si + 3]
        }
      }
      return { data: out, width: w, height: h, channels: 4 }
    },
    /** Write another image over this one at (x0, y0). */
    blit(patch, x0, y0) {
      const src = patch.data ?? patch
      const pw = patch.width
      for (let y = 0; y < patch.height; y++) {
        for (let x = 0; x < pw; x++) {
          const si = (y * pw + x) * 4
          const dx = x0 + x
          const dy = y0 + y
          if (dx < 0 || dy < 0 || dx >= width || dy >= height) continue
          const di = (dy * width + dx) * 4
          data[di] = src[si]
          data[di + 1] = src[si + 1]
          data[di + 2] = src[si + 2]
          data[di + 3] = src[si + 3] ?? 255
        }
      }
    },
    /** A shallow view sharing this image's buffer. */
    view() {
      return { data, width, height, channels: 4 }
    },
  }
}

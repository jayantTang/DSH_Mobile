import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { apply, buildPrompt, defaultDir, inject, name, renderResult, resolveCount } from '../lib/index.js'
import { countOccurrences, submitPrompt } from '../lib/doubao.mjs'
import { decodePng, encodePng } from '../lib/image.mjs'
import {
  dilateMask,
  frameFlatness,
  isGlyphPixel,
  removeWatermark,
  verifyOnFlat,
  watermarkBox,
} from '../lib/watermark.mjs'
import { IMAGE_PROMPT_PREFIX, downloadsDir, sniffFormat } from '../lib/doubao.mjs'

/** A tool definition as the host would receive it. */
function register() {
  let tool = null
  apply({ tools: { register: (definition) => { tool = definition } } })
  assert.ok(tool, 'apply() registered nothing')
  return tool
}

test('exports a Cordis plugin shape', () => {
  assert.equal(name, 'tool-doubao-image')
  // `attachments` is how generated pictures reach the client without becoming
  // user messages.
  assert.deepEqual(inject, ['tools', 'attachments'])
})

test('registers the generate_image tool', () => {
  const tool = register()
  assert.equal(tool.name, 'generate_image')
  assert.equal(tool.parameters.type, 'object')
  assert.deepEqual(
    Object.keys(tool.parameters.properties).sort(),
    ['aspect', 'composition', 'count', 'dir', 'negative', 'prompt', 'reuseCurrentChat', 'stripWatermark', 'style'],
  )
  // Only the prompt is mandatory: a model that writes a good prompt but omits
  // the aspect ratio should get an image, not a schema rejection.
  assert.deepEqual(tool.parameters.required, ['prompt'])
  assert.equal(typeof tool.execute, 'function')
  assert.ok(tool.description.length > 100)
})

test('declares an output schema, which the registry refuses to load without', () => {
  // Boot fails hard on a tool with no `output`, and a failed boot takes the
  // whole harness down — the desktop app then cannot start at all.
  const tool = register()
  assert.equal(tool.output.schema.type, 'object')
  assert.deepEqual(tool.output.schema.required, ['ok'])
  assert.deepEqual(
    Object.keys(tool.output.schema.properties).sort(),
    ['attachments', 'detail', 'error', 'files', 'ok'],
  )
  assert.equal(typeof tool.output.render, 'function')
})

test('buildPrompt prefixes the phrase Doubao routes on', () => {
  const built = buildPrompt({ prompt: '一只橘猫' })
  assert.equal(built.ok, true)
  assert.ok(built.text.startsWith(IMAGE_PROMPT_PREFIX), 'without the prefix Doubao answers in chat instead')
  assert.match(built.text, /一只橘猫/)
})

test('buildPrompt assembles the ordered professional description', () => {
  const built = buildPrompt({
    prompt: '一只橘猫',
    style: '黏土质感',
    composition: '45 度俯视',
    negative: '文字，水印',
    aspect: '3:4',
  })
  assert.equal(built.ok, true)
  // Order matters: subject, then style/light, then composition, then what to
  // avoid, with the aspect request last so nothing dilutes it.
  const index = (needle) => built.text.indexOf(needle)
  assert.ok(index('一只橘猫') < index('风格与光影'))
  assert.ok(index('风格与光影') < index('构图'))
  assert.ok(index('构图') < index('不要出现'))
  assert.ok(index('不要出现') < index('3:4'))
})

test('buildPrompt omits every optional clause it was not given', () => {
  const built = buildPrompt({ prompt: '一只橘猫' })
  assert.ok(!built.text.includes('风格与光影'))
  assert.ok(!built.text.includes('构图'))
  assert.ok(!built.text.includes('不要出现'))
  assert.ok(!built.text.includes('比例'))
})

test('buildPrompt refuses an empty prompt', () => {
  assert.equal(buildPrompt({}).ok, false)
  assert.equal(buildPrompt({ prompt: '   ' }).ok, false)
  const result = buildPrompt({})
  assert.match(result.error, /prompt/)
})

test('resolveCount clamps to what Doubao will honour', () => {
  assert.equal(resolveCount(undefined), 1)
  assert.equal(resolveCount(0), 1)
  assert.equal(resolveCount(-3), 1)
  assert.equal(resolveCount('abc'), 1)
  assert.equal(resolveCount(2), 2)
  assert.equal(resolveCount(2.7), 2)
  assert.equal(resolveCount(99), 4)
})

test('sniffFormat reads magic bytes, not file extensions', () => {
  const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(8)])
  assert.equal(sniffFormat(png), 'png')
  assert.equal(sniffFormat(Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(8)])), 'jpg')
  assert.equal(
    sniffFormat(Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(4), Buffer.from('WEBP'), Buffer.alloc(4)])),
    'webp',
  )
})

test('sniffFormat rejects anything that is not an image', () => {
  // The failure this guards: the CDN answering a signed-URL rejection with an
  // HTML error page, which would otherwise be written out as a ".png".
  assert.equal(sniffFormat(Buffer.from('<html>403 Forbidden</html>')), null)
  assert.equal(sniffFormat(Buffer.alloc(0)), null)
})

test('renderResult lists every saved file with its size', () => {
  const text = renderResult({
    ok: true,
    files: [{ path: '/tmp/doubao-a1b2c3.jpg', bytes: 3_875_198 }],
  })
  assert.match(text, /\/tmp\/doubao-a1b2c3\.jpg/)
  assert.match(text, /3\.7 MB/)
})

test('renderResult handles the no-image and failure cases', () => {
  assert.match(renderResult({ ok: true, files: [] }), /没有返回可用图片/)
  assert.match(renderResult({ ok: false, error: '等待生成超时' }), /等待生成超时/)
  assert.match(renderResult({ ok: false }), /未知原因/)
})

test('defaultDir points at a Pictures subdirectory', () => {
  assert.match(defaultDir(), /Pictures\/doubao$/)
})

test('downloadsDir is where Doubao itself writes saved pictures', () => {
  // Not configurable: the app's own download control decides, and the tool
  // moves the file out afterwards. A change here would silently break harvest.
  assert.match(downloadsDir(), /Downloads$/)
})

test('execute refuses an empty prompt without touching the app', async () => {
  const tool = register()
  const result = await tool.execute({}, {})
  assert.equal(result.ok, false)
  assert.match(result.error, /prompt/)
})

/**
 * Regression tests for the duplicate-generation bug.
 *
 * The first submit path inferred delivery from the editor going empty, and
 * retried whenever it did not. Doubao also clears the editor while switching
 * conversations, so a prompt that HAD been sent was reported as failed and
 * re-sent — running the same generation twice and consuming the user's quota
 * twice. One conversation was found holding the same prompt twice with two
 * result images, next to a sibling holding it once.
 *
 * These tests pin the corrected rule: a retry may only happen on positive
 * evidence that the previous attempt delivered nothing.
 */

/** A session whose transcript grows only when the fake send decides it did. */
function fakeSession({ countBefore = 0, incrementsPerAttempt = [], editorCleared = true }) {
  const calls = { evaluate: 0, attempts: 0 }
  let count = countBefore
  return {
    calls,
    session: {
      async evaluate(expression) {
        calls.evaluate += 1
        if (expression.includes('findEditor')) {
          const bump = incrementsPerAttempt[calls.attempts] ?? 0
          calls.attempts += 1
          count += bump
          return { ok: true, via: editorCleared ? 'enter' : null, typedLength: 10, editorCleared }
        }
        return 'x'.repeat(count * 24) + 'P'.repeat(0) // transcript with `count` needles
      },
    },
  }
}

test('a delivered prompt is never sent twice', async () => {
  // Transcript already carries one copy, and the attempt adds another: the
  // confirmation must stop there rather than retry.
  const before = '生成图片：一只橘猫'
  const { session, calls } = fakeSession({ countBefore: 1, incrementsPerAttempt: [1] })
  // countOccurrences counts occurrences of a 24-char needle; make the returned
  // text contain exactly the counter's worth of matches.
  session.evaluate = (function (original) {
    let count = 1
    return async (expression) => {
      calls.evaluate += 1
      if (expression.includes('findEditor')) {
        calls.attempts += 1
        count += 1
        return { ok: true, via: 'enter', typedLength: 10, editorCleared: true }
      }
      return before.slice(0, 24).repeat(count)
    }
  })()
  const result = await submitPrompt(session, before, { confirmTimeoutMs: 300 })
  assert.equal(result.ok, true)
  assert.equal(calls.attempts, 1, '提交了不止一次，会重复消耗生成额度')
})

test('a genuinely unsent prompt is retried', async () => {
  // Editor kept the text and nothing reached the transcript: retrying is safe
  // and necessary.
  let attempts = 0
  const session = {
    async evaluate(expression) {
      if (expression.includes('findEditor')) {
        attempts += 1
        // first attempt leaves the text in the box, second one succeeds
        const cleared = attempts > 1
        return { ok: true, via: cleared ? 'enter' : null, typedLength: 10, editorCleared: cleared }
      }
      return attempts > 1 ? '生成图片：一只橘猫' : ''
    },
  }
  const result = await submitPrompt(session, '生成图片：一只橘猫', { confirmTimeoutMs: 300 })
  assert.equal(result.ok, true)
  assert.equal(attempts, 2)
})

test('an ambiguous submit stops instead of risking a second generation', async () => {
  // The dangerous state: the editor is empty but the transcript shows nothing.
  // Retrying here is exactly what duplicated generations, so it must refuse.
  let attempts = 0
  const session = {
    async evaluate(expression) {
      if (expression.includes('findEditor')) {
        attempts += 1
        return { ok: true, via: 'enter', typedLength: 10, editorCleared: true }
      }
      return ''
    },
  }
  await assert.rejects(
    () => submitPrompt(session, '生成图片：一只橘猫', { confirmTimeoutMs: 300 }),
    /重复生成|状态不明/,
  )
  assert.equal(attempts, 1, '状态不明时不应再次提交')
})

test('countOccurrences counts repeats rather than mere presence', async () => {
  const session = { async evaluate() { return 'abXabXab' } }
  assert.equal(await countOccurrences(session, 'ab'), 3)
  assert.equal(await countOccurrences(session, 'zz'), 0)
  assert.equal(await countOccurrences(session, ''), 0)
})

/** ---------------------------------------------------------- watermark geometry */

test('the watermark box scales with the image short side', async () => {
  // Measured on flat samples: 2048x2048 -> 321x69 gap 41/34, and
  // 1365x2048 -> 214x46 gap 27/23. Keying off width instead of the short side
  // put the box in the wrong place on non-square renders, which silently made
  // the removal a no-op on a real landscape image.
  const square = watermarkBox(2048, 2048)
  const portrait = watermarkBox(1365, 2048)
  assert.ok(Math.abs(square.boxW - 321) <= 2, `square box ${square.boxW}`)
  assert.ok(Math.abs(portrait.boxW - 214) <= 2, `portrait box ${portrait.boxW}`)
  // same ratios either way, which is what "scales with the short side" means
  assert.ok(Math.abs(square.boxW / 2048 - portrait.boxW / 1365) < 0.005)
})

test('the watermark box tracks the short side on widescreen too', () => {
  // A 16:9 render's short side is its height, so the box must shrink with it.
  const wide = watermarkBox(2048, 1152)
  assert.ok(Math.abs(wide.boxW - Math.round(1152 * 0.1567)) <= 2, `wide box ${wide.boxW}`)
  assert.ok(wide.boxH < wide.boxW, 'the mark is wider than it is tall')
})

test('the watermark box stays inside the frame', () => {
  for (const [w, h] of [[2048, 2048], [1365, 2048], [2048, 1152], [256, 256]]) {
    const box = watermarkBox(w, h)
    assert.ok(box.x0 >= 0 && box.y0 >= 0, `negative origin for ${w}x${h}`)
    assert.ok(box.x1 <= w - 1 && box.y1 <= h - 1, `overflow for ${w}x${h}`)
    assert.ok(box.x1 > box.x0 && box.y1 > box.y0, `empty box for ${w}x${h}`)
  }
})

test('glyph detection requires light AND desaturated', () => {
  assert.equal(isGlyphPixel(200, 200, 195, 120), true)
  // A saturated colour of the same brightness is artwork, not the mark.
  assert.equal(isGlyphPixel(220, 40, 30, 120), false)
  // Dark artwork is not the mark either.
  assert.equal(isGlyphPixel(40, 40, 38, 120), false)
})

test('glyph detection is relative to the frame background', () => {
  // The regression: an absolute threshold classified a whole 50%-grey card as
  // glyph, because 166 is bright and perfectly neutral. Doubao renders on light
  // backgrounds often, so the background must not count as the mark.
  assert.equal(isGlyphPixel(166, 166, 164, 166), false, 'a flat grey card is not a glyph')
  // The mark on that same card sits well above it.
  assert.equal(isGlyphPixel(220, 221, 218, 166), true)
})

test('dilateMask grows the mask by a true radius', () => {
  const width = 21
  const height = 21
  const mask = new Uint8Array(width * height)
  mask[10 * width + 10] = 1
  const grown = dilateMask({ mask, width, height }, 2)
  // every pixel within Euclidean distance 2 of the seed, and nothing beyond
  let count = 0
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (!grown.mask[y * width + x]) continue
      count++
      assert.ok(Math.hypot(x - 10, y - 10) <= 2 + 1e-9, `(${x},${y}) is outside the radius`)
    }
  }
  assert.equal(count, 13, 'a radius-2 disc holds 13 pixels')
})

test('flatness separates a grey card from a photograph', () => {
  // The gate has to accept a flat reference (where the metric is meaningful)
  // and reject a photo (where a glyph-shaped mask just selects bright artwork,
  // which reported a flattering zero in testing).
  const flat = solidImage(2048, 2048, [166, 166, 164])
  assert.ok(frameFlatness(flat) < 4, 'a solid grey frame must read as flat')

  const noisy = solidImage(2048, 2048, [166, 166, 164])
  let seed = 7
  for (let i = 0; i < noisy.data.length; i += 4) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    const n = (seed % 90) - 45
    noisy.data[i] = 120 + n
    noisy.data[i + 1] = 120 + n
    noisy.data[i + 2] = 120 + n
  }
  assert.ok(frameFlatness(noisy) > 8, 'a noisy frame must not read as flat')
})

/** A flat RGBA image, for the geometry and flatness tests. */
function solidImage(width, height, [r, g, b]) {
  const data = new Uint8ClampedArray(width * height * 4)
  for (let i = 0; i < width * height; i++) {
    data[i * 4] = r
    data[i * 4 + 1] = g
    data[i * 4 + 2] = b
    data[i * 4 + 3] = 255
  }
  return { data, width, height }
}

test('png encode/decode round-trips losslessly', () => {
  const source = decodePng(fixturePng())
  const back = decodePng(encodePng(source))
  assert.equal(back.width, source.width)
  assert.equal(back.height, source.height)
  let maxDelta = 0
  for (let i = 0; i < source.data.length; i++) {
    maxDelta = Math.max(maxDelta, Math.abs(source.data[i] - back.data[i]))
  }
  // Re-encoding must not perturb pixels: the watermark pass writes a new file,
  // and a lossy round trip would show up as a needless quality drop.
  assert.equal(maxDelta, 0)
})

test('the decoder rejects formats it cannot handle', () => {
  assert.throws(() => decodePng(Buffer.from('not a png at all')), /不是 PNG/)
})

test('a picture with no watermark is left untouched', () => {
  const clean = solidImage(1024, 1024, [30, 40, 50])
  const result = removeWatermark(clean, { log: () => {} })
  assert.equal(result.changed, false, 'a uniform dark image has no glyphs to remove')
  assert.equal(result.image, clean)
})

/** A tiny valid PNG, produced by the encoder under test. */
function fixturePng() {
  const img = solidImage(8, 8, [10, 20, 30])
  img.data[0] = 200
  img.data[1] = 100
  img.data[2] = 50
  return encodePng(img)
}

test('removeWatermark does not mutate its input', () => {
  // It used to: rgba() returns a view over the caller's buffer, so the removal
  // wrote straight into the source image. A before/after verification run after
  // it then measured the already-cleaned original and reported a false perfect
  // score — the most dangerous kind of bug here, because it looks like success.
  const img = solidImage(512, 512, [40, 60, 80])
  const snapshot = Uint8ClampedArray.from(img.data)
  removeWatermark(img, { log: () => {} })
  assert.deepEqual(Array.from(img.data), Array.from(snapshot), '输入图被就地修改了')
})

test('verifyOnFlat measures the original, not a mutated copy', () => {
  // Same defect seen from the caller's side: verification must be able to report
  // a real before-value even after a removal has already run.
  const img = solidImage(1024, 1024, [166, 166, 166])
  imprintGlyphs(img)
  const first = verifyOnFlat(img, { log: () => {} })
  const second = verifyOnFlat(img, { log: () => {} })
  assert.equal(first.applicable, true)
  assert.ok(first.before > 10, `before-residual was ${first.before}, expected the mark to register`)
  assert.ok(second.before > 10, '第二次反验读到的 before 变小了，说明原图被改过')
  assert.equal(second.before, first.before)
  assert.ok(first.after < first.before * 0.1, '去除后残差应大幅下降')
})

/** Paint a watermark-shaped bright block into the mark's frame. */
function imprintGlyphs(img) {
  const box = watermarkBox(img.width, img.height)
  for (let y = box.y0 + Math.round(box.boxH * 0.25); y < box.y1 - Math.round(box.boxH * 0.25); y++) {
    for (let x = box.x0 + Math.round(box.boxW * 0.2); x < box.x1 - 4; x++) {
      if ((x + y) % 3 === 0) continue // a stroke-like pattern, not a solid block
      const p = (y * img.width + x) * 4
      img.data[p] = 220
      img.data[p + 1] = 220
      img.data[p + 2] = 218
    }
  }
}

test('generated files are published as attachments, without a session', async () => {
  // Regression: delivery used to run send-image.mjs with a session id, which
  // submitted each file as a `session/prompt` — the pictures arrived as user
  // messages and every one of them started another turn, so the agent answered
  // its own generated image. Attachments on the tool result replace all of that,
  // and with it the whole "拿不到会话 id" failure class.
  const { publishAll } = await import('../lib/index.js')
  const directory = mkdtempSync(join(tmpdir(), 'dsh-doubao-'))
  const path = join(directory, 'doubao-1.png')
  const bytes = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64'
  )
  writeFileSync(path, bytes)
  const saved = []
  const attachments = {
    async saveImage(input) {
      saved.push(input)
      return { type: 'image', attachmentId: `att_${saved.length}`, mediaType: input.mediaType, bytes: input.data.length }
    },
  }
  try {
    const published = await publishAll(attachments, [
      { path, bytes: bytes.length, format: 'png' },
    ])
    assert.equal(published.attachments.length, 1)
    assert.match(published.note, /已把 1 张图放进当前会话/)
    assert.equal(saved[0].mediaType, 'image/png')
    assert.equal(saved[0].name, 'doubao-1.png')
    assert.equal(saved[0].data.length, bytes.length)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('a picture that cannot be published keeps the others', async () => {
  // Two ways to fail, and neither may take the rest of the batch with it: the
  // Host refusing the bytes, and a file that is not readable any more.
  const { publishAll } = await import('../lib/index.js')
  const directory = mkdtempSync(join(tmpdir(), 'dsh-doubao-'))
  const good = join(directory, 'good.png')
  const rejected = join(directory, 'rejected.png')
  writeFileSync(good, Buffer.from('89504e470d0a1a0a', 'hex'))
  writeFileSync(rejected, Buffer.from('89504e470d0a1a0a', 'hex'))
  const attachments = {
    async saveImage(input) {
      if (input.name === 'rejected.png') throw new Error('image exceeds 20971520 bytes')
      return { type: 'image', attachmentId: 'att_1', mediaType: input.mediaType, bytes: input.data.length }
    },
  }
  try {
    const published = await publishAll(attachments, [
      { path: good, bytes: 8, format: 'png' },
      { path: rejected, bytes: 8, format: 'png' },
      { path: join(directory, 'missing.png'), bytes: 8, format: 'png' },
      { path: good, bytes: 8, format: 'png' },
    ])
    assert.equal(published.attachments.length, 2, 'a failed publish must not lose the others')
    assert.match(published.note, /2 张未能放入/)
    assert.match(published.note, /rejected\.png/)
    assert.match(published.note, /missing\.png/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

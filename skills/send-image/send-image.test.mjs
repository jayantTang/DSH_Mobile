import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile, execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { fileURLToPath } from 'node:url'
import {
  describePrepared, explainCaptureFailure, generatePreview, needsPreviewResize, parsePixelSize,
} from './send-image.mjs'

const run = promisify(execFile)
const script = fileURLToPath(new URL('./send-image.mjs', import.meta.url))

test('a denied capture points at the permission and the restart, not at stderr', () => {
  // This exact stderr is what macOS returns when the Screen Recording grant
  // does not cover the running process.
  const message = explainCaptureFailure({
    stderr: Buffer.from('could not create image from display\n'),
  })
  assert.match(message, /屏幕录制/)
  // 只指路到"运行 DSH 的那个程序"，不再点名某个具体应用：自研外壳已删除，
  // 名字写死会让用户去找一个不存在的 App（官方桌面版是 DeepSeek Harness）。
  assert.match(message, /运行 DSH 的那个程序/)
  assert.match(message, /完全退出并重新打开/)
  assert.doesNotMatch(message, /DSH\.app/)
  // The original text stays, so a different cause is still diagnosable.
  assert.match(message, /could not create image from display/)
})

test('another failure keeps its own reason', () => {
  const message = explainCaptureFailure({ stderr: Buffer.from('screencapture: no display\n') })
  assert.match(message, /截屏失败/)
  assert.match(message, /no display/)
  assert.doesNotMatch(message, /重新打开/)
})

test('a failure with no stderr still says something usable', () => {
  const message = explainCaptureFailure(new Error('spawn screencapture ENOENT'))
  assert.match(message, /spawn screencapture ENOENT/)
})

// ── prepare mode ────────────────────────────────────────────────────────────

test('--file prepares a descriptor instead of sending anything', async () => {
  // The default mode must not touch the session: the tool turns this descriptor
  // into an attachment that rides on its own result. A prompt would show up as a
  // user message and start another turn — the bug this replaced.
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-script-'))
  const path = join(directory, 'pixel.png')
  writeFileSync(path, Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64'
  ))
  try {
    // No DSH_SESSION_ID: preparing must not need one, and must not call the API.
    const env = { ...process.env }
    delete env.DSH_SESSION_ID
    const { stdout } = await run(process.execPath, [script, '--file', path], { env, encoding: 'utf8' })
    const descriptor = JSON.parse(stdout.trim())
    assert.equal(descriptor.path, path)
    assert.equal(descriptor.mediaType, 'image/png')
    assert.equal(descriptor.name, 'pixel.png')
    assert.ok(descriptor.bytes > 0)
    assert.equal(descriptor.temporary, false)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('--via-prompt still insists on a session id', async () => {
  // The fallback path is the one that needs the session, and it says so rather
  // than failing deeper in with a confusing error.
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-script-'))
  const path = join(directory, 'pixel.png')
  writeFileSync(path, Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64'
  ))
  try {
    const env = { ...process.env }
    delete env.DSH_SESSION_ID
    await assert.rejects(
      () => run(process.execPath, [script, '--file', path, '--via-prompt'], { env, encoding: 'utf8' }),
      (error) => /DSH_SESSION_ID/.test(String(error.stderr) + String(error.message))
    )
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

// ── 预览 ───────────────────────────────────────────────────────────────────

test('sips 尺寸解析只认像素键，缩放判断按最长边与总像素', () => {
  assert.deepEqual(
    parsePixelSize('/tmp/a.png\n  pixelWidth: 4032\n  pixelHeight: 3024\n'),
    { width: 4032, height: 3024 },
  )
  // 路径里带 pixelWidth 也不能被当成尺寸。
  assert.equal(parsePixelSize('/tmp/notpixelWidth.png\n  pixelHeight: 10\n'), null)
  assert.equal(parsePixelSize('sips: not an image'), null)
  // 正好 2560 边 / 400 万像素都不缩放：重编码会无谓改变像素。
  assert.equal(needsPreviewResize({ width: 2560, height: 1000 }), false)
  assert.equal(needsPreviewResize({ width: 2000, height: 2000 }), false)
  assert.equal(needsPreviewResize({ width: 2561, height: 1 }), true)
  assert.equal(needsPreviewResize({ width: 2001, height: 2000 }), true)
})

test('不超上限的图只复制原文件，不交给 sips 重编码', () => {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-preview-'))
  const path = join(directory, 'pixel.png')
  const bytes = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64'
  )
  writeFileSync(path, bytes)
  const calls = []
  let preview
  try {
    // 只伪造 sips；复制走真实文件系统，产物必须逐字节等于原图。
    preview = generatePreview(path, 'image/png', {
      execFileSync: (...args) => {
        calls.push(args)
        return '  pixelWidth: 1\n  pixelHeight: 1\n'
      },
    })
    assert.equal(preview.ok, true, preview.error)
    assert.equal(calls.length, 1, '小图只查询尺寸，不调用缩放')
    assert.equal(calls[0][1].includes('-Z'), false)
    assert.notEqual(preview.path, path)
    assert.deepEqual(readFileSync(preview.path), bytes)
    assert.equal(preview.bytes, bytes.length)
    assert.equal(preview.mediaType, 'image/png')
  } finally {
    if (preview?.path) rmSync(preview.path, { force: true })
    rmSync(directory, { recursive: true, force: true })
  }
})

test('超过 2560 的图用 sips 缩到最长边 2560 的 JPEG', () => {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-preview-'))
  const pixel = join(directory, 'pixel.png')
  const large = join(directory, 'large.png')
  writeFileSync(pixel, Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64'
  ))
  let preview
  try {
    // 真跑 sips 造一张 4000×3000（1200 万像素）的原图，避免只用桩证明"缩过了"。
    execFileSync('sips', ['-z', '3000', '4000', pixel, '--out', large], { stdio: 'ignore' })
    preview = generatePreview(large, 'image/png')
    assert.equal(preview.ok, true, preview.error)
    assert.equal(preview.mediaType, 'image/jpeg')
    assert.notEqual(preview.path, large)
    const dimensions = parsePixelSize(
      execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', preview.path], { encoding: 'utf8' }),
    )
    assert.ok(Math.max(dimensions.width, dimensions.height) <= 2560, JSON.stringify(dimensions))
    // 两个上限必须同时成立：4:3 的 4000×3000 若只按最长边缩到 2560，
    // 会得到约 4.9 MP。目标边长按像素上限反解，结果两边都不越界。
    assert.ok(dimensions.width * dimensions.height <= 4_000_000, JSON.stringify(dimensions))
    // JPEG 魔数：确认输出真的是 JPEG，不是改了扩展名的 PNG。
    assert.deepEqual([...readFileSync(preview.path).subarray(0, 2)], [0xff, 0xd8])
    assert.equal(preview.bytes, readFileSync(preview.path).length)
  } finally {
    if (preview?.path) rmSync(preview.path, { force: true })
    rmSync(directory, { recursive: true, force: true })
  }
})

test('sips 失败只返回 previewError，不抛错', () => {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-preview-'))
  const path = join(directory, 'bad.png')
  writeFileSync(path, 'not an image')
  try {
    const preview = generatePreview(path, 'image/png', {
      execFileSync: () => {
        const error = new Error('sips failed')
        error.stderr = 'Error: Unable to render image'
        throw error
      },
    })
    assert.equal(preview.ok, false)
    assert.match(preview.error, /Unable to render image/)
    assert.equal(preview.path, undefined)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('不可解码的扩展名给出 previewError，而不是抛错', () => {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-preview-'))
  const path = join(directory, 'notes.bmp')
  writeFileSync(path, 'not an image')
  try {
    const preview = generatePreview(path, undefined)
    assert.equal(preview.ok, false)
    assert.match(preview.error, /不支持的图片格式/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('读不到尺寸时 CLI 仍输出原图描述符并带 previewError', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-script-'))
  const path = join(directory, 'corrupt.png')
  const bytes = Buffer.from('this is not a png')
  writeFileSync(path, bytes)
  try {
    const { stdout } = await run(process.execPath, [script, '--file', path], { encoding: 'utf8' })
    const descriptor = JSON.parse(stdout.trim())
    assert.equal(descriptor.path, path)
    assert.equal(descriptor.name, 'corrupt.png')
    assert.equal(descriptor.mediaType, 'image/png')
    assert.equal(descriptor.bytes, bytes.length)
    assert.match(descriptor.previewError, /无法生成预览/)
    assert.equal(descriptor.previewPath, undefined)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('不支持的扩展名 CLI 也输出原图描述符，交给调用方按文件发送', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-script-'))
  const path = join(directory, 'notes.bmp')
  const bytes = Buffer.from('BM-not-really')
  writeFileSync(path, bytes)
  try {
    const { stdout } = await run(process.execPath, [script, '--file', path], { encoding: 'utf8' })
    const descriptor = JSON.parse(stdout.trim())
    assert.equal(descriptor.path, path)
    assert.equal(descriptor.name, 'notes.bmp')
    assert.equal(descriptor.bytes, bytes.length)
    assert.equal(descriptor.mediaType, undefined)
    assert.match(descriptor.previewError, /不支持的图片格式/)
    assert.equal(descriptor.previewPath, undefined)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('截图/剪贴板等临时原图同样附带临时预览标记', () => {
  // 截图与剪贴板只差 loadImage 的 temporary 标记；描述符形状必须一致。
  const descriptor = describePrepared({
    path: '/tmp/shot.png',
    name: 'shot.png',
    mediaType: 'image/png',
    bytes: 10,
    temporary: true,
    preview: { ok: true, path: '/tmp/preview.jpg', bytes: 5, mediaType: 'image/jpeg', temporary: true },
  })
  assert.equal(descriptor.path, '/tmp/shot.png')
  assert.equal(descriptor.temporary, true)
  assert.equal(descriptor.previewPath, '/tmp/preview.jpg')
  assert.equal(descriptor.previewBytes, 5)
  assert.equal(descriptor.previewTemporary, true)
  assert.equal(descriptor.previewError, undefined)
})

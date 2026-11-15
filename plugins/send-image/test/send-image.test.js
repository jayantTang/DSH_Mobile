import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  apply, buildArgs, describeSend, discardPrepared, inject, name, publish,
  renderResult, resolveSource, scriptPath,
} from '../lib/index.js'

/** A 1×1 PNG: real bytes, so the print-and-parse path is exercised for real. */
function fixturePng() {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-'))
  const path = join(directory, 'pixel.png')
  const bytes = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64'
  )
  writeFileSync(path, bytes)
  return { directory, path, bytes }
}

/** The host context the tool is applied to, with a recording attachments service. */
function host({ failWith, withSaveFile = false, failSaveFile } = {}) {
  const saved = []
  const savedFiles = []
  const attachments = {
    async saveImage(input) {
      if (failWith) throw new Error(failWith)
      saved.push(input)
      return {
        type: 'image',
        attachmentId: 'att_test',
        mediaType: input.mediaType,
        bytes: input.data.length,
        width: 1,
        height: 1,
        name: input.name,
      }
    },
  }
  // 旧 Host 没有 `saveFile`：只有用例显式要求时才挂上，保证能力探测分支也被真实覆盖。
  if (withSaveFile) {
    attachments.saveFile = async (input) => {
      if (failSaveFile) throw new Error(failSaveFile)
      savedFiles.push(input)
      return {
        attachmentId: 'file_test',
        name: input.name,
        bytes: input.data.length,
      }
    }
  }
  const ctx = {
    tools: { register: (definition) => { ctx.tool = definition } },
    attachments,
    saved,
    savedFiles,
  }
  return ctx
}

/** 一份原图 + 一份内容不同的预览，用来区分"存的是哪一份字节"。 */
function fixturePreview() {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-'))
  const originalPath = join(directory, 'photo.png')
  const previewPath = join(directory, 'preview.jpg')
  const original = Buffer.from(`original-${'x'.repeat(64)}`)
  const preview = Buffer.from('preview-jpeg-bytes')
  writeFileSync(originalPath, original)
  writeFileSync(previewPath, preview)
  return { directory, originalPath, previewPath, original, preview }
}

/** Applies the plugin and returns the registered tool and its context. */
function register(options) {
  const ctx = host(options)
  apply(ctx)
  assert.ok(ctx.tool, 'apply() registered nothing')
  return { tool: ctx.tool, ctx }
}

test('exports a Cordis plugin shape', () => {
  assert.equal(name, 'tool-send-image')
  // `attachments` is what makes the picture reachable without a user message.
  assert.deepEqual(inject, ['tools', 'attachments'])
})

test('registers the send_image tool with every documented parameter', () => {
  const { tool } = register()
  assert.equal(tool.name, 'send_image')
  assert.equal(tool.parameters.type, 'object')
  assert.deepEqual(Object.keys(tool.parameters.properties).sort(), ['caption', 'clipboard', 'file', 'screenshot'])
  assert.equal(typeof tool.execute, 'function')
  // The description is what the model reads; an empty one makes the tool
  // undiscoverable even though it is registered.
  assert.ok(tool.description.length > 30)
  // And it has to say where the picture lands: a model that believes this is a
  // user message will describe it as one.
  assert.match(tool.description, /工具结果/)
})

test('declares an output schema, which the registry refuses to load without', () => {
  // Boot fails hard on a tool with no `output`, and a failed boot takes the
  // whole harness down — the desktop app then cannot start at all.
  const { tool } = register()
  assert.equal(tool.output.schema.type, 'object')
  assert.deepEqual(tool.output.schema.required, ['ok'])
  assert.deepEqual(
    Object.keys(tool.output.schema.properties).sort(),
    ['attachment', 'bytes', 'detail', 'error', 'ok', 'original', 'originalError', 'path'],
  )
  assert.equal(typeof tool.output.render, 'function')
})

test('the result carries the picture as an image block, not just words', () => {
  // This is the whole point: the reference rides on the tool result, so clients
  // draw it inside the agent's own turn. Putting it back into a prompt is what
  // turned it into a user message that started another turn.
  const { tool } = register()
  const attachment = { type: 'image', attachmentId: 'att_1', mediaType: 'image/png', bytes: 12 }
  assert.deepEqual(tool.output.render({}, { ok: true, attachment, detail: '已把图片放进这次回答的工具结果' }), [
    { type: 'image', attachment },
    { type: 'text', text: '已把图片放进这次回答的工具结果' },
  ])
  // A failure has no picture to draw.
  assert.deepEqual(tool.output.render({}, { ok: false, error: '需要 file、screenshot 或 clipboard 之一' }), [
    { type: 'text', text: '发送失败：需要 file、screenshot 或 clipboard 之一' },
  ])
})

test('render turns a result into model-facing text parts', () => {
  assert.equal(renderResult({ ok: true, detail: '已发送 3.4 KB' }), '已发送 3.4 KB')
  // A bare success still has to say something: an empty part reads as no result.
  assert.equal(renderResult({ ok: true }), '图片已发送。')
  assert.equal(renderResult({ ok: false }), '发送失败：未知原因')
})

test('resolveSource accepts exactly one source', () => {
  assert.deepEqual(resolveSource({ file: '/tmp/a.png' }), { ok: true, source: 'file' })
  assert.deepEqual(resolveSource({ screenshot: true }), { ok: true, source: 'screenshot' })
  assert.deepEqual(resolveSource({ clipboard: true }), { ok: true, source: 'clipboard' })
})

test('resolveSource refuses none', () => {
  const result = resolveSource({})
  assert.equal(result.ok, false)
  assert.match(result.error, /file.*screenshot.*clipboard/)
})

test('resolveSource refuses more than one', () => {
  // Silently picking one would send something the caller did not ask for.
  const result = resolveSource({ file: '/tmp/a.png', screenshot: true })
  assert.equal(result.ok, false)
  assert.match(result.error, /一次只能用一个来源/)
  assert.match(result.error, /file/)
  assert.match(result.error, /screenshot/)
})

test('resolveSource treats a blank file path as missing', () => {
  const result = resolveSource({ file: '   ' })
  assert.equal(result.ok, false)
})

test('buildArgs maps each source to its flag', () => {
  assert.deepEqual(buildArgs({ file: '/tmp/a.png' }, 'S'), ['S', '--file', '/tmp/a.png'])
  assert.deepEqual(buildArgs({ screenshot: true }, 'S'), ['S', '--screenshot'])
  assert.deepEqual(buildArgs({ clipboard: true }, 'S'), ['S', '--clipboard'])
})

test('buildArgs leaves the caption to the tool, not to the script', () => {
  // The script only prepares; the sentence travels in the result. Passing
  // `--caption` here would put it on the prompt path instead.
  assert.deepEqual(buildArgs({ file: 'a.png', caption: '渲染结果' }, 'S'), ['S', '--file', 'a.png'])
})

test('describeSend names the file, its size and the caption', () => {
  assert.equal(
    describeSend({ name: 'chart.png', bytes: 3481, mediaType: 'image/png' }, '渲染结果'),
    '已把图片放进这次回答的工具结果：渲染结果 — chart.png（3.4 KB，image/png）',
  )
  assert.match(describeSend({ name: 'a.png', bytes: 12, mediaType: 'image/png' }), /12 B/)
})

test('scriptPath finds the installed skill', () => {
  // This one only proves the script is reachable *from a repository checkout*
  // (candidate 3). An npm user has no `skills/` directory, so what actually
  // saves them is the copy inside the package — asserted separately below.
  const path = scriptPath()
  assert.ok(path, 'the send-image script was not found')
  assert.match(path, /send-image\.mjs$/)
})

test('the package ships its own copy of the capture script', () => {
  // The package's own copy is what an npm install runs; without it the plugin
  // installs fine and then fails at the first capture. `check:contracts` keeps
  // it byte-identical to the canonical copy under `skills/`.
  const inPackage = fileURLToPath(new URL('../lib/send-image.mjs', import.meta.url))
  assert.ok(existsSync(inPackage), `the package must ship ${inPackage}`)
  assert.ok(readFileSync(inPackage, 'utf8').trim().length > 0, 'it must not be empty')
})

test('publish hands the bytes to the attachment service', async () => {
  const { directory, path, bytes } = fixturePng()
  const ctx = host()
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: { path, name: 'pixel.png', mediaType: 'image/png', bytes: bytes.length },
      caption: '一像素',
    })
    assert.equal(value.ok, true)
    assert.equal(value.attachment.attachmentId, 'att_test')
    assert.match(value.detail, /一像素/)
    assert.equal(ctx.saved.length, 1)
    assert.equal(ctx.saved[0].data.length, bytes.length)
    assert.equal(ctx.saved[0].mediaType, 'image/png')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('publish reports a refusal with the service reason', async () => {
  const { directory, path } = fixturePng()
  const ctx = host({ failWith: 'image exceeds 20971520 bytes' })
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: { path, name: 'pixel.png', mediaType: 'image/png', bytes: 68 },
    })
    assert.equal(value.ok, false)
    assert.match(value.error, /Host 拒绝了这张图片/)
    assert.match(value.error, /20971520/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('publish refuses a prepared descriptor it cannot use', async () => {
  const ctx = host()
  assert.equal((await publish({ attachments: ctx.attachments, prepared: null })).ok, false)
  const missing = await publish({
    attachments: ctx.attachments,
    prepared: { path: '/definitely/not/here.png', name: 'x.png', mediaType: 'image/png' },
  })
  assert.equal(missing.ok, false)
  assert.match(missing.error, /读不到准备好的图片/)
})

test('publish saves the preview bytes as the image and the original bytes as a file', async () => {
  const { directory, originalPath, previewPath, original, preview } = fixturePreview()
  const ctx = host({ withSaveFile: true })
  const home = join(directory, 'home-that-does-not-exist')
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: {
        path: originalPath,
        name: 'photo.png',
        mediaType: 'image/png',
        bytes: original.length,
        temporary: false,
        previewPath,
        previewBytes: preview.length,
        previewMediaType: 'image/jpeg',
        previewTemporary: true,
      },
      caption: '原图与预览',
      home,
      logger: { warn() {} },
    })

    assert.equal(value.ok, true, value.error)
    // 两处字节不能串：预览给 saveImage，原图给 saveFile。
    assert.deepEqual(ctx.saved[0].data, preview)
    assert.equal(ctx.saved[0].mediaType, 'image/jpeg')
    assert.equal(ctx.saved[0].name, 'photo.png')
    assert.deepEqual(ctx.savedFiles[0].data, original)
    assert.equal(ctx.savedFiles[0].name, 'photo.png')
    assert.equal(value.original.attachmentId, 'file_test')
    assert.match(value.detail, /原图已保存/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('publish appends one contract-shaped index line and creates the directory', async () => {
  const { directory, originalPath, previewPath, original, preview } = fixturePreview()
  const ctx = host({ withSaveFile: true })
  const home = join(directory, 'fresh-home')
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: {
        path: originalPath,
        name: 'photo.png',
        mediaType: 'image/png',
        bytes: original.length,
        previewPath,
        previewBytes: preview.length,
        previewMediaType: 'image/jpeg',
        previewTemporary: true,
      },
      home,
      logger: { warn() {} },
    })
    assert.equal(value.ok, true, value.error)

    const file = join(home, 'mobile-link', 'image-originals.jsonl')
    assert.ok(existsSync(file), '目录不存在时必须由写入端创建')
    const lines = readFileSync(file, 'utf8').trim().split('\n')
    assert.equal(lines.length, 1)
    const entry = JSON.parse(lines[0])
    const { savedAt, ...rest } = entry
    assert.deepEqual(rest, {
      v: 1,
      previewId: 'att_test',
      original: {
        attachmentId: 'file_test',
        name: 'photo.png',
        bytes: original.length,
        mediaType: 'image/png',
      },
      source: 'tool',
    })
    assert.equal(new Date(savedAt).toISOString(), savedAt, 'savedAt 必须是 ISO-8601')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('a saveFile failure still returns the preview and says the original is unavailable', async () => {
  const { directory, originalPath, previewPath, original, preview } = fixturePreview()
  const ctx = host({ withSaveFile: true, failSaveFile: 'disk full' })
  const home = join(directory, 'home')
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: {
        path: originalPath,
        name: 'photo.png',
        mediaType: 'image/png',
        bytes: original.length,
        previewPath,
        previewBytes: preview.length,
        previewMediaType: 'image/jpeg',
        previewTemporary: true,
      },
      home,
      logger: { warn() {} },
    })

    assert.equal(value.ok, true)
    assert.deepEqual(ctx.saved[0].data, preview, '原图存不进去也不能影响预览')
    assert.equal(value.original, undefined, '没有原图引用时不得伪造一个')
    assert.match(value.originalError, /disk full/)
    assert.match(value.detail, /原图不可用/)
    assert.equal(existsSync(join(home, 'mobile-link', 'image-originals.jsonl')), false,
      '没有原图可关联时不应写索引')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('an old host without saveFile still gets the preview and an explicit original error', async () => {
  const { directory, originalPath, previewPath, original, preview } = fixturePreview()
  const ctx = host()
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: {
        path: originalPath,
        name: 'photo.png',
        mediaType: 'image/png',
        bytes: original.length,
        previewPath,
        previewBytes: preview.length,
        previewMediaType: 'image/jpeg',
      },
    })
    assert.equal(value.ok, true)
    assert.equal(value.original, undefined)
    assert.match(value.originalError, /不支持保存原图/)
    assert.match(value.detail, /原图不可用/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('an index write failure never changes a successful send', async () => {
  const { directory, originalPath, previewPath, original, preview } = fixturePreview()
  const ctx = host({ withSaveFile: true })
  const home = join(directory, 'blocked-home')
  mkdirSync(home)
  // 把 `mobile-link` 做成普通文件，真实制造 mkdir/open 失败，而不是 mock 一个异常。
  writeFileSync(join(home, 'mobile-link'), 'not a directory')
  const warnings = []
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: {
        path: originalPath,
        name: 'photo.png',
        mediaType: 'image/png',
        bytes: original.length,
        previewPath,
        previewBytes: preview.length,
        previewMediaType: 'image/jpeg',
      },
      home,
      logger: { warn: (message) => warnings.push(message) },
    })
    assert.equal(value.ok, true)
    assert.equal(value.original.attachmentId, 'file_test')
    assert.equal(warnings.length, 1)
    assert.match(warnings[0], /image-originals append failed/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('a missing preview is refused instead of passing the original off as the preview', async () => {
  const { directory, originalPath, original } = fixturePreview()
  const ctx = host()
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: {
        path: originalPath,
        name: 'photo.png',
        mediaType: 'image/png',
        bytes: original.length,
        previewError: '无法生成预览：sips 失败',
      },
    })
    // 需求 SR-02.07 / SR-02.11：预览有明确口径（≤2560、≤400 万像素），
    // 生成不了就不能拿原图顶替；工具结果里也没有文件块形态，只能给可行动的错误。
    assert.equal(value.ok, false)
    assert.match(value.error, /无法预览这张图片/)
    assert.match(value.error, /请改用文件发送/)
    assert.equal(ctx.saved.length, 0, '一份附件都不该写')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('a legacy descriptor without preview fields still sends, with the old script named', async () => {
  const { directory, originalPath, original } = fixturePreview()
  const ctx = host()
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: {
        path: originalPath,
        name: 'photo.png',
        mediaType: 'image/png',
        bytes: original.length,
      },
    })
    // 旧描述符（没有 previewPath / previewError）：仍按旧行为把原图交给 Host 归一化，
    // 否则用户重装 skill 之前整条能力会失效；但文案必须说明脚本是旧的。
    assert.equal(value.ok, true, value.error)
    assert.deepEqual(ctx.saved[0].data, original)
    assert.match(value.detail, /旧版/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('a missing preview for an unsupported original is a readable file-send error', async () => {
  const { directory, originalPath, original } = fixturePreview()
  const ctx = host()
  try {
    const value = await publish({
      attachments: ctx.attachments,
      prepared: {
        path: originalPath,
        name: 'photo.bmp',
        bytes: original.length,
        previewError: '无法生成预览：不支持的图片格式 .bmp',
      },
    })
    assert.equal(value.ok, false)
    assert.match(value.error, /文件发送/)
    assert.equal(ctx.saved.length, 0)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('discardPrepared removes a temporary preview and keeps a --file source', () => {
  const { directory, originalPath, previewPath } = fixturePreview()
  try {
    discardPrepared({
      path: originalPath,
      temporary: false,
      previewPath,
      previewTemporary: true,
    })
    assert.doesNotThrow(() => readFileSync(originalPath), '源文件必须保留')
    assert.throws(() => readFileSync(previewPath), '临时预览应当清理')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('discardPrepared removes a capture and keeps a real file', () => {
  const { directory, path } = fixturePng()
  try {
    discardPrepared({ path, temporary: false })
    assert.doesNotThrow(() => readFileSync(path), 'a source file must survive')
    discardPrepared({ path, temporary: true })
    assert.throws(() => readFileSync(path), 'a capture should be cleaned up')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('execute prepares the image and publishes it, with no session involved',
  { skip: process.platform !== 'darwin' && 'sips is macOS-only' }, async () => {
  // The old version refused without a session id and then submitted a prompt
  // with it. Neither is needed now: the picture becomes an attachment and rides
  // on the tool result.
  const savedSession = process.env.DSH_SESSION_ID
  const savedHome = process.env.DSH_HOME
  const { directory, path, bytes } = fixturePng()
  delete process.env.DSH_SESSION_ID
  // Point the script lookup at the checkout instead of whatever is installed on
  // this machine, so the test measures this commit.
  process.env.DSH_HOME = join(directory, 'empty-home')
  try {
    const { tool, ctx } = register()
    const value = await tool.execute({ file: path, caption: '一像素' }, {})
    assert.equal(value.ok, true, value.error)
    assert.equal(ctx.saved[0].data.length, bytes.length)
    assert.equal(value.attachment.mediaType, 'image/png')
    const parts = tool.output.render({}, value)
    assert.equal(parts[0].type, 'image')
    assert.equal(parts[1].type, 'text')
  } finally {
    if (savedSession === undefined) delete process.env.DSH_SESSION_ID
    else process.env.DSH_SESSION_ID = savedSession
    if (savedHome === undefined) delete process.env.DSH_HOME
    else process.env.DSH_HOME = savedHome
    rmSync(directory, { recursive: true, force: true })
  }
})

test('execute refuses without a source before touching the script', async () => {
  const { tool } = register()
  const result = await tool.execute({}, {})
  assert.equal(result.ok, false)
  assert.match(result.error, /需要 file/)
})

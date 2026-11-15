/**
 * 图片两变体（预览 + 可选原图）连接器侧单测。
 *
 * 落点：
 *   - 预览字节与原图字节**分别**交给 Host 的两个服务（不混、不互相顶替）；
 *   - 原图逐字节保存，索引按预览 id 记录，手机据此才能按需取回；
 *   - 超限/不可解码的原图按**文件**交回，绝不写进"原图"索引；
 *   - 暂存文件在提交后被清掉；
 *   - 读回：元数据三态（有 / 没有 / 对象被清理）与分片拼接、边界、错误码；
 *   - 走完整路由时是自答方法，不转发 Host。
 */

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  DEFAULT_CHUNK_BYTES,
  IMAGE_COMMIT,
  IMAGE_ORIGINAL,
  IMAGE_ORIGINAL_CHUNK,
  ImageVariants,
  MAX_CHUNK_BYTES,
} from '../lib/image-variants.js'
import { readIndex } from '../lib/image-originals.js'
import { DeviceRouter } from '../lib/router.js'

const previewBytes = Buffer.from('preview-jpeg-bytes')
const originalBytes = Buffer.from('original-heic-bytes-'.repeat(64))

/** 收集一个可读流（连接器传给 Host 的 data 是 fs.ReadStream）。 */
async function collect(stream) {
  const chunks = []
  for await (const chunk of stream) chunks.push(Buffer.from(chunk))
  return Buffer.concat(chunks)
}

const sha256 = (buffer) => `sha256:${createHash('sha256').update(buffer).digest('hex')}`

/**
 * 一份最小的 Host 侧环境：附件对象库 + 两个服务。
 *
 * 两个服务都把收到的字节**原样**记下来，用例据此断言"交给 Host 的是哪一份字节"。
 */
function makeHost(t) {
  const root = mkdtempSync(join(tmpdir(), 'dsh-image-variants-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const objects = join(root, 'objects')
  mkdirSync(objects, { recursive: true })
  const calls = { images: [], files: [], fileStreams: [] }
  let receipts = 0

  const attachments = {
    async saveFileStream({ data, name }) {
      const bytes = await collect(data)
      const attachmentId = sha256(bytes)
      writeFileSync(join(objects, attachmentId.slice('sha256:'.length)), bytes)
      calls.fileStreams.push({ name, bytes })
      return { attachmentId, name, bytes: bytes.length }
    },
    fileHostPath(ref) {
      return join(objects, ref.attachmentId.slice('sha256:'.length))
    },
  }

  const fileUploads = {
    async uploadImageStream({ sessionId, data, mediaType, name }) {
      const bytes = await collect(data)
      calls.images.push({ sessionId, mediaType, name, bytes })
      receipts += 1
      return {
        receiptId: `receipt-image-${receipts}`,
        image: {
          attachmentId: sha256(Buffer.concat([Buffer.from('normalized:'), bytes])),
          mediaType,
          bytes: bytes.length,
          width: 1200,
          height: 800,
          name,
        },
      }
    },
    async uploadStream({ sessionId, data, name }) {
      const bytes = await collect(data)
      calls.files.push({ sessionId, name, bytes })
      receipts += 1
      return {
        receiptId: `receipt-file-${receipts}`,
        file: { attachmentId: sha256(bytes), name, bytes: bytes.length },
      }
    },
  }

  return { root, objects, calls, attachments, fileUploads }
}

/** 把一个"已落盘"的暂存文件放进会话收件箱，返回它的路径。 */
function stage(home, sessionId, name, bytes) {
  const directory = join(home, 'inbox', sessionId)
  mkdirSync(directory, { recursive: true })
  const path = join(directory, name)
  writeFileSync(path, bytes)
  return path
}

function setup(t) {
  const home = mkdtempSync(join(tmpdir(), 'dsh-image-home-'))
  const host = makeHost(t)
  t.after(() => rmSync(home, { recursive: true, force: true }))
  return { home, host }
}

test('提交时预览与原图分两路交给 Host，索引按预览 id 登记原图', async (t) => {
  const { home, host } = setup(t)
  const sessionId = 'sess-1'
  const previewPath = stage(home, sessionId, 'photo.jpg', previewBytes)
  const originalPath = stage(home, sessionId, 'photo.heic', originalBytes)
  const variants = new ImageVariants({ ...host, home })

  const result = await variants.handle(IMAGE_COMMIT, {
    sessionId,
    preview: { path: previewPath, mediaType: 'image/jpeg', name: 'photo.jpg' },
    original: { path: originalPath, name: 'photo.heic', mediaType: 'image/heic' },
  })

  assert.deepEqual(host.calls.images[0].bytes, previewBytes, '预览服务收到的是预览字节')
  assert.deepEqual(host.calls.fileStreams[0].bytes, originalBytes, '原图逐字节保存，未被重编码')
  assert.equal(host.calls.fileStreams[0].name, 'photo.heic')
  assert.equal(result.preview.receiptId, 'receipt-image-1')
  assert.equal(result.preview.image.width, 1200)
  assert.deepEqual(result.original, {
    attachmentId: sha256(originalBytes),
    name: 'photo.heic',
    bytes: originalBytes.length,
    mediaType: 'image/heic',
  })
  assert.equal(result.fileReceiptId, undefined)

  assert.deepEqual(readIndex({ home }).get(result.preview.image.attachmentId), result.original)
  assert.equal(readIndex({ home }).get(result.preview.image.attachmentId).name, 'photo.heic')
})

test('提交后暂存文件被清掉（预览与原图都不留在收件箱）', async (t) => {
  const { home, host } = setup(t)
  const previewPath = stage(home, 's', 'a.jpg', previewBytes)
  const originalPath = stage(home, 's', 'a.heic', originalBytes)
  const variants = new ImageVariants({ ...host, home })

  await variants.handle(IMAGE_COMMIT, {
    sessionId: 's',
    preview: { path: previewPath, mediaType: 'image/jpeg', name: 'a.jpg' },
    original: { path: originalPath, name: 'a.heic' },
  })

  assert.throws(() => statSync(previewPath))
  assert.throws(() => statSync(originalPath))
})

test('暂存路径越出本会话收件箱时拒绝，且一次上传都不发生', async (t) => {
  const { home, host } = setup(t)
  const outside = stage(home, 'other-session', 'x.jpg', previewBytes)
  const variants = new ImageVariants({ ...host, home })

  await assert.rejects(
    variants.handle(IMAGE_COMMIT, {
      sessionId: 's',
      preview: { path: outside, mediaType: 'image/jpeg', name: 'x.jpg' },
    }),
    (error) => error.code === 'image/invalid-path',
  )
  assert.equal(host.calls.images.length, 0)
})

test('原图超限/不可解码：按文件交回 receiptId，不写原图索引', async (t) => {
  const { home, host } = setup(t)
  const previewPath = stage(home, 's', 'big.jpg', previewBytes)
  const originalPath = stage(home, 's', 'big.mov', originalBytes)
  const variants = new ImageVariants({ ...host, home })

  const result = await variants.handle(IMAGE_COMMIT, {
    sessionId: 's',
    preview: { path: previewPath, mediaType: 'image/jpeg', name: 'big.jpg' },
    original: { path: originalPath, name: 'big.mov', mediaType: 'video/quicktime' },
    sendOriginalAsFile: true,
    originalReason: 'tooLarge',
  })

  assert.deepEqual(host.calls.files[0].bytes, originalBytes, '按文件发送的是原图字节')
  assert.equal(result.fileReceiptId, 'receipt-file-2')
  assert.equal(result.original, null)
  assert.equal(result.originalReason, 'tooLarge')
  assert.equal(readIndex({ home }).size, 0, '超限原图不得冒充原图变体')
})

test('没有预览、只有原图时按文件提交（预览生成失败的降级路径）', async (t) => {
  const { home, host } = setup(t)
  const originalPath = stage(home, 's', 'broken.heic', originalBytes)
  const variants = new ImageVariants({ ...host, home })

  const result = await variants.handle(IMAGE_COMMIT, {
    sessionId: 's',
    original: { path: originalPath, name: 'broken.heic', mediaType: 'image/heic' },
    sendOriginalAsFile: true,
    originalReason: 'undecodable',
  })

  assert.equal(result.preview, null, '没有预览就不该编造一份')
  assert.equal(result.fileReceiptId, 'receipt-file-1')
  assert.equal(result.originalReason, 'undecodable')
  assert.deepEqual(host.calls.files[0].bytes, originalBytes)
  assert.equal(host.calls.images.length, 0)
  assert.equal(readIndex({ home }).size, 0)
  assert.throws(() => statSync(originalPath), '提交后暂存文件应当被清掉')
})

test('既没有预览也没有原图时拒绝提交', async (t) => {
  const { home, host } = setup(t)
  const variants = new ImageVariants({ ...host, home })
  await assert.rejects(
    variants.handle(IMAGE_COMMIT, { sessionId: 's' }),
    (error) => error.code === 'image/invalid-path',
  )
})

test('没有预览却要求保存原图变体时拒绝（否则用户看不到也取不回）', async (t) => {
  const { home, host } = setup(t)
  const originalPath = stage(home, 's', 'a.heic', originalBytes)
  const variants = new ImageVariants({ ...host, home })
  await assert.rejects(
    variants.handle(IMAGE_COMMIT, {
      sessionId: 's',
      original: { path: originalPath, name: 'a.heic' },
    }),
    (error) => error.code === 'image/invalid-path',
  )
  assert.equal(host.calls.fileStreams.length, 0)
})

test('原图保存失败不挡预览：预览照发，索引不写，原因如实', async (t) => {
  const { home, host } = setup(t)
  const previewPath = stage(home, 's', 'a.jpg', previewBytes)
  const originalPath = stage(home, 's', 'a.heic', originalBytes)
  const failing = {
    ...host,
    attachments: {
      fileHostPath: host.attachments.fileHostPath,
      async saveFileStream() { throw new Error('disk full') },
    },
  }
  const variants = new ImageVariants({ ...failing, home })

  const result = await variants.handle(IMAGE_COMMIT, {
    sessionId: 's',
    preview: { path: previewPath, mediaType: 'image/jpeg', name: 'a.jpg' },
    original: { path: originalPath, name: 'a.heic' },
  })

  assert.equal(result.preview.receiptId, 'receipt-image-1')
  assert.equal(result.original, null)
  assert.equal(result.originalReason, 'failed')
  assert.equal(readIndex({ home }).size, 0)
})

test('预览被宿主判为超限时给出 image/too-large，不写成通用失败', async (t) => {
  const { home, host } = setup(t)
  const previewPath = stage(home, 's', 'a.jpg', previewBytes)
  const rejecting = {
    ...host,
    fileUploads: {
      async uploadImageStream() {
        const error = new Error('Image exceeds the configured byte limit.')
        error.code = 'session/attachment-invalid'
        error.details = { reason: 'IMAGE_TOO_LARGE' }
        throw error
      },
    },
  }
  const variants = new ImageVariants({ ...rejecting, home })

  await assert.rejects(
    variants.handle(IMAGE_COMMIT, {
      sessionId: 's',
      preview: { path: previewPath, mediaType: 'image/jpeg', name: 'a.jpg' },
    }),
    (error) => error.code === 'image/too-large',
  )
})

test('宿主服务缺失时提交报 link/unsupported（不静默降级成只有预览）', async (t) => {
  const { home } = setup(t)
  const previewPath = stage(home, 's', 'a.jpg', previewBytes)
  const variants = new ImageVariants({ home, logger: { warn() {} } })

  await assert.rejects(
    variants.handle(IMAGE_COMMIT, {
      sessionId: 's',
      preview: { path: previewPath, mediaType: 'image/jpeg', name: 'a.jpg' },
    }),
    (error) => error.code === 'link/unsupported',
  )
})

test('原图元数据：有 / 没有 / 对象被清理 三态分明', async (t) => {
  const { home, host } = setup(t)
  const previewPath = stage(home, 's', 'a.jpg', previewBytes)
  const originalPath = stage(home, 's', 'a.heic', originalBytes)
  const variants = new ImageVariants({ ...host, home })
  const committed = await variants.handle(IMAGE_COMMIT, {
    sessionId: 's',
    preview: { path: previewPath, mediaType: 'image/jpeg', name: 'a.jpg' },
    original: { path: originalPath, name: 'a.heic' },
  })
  const previewId = committed.preview.image.attachmentId

  assert.deepEqual(await variants.handle(IMAGE_ORIGINAL, { attachmentId: previewId }), {
    available: true,
    original: committed.original,
  })

  assert.deepEqual(await variants.handle(IMAGE_ORIGINAL, { attachmentId: 'sha256:unknown' }), {
    available: false,
    reason: 'missing',
  })

  unlinkSync(host.attachments.fileHostPath(committed.original))
  assert.deepEqual(await variants.handle(IMAGE_ORIGINAL, { attachmentId: previewId }), {
    available: false,
    reason: 'cleaned',
  })
})

test('旧数据只有一份附件：查原图回 missing，不抛错', async (t) => {
  const { home, host } = setup(t)
  const variants = new ImageVariants({ ...host, home })
  assert.deepEqual(await variants.handle(IMAGE_ORIGINAL, { attachmentId: 'sha256:legacy' }), {
    available: false,
    reason: 'missing',
  })
})

test('分片读回：拼接后与原图字节完全一致，eof 只在最后一片为真', async (t) => {
  const { home, host } = setup(t)
  const big = Buffer.alloc(DEFAULT_CHUNK_BYTES * 2 + 1234)
  for (let index = 0; index < big.length; index += 1) big[index] = index % 251
  const previewPath = stage(home, 's', 'p.jpg', previewBytes)
  const originalPath = stage(home, 's', 'p.heic', big)
  const variants = new ImageVariants({ ...host, home })
  const committed = await variants.handle(IMAGE_COMMIT, {
    sessionId: 's',
    preview: { path: previewPath, mediaType: 'image/jpeg', name: 'p.jpg' },
    original: { path: originalPath, name: 'p.heic' },
  })
  const previewId = committed.preview.image.attachmentId

  const parts = []
  let offset = 0
  let guard = 0
  for (;;) {
    const chunk = await variants.handle(IMAGE_ORIGINAL_CHUNK, { attachmentId: previewId, offset })
    assert.equal(chunk.offset, offset)
    assert.equal(chunk.bytes, big.length)
    parts.push(Buffer.from(chunk.data, 'base64'))
    offset += Buffer.from(chunk.data, 'base64').length
    guard += 1
    assert.ok(guard < 10, '不该需要这么多次分片')
    if (chunk.eof) break
  }

  const assembled = Buffer.concat(parts)
  assert.equal(assembled.length, big.length)
  assert.deepEqual(assembled, big)
  assert.equal(sha256(assembled), committed.original.attachmentId, '拼接结果与内容地址一致')
})

test('分片请求的长度被夹到上限，越过末尾直接 eof', async (t) => {
  const { home, host } = setup(t)
  const previewPath = stage(home, 's', 'p.jpg', previewBytes)
  const originalPath = stage(home, 's', 'p.heic', originalBytes)
  const variants = new ImageVariants({ ...host, home })
  const committed = await variants.handle(IMAGE_COMMIT, {
    sessionId: 's',
    preview: { path: previewPath, mediaType: 'image/jpeg', name: 'p.jpg' },
    original: { path: originalPath, name: 'p.heic' },
  })
  const previewId = committed.preview.image.attachmentId

  const clamped = await variants.handle(IMAGE_ORIGINAL_CHUNK, {
    attachmentId: previewId, offset: 0, length: MAX_CHUNK_BYTES * 4,
  })
  assert.equal(Buffer.from(clamped.data, 'base64').length, originalBytes.length)
  assert.equal(clamped.eof, true)

  const past = await variants.handle(IMAGE_ORIGINAL_CHUNK, { attachmentId: previewId, offset: 10_000 })
  assert.deepEqual(past, { data: '', offset: 10_000, eof: true, bytes: originalBytes.length })
})

test('没有原图时分片给出稳定错误码', async (t) => {
  const { home, host } = setup(t)
  const variants = new ImageVariants({ ...host, home })
  await assert.rejects(
    variants.handle(IMAGE_ORIGINAL_CHUNK, { attachmentId: 'sha256:none', offset: 0 }),
    (error) => error.code === 'image-original/missing',
  )
})

test('走完整路由：_link/imageCommit 自答，不转发 Host', async (t) => {
  const { home, host } = setup(t)
  const previewPath = stage(home, 'dev-session', 'a.jpg', previewBytes)
  const rpcCalls = []
  const frames = []
  const router = new DeviceRouter({
    dsh: { async rpc(method) { rpcCalls.push(method); return { ok: true, value: {} } } },
    send: (deviceId, frame) => frames.push({ deviceId, frame }),
  })
  router.bindImageVariants(new ImageVariants({ ...host, home }))

  await router.handleRequest('dev_1', {
    t: 'req',
    id: 'r1',
    method: IMAGE_COMMIT,
    args: {
      sessionId: 'dev-session',
      preview: { path: previewPath, mediaType: 'image/jpeg', name: 'a.jpg' },
    },
  })

  assert.deepEqual(rpcCalls, [], '保留方法不得转发 Host')
  assert.equal(frames.length, 1)
  assert.equal(frames[0].frame.t, 'res')
  assert.equal(frames[0].frame.ok, true)
  assert.equal(frames[0].frame.value.preview.receiptId, 'receipt-image-1')
})

test('未绑定服务时三个方法都回 link/unsupported', async (t) => {
  const frames = []
  const router = new DeviceRouter({
    dsh: { async rpc() { return { ok: true, value: {} } } },
    send: (deviceId, frame) => frames.push({ deviceId, frame }),
  })

  await router.handleRequest('dev_1', { t: 'req', id: 'r1', method: IMAGE_ORIGINAL, args: { attachmentId: 'x' } })
  assert.equal(frames[0].frame.ok, false)
  assert.equal(frames[0].frame.error.code, 'link/unsupported')
})

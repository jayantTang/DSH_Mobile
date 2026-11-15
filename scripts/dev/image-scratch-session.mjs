#!/usr/bin/env node
/**
 * Creates a throwaway session whose **last message is a picture**, and prints
 * its id.
 *
 * Why: a case about the image placeholder ("加载失败 → 点按重试") needs the
 * picture to be *on screen when the transcript opens*. A transcript opens at the
 * bottom, so in any working session the pictures are screens away — the first
 * version of TC-MOB-25 scrolled up six screens and still found none. Here the
 * picture is the last thing in a session of its own, so the case needs no
 * scrolling and no luck.
 *
 * The image is sent as a prompt attachment — the path a user's own picture takes
 * — and the agent turn it starts is cancelled immediately: the picture stays,
 * and no model tokens are spent on a reply nobody reads.
 *
 * Usage:
 *   node scripts/dev/image-scratch-session.mjs [--dir /tmp/dsh-uitest-image]
 *   node scripts/dev/image-scratch-session.mjs --with-original [--file <图片>]
 *       # 同时按生产落盘契约登记一份原图（「查看原图/保存原图」用例的夹具）
 *   # then: 会话: <printed id>  in test/acceptance/*.md
 *   node scripts/dev/image-scratch-session.mjs --cleanup <sessionId>
 */

import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, appendFileSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HOME = homedir()
const ENDPOINT = join(HOME, '.dsh', 'mobile-link', 'endpoint.json')
const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

function endpoint() {
  const raw = JSON.parse(readFileSync(ENDPOINT, 'utf8'))
  const token = /token=([^&]+)/.exec(raw.url)?.[1]
  if (!raw.port || !token) throw new Error('endpoint.json 里没有 port/token，什么都做不了')
  return { port: raw.port, token }
}

async function host() {
  const { port, token } = endpoint()
  const exchange = await fetch(`http://127.0.0.1:${port}/?token=${token}`, { redirect: 'manual' })
  const cookie = (exchange.headers.getSetCookie?.() ?? [])[0]?.split(';')[0]
  let seq = 0
  const call = async (method, args) => {
    const response = await fetch(`http://127.0.0.1:${port}/api/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', cookie },
      body: JSON.stringify({ type: 'client-request', rpcId: `img${++seq}`, method, payload: { args } }),
    })
    const body = await response.json()
    if (!body.result?.ok) throw new Error(`${method}: ${JSON.stringify(body.result?.error)}`)
    return body.result.value
  }
  return { call }
}

const args = process.argv.slice(2)

if (args.includes('--cleanup')) {
  const sessionId = args[args.indexOf('--cleanup') + 1]
  if (!sessionId) throw new Error('--cleanup 需要会话 id')
  for (const directory of readdirSync(join(HOME, '.dsh', 'sessions'))) {
    rmSync(join(HOME, '.dsh', 'sessions', directory, sessionId), { recursive: true, force: true })
  }
  rmSync(join(HOME, '.dsh', 'storages', 'session_projcache', 'sessions', `${sessionId}.json`), { force: true })
  console.log(`已删除 ${sessionId}`)
  process.exit(0)
}

/**
 * 顺手给这张图登记一份**原图变体**（`--with-original`）。
 *
 * 为什么需要：SR-02.11 的界面用例（「查看原图 / 保存原图」）要一张**有原图**的
 * 夹具。生产里这份关联由连接器的 `_link/imageCommit` 或 send_image 插件写；这里
 * 用**同一条落盘契约**（对象库 + image-originals.jsonl）直接登记，这样用例可复现，
 * 而读路径（`_link/imageOriginal*`、分片、SHA-256 校验）仍然是产品代码。
 *
 * 写入的是什么：原文件的**原始字节**（与 send_image 的 `saveFile` 同一语义），
 * 对象名就是它的 sha256；预览 id 用 Host 归一化后的那个附件 id。
 */
async function registerOriginal(call, sessionId, file, bytes) {
  const list = await call('session/list', { _request: {} })
  const row = list.items?.find((item) => item.sessionId === sessionId)
  const throughSeq = row?.projections?.asOfSeq ?? 0
  if (!throughSeq) throw new Error('会话还没有可用的事件游标，无法读取刚发的图片')
  const page = await call('session/page', {
    request: { address: { kind: 'session', sessionId }, throughSeq, maxMessages: 40 },
  })
  let preview = null
  const walk = (blocks) => {
    for (const block of blocks ?? []) {
      if (preview) return
      if (block?.type === 'image' && block.attachment?.attachmentId) preview = block.attachment
      if (block?.content) walk(block.content)
    }
  }
  for (const record of page.records ?? []) {
    const data = record.event?.data
    walk(data?.content)
    walk(data?.message?.content)
    walk(data?.inserted)
  }
  if (!preview) throw new Error('刚发的图片没有出现在会话里，无法登记原图')

  const sha256 = createHash('sha256').update(bytes).digest('hex')
  const name = file.split('/').pop()
  // 逐字节文件的落盘布局与图像不同（dsh-attachment-local 的 file-store）：
  //   v1/file-objects/<sha2>/<sha>           规范对象
  //   v1/files/<sha2>/<sha>/<name>           同一份字节的显示名别名
  // `fileHostPath` 返回的是**别名**路径，少写一层就会按「原图已被清理」处理。
  const attachmentRoot = join(HOME, '.dsh', 'attachments', 'v1')
  const objectPath = join(attachmentRoot, 'file-objects', sha256.slice(0, 2), sha256)
  mkdirSync(dirname(objectPath), { recursive: true, mode: 0o700 })
  // 内容寻址：同一个摘要已经存在就复用（对象库里的文件是只读的，重写会 EACCES）。
  if (!existsSync(objectPath)) writeFileSync(objectPath, bytes, { mode: 0o600 })
  const aliasPath = join(attachmentRoot, 'files', sha256.slice(0, 2), sha256, name)
  mkdirSync(dirname(aliasPath), { recursive: true, mode: 0o700 })
  if (!existsSync(aliasPath)) writeFileSync(aliasPath, bytes, { mode: 0o600 })

  const indexPath = join(HOME, '.dsh', 'mobile-link', 'image-originals.jsonl')
  mkdirSync(join(HOME, '.dsh', 'mobile-link'), { recursive: true, mode: 0o700 })
  const entry = {
    v: 1,
    previewId: preview.attachmentId,
    original: {
      attachmentId: `sha256:${sha256}`,
      name,
      bytes: bytes.length,
      mediaType: preview.mediaType,
    },
    savedAt: new Date().toISOString(),
    source: 'composer',
  }
  appendFileSync(indexPath, `${JSON.stringify(entry)}\n`, { mode: 0o600 })
  return { previewId: preview.attachmentId, originalId: entry.original.attachmentId, bytes: bytes.length }
}

const dirAt = args.indexOf('--dir')
const directory = dirAt >= 0 ? args[dirAt + 1] : '/tmp/dsh-uitest-image'
const fileAt = args.indexOf('--file')
const file = fileAt >= 0 ? args[fileAt + 1] : join(REPO, 'test', 'fixtures', 'sample-image.png')

const { call } = await host()
const created = await call('session/create', { request: { cwd: directory, agentPreset: 'standard' } })

const bytes = readFileSync(file)
await call('session/prompt', {
  request: {
    requestId: `image-${Date.now()}`,
    sessionId: created.sessionId,
    mode: 'queue',
    clientTimeZone: 'Asia/Shanghai',
    content: [
      { type: 'text', text: '（这条会话只放一张图片，用来验图片占位的重试）' },
      { type: 'image', mediaType: 'image/png', data: bytes.toString('base64'), name: file.split('/').pop() },
    ],
  },
})
// Cancel the turn the prompt started: the picture is already stored, and a reply
// would only push it off the bottom of the transcript.
await call('session/cancel', { request: { sessionId: created.sessionId } }).catch(() => {})

if (args.includes('--with-original')) {
  const registered = await registerOriginal(call, created.sessionId, file, bytes)
  console.log(`已登记原图：预览 ${registered.previewId} → 原图 ${registered.originalId}（${registered.bytes} 字节）`)
}

console.log(created.sessionId)
console.log(`图片会话就绪（用完：node scripts/dev/image-scratch-session.mjs --cleanup ${created.sessionId}）`)

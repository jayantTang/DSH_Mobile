#!/usr/bin/env node
/**
 * Prepare one image to be shown in the conversation.
 *
 * **Default mode is "prepare only"**: it captures or resolves the picture,
 * checks what the Host would refuse anyway, and prints a JSON descriptor on
 * stdout. The caller — the `send_image` tool in `plugins/send-image` — hands the
 * bytes to the Host's attachment service (`ctx.attachments.saveImage`) and puts
 * the resulting reference into its **tool result**, where every client renders
 * it inside the agent's own turn.
 *
 * Why not submit it as a prompt, which is what this script used to do: a prompt
 * is a *user message*. The picture therefore appeared as if the user had sent
 * it, and — worse — it started a new turn, so the agent answered its own
 * screenshot. `--via-prompt` keeps that path for a harness whose client cannot
 * render tool-result images; it is opt-in for exactly that reason.
 *
 * Usage:
 *   send-image.mjs --file <path>        # print {path, mediaType, bytes, name, previewPath?}
 *   send-image.mjs --screenshot
 *   send-image.mjs --clipboard
 *   send-image.mjs --file <path> --via-prompt [--caption "..."]
 *
 * Environment:
 *   DSH_SESSION_ID  the session to send into (only needed with --via-prompt)
 *   DSH_HOME        the harness home, for the endpoint file
 */

import { execFileSync } from 'node:child_process'
import { copyFileSync, readFileSync, statSync, unlinkSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { extname, join, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'

/**
 * Prefix that marks a prompt as the agent's own, not the user's.
 *
 * A picture can only enter a conversation as a prompt, and a prompt is always
 * attributed to the user — so the sender has to be carried somewhere. It rides
 * on the request id: the Host stores the id verbatim, and no client renders it,
 * unlike the caption (where an invisible character and then a camera glyph both
 * turned out to be visible) or the file name (which some clients label).
 */
const AGENT_REQUEST_PREFIX = 'agent-'

const MEDIA_TYPES = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
}

/**
 * Refuse anything the Host would reject anyway, with a clearer message.
 *
 * Matches the configured `maxImageBytes` on this host (20 MB). Sending a larger
 * file is not harmless: the Host refuses the whole prompt, so the user gets a
 * failed turn instead of an error they can act on.
 */
const MAX_BYTES = 20 * 1024 * 1024

/**
 * 预览的上限：最长边 2560、总像素 400 万，JPEG 质量 85。
 *
 * 与 iOS 侧生成预览的口径一致（契约 §2.2）：手机和电脑各生成一次预览时，
 * 同一个原图不应因平台不同而得到两种清晰度。超过上限的图若原样交给 Host，
 * 归一化也会降采样，但会先整份上传；这里先在本地缩到该口径，减少手机下载量。
 */
const PREVIEW_MAX_EDGE = 2560
const PREVIEW_MAX_PIXELS = 4_000_000
const PREVIEW_JPEG_QUALITY = 85

/** 默认依赖：测试可替换，CLI 行为不变。 */
const PREVIEW_DEPS = { execFileSync, statSync, copyFileSync, unlinkSync }

function parseArgs(argv) {
  const args = { caption: '', screenshots: 0 }
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i]
    switch (token) {
      case '--file': args.file = argv[++i]; break
      case '--caption': args.caption = argv[++i] ?? ''; break
      case '--screenshot': args.screenshot = true; args.screenshots += 1; break
      case '--clipboard': args.clipboard = true; break
      case '--via-prompt': args.viaPrompt = true; break
      case '--help': args.help = true; break
      default:
        if (!args.file && !token.startsWith('--')) args.file = token
        break
    }
  }
  return args
}

function usage() {
  console.log(`send-image — 准备一张图片给当前会话（默认只准备，不发送）

  --file <路径>      使用指定图片
  --screenshot      截取整屏（可重复，多次则连续截取）
  --clipboard       使用剪贴板里的图片
  --caption <文本>   仅配合 --via-prompt
  --via-prompt      直接把图片作为 prompt 提交（旧路径：它会以「用户消息」的身份
                    出现并触发新一轮回答，只在客户端无法渲染工具结果图片时使用）

默认输出一行 JSON：{path, name, mediaType, bytes, temporary, previewPath?, previewBytes?}，
调用方（send_image 工具）据此把预览与原图存成附件、放进工具结果。
预览不可生成时给出 previewError，原图描述符仍然有效（调用方回退到原图或按文件发送）。`)
}

/**
 * The live DSH endpoint and its launch token.
 *
 * One source: the connector writes `$DSH_HOME/mobile-link/endpoint.json` with the
 * authenticated loopback address, in every supported host (official desktop app and
 * command-line web host). The handoff our old self-built shell used is gone with it
 * — see specs/001-connector-host-compat/.
 */
function endpoint() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  const handoff = join(home, 'mobile-link', 'endpoint.json')
  try {
    const raw = JSON.parse(readFileSync(handoff, 'utf8'))
    const url = new URL(raw.url)
    const token = url.searchParams.get('token')
    const port = url.port || raw.port
    if (token && port) return { base: `http://127.0.0.1:${port}`, token }
  } catch {
    /* fall through to the actionable error below */
  }
  throw new Error(
    `找不到运行中的 DSH：${handoff} 不存在。请确认宿主（官方桌面版或 \`dsh web\`）正在运行、`
    + '且连接器已加载——这份交接文件由连接器写出。',
  )
}

class Client {
  #base
  #cookie
  #counter = 0

  constructor(base) {
    this.#base = base
  }

  /** The launch token trades for a session cookie, which the API expects. */
  async authenticate(token) {
    const response = await fetch(`${this.#base}/?token=${encodeURIComponent(token)}`, {
      redirect: 'manual',
    })
    const header = response.headers.getSetCookie?.()[0] ?? response.headers.get('set-cookie')
    if (!header) throw new Error('换取会话 cookie 失败：DSH 可能已重启，令牌已轮换')
    this.#cookie = header.split(';')[0]
  }

  async call(method, args) {
    const response = await fetch(`${this.#base}/api/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', cookie: this.#cookie },
      body: JSON.stringify({
        type: 'client-request',
        rpcId: `img${++this.#counter}`,
        method,
        payload: { args },
      }),
    })
    const body = await response.json()
    if (!body?.result?.ok) {
      throw new Error(`${method} 失败: ${JSON.stringify(body?.result?.error ?? body)}`)
    }
    return body.result.value
  }
}

/**
 * Turn `screencapture`'s opaque failure into the one thing the user can act on.
 *
 * "could not create image from display" means the Screen Recording grant is
 * missing *for this process*. Two causes cover almost every case: the grant
 * was made after this launch (macOS only hands a fresh grant to a process
 * started afterwards), or the app was rebuilt with an ad-hoc signature so the
 * grant no longer matches its code identity. Retrying cannot fix either one —
 * the app has to be reopened — so the message says that instead of echoing
 * stderr.
 *
 * Exported for testing: this string is the whole user-facing recovery path.
 */
export function explainCaptureFailure(error) {
  const stderr = String(error?.stderr ?? '').trim()
  if (/could not create image from display|not authorized|denied|declined/i.test(stderr)) {
    return (
      '屏幕录制权限没有生效。在「系统设置 → 隐私与安全性 → 屏幕录制」里勾选运行 DSH 的那个程序'
      + '（官方桌面版是「DeepSeek Harness」），然后完全退出并重新打开它 —— '
      + 'macOS 只把权限交给重新启动后的进程。' +
      `（原始错误：${stderr || 'screencapture 失败'}）`
    )
  }
  return `截屏失败：${stderr || error?.message || 'screencapture 失败'}`
}

/** Capture the screen, or pull an image off the clipboard. */
function capture(kind) {
  const out = join(tmpdir(), `dsh-image-${randomUUID()}.png`)
  if (kind === 'clipboard') {
    // `-c` reads the clipboard; when it holds no image the file is never made.
    execFileSync('pngpaste', [out], { stdio: 'ignore' })
    return out
  }
  try {
    execFileSync('screencapture', ['-x', out], { stdio: ['ignore', 'ignore', 'pipe'] })
  } catch (error) {
    throw new Error(explainCaptureFailure(error))
  }
  return out
}

function loadImage(args) {
  if (args.clipboard) {
    try {
      return { path: capture('clipboard'), temporary: true }
    } catch {
      throw new Error('剪贴板里没有图片（需要安装 pngpaste：brew install pngpaste）')
    }
  }
  if (args.screenshot) {
    return { path: capture('screenshot'), temporary: true }
  }
  if (!args.file) throw new Error('需要 --file、--screenshot 或 --clipboard 之一')
  return { path: resolve(args.file), temporary: false }
}

/**
 * 从 `sips -g pixelWidth -g pixelHeight` 的输出里取尺寸。
 *
 * sips 会先打印文件路径再逐行打印属性；只认这两个键，别解析整段文本，
 * 路径里出现 "pixelWidth" 也不会误读。解析不出就返回 null，由调用方给
 * previewError，而不是猜一个尺寸去缩放。
 */
export function parsePixelSize(stdout) {
  const text = String(stdout ?? '')
  const width = /(?:^|\s)pixelWidth:\s*(\d+)/.exec(text)?.[1]
  const height = /(?:^|\s)pixelHeight:\s*(\d+)/.exec(text)?.[1]
  if (!width || !height) return null
  const parsed = { width: Number(width), height: Number(height) }
  if (!Number.isFinite(parsed.width) || !Number.isFinite(parsed.height)) return null
  if (parsed.width <= 0 || parsed.height <= 0) return null
  return parsed
}

/** 是否需要交给 sips 缩到预览口径；小图不缩放，避免无谓的重编码。 */
export function needsPreviewResize({ width, height }) {
  return Math.max(width, height) > previewTargetEdge({ width, height })
}

/**
 * 预览的目标最长边：同时满足「最长边 ≤ 2560」与「总像素 ≤ 400 万」。
 *
 * 为什么不能只写 `-Z 2560`：那一条只约束最长边，4:3 的 4000×3000 会得到
 * 2560×1920（约 490 万像素），超过预览的像素上限。等比例缩放下
 * `像素 = 长边² / 长宽比`，反解长边上限后与 2560 取小，才是两个上限同时成立的值。
 */
export function previewTargetEdge({ width, height }) {
  const long = Math.max(width, height)
  const short = Math.min(width, height)
  if (long <= 0 || short <= 0) return 1
  const aspect = long / short
  const pixelEdge = Math.floor(Math.sqrt(PREVIEW_MAX_PIXELS * aspect))
  return Math.max(1, Math.min(PREVIEW_MAX_EDGE, pixelEdge))
}

/**
 * 生成预览文件，返回 `{ok:true, path, bytes, mediaType, temporary}` 或
 * `{ok:false, error}`；**从不抛错**，因为预览只是附加能力，不能拖垮整次 prepare。
 *
 * 两条分支：
 *   - 需要缩放：`sips -Z 2560 -s format jpeg`，输出 JPEG；
 *   - 不需要缩放：原样复制一份（不重编码），媒体类型沿用原图（必须是 Host 接受的
 *     png/jpeg/webp/gif；其它格式直接判为不可预览）。
 *
 * 依赖通过 `deps` 注入，单测可以伪造 sips 与文件系统；CLI 不传，行为不变。
 */
export function generatePreview(path, mediaType, deps = {}) {
  const run = deps.execFileSync ?? PREVIEW_DEPS.execFileSync
  const stat = deps.statSync ?? PREVIEW_DEPS.statSync
  const copy = deps.copyFileSync ?? PREVIEW_DEPS.copyFileSync
  const remove = deps.unlinkSync ?? PREVIEW_DEPS.unlinkSync
  const accepted = Object.values(MEDIA_TYPES)

  if (!mediaType || !accepted.includes(mediaType)) {
    return {
      ok: false,
      error: `无法生成预览：不支持的图片格式 ${extname(path) || '(无扩展名)'}；请按文件发送。`,
    }
  }

  let dimensions
  try {
    const stdout = run(
      'sips',
      ['-g', 'pixelWidth', '-g', 'pixelHeight', path],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
    )
    dimensions = parsePixelSize(stdout)
  } catch (error) {
    return { ok: false, error: `无法生成预览：${sipsReason(error)}` }
  }
  if (!dimensions) {
    return { ok: false, error: '无法生成预览：读不到图片尺寸（sips 未返回 pixelWidth/pixelHeight）' }
  }

  if (needsPreviewResize(dimensions)) {
    const preview = join(tmpdir(), `dsh-image-preview-${randomUUID()}.jpg`)
    try {
      // `-Z` 按最长边等比缩放；目标边长同时满足边上限与像素上限（见 previewTargetEdge）。
      run(
        'sips',
        [
          '-Z', String(previewTargetEdge(dimensions)),
          '-s', 'format', 'jpeg',
          '-s', 'formatOptions', String(PREVIEW_JPEG_QUALITY),
          path,
          '--out', preview,
        ],
        { stdio: ['ignore', 'ignore', 'pipe'] },
      )
      const size = stat(preview).size
      if (!Number.isFinite(size) || size <= 0) throw new Error('sips 没有写出预览文件')
      return { ok: true, path: preview, bytes: size, mediaType: 'image/jpeg', temporary: true }
    } catch (error) {
      try { remove(preview) } catch { /* 半截文件，删不掉也不影响结果 */ }
      return { ok: false, error: `无法生成预览：${sipsReason(error)}` }
    }
  }

  const preview = join(
    tmpdir(),
    `dsh-image-preview-${randomUUID()}${extname(path).toLowerCase() || '.img'}`,
  )
  try {
    copy(path, preview)
    const size = stat(preview).size
    if (!Number.isFinite(size) || size <= 0) throw new Error('复制的预览文件是空的')
    return { ok: true, path: preview, bytes: size, mediaType, temporary: true }
  } catch (error) {
    try { remove(preview) } catch { /* 同上 */ }
    return { ok: false, error: `无法生成预览：${sipsReason(error)}` }
  }
}

/** 把 sips / 文件系统的错误压成一句能放进 previewError 的原因。 */
function sipsReason(error) {
  const stderr = String(error?.stderr ?? '').trim()
  return stderr || error?.message || String(error)
}

/** 默认 prepare 的 JSON 描述符：既有字段不动，预览成功才附加预览字段。 */
export function describePrepared({ path, name, mediaType, bytes, temporary, preview }) {
  const descriptor = {
    path,
    name,
    mediaType,
    bytes,
    temporary: temporary === true,
  }
  if (mediaType === undefined) delete descriptor.mediaType
  if (preview?.ok) {
    descriptor.previewPath = preview.path
    descriptor.previewBytes = preview.bytes
    descriptor.previewMediaType = preview.mediaType
    // 预览总是临时文件，由调用方（send_image 工具）在用完后清理。
    descriptor.previewTemporary = preview.temporary === true
  } else {
    descriptor.previewError = preview?.error ?? '无法生成预览：未知原因'
  }
  return descriptor
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.help) return usage()

  const { path, temporary } = loadImage(args)
  const bytes = readFileSync(path)
  if (bytes.length === 0) throw new Error(`图片是空的: ${path}`)
  if (bytes.length > MAX_BYTES) {
    throw new Error(
      `图片过大（${(bytes.length / 1048576).toFixed(1)} MB）。` +
      `Host 上限 20 MB（maxImageBytes）——先压缩或用 --screenshot`
    )
  }

  const mediaType = MEDIA_TYPES[extname(path).toLowerCase()]
  const name = path.split('/').pop()

  // Default: hand the caller everything it needs to publish the picture itself.
  if (!args.viaPrompt) {
    // 预览失败不阻断：描述符仍带原图路径与类型，调用方回退到原图归一化或按文件发送。
    const preview = generatePreview(path, mediaType)
    console.log(JSON.stringify(describePrepared({
      path,
      name,
      mediaType,
      bytes: bytes.length,
      temporary,
      preview,
    })))
    return
  }

  // 旧路径仍然只认支持的图片类型：prompt 的 image 块必须声明 mediaType。
  if (!mediaType) throw new Error(`不支持的图片格式: ${extname(path) || '(无扩展名)'}`)

  const sessionId = process.env.DSH_SESSION_ID
  if (!sessionId) {
    throw new Error('没有 $DSH_SESSION_ID：--via-prompt 需要它，send_image 工具不需要')
  }

  const { base, token } = endpoint()
  const client = new Client(base)
  await client.authenticate(token)

  const caption = args.caption?.trim() || `图片 ${name}`

  await client.call('session/prompt', {
    request: {
      requestId: AGENT_REQUEST_PREFIX + randomUUID(),
      sessionId,
      mode: 'queue',
      content: [
        { type: 'text', text: caption },
        { type: 'image', mediaType, data: bytes.toString('base64'), name },
      ],
      clientTimeZone: 'Asia/Shanghai',
    },
  })

  // The Host normalizes and re-encodes, so the stored size is smaller than the
  // source; report what was submitted rather than guessing at the result.
  const kb = (bytes.length / 1024).toFixed(0)
  console.log(`已发送图片到会话 ${sessionId}`)
  console.log(`  文件: ${path}`)
  console.log(`  大小: ${kb} KB (${mediaType})`)
  console.log(`  说明: ${caption}`)

  if (temporary) {
    try { unlinkSync(path) } catch { /* best effort */ }
  }
}

// Only run when invoked as a program: the tests import this file for its pure
// helpers, and an unguarded main() would exit the test process.
const isDirectRun = process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (isDirectRun) {
  main().catch((error) => {
    console.error(`send-image: ${error.message}`)
    process.exit(1)
  })
}

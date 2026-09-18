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
 *   send-image.mjs --file <path>        # print {path, mediaType, bytes, name}
 *   send-image.mjs --screenshot
 *   send-image.mjs --clipboard
 *   send-image.mjs --file <path> --via-prompt [--caption "..."]
 *
 * Environment:
 *   DSH_SESSION_ID  the session to send into (only needed with --via-prompt)
 *   DSH_HOME        the harness home, for the endpoint file
 */

import { execFileSync } from 'node:child_process'
import { readFileSync, statSync, unlinkSync } from 'node:fs'
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

默认输出一行 JSON：{path, name, mediaType, bytes, temporary}，
调用方（send_image 工具）据此把图片存成附件、放进工具结果。`)
}

/**
 * The live DSH endpoint and its launch token.
 *
 * Two sources, because `endpoint.json` is not always there: the desktop shell
 * writes it as a handoff and **deletes it again when its host exits**, and a
 * bare `dsh web --port 0` never writes one. The shell's log keeps every launch
 * line, so its last entry is the fallback — the same second source
 * `test/tools/host.mjs` reads for the same reason.
 */
function endpoint() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  const handoff = join(home, 'desktop-shell', 'endpoint.json')
  try {
    const raw = JSON.parse(readFileSync(handoff, 'utf8'))
    const url = new URL(raw.url)
    const token = url.searchParams.get('token')
    const port = url.port || raw.port
    if (token && port) return { base: `http://127.0.0.1:${port}`, token }
  } catch {
    /* fall through to the shell log */
  }
  const log = join(home, 'desktop-shell', 'dsh-shell.log')
  try {
    const matches = readFileSync(log, 'utf8')
      .match(/http:\/\/127\.0\.0\.1:(\d+)\/\?token=([A-Za-z0-9_-]+)/g)
    const last = matches && matches[matches.length - 1]
    const parsed = last && /http:\/\/127\.0\.0\.1:(\d+)\/\?token=([A-Za-z0-9_-]+)/.exec(last)
    if (parsed) return { base: `http://127.0.0.1:${parsed[1]}`, token: parsed[2] }
  } catch {
    /* fall through to the error below */
  }
  throw new Error(`找不到运行中的 DSH：${handoff} 不存在，${log} 里也没有启动地址`)
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
      '屏幕录制权限没有生效。在「系统设置 → 隐私与安全性 → 屏幕录制」里勾选 DSH，' +
      '然后退出并重新打开 DSH.app —— macOS 只把权限交给重新启动后的进程。' +
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
  if (!mediaType) throw new Error(`不支持的图片格式: ${extname(path) || '(无扩展名)'}`)

  const name = path.split('/').pop()

  // Default: hand the caller everything it needs to publish the picture itself.
  if (!args.viaPrompt) {
    console.log(JSON.stringify({ path, name, mediaType, bytes: bytes.length, temporary: temporary === true }))
    return
  }

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

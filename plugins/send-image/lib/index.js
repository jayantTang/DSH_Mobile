/**
 * The `send_image` tool.
 *
 * A plugin rather than a skill on purpose: a registered tool is always in the
 * model's tool list, whereas a skill has to be noticed and loaded first. For a
 * capability whose whole value is "the user gets to see this", being reliably
 * present matters more than being discoverable.
 *
 * How the picture reaches the screen: the bytes go to the Host's attachment
 * service (`ctx.attachments.saveImage`, which normalizes and persists them) and
 * the returned reference rides on this tool's **result**, as an image content
 * block. Every client renders tool-result blocks inside the agent's own turn, so
 * the picture appears in the tool card where it belongs.
 *
 * The obvious alternative — submitting the picture as a prompt — is what this
 * used to do, and it was wrong twice over: a prompt is a **user message**, so
 * the image appeared to have been sent by the user, and it **started a turn**,
 * so the agent answered its own screenshot. Nothing here may go back to that:
 * the prompt path still exists in the skill script behind `--via-prompt`, for a
 * harness whose client cannot render tool-result images, and is not used here.
 */

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { existsSync, readFileSync, unlinkSync } from 'node:fs'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

const run = promisify(execFile)

const name = 'tool-send-image'
const inject = ['tools', 'attachments']

/** Where the script lives: the installed skill first, then the checkout. */
function scriptPath() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  const candidates = [
    join(home, 'skills', 'send-image', 'send-image.mjs'),
    // 同一个仓库里的 skill：按本模块定位，不写任何人的家目录。
    fileURLToPath(new URL('../../../skills/send-image/send-image.mjs', import.meta.url)),
  ]
  return candidates.find((path) => existsSync(path))
}

/**
 * Which single source the caller asked for.
 *
 * Exported for testing: the validation is the part that decides whether a user
 * gets an error they can act on or a silently wrong send.
 */
export function resolveSource(args) {
  const chosen = [
    args?.file ? 'file' : null,
    args?.screenshot ? 'screenshot' : null,
    args?.clipboard ? 'clipboard' : null,
  ].filter(Boolean)

  if (chosen.length === 0) {
    return { ok: false, error: '需要 file、screenshot 或 clipboard 之一' }
  }
  if (chosen.length > 1) {
    return { ok: false, error: `一次只能用一个来源，收到：${chosen.join(', ')}` }
  }
  if (chosen[0] === 'file' && String(args.file).trim().length === 0) {
    return { ok: false, error: 'file 是空路径' }
  }
  return { ok: true, source: chosen[0] }
}

/**
 * The argv handed to the script, in the order it parses.
 *
 * No `--caption`: the script's job here is capture and validation. The sentence
 * the user reads is this tool's, and it travels in the result next to the
 * picture.
 */
export function buildArgs(args, script) {
  const argv = [script]
  if (args.file) argv.push('--file', String(args.file))
  if (args.screenshot) argv.push('--screenshot')
  if (args.clipboard) argv.push('--clipboard')
  return argv
}

/** How the picture is described back to the model and to the user. */
export function describeSend(prepared, caption) {
  const size = prepared?.bytes >= 1024
    ? `${(prepared.bytes / 1024).toFixed(1)} KB`
    : `${prepared?.bytes ?? 0} B`
  const what = `${prepared?.name ?? '图片'}（${size}，${prepared?.mediaType ?? 'image'}）`
  const said = typeof caption === 'string' && caption.trim().length > 0 ? `：${caption.trim()} ` : ''
  return `已把图片放进这次回答的工具结果${said}— ${what}`
}

/**
 * One prepared image → one durable attachment reference.
 *
 * Split out from `execute` so the two things that can go wrong have names:
 * reading what the script prepared, and the Host refusing the bytes (format,
 * size, pixels). Both come back as tool errors carrying the service's own
 * reason, because the model can act on those and cannot act on a stack trace.
 */
export async function publish({ attachments, prepared, caption, read = readFileSync }) {
  if (!prepared?.path || !prepared?.mediaType) {
    return { ok: false, error: `准备图片失败：${JSON.stringify(prepared ?? null)}` }
  }
  let bytes
  try {
    bytes = read(prepared.path)
  } catch (error) {
    return { ok: false, error: `读不到准备好的图片：${error?.message ?? error}` }
  }
  if (bytes.length === 0) return { ok: false, error: `图片是空的：${prepared.path}` }

  try {
    const attachment = await attachments.saveImage({
      data: bytes,
      mediaType: prepared.mediaType,
      name: prepared.name,
    })
    return {
      ok: true,
      attachment,
      bytes: bytes.length,
      path: prepared.path,
      detail: describeSend({ ...prepared, bytes: bytes.length }, caption),
    }
  } catch (error) {
    return { ok: false, error: `Host 拒绝了这张图片：${error?.message ?? error}` }
  }
}

/** Tidies up after a capture, and never throws over it. */
export function discardPrepared(prepared, remove = unlinkSync) {
  if (!prepared?.temporary) return
  try { remove(prepared.path) } catch { /* best effort */ }
}

const description = [
  '把一张图片送进当前会话给用户看。图片会经 Host 归一化后持久化，',
  '并作为本次回答的工具结果出现在用户的 DSH 客户端（含 iOS 手机端）里，',
  '用户可点开放大——它不会变成一条用户消息，也不会触发新一轮回答。',
  '用 `file` 发送已有图片（截图、图表、渲染产物、设计稿）；',
  '用 `screenshot: true` 截取当前屏幕；用 `clipboard: true` 发送剪贴板里的图。',
  '适用于用户要求看图、需要目视确认，或你想用图片而非文字汇报的场景。',
].join(' ')

/**
 * The model-facing argument schema, raw JSON Schema because the plugin is
 * loaded from outside the dsh install and cannot import `@deepseek-ai/dsh-tools`
 * for its authoring helpers. Every property is optional on purpose: the
 * source-exclusivity rule has to be a readable tool error, not a schema
 * rejection the model cannot learn from.
 */
const parameters = {
  type: 'object',
  properties: {
    file: {
      type: 'string',
      description: '要发送的图片文件路径（绝对路径或相对当前工作目录）。与 screenshot/clipboard 三选一。',
    },
    screenshot: {
      type: 'boolean',
      description: '截取当前屏幕并发送。注意画面会包含屏幕上的一切。',
    },
    clipboard: {
      type: 'boolean',
      description: '发送剪贴板里的图片（需要 pngpaste）。',
    },
    caption: {
      type: 'string',
      description: '随图片显示的说明文字。写清楚这是什么，不要让用户猜。',
    },
  },
}

/**
 * The result the script reports, in both outcomes. A tool that returns a value
 * without declaring this shape is refused at registration time, which fails the
 * whole plugin tree — and with it every DSH boot, DSH.app included.
 */
const outputSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    ok: { type: 'boolean' },
    detail: { type: 'string' },
    error: { type: 'string' },
    path: { type: 'string' },
    bytes: { type: 'number' },
    // The durable reference the client draws. Deliberately permissive: the
    // shape belongs to the attachment service, and pinning it here would break
    // this tool the day that service adds a field.
    attachment: { type: 'object', additionalProperties: true },
  },
  required: ['ok'],
}

/** The text the model reads back, for either outcome. Exported for testing. */
export function renderResult(value) {
  if (value?.ok === true) {
    return typeof value.detail === 'string' && value.detail.trim().length > 0
      ? value.detail
      : '图片已发送。'
  }
  return `发送失败：${typeof value?.error === 'string' && value.error.trim().length > 0 ? value.error : '未知原因'}`
}

function apply(ctx) {
  ctx.tools.register({
    name: 'send_image',
    description,
    parameters,
    output: {
      schema: outputSchema,
      render: (_args, value) => {
        const parts = []
        // Picture first, then the sentence: clients draw them in this order
        // inside the tool card, and the model reads the text parts as the result.
        if (value?.ok === true && value.attachment) {
          parts.push({ type: 'image', attachment: value.attachment })
        }
        parts.push({ type: 'text', text: renderResult(value) })
        return parts
      },
    },
    async execute(args) {
      const source = resolveSource(args)
      if (!source.ok) return source

      const script = scriptPath()
      if (!script) {
        return {
          ok: false,
          error: '找不到 send-image.mjs；运行 scripts/install/install-skills.sh 安装',
        }
      }

      // Capture and validation live in the script (the screencapture/pngpaste
      // quirks, the screen-recording permission message). It prints one JSON
      // descriptor and never touches the session: publishing is this tool's job,
      // which is what keeps the picture out of the user's side of the
      // transcript.
      let prepared
      try {
        const { stdout } = await run(process.execPath, buildArgs(args, script), {
          env: process.env,
          timeout: 120_000,
        })
        const line = String(stdout).trim().split('\n').filter(Boolean).at(-1)
        prepared = JSON.parse(line)
      } catch (error) {
        const detail = [error?.stdout, error?.stderr, error?.message]
          .filter((part) => typeof part === 'string' && part.trim().length > 0)
          .join('\n')
          .trim()
        return { ok: false, error: detail || '准备图片失败' }
      }

      try {
        return await publish({
          attachments: ctx.attachments,
          prepared,
          caption: args?.caption,
        })
      } finally {
        discardPrepared(prepared)
      }
    },
  })
}

export { apply, inject, name, scriptPath }

/**
 * The `send_image` tool.
 *
 * A plugin rather than a skill on purpose: a registered tool is always in the
 * model's tool list, whereas a skill has to be noticed and loaded first. For a
 * capability whose whole value is "the user gets to see this", being reliably
 * present matters more than being discoverable.
 *
 * The image itself cannot be produced by the model — the provider adapters are
 * text-only — and the attachment service is read-only. The one channel is a
 * prompt carrying inline bytes, which the Host promotes to a durable
 * attachment. So this runs the send-image script, which submits exactly that
 * into the session the tool was called from.
 */

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

const run = promisify(execFile)

const name = 'tool-send-image'
const inject = ['tools']

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

/** The argv handed to the script, in the order it parses. */
export function buildArgs(args, script) {
  const argv = [script]
  if (args.file) argv.push('--file', String(args.file))
  if (args.screenshot) argv.push('--screenshot')
  if (args.clipboard) argv.push('--clipboard')
  if (args.caption && String(args.caption).trim().length > 0) {
    argv.push('--caption', String(args.caption))
  }
  return argv
}

const description = [
  '把一张图片送进当前会话给用户看。图片会经 Host 归一化后持久化，',
  '并在用户的 DSH 客户端（含 iOS 手机端）里直接显示，用户可点开放大。',
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
    sessionId: { type: 'string' },
    detail: { type: 'string' },
    error: { type: 'string' },
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
      render: (_args, value) => [{ type: 'text', text: renderResult(value) }],
    },
    async execute(args, exec) {
      // The session id has moved around between host versions, so every
      // plausible carrier is tried rather than trusting one shape.
      // Same host change as in doubao-image: the id now lives on the session
      // object. Without `agent.session.id` first, this tool fails every call
      // with "拿不到会话 id" — which is exactly what happened.
      const sessionId =
        exec?.agent?.session?.id ??
        exec?.agent?.sessionId ??
        exec?.session?.id ??
        exec?.sessionId ??
        exec?.context?.sessionId ??
        process.env.DSH_SESSION_ID
      if (!sessionId) {
        const seen = exec && typeof exec === 'object' ? Object.keys(exec).join(', ') : String(exec)
        return {
          ok: false,
          error: `拿不到会话 id，无法把图片发进对话（exec 字段：${seen}）`,
        }
      }

      const source = resolveSource(args)
      if (!source.ok) return source

      const script = scriptPath()
      if (!script) {
        return {
          ok: false,
          error: '找不到 send-image.mjs；运行 scripts/install/install-skills.sh 安装',
        }
      }

      const argv = buildArgs(args, script)

      try {
        const { stdout } = await run(process.execPath, argv, {
          env: { ...process.env, DSH_SESSION_ID: sessionId },
          timeout: 120_000,
        })
        return {
          ok: true,
          sessionId,
          // The script already reports the normalized-vs-source distinction the
          // model needs to describe what it sent.
          detail: stdout.trim(),
        }
      } catch (error) {
        const detail = [error?.stdout, error?.stderr, error?.message]
          .filter((part) => typeof part === 'string' && part.trim().length > 0)
          .join('\n')
          .trim()
        return { ok: false, error: detail || '发送失败' }
      }
    },
  })
}

export { apply, inject, name, scriptPath }

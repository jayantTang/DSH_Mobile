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
import { registerScreenshotRoute } from './screenshot-route.js'
import { appendIndex, indexEntry } from './image-originals.js'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

const run = promisify(execFile)

const name = 'tool-send-image'
const inject = ['tools', 'attachments']

/**
 * Where the script lives.
 *
 * Three candidates, in order:
 *   1. **the copy inside this package** — same version as the plugin, and the
 *      only one an npm install has. It comes first because the script's output
 *      descriptor is part of the plugin's contract: an older installed skill
 *      does not emit `previewPath`, which the plugin needs to keep a preview
 *      and an original apart;
 *   2. the installed skill under `$DSH_HOME/skills` — for hand-installed or
 *      partially cleaned trees where the package copy is missing;
 *   3. the `skills/` directory of a repository checkout — only resolves inside
 *      a checkout, kept last for local development and tests.
 *
 * Candidates 2 and 3 must stay byte-identical: `check:contracts` compares them
 * (via `test/contract/send-image-script.json`). Edit the canonical copy under
 * `skills/` and run `node scripts/dev/sync-send-image-script.mjs` to refresh.
 */
function scriptPath() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  const candidates = [
    // 包内那份：与插件同版本、随插件一起发布。**排在已安装 skill 之前**，
    // 因为两份脚本的**输出描述符**必须匹配插件的预期：用户机器上的旧 skill
    // 不会生成 previewPath，而新版插件需要它来区分预览与原图（2026-11-15 起）。
    // 已安装 skill 只在包内副本缺失时才用（老式安装/手工删文件）。
    fileURLToPath(new URL('./send-image.mjs', import.meta.url)),
    join(home, 'skills', 'send-image', 'send-image.mjs'),
    // 仓库 checkout 里的 skill：只在仓库里成立。
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

/** 人类可读大小；工具文案与详情共用，避免两处算出不同数字。 */
function formatSize(bytes) {
  return bytes >= 1024 ? `${(bytes / 1024).toFixed(1)} KB` : `${bytes ?? 0} B`
}

/**
 * How the picture is described back to the model and to the user.
 *
 * `original` 是可选状态：有原图时说保存了多大；保存失败/旧 Host 不支持时
 * 明说「原图不可用」，绝不能让用户以为还能取回原图。不传状态时保持旧文案，
 * 供只关心预览的调用方使用。
 */
export function describeSend(prepared, caption, { original, originalError } = {}) {
  const what = `${prepared?.name ?? '图片'}（${formatSize(prepared?.bytes ?? 0)}，${prepared?.mediaType ?? 'image'}）`
  const said = typeof caption === 'string' && caption.trim().length > 0 ? `：${caption.trim()} ` : ''
  const base = `已把图片放进这次回答的工具结果${said}— ${what}`
  if (original) return `${base}；原图已保存（${formatSize(original.bytes ?? 0)}）`
  if (originalError) return `${base}；原图不可用（${originalError}）`
  return base
}

/**
 * 读脚本生成的预览字节；预览不可用（没生成、读不到）时返回 null。
 *
 * 预览是「附加能力」：脚本可能因为 sips 失败只给出 `previewError`，而原图
 * 描述符仍然有效。这里不抛错，交给 `publish` 决定回退到原图。
 */
function readPreparedPreview(prepared, read) {
  if (!prepared?.previewPath) return null
  try {
    const data = read(prepared.previewPath)
    if (!data || data.length === 0) return null
    return { data, mediaType: prepared.previewMediaType || prepared.mediaType }
  } catch {
    return null
  }
}

/**
 * One prepared image → one durable preview reference, plus the optional original.
 *
 * 顺序固定为「先预览、后原图」：预览是该工具结果要画出来的东西，它失败就整次
 * 发送失败；原图只是按需取回的第二份字节，保存失败不能让用户连预览都看不到，
 * 所以降级成 `originalError` + 「原图不可用」，绝不能用预览冒充原图。
 *
 * `attachments.saveFile` 是较新的能力：旧 Host 上它根本不存在，必须能力探测，
 * 不能在调用处让 `TypeError` 冒出来。
 */
export async function publish({
  attachments,
  prepared,
  caption,
  read = readFileSync,
  home,
  logger = console,
}) {
  if (!prepared?.path) {
    return { ok: false, error: `准备图片失败：${JSON.stringify(prepared ?? null)}` }
  }
  let bytes
  let originalReadError
  try {
    bytes = read(prepared.path)
    if (!bytes || bytes.length === 0) originalReadError = `图片是空的：${prepared.path}`
  } catch (error) {
    originalReadError = `读不到准备好的图片：${error?.message ?? error}`
  }

  const preview = readPreparedPreview(prepared, read)
  let previewBytes = preview?.data
  let previewMediaType = preview?.mediaType
  // 没有预览字段、也没有 previewError 的描述符来自旧版采集脚本（本插件优先用包内
  // 副本，正常不会走到这里）。旧脚本把原图当成预览交给 Host，是这次要改掉的行为，
  // 但**旧描述符**仍必须能发出去：用户重装 skill 之前不该整条能力失效。
  // 一旦描述符明确报了 previewError，就不能再拿原图顶替（见下）。
  const legacyDescriptor = !prepared.previewPath && !prepared.previewError
  if (legacyDescriptor && prepared.mediaType) {
    if (!previewBytes && bytes?.length) {
      previewBytes = bytes
      previewMediaType = prepared.mediaType
    }
  }
  if (!previewBytes || !previewMediaType) {
    // 预览是这张工具结果要画出来的**那唯一一份图**。没有合格的预览就不发：
    // 把原图直接当预览交给 Host 归一化，会绕过"预览最长边 ≤ 2560、≤ 400 万像素"
    // 的口径（全景图归一化后最长边仍可能远超 2560），那是拿不合规的图冒充预览。
    // 工具结果形态里也没有"文件块"这条路，所以如实给可行动的错误。
    if (!bytes || bytes.length === 0) {
      return { ok: false, error: originalReadError ?? `图片是空的：${prepared.path}` }
    }
    const reason = prepared.previewError ?? '预览文件读不到'
    return {
      ok: false,
      error: `无法预览这张图片（${reason}）。请改用文件发送：${prepared.path}`,
    }
  }

  let attachment
  try {
    attachment = await attachments.saveImage({
      data: previewBytes,
      mediaType: previewMediaType,
      name: prepared.name,
    })
  } catch (error) {
    return { ok: false, error: `Host 拒绝了这张图片：${error?.message ?? error}` }
  }
  if (!attachment?.attachmentId) {
    return { ok: false, error: 'Host 没有返回预览附件引用' }
  }

  let original
  let originalError = originalReadError
  if (!originalError) {
    if (typeof attachments.saveFile !== 'function') {
      originalError = '当前 Host 不支持保存原图'
    } else {
      try {
        const saved = await attachments.saveFile({ data: bytes, name: prepared.name })
        if (saved?.attachmentId) original = saved
        else originalError = 'Host 没有返回原图引用'
      } catch (error) {
        originalError = `保存原图失败：${error?.message ?? error}`
      }
    }
  }

  if (original) {
    // 索引写失败只记日志：原图已经存进 Host，取不到关联不该让发图失败。
    appendIndex(
      indexEntry({
        previewId: attachment.attachmentId,
        original: {
          attachmentId: original.attachmentId,
          name: original.name ?? prepared.name,
          bytes: Number.isSafeInteger(original.bytes) ? original.bytes : bytes.length,
          mediaType: prepared.mediaType,
        },
        source: 'tool',
      }),
      { home, logger },
    )
  }

  const reportedBytes = bytes?.length ?? (Number.isSafeInteger(prepared.bytes) ? prepared.bytes : 0)
  let detail = describeSend({ ...prepared, bytes: reportedBytes }, caption, {
    original,
    originalError,
  })
  if (legacyDescriptor && previewBytes === bytes) {
    detail += '；采集脚本为旧版，未生成预览（请重新安装 dsh-plugin-send-image）'
  }

  return {
    ok: true,
    attachment,
    ...(original ? { original } : {}),
    ...(originalError ? { originalError } : {}),
    bytes: reportedBytes,
    path: prepared.path,
    detail,
  }
}

/** Tidies up after a capture, and never throws over it. */
export function discardPrepared(prepared, remove = unlinkSync) {
  // 预览总是临时文件（脚本用 previewTemporary 标记），先删它再删截图原文；
  // 源文件（--file）不能被删，所以只认脚本给出的 temporary / previewTemporary。
  if (prepared?.previewTemporary && prepared.previewPath) {
    try { remove(prepared.previewPath) } catch { /* best effort */ }
  }
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
 * whole plugin tree — and with it every DSH boot, the desktop app included.
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
    // 原图是可选的第二份字节；缺失表示这次没有原图（旧 Host 或保存失败），
    // 客户端仍只看 `attachment`（预览），不得用预览冒充原图。
    original: { type: 'object', additionalProperties: true },
    originalError: { type: 'string' },
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

/**
 * 工具的实际动作：准备图片（脚本）→ 交给 Host 的附件服务发布。
 *
 * 拆出来是为了让 `apply` 只剩"挂哪些入口"，也为了测试能不经过注册表直接跑这一条路径。
 */
async function executeSendImage(ctx, args) {
  const source = resolveSource(args)
  if (!source.ok) return source

  const script = scriptPath()
  if (!script) {
    return {
      ok: false,
      error: '找不到采集脚本（send-image.mjs），这个插件本应自带它。'
        + '请重新安装 dsh-plugin-send-image（例如 dsh plugin add dsh-plugin-send-image）；'
        + '若只是手工删过文件，重装即可恢复。',
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
      logger: ctx.logger,
    })
  } finally {
    discardPrepared(prepared)
  }
}

/** 面向 agent 的工具：始终在模型的工具表里。 */
function registerTool(ctx) {
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
    execute: (args) => executeSendImage(ctx, args),
  })
}

/**
 * 宿主半边：agent 工具 + 用户侧截图路由。
 *
 * 路由必须**同时**注入 `connection`：围栏服务只在被注入的作用域里取得到（`ctx.get('connection')`
 * 在插件作用域返回 undefined，001 记过这个坑）。分开注入的写法会让围栏永远取不到、把每个请求都
 * 判成"不可用"而 403——路由看起来注册成功，实际不可用。
 *
 * 生命期：路由的 disposer 交给 `scope.effect`，插件被禁用时路由随之撤销（热插拔的一半在宿主侧）。
 */
function apply(ctx) {
  registerTool(ctx)
  ctx.inject?.(['webServer', 'connection'], (scope) => {
    const dispose = registerScreenshotRoute(scope, { logger: ctx.logger })
    scope.effect?.(() => () => {
      try {
        dispose()
      } catch {
        /* route table already torn down */
      }
    }, 'send-image: screenshot route')
  })
}

export { apply, inject, name, scriptPath }

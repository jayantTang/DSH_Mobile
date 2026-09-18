/**
 * The `generate_image` tool — ask the locally installed Doubao app for an image
 * and bring the original bytes back into DSH.
 *
 * Why a plugin and not a skill: this is a capability the model should always
 * see in its tool list, not something it has to notice and load first. Same
 * reasoning as the sibling `send_image` plugin, in the opposite direction —
 * that one pushes a picture out to the user, this one pulls one in.
 *
 * Why CDP and not UI scripting: Doubao ships a full Chromium, so launching it
 * with `--remote-debugging-port` exposes a real DevTools Protocol endpoint and
 * the page can be driven with JavaScript. Driving it through `osascript` would
 * instead require the macOS Accessibility permission, which this machine has
 * not granted. The trade-off is that the app has to be (re)started by us,
 * because a normally-launched Doubao holds a singleton lock and never opens
 * the port.
 */

import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { IMAGE_PROMPT_PREFIX, generateImage } from './doubao.mjs'

const name = 'tool-doubao-image'
const inject = ['tools', 'attachments']

/** Where generated files land when the caller does not pick a directory. */
export function defaultDir() {
  return join(homedir(), 'Pictures', 'doubao')
}

/**
 * Turn the model's structured request into the sentence Doubao receives.
 *
 * Doubao's routing keys off the `生成图片：` prefix — without it the request is
 * answered in chat instead of by the image model. The rest of the string is
 * assembled in the order the image models weight most: subject, then style and
 * lighting, then composition, then the constraints that are most often broken
 * (text, watermark) and the output shape. Exported for testing because this
 * assembly is the part that decides whether the result is usable.
 */
export function buildPrompt(args) {
  const subject = String(args?.prompt ?? '').trim()
  if (subject.length === 0) return { ok: false, error: 'prompt 不能为空' }

  const parts = [subject]
  const style = String(args?.style ?? '').trim()
  const composition = String(args?.composition ?? '').trim()
  const negative = String(args?.negative ?? '').trim()
  const aspect = String(args?.aspect ?? '').trim()

  if (style) parts.push(`风格与光影：${style}。`)
  if (composition) parts.push(`构图：${composition}。`)
  if (negative) parts.push(`不要出现：${negative}。`)
  // Doubao's own image model accepts a plain-language aspect request; stating it
  // last keeps it adjacent to nothing that could dilute it.
  if (aspect) parts.push(`输出${aspect} 比例的图。`)

  return { ok: true, text: IMAGE_PROMPT_PREFIX + parts.join('') }
}

/** How many images to ask for, clamped to something Doubao will honour. */
export function resolveCount(value) {
  const n = Number(value)
  if (!Number.isFinite(n) || n <= 0) return 1
  return Math.min(Math.floor(n), 4)
}

const description = [
  '调用本机安装并已登录的豆包（Doubao）桌面应用生成图片，并把生成结果的原图保存到本地。',
  '',
  '**何时用**：用户想用豆包生成图、要一张配图/概念图/插画，或明确说“用豆包生成图片”时。',
  '生成的图片会以文件路径返回，同时自动发送到当前会话，用户可以直接看到。',
  '',
  '**prompt 要写专业**：不要只写几个关键词。按「主体 + 关键细节 + 风格/材质 + 光影 + 构图」写完整描述句，',
  '并主动指出最容易被做坏的地方（文字、水印、多余肢体、比例错误）。用 negative 参数排除不想要的元素。',
  '',
  '**注意**：豆包必须由本插件重启（正常启动的豆包不带调试端口，无法自动化），',
  '首次调用会关闭并重新打开豆包窗口，约需 10–40 秒。生成本身通常还要 30 秒到 2 分钟。',
].join('\n')

/**
 * The model-facing schema. Only `prompt` is required — everything else has a
 * sensible default, because a model that writes a good prompt but omits the
 * aspect ratio should get an image, not a validation error.
 */
const parameters = {
  type: 'object',
  properties: {
    prompt: {
      type: 'string',
      description:
        '图片内容描述，写成完整句。必须包含：主体是什么、关键外观细节、期望的风格与材质、光线氛围。例如「一位穿深蓝粗花呢大衣的中年航海家，银白胡须，站在雾中的木码头，身后是铜制六分仪和旧海图」。',
    },
    style: {
      type: 'string',
      description: '风格与渲染方式，如「黏土质感 C4D 渲染」「宫崎骏赛璐璐动画」「黑白胶片颗粒，柯达 Tri-X」。留空则由豆包自行判断。',
    },
    composition: {
      type: 'string',
      description: '构图与镜头，如「45 度俯视等距视角，主体居中，浅景深」「正面半身特写，背景虚化」。',
    },
    aspect: {
      type: 'string',
      description: '画幅比例，如 "3:4"（竖版海报）、"16:9"（横版横幅）、"1:1"（方图）。留空由豆包决定。',
    },
    negative: {
      type: 'string',
      description: '不要出现的元素，逗号分隔，如「文字，水印，多余的手指，畸变的脸」。默认会在提示词里强调无水印、无文字。',
    },
    count: {
      type: 'number',
      description: '最多取回几张图，1–4，默认 1。仅当用户明确要多张时才传大于 1 的值。',
    },
    dir: {
      type: 'string',
      description: '保存目录，默认 ~/Pictures/doubao。',
    },
    reuseCurrentChat: {
      type: 'boolean',
      description: 'true 时沿用豆包当前会话继续生成，适合「按上一张改一下」这类要求；默认 false，会新开一个对话。',
    },
    stripWatermark: {
      type: 'boolean',
      description:
        '默认 true，去掉豆包叠加的「豆包AI生成」水印（仅内部参考稿使用）。需要保留原始水印以便溯源时传 false。',
    },
  },
  required: ['prompt'],
}

/**
 * The declared result shape. A tool returning a value without a declared schema
 * is refused at registration, and that failure takes the whole plugin tree —
 * and every DSH boot — down with it, so this must stay in sync with `execute`.
 */
const outputSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    ok: { type: 'boolean' },
    files: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          path: { type: 'string' },
          bytes: { type: 'number' },
          format: { type: 'string' },
        },
        required: ['path'],
      },
    },
    error: { type: 'string' },
    detail: { type: 'string' },
    // Durable references for the pictures the client draws inside this tool's
    // card. Permissive on purpose: the shape belongs to the attachment service.
    attachments: {
      type: 'array',
      items: { type: 'object', additionalProperties: true },
    },
  },
  required: ['ok'],
}

/** The text the model reads back. Exported for testing. */
export function renderResult(value) {
  if (value?.ok === true) {
    const files = Array.isArray(value.files) ? value.files : []
    if (files.length === 0) return '豆包没有返回可用图片。'
    const lines = files.map(
      (f) => `${f.path}${f.bytes ? `（${(f.bytes / 1024 / 1024).toFixed(1)} MB）` : ''}`,
    )
    return `豆包已生成 ${files.length} 张图，原图已保存：\n${lines.join('\n')}`
  }
  return `豆包生成失败：${typeof value?.error === 'string' && value.error.trim().length > 0 ? value.error : '未知原因'}`
}

function apply(ctx) {
  ctx.tools.register({
    name: 'generate_image',
    description,
    parameters,
    output: {
      schema: outputSchema,
      render: (_args, value) => {
        const parts = []
        // Every generated picture, drawn in the tool card: the user sees the
        // result inside this turn rather than as a message of their own. A
        // prompt would have made it a user message and started another turn.
        for (const attachment of Array.isArray(value?.attachments) ? value.attachments : []) {
          if (attachment) parts.push({ type: 'image', attachment })
        }
        parts.push({ type: 'text', text: renderResult(value) })
        return parts
      },
    },
    async execute(args, exec) {
      const built = buildPrompt(args)
      if (!built.ok) return built

      const dir = typeof args?.dir === 'string' && args.dir.trim().length > 0 ? args.dir.trim() : defaultDir()

      // The whole run is minutes long (app relaunch plus generation), so the
      // log callback is what keeps a hung call distinguishable from a slow one.
      const notes = []
      const log = (message) => notes.push(message)

      try {
        const result = await generateImage({
          prompt: built.text,
          dir,
          count: resolveCount(args?.count),
          reuseCurrentChat: args?.reuseCurrentChat === true,
          stripWatermark: args?.stripWatermark !== false,
          timeoutMs: 300_000,
          log,
        })

        // Hand the pictures to the client so the user sees them without opening
        // a file manager: they become attachments referenced by this result, and
        // every client draws them in the tool card. A failure here must not fail
        // the generation that already succeeded — the files are on disk either
        // way, and the message says so.
        let delivered = ''
        let attachments = []
        try {
          const published = await publishAll(ctx.attachments, result.files)
          attachments = published.attachments
          delivered = published.note
        } catch (error) {
          delivered = `（自动放进会话失败：${error.message}；图片仍在磁盘上）`
        }

        return {
          ok: true,
          files: result.files.map((f) => ({
            path: f.path,
            bytes: f.bytes,
            format: f.format,
          })),
          attachments,
          detail: [notes.join('\n'), delivered].filter(Boolean).join('\n'),
        }
      } catch (error) {
        return { ok: false, error: `${error.message}${notes.length ? `\n过程：${notes.join(' → ')}` : ''}` }
      }
    },
  })
}

/**
 * Publish generated files as durable attachments.
 *
 * No session id is involved any more, and that is the point: the old path
 * pushed each file through `send-image.mjs` as a `session/prompt`, so the
 * pictures arrived as **user messages** and each one **started another turn** —
 * the agent answered its own generated image. A tool result carrying image
 * blocks shows them where they belong and costs nothing else.
 *
 * Exported for testing: the failure mode here is quiet (the tool still succeeds,
 * the files are still on disk, only the pictures are missing from the chat).
 */
export async function publishAll(attachments, files, read = readFileSync) {
  const refs = []
  const failures = []
  for (const file of files) {
    try {
      const bytes = read(file.path)
      refs.push(await attachments.saveImage({
        data: bytes,
        mediaType: mediaTypeOf(file),
        name: file.path.split('/').pop(),
      }))
    } catch (error) {
      failures.push(`${file.path}: ${error?.message ?? error}`)
    }
  }
  if (refs.length === 0) {
    throw new Error(failures.join('; ') || '没有可发布的图片')
  }
  const note = failures.length > 0
    ? `已把 ${refs.length} 张图放进当前会话（${failures.length} 张未能放入：${failures.join('; ')}）`
    : `已把 ${refs.length} 张图放进当前会话。`
  return { attachments: refs, note }
}

/** The declared format when the generator gave one, else the file extension. */
function mediaTypeOf(file) {
  const format = String(file?.format ?? '').toLowerCase()
  if (format === 'jpg') return 'image/jpeg'
  if (format === 'png' || format === 'webp' || format === 'gif') return `image/${format}`
  const extension = String(file?.path ?? '').toLowerCase().split('.').pop()
  if (extension === 'jpg' || extension === 'jpeg') return 'image/jpeg'
  if (extension === 'webp') return 'image/webp'
  if (extension === 'gif') return 'image/gif'
  return 'image/png'
}

export { apply, inject, name }

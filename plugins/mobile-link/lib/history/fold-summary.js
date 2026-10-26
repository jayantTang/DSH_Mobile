/**
 * `_link/sessionWindow` 的**概要 v2**投影（能力 `history-fold-summary-v2`）。
 *
 * 与 v1（`fold.js`，`fold: true`）的分工：v1 只把"过程段"换成一条 `+link/fold`
 * 摘要，记录里的**原始事件**基本照旧下发（工具正文、思考正文、完整 args 都在）。
 * v2 是给手机首屏用的取数模式：整段过程一个字节都不下发，只留
 * - 人类 `user/message`（含人发的图片）；
 * - `assistant/message` 的**正文块**：text 块（中间讲话也在内，思考块摘掉）+ image /
 *   file 块（**只留 attachment 元数据**：id / url / mime / 字节数 / 宽高 / 名字，
 *   绝不内联 base64）；图片是正式回答的一部分，不能因为折叠就消失；
 * - agent 代发的图片消息（`agent/inbox/spliced` 里带 attachment 的那条：这是宿主
 *   把"agent 发图"送进会话的唯一通道，见 DSHKit `Timeline.joinedImages` 的注释）；
 * - `turn/start` / `turn/end` / 压缩通知 / 错误通知；
 * - 每个过程段一条 `+link/fold`（`v: 2`），带分组、步骤标题、参数预览、状态与结果字节数。
 *
 * 展开轮次/分组不发请求：标题与预览都在摘要里；点开单条才按 seq 取那一条正文
 * （现有不带 fold 的窗口请求就够）。设计见
 * `maintainers/设计/20261025-过程折叠-对齐桌面.md` §3.4 / §4.4 / M6 / §十一。
 *
 * 两个口径与桌面保持一致（不是自己发明的）：
 * - 活动类别 = 桌面 `processActivity`/`activity(name)` 的那张表（`activityKind`）；
 * - 分组 = 中间讲话切开的连续过程段（桌面 `TurnGroups.rebuild` 在 reply / user /
 *   turn 边界处 flush）。所以本文件按"段"产摘要，`groups` 是段内的分组（今天一段一组，
 *   字段保留是为了与设计里的线格式一致）。
 *
 * 只做纯函数：IO 由 `summary-window.js` 负责。
 */

import { FOLD_RECORD_TYPE, isHumanMessage } from './fold.js'
import { bytesOf, trimRecordForWire } from './records.js'

/// `_link/hello` 声明的新能力位。老客户端不认识它，继续用 `fold: true`。
export const SUMMARY_FOLD_CAPABILITY = 'history-fold-summary-v2'
/// `fold` 的取值：只有这个字符串才切到 v2；`true` 仍是 v1，其余一律当没折（老行为）。
export const SUMMARY_FOLD_MODE = 'summary'
/// 摘要记录的版本号。客户端据此区分 v1（`foldedCount` 那套）与 v2。
export const SUMMARY_FOLD_VERSION = 2
/// `preview` 限长（字符）。设计 §十一 写的是"约 80B/步"，实现取 80 字。
export const SUMMARY_PREVIEW_CHARS = 80
/// 只有这些事件在 v2 里原样（去掉 `stream`）下发；其余要么折进摘要，要么丢掉。
const KEEP_TYPES = new Set([
  'compaction/start', 'compaction/end', 'compaction/summary', 'agent/error', 'error',
])

/// attachment 上可以下发的**元数据**键。白名单而不是黑名单：宁可少一个字段，
/// 也不许把 `data` / `base64` / `content` 这类内联负载带出去（一张图的 base64
/// 有几十万字符，比一整页概要还大）。
const ATTACHMENT_METADATA_KEYS = [
  'attachmentId', 'id', 'url', 'mediaType', 'mimeType', 'mime', 'bytes', 'size',
  'width', 'height', 'name', 'originalDimensions',
]
/// 任何"元数据"字符串超过这个长度就当作内联负载丢掉（例如不带 `data:` 前缀的
/// base64 或超长签名 URL）。
const MAX_METADATA_STRING = 512
/// 不认识的块类型：原样保留（客户端也是"不认识就原样留"，见 DSHKit
/// `ContentBlock.unknown`），但只在它足够小的时候——大块未知负载按内联字节处理。
const MAX_UNKNOWN_BLOCK_BYTES = 1024
/// 带 attachment 的块类型。图片与文件都是"正式回答的一部分"。
const ATTACHMENT_BLOCK_TYPES = new Set(['image', 'file'])

/// 工具名 → 桌面活动类别。与 `dsh-client-ui-chat` 的 `activity(name)` 逐条对齐：
/// 手机分组标题、活动计数都按这张表算，否则同一轮在桌面与手机上标题会不一样。
///
/// 表驱动而不是分支链：精确名、同义名集合、前缀三类各一张表，新增工具只加一行。
const ACTIVITY_EXACT = new Map([
  ['read', 'read'], ['read_image', 'readImage'],
  ['write', 'write'], ['edit', 'edit'], ['apply_patch', 'edit'],
  ['run_code', 'code'], ['web_search', 'webSearch'], ['web_fetch', 'webFetch'],
  ['ask_user_question', 'questions'], ['request_user_input', 'questions'],
])
const ACTIVITY_GROUPS = [
  [new Set(['grep', 'glob']), 'search'],
  [new Set(['bash', 'pwsh', 'exec_command', 'write_stdin']), 'commands'],
  [new Set(['todo_write', 'create_goal', 'update_goal', 'get_goal']), 'plan'],
]
const ACTIVITY_PREFIXES = [
  ['terminal_', 'commands'],
  ['subagent_', 'subagents'],
]
const ACTIVITY_INSPECT_SUFFIX = '_inspect'

export function activityKind(name) {
  if (typeof name !== 'string') return 'tools'
  const exact = ACTIVITY_EXACT.get(name)
  if (exact !== undefined) return exact
  for (const [names, kind] of ACTIVITY_GROUPS) if (names.has(name)) return kind
  for (const [prefix, kind] of ACTIVITY_PREFIXES) if (name.startsWith(prefix)) return kind
  if (name === 'subagent') return 'subagents'
  if (name.endsWith(ACTIVITY_INSPECT_SUFFIX)) return 'search'
  return 'tools'
}

/// 一条 `assistant/message` 的内容块。三种形态都认（生产形态 / 旧形态 / 裸文本），
/// 与 v1 的 `hasTextBlock`、搜索的 `docText` 同一枚举顺序。
function blocksOf(event) {
  const data = event?.data ?? {}
  const blocks = [data.message?.content, data.content].find((value) => Array.isArray(value))
  if (blocks !== undefined) return blocks
  if (typeof data.text === 'string' && data.text.trim() !== '') return [{ type: 'text', text: data.text }]
  return []
}

function reasoningTextOf(blocks) {
  return blocks
    .filter((block) => block?.type === 'reasoning' || block?.type === 'thinking')
    .map((block) => (typeof block?.text === 'string' ? block.text : ''))
    .filter((text) => text.trim() !== '')
    .join('\n')
}

/// attachment 的元数据副本：只留白名单键，且拒绝内联字节（`data:` URI、超长字符串、
/// 超大对象）。没有任何元数据时返回 undefined（宁可给个空 attachment 也不编字段）。
function attachmentMetadata(source) {
  if (source === null || typeof source !== 'object') return undefined
  const out = {}
  for (const key of ATTACHMENT_METADATA_KEYS) {
    const value = source[key]
    if (value === undefined || value === null) continue
    if (typeof value === 'string') {
      if (value.length > MAX_METADATA_STRING) continue
      if (/^data:/i.test(value)) continue
      out[key] = value
      continue
    }
    if (typeof value === 'object') {
      let encoded
      try { encoded = JSON.stringify(value) } catch { continue }
      if (typeof encoded !== 'string' || encoded.length > MAX_METADATA_STRING) continue
      out[key] = value
      continue
    }
    out[key] = value
  }
  return Object.keys(out).length > 0 ? out : undefined
}

/// `image` / `file` 块的 v2 形态：`{type, attachment:{元数据}}`，字节一律不内联。
function attachmentBlockForWire(block) {
  const merged = {
    ...(metadataForWire(block) ?? {}),
    ...(attachmentMetadata(block?.attachment) ?? {}),
  }
  const out = { type: block.type }
  if (Object.keys(merged).length > 0) out.attachment = merged
  return out
}

/// 块级别的元数据（有些形态把 id/url 直接放在块上而不是 `attachment` 里）。
function metadataForWire(block) {
  return attachmentMetadata(block)
}

/// 内容块的 v2 白名单，**保持原顺序**（客户端按块序渲染，图片与文字的前后关系要留住）：
/// - `text` 留；空的丢；
/// - `image` / `file` 只留 attachment 元数据；
/// - `reasoning` / `thinking` / `tool-call` / `tool-result` 丢（过程已进摘要）；
/// - 其它未知块原样留（小的时候），大块当作内联负载丢。
function contentForWire(blocks) {
  const out = []
  for (const block of blocks) {
    if (block === null || typeof block !== 'object') continue
    const type = block.type
    if (type === 'text') {
      if (typeof block.text === 'string' && block.text.trim() !== '') {
        out.push({ type: 'text', text: block.text })
      }
      continue
    }
    if (ATTACHMENT_BLOCK_TYPES.has(type)) {
      out.push(attachmentBlockForWire(block))
      continue
    }
    if (type === 'reasoning' || type === 'thinking' || type === 'tool-call' || type === 'tool-result') {
      continue
    }
    let encoded
    try { encoded = JSON.stringify(block) } catch { continue }
    if (typeof encoded !== 'string' || encoded.length > MAX_UNKNOWN_BLOCK_BYTES) continue
    out.push(block)
  }
  return out
}

/// 这批块里有没有带 attachment 的内容（图片/文件）。判定"这条消息算不算回答"要用它。
function hasAttachmentBlock(blocks) {
  return blocks.some((block) => ATTACHMENT_BLOCK_TYPES.has(block?.type))
}

/// 参数预览：折叠空白（步骤行只有一行）后截到 `SUMMARY_PREVIEW_CHARS` 个字符。
/// 完整 args 不下发——它是体积大户，也是"展开零请求"唯一可以省掉的一项。
export function previewOf(args) {
  if (typeof args !== 'string') return ''
  const flat = args.replace(/\s+/g, ' ').trim()
  return flat.length > SUMMARY_PREVIEW_CHARS ? flat.slice(0, SUMMARY_PREVIEW_CHARS) : flat
}

/// 工具结果里的**正文**（与搜索的 `docText` 同一组键）。只用来量字节数，不下发。
function resultTextOf(data) {
  const parts = []
  const blocks = [data?.message?.content, data?.content].find((value) => Array.isArray(value)) ?? []
  for (const block of blocks) {
    if (typeof block?.text === 'string' && block.text.length > 0) parts.push(block.text)
  }
  for (const key of ['output', 'result', 'stdout', 'stderr', 'text']) {
    if (typeof data?.[key] === 'string' && data[key].length > 0) parts.push(data[key])
  }
  return parts.join('\n')
}

function isErrorResult(data) {
  if (data?.message?.isError === true || data?.isError === true) return true
  const error = data?.error ?? data?.message?.error
  return error !== undefined && error !== null && error !== false
}

function record(event) {
  return { type: 'event', event }
}

/// `assistant/message` 的 v2 形态：正文块（text + image/file 元数据）。
/// `source`（含宿主的 `replayState` 回放日志）整块不要——那是另一个体积大户，
/// 手机侧没有读者。
function messageWithContent(event, blocks) {
  const data = {}
  if (Number.isInteger(event?.data?.turn)) data.turn = event.data.turn
  if (Number.isInteger(event?.data?.step)) data.step = event.data.step
  data.message = { role: 'assistant', content: blocks }
  return { type: 'assistant/message', seq: event.seq, time: event.time, data }
}

/// `user/message` 的 v2 形态。纯文本消息原样（只去掉 `stream`），不重建形状；
/// 带图片 / 文件、或带会被白名单摘掉的块（思考、工具块）时才重建 `content`，
/// 并把 attachment 里**内联字节**清掉——图片元数据留着，base64 不出去。
function userMessageForWire(event, blocks) {
  const needsRewrite = blocks.some((block) => ATTACHMENT_BLOCK_TYPES.has(block?.type)
    || block?.type === 'reasoning' || block?.type === 'thinking'
    || block?.type === 'tool-call' || block?.type === 'tool-result')
  if (!needsRewrite) return trimRecordForWire(record(event))
  const content = contentForWire(blocks)
  const data = { ...event.data }
  if (Array.isArray(event?.data?.content)) {
    data.content = content
  } else if (Array.isArray(event?.data?.message?.content)) {
    data.message = { ...event.data.message, content }
  } else {
    data.content = content
  }
  return trimRecordForWire(record({ ...event, data }))
}

/// 分组的活动计数。**只数工具步骤**，与桌面 `processActivity` 一致：桌面那张表
/// （commands/read/search/…）是工具类别，思考不算一种"已完成的活动"——一个只有思考的
/// 分组在桌面标题是 `已完成分析`（`counts` 为空时的兜底），如果这里把思考算成
/// `thinking: 1`，手机标题就会变成"已分析"之外的东西，与桌面不一致。
/// 思考本身仍以 `kind: "reasoning"` 的步骤留在 `steps[]` 里（步骤卡要用）。
function countActivities(steps) {
  const counts = {}
  for (const step of steps) {
    if (step.kind !== 'tools') continue
    const kind = activityKind(step.name)
    counts[kind] = (counts[kind] ?? 0) + 1
  }
  return counts
}

/**
 * 把**一轮**（`turn/start` … `turn/end`，或运行中到上界）的事件投影成 v2 的记录。
 *
 * @param {Array<object>} events 该轮的原始事件，按 seq 升序
 * @returns {{
 *   turn: number|null, durationMs: number|null, endReason: string|null,
 *   records: Array<{type:string, event:object}>,
 *   summaries: Array<object>, bytes: number,
 *   startSeq: number|null, endSeq: number|null,
 * }}
 */
export function projectTurnUnit(events) {
  const input = (Array.isArray(events) ? events : []).filter((event) => Number.isInteger(event?.seq))
  const startEvent = input.find((event) => event.type === 'turn/start')
  const endEvent = [...input].reverse().find((event) => event.type === 'turn/end')

  // 轮次号：优先 turn/start；没有边界（日志被裁剪）时用最近一条带 turn 的事件。
  // 都没有就如实给 null，不编一个 0 之外的号。
  let turn = Number.isInteger(startEvent?.data?.turn) ? startEvent.data.turn : null
  if (turn === null) {
    for (let index = input.length - 1; index >= 0; index -= 1) {
      const value = input[index]?.data?.turn
      if (Number.isInteger(value)) { turn = value; break }
    }
  }
  const durationMs = startEvent !== undefined && endEvent !== undefined
    && Number.isFinite(startEvent.time) && Number.isFinite(endEvent.time)
    ? Math.max(0, endEvent.time - startEvent.time)
    : null
  const reason = endEvent?.data?.reason
  const endReason = typeof reason === 'string'
    ? reason
    : (typeof reason?.kind === 'string' ? reason.kind : null)

  const out = []
  const summaries = []
  let group = null

  const openGroup = (event) => {
    if (group !== null) return
    group = { startSeq: event.seq, endSeq: event.seq, time: event.time, steps: [], calls: new Map() }
  }

  const flush = () => {
    const current = group
    group = null
    if (current === null || current.steps.length === 0) return
    const activities = countActivities(current.steps)
    const summary = {
      v: SUMMARY_FOLD_VERSION,
      turn,
      startSeq: current.startSeq,
      endSeq: current.endSeq,
      durationMs,
      endReason,
      activities,
      groups: [{
        startSeq: current.startSeq,
        endSeq: current.endSeq,
        activities: { ...activities },
        toolCount: current.steps.filter((step) => step.kind === 'tools').length,
        steps: current.steps,
      }],
    }
    summaries.push(summary)
    out.push(record({ type: FOLD_RECORD_TYPE, seq: current.startSeq, time: current.time, data: summary }))
  }

  for (const event of input) {
    switch (event.type) {
      case 'turn/start': {
        flush()
        const data = {}
        if (Number.isInteger(event?.data?.turn)) data.turn = event.data.turn
        out.push(record({ type: 'turn/start', seq: event.seq, time: event.time, data }))
        break
      }
      case 'turn/end': {
        flush()
        const data = {}
        if (Number.isInteger(event?.data?.turn)) data.turn = event.data.turn
        if (event?.data?.reason !== undefined) data.reason = event.data.reason
        out.push(record({ type: 'turn/end', seq: event.seq, time: event.time, data }))
        break
      }
      case 'user/message': {
        flush()
        // 只有人打的字才是"讲话"。插件 / 运行时注入的同类型消息（`source.kind`
        // 不是 `user`）手机侧本来也不显示（DSHKit `Timeline.applyEvent` 只看人发的）……
        // 但如果它带着图片，那就是"agent 代发的图片回答"（老格式走这条），必须留。
        const blocks = blocksOf(event)
        if (isHumanMessage(event) || hasAttachmentBlock(blocks)) {
          out.push(userMessageForWire(event, blocks))
        }
        break
      }
      case 'agent/inbox/spliced': {
        // 宿主把 **agent 发出的图片** 走 splice 通道送进会话（DSHKit `Timeline`
        // 的 `joinedImages` 注释："splice 是 agent 发的图片进入对话的唯一通道"）。
        // 这条消息可能就是正式回答本身，所以只要它带 attachment 就留；其余 splice
        // （用户消息的本地回声、插件通知）在 v2 里一律不发——人打的那句话在
        // `user/message` 里已经有了，客户端本来就按 rpcId 去重。
        const inserted = Array.isArray(event?.data?.inserted) ? event.data.inserted : []
        const items = inserted.map((item) => {
          const itemBlocks = Array.isArray(item?.content) ? item.content : []
          return { item, blocks: itemBlocks, content: contentForWire(itemBlocks) }
        }).filter((entry) => entry.content.length > 0
          && entry.content.some((block) => ATTACHMENT_BLOCK_TYPES.has(block.type)))
        if (items.length === 0) break
        flush()
        out.push(record({
          type: 'agent/inbox/spliced',
          seq: event.seq,
          time: event.time,
          data: {
            ...(typeof event?.data?.target === 'string' ? { target: event.data.target } : {}),
            inserted: items.map(({ item, content }) => {
              const kept = { content }
              for (const key of ['source', 'role', 'id']) {
                if (item?.[key] !== undefined) kept[key] = item[key]
              }
              return kept
            }),
          },
        }))
        break
      }
      case 'assistant/message': {
        const blocks = blocksOf(event)
        const reasoning = reasoningTextOf(blocks)
        if (reasoning !== '') {
          openGroup(event)
          group.steps.push({
            seq: event.seq,
            kind: 'reasoning',
            name: 'thinking',
            preview: '',
            status: 'ok',
            bytes: Buffer.byteLength(reasoning, 'utf8'),
          })
          group.endSeq = event.seq
        }
        const content = contentForWire(blocks)
        if (content.length > 0) {
          flush()
          out.push(record(messageWithContent(event, content)))
        }
        break
      }
      case 'tool/call': {
        openGroup(event)
        const step = {
          seq: event.seq,
          kind: 'tools',
          name: typeof event?.data?.name === 'string' && event.data.name !== '' ? event.data.name : 'tool',
          preview: previewOf(event?.data?.arguments),
          status: 'running',
        }
        group.steps.push(step)
        const callId = event?.data?.callId
        if (typeof callId === 'string') group.calls.set(callId, step)
        group.endSeq = event.seq
        break
      }
      case 'tool/result': {
        const callId = event?.data?.message?.toolCallId ?? event?.data?.toolCallId ?? event?.data?.callId
        const step = group?.calls.get(callId)
        // 结果找不到对应调用（日志被裁剪、旧格式）就丢掉：摘要里不凭空造一步。
        if (step === undefined) break
        const text = resultTextOf(event?.data)
        step.status = isErrorResult(event?.data) ? 'error' : 'ok'
        step.resultSeq = event.seq
        if (text !== '') step.bytes = Buffer.byteLength(text, 'utf8')
        group.endSeq = event.seq
        break
      }
      default: {
        if (!KEEP_TYPES.has(event.type)) break
        flush()
        out.push(trimRecordForWire(record(event)))
        break
      }
    }
  }
  flush()

  return {
    turn,
    durationMs,
    endReason,
    records: out,
    summaries,
    // 预算单位是**下发字节**，不是原始事件字节：摘要页的价值就在这里。
    bytes: bytesOf(out),
    startSeq: out.length > 0 ? out[0].event.seq : null,
    endSeq: out.length > 0 ? out[out.length - 1].event.seq : null,
  }
}

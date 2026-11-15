/**
 * 作答记录（`+link/question`）：把 `ask_user_question` 的问题与答案单独下发。
 *
 * 为什么需要：折叠模式把 `tool/call` / `tool/result` 整段收进摘要，正文与参数都不
 * 下发；但用户刚做出的选择属于**用户自己的输入**，不能因为它来自工具结果就跟着
 * 过程一起消失（SR-02.16）。桌面把这种记录渲染成一条用户消息气泡，手机侧沿用同一
 * 语义：它是会话内容，不是过程。
 *
 * 形状：
 *
 *     +link/question {
 *       callId,
 *       questions: [{ id, question, header? }],
 *       answers:   [{ id, selected: string[], custom?: string }]
 *     }
 *
 * - 只发**已结算**的答案批次；`{pending:true}` 的计时提问、失败或取消的调用不发。
 * - 问题文字从 `tool/call` 参数里取；参数缺失/形状不认识时给空数组，客户端至少
 *   还能显示答案（AR-02.16.01 的降级口径）。
 * - 文字按码元截断且不切开代理对（与预览、搜索片段同一套 `truncateSafe`）。
 */

import { truncateSafe } from '../unicode.js'

/** 记录类型。以 `+` 开头，不会与宿主事件类型相撞。 */
export const QUESTION_RECORD_TYPE = '+link/question'

/** 会带来问题清单的工具名。 */
const QUESTION_TOOLS = new Set(['ask_user_question', 'request_user_input'])

/** 单个字段（问题、标题、自定义答案）下发的上限；超出截断并加省略号。 */
export const QUESTION_TEXT_LIMIT = 1000

export function isQuestionTool(name) {
  return typeof name === 'string' && QUESTION_TOOLS.has(name)
}

/**
 * 工具结果的正文。与摘要的字节统计、搜索的 `docText` 同一组键。
 * 只取文本块与文本字段，图片/文件不在其中。
 */
export function resultTextOf(data) {
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

function parseJson(value) {
  if (typeof value !== 'string') return undefined
  try {
    return JSON.parse(value)
  } catch {
    return undefined
  }
}

/** 截到上限并补省略号；截断点不落在 emoji 中间。 */
function cap(text) {
  if (typeof text !== 'string') return ''
  if (text.length <= QUESTION_TEXT_LIMIT) return text
  return `${truncateSafe(text, QUESTION_TEXT_LIMIT - 1)}…`
}

/**
 * `tool/call` 参数里的问题清单。
 *
 * 严格配对：任何一项缺 `id` / `question` 就整份不要——半份问题清单会把答案配到
 * 错的问题上，比没有文字更糟。`multi_select` / `multiSelect` 两种拼写都收
 * （宿主 schema 用蛇形，旧夹具可能用驼峰），展示只需要文字。
 */
export function questionsOf(argumentsValue) {
  const parsed = typeof argumentsValue === 'object' && argumentsValue !== null
    ? argumentsValue
    : parseJson(argumentsValue)
  if (parsed === null || typeof parsed !== 'object') return []
  if (!Array.isArray(parsed.questions) || parsed.questions.length === 0) return []
  const out = []
  for (const question of parsed.questions) {
    if (question === null || typeof question !== 'object') return []
    if (typeof question.id !== 'string' || question.id === '') return []
    if (typeof question.question !== 'string') return []
    out.push({
      id: question.id,
      question: cap(question.question),
      ...(typeof question.header === 'string' && question.header !== ''
        ? { header: cap(question.header) }
        : {}),
    })
  }
  return out
}

/**
 * 工具结果里的答案批次；没结算、形状不认识时返回 null。
 *
 * `answers: []` 保留为空数组（调用方据此不发记录）：它表示"没有可显示的答案"，
 * 与"结果还没回来"不是同一件事。
 */
export function answersOf(resultText) {
  const parsed = parseJson(resultText)
  if (parsed === null || typeof parsed !== 'object') return null
  if (parsed.pending === true) return null
  if (!Array.isArray(parsed.answers)) return null
  const out = []
  for (const answer of parsed.answers) {
    if (answer === null || typeof answer !== 'object') return null
    if (typeof answer.id !== 'string' || answer.id === '') return null
    if (!Array.isArray(answer.selected) || !answer.selected.every((item) => typeof item === 'string')) {
      return null
    }
    if (answer.custom !== undefined && typeof answer.custom !== 'string') return null
    out.push({
      id: answer.id,
      selected: answer.selected,
      ...(typeof answer.custom === 'string' && answer.custom.trim() !== ''
        ? { custom: cap(answer.custom) }
        : {}),
    })
  }
  return out
}

/**
 * 一次提问调用 + 它的结果 → 一条待下发的记录。
 *
 * @param {object} input
 * @param {{callId?: string, name?: string, arguments?: unknown}} input.call
 * @param {string} input.resultText 工具结果正文
 * @param {number} input.seq 结果事件的 seq（记录的排序键）
 * @param {number} [input.time] 结果事件时间
 * @returns {object|null} 不是提问、没结算、或 callId 缺失时返回 null
 */
export function questionRecordFor({ call, resultText, seq, time }) {
  if (!isQuestionTool(call?.name)) return null
  if (typeof call?.callId !== 'string' || call.callId === '') return null
  if (!Number.isInteger(seq)) return null
  const answers = answersOf(resultText)
  if (answers === null || answers.length === 0) return null
  return {
    type: QUESTION_RECORD_TYPE,
    seq,
    ...(Number.isFinite(time) ? { time } : {}),
    data: {
      callId: call.callId,
      questions: questionsOf(call.arguments),
      answers,
    },
  }
}

/**
 * 从原始记录里取出提问结果，供 v1/v2 两条折叠路径共用。
 * @param {Array<{type:string,event:object}>} records
 * @returns {Array<{seq:number,record:object}>} 按 seq 升序
 */
export function questionRecordsOfEvents(events) {
  const calls = new Map()
  const out = []
  for (const event of events) {
    if (event?.type === 'tool/call' && isQuestionTool(event?.data?.name)) {
      const callId = event?.data?.callId
      if (typeof callId === 'string' && callId !== '') {
        calls.set(callId, { callId, name: event.data.name, arguments: event.data.arguments })
      }
      continue
    }
    if (event?.type !== 'tool/result') continue
    const callId = event?.data?.message?.toolCallId ?? event?.data?.toolCallId ?? event?.data?.callId
    const call = calls.get(callId)
    if (call === undefined) continue
    const record = questionRecordFor({
      call,
      resultText: resultTextOf(event.data),
      seq: event.seq,
      time: event.time,
    })
    if (record !== null) out.push({ seq: event.seq, record })
  }
  return out
}

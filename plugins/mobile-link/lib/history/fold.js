/**
 * `_link/sessionWindow` 的折叠感知下发（能力 `history-fold-summary`）。
 *
 * 手机对已完成的轮次默认收起过程（spec 033）。但报文仍按原始事件把整段过程
 * 发下来——实测一次上翻里多数字节属于折叠后不可见的行。长轮次会跨好几页
 * （本机样本一轮可达千级 seq），所以这里不按"整轮"折，而按**页内连续过程段**折：
 * 一段连续的助手中间输出 / 工具调用 / 工具结果收成一条 `+link/fold` 摘要记录；
 * 用户消息、轮次开始/结束、压缩与错误通知一律保留。
 *
 * 保留规则是**轮级**的，与客户端收起态契约一致（`TranscriptProcessFold.plan`）：
 * 每个 `turn/end` 之前末尾连续的一段回答必须留在页里（回答 = 带正文的
 * `assistant/message`，或 agent 发送的图片消息）；页尾再补一次同样的扫描，覆盖
 * "轮次未结束、`turn/end` 在下一页"的跨页截断。回答不在页里，收起后该轮就没有正文；
 * 少折只损失字节。
 *
 * 展开：客户端按摘要的 `startSeq...endSeq` 发一次**不带 fold** 的普通窗口请求
 * （现有 `_link/sessionWindow`），取回原事件即可，不需要新端点。
 */

/// 客户端按这个类型画过程节点；以 `+` 开头，不会与宿主事件类型相撞。
export const FOLD_RECORD_TYPE = '+link/fold'

/// 连接器在 `_link/hello` 里声明：`_link/sessionWindow` 接受 `fold: true`。
export const FOLD_CAPABILITY = 'history-fold-summary'

/// 客户端渲染不读、可以整条丢掉的事件（不产生任何行，也不参与折叠状态）。
/// `turn/start` / `turn/end` 不在其中：它们维持轮次状态与结束标记。
const DROP_TYPES = new Set([
  'request/header', 'step/start', 'step/end', 'goal/change', 'title/change',
  'system/message', 'developer/message',
  'session-log-deepseek/delivery-accepted', 'session/end-seed', 'compaction/prune',
])

/// 可以收进摘要的过程事件。助手回答里可能既有思考也有正文；整条一起折。
const FOLD_TYPES = new Set(['assistant/message', 'tool/call', 'tool/result'])

/// 会渲染成可见行的通知 / 压缩事件：保留，绝不折。
const KEEP_SIDE_EVENTS = new Set([
  'compaction/start', 'compaction/end', 'compaction/summary', 'agent/error', 'error',
])

/// 是不是**人打的字**（`user/message` 里插件 / 运行时注入的同类型消息不算）。
///
/// 导出给 `fold-summary.js` 用：v1 用它决定"人类消息切开过程段"，v2 用它决定
/// "哪些 `user/message` 算讲话"。同一口径只留一份，两边各写一遍必然会漂。
export function isHumanMessage(event) {
  if (event?.type !== 'user/message') return false
  const source = event?.data?.source
  if (source !== undefined && source !== null && typeof source === 'object') {
    if (source.kind !== undefined && source.kind !== 'user') return false
    if (typeof source.rpcId === 'string' && source.rpcId.startsWith('agent-')) return false
  }
  return true
}

function reasoningBlocks(event) {
  const blocks = event?.data?.content
  if (!Array.isArray(blocks)) return 0
  return blocks.filter((block) => block?.type === 'reasoning' || block?.type === 'thinking').length
}

/// 一条 `assistant/message` 会不会渲染成正文行。
///
/// 判定必须看 content 块，不能只看事件类型：一条消息可以只有 `reasoning` 块，
/// 客户端不会为它产生 `assistantText` 行（Timeline.swift 按块拆行）。枚举的形态与
/// `docText` 的消息类枚举对齐：`data.message.content`（宿主生产形态）、`data.content`
/// （旧 / 测试形态）、以及裸 `data.text`。
function hasTextBlock(event) {
  if (event?.type !== 'assistant/message') return false
  const data = event?.data ?? {}
  const blocks = [data.message?.content, data.content].find((value) => Array.isArray(value)) ?? []
  const hasBlock = blocks.some((block) => block?.type === 'text'
    && typeof block.text === 'string' && block.text.trim() !== '')
  return hasBlock || (typeof data.text === 'string' && data.text.trim() !== '')
}

/// agent 代发的消息（图片型回答）也算回答行：客户端 `isAnswerRow` 认它。
/// 人类用户消息是可见行、会切开过程段，但不是回答候选。
function isAgentMessage(event) {
  return event?.type === 'user/message' && !isHumanMessage(event)
}

/// 轮级保留：把 `turn/end`（或页尾）之前末尾连续的一段回答加进保护集。
///
/// 与客户端 `TranscriptProcessFold.plan` 同构：从 `beforeIndex - 1` 向前找第一条
/// **回答候选**作为锚点，再向左扩展整段连续回答；`DROP_TYPES` 事件不产生行、跳过
/// 不算断开；人类用户消息不是候选但也不终止扫描（回答可能在它的后面）；其余任何
/// 事件（tool/*、无正文的 assistant、通知类、`turn/start`）停止扫描——尤其 `turn/end`
/// / `turn/start` 保证不跨入上一轮。
function protectAnswerRun(events, beforeIndex, protectedIndexes) {
  const isCandidate = (index) => hasTextBlock(events[index]) || isAgentMessage(events[index])
  let anchor = -1
  for (let index = beforeIndex - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event.type === 'turn/end' || event.type === 'turn/start') return
    if (isCandidate(index)) {
      anchor = index
      break
    }
  }
  if (anchor < 0) return
  for (let index = anchor; index >= 0; index -= 1) {
    const event = events[index]
    if (DROP_TYPES.has(event.type)) continue
    if (!isCandidate(index)) break
    if (hasTextBlock(event)) protectedIndexes.add(index)
  }
}

function summarise(run) {
  let toolCount = 0
  let reasoningCount = 0
  let messageCount = 0
  let subagentCount = 0
  for (const event of run) {
    if (event.type === 'tool/call') {
      toolCount += 1
      if (event?.data?.name === 'subagent' || event?.data?.name === 'task') subagentCount += 1
    } else if (event.type === 'assistant/message') {
      messageCount += 1
      reasoningCount += reasoningBlocks(event)
    }
  }
  const turn = run.find((event) => Number.isInteger(event?.data?.turn))?.data?.turn ?? 0
  return {
    turn,
    startSeq: run[0].seq,
    endSeq: run[run.length - 1].seq,
    finalSeq: null,
    dividerSeq: null,
    toolCount,
    reasoningCount,
    messageCount,
    subagentCount,
    endReason: null,
    durationMs: null,
    foldedCount: run.length,
  }
}

/// 把一页记录折成"过程摘要 + 保留事件"。
///
/// `records` 必须是 `[{type:'event', event}]` 且按 seq 升序。返回的 `records`
/// 保持这个形状；`folds` 是同一份摘要的列表，便于记账与测试。
export function foldProcessRuns(records) {
  const events = records.map((record) => record.event)
  // 轮级保留：每个已结束轮次回答段各保一次，页尾再补一次覆盖跨页未结束的轮次。
  const protectedIndexes = new Set()
  for (let i = 0; i < events.length; i += 1) {
    if (events[i].type === 'turn/end') protectAnswerRun(events, i, protectedIndexes)
  }
  protectAnswerRun(events, events.length, protectedIndexes)

  const out = []
  const folds = []
  let run = []
  const flush = () => {
    if (run.length === 0) return
    const summary = summarise(run)
    out.push({ type: FOLD_RECORD_TYPE, seq: summary.startSeq, time: run[0].time, data: summary })
    folds.push(summary)
    run = []
  }

  for (let index = 0; index < events.length; index += 1) {
    const event = events[index]
    if (DROP_TYPES.has(event.type)) continue
    const protectedEvent = protectedIndexes.has(index)
    if (FOLD_TYPES.has(event.type) && !protectedEvent) {
      run.push(event)
      continue
    }
    flush()
    out.push(event)
    // 可见行（用户消息、回答、通知、轮次边界）把过程段切开；保留原顺序。
    if (KEEP_SIDE_EVENTS.has(event.type) || isHumanMessage(event)) continue
  }
  flush()

  return {
    records: out.map((event) => ({ type: 'event', event })),
    folds,
  }
}

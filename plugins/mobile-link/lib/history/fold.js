/**
 * `_link/sessionWindow` 的折叠感知下发（能力 `history-fold-summary`）。
 *
 * 手机对已完成的轮次默认收起过程（spec 033）。但报文仍按原始事件把整段过程
 * 发下来——实测一次上翻里多数字节属于折叠后不可见的行。长轮次会跨好几页
 * （本机样本一轮可达千级 seq），所以这里不按"整轮"折，而按**页内连续过程段**折：
 * 一段连续的助手中间输出 / 工具调用 / 工具结果收成一条 `+link/fold` 摘要记录；
 * 用户消息、页内最后一条助手回答、轮次开始/结束、压缩与错误通知一律保留。
 *
 * 为什么保留"页内最后一条助手回答"：连接器不知道它是不是最终回答（页可能结束在
 * 轮次中间）。错把它折掉，读者就看不到当前这屏唯一的正文；少折只损失字节。
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

function isHumanMessage(event) {
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
export function foldCompletedTurns(records) {
  const events = records.map((record) => record.event)
  // 页内最后一条助手回答保留：它可能是最终回答，也可能是这一屏唯一的正文。
  let lastAssistant = -1
  for (let i = 0; i < events.length; i += 1) {
    if (events[i].type === 'assistant/message') lastAssistant = i
  }

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
    const protectedEvent = index === lastAssistant
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

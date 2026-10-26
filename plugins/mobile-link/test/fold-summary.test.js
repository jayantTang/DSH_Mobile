/**
 * 概要 v2（能力 `history-fold-summary-v2`）的投影层单测。
 *
 * 需求（`maintainers/设计/20261025-过程折叠-对齐桌面.md` §3.4 / §4.4 / M6 / §十一）：
 * 手机首屏只拿"讲话 + 概要 + 正式回答"——
 * - 保留：人类 `user/message`、`assistant/message` 的**正文 text 块**（含中间讲话）、
 *   `turn/start` / `turn/end`、压缩与错误通知；
 * - 每个过程段一条 `+link/fold` v2 记录（`turn/startSeq/endSeq/durationMs/endReason/
 *   activities/groups[].steps[]`）；
 * - 不传：`tool/call`、`tool/result` 正文、`reasoning` 正文、完整 args（只给 preview）。
 */

import test from 'node:test'
import assert from 'node:assert/strict'

import {
  SUMMARY_FOLD_VERSION, SUMMARY_FOLD_MODE, SUMMARY_FOLD_CAPABILITY,
  SUMMARY_PREVIEW_CHARS, activityKind, projectTurnUnit,
} from '../lib/history/fold-summary.js'
import { FOLD_RECORD_TYPE } from '../lib/history/fold.js'

let seq = 0
function ev(type, data = {}, time) {
  seq += 1
  const at = seq - 1
  return { type, seq: at, time: time ?? 1_700_000_000_000 + at, data }
}
function reset() { seq = 0 }
const typesOf = (out) => out.records.map((record) => record.event.type)

const REASONING = '这段思考正文绝不能出现在回包里（一）'
const RESULT_OK = '命令输出：a.txt b.txt c.txt'
const RESULT_ERR = '错误输出：pattern not found'
const ARGS_LONG = `{"command":"${'x'.repeat(200)}"}`
const ANSWER = '正式回答：两个文件都在。'

/// 一轮典型轮次：思考块 + 两次工具调用（一次成功一次失败）+ 中间讲话 + 正式回答。
function typicalTurn() {
  reset()
  return [
    ev('turn/start', { turn: 1 }, 1_700_000_000_000),
    ev('user/message', { content: [{ type: 'text', text: '帮我看一下目录' }], source: { kind: 'user', rpcId: 'r1' } }),
    ev('step/start', { turn: 1, step: 1 }),
    ev('assistant/message', {
      turn: 1, step: 1,
      message: { role: 'assistant', content: [{ type: 'reasoning', text: REASONING }] },
    }),
    ev('tool/call', { turn: 1, step: 1, callId: 'c1', name: 'bash', arguments: ARGS_LONG }),
    ev('tool/result', {
      turn: 1, step: 1,
      message: { role: 'tool', toolCallId: 'c1', content: [{ type: 'text', text: RESULT_OK }] },
    }),
    ev('step/end', { turn: 1, step: 1 }),
    ev('assistant/message', {
      turn: 1, step: 2,
      message: { role: 'assistant', content: [{ type: 'text', text: '中间讲话：先看目录结构。' }] },
    }),
    ev('assistant/message', {
      turn: 1, step: 3,
      message: { role: 'assistant', content: [{ type: 'reasoning', text: REASONING }] },
    }),
    ev('tool/call', { turn: 1, step: 3, callId: 'c2', name: 'grep', arguments: '{"pattern":"TODO"}' }),
    ev('tool/result', {
      turn: 1, step: 3,
      message: { role: 'tool', toolCallId: 'c2', isError: true, content: [{ type: 'text', text: RESULT_ERR }] },
    }),
    ev('assistant/message', {
      turn: 1, step: 4,
      message: { role: 'assistant', content: [{ type: 'text', text: ANSWER }] },
    }),
    ev('turn/end', { turn: 1, reason: { kind: 'completed' } }, 1_700_000_001_500),
  ]
}

test('能力名与版本号是新增的，不改动 v1 的 history-fold-summary', () => {
  assert.equal(SUMMARY_FOLD_MODE, 'summary')
  assert.equal(SUMMARY_FOLD_VERSION, 2)
  assert.equal(SUMMARY_FOLD_CAPABILITY, 'history-fold-summary-v2')
  assert.equal(SUMMARY_PREVIEW_CHARS, 80)
  assert.equal(FOLD_RECORD_TYPE, '+link/fold')
})

test('活动类别与桌面同一口径（read/search/commands/… 与 tools 兜底）', () => {
  assert.equal(activityKind('read'), 'read')
  assert.equal(activityKind('read_image'), 'readImage')
  assert.equal(activityKind('grep'), 'search')
  assert.equal(activityKind('glob'), 'search')
  assert.equal(activityKind('write'), 'write')
  assert.equal(activityKind('edit'), 'edit')
  assert.equal(activityKind('apply_patch'), 'edit')
  assert.equal(activityKind('bash'), 'commands')
  assert.equal(activityKind('terminal_send'), 'commands')
  assert.equal(activityKind('run_code'), 'code')
  assert.equal(activityKind('web_search'), 'webSearch')
  assert.equal(activityKind('web_fetch'), 'webFetch')
  assert.equal(activityKind('subagent_batch'), 'subagents')
  assert.equal(activityKind('todo_write'), 'plan')
  assert.equal(activityKind('ask_user_question'), 'questions')
  assert.equal(activityKind('send_image'), 'tools')
  assert.equal(activityKind(undefined), 'tools')
})

test('概要 v2 的字段：轮次、时长、结束原因、活动计数与分组', () => {
  const { records, summaries } = projectTurnUnit(typicalTurn())
  assert.deepEqual(typesOf({ records }),
    ['turn/start', 'user/message', FOLD_RECORD_TYPE, 'assistant/message', FOLD_RECORD_TYPE,
      'assistant/message', 'turn/end'])
  assert.equal(summaries.length, 2)

  const [first, second] = summaries
  assert.equal(first.v, 2)
  assert.equal(first.turn, 1)
  assert.equal(first.durationMs, 1500)
  assert.equal(first.endReason, 'completed')
  // 每段一条：第一段是 seq3..5（思考 + bash + 结果），第二段是 seq8..10（思考 + grep + 结果）
  assert.equal(first.startSeq, 3)
  assert.equal(first.endSeq, 5)
  // 只数工具步骤（思考不算活动，桌面 `processActivity` 同口径；纯思考分组标题是
  // "已完成分析"，由客户端按空 activities 兜底）
  assert.deepEqual(first.activities, { commands: 1 })
  assert.equal(first.groups.length, 1)
  const group = first.groups[0]
  assert.equal(group.startSeq, 3)
  assert.equal(group.endSeq, 5)
  assert.deepEqual(group.activities, { commands: 1 })
  assert.equal(group.toolCount, 1)
  assert.deepEqual(group.steps, [
    { seq: 3, kind: 'reasoning', name: 'thinking', preview: '', status: 'ok',
      bytes: Buffer.byteLength(REASONING, 'utf8') },
    { seq: 4, kind: 'tools', name: 'bash', preview: ARGS_LONG.slice(0, SUMMARY_PREVIEW_CHARS),
      status: 'ok', resultSeq: 5, bytes: Buffer.byteLength(RESULT_OK, 'utf8') },
  ])

  assert.equal(second.turn, 1)
  assert.equal(second.startSeq, 8)
  assert.equal(second.endSeq, 10)
  assert.deepEqual(second.activities, { search: 1 })
  assert.deepEqual(second.groups[0].steps, [
    { seq: 8, kind: 'reasoning', name: 'thinking', preview: '', status: 'ok',
      bytes: Buffer.byteLength(REASONING, 'utf8') },
    { seq: 9, kind: 'tools', name: 'grep', preview: '{"pattern":"TODO"}',
      status: 'error', resultSeq: 10, bytes: Buffer.byteLength(RESULT_ERR, 'utf8') },
  ])
})

test('中间讲话保留为正文行；正文行只含 text 块（reasoning 块被摘掉）', () => {
  const { records } = projectTurnUnit(typicalTurn())
  const texts = records
    .filter((record) => record.event.type === 'assistant/message')
    .map((record) => record.event.data.message.content)
  assert.deepEqual(texts, [
    [{ type: 'text', text: '中间讲话：先看目录结构。' }],
    [{ type: 'text', text: ANSWER }],
  ])
})

test('reasoning 正文、tool 正文、完整 args 都不进回包（只有 preview 与字节数）', () => {
  const { records } = projectTurnUnit(typicalTurn())
  const wire = JSON.stringify(records)
  assert.equal(wire.includes(REASONING), false, 'reasoning 正文不许下发')
  assert.equal(wire.includes(RESULT_OK), false, '工具结果正文不许下发')
  assert.equal(wire.includes(RESULT_ERR), false, '失败结果的正文同样不许下发')
  assert.equal(wire.includes(ARGS_LONG), false, '完整 args 不许下发（只有前 80 字）')
  assert.equal(wire.includes('"arguments"'), false, 'args 这个键本身也不出现')
  // 工具调用事件整条不出现：它已折进摘要的 steps
  assert.deepEqual(records.map((r) => r.event.type).filter((t) => t.startsWith('tool/')), [])
  // 中间讲话与正式回答都在
  assert.equal(wire.includes('中间讲话：先看目录结构。'), true)
  assert.equal(wire.includes(ANSWER), true)
})

test('assistant 图文回答：text 与 image 块都留，attachment 只留元数据（内联字节清掉）', () => {
  reset()
  const inline = 'A'.repeat(200_000)
  const attachment = {
    attachmentId: 'sha256:aa11',
    mediaType: 'image/png',
    bytes: 12_345,
    width: 390,
    height: 844,
    name: 'shot.png',
    originalDimensions: { width: 1170, height: 2532 },
    data: inline,
    base64: inline,
  }
  const { records } = projectTurnUnit([
    ev('turn/start', { turn: 1 }),
    ev('user/message', { content: [{ type: 'text', text: '画个图' }], source: { kind: 'user' } }),
    ev('assistant/message', {
      turn: 1,
      message: { role: 'assistant', content: [{ type: 'text', text: '图在这里' }, { type: 'image', attachment }] },
    }),
    ev('turn/end', { turn: 1, reason: { kind: 'completed' } }),
  ])
  const message = records.find((record) => record.event.type === 'assistant/message')
  assert.deepEqual(message.event.data.message.content, [
    { type: 'text', text: '图在这里' },
    {
      type: 'image',
      attachment: {
        attachmentId: 'sha256:aa11',
        mediaType: 'image/png',
        bytes: 12_345,
        width: 390,
        height: 844,
        name: 'shot.png',
        originalDimensions: { width: 1170, height: 2532 },
      },
    },
  ])
  assert.equal(JSON.stringify(records).includes(inline), false, 'base64 正文不许下发')
  assert.equal(JSON.stringify(records).includes('"base64"'), false)
})

test('agent 代发的纯图回答（splice 通道）不丢：图片元数据保留、内联字节清掉', () => {
  reset()
  const { records } = projectTurnUnit([
    ev('turn/start', { turn: 2 }),
    ev('agent/inbox/spliced', {
      target: 'next-turn',
      start: 0,
      inserted: [{
        role: 'user',
        id: 'm1',
        source: { kind: 'agent', rpcId: 'agent-77' },
        content: [{
          type: 'image',
          attachment: {
            attachmentId: 'sha256:bb22',
            mediaType: 'image/jpeg',
            bytes: 999,
            width: 100,
            height: 200,
            name: '📷图.jpg',
            url: 'https://example.com/x.jpg',
            data: 'B'.repeat(1000),
          },
        }],
      }],
    }),
    ev('assistant/message', { turn: 2, message: { content: [{ type: 'text', text: '发给你了' }] } }),
    ev('turn/end', { turn: 2, reason: { kind: 'completed' } }),
  ])
  assert.deepEqual(typesOf({ records }),
    ['turn/start', 'agent/inbox/spliced', 'assistant/message', 'turn/end'])
  const spliced = records.find((record) => record.event.type === 'agent/inbox/spliced')
  assert.equal(spliced.event.data.target, 'next-turn')
  assert.deepEqual(spliced.event.data.inserted, [{
    role: 'user',
    id: 'm1',
    source: { kind: 'agent', rpcId: 'agent-77' },
    content: [{
      type: 'image',
      attachment: {
        attachmentId: 'sha256:bb22',
        mediaType: 'image/jpeg',
        bytes: 999,
        width: 100,
        height: 200,
        name: '📷图.jpg',
        url: 'https://example.com/x.jpg',
      },
    }],
  }])
  assert.equal(JSON.stringify(records).includes('B'.repeat(1000)), false)
})

test('图文混合回答：块顺序保持，工具块摘掉，data: URI 与超长字符串当内联字节丢掉', () => {
  reset()
  const { records } = projectTurnUnit([
    ev('turn/start', { turn: 3 }),
    ev('user/message', {
      content: [
        { type: 'text', text: '这两张图对比一下' },
        { type: 'image', attachment: { attachmentId: 'sha256:u1', mediaType: 'image/png', bytes: 10 } },
      ],
      source: { kind: 'user', rpcId: 'r3' },
    }),
    ev('assistant/message', {
      turn: 3,
      message: {
        role: 'assistant',
        content: [
          { type: 'text', text: '第一张正常' },
          { type: 'image', attachment: { attachmentId: 'sha256:c1', url: 'data:image/png;base64,AAAA', bytes: 42 } },
          { type: 'tool-call', id: 'x', name: 'bash', arguments: '{"command":"ls"}' },
          { type: 'file', attachment: { attachmentId: 'sha256:f1', name: 'report.pdf', bytes: 4096 } },
          { type: 'image', attachment: { attachmentId: 'sha256:c2', url: `https://example.com/${'q'.repeat(600)}`, width: 10 } },
          { type: 'text', text: '第二张有问题' },
        ],
      },
    }),
    ev('turn/end', { turn: 3, reason: { kind: 'completed' } }),
  ])
  const userMessage = records.find((record) => record.event.type === 'user/message')
  assert.deepEqual(userMessage.event.data.content, [
    { type: 'text', text: '这两张图对比一下' },
    { type: 'image', attachment: { attachmentId: 'sha256:u1', mediaType: 'image/png', bytes: 10 } },
  ])
  const message = records.find((record) => record.event.type === 'assistant/message')
  assert.deepEqual(message.event.data.message.content, [
    { type: 'text', text: '第一张正常' },
    { type: 'image', attachment: { attachmentId: 'sha256:c1', bytes: 42 } },
    { type: 'file', attachment: { attachmentId: 'sha256:f1', name: 'report.pdf', bytes: 4096 } },
    { type: 'image', attachment: { attachmentId: 'sha256:c2', width: 10 } },
    { type: 'text', text: '第二张有问题' },
  ])
  const wire = JSON.stringify(records)
  assert.equal(wire.includes('data:image/png'), false, 'data: URI 是内联字节')
  assert.equal(wire.includes('q'.repeat(600)), false, '超长 url 当内联负载丢掉')
})

test('preview 折叠空白并截断到 80 字；args 不是字符串时给空串', () => {
  reset()
  const long = `{\n  "command": "  ls   -la  ${'y'.repeat(120)}"\n}`
  const { summaries } = projectTurnUnit([
    ev('turn/start', { turn: 1 }),
    ev('tool/call', { turn: 1, callId: 'c1', name: 'bash', arguments: long }),
  ])
  const preview = summaries[0].groups[0].steps[0].preview
  assert.equal(preview.length, SUMMARY_PREVIEW_CHARS)
  assert.equal(preview, long.replace(/\s+/g, ' ').trim().slice(0, SUMMARY_PREVIEW_CHARS))
  assert.equal(/\s{2}/.test(preview), false, '连续空白要折叠')

  reset()
  const noArgs = projectTurnUnit([
    ev('turn/start', { turn: 1 }),
    ev('tool/call', { turn: 1, callId: 'c1', name: 'todo_write' }),
  ])
  assert.equal(noArgs.summaries[0].groups[0].steps[0].preview, '')
})

test('纯思考的分组 activities 为空（桌面标题"已完成分析"由客户端兜底）', () => {
  reset()
  const { summaries } = projectTurnUnit([
    ev('turn/start', { turn: 1 }),
    ev('assistant/message', { turn: 1, message: { content: [{ type: 'reasoning', text: '想一会儿' }] } }),
    ev('assistant/message', { turn: 1, message: { content: [{ type: 'text', text: '答' }] } }),
  ])
  assert.deepEqual(summaries[0].activities, {})
  assert.deepEqual(summaries[0].groups[0].activities, {})
  assert.equal(summaries[0].groups[0].toolCount, 0)
  assert.deepEqual(summaries[0].groups[0].steps.map((step) => step.kind), ['reasoning'])
})

test('运行中的工具给 running，且没有 bytes/resultSeq（结果还没取）', () => {
  reset()
  const { summaries } = projectTurnUnit([
    ev('turn/start', { turn: 4 }),
    ev('user/message', { content: [{ type: 'text', text: '跑测试' }], source: { kind: 'user' } }),
    ev('tool/call', { turn: 4, callId: 'c9', name: 'bash', arguments: '{"command":"npm test"}' }),
  ])
  const step = summaries[0].groups[0].steps[0]
  assert.equal(step.status, 'running')
  assert.equal('bytes' in step, false)
  assert.equal('resultSeq' in step, false)
  // 轮次还没结束：时长与结束原因都是 null（如实表示"不知道"，不编造）
  assert.equal(summaries[0].durationMs, null)
  assert.equal(summaries[0].endReason, null)
  assert.equal(summaries[0].turn, 4)
})

test('压缩与错误通知保留并切开过程段；用户消息与轮次边界保留', () => {
  reset()
  const { records, summaries } = projectTurnUnit([
    ev('turn/start', { turn: 2 }),
    ev('user/message', { content: [{ type: 'text', text: '问' }], source: { kind: 'user' } }),
    ev('tool/call', { turn: 2, callId: 'c1', name: 'bash', arguments: '{}' }),
    ev('compaction/summary', { compactionId: 'cp1', summary: [{ type: 'text', text: '压缩了' }] }),
    ev('tool/call', { turn: 2, callId: 'c2', name: 'bash', arguments: '{}' }),
    ev('agent/error', { message: '出了点问题' }),
    ev('assistant/message', { turn: 2, message: { content: [{ type: 'text', text: '答' }] } }),
    ev('turn/end', { turn: 2, reason: { kind: 'aborted' } }),
  ])
  assert.deepEqual(typesOf({ records }), [
    'turn/start', 'user/message', FOLD_RECORD_TYPE, 'compaction/summary', FOLD_RECORD_TYPE,
    'agent/error', 'assistant/message', 'turn/end',
  ])
  assert.equal(summaries.length, 2)
  assert.equal(summaries[0].endReason, 'aborted')
})

test('不渲染的宿主事件整条丢掉（request/header、step/*、goal、title、注入消息）', () => {
  reset()
  const { records } = projectTurnUnit([
    ev('request/header', { text: 'x'.repeat(500) }),
    ev('turn/start', { turn: 1 }),
    ev('user/message', { content: [{ type: 'text', text: '运行时注入' }], source: { kind: 'runtime-context' } }),
    ev('step/start', { turn: 1, step: 1 }),
    ev('tool/call', { turn: 1, callId: 'c1', name: 'bash', arguments: '{}' }),
    ev('step/end', { turn: 1, step: 1 }),
    ev('goal/change', { goal: 'x' }),
    ev('title/change', { title: 't' }),
    ev('turn/end', { turn: 1, reason: { kind: 'completed' } }),
  ])
  assert.deepEqual(typesOf({ records }), ['turn/start', FOLD_RECORD_TYPE, 'turn/end'])
})

test('生产形态 data.message.content 与裸 data.text 都认得', () => {
  reset()
  const fromMessage = projectTurnUnit([
    ev('turn/start', { turn: 1 }),
    ev('assistant/message', { turn: 1, message: { role: 'assistant', content: [{ type: 'text', text: '生产形态' }] } }),
  ])
  assert.deepEqual(fromMessage.records[1].event.data.message.content, [{ type: 'text', text: '生产形态' }])

  reset()
  const bare = projectTurnUnit([
    ev('turn/start', { turn: 1 }),
    ev('assistant/message', { turn: 1, text: '裸文本形态' }),
  ])
  assert.deepEqual(bare.records[1].event.data.message.content, [{ type: 'text', text: '裸文本形态' }])
})

test('没有轮次边界的事件段（日志被裁剪）也能投影，不造假轮次号', () => {
  reset()
  const { records, summaries } = projectTurnUnit([
    ev('tool/call', { callId: 'c1', name: 'bash', arguments: '{}' }),
    ev('tool/result', { message: { toolCallId: 'c1', content: [{ type: 'text', text: '输出' }] } }),
    ev('assistant/message', { message: { content: [{ type: 'text', text: '最后一句' }] } }),
  ])
  assert.deepEqual(typesOf({ records }), [FOLD_RECORD_TYPE, 'assistant/message'])
  assert.equal(summaries[0].turn, null)
  assert.equal(summaries[0].endReason, null)
})

import test from 'node:test'
import assert from 'node:assert/strict'

import { FOLD_RECORD_TYPE, foldProcessRuns } from '../lib/history/fold.js'

let seq = 0
function event(type, data = {}, at) {
  seq += 1
  return { type, seq: at ?? seq, time: 1_700_000_000_000 + (at ?? seq), data }
}
function reset() { seq = 0 }
function records(events) { return events.map((event) => ({ type: 'event', event })) }
function types(out) { return out.map((record) => record.event.type) }

test('连续过程段折成一条摘要：用户消息、页内最后回答、轮次结束都保留', () => {
  reset()
  const events = [
    event('turn/start', { turn: 1 }),
    event('user/message', { content: [{ type: 'text', text: '问题' }], source: { kind: 'user' } }),
    event('assistant/message', { turn: 1, content: [{ type: 'reasoning', text: '想' }] }),
    event('tool/call', { callId: 'c1', name: 'bash', arguments: '{}' }),
    event('tool/result', { callId: 'c1', content: [{ type: 'text', text: '输出' }] }),
    event('assistant/message', { turn: 1, content: [{ type: 'text', text: '最终回答' }] }),
    event('turn/end', { turn: 1, reason: { kind: 'completed' } }),
  ]
  const { records: out, folds } = foldProcessRuns(records(events))
  assert.deepEqual(types(out), ['turn/start', 'user/message', FOLD_RECORD_TYPE, 'assistant/message', 'turn/end'])
  assert.equal(folds.length, 1)
  assert.equal(folds[0].toolCount, 1)
  assert.equal(folds[0].reasoningCount, 1)
  assert.equal(folds[0].messageCount, 1)
  assert.equal(folds[0].foldedCount, 3)
  assert.equal(folds[0].startSeq, events[2].seq)
  assert.equal(folds[0].endSeq, events[4].seq)
  assert.equal(out[2].event.seq, events[2].seq)
})

test('页内最后一条助手回答永远不折（可能是最终回答或这一屏唯一正文）', () => {
  reset()
  const { records: out, folds } = foldProcessRuns(records([
    event('user/message', { content: [{ type: 'text', text: '问' }] }),
    event('assistant/message', { content: [{ type: 'text', text: '中间' }] }),
    event('assistant/message', { content: [{ type: 'text', text: '最后' }] }),
  ]))
  assert.equal(folds.length, 1)
  assert.deepEqual(types(out), ['user/message', FOLD_RECORD_TYPE, 'assistant/message'])
  const kept = out[2].event
  assert.equal(kept.data.content[0].text, '最后')
})

test('不渲染的事件整条丢掉（request/header、step、goal、title）', () => {
  reset()
  const { records: out, folds } = foldProcessRuns(records([
    event('request/header', { text: 'x'.repeat(1000) }),
    event('user/message', { content: [{ type: 'text', text: '问' }] }),
    event('step/start', { turn: 1, step: 1 }),
    event('step/end', { turn: 1, step: 1 }),
    event('goal/change', {}),
    event('assistant/message', { content: [{ type: 'text', text: '答' }] }),
    event('title/change', { title: 't' }),
  ]))
  assert.equal(folds.length, 0)
  assert.deepEqual(types(out), ['user/message', 'assistant/message'])
})

test('压缩与错误通知保留，并把过程段切开', () => {
  reset()
  const { records: out } = foldProcessRuns(records([
    event('user/message', { content: [{ type: 'text', text: '问' }] }),
    event('tool/call', { callId: 'c1', name: 'bash' }),
    event('compaction/summary', { summary: '压缩了' }),
    event('tool/call', { callId: 'c2', name: 'bash' }),
    event('assistant/message', { content: [{ type: 'text', text: '答' }] }),
  ]))
  assert.deepEqual(types(out),
    ['user/message', FOLD_RECORD_TYPE, 'compaction/summary', FOLD_RECORD_TYPE, 'assistant/message'])
})

test('多个过程段各自成一条摘要（跨页轮次也能受益）', () => {
  reset()
  const { records: out, folds } = foldProcessRuns(records([
    event('turn/start', { turn: 4 }),
    event('tool/call', { callId: 'a', name: 'bash' }),
    event('tool/result', { callId: 'a', content: [] }),
    event('assistant/message', { content: [{ type: 'text', text: '中间说明' }] }),
    event('tool/call', { callId: 'b', name: 'bash' }),
    event('tool/result', { callId: 'b', content: [] }),
    event('assistant/message', { content: [{ type: 'text', text: '最终' }] }),
    event('turn/end', { turn: 4, reason: { kind: 'completed' } }),
  ]))
  // 最后一条回答受保护；它前面的两段被中间说明与工具调用连成一段（无可见行切开）。
  assert.equal(folds.length, 1)
  assert.deepEqual(types(out), ['turn/start', FOLD_RECORD_TYPE, 'assistant/message', 'turn/end'])
})

test('页首/页尾从轮次中间开始或结束也不影响（按过程段折）', () => {
  reset()
  const running = foldProcessRuns(records([
    event('tool/call', { callId: 'c1', name: 'bash' }),
    event('tool/result', { callId: 'c1', content: [] }),
    event('assistant/message', { content: [{ type: 'text', text: '进行中的最后一句' }] }),
  ]))
  assert.equal(running.folds.length, 1)
  assert.deepEqual(types(running.records), [FOLD_RECORD_TYPE, 'assistant/message'])
})

test('只有保留事件时输出与输入逐条相同', () => {
  reset()
  const input = records([
    event('turn/start', { turn: 1 }),
    event('user/message', { content: [{ type: 'text', text: '问' }] }),
    event('assistant/message', { content: [{ type: 'text', text: '答' }] }),
    event('turn/end', { turn: 1, reason: { kind: 'completed' } }),
  ])
  const { records: out, folds } = foldProcessRuns(input)
  assert.equal(folds.length, 0)
  assert.deepEqual(out, input)
})

test('轮次外的非渲染事件也丢掉（不影响轮次内折叠）', () => {
  reset()
  const before = event('request/header', {})
  const { records: out, folds } = foldProcessRuns(records([
    before,
    event('user/message', { content: [{ type: 'text', text: '问' }] }),
    event('tool/call', { callId: 'c1', name: 'bash' }),
    event('assistant/message', { content: [{ type: 'text', text: '答' }] }),
  ]))
  assert.equal(folds.length, 1)
  assert.deepEqual(types(out), ['user/message', FOLD_RECORD_TYPE, 'assistant/message'])
})

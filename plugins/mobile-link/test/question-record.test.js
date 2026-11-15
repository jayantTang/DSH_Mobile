/**
 * 作答记录（`+link/question`）的投影单测。
 *
 * 需求 SR-02.16：用户提交答案后，问题与答案要作为独立记录留在会话里；折叠模式
 * 不能把它跟着过程一起藏掉，也不能把原始 JSON 当作答案正文下发。
 *
 * 覆盖：
 * - 问题/答案的解析与降级（参数缺失、pending、坏形状、超长截断）；
 * - v1（`fold:true`）与 v2（`fold:"summary"`）都下发记录；
 * - 记录排在过程摘要之后、按 seq 有序；
 * - 没有提问的轮次输出逐字节不变。
 */

import test from 'node:test'
import assert from 'node:assert/strict'

import { projectTurnUnit } from '../lib/history/fold-summary.js'
import { foldProcessRuns, FOLD_RECORD_TYPE } from '../lib/history/fold.js'
import {
  QUESTION_RECORD_TYPE, QUESTION_TEXT_LIMIT,
  answersOf, isQuestionTool, questionRecordFor, questionsOf,
} from '../lib/history/question-record.js'

let seq = 0
function ev(type, data = {}, time) {
  seq += 1
  const at = seq - 1
  return { type, seq: at, time: time ?? 1_700_000_000_000 + at, data }
}
function reset() { seq = 0 }
const typesOf = (records) => records.map((record) => record.event.type)

const QUESTIONS = [
  { id: 'q1', question: '用哪套配色？', header: '配色', options: [{ label: '深色' }, { label: '浅色' }] },
  { id: 'q2', question: '要附截图吗？', multi_select: false },
]
const ARGS = JSON.stringify({ questions: QUESTIONS })
const ANSWER_OK = JSON.stringify({
  answers: [
    { id: 'q1', selected: ['深色'] },
    { id: 'q2', selected: [], custom: '不用了' },
  ],
})

function questionTurn(resultText = ANSWER_OK) {
  reset()
  return [
    ev('turn/start', { turn: 1 }),
    ev('user/message', { content: [{ type: 'text', text: '帮我选一下' }], source: { kind: 'user' } }),
    ev('tool/call', { turn: 1, step: 1, callId: 'ask-1', name: 'ask_user_question', arguments: ARGS }),
    ev('tool/result', {
      turn: 1, step: 1,
      message: { role: 'tool', toolCallId: 'ask-1', content: [{ type: 'text', text: resultText }] },
    }),
    ev('assistant/message', { turn: 1, step: 2, message: { content: [{ type: 'text', text: '好，用深色。' }] } }),
    ev('turn/end', { turn: 1, reason: { kind: 'completed' } }),
  ]
}

test('工具名判定：只认真实的提问工具', () => {
  assert.equal(isQuestionTool('ask_user_question'), true)
  assert.equal(isQuestionTool('request_user_input'), true)
  assert.equal(isQuestionTool('bash'), false)
  assert.equal(isQuestionTool(undefined), false)
})

test('问题解析：蛇形/驼峰都收，缺字段整份不要，超长截断不切开 emoji', () => {
  assert.deepEqual(questionsOf(ARGS).map((q) => q.id), ['q1', 'q2'])
  assert.equal(questionsOf(ARGS)[0].header, '配色')

  const camel = JSON.stringify({ questions: [{ id: 'q', question: '问题', multiSelect: true }] })
  assert.equal(questionsOf(camel).length, 1)

  assert.deepEqual(questionsOf('not json'), [])
  assert.deepEqual(questionsOf(JSON.stringify({ questions: [{ id: 'q' }] })), [])
  assert.deepEqual(questionsOf(JSON.stringify({ questions: [] })), [])

  const long = `${'😀'.repeat(QUESTION_TEXT_LIMIT)}`
  const capped = questionsOf(JSON.stringify({ questions: [{ id: 'q', question: long }] }))[0].question
  assert.equal(capped.endsWith('…'), true)
  const body = capped.slice(0, -1)
  const last = body.charCodeAt(body.length - 1)
  assert.equal(last >= 0xd800 && last <= 0xdbff, false, '截断不许留下落单代理项')
})

test('答案解析：pending 与坏形状返回 null，空批次是空数组', () => {
  assert.equal(answersOf(JSON.stringify({ pending: true, callId: 'x' })), null)
  assert.equal(answersOf('not json'), null)
  assert.equal(answersOf(JSON.stringify({ answers: [{ id: 'q', selected: 'x' }] })), null)
  assert.deepEqual(answersOf(JSON.stringify({ answers: [] })), [])
  assert.deepEqual(answersOf(ANSWER_OK), [
    { id: 'q1', selected: ['深色'] },
    { id: 'q2', selected: [], custom: '不用了' },
  ])
})

test('记录组装：只发已结算批次；参数缺失时仍带答案', () => {
  const call = { callId: 'ask-1', name: 'ask_user_question', arguments: ARGS }
  const record = questionRecordFor({ call, resultText: ANSWER_OK, seq: 7, time: 99 })
  assert.equal(record.type, QUESTION_RECORD_TYPE)
  assert.equal(record.seq, 7)
  assert.equal(record.data.callId, 'ask-1')
  assert.equal(record.data.questions.length, 2)
  assert.equal(record.data.answers[1].custom, '不用了')

  assert.equal(questionRecordFor({ call, resultText: JSON.stringify({ pending: true, callId: 'ask-1' }), seq: 7 }), null)
  assert.equal(questionRecordFor({ call: { ...call, name: 'bash' }, resultText: ANSWER_OK, seq: 7 }), null)
  assert.equal(questionRecordFor({ call: { ...call, callId: '' }, resultText: ANSWER_OK, seq: 7 }), null)

  const noQuestions = questionRecordFor({ call: { ...call, arguments: '' }, resultText: ANSWER_OK, seq: 7 })
  assert.deepEqual(noQuestions.data.questions, [])
  assert.equal(noQuestions.data.answers.length, 2)
})

test('概要 v2：作答记录独立下发，排在过程摘要之后、原始结果正文不外泄', () => {
  const { records } = projectTurnUnit(questionTurn())
  assert.deepEqual(typesOf(records),
    ['turn/start', 'user/message', FOLD_RECORD_TYPE, QUESTION_RECORD_TYPE, 'assistant/message', 'turn/end'])

  const wire = JSON.stringify(records)
  assert.equal(wire.includes('"answers"'), true)
  assert.equal(wire.includes('深色'), true)
  assert.equal(wire.includes('不用了'), true)
  // 工具结果原始 JSON 不作为 tool/result 正文下发：只留记录里那一份。
  assert.equal(records.some((record) => record.event.type === 'tool/result'), false)
  assert.equal(wire.includes('"role":"tool"'), false)

  const record = records.find((entry) => entry.event.type === QUESTION_RECORD_TYPE).event
  assert.equal(record.seq, 3)
  assert.equal(record.data.questions[0].question, '用哪套配色？')
})

test('概要 v2：pending（还没结算）不下发记录，工具调用仍按步骤计数', () => {
  const pending = JSON.stringify({ pending: true, callId: 'ask-1' })
  const { records, summaries } = projectTurnUnit(questionTurn(pending))
  assert.equal(typesOf(records).includes(QUESTION_RECORD_TYPE), false)
  assert.equal(summaries[0].groups[0].steps.length, 1)
  assert.equal(summaries[0].groups[0].steps[0].name, 'ask_user_question')
})

test('v1 折叠：作答记录同样下发，且排在对应的 +link/fold 之后', () => {
  const { records } = foldProcessRuns(questionTurn().map((event) => ({ type: 'event', event })))
  const types = typesOf(records)
  assert.deepEqual(types,
    ['turn/start', 'user/message', FOLD_RECORD_TYPE, QUESTION_RECORD_TYPE, 'assistant/message', 'turn/end'])
  const record = records.find((entry) => entry.event.type === QUESTION_RECORD_TYPE).event
  assert.equal(record.data.callId, 'ask-1')
  assert.equal(record.data.answers[0].selected[0], '深色')
})

test('没有提问的轮次：v1/v2 输出不变', () => {
  reset()
  const events = [
    ev('turn/start', { turn: 1 }),
    ev('user/message', { content: [{ type: 'text', text: '列目录' }], source: { kind: 'user' } }),
    ev('tool/call', { turn: 1, step: 1, callId: 'c1', name: 'bash', arguments: '{"command":"ls"}' }),
    ev('tool/result', { turn: 1, step: 1, message: { toolCallId: 'c1', content: [{ type: 'text', text: 'a.txt' }] } }),
    ev('turn/end', { turn: 1, reason: { kind: 'completed' } }),
  ]
  const v2 = projectTurnUnit(events)
  assert.deepEqual(typesOf(v2.records), ['turn/start', 'user/message', FOLD_RECORD_TYPE, 'turn/end'])
  const v1 = foldProcessRuns(events.map((event) => ({ type: 'event', event })))
  assert.deepEqual(typesOf(v1.records), ['turn/start', 'user/message', FOLD_RECORD_TYPE, 'turn/end'])
})

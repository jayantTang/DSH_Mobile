/**
 * Routing tests for the DLP agent. A fake relay socket and a fake DSH client
 * drive `handleRelayFrame`, so no network or DSH instance is involved.
 */

import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { readFileSync, rmSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { MobileLinkAgent } from '../lib/link.js'

const setTimeoutFnReal = setTimeout

class FakeSocket {
  constructor() {
    this.sent = []
    this.closed = false
    this.closeCode = undefined
  }

  send(text) {
    this.sent.push(JSON.parse(text))
  }

  close(code) {
    this.closed = true
    this.closeCode = code
  }

  frames(type) {
    return this.sent.filter((frame) => frame.t === type)
  }

  last(type) {
    const frames = this.frames(type)
    return frames[frames.length - 1]
  }
}

class FakeDsh extends EventEmitter {
  constructor() {
    super()
    this.calls = []
    this.muxReady = true
    this.cookie = 'dsh-auth-test=v1'
    this.endpoint = { base: 'http://127.0.0.1:54499', port: 54499, source: 'test' }
    this.responses = new Map()
    this.rpcError = undefined
  }

  async ensureMux() {
    return { closed: false }
  }

  openStream(muxId, endpoint, args) {
    this.calls.push({ kind: 'open', muxId, endpoint, args })
  }

  cancelStream(muxId) {
    this.calls.push({ kind: 'cancel', muxId })
  }

  async rpc(method, args) {
    this.calls.push({ kind: 'rpc', method, args })
    if (this.rpcError) throw this.rpcError
    return this.responses.get(method) ?? { ok: true, value: { items: [] } }
  }

  close() {
    this.closed = true
  }

  opens() {
    return this.calls.filter((call) => call.kind === 'open')
  }

  cancels() {
    return this.calls.filter((call) => call.kind === 'cancel')
  }
}

function makeAgent({ responses, notify } = {}) {
  const dsh = new FakeDsh()
  if (responses) for (const [method, value] of Object.entries(responses)) dsh.responses.set(method, value)
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({
    dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1',
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test', agentName: 'test mac' }
  const socket = new FakeSocket()
  agent.socket = socket
  // 桩：`notify` 的默认实现是往 relay socket 上发 `{t:'notify'}`；这里替换成记账，
  // 单测要断言的就是"报了什么"（`socket.frames('notify')` 走的是真实现那条路）。
  if (notify) agent.router.notify = notify
  return { agent, dsh, socket }
}

const attach = (deviceId = 'dev_1') => ({ t: 'deviceAttach', deviceId, device: { name: 'iPhone', model: 'iPhone17,1' } })
const ready = (clientId = 'client_1') => ({ type: 'ready', clientId, host: { home: '/Users/x' } })

test('deviceAttach opens one $events stream per device', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(attach('dev_2'))
  const opens = dsh.opens()
  assert.deepEqual(opens.map((call) => call.muxId).sort(), ['ev:dev_1', 'ev:dev_2'])
  assert.deepEqual(opens[0].args, {})
  assert.equal(agent.devices.size, 2)

  // A duplicate attach is ignored (the relay re-attaches only after a reconnect).
  await agent.handleRelayFrame(attach('dev_1'))
  assert.equal(dsh.opens().length, 2)
})

test('the ready frame records the per-device clientId and is forwarded', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('client_9'))
  assert.equal(agent.devices.get('dev_1').clientId, 'client_9')
  assert.deepEqual(socket.last('event').value, { type: 'ready', clientId: 'client_9', host: { home: '/Users/x' } })
})

test('$events items become `event` frames until the device opens the stream', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'session/updated', args: [1] })
  assert.equal(socket.frames('event').length, 2)
  assert.equal(socket.frames('item').length, 0)

  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'session/updated', args: [2] })
  const item = socket.last('item')
  assert.equal(item.id, '2')
  assert.equal(item.deviceId, 'dev_1')
  assert.equal(item.value.args[0], 2)
  assert.equal(socket.frames('event').length, 2)
})

test('req is answered with res, preserving id and addressing', async () => {
  const { agent, dsh, socket } = makeAgent({
    responses: { 'session/list': { ok: true, value: { items: [{ sessionId: 's-1' }] } } },
  })
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'req', id: '1', method: 'session/list', args: { _request: {} }, deviceId: 'dev_1' })
  const res = socket.last('res')
  assert.equal(res.id, '1')
  assert.equal(res.deviceId, 'dev_1')
  assert.equal(res.ok, true)
  assert.deepEqual(res.value.items, [{ sessionId: 's-1' }])
  assert.deepEqual(dsh.calls.filter((call) => call.kind === 'rpc')[0].args, { _request: {} })
})

test('a failing DSH call becomes res ok:false with the DSH error shape', async () => {
  const { agent, socket } = makeAgent({
    responses: { 'session/page': { ok: false, error: { code: 'session/unknown', message: 'no such session', details: { id: 'x' } } } },
  })
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'req', id: '7', method: 'session/page', args: {}, deviceId: 'dev_1' })
  const res = socket.last('res')
  assert.equal(res.ok, false)
  assert.deepEqual(res.error, { code: 'session/unknown', message: 'no such session', details: { id: 'x' } })
})

test('an unreachable DSH turns into a host/unavailable error, not a crash', async () => {
  const { agent, dsh, socket } = makeAgent()
  dsh.rpcError = new Error('connect ECONNREFUSED')
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'req', id: '8', method: 'session/list', args: {}, deviceId: 'dev_1' })
  const res = socket.last('res')
  assert.equal(res.ok, false)
  assert.equal(res.error.code, 'host/unavailable')
})

test('open allocates a per-device mux stream; cancel tears it down', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach())
  const open = { t: 'open', id: '2', endpoint: 'session/follow',
    args: { request: { address: { kind: 'session', sessionId: 's-1' } } }, deviceId: 'dev_1' }
  await agent.handleRelayFrame(open)
  const forwarded = dsh.opens().find((call) => call.endpoint === 'session/follow')
  assert.equal(forwarded.muxId, 's:dev_1:2')
  assert.deepEqual(forwarded.args, open.args)

  agent.onStreamItem(forwarded.muxId, { type: 'snapshot' })
  assert.deepEqual(agent.socket.last('item'), { t: 'item', id: '2', deviceId: 'dev_1', value: { type: 'snapshot' } })

  await agent.handleRelayFrame({ t: 'cancel', id: '2', deviceId: 'dev_1' })
  assert.deepEqual(dsh.cancels().at(-1), { kind: 'cancel', muxId: 's:dev_1:2' })
})

test('two devices may reuse the same DLP stream id', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(attach('dev_2'))
  const open = (deviceId) => ({ t: 'open', id: '5', endpoint: 'session/follow', args: {}, deviceId })
  await agent.handleRelayFrame(open('dev_1'))
  await agent.handleRelayFrame(open('dev_2'))
  const muxIds = dsh.opens().filter((call) => call.endpoint === 'session/follow').map((call) => call.muxId)
  assert.deepEqual(muxIds.sort(), ['s:dev_1:5', 's:dev_2:5'])
})

test('a duplicate open id is refused with streamError', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach())
  const open = { t: 'open', id: '5', endpoint: 'session/follow', args: {}, deviceId: 'dev_1' }
  await agent.handleRelayFrame(open)
  await agent.handleRelayFrame(open)
  assert.equal(socket.last('streamError').error.code, 'stream/duplicate')
})

test('stream error and end are mapped back to the owning device only', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(attach('dev_2'))
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: 'session/follow', args: {}, deviceId: 'dev_1' })
  const muxId = 's:dev_1:2'
  agent.onStreamError(muxId, { code: 'gateway/input-invalid', message: 'bad', details: { f: 1 } })
  const failure = socket.last('streamError')
  assert.equal(failure.id, '2')
  assert.equal(failure.deviceId, 'dev_1')
  assert.equal(failure.error.code, 'gateway/input-invalid')

  await agent.handleRelayFrame({ t: 'open', id: '3', endpoint: 'session/follow', args: {}, deviceId: 'dev_2' })
  agent.onStreamEnd('s:dev_2:3')
  assert.deepEqual(socket.last('end'), { t: 'end', id: '3', deviceId: 'dev_2' })
})

test('detaching a device cancels its ordinary streams but keeps $events on duty', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: 'session/follow', args: {}, deviceId: 'dev_1' })
  await agent.handleRelayFrame({ t: 'open', id: '3', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })

  // 普通流立刻撤；`$events` 留着替手机值班（不然这期间的提问会连同 Agent Context
  // 一起被 host 撤掉，用户回到手机就再也看不到）。
  assert.deepEqual(dsh.cancels().map((call) => call.muxId), ['s:dev_1:2'])
  assert.equal(agent.devices.size, 1)
  assert.equal(agent.streams.size, 1)
  assert.notEqual(agent.devices.get('dev_1').offlineSince, undefined)
})

test('a question raised while the phone is away is replayed when it comes back', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  await agent.handleRelayFrame({ t: 'open', id: '3', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })

  const question = {
    type: 'waterfall', event: 'user-questions/request', eventId: 'wf_1', agentId: 's-1', request: { args: {} },
  }
  agent.onStreamItem('ev:dev_1', question)
  // 攒着，不往一个已经断开的 socket 上发（发了也没人收）。
  assert.equal(socket.last('event')?.value?.eventId, undefined)
  assert.equal(agent.devices.get('dev_1').eventsPending.size, 1)

  // 手机回来了：ready 先补（App 要拿 clientId 才能回答），紧接着补发那条提问。
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'open', id: '4', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  const items = socket.frames('item').filter((frame) => frame.id === '4')
  assert.equal(items[0].value.type, 'ready')
  assert.equal(items[1].value.eventId, 'wf_1')
  // 送过之后**不能清空**：App 再重启一次还得能拿到它（除非有人回答了）。
  assert.equal(agent.devices.get('dev_1').eventsPending.size, 1)
})

test('an emit that happened while the phone was away is dropped, not replayed', async () => {
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  // emit 是"某事刚发生"的通知：几分钟后补发只会让 App 对着旧事件发通知。
  // 注：**"不补发" ≠ "不报一声"**——`turnEnd`/`attention` 照样会走 notify（见下面那组
  // 用例），区别只是它不进待答表、不占 `$events` 的补发额度。
  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'api-session/status', args: [{ sessionId: 's-1' }] })
  assert.equal(agent.devices.get('dev_1').eventsPending.size, 0)
})

// ── 「报一声」（C-02）────────────────────────────────────────────────────────
// 手机在不在线都要报：在线的手机自己会弹本地通知，报一声是给"离线"那一段用的；
// 中转按"这台设备此刻在不在线"决定推不推（在线不推，否则两条提醒一起响）。

test('离线时"跑完了"会报一声：{t:"notify", kind:"turnEnd", sid}', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })

  agent.onStreamItem('ev:dev_1', {
    type: 'emit', event: 'api-session/status', args: ['s-1', false],
  })
  assert.deepEqual(socket.last('notify'), { t: 'notify', kind: 'turnEnd', sid: 's-1' })
  // 报一声不改"攒什么"：emit 本来就不进待答表。
  assert.equal(agent.devices.get('dev_1').eventsPending.size, 0)
})

test('离线时的两种 waterfall 都报 attention，并且同时记账', async () => {
  for (const event of ['user-questions/request', 'approval/request']) {
    const { agent, socket } = makeAgent()
    await agent.handleRelayFrame(attach('dev_1'))
    await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
    agent.onStreamItem('ev:dev_1', {
      type: 'waterfall', event, eventId: `wf_${event}`, agentId: 's-1', request: {},
    })
    assert.deepEqual(socket.last('notify'), {
      t: 'notify', kind: 'attention', sid: 's-1', eid: `wf_${event}`,
    })
    // 报一声与记账是两件事：这条同时被攒下来，手机回来能补发。
    assert.equal(agent.devices.get('dev_1').eventsPending.size, 1, `${event} 没被记账`)
  }
})

test('不该报的三种一律不报：running=true / turn·end / api-session·error', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })

  // running=true 是"开跑了"，不是"跑完了"。
  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'api-session/status', args: ['s-1', true] })
  // `turn/end` 根本不在 `$events` 白名单上（它是 session/follow 的事件），这里模拟
  // "万一来了"也不该被当成"跑完了"。
  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'turn/end', args: [{ sessionId: 's-1' }] })
  // `api-session/error` 有意不推（见 router.js notifyFor 的注释）。
  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'api-session/error', args: ['s-1', 'boom'] })
  // sid 为空（`args[0]` 缺失）时也不发一条指向不了任何会话的提醒。
  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'api-session/status', args: [undefined, false] })

  assert.deepEqual(socket.frames('notify'), [])
})

test('在线时两条也都报一声（推不推由中转判，见 C-06）', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))

  agent.onStreamItem('ev:dev_1', { type: 'emit', event: 'api-session/status', args: ['s-1', false] })
  agent.onStreamItem('ev:dev_1', {
    type: 'waterfall', event: 'approval/request', eventId: 'wf_on', agentId: 's-2', request: {},
  })

  assert.deepEqual(socket.frames('notify').map((f) => [f.kind, f.sid, f.eid]), [
    ['turnEnd', 's-1', undefined],
    ['attention', 's-2', 'wf_on'],
  ])
  // 在线时照旧逐项转发给设备（`$events` 转发语义一字没改）。
  assert.ok(socket.frames('event').some((f) => f.value?.eventId === 'wf_on'))
})

test('an answered question is not replayed again', async () => {
  const { agent, dsh, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  await agent.handleRelayFrame({ t: 'open', id: '3', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  agent.onStreamItem('ev:dev_1', {
    type: 'waterfall', event: 'user-questions/request', eventId: 'wf_9', agentId: 's-1', request: {},
  })
  assert.equal(agent.devices.get('dev_1').eventsPending.size, 1)

  dsh.responses.set('$events/result', { ok: true, value: undefined })
  await agent.handleRelayFrame({
    t: 'eventResult', id: '7', deviceId: 'dev_1',
    result: { eventId: 'wf_9', outcome: { kind: 'result', value: { answers: [] } } },
  })
  assert.equal(agent.devices.get('dev_1').eventsPending.size, 0)

  // 重连一次：不该再冒出来
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  await agent.handleRelayFrame(attach('dev_1'))
  const before = socket.frames('item').length
  await agent.handleRelayFrame({ t: 'open', id: '5', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  const replayed = socket.frames('item').slice(before).filter((f) => f.value?.eventId === 'wf_9')
  assert.equal(replayed.length, 0)
})

test('a second reconnect still gets the same unanswered question', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  agent.onStreamItem('ev:dev_1', {
    type: 'waterfall', event: 'user-questions/request', eventId: 'wf_7', agentId: 's-1', request: {},
  })

  const countReplays = async (openId) => {
    await agent.handleRelayFrame(attach('dev_1'))
    const before = socket.frames('item').length
    await agent.handleRelayFrame({ t: 'open', id: openId, endpoint: '$events', args: {}, deviceId: 'dev_1' })
    await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
    return socket.frames('item').slice(before).filter((f) => f.value?.eventId === 'wf_7').length
  }
  assert.equal(await countReplays('4'), 1)
  // App 又崩了一次：没人回答过，所以还得再给一遍。
  assert.equal(await countReplays('6'), 1)
})

test('新契约：手机一直不在也不撤流，$events 替它值班到设备被撤销', async () => {
  // 这条以前叫「the grace period ends and the kept $events stream is finally
  // cancelled」——15 分钟到点撤流。2026-09-28 的 R-1 把这套拆掉了：手机离线
  // 超过 15 分钟提问就永远丢了，而那正是"值班"最该起作用的时候。现在**没有时限**，
  // 唯一的出口是 `reason === 'revoked'`（下一条用例）与进程退出。
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  assert.equal(agent.devices.size, 1)

  // 把注入的时钟推进 30 分钟（远超旧的 15 分钟宽限期）：设备记录、流与待答表都还在。
  agent.router.now = () => Date.now() + 30 * 60 * 1000
  agent.now = agent.router.now
  agent.onStreamItem('ev:dev_1', {
    type: 'waterfall', event: 'user-questions/request', eventId: 'wf_late', agentId: 's-1', request: {},
  })
  await new Promise((resolve) => setTimeoutFnReal(resolve, 30))

  assert.deepEqual(dsh.cancels().map((call) => call.muxId), [], '挂了 30 分钟后 $events 不该被撤')
  assert.equal(agent.devices.size, 1)
  assert.equal(agent.streams.size, 1)
  assert.equal(agent.devices.get('dev_1').eventsPending.size, 1)
})

test('撤销设备即放下：撤全部流、删记录，不再替它值班', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: 'session/follow', args: {}, deviceId: 'dev_1' })
  await agent.handleRelayFrame({ t: 'open', id: '3', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  agent.onStreamItem('ev:dev_1', {
    type: 'waterfall', event: 'user-questions/request', eventId: 'wf_1', agentId: 's-1', request: {},
  })
  assert.equal(agent.devices.get('dev_1').eventsPending.size, 1)

  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'revoked' })

  // 这台手机不会再回来了（令牌已经作废），继续留流只是白占一条。
  assert.deepEqual(dsh.cancels().map((call) => call.muxId).sort(), ['ev:dev_1', 's:dev_1:2'])
  assert.equal(agent.devices.size, 0)
  assert.equal(agent.streams.size, 0)
})

test('别的 detach reason 仍然走"值班"：记录与 $events 流都留着', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  assert.deepEqual(dsh.cancels(), [])
  assert.equal(agent.devices.size, 1)
  assert.equal(agent.streams.size, 1)
})

test('eventResult answers $events/result with this device clientId, first answer wins', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(attach('dev_2'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  agent.onStreamItem('ev:dev_2', ready('c2'))

  const answer = (deviceId, eventId) => agent.handleRelayFrame({
    t: 'eventResult', id: '3', deviceId,
    result: { clientId: 'ignored', eventId, outcome: { kind: 'result', value: { answers: ['a'] } } },
  })
  await answer('dev_1', 'evt_1')
  await answer('dev_2', 'evt_1')
  const calls = dsh.calls.filter((call) => call.kind === 'rpc' && call.method === '$events/result')
  assert.equal(calls.length, 1)
  assert.deepEqual(calls[0].args, {
    clientId: 'c1', eventId: 'evt_1', outcome: { kind: 'result', value: { answers: ['a'] } },
  })
})

test('eventResult is refused before the $events stream is ready', async () => {
  const { agent, socket, dsh } = makeAgent()
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'eventResult', id: '3', deviceId: 'dev_1', result: { eventId: 'e', outcome: { kind: 'next' } } })
  assert.equal(socket.last('error').code, 'events/not-ready')
  assert.equal(dsh.calls.filter((call) => call.method === '$events/result').length, 0)
})

test('a rejected waterfall answer is released so another device may retry', async () => {
  const { agent, dsh } = makeAgent()
  dsh.rpcError = new Error('boom')
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  await agent.handleRelayFrame({ t: 'eventResult', id: '3', deviceId: 'dev_1', result: { eventId: 'e1', outcome: { kind: 'next' } } })
  assert.equal(agent.dedupe.has('e1'), false)
  dsh.rpcError = undefined
  await agent.handleRelayFrame({ t: 'eventResult', id: '3', deviceId: 'dev_1', result: { eventId: 'e1', outcome: { kind: 'next' } } })
  assert.equal(agent.dedupe.has('e1'), true)
})

test('unknown frame types and unaddressed frames are ignored', async () => {
  const { agent, socket, dsh } = makeAgent()
  await agent.handleRelayFrame({ t: 'somethingNew', deviceId: 'dev_1' })
  await agent.handleRelayFrame({ t: 'req', id: '1', method: 'session/list' })
  await agent.handleRelayFrame(undefined)
  assert.equal(socket.sent.length, 0)
  assert.equal(dsh.calls.length, 0)
})

test('malformed device frames produce a protocol error instead of a DSH call', async () => {
  const { agent, socket, dsh } = makeAgent()
  await agent.handleRelayFrame(attach())
  await agent.handleRelayFrame({ t: 'req', deviceId: 'dev_1' })
  assert.equal(socket.last('error').code, 'protocol/bad-frame')
  assert.equal(dsh.calls.filter((call) => call.kind === 'rpc').length, 0)
})

test('relay ping is answered and pong refreshes liveness', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame({ t: 'ping', ts: 42 })
  assert.deepEqual(socket.last('pong'), { t: 'pong', ts: 42 })
  const before = agent._lastPong
  await agent.handleRelayFrame({ t: 'pong', ts: 43 })
  assert.ok(agent._lastPong >= before)
})

test('a fatal relay error closes the socket', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame({ t: 'error', code: 'auth/invalid-agent', message: 'nope', fatal: true })
  assert.equal(socket.closed, true)
  assert.equal(socket.closeCode, 4002)
  assert.match(agent.lastError, /auth\/invalid-agent/)
})

test('mux-down notifies devices and re-arms their $events streams', async () => {
  const { agent, socket, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: 'session/follow', args: {}, deviceId: 'dev_1' })
  agent.onMuxDown('socket closed')
  const failure = socket.last('streamError')
  assert.equal(failure.id, '2')
  assert.equal(failure.error.code, 'host/unavailable')
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(agent.devices.get('dev_1').eventsMuxId, 'ev:dev_1')
  assert.ok(dsh.opens().some((call) => call.muxId === 'ev:dev_1'))
})

test('opening $events later replays the ready item so the device learns its clientId', async () => {
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  // The ready item arrived before the device opened the stream (as an `event`).
  assert.equal(socket.last('event').value.clientId, 'c1')
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  const replayed = socket.last('item')
  assert.equal(replayed.id, '2')
  assert.equal(replayed.value.type, 'ready')
  assert.equal(replayed.value.clientId, 'c1')
})

test('status() reports connection, devices and streams', async () => {
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  agent.onStreamItem('ev:dev_1', ready('c1'))
  const status = agent.status()
  assert.equal(status.connected, false)
  assert.equal(status.state, 'idle')
  assert.equal(status.agentId, 'agt_1')
  assert.equal(status.deviceCount, 1)
  assert.equal(status.devices[0].eventsReady, true)
  assert.equal(status.devices[0].name, 'iPhone')
  assert.equal(status.dsh.port, 54499)
  assert.equal(status.protocolVersion, 1)
})

test('file transfers are answered locally and never reach the Host', async () => {
  // The Host has no upload endpoint, so the link carries the bytes itself. If
  // these calls were forwarded they would fail as unknown methods — and the
  // whole point is that the relay and protocol stay unchanged.
  const { agent, dsh, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))

  const sessionId = `link-test-${process.pid}`
  const body = Buffer.from('hello from the phone, in bytes: \u0000\u0001\u0002')
  const transferId = 'tr-1'

  const send = (id, method, args) =>
    agent.handleRelayFrame({ t: 'req', id, method, args, deviceId: 'dev_1' })

  await send('1', '_link/fileBegin', {
    transferId, sessionId, name: 'notes.txt', bytes: body.length,
  })
  await send('2', '_link/fileChunk', { transferId, seq: 0, data: body.toString('base64') })
  await send('3', '_link/fileEnd', { transferId })

  const replies = socket.frames('res').filter((f) => ['1', '2', '3'].includes(f.id))
  assert.equal(replies.length, 3, 'the device did not get an answer for every call')
  assert.ok(replies.every((f) => f.ok === true), `a file call failed: ${JSON.stringify(replies)}`)

  // Selected by id rather than by position: the replies are not guaranteed to
  // arrive in the order the assertions in this file happen to assume.
  const done = replies.find((frame) => frame.id === '3')
  assert.ok(done?.value, `fileEnd replied without a value: ${JSON.stringify(replies)}`)
  assert.equal(done.value.bytes, body.length)
  assert.match(done.value.path, /notes\.txt$/)
  assert.ok(readFileSync(done.value.path).equals(body), 'the staged bytes differ')

  // Nothing was asked of the Host.
  assert.deepEqual(
    dsh.calls.filter((call) => String(call.method).startsWith('_link/')),
    [],
    'a file call was forwarded to the Host',
  )

  rmSync(join(homedir(), '.dsh', 'inbox', sessionId), { recursive: true, force: true })
})

test('_link/hello reports what this connector can do, without asking the Host', async () => {
  // The app feature-detects from this answer. It has to come over the link
  // rather than the HTTP status route, because the status route only exists on
  // the direct path and users run through the relay.
  const { agent, dsh, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'req', id: 'h1', method: '_link/hello', args: {}, deviceId: 'dev_1' })

  const reply = socket.frames('res').find((frame) => frame.id === 'h1')
  assert.ok(reply?.ok, `hello failed: ${JSON.stringify(reply)}`)
  assert.ok(reply.value.serverVersion, 'no server version reported')
  assert.ok(Array.isArray(reply.value.capabilities), 'no capability list reported')
  // The one the app gates its file entry on.
  assert.ok(reply.value.capabilities.includes('file-transfer'))
  assert.equal(reply.value.protocolVersion, 1)
  assert.deepEqual(
    dsh.calls.filter((call) => call.method === '_link/hello'),
    [],
    'hello was forwarded to the Host',
  )
})

test('the phone naming its build is recorded, and visible in the device snapshot', async () => {
  // The relay's device row is written at pairing and never again, so this frame
  // is the only place the *client's* build travels after that. Recording it is
  // what makes "did that phone update?" answerable.
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'req', id: 'h1', method: '_link/hello', deviceId: 'dev_1',
    args: { clientName: 'DSHMobile', clientVersion: '1.0', clientBuild: '20260919.0005' },
  })

  const record = agent.router.snapshot().find((entry) => entry.deviceId === 'dev_1')
  assert.equal(record.client.name, 'DSHMobile')
  assert.equal(record.client.build, '20260919.0005')
  assert.equal(record.client.label, 'DSHMobile 1.0 (20260919.0005)')
  // And the connector still answers the app's question.
  assert.ok(socket.frames('res').find((frame) => frame.id === 'h1')?.ok)
})

test('a phone that says nothing about itself reports nothing', async () => {
  // Older builds send `{}`. Inventing a version here would be worse than
  // admitting we do not know one.
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'req', id: 'h1', method: '_link/hello', args: {}, deviceId: 'dev_1' })
  const record = agent.router.snapshot().find((entry) => entry.deviceId === 'dev_1')
  assert.equal(record.client, null)
})


test('桥接回复不带 deviceId：relay 靠 bid 关联回那个 HTTP 请求', async () => {
  // 这是线上真正生效的那一层：`sendToDevice(undefined, frame)` 必须原样发出去，
  // 不能顺手补一个 deviceId——relay 的 `PUT /files/up` 是靠 `bid` 找回那个请求的。
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))

  const sessionId = `bridge-test-${process.pid}`
  const body = Buffer.from('bridge bytes')
  await agent.handleRelayFrame({
    t: 'fsPutBegin', deviceId: 'dev_1', bid: 'b1', sessionId, name: 'b.txt', bytes: body.length,
  })
  await agent.handleRelayFrame({
    t: 'fsPutChunk', deviceId: 'dev_1', bid: 'b1', seq: 0, data: body.toString('base64'),
  })
  await agent.handleRelayFrame({ t: 'fsPutEnd', deviceId: 'dev_1', bid: 'b1' })

  const ack = socket.last('fsPutAck')
  assert.deepEqual(ack, { t: 'fsPutAck', bid: 'b1', received: 0 })
  const done = socket.last('fsPutDone')
  assert.equal(done.bid, 'b1')
  assert.equal(done.bytes, body.length)
  assert.equal('deviceId' in done, false, `fsPutDone 带了 deviceId：${JSON.stringify(done)}`)
  assert.ok(readFileSync(done.path).equals(body))

  rmSync(join(homedir(), '.dsh', 'inbox', sessionId), { recursive: true, force: true })
})

test('unknown frame types with a deviceId still produce nothing (bridge 帧不跨到设备)', async () => {
  // `notify` / `fs*` 是 agent 侧控制帧，设备方向根本不该见到它们；未知类型照旧忽略。
  const { agent, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  const before = socket.sent.length
  await agent.handleRelayFrame({ t: 'notify', deviceId: 'dev_1', kind: 'turnEnd', sid: 's' })
  assert.equal(socket.sent.length, before, 'notify 被当成设备帧处理了')
})

test('C-04 臂 2：连接器重连时，中转广播"这台回不来了"只放下那一台', async () => {
  // relay 重启后连接器重连，中转会把该 agent 名下**已撤销**的设备逐条
  // `deviceDetach(revoked)` 广播过来（连接器没持有的那些是空操作）。
  // 关键在"克制"：只是手机不在的那台（B）必须原样留着——那是 C-01 的核心。
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach('dev_A'))
  await agent.handleRelayFrame(attach('dev_B'))
  await agent.handleRelayFrame({ t: 'open', id: '2', endpoint: '$events', args: {}, deviceId: 'dev_A' })
  await agent.handleRelayFrame({ t: 'open', id: '3', endpoint: '$events', args: {}, deviceId: 'dev_B' })
  // 两台都只是"手机不在"：各自留一条值班流。
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_A', reason: 'socket closed' })
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_B', reason: 'socket closed' })
  assert.equal(agent.devices.size, 2)

  // 重连之后中转只说 A（它已被撤销），并且重复说一次也是空操作。
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_A', reason: 'revoked' })
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_A', reason: 'revoked' })

  assert.deepEqual(dsh.cancels().map((call) => call.muxId), ['ev:dev_A'])
  assert.equal(agent.devices.has('dev_A'), false)
  assert.equal(agent.devices.has('dev_B'), true, 'B 只是手机不在，不许被误伤')
  assert.equal(agent.streams.byDevice('dev_B').length, 1, 'B 的 $events 值班流必须原样留着')
})

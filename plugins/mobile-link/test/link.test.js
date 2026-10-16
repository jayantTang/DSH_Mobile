/**
 * Routing tests for the DLP agent. A fake relay socket and a fake DSH client
 * drive `handleRelayFrame`, so no network or DSH instance is involved.
 */

import assert from 'node:assert/strict'
import { inflateRawSync } from 'node:zlib'
import { EventEmitter } from 'node:events'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

// 隔离：收件箱落在 `$DSH_HOME/inbox`（`lib/files.js` 认这个变量）。不隔离的话
// 用例会往真实 `~/.dsh/inbox` 写文件——既是脏数据，也违反宪法第 III 条。
const TEST_HOME = mkdtempSync(join(tmpdir(), 'mobile-link-link-test-'))
process.env.DSH_HOME = TEST_HOME
process.on('exit', () => rmSync(TEST_HOME, { recursive: true, force: true }))

import { MobileLinkAgent } from '../lib/link.js'
import { createHistoryService } from '../lib/history.js'
import { SESSION_DIGEST_METHOD } from '../lib/session-digest.js'

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

function makeAgent({ responses, notify, slowRequestMs, diagnostics } = {}) {
  const dsh = new FakeDsh()
  if (responses) for (const [method, value] of Object.entries(responses)) dsh.responses.set(method, value)
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({
    dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1', slowRequestMs, diagnostics,
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

  rmSync(join(TEST_HOME, 'inbox', sessionId), { recursive: true, force: true })
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
  // 扫描式搜索的进度：界面据此从第一页起显示「已扫 k/N 片」。
  assert.ok(reply.value.capabilities.includes('search-progress'))
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

  rmSync(join(TEST_HOME, 'inbox', sessionId), { recursive: true, force: true })
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

/**
 * 热插拔（003）：`stop()` 是"禁用插件"这条路上最后一道收尾。宿主把 effect 的清理函数跑掉之后，
 * 这个 agent 必须一条资源都不留——心跳定时器、relay socket、DSH 客户端、值班流。
 */
test('stop() puts everything down: heartbeat, socket, DSH client, device streams', async () => {
  const { agent, dsh, socket } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'open', id: '1', endpoint: '$events', args: {}, deviceId: 'dev_1' })
  // 模拟"已连上并跑起心跳"的状态：心跳是连接成功之后才开的定时器。
  agent.state = 'connected'
  let heartbeatTicked = false
  agent._heartbeat = setInterval(() => { heartbeatTicked = true }, 1000)

  await agent.stop()

  assert.equal(agent._heartbeat, undefined, '心跳定时器必须被清掉')
  assert.equal(agent.socket, undefined, 'relay socket 必须从 agent 上摘掉')
  assert.equal(socket.closed, true, 'relay socket 必须被关闭')
  assert.equal(dsh.closed, true, 'DSH 客户端也必须收掉')
  assert.equal(agent.devices.size, 0, '设备记录随 agent 一起释放')
  assert.equal(agent.state, 'stopped')
  assert.equal(heartbeatTicked, false, '清掉之后心跳不能再跑（否则就是泄漏）')
})

test('stop() is idempotent: a second call is a no-op, not a throw', async () => {
  const { agent } = makeAgent()
  await agent.stop()
  await assert.doesNotReject(() => agent.stop())
  assert.equal(agent.state, 'stopped')
})

// ---------------------------------------------------------------------------
// T057：旧 App + 新连接器。新能力（`history-window` / `session-search`）只是**多出来的两条**，
// 旧手机走的 `session/page` / `session/follow` 必须一个字节都不变——不改写参数、不裁剪回复。
// 这条是"新连接器不会把老 App 弄坏"的机器证据（真旧版 App 构建没法在本机跑，见 T057 的说明）。
// ---------------------------------------------------------------------------

test('session/page 与 session/follow 在新连接器上仍原样透传', async () => {
  const { agent, dsh, socket } = makeAgent({
    responses: { 'session/page': { ok: true, value: { events: [{ seq: 2445 }], hasMore: true } } },
  })
  await agent.handleRelayFrame(attach())
  // 参数里带着 host 的 `{request: …}` 信封，连接器不许动它：
  const args = { request: { address: { kind: 'session', sessionId: 's-1' }, beforeSeq: 2445, maxMessages: 60 } }
  await agent.handleRelayFrame({ t: 'req', id: '11', method: 'session/page', args, deviceId: 'dev_1' })
  const call = dsh.calls.find((entry) => entry.kind === 'rpc')
  assert.equal(call.method, 'session/page')
  assert.deepEqual(call.args, args, '参数被改写了')
  assert.deepEqual(socket.last('res').value, { events: [{ seq: 2445 }], hasMore: true }, '回复被裁剪了')

  // 流式那条也一样：endpoint 与 args 原样交给 host。
  const open = { t: 'open', id: '12', endpoint: 'session/follow',
    args: { request: { address: { kind: 'session', sessionId: 's-1' } } }, deviceId: 'dev_1' }
  await agent.handleRelayFrame(open)
  const forwarded = dsh.opens().find((entry) => entry.endpoint === 'session/follow')
  assert.deepEqual(forwarded.args, open.args)
})

test('新方法只在被调用时才出现，旧方法不受能力声明影响', async () => {
  const { agent, dsh } = makeAgent()
  await agent.handleRelayFrame(attach())
  // 握手声明的能力里多了两条（`hello.js`），但这不该让连接器去碰旧方法的路由：
  await agent.handleRelayFrame({ t: 'req', id: '13', method: 'session/list', args: { request: {} }, deviceId: 'dev_1' })
  const methods = dsh.calls.filter((entry) => entry.kind === 'rpc').map((entry) => entry.method)
  assert.deepEqual(methods, ['session/list'])
})

// ── 链路自愈（2026-10-09 真机连不上的两个根因） ─────────────────────────────

// 走真连接路径的 socket 必须实现 `onMessage/onError/onClose`（`#session()` 直接调用它们）。
class ConnectedSocket extends FakeSocket {
  onMessage(handler) { this.messageHandler = handler; return this }
  onError(handler) { this.errorHandler = handler; return this }
  onClose(handler) { this.closeHandler = handler; return this }
}

test('看门狗：单次心跳停摆时也会把卡住的会话拆掉重连', async () => {
  let connects = 0
  const sockets = []
  const warnings = []
  const agent = new MobileLinkAgent({
    dshClient: new FakeDsh(),
    logger: { debug() {}, info() {}, warn(message) { warnings.push(message) }, error() {} },
    relayUrl: 'ws://relay.test',
    agentId: 'agt_1',
    agentSecret: 'as_1',
    // 心跳故意设得极慢：这条用例要证明的是**光靠看门狗**也能恢复。
    // 看门狗的检查周期有 1 秒下限（生产里不该更密），所以这里等 1.4 秒。
    heartbeatMs: 60000, pongTimeoutMs: 30, watchdogMs: 40,
    connectImpl: async () => {
      connects += 1
      const socket = new ConnectedSocket()
      sockets.push(socket)
      return socket
    },
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  agent.needsEnroll = false   // 测试环境没有身份文件：直接按"已登记"跑链路
  await agent.start()
  // 看门狗 1 秒醒一次动手，之后还有一次退避重连，所以等 3 秒才能看到第二次连接。
  await new Promise((resolve) => setTimeout(resolve, 3000))
  await agent.stop()
  assert.ok(connects >= 2, `看门狗应该重建过连接（实际 ${connects} 次）`)
  assert.ok(warnings.some((message) => message.includes('看门狗')),
    `看门狗应该报出它动手了（实际日志：${warnings.join(' | ') || '空'}）`)
  assert.ok(sockets[0].closed, '卡住的那条 socket 应该被拆掉')
})

test('重复实例：新 Link 启动会先停掉上一个（热更不会留下两条连接）', async () => {
  const opts = () => ({
    dshClient: new FakeDsh(),
    logger: { debug() {}, info() {}, warn() {}, error() {} },
    relayUrl: 'ws://relay.test',
    agentId: 'agt_1',
    agentSecret: 'as_1',
    connectImpl: async () => new FakeSocket(),
  })
  const first = new MobileLinkAgent(opts())
  first.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  first.needsEnroll = false
  await first.start()
  const second = new MobileLinkAgent(opts())
  second.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  second.needsEnroll = false
  await second.start()
  assert.equal(first.state, 'stopped', '旧实例应该被停掉')
  assert.notEqual(second.state, 'stopped')
  await second.stop()
})

// ── `_link/diagnostics`：App 推上来的阶段记录（spec 020 的 FR-011） ─────────

const diagReq = (args, id = 'd1') => ({ t: 'req', id, method: '_link/diagnostics', args, deviceId: 'dev_1' })
// **App 侧的线形状**（与 DSHKit 的 LinkDiagnostics.Event 一致）：字段嵌在 `detail` 里。
// 用例必须照抄这个形状——曾经用扁平形状写，于是"清洗时把 detail 整个丢掉"这个 bug
// 在单测里全绿、到真机才暴露（2026-10-13 09:25 的中转运行）。
const appEvent = (seq, kind, ms, detail = {}) => ({ seq, at: new Date(ms).toISOString(), ms, kind, detail })

test('App 的阶段记录原样落盘，时刻用 App 自己的（连接器不改写）', async () => {
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  const appMs = 1_791_825_010_506
  await agent.handleRelayFrame(diagReq({
    since: 0, sentAt: appMs,
    events: [
      appEvent(1, 'app.dial', appMs, { phase: 'start' }),
      appEvent(2, 'app.hello', appMs + 12, { elapsedMs: 12 }),
    ],
  }))
  const entries = agent.journal.entries()
  const dial = entries.find((entry) => entry.kind === 'app.dial')
  assert.equal(dial.source, 'app', '要标出来源，否则分不清是谁记的')
  assert.equal(dial.ms, appMs, 'App 的时刻必须原样保留——它正是"手机侧几点"的唯一来源')
  assert.equal(dial.phase, 'start', 'detail 里的字段必须摊平到顶层，否则落盘等于丢字段')
  assert.equal(dial.deviceId, 'dev_1', 'App 不知道自己的 deviceId，连接器必须补上（多设备时要能归人）')
  const hello = entries.find((entry) => entry.kind === 'app.hello')
  assert.equal(hello.ms, appMs + 12, '信封的 ms 是 App 的时刻')
  assert.equal(hello.elapsedMs, 12, '耗时落在 elapsedMs 上')
  assert.equal(hello.detail, undefined, '不该留一个嵌套 detail')

  // 关键回归：App 的 detail 里也有一个 ms（含义是**耗时**）。摊平时它绝不能把
  // 事件的**时刻**冲掉——否则时间线上这条会跑到 1970 年（2026-10-13 真机运行踩到过）。
  const withDuration = { seq: 3, at: new Date(appMs + 500).toISOString(), ms: appMs + 500,
    kind: 'app.hello', detail: { elapsedMs: 11742 } }
  await agent.handleRelayFrame(diagReq({ since: 2, sentAt: appMs + 500, events: [withDuration] }, 'd3'))
  const hello2 = agent.journal.entries().filter((entry) => entry.kind === 'app.hello').at(-1)
  assert.equal(hello2.ms, appMs + 500, '信封时刻必须还是 App 的时刻')
  assert.equal(hello2.elapsedMs, 11742, '耗时落在 elapsedMs 上')
  const push = entries.find((entry) => entry.kind === 'app.push')
  assert.equal(push.count, 2)
  assert.equal(push.sentAt, appMs)
  assert.equal(Number.isFinite(push.skewMs), true, 'skewMs 是手机时钟对齐的唯一来源')
})

test('同一批重推按序号幂等：第二次一条都不收', async () => {
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  const batch = { since: 0, sentAt: 1, events: [appEvent(1, 'app.dial', 1), appEvent(2, 'app.hello', 2)] }
  await agent.handleRelayFrame(diagReq(batch))
  await agent.handleRelayFrame(diagReq(batch, 'd2'))
  const dials = agent.journal.entries().filter((entry) => entry.kind === 'app.dial')
  assert.equal(dials.length, 1, '重推不该写第二遍')
  const pushes = agent.journal.entries().filter((entry) => entry.kind === 'app.push')
  assert.deepEqual(pushes.map((entry) => entry.count), [2, 0])
})

test('超过单批上限就截断，并如实报 accepted/lastSeq（剩下的下次再推）', async () => {
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  const events = []
  for (let index = 1; index <= 200; index += 1) {
    events.push(appEvent(index, 'app.interaction', index, { pad: 'x'.repeat(300), n: index }))
  }
  await agent.handleRelayFrame(diagReq({ since: 0, sentAt: 5, events }))
  const acceptedPush = agent.journal.entries().filter((entry) => entry.kind === 'app.push').at(-1)
  assert.ok(acceptedPush.count < 200, `必须截断，实际收了 ${acceptedPush.count}`)
  assert.ok(acceptedPush.count > 0, '不该一条都不收')
  // 未收完的部分再推一次要能继续收（水位只到已收的那条）。
  const accepted = acceptedPush.count
  const rest = { since: accepted, sentAt: 6, events: events.slice(accepted) }
  await agent.handleRelayFrame(diagReq(rest, 'd2'))
  const total = agent.journal.entries().filter((entry) => entry.kind === 'app.interaction').length
  assert.ok(total > accepted, `续推要能继续收：先 ${accepted}，共 ${total}`)
})

test('落盘写坏了也不改链路状态（诊断不许影响连接）', async () => {
  const blocker = join(mkdtempSync(join(tmpdir(), 'mobile-link-diag-')), 'blocker')
  writeFileSync(blocker, 'x')
  const agent = new MobileLinkAgent({
    dshClient: new FakeDsh(),
    logger: { debug() {}, info() {}, warn() {}, error() {} },
    relayUrl: 'ws://relay.test',
    agentId: 'agt_1',
    journalPath: join(blocker, 'sub', 'link-events.jsonl'),
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  agent.socket = new FakeSocket()
  await agent.handleRelayFrame(attach('dev_1'))
  const before = agent.journal.recorded
  await agent.handleRelayFrame(diagReq({ since: 0, sentAt: 1, events: [appEvent(1, 'app.dial', 1)] }))
  assert.ok(agent.journal.recorded > before, '内存那份照旧可用')
  assert.equal(agent.journal.fileErrors, 1, '写失败只报一次')
  assert.equal(agent.router.lastError, undefined, '诊断写失败不该变成链路错误')
})


const helloReq = () => ({ t: 'req', id: 'h1', method: '_link/hello', args: { protocolVersion: 1 }, deviceId: 'dev_1' })
const dataReq = (id = 'u1') => ({ t: 'req', id, method: 'session/list', args: { request: {} }, deviceId: 'dev_1' })

/** 取最后一条 device.phase 的 detail。 */
function lastPhase(agent) {
  return [...agent.journal.entries()].reverse().find((entry) => entry.kind === 'device.phase')?.phases
}

test('阶段齐全：接入 → 握手 → 首个数据请求 → 首个数据响应，missing 为空', async () => {
  const { agent } = makeAgent({ responses: { 'session/list': { items: [] } } })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(helloReq())
  await agent.handleRelayFrame(dataReq())
  const phases = lastPhase(agent)
  assert.equal(phases.helloMs !== null, true, '握手到了就该有毫秒')
  assert.equal(phases.firstRequestMs !== null, true)
  assert.equal(phases.firstResponseMs !== null, true)
  assert.ok(phases.firstRequestMs <= phases.firstResponseMs, '三段必须单调')
  const event = [...agent.journal.entries()].reverse().find((entry) => entry.kind === 'device.phase')
  assert.deepEqual(event.missing, [], '都发生了就不该有 missing')
})

test('只到握手就断：后两段记 null 并进 missing（不是 0）', async () => {
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(helloReq())
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  const event = [...agent.journal.entries()].reverse().find((entry) => entry.kind === 'device.phase')
  assert.deepEqual(event.missing, ['first-request', 'first-response'])
  assert.equal(event.phases.firstRequestMs, null, '没发生就是 null')
  assert.notEqual(event.phases.firstRequestMs, 0, '0 与"没发生"是两回事')
})

test('只接入就断：三段全 null，missing 列全', async () => {
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  const event = [...agent.journal.entries()].reverse().find((entry) => entry.kind === 'device.phase')
  assert.deepEqual(event.missing, ['hello', 'first-request', 'first-response'])
  assert.deepEqual(event.phases, { helloMs: null, firstRequestMs: null, firstResponseMs: null })
})

test('没有握手但有数据请求：不急着写，等断开时补一条带 missing 的', async () => {
  const { agent } = makeAgent({ responses: { 'session/list': { items: [] } } })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(dataReq())
  // 真实顺序是**先探针后握手**（ConnectionStore.connect 先 sessions 再 hello）。若一见数据请求
  // 就写阶段事件，`missing` 里会永远挂着 hello——最有用的 attach→hello 那一段就丢了。
  assert.equal(agent.journal.entries().some((entry) => entry.kind === 'device.phase'), false,
    '握手还没到，不该急着写')
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  const event = [...agent.journal.entries()].reverse().find((entry) => entry.kind === 'device.phase')
  assert.deepEqual(event.missing, ['hello'])
  assert.equal(event.phases.helloMs, null)
  assert.equal(event.phases.firstRequestMs !== null, true)
})

test('真实顺序（先探针后握手）：三段齐了才写，hello 那一段不为空', async () => {
  const { agent } = makeAgent({ responses: { 'session/list': { items: [] } } })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(dataReq('u1'))
  assert.equal(agent.journal.entries().some((entry) => entry.kind === 'device.phase'), false)
  await agent.handleRelayFrame(helloReq())
  const phases = agent.journal.entries().filter((entry) => entry.kind === 'device.phase')
  assert.equal(phases.length, 1)
  assert.deepEqual(phases[0].missing, [], '探针在前、握手在后，三段一起齐')
  assert.equal(phases[0].phases.helloMs !== null, true, 'hello 那一段必须有数')
})

test('一次接入只写一条 device.phase，请求再多也不重复', async () => {
  const { agent } = makeAgent({ responses: { 'session/list': { items: [] } } })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(helloReq())
  await agent.handleRelayFrame(dataReq('u1'))
  await agent.handleRelayFrame(dataReq('u2'))
  await agent.handleRelayFrame(dataReq('u3'))
  const phases = agent.journal.entries().filter((entry) => entry.kind === 'device.phase')
  assert.equal(phases.length, 1, `一次接入只该一条，实际 ${phases.length}`)
  assert.deepEqual(phases[0].missing, [], '三段齐了，missing 该是空的')
})

test('断开时补一条汇总，条数与请求量同级（常数级）', async () => {
  const { agent } = makeAgent({ responses: { 'session/list': { items: [] } } })
  await agent.handleRelayFrame(attach('dev_1'))
  for (let index = 0; index < 5; index += 1) await agent.handleRelayFrame(dataReq(`u${index}`))
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  const summaries = agent.journal.entries().filter((entry) => entry.kind === 'device.summary')
  assert.equal(summaries.length, 1)
  assert.equal(summaries[0].requests, 5)
  assert.ok(summaries[0].top3.length <= 3)
})


/** 等到 `predicate()` 成立，否则失败。 */
async function until(predicate, message, timeoutMs = 4000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.ok(predicate(), message)
}

test('链路连上、被拆掉都写进流水，并带上原因', async () => {
  const sockets = []
  const agent = new MobileLinkAgent({
    dshClient: new FakeDsh(),
    logger: { debug() {}, info() {}, warn() {}, error() {} },
    relayUrl: 'ws://relay.test',
    agentId: 'agt_1',
    agentSecret: 'as_1',
    heartbeatMs: 60000,
    connectImpl: async () => {
      const socket = new ConnectedSocket()
      sockets.push(socket)
      return socket
    },
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  agent.needsEnroll = false
  await agent.start()
  await until(() => agent.state === 'connected', `没能连上（state=${agent.state}）`)

  // 关闭 socket ＝ 中转把这条链路断了；会话随即返回，走拆链那条路。
  sockets[0].closeHandler?.(1006, 'gone')
  await until(() => agent.journal.entries().some((entry) => entry.kind === 'link.close'),
    `拆链没有写进流水：${JSON.stringify(agent.journal.entries().map((entry) => entry.kind))}`)
  await agent.stop()

  const entries = agent.journal.entries()
  const kinds = entries.map((entry) => entry.kind)
  const open = entries.find((entry) => entry.kind === 'link.open')
  assert.ok(kinds.includes('link.start'), `link.start 不见了：${kinds.join(', ')}`)
  assert.equal(open.agentId, 'agt_1')
  assert.ok(open.relay.startsWith('ws://relay.test'), `link.open 应带上中转地址：${open.relay}`)
  const close = entries.find((entry) => entry.kind === 'link.close')
  assert.match(close.reason, /relay closed the socket/, `拆链原因该被记下来：${close.reason}`)
  assert.equal(close.from, 'connected', '拆之前的链路状态要一起记，才能区分"刚连上就掉"和"挂了很久才掉"')
})

test('同一台设备又 attach 一次（中间没有 detach）会被标出来', async () => {
  const { agent } = makeAgent()
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(attach('dev_1'))
  const kinds = agent.journal.entries().map((entry) => entry.kind)
  assert.ok(kinds.includes('device.attach'), `首次接入要记：${kinds.join(', ')}`)
  assert.ok(kinds.includes('device.attach-again'),
    `同一台设备连着开第二条时必须留痕，否则日志里只看得到"它连上了"：${kinds.join(', ')}`)
  const again = agent.journal.entries().find((entry) => entry.kind === 'device.attach-again')
  assert.equal(again.deviceId, 'dev_1')

  // 断开之后再连是**回头客**，不是"又开了一条"：两条要分得开。
  const before = agent.journal.entries().length
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  await agent.handleRelayFrame(attach('dev_1'))
  const after = agent.journal.entries().slice(before).map((entry) => entry.kind)
  assert.ok(after.includes('device.detach'), `断开要记：${after.join(', ')}`)
  assert.ok(after.includes('device.reattach'), `回头客要记成 reattach：${after.join(', ')}`)
  assert.ok(!after.includes('device.attach-again'), '先断后连不是"又开一条"')
})

// ── US5：上限与回退闸（spec 020 的 FR-018） ────────────────────────────────

test('回退闸：diagnostics: false 时明确拒绝接收，且不影响链路', async () => {
  const { agent } = makeAgent({ diagnostics: false })
  await agent.handleRelayFrame(attach('dev_1'))
  const before = agent.journal.recorded
  await agent.handleRelayFrame(diagReq({ since: 0, sentAt: 1, events: [appEvent(1, 'app.dial', 1, { phase: 'start' })] }))
  const entries = agent.journal.entries()
  assert.equal(entries.filter((entry) => entry.kind === 'app.dial').length, 0, '关掉后不该落盘')
  assert.equal(entries.filter((entry) => entry.kind === 'app.push').length, 0)
  assert.equal(agent.journal.recorded, before, '一条都不该多')
  assert.equal(agent.router.lastError, undefined, '拒绝接收不是链路错误')
  assert.equal(agent.state, 'idle', '链路状态不受影响')
})

test('slowRequestMs: 0 时不写 request.slow，但汇总照写（数字仍在）', async () => {
  const { agent } = makeAgent({ slowRequestMs: 0, responses: { 'session/list': { items: [] } } })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(dataReq('u1'))
  await agent.handleRelayFrame({ t: 'deviceDetach', deviceId: 'dev_1', reason: 'socket closed' })
  const kinds = agent.journal.entries().map((entry) => entry.kind)
  assert.equal(kinds.includes('request.slow'), false, '0 = 关闭逐条慢请求')
  assert.equal(kinds.includes('device.summary'), true, '汇总不跟着关：p50/p95 仍要能看')
})

// ── US8：链路被异常关闭时要留下系统给的错误文本（spec 020 的 FR-027） ──────────

test('异常关闭：socket 的系统错误进 link.close.socketError', async () => {
  const sockets = []
  const agent = new MobileLinkAgent({
    dshClient: new FakeDsh(),
    logger: { debug() {}, info() {}, warn() {}, error() {} },
    relayUrl: 'ws://relay.test', agentId: 'agt_1', agentSecret: 'as_1', heartbeatMs: 60000,
    connectImpl: async () => {
      const socket = new ConnectedSocket()
      sockets.push(socket)
      return socket
    },
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  agent.needsEnroll = false
  await agent.start()
  await until(() => agent.state === 'connected', `没能连上（state=${agent.state}）`)

  // 系统层报错（真实里就是"1006 + 这个文本"的情形），然后 socket 关掉。
  sockets[0].errorHandler?.(new Error('ECONNRESET: socket hang up'))
  sockets[0].closeHandler?.(1006, '')
  await until(() => agent.journal.entries().some((entry) => entry.kind === 'link.close'),
    '拆链没有写进流水')
  await agent.stop()
  const close = agent.journal.entries().find((entry) => entry.kind === 'link.close')
  assert.match(String(close.socketError), /ECONNRESET/, `错误文本要留下：${close.socketError}`)
})

test('正常关闭：不带 socketError（凭空多一个 null 会让人以为出过错）', async () => {
  const sockets = []
  const agent = new MobileLinkAgent({
    dshClient: new FakeDsh(),
    logger: { debug() {}, info() {}, warn() {}, error() {} },
    relayUrl: 'ws://relay.test', agentId: 'agt_1', agentSecret: 'as_1', heartbeatMs: 60000,
    connectImpl: async () => {
      const socket = new ConnectedSocket()
      sockets.push(socket)
      return socket
    },
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  agent.needsEnroll = false
  await agent.start()
  await until(() => agent.state === 'connected', `没能连上（state=${agent.state}）`)
  sockets[0].closeHandler?.(1000, 'bye')
  await until(() => agent.journal.entries().some((entry) => entry.kind === 'link.close'), '拆链没写进流水')
  await agent.stop()
  const close = agent.journal.entries().find((entry) => entry.kind === 'link.close')
  assert.ok(!('socketError' in close), `正常关闭不该带 socketError：${JSON.stringify(close)}`)
})

// ── spec 021：`_link/sessionDigest` 走完整 DLP 路径，且老方法逐字节不变 ─────────────

/** 一份最小"宿主形状"的列表：两个被剔除的投影键 + 一个保留键 + 一个未来字段。 */
function hostSessionList() {
  return {
    ok: true,
    value: {
      items: [{
        sessionId: 'session-1',
        updatedAt: 1_791_860_000_000,
        agentAvailable: true,
        running: true,
        blank: false,
        cwd: '/Users/x/p',
        origin: 'session',
        parentSessionId: null,
        futureField: 'keep-me',
        projections: {
          kind: 'sequenced',
          asOfSeq: 42,
          values: {
            title: '标题',
            turnOutline: [{ turn: 1, prompt: 'p'.repeat(500), response: 'r'.repeat(500) }],
            imageLimits: { maxImageBytes: 20_971_520 },
            tokenUsage: { totalTokens: 1234 },
          },
        },
      }],
    },
  }
}

const digestReq = (args, id = 'dg1') => ({ t: 'req', id, method: SESSION_DIGEST_METHOD, args, deviceId: 'dev_1' })

test('sessionDigest：走完整路径出精简结果，老方法一字不改', async () => {
  const page = hostSessionList()
  const { agent, dsh, socket } = makeAgent({ responses: { 'session/list': page } })
  await agent.handleRelayFrame(attach('dev_1'))

  // ① 新方法：不压缩
  await agent.handleRelayFrame(digestReq({ _request: {} }))
  const plain = socket.last('res')
  assert.equal(plain.ok, true)
  assert.equal(plain.value.encoding, 'identity')
  const item = plain.value.value.items[0]
  assert.ok(!('agentAvailable' in item), 'agentAvailable 应被剔除')
  assert.ok(!('kind' in item.projections), 'projections.kind 应被剔除')
  assert.ok(!('turnOutline' in item.projections.values), 'turnOutline 应被剔除')
  assert.ok(!('imageLimits' in item.projections.values), 'imageLimits 应被剔除')
  assert.equal(item.projections.values.title, '标题', '保留字段逐字不变')
  assert.equal(item.projections.asOfSeq, 42)
  assert.equal(item.futureField, 'keep-me', '名单之外的新字段要保留')
  assert.ok(JSON.stringify(plain.value.value).length < JSON.stringify(page.value).length * 0.5,
    '应省下一半以上')

  // ② 新方法：deflate-raw
  await agent.handleRelayFrame(digestReq({ _request: {}, encoding: 'deflate-raw' }, 'dg2'))
  const packed = socket.last('res')
  assert.equal(packed.value.encoding, 'deflate-raw')
  const bytes = inflateRawSync(Buffer.from(packed.value.value, 'base64'))
  assert.equal(packed.value.rawBytes, bytes.length, 'rawBytes 要和解压后长度一致')
  assert.deepEqual(JSON.parse(bytes.toString('utf8')), plain.value.value, '压缩往返无损')

  // ③ 老方法：一个字段都不许少（帧的 value 必须逐字段等于宿主给的那份）
  await agent.handleRelayFrame({ t: 'req', id: 'u9', method: 'session/list', args: { _request: {} }, deviceId: 'dev_1' })
  const legacy = socket.last('res')
  assert.deepEqual(legacy.value, page.value, 'session/list 的响应必须与宿主给的一模一样')
  const text = JSON.stringify(legacy)
  assert.ok(text.includes('agentAvailable') && text.includes('turnOutline') && text.includes('imageLimits'),
    '老路径不许被裁剪波及')
  assert.ok(dsh.calls.some((call) => call.method === 'session/list'), '新方法最终走的是宿主的 session/list')
})

test('sessionDigest：宿主失败时返回与老方法同形的错误', async () => {
  const { agent, dsh, socket } = makeAgent()
  dsh.rpcError = new Error('DSH is not connected')
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame(digestReq({ _request: {} }))
  const res = socket.last('res')
  assert.equal(res.ok, false)
  assert.equal(res.error.code, 'host/unavailable')
  assert.match(res.error.message, /DSH is not connected/)
})

// ---------------------------------------------------------------------------
// 会话内搜索的**链路级**集成：设备帧经连接器的路由表落到历史服务，再回来带上片数进度。
// 这一层盖住"单元测试各自过、拼起来却不对"的位置：方法名路由、args 解包、响应字段出网。
// ---------------------------------------------------------------------------

/// 宿主的 `sessionQuery` 替身：只实现扫描路径需要的两个方法
/// （没有 `searchEvents` → 连接器直接走扫描，正好是当前部署的形状）。
function fakeSessionQuery(count) {
  const log = Array.from({ length: count }, (_, seq) => ({
    seq,
    type: seq % 2 === 0 ? 'user/message' : 'assistant/message',
    time: 1_700_000_000_000 + seq,
    data: { text: `第 ${seq} 条，含关键词我` },
  }))
  return {
    async listEvents() {
      return log.map(({ seq, type, time }) => ({ seq, type, time }))
    },
    async filterEvents(sessionId, filters) {
      const range = (filters ?? []).find((filter) => filter.kind === 'seq')
      const text = (filters ?? []).find((filter) => filter.kind === 'text')
      if (range === undefined) return []
      return log
        .filter((event) => event.seq >= range.from && event.seq <= range.to)
        .filter((event) => text === undefined || event.data.text.includes(text.text))
        .map((event) => ({ sessionId, seq: event.seq, type: event.type, time: event.time,
                           data: event.data }))
    },
  }
}

test('a device-frame sessionFind lands on the history service and carries chunk progress', async () => {
  const { agent, socket } = makeAgent()
  const history = createHistoryService({ logger: { warn() {}, info() {} } })
  history.bindQuery(fakeSessionQuery(20))
  agent.setHistoryService(history)
  await agent.handleRelayFrame(attach())

  // 一个字的查询（owner 2026-10-17 把下限降到 1）也要走通，并且带回片数进度。
  await agent.handleRelayFrame({
    t: 'req', id: 'find1', method: '_link/sessionFind',
    args: { address: { kind: 'session', sessionId: 's-1' }, query: '我', limit: 3, chunk: 10 },
    deviceId: 'dev_1',
  })

  const reply = socket.frames('res').find((frame) => frame.id === 'find1')
  assert.ok(reply?.ok, `sessionFind 失败：${JSON.stringify(reply)}`)
  assert.equal(reply.value.hits.length, 3, '命中要回给设备')
  assert.equal(reply.value.source, 'scan', '没有索引就走扫描')
  assert.equal(reply.value.totalChunks, 2, '片数：20 条 seq、片宽 10')
  assert.ok(reply.value.remainingChunks <= reply.value.totalChunks, '剩余片数不得超过总数')
  assert.equal(reply.value.hasMore, true)
})

test('a device-frame sessionFind with no query and no roles is refused', async () => {
  const { agent, socket } = makeAgent()
  const history = createHistoryService({ logger: { warn() {}, info() {} } })
  history.bindQuery(fakeSessionQuery(20))
  agent.setHistoryService(history)
  await agent.handleRelayFrame(attach())

  await agent.handleRelayFrame({
    t: 'req', id: 'find2', method: '_link/sessionFind',
    args: { address: { kind: 'session', sessionId: 's-1' }, query: '' },
    deviceId: 'dev_1',
  })

  const reply = socket.frames('res').find((frame) => frame.id === 'find2')
  assert.equal(reply.ok, false)
  assert.equal(reply.error.code, 'link/query-too-short', '空查询不是搜索')
})

/**
 * 活动名单（spec 018）的**集成**用例：真 router + 真 agent + 假宿主 `ctx.jobs` + 假设备传输。
 *
 * 驱动一条完整链路：设备连上 → 宿主任务注册 → 连接器推帧 → 任务结算 → 再推帧 →
 * 设备断开 → 不再推。断言点是设备那一侧真正收到的帧（`(deviceId, frame)`），
 * 不是 roster 的返回值：契约 §3 的"整格替换""两台设备各收一份""断开后无帧"都在这里钉。
 *
 * 不碰网络、不碰真实会话：宿主与设备都是假的，`DSH_HOME` 指向临时目录。
 */

import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

// 隔离：连接器默认把身份与流水写在 `$DSH_HOME` 下（`agent.json` / `link-events.jsonl`）。
const TEST_HOME = mkdtempSync(join(tmpdir(), 'mobile-link-jobs-roster-integration-'))
process.env.DSH_HOME = TEST_HOME
process.on('exit', () => rmSync(TEST_HOME, { recursive: true, force: true }))

import { MobileLinkAgent } from '../lib/link.js'
import { JOBS_FRAME, ROSTER_METHOD } from '../lib/jobs-roster.js'

/** 宿主 DSH 客户端的假体：只够 router 打开 `$events` 流，绝不发 RPC。 */
class FakeDsh extends EventEmitter {
  constructor() {
    super()
    this.calls = []
    this.endpoint = { base: 'http://127.0.0.1:54499', port: 54499, source: 'test' }
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
    throw new Error(`the connector must answer ${method} locally, not forward it`)
  }

  close() {}
}

/** 中转那一侧的假体：只记下发出的帧，按 `(deviceId, frame)` 读。 */
class FakeSocket {
  constructor() {
    this.sent = []
    this.closed = false
  }

  send(text) {
    this.sent.push(JSON.parse(text))
  }

  close() {
    this.closed = true
  }

  /** 这台设备收到的 `link/jobs` 帧（走 item 或 event 两种投递口径都算）。 */
  jobFrames() {
    return this.sent
      .filter((frame) => (frame.t === 'item' || frame.t === 'event') && frame.value?.type === JOBS_FRAME)
      .map((frame) => ({ deviceId: frame.deviceId, value: frame.value.value, as: frame.t }))
  }

  responses(id) {
    return this.sent.filter((frame) => frame.t === 'res' && frame.id === id)
  }
}

/** 宿主 `ctx.jobs` 的假体：能注册 / 推进 / 结算任务，能向订阅者发事件。 */
function fakeJobs(initial = {}) {
  const bySession = new Map(Object.entries(initial))
  const listeners = new Set()
  const host = {
    filters: [],
    get subscriberCount() {
      return listeners.size
    },
    list(sessionId) {
      return bySession.get(sessionId) ?? []
    },
    events: {
      subscribe(filter, listener) {
        host.filters.push(filter)
        listeners.add(listener)
        return () => listeners.delete(listener)
      },
    },
    emit(event) {
      for (const listener of [...listeners]) listener(event)
    },
    register(entry) {
      const list = bySession.get(entry.owner) ?? []
      list.push(entry)
      bySession.set(entry.owner, list)
      host.emit({ type: 'registered', job: entry })
      return entry
    },
    progress(jobId, line) {
      const entry = host.find(jobId)
      entry.progress = line
      host.emit({ type: 'progress', job: entry })
    },
    settle(jobId, status = 'completed') {
      const entry = host.find(jobId)
      entry.status = status
      entry.finishedAt = Date.now()
      host.emit({ type: 'settled', job: entry, cause: 'producer', awaited: false })
      return entry
    },
    find(jobId) {
      for (const list of bySession.values()) {
        const entry = list.find((candidate) => candidate.id === jobId)
        if (entry !== undefined) return entry
      }
      throw new Error(`no such job: ${jobId}`)
    },
  }
  return host
}

function fakeSessions(ids) {
  return { list: () => ids.map((id) => ({ id })) }
}

function job(id, owner, status = 'running', extra = {}) {
  return {
    id,
    kind: 'bash',
    label: `run ${id}`,
    owner,
    status,
    startedAt: Date.now(),
    output: { total: 0, earliest: 0 },
    ...extra,
  }
}

/** 一台连接器 + 它的假 socket；给了 jobs/sessions 就等价于插件注入完成。 */
function makeAgent({ jobs, sessions } = {}) {
  const dsh = new FakeDsh()
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({
    dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1',
  })
  agent.setJobsServices({ jobs, sessions })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test', agentName: 'test mac' }
  const socket = new FakeSocket()
  agent.socket = socket
  return { agent, dsh, socket }
}

const attach = (deviceId) => ({
  t: 'deviceAttach', deviceId, device: { name: 'iPhone', model: 'iPhone17,1' },
})
const detach = (deviceId, reason = 'closed') => ({ t: 'deviceDetach', deviceId, reason })
/** 手机打开 `$events`：之后连接器自造的帧按 `item`（带 dlpId）投递。 */
const openEvents = (deviceId, id) => ({ t: 'open', deviceId, id, endpoint: '$events' })

async function connect(agent, socket, deviceId) {
  await agent.handleRelayFrame(attach(deviceId))
  await agent.handleRelayFrame(openEvents(deviceId, `ev-${deviceId}`))
}

/** 等条件成立，最多 4 秒（去抖窗口 120ms，用例留足余量）。 */
async function until(predicate, message, timeoutMs = 4000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error(`timed out: ${message}`)
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

test('两台设备各收一份；整格替换；断开后不再推帧', async () => {
  const jobs = fakeJobs({ s1: [] })
  const { agent, socket } = makeAgent({ jobs, sessions: fakeSessions(['s1']) })

  // 设备连上之前：不订阅、不攒帧（契约 §3）。
  jobs.register(job('bash-0', 's1'))
  await sleep(200)
  assert.equal(jobs.subscriberCount, 0, '没有设备就不该订阅宿主任务事件')
  assert.deepEqual(socket.jobFrames(), [], '没有人收的帧不该产出')

  await connect(agent, socket, 'dev_1')
  await connect(agent, socket, 'dev_2')
  assert.equal(jobs.subscriberCount, 1, '两台设备共用一份宿主订阅')
  assert.deepEqual(jobs.filters, [{ owners: 'all' }])

  // 注册 → 推帧。
  jobs.register(job('bash-1', 's1'))
  await until(() => socket.jobFrames().length === 2, '两台设备各该收到一帧')
  const pushed = socket.jobFrames()
  assert.deepEqual(pushed.map((entry) => entry.deviceId).sort(), ['dev_1', 'dev_2'])
  assert.deepEqual(pushed[0].value, pushed[1].value, '同一次变化，两台设备看到同一份')
  assert.equal(pushed[0].as, 'item', '开了 $events 的设备按 item 收')
  assert.equal(pushed[0].value.sessionId, 's1')
  assert.deepEqual(pushed[0].value.running.map((entry) => entry.id), ['bash-0', 'bash-1'],
    '注册顺序照宿主：先注册的 bash-0 在名单里，加上新的 bash-1')

  // 结算一件、再注册一件：窗口里的多次变化合并成一帧，且整格替换。
  jobs.settle('bash-0')
  jobs.register(job('bash-2', 's1'))
  jobs.progress('bash-2', '2/5')
  await until(() => socket.jobFrames().length === 4, '两台设备各该再收到一帧')
  const second = socket.jobFrames().slice(2)
  assert.equal(second[0].value.sessionId, 's1')
  assert.deepEqual(second[0].value.running.map((entry) => entry.id), ['bash-1', 'bash-2'],
    '整格替换：结算掉的 bash-0 不在帧里，没变的 bash-1 仍在')
  assert.equal(second[0].value.settled, 1)
  assert.equal(second[0].value.running.find((entry) => entry.id === 'bash-2').progress, '2/5')
  assert.equal(second[1].value.at, second[0].value.at, '同一窗口里的两台设备收到同一个时刻')

  // 断开两台设备：订阅释放，之后宿主再变也不推帧。
  await agent.handleRelayFrame(detach('dev_1'))
  await agent.handleRelayFrame(detach('dev_2'))
  assert.equal(jobs.subscriberCount, 0, '最后一台设备离开后订阅必须释放')
  const before = socket.jobFrames().length
  jobs.register(job('bash-3', 's1'))
  await sleep(300)
  assert.equal(socket.jobFrames().length, before, '断开后不得再推帧')
})

test('一台设备断开不影响另一台继续收帧', async () => {
  const jobs = fakeJobs({ s1: [] })
  const { agent, socket } = makeAgent({ jobs, sessions: fakeSessions(['s1']) })
  await connect(agent, socket, 'dev_1')
  await connect(agent, socket, 'dev_2')

  jobs.register(job('bash-1', 's1'))
  await until(() => socket.jobFrames().length === 2, '两台设备各一帧')

  await agent.handleRelayFrame(detach('dev_1'))
  assert.equal(jobs.subscriberCount, 1, '还有一台设备，订阅要留着')
  jobs.register(job('bash-2', 's1'))
  await until(() => socket.jobFrames().length === 3, '剩下的那台设备应再收到一帧')
  assert.equal(socket.jobFrames().at(-1).deviceId, 'dev_2', '帧只发给还在线的设备')

  // 撤销（`reason === 'revoked'`）走 #dropDevice：最后一台设备被放下，订阅同样释放。
  await agent.handleRelayFrame(detach('dev_2', 'revoked'))
  assert.equal(jobs.subscriberCount, 0, '设备被撤销后订阅必须释放')
  jobs.register(job('bash-3', 's1'))
  await sleep(300)
  assert.equal(socket.jobFrames().length, 3, '撤销之后不得再推帧')
})

test('没开 $events 的设备照旧按 event 帧收（与宿主事件同一条投递口径）', async () => {
  const jobs = fakeJobs({ s1: [] })
  const { agent, socket } = makeAgent({ jobs, sessions: fakeSessions(['s1']) })
  // 只连上、不打开 `$events`：投递应当退化成 `event` 帧（现有帧语义不变）。
  await agent.handleRelayFrame(attach('dev_1'))

  jobs.register(job('bash-1', 's1'))
  await until(() => socket.jobFrames().length === 1, '没开流的设备也该收到一帧')
  assert.equal(socket.jobFrames()[0].as, 'event')
  assert.equal(socket.jobFrames()[0].value.sessionId, 's1')
})

test('帧按会话分开：另一个会话的变化只推它那一格', async () => {
  const jobs = fakeJobs({ s1: [], s2: [] })
  const { agent, socket } = makeAgent({ jobs, sessions: fakeSessions(['s1', 's2']) })
  await connect(agent, socket, 'dev_1')

  jobs.register(job('bash-1', 's1'))
  jobs.register(job('bash-2', 's2'))
  await until(() => socket.jobFrames().length === 2, '两个会话各一帧')
  const [first, second] = socket.jobFrames().map((entry) => entry.value)
  assert.deepEqual([first.sessionId, second.sessionId].sort(), ['s1', 's2'])
  for (const frame of [first, second]) {
    assert.equal(frame.running.length, 1, '每帧只描述自己那一格')
  }
})

test('_link/jobRoster 由连接器自己回答，不转发宿主', async () => {
  const jobs = fakeJobs({ s1: [job('bash-1', 's1'), job('bash-0', 's1', 'completed')] })
  const { agent, dsh, socket } = makeAgent({ jobs, sessions: fakeSessions(['s1']) })
  await connect(agent, socket, 'dev_1')

  await agent.handleRelayFrame({ t: 'req', id: 'r1', deviceId: 'dev_1', method: ROSTER_METHOD, args: {} })
  const [reply] = socket.responses('r1')
  assert.ok(reply, '没收到 res 帧')
  assert.equal(reply.ok, true)
  assert.deepEqual(reply.value.sessions.s1.running.map((entry) => entry.id), ['bash-1'])
  assert.equal(reply.value.sessions.s1.settled, 1)
  assert.ok(dsh.calls.every((call) => call.kind !== 'rpc'), '名单是本地读取，不得走宿主 RPC')
})

test('没绑定宿主服务时 _link/jobRoster 回 link/unsupported（不是空名单）', async () => {
  const { agent, dsh, socket } = makeAgent()
  await connect(agent, socket, 'dev_1')

  await agent.handleRelayFrame({ t: 'req', id: 'r2', deviceId: 'dev_1', method: ROSTER_METHOD, args: {} })
  const [reply] = socket.responses('r2')
  assert.ok(reply, '没收到 res 帧')
  assert.equal(reply.ok, false)
  assert.equal(reply.error.code, 'link/unsupported')
  assert.equal('value' in reply, false, '不得回空名单')
  assert.ok(dsh.calls.every((call) => call.kind !== 'rpc'), '也不得转发给宿主')
})

test('参数不是空对象时经路由器回 gateway/bad-request', async () => {
  const jobs = fakeJobs({ s1: [] })
  const { agent, socket } = makeAgent({ jobs, sessions: fakeSessions(['s1']) })
  await connect(agent, socket, 'dev_1')

  await agent.handleRelayFrame({
    t: 'req', id: 'r3', deviceId: 'dev_1', method: ROSTER_METHOD, args: { sessionId: 's1' },
  })
  const [reply] = socket.responses('r3')
  assert.ok(reply, '没收到 res 帧')
  assert.equal(reply.ok, false)
  assert.equal(reply.error.code, 'gateway/bad-request')
})

test('插件注入晚于设备连接：首答之前补订阅，任务变化照样推', async () => {
  const jobs = fakeJobs({ s1: [] })
  // 先起 agent，不绑服务（等价于 ctx.inject 还没跑）。
  const { agent, socket } = makeAgent()
  await connect(agent, socket, 'dev_1')
  assert.equal(jobs.subscriberCount, 0, '服务没就绪时不订阅')
  assert.deepEqual(socket.jobFrames(), [])

  // 注入到位：roster 要对已连设备补报，不必等下一次 attach。
  agent.setJobsServices({ jobs, sessions: fakeSessions(['s1']) })
  assert.equal(jobs.subscriberCount, 1, '绑定服务后应补订阅')
  jobs.register(job('bash-1', 's1'))
  await until(() => socket.jobFrames().length === 1, '设备应收到任务帧')
  assert.equal(socket.jobFrames()[0].value.sessionId, 's1')
})

// ── 覆盖率审查补齐的缺口（018 / test-coverage.md §2） ─────────────────────

test('G1：设备全部离开后重新接入，订阅重新装上、后续事件照旧推帧', async () => {
  const jobs = fakeJobs({ s1: [] })
  const { agent, socket } = makeAgent({ jobs, sessions: fakeSessions(['s1']) })
  await connect(agent, socket, 'dev_1')

  jobs.register(job('bash-1', 's1'))
  await until(() => socket.jobFrames().length === 1, '连上后应收到一帧')

  // 全部离开：订阅释放（契约 §3 / 不变式 4）。
  await agent.handleRelayFrame(detach('dev_1'))
  assert.equal(jobs.subscriberCount, 0, '最后一台设备离开后订阅必须释放')
  jobs.register(job('bash-2', 's1'))
  await sleep(300)
  assert.equal(socket.jobFrames().length, 1, '离线期间不推帧')

  // 同一台设备再连一次：attach 是"回来"的唯一入口，订阅要在这里重新装上。
  await agent.handleRelayFrame(attach('dev_1'))
  assert.equal(jobs.subscriberCount, 1, '重新接入必须重新订阅宿主任务事件')
  jobs.register(job('bash-3', 's1'))
  await until(() => socket.jobFrames().length === 2, '重新接入后应再收到一帧')

  const frame = socket.jobFrames().at(-1)
  assert.equal(frame.deviceId, 'dev_1')
  assert.equal(frame.as, 'item', '$events 绑定还在，回来的设备照旧按 item 收')
  assert.equal(frame.value.sessionId, 's1')
  assert.deepEqual(frame.value.running.map((entry) => entry.id), ['bash-1', 'bash-2', 'bash-3'],
    '新帧是回来那一刻的整格（离线期间的变化不补发，只反映当前状态）')
})

test('G3：一台设备的投递抛错不影响其它设备，也不打断后续帧', async () => {
  const jobs = fakeJobs({ s1: [] })
  const { agent, socket } = makeAgent({ jobs, sessions: fakeSessions(['s1']) })
  await connect(agent, socket, 'dev_1')
  await connect(agent, socket, 'dev_2')

  // dev_1 那一侧的链路坏了：发送抛错（与 `#sendText` 的"发送异常只记 debug"是同一处）。
  const innermost = socket.send.bind(socket)
  let failedSends = 0
  socket.send = (text) => {
    if (JSON.parse(text).deviceId === 'dev_1') {
      failedSends += 1
      throw new Error('relay link is gone')
    }
    innermost(text)
  }

  jobs.register(job('bash-1', 's1'))
  await until(() => socket.jobFrames().length === 1, '另一台设备应照旧收到帧')
  assert.equal(socket.jobFrames()[0].deviceId, 'dev_2', '坏掉的那台收不到，另一台不受影响')
  assert.ok(failedSends >= 1, 'dev_1 的投递确实抛过')

  // 后续帧照旧：推送循环不因为上一台抛错而中断。
  jobs.settle('bash-1')
  await until(() => socket.jobFrames().length === 2, '后续帧不得被前面的投递异常打断')
  const next = socket.jobFrames().at(-1)
  assert.equal(next.deviceId, 'dev_2')
  assert.equal(next.value.settled, 1)
  assert.deepEqual(next.value.running, [])
})

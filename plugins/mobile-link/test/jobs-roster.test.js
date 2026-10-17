/**
 * 活动名单（spec 018）的不变量。
 *
 * 契约：`specs/018-mobile-activity-visibility/contracts/link-job-roster.md`。
 *
 * §4 的五条逐条钉住：终态过滤 / 无 `ctx.jobs` 回 `link/unsupported` / 参数非法回
 * `gateway/bad-request` / 设备断开释放订阅 / `at` 单调不减。另外补三条实现口径：
 * 没有设备的连接不订阅也不攒帧、`JobLite` 的字段取舍、宿主读取出错回 `link/failed`。
 *
 * 这里不碰网络、不碰真实会话：宿主与设备都是假的，时钟与去抖也是假的。
 */

import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

// 隔离：连接器默认把身份与流水写在 `$DSH_HOME` 下，用例一律指向临时目录。
const TEST_HOME = mkdtempSync(join(tmpdir(), 'mobile-link-jobs-roster-test-'))
process.env.DSH_HOME = TEST_HOME
process.on('exit', () => rmSync(TEST_HOME, { recursive: true, force: true }))

import {
  JOBS_FRAME, LIVE_STATUSES, ROSTER_METHOD,
  createJobsRoster, isJobsMethod, jobLite,
} from '../lib/jobs-roster.js'

/** 宿主 `ctx.jobs` 的假体：可按会话读、可发事件、能报"谁在订阅"。 */
function fakeJobs(initial = {}) {
  const bySession = new Map(Object.entries(initial))
  const listeners = new Set()
  const host = {
    filters: [],
    disposals: 0,
    disposed: 0,
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
        return () => {
          host.disposals += 1
          if (listeners.delete(listener)) host.disposed += 1
        }
      },
    },
    emit(event) {
      for (const listener of [...listeners]) listener(event)
    },
    /** 照宿主：注册先落进任务表，再发 `registered`。 */
    register(job) {
      const list = bySession.get(job.owner) ?? []
      list.push(job)
      bySession.set(job.owner, list)
      host.emit({ type: 'registered', job })
      return job
    },
    /** 照宿主：结算后 `list` 里仍是这条（状态变终态），事件是 `settled`。 */
    settle(jobId, status = 'completed') {
      for (const list of bySession.values()) {
        const job = list.find((entry) => entry.id === jobId)
        if (job === undefined) continue
        job.status = status
        job.finishedAt = 1_000_000
        host.emit({ type: 'settled', job, cause: 'producer', awaited: false })
        return job
      }
      throw new Error(`no such job: ${jobId}`)
    },
    /** 照宿主：进度写在任务本身上，事件带同一个对象。 */
    progress(jobId, line) {
      for (const list of bySession.values()) {
        const job = list.find((entry) => entry.id === jobId)
        if (job === undefined) continue
        job.progress = line
        host.emit({ type: 'progress', job })
        return job
      }
      throw new Error(`no such job: ${jobId}`)
    },
    /** 照宿主：任务从表里被移除（清理 / 回收），事件是 `removed`。 */
    remove(jobId) {
      for (const [owner, list] of bySession) {
        const index = list.findIndex((entry) => entry.id === jobId)
        if (index === -1) continue
        const [entry] = list.splice(index, 1)
        bySession.set(owner, list)
        host.emit({ type: 'removed', job: entry, reason: 'reaped' })
        return entry
      }
      throw new Error(`no such job: ${jobId}`)
    },
  }
  return host
}

/** 宿主 `ctx.sessions` 的假体：活会话按创建顺序。 */
function fakeSessions(ids) {
  return { list: () => ids.map((id) => ({ id })) }
}

/** 假调度器：去抖窗口由用例自己到期，不依赖真实定时器。 */
function fakeTimers() {
  let queue = []
  return {
    schedule(fn) {
      const job = { fn }
      queue.push(job)
      return job
    },
    cancel(job) {
      queue = queue.filter((entry) => entry !== job)
    },
    run() {
      const due = queue
      queue = []
      for (const job of due) job.fn()
    },
    get pending() {
      return queue.length
    },
  }
}

function fakeClock(start = 1_791_815_149_814) {
  let value = start
  return {
    now: () => value,
    set(next) {
      value = next
    },
  }
}

function job(id, owner, status = 'running', extra = {}) {
  return {
    id,
    kind: 'bash',
    label: `run ${id}`,
    owner,
    status,
    startedAt: 1_791_815_000_000,
    output: { total: 0, earliest: 0 },
    ...extra,
  }
}

function makeRoster({
  jobs, sessions, timers = fakeTimers(), clock = fakeClock(), logger, deliver,
} = {}) {
  const frames = []
  const roster = createJobsRoster({
    getJobs: () => jobs,
    getSessions: () => sessions,
    deliver: deliver ?? ((value) => frames.push(value)),
    logger: logger ?? { debug() {}, info() {}, warn() {} },
    now: clock.now,
    debounceMs: 10,
    schedule: timers.schedule,
    cancel: timers.cancel,
  })
  return { roster, frames, timers, clock }
}

test('方法名、帧名与活状态是冻结的契约字面量', () => {
  assert.equal(ROSTER_METHOD, '_link/jobRoster')
  assert.equal(JOBS_FRAME, 'link/jobs')
  assert.deepEqual([...LIVE_STATUSES], ['running', 'stopping'])
  assert.equal(isJobsMethod(ROSTER_METHOD), true)
  for (const other of ['_link/sessionWindow', '_link/sessionFind', 'job/list', '_link/hello']) {
    assert.equal(isJobsMethod(other), false, `${other} 不该被当成名单方法`)
  }
})

// ── 不变式 1：终态过滤 ───────────────────────────────────────────────────

test('不变式 1：running 里只出现 running / stopping，终态只计入 settled', async () => {
  const jobs = fakeJobs({
    s1: [
      job('bash-1', 's1', 'running'),
      job('bash-2', 's1', 'stopping'),
      job('bash-3', 's1', 'completed'),
      job('bash-4', 's1', 'killed'),
      job('bash-5', 's1', 'failed'),
    ],
  })
  const { roster } = makeRoster({ jobs, sessions: fakeSessions(['s1']) })
  const answer = await roster.handle({})

  assert.equal(answer.ok, true)
  const cell = answer.value.sessions.s1
  assert.deepEqual(cell.running.map((entry) => entry.id), ['bash-1', 'bash-2'],
    '终态任务不得混进 running')
  assert.equal(cell.settled, 3, '三条终态各计一次')
  for (const entry of cell.running) {
    assert.ok(LIVE_STATUSES.includes(entry.status), `${entry.id} 的状态 ${entry.status} 不是活状态`)
  }
})

test('一件任务都没有的会话不占位；只有已结算任务的会话仍然给出 settled', async () => {
  const jobs = fakeJobs({
    s1: [job('bash-1', 's1', 'completed')],
  })
  const { roster } = makeRoster({ jobs, sessions: fakeSessions(['s1', 's2']) })
  const answer = await roster.handle({})

  assert.deepEqual(Object.keys(answer.value.sessions), ['s1'],
    '没有任何任务的会话不该占位（手机把缺席读成"没有活"）')
  assert.deepEqual(answer.value.sessions.s1, { running: [], settled: 1 })
})

test('JobLite 只减不增：丢 outputLimitBytes / spillPaths，outputLost 由 earliest 推', async () => {
  const lite = jobLite({
    id: 'bash-9', kind: 'bash', label: 'pytest', owner: 's1', status: 'stopping',
    progress: '3/10', detail: 'SIGTERM', startedAt: 5, finishedAt: undefined,
    outputLimitBytes: 4096,
    output: { total: 120, earliest: 12, spillPaths: ['/tmp/spill'] },
  })
  assert.deepEqual(lite, {
    id: 'bash-9', kind: 'bash', label: 'pytest', status: 'stopping',
    startedAt: 5, outputTotal: 120, owner: 's1', progress: '3/10', detail: 'SIGTERM',
    outputLost: true,
  }, '进度/终止原因原样带上，输出环丢过头部时才有 outputLost')

  const idle = jobLite({ id: 'b', kind: 'bash', label: 'x', status: 'running', startedAt: 1, output: { total: 0, earliest: 0 } })
  assert.equal('progress' in idle, false, '缺省字段不带空值')
  assert.equal('detail' in idle, false)
  assert.equal('finishedAt' in idle, false)
  assert.equal('outputLost' in idle, false)
  assert.equal('owner' in idle, false, '无主任务没有 owner')
  assert.equal(idle.outputTotal, 0)
})

// ── 不变式 2：没有 ctx.jobs 回 link/unsupported ───────────────────────────

test('不变式 2：拿不到 ctx.jobs 时回 link/unsupported，不回空名单', async () => {
  const bare = createJobsRoster({ logger: { debug() {} } })
  const answer = await bare.handle({})
  assert.equal(answer.ok, false)
  assert.equal(answer.error.code, 'link/unsupported')
  assert.equal('value' in answer, false, '不得给出空名单——那会被手机读成"没有任务在跑"')

  // 只有一半服务也一样：缺 sessions 就枚举不出活会话。
  const half = makeRoster({ jobs: fakeJobs(), sessions: undefined }).roster
  assert.equal((await half.handle({})).error.code, 'link/unsupported')
  const other = makeRoster({ jobs: undefined, sessions: fakeSessions(['s1']) }).roster
  assert.equal((await other.handle({})).error.code, 'link/unsupported')
})

test('宿主读取出错回 link/failed，details 不带宿主内部栈', async () => {
  const jobs = fakeJobs()
  const sessions = { list: () => { throw new Error('session store is closed') } }
  const { roster } = makeRoster({ jobs, sessions })
  const answer = await roster.handle({})
  assert.equal(answer.ok, false)
  assert.equal(answer.error.code, 'link/failed')
  assert.match(answer.error.message, /session store is closed/)
  assert.deepEqual(answer.error.details, {})
})

// ── 不变式 3：参数非法回 gateway/bad-request ──────────────────────────────

test('不变式 3：args 不是空对象时回 gateway/bad-request', async () => {
  const { roster } = makeRoster({ jobs: fakeJobs(), sessions: fakeSessions(['s1']) })
  for (const args of [{ sessionId: 's1' }, { _request: {} }, [], 'x', 42]) {
    const answer = await roster.handle(args)
    assert.equal(answer.ok, false, `${JSON.stringify(args)} 不该被接受`)
    assert.equal(answer.error.code, 'gateway/bad-request')
  }
  // 空对象与缺省都是合法请求（契约 §2：无参数）。
  assert.equal((await roster.handle({})).ok, true)
  assert.equal((await roster.handle(undefined)).ok, true)
})

// ── 不变式 4：设备断开释放订阅 ────────────────────────────────────────────

test('不变式 4：最后一个设备离开时释放宿主订阅，之后不再产帧', async () => {
  const jobs = fakeJobs({ s1: [] })
  const timers = fakeTimers()
  const { roster, frames } = makeRoster({ jobs, sessions: fakeSessions(['s1']), timers })

  assert.equal(roster.addDevice('dev_1'), true)
  assert.equal(roster.subscribed, true, '有设备才订阅')
  assert.deepEqual(jobs.filters, [{ owners: 'all' }], '订阅要看全部会话，不只看某个作用域')

  jobs.register(job('bash-1', 's1'))
  assert.equal(timers.pending, 1, '窗口内的事件合成一帧')
  timers.run()
  assert.equal(frames.length, 1)
  assert.equal(frames[0].type, JOBS_FRAME)

  // 断开：订阅被释放（disposer 真的被调用），窗口里排队的帧也不再发。
  jobs.register(job('bash-2', 's1'))
  assert.equal(roster.removeDevice('dev_1'), true)
  assert.equal(jobs.disposals, 1, 'disposer 必须被调用')
  assert.equal(jobs.subscriberCount, 0)
  assert.equal(roster.subscribed, false)
  assert.equal(timers.pending, 0, '设备没了，排队的去抖定时器也要撤掉')

  jobs.emit({ type: 'registered', job: job('bash-3', 's1') })
  assert.equal(timers.pending, 0, '释放之后宿主事件不再排帧')
  assert.equal(frames.length, 1, '断开后不得再推帧')

  // 第二台设备还在时不释放；只有最后一台离开才释放。
  roster.addDevice('dev_2')
  roster.addDevice('dev_3')
  roster.removeDevice('dev_2')
  assert.equal(roster.subscribed, true, '还有设备时订阅要留着')
  roster.removeDevice('dev_3')
  assert.equal(roster.subscribed, false)
  assert.equal(jobs.disposals, 2)
})

test('没有任何设备时既不订阅、也不攒帧', () => {
  const jobs = fakeJobs({ s1: [] })
  const timers = fakeTimers()
  const { roster, frames } = makeRoster({ jobs, sessions: fakeSessions(['s1']), timers })

  jobs.register(job('bash-1', 's1'))
  assert.equal(roster.subscribed, false, '设备数为 0 时不该订阅宿主事件')
  assert.equal(timers.pending, 0, '没人收的帧不必排队')
  timers.run()
  assert.deepEqual(frames, [])
})

test('注入晚于第一台设备：绑定服务后补订阅，不必等下一次 attach', () => {
  const jobs = fakeJobs({ s1: [] })
  const timers = fakeTimers()
  const roster = createJobsRoster({
    getJobs: () => undefined,
    getSessions: () => undefined,
    deliver: () => {},
    logger: { debug() {} },
    schedule: timers.schedule,
    cancel: timers.cancel,
  })
  roster.addDevice('dev_1')
  assert.equal(roster.subscribed, false, '服务还没就绪，先不订阅')
  roster.bindServices({ jobs, sessions: fakeSessions(['s1']) })
  assert.equal(roster.available, true)
  assert.equal(roster.subscribed, true, '服务就绪后要自己补订阅')
  assert.equal(jobs.subscriberCount, 1)
})

test('teardownAll 的收尾：设备、订阅、定时器一并清掉', () => {
  const jobs = fakeJobs({ s1: [] })
  const timers = fakeTimers()
  const { roster } = makeRoster({ jobs, sessions: fakeSessions(['s1']), timers })
  roster.addDevice('dev_1')
  roster.addDevice('dev_2')
  jobs.register(job('bash-1', 's1'))
  roster.releaseAll()
  assert.equal(roster.deviceCount, 0)
  assert.equal(roster.subscribed, false)
  assert.equal(jobs.subscriberCount, 0)
  assert.equal(timers.pending, 0)
})

// ── 不变式 5：at 单调不减 ────────────────────────────────────────────────

test('不变式 5：同一连接内 at 单调不减（时钟回拨也不倒退）', async () => {
  const clock = fakeClock(1_000)
  const jobs = fakeJobs({ s1: [job('bash-1', 's1')] })
  const { roster } = makeRoster({ jobs, sessions: fakeSessions(['s1']), clock })

  const first = await roster.handle({})
  assert.equal(first.value.at, 1_000)
  clock.set(900) // 时钟回拨
  const second = await roster.handle({})
  assert.ok(second.value.at >= first.value.at, `at 倒退了：${first.value.at} → ${second.value.at}`)
  clock.set(1_200)
  const third = await roster.handle({})
  assert.equal(third.value.at, 1_200, '时钟前进时照常前进')
})

test('推帧的 at 与首答同一口径：后一帧不小于前一帧', async () => {
  const clock = fakeClock(2_000)
  const jobs = fakeJobs({ s1: [] })
  const timers = fakeTimers()
  const { roster, frames } = makeRoster({ jobs, sessions: fakeSessions(['s1']), timers, clock })
  roster.addDevice('dev_1')

  jobs.register(job('bash-1', 's1'))
  timers.run()
  clock.set(1_500) // 回拨
  jobs.settle('bash-1')
  timers.run()

  assert.equal(frames.length, 2)
  assert.ok(frames[1].value.at >= frames[0].value.at, '乱序帧必须能被 at 判掉')
})

// ── 推帧的形状 ───────────────────────────────────────────────────────────

test('去抖窗口内同一会话的多次变化合成一帧，且是整格替换', () => {
  const jobs = fakeJobs({ s1: [job('bash-1', 's1')], s2: [job('bash-2', 's2')] })
  const timers = fakeTimers()
  const { roster, frames } = makeRoster({ jobs, sessions: fakeSessions(['s1', 's2']), timers })
  roster.addDevice('dev_1')

  jobs.register(job('bash-3', 's1'))
  jobs.settle('bash-1')
  jobs.emit({ type: 'progress', job: job('bash-3', 's1', 'running', { progress: '1/3' }) })
  assert.equal(timers.pending, 1, '窗口内只排一帧')

  timers.run()
  assert.equal(frames.length, 1)
  const frame = frames[0]
  assert.equal(frame.type, JOBS_FRAME)
  assert.equal(frame.value.sessionId, 's1', '帧只描述变过的那个会话')
  assert.deepEqual(frame.value.running.map((entry) => entry.id), ['bash-3'],
    '整格替换：结算掉的 bash-1 不在帧里')
  assert.equal(frame.value.settled, 1)
  assert.ok(frame.value.at >= 1, '帧带采样时刻')
})

test('无主任务没有归属会话，进不了推帧；首答里仍然可见', async () => {
  const timers = fakeTimers()
  const unowned = job('bash-9', undefined)
  delete unowned.owner
  // 宿主的可见集是"该会话自己的 + 所有无主任务"，所以它会出现在每个会话的读里。
  const jobs = fakeJobs({ s1: [unowned] })
  const { roster, frames } = makeRoster({ jobs, sessions: fakeSessions(['s1']), timers })
  roster.addDevice('dev_1')
  jobs.emit({ type: 'registered', job: unowned })
  assert.equal(timers.pending, 0, '一格都放不下的任务不排帧')
  timers.run()
  assert.deepEqual(frames, [])

  const answer = await roster.handle({})
  assert.deepEqual(answer.value.sessions.s1.running.map((entry) => entry.id), ['bash-9'])
  assert.equal('owner' in answer.value.sessions.s1.running[0], false)
})

// ── 覆盖率审查补齐的缺口（018 / test-coverage.md §2，G1–G6） ──────────────

test('G1：设备全部离开后重新接入，订阅重新装上、后续事件照旧推帧', () => {
  const jobs = fakeJobs({ s1: [] })
  const timers = fakeTimers()
  const { roster, frames } = makeRoster({ jobs, sessions: fakeSessions(['s1']), timers })

  roster.addDevice('dev_1')
  jobs.register(job('bash-1', 's1'))
  timers.run()
  assert.equal(frames.length, 1)

  // 全部离开：订阅释放（不变式 4）。
  roster.removeDevice('dev_1')
  assert.equal(roster.subscribed, false)
  assert.equal(jobs.subscriberCount, 0)
  // 离线期间宿主照样在变：不推、也不攒（契约 §3）。
  jobs.register(job('bash-2', 's1'))
  jobs.settle('bash-2')
  assert.equal(timers.pending, 0, '离线期间不排帧')
  assert.equal(frames.length, 1, '离线期间不推帧')

  // 同一台设备回来：必须重新订阅（旧的 listener 已经 dispose 掉了）。
  assert.equal(roster.addDevice('dev_1'), true, '回头客要重新进名单')
  assert.equal(roster.subscribed, true, '重新接入必须重新订阅宿主任务事件')
  assert.equal(jobs.subscriberCount, 1, '订阅是真的重装的，不是复用一个已 dispose 的 listener')
  assert.deepEqual(jobs.filters, [{ owners: 'all' }, { owners: 'all' }], '重装时仍要覆盖全部会话')

  jobs.register(job('bash-3', 's1'))
  assert.equal(timers.pending, 1, '回来之后事件要重新排帧')
  timers.run()
  assert.equal(frames.length, 2, '回来之后必须能再收帧')
  assert.equal(frames[1].value.sessionId, 's1')
  assert.deepEqual(frames[1].value.running.map((entry) => entry.id), ['bash-1', 'bash-3'],
    '新帧是回来那一刻的整格：在跑的那两件都在，离线期间结算掉的 bash-2 不在')
  assert.equal(frames[1].value.settled, 1, '离线期间结算的那件只计一次')
})

test('G2：推帧刷新时宿主读取抛错——记 warn、不推坏帧、下一轮事件恢复推帧', () => {
  const jobs = fakeJobs({ s1: [job('bash-1', 's1')], s2: [job('bash-2', 's2')] })
  const timers = fakeTimers()
  const warnings = []
  const logger = { debug() {}, info() {}, warn: (message) => warnings.push(message) }
  const { roster, frames } = makeRoster({
    jobs, sessions: fakeSessions(['s1', 's2']), timers, logger,
  })
  roster.addDevice('dev_1')

  // 宿主读 s1 的那一格时抛错（另一个会话照旧可读）。
  const realList = jobs.list.bind(jobs)
  jobs.list = (sessionId) => {
    if (sessionId === 's1') throw new Error('job table is closed')
    return realList(sessionId)
  }
  jobs.emit({ type: 'progress', job: job('bash-1', 's1', 'running', { progress: '2/9' }) })
  jobs.progress('bash-2', '1/9')
  assert.doesNotThrow(() => timers.run(), '读取抛错不得冲进定时器回调')

  assert.equal(warnings.filter((message) => /job table is closed/.test(message)).length, 1,
    '手机可见的漏帧要记 warn')
  assert.deepEqual(frames.map((frame) => frame.value.sessionId), ['s2'],
    '读不到的那一格不推——推一份空 running 会把手机上正在跑的任务擦掉')
  assert.equal(frames[0].value.running.length, 1)
  assert.equal(frames[0].value.running[0].progress, '1/9')

  // 恢复：宿主读得动了，下一轮事件照旧推那一格。
  jobs.list = realList
  jobs.settle('bash-1')
  timers.run()
  assert.equal(frames.length, 2, '读恢复之后要能继续推帧')
  assert.equal(frames[1].value.sessionId, 's1')
  assert.equal(frames[1].value.settled, 1)
  assert.deepEqual(frames[1].value.running, [])
})

test('G3：投递回调抛错不影响其它格，也不打断后续帧', () => {
  const jobs = fakeJobs({ s1: [job('bash-1', 's1')], s2: [job('bash-2', 's2')] })
  const timers = fakeTimers()
  const delivered = []
  const warnings = []
  const { roster } = makeRoster({
    jobs,
    sessions: fakeSessions(['s1', 's2']),
    timers,
    logger: { debug() {}, info() {}, warn: (message) => warnings.push(message) },
    deliver: (value) => {
      if (value.value.sessionId === 's1') {
        delivered.push(value.value.sessionId)
        throw new Error('relay link is gone')
      }
      delivered.push(value.value.sessionId)
    },
  })
  roster.addDevice('dev_1')

  jobs.register(job('bash-3', 's1'))
  jobs.register(job('bash-4', 's2'))
  assert.doesNotThrow(() => timers.run(), '投递抛错不得从定时器回调里漏出去')
  assert.deepEqual(delivered, ['s1', 's2'], '一格投递失败不得吃掉同一窗口里另一格的帧')
  assert.equal(warnings.filter((message) => /relay link is gone/.test(message)).length, 1,
    '投递失败要记 warn')

  // 后续帧照旧：pending 与定时器都不得卡住。
  jobs.settle('bash-4')
  assert.equal(timers.pending, 1, '后面的变化照旧排帧')
  timers.run()
  assert.deepEqual(delivered, ['s1', 's2', 's2'], '下一轮帧必须还能送出去')
})

test('G4：removed 事件推一帧——重算后 running 为空、settled 递减', () => {
  const jobs = fakeJobs({ s1: [job('bash-1', 's1'), job('bash-0', 's1', 'completed')] })
  const timers = fakeTimers()
  const { roster, frames } = makeRoster({ jobs, sessions: fakeSessions(['s1']), timers })
  roster.addDevice('dev_1')

  jobs.remove('bash-1')
  assert.equal(timers.pending, 1, 'removed 改了名单，要排帧')
  timers.run()
  assert.equal(frames.length, 1, 'removed 必须推一帧')
  assert.deepEqual(frames[0].value.running, [], '被移除的在跑任务不再出现，running 为空')
  assert.equal(frames[0].value.settled, 1, '只剩那条结算过的')

  jobs.remove('bash-0')
  assert.equal(timers.pending, 1)
  timers.run()
  assert.equal(frames.length, 2)
  assert.equal(frames[1].value.settled, 0, '结算过的也被移除后 settled 归零（现算，不累加）')
  assert.deepEqual(frames[1].value.running, [])
})

test('G5：ctx.sessions.list() 读回异常形状时按空名单处理，不崩也不报 failed', async () => {
  const jobs = fakeJobs({ s1: [job('bash-1', 's1')] })
  const shapes = [
    ['返回 undefined', () => undefined],
    ['返回 null', () => null],
    ['返回非数组对象', () => ({ sessions: [{ id: 's1' }] })],
    ['返回数字', () => 42],
    ['返回字符串', () => 's1'],
    ['list 不是函数', () => ({ list: 'nope' })],
  ]
  for (const [label, list] of shapes) {
    const { roster } = makeRoster({ jobs, sessions: { list } })
    const answer = await roster.handle({})
    assert.equal(answer.ok, true, `${label}：应给空名单，不是错误（错误会被手机读成"不支持"）`)
    assert.deepEqual(answer.value.sessions, {}, `${label}：异常形状按"没有活会话"处理`)
  }
})

test('G5：会话元素缺 id 时跳过它，其余照常给出', async () => {
  const jobs = fakeJobs({ s1: [job('bash-1', 's1')] })
  const sessions = {
    list: () => [{ id: 's1' }, {}, null, undefined, { id: '' }, { id: 7 }, 's2'],
  }
  const { roster } = makeRoster({ jobs, sessions })
  const answer = await roster.handle({})
  assert.equal(answer.ok, true)
  assert.deepEqual(Object.keys(answer.value.sessions), ['s1'],
    '缺 id / 空 id / 非字符串 id 的条目跳过；没有任务的 s2 不占位')
  assert.deepEqual(answer.value.sessions.s1.running.map((entry) => entry.id), ['bash-1'])
})

test('G6：同一 at 的两帧都下发且后者生效——不倒退、不重复累加', () => {
  const clock = fakeClock(5_000)
  const jobs = fakeJobs({ s1: [job('bash-1', 's1')] })
  const timers = fakeTimers()
  const { roster, frames } = makeRoster({
    jobs, sessions: fakeSessions(['s1']), timers, clock,
  })
  roster.addDevice('dev_1')

  jobs.register(job('bash-2', 's1'))
  timers.run()
  // 时钟不走：第二帧的采样时刻与第一帧相同（毫秒内两次刷新）。
  jobs.progress('bash-2', '4/9')
  jobs.settle('bash-1')
  timers.run()

  assert.equal(frames.length, 2, '同一毫秒的两帧都要下发，手机按"后者生效"处理')
  const [first, second] = frames
  assert.equal(second.value.at, first.value.at, '同一毫秒内 at 相等')
  assert.ok(second.value.at >= first.value.at, 'at 不得倒退')
  assert.deepEqual(second.value.running.map((entry) => entry.id), ['bash-2'],
    '后者是重算后的最新一格')
  assert.equal(second.value.running[0].progress, '4/9')
  assert.equal(second.value.settled, 1, 'settled 是现算的：一条终态，不是两帧累加')
  assert.deepEqual(first.value.running.map((entry) => entry.id), ['bash-1', 'bash-2'],
    '前一帧的内容不被后来者改写（帧是快照，不是引用）')
})

/**
 * 活动名单：本地方法 `_link/jobRoster` 与推帧 `link/jobs`（spec 018）。
 *
 * 为什么由连接器聚合：宿主没有 host-wide 的任务读法——`JobRegistry.list(caller)`
 * 只回该会话自己的 + 所有无主任务，`session/control` 的基线在本版本也只带
 * projections。连接器与宿主同进程，逐会话读是内存过滤，既没有网络往返，也不需要
 * 手机为每个会话各开一条 `job/list` 流。
 *
 * 契约：`specs/018-mobile-activity-visibility/contracts/link-job-roster.md`。
 * 与 `_link/sessionWindow` / `_link/sessionFind` 同族：连接器自己回答，不转发宿主。
 * 特性检测而不是版本比较——拿不到 `ctx.jobs` 时回 `link/unsupported`，手机整块不显示。
 */

/** 连接器自答的方法名（`_link/` 前缀表示"不转发宿主"，与 history 一族一致）。 */
export const ROSTER_METHOD = '_link/jobRoster'

/** 推帧的 `type`。包在 per-device `$events` 的 item 里，旧 App 当未知类型忽略。 */
export const JOBS_FRAME = 'link/jobs'

/**
 * 还算"活着"的状态。其余（`completed` / `killed` / `failed`，以及宿主将来可能
 * 新增的终态）一律只计入 `settled`，不下发——否则每个会话的历史任务都会跟着名单
 * 一起上手机。
 */
export const LIVE_STATUSES = Object.freeze(['running', 'stopping'])

/**
 * 合并窗口（毫秒）。一次任务生命周期里宿主会在毫秒级连发 registered / progress /
 * stopping / settled 几个事件；按会话合并成最后一帧，手机只看到稳定后的那一格。
 */
export const DEFAULT_DEBOUNCE_MS = 120

const LIVE = new Set(LIVE_STATUSES)

/** 会改变名单的宿主事件。`output` 只影响输出流，不影响这一格。 */
const LIFECYCLE_TYPES = new Set(['registered', 'progress', 'stopping', 'settled', 'removed'])

function messageOf(error) {
  return error instanceof Error ? error.message : String(error)
}

function failure(code, message, details = {}) {
  return { ok: false, error: { code, message, details } }
}

/** 默认调度器：`unref` 掉，去抖窗口里没有别的事情时不该把进程按住不让退出。 */
function defaultSchedule(fn, ms) {
  const handle = setTimeout(fn, ms)
  handle.unref?.()
  return handle
}

function defaultCancel(handle) {
  clearTimeout(handle)
}

/**
 * 请求参数只允许空对象（契约 §2）。未知字段一律拒绝：放宽了，将来某个字段改名
 * 就会静默变成"没有过滤条件"，而不是一条能看到的 bad-request。
 * @returns {object|undefined} 失败时的回包，成功时 undefined
 */
function checkArgs(args) {
  if (args === undefined || args === null) return undefined
  if (typeof args !== 'object' || Array.isArray(args)) {
    return failure('gateway/bad-request', 'arguments must be an empty object')
  }
  const keys = Object.keys(args)
  if (keys.length > 0) return failure('gateway/bad-request', `unknown field "${keys[0]}"`)
  return undefined
}

/**
 * 宿主 `JobView` → 契约的 `JobLite`。
 *
 * 只减不增：手机不读 `outputLimitBytes` / `spillPaths`，就不下发。`progress` /
 * `detail` / `finishedAt` 按宿主现值原样带上，缺省即不带（不补 null，手机按"没有"
 * 处理）。`outputLost` 是唯一重命名：`output.earliest > 0` 表示输出环丢过头部。
 */
export function jobLite(job) {
  const output = job?.output ?? {}
  const lite = {
    id: job?.id,
    kind: job?.kind,
    label: job?.label,
    status: job?.status,
    startedAt: job?.startedAt,
    outputTotal: Number.isFinite(output.total) ? output.total : 0,
  }
  if (typeof job?.owner === 'string' && job.owner) lite.owner = job.owner
  if (typeof job?.progress === 'string') lite.progress = job.progress
  if (typeof job?.detail === 'string') lite.detail = job.detail
  if (Number.isFinite(job?.finishedAt)) lite.finishedAt = job.finishedAt
  if (Number.isFinite(output.earliest) && output.earliest > 0) lite.outputLost = true
  return lite
}

/** 会话对象 → id。宿主的 `Session` 把 id 放在 `id` 上；裸 id 只在测试与将来的读法里出现。 */
function sessionIdOf(entry) {
  const id = typeof entry === 'string' ? entry : entry?.id
  return typeof id === 'string' && id.length > 0 ? id : undefined
}

/**
 * @param {{
 *   getJobs?: () => object | undefined,
 *   getSessions?: () => object | undefined,
 *   deliver?: (value: object) => void,
 *   logger?: { debug?: Function, info?: Function, warn?: Function },
 *   now?: () => number,
 *   debounceMs?: number,
 *   schedule?: (fn: Function, ms: number) => unknown,
 *   cancel?: (handle: unknown) => void,
 * }} deps
 */
export function createJobsRoster({
  getJobs = () => undefined,
  getSessions = () => undefined,
  deliver = () => {},
  logger = console,
  now = Date.now,
  debounceMs = DEFAULT_DEBOUNCE_MS,
  schedule = defaultSchedule,
  cancel = defaultCancel,
} = {}) {
  /**
   * 服务来自两处：构造参数是读取函数（`link.js` 用它把 roster 接在 agent 上），
   * `bindServices` 是插件注入时直接把服务实例交进来。**后者优先**：注入晚于第一台
   * 设备连接时，正是它让订阅能补上。
   */
  const bound = { jobs: undefined, sessions: undefined }

  /**
   * 已在线、且需要收 `link/jobs` 的设备。**不**包含"断了但 `$events` 还替它值班"的
   * 设备：离线期间的旧任务状态没有补发意义（契约 §3），重连后手机重新问一次名单。
   */
  const devices = new Set()
  /** 宿主 `ctx.jobs.events.subscribe(...)` 的 disposer；undefined = 现在没订阅。 */
  let unsubscribe
  /** 去抖定时器的句柄；undefined = 没有排队的帧。 */
  let timer
  /** 窗口内变过的会话；flush 时逐个重算那一格。 */
  const pending = new Set()
  /** 已发出的最大 `at`：同一连接内单调不减，手机据此丢弃乱序帧（契约 §4.5）。 */
  let lastAt = 0

  function jobs() {
    return bound.jobs ?? getJobs()
  }

  function sessions() {
    return bound.sessions ?? getSessions()
  }

  function available() {
    return jobs() !== undefined && sessions() !== undefined
  }

  /**
   * 挂上（或摘下）宿主服务。注入可能晚于第一台设备连上，所以绑定后要补一次订阅：
   * 只在 attach 时订阅的话，这台连接会一直到下一次设备 attach 才开始推帧。
   */
  function bindServices(next = {}) {
    bound.jobs = next.jobs
    bound.sessions = next.sessions
    if (devices.size > 0) {
      if (available()) subscribe()
      else releaseSubscription()
    }
    return available()
  }

  function nextAt() {
    const value = Number(now())
    if (Number.isFinite(value) && value > lastAt) lastAt = value
    return lastAt
  }

  /** 一个会话那一格：只留活的任务，其余计数。 */
  function cellOf(sessionId) {
    const running = []
    let settled = 0
    for (const job of jobs().list(sessionId) ?? []) {
      if (LIVE.has(job?.status)) running.push(jobLite(job))
      else settled += 1
    }
    return { running, settled }
  }

  /**
   * 宿主活会话列表（`ctx.sessions.list()`）。
   *
   * 形状不可信：`undefined` / 非数组 / `list` 不是函数（宿主换实现、依赖没装全时都可能）
   * 一律当空名单。名单只是一份旁路读数，为它把整个 `_link/jobRoster` 变成
   * `link/failed`，等于跟手机说"这台连接器不支持活动名单"（契约 §2 的失败口径只留给
   * **真的读不出来**的情形）。读的时候**抛错**仍然向上抛，由 `handle` 转成 `link/failed`。
   * 元素缺 `id` 不是异常形状，在 `sample` 里逐条跳过。
   */
  function sessionEntries() {
    const store = sessions()
    if (typeof store?.list !== 'function') return []
    const listed = store.list()
    return Array.isArray(listed) ? listed : []
  }

  /** 整份名单（`_link/jobRoster` 的 `value`）。 */
  function sample() {
    const at = nextAt()
    const out = {}
    for (const entry of sessionEntries()) {
      const sessionId = sessionIdOf(entry)
      if (sessionId === undefined || out[sessionId] !== undefined) continue
      let cell
      try {
        cell = cellOf(sessionId)
      } catch (error) {
        // 会话在枚举与读取之间消失，或宿主拒绝这次读：少一格好过整份名单失败。
        logger.debug?.(`mobile-link: job roster skipped ${sessionId}: ${messageOf(error)}`)
        continue
      }
      // 一件任务都没有的会话不占位：手机把"缺席"读成"没有活"（契约 §2）。
      // 有已结算任务的会话仍然占位——`settled` 是面板「已结束 N 个」的口径。
      if (cell.running.length === 0 && cell.settled === 0) continue
      out[sessionId] = cell
    }
    return { at, sessions: out }
  }

  function subscribe() {
    if (unsubscribe !== undefined) return
    const events = jobs()?.events
    if (typeof events?.subscribe !== 'function') {
      logger.debug?.('mobile-link: this Host has no jobs event stream; link/jobs frames stay off')
      return
    }
    try {
      // `{owners:'scope'}`：连接器挂在宿主全局层，作用域就是整个进程，等价于"全部会话"。
      //
      // 不用 `{owners:'all'}`：本机实测（0.2.0-rc.2 桌面版宿主）该过滤器的订阅装上了
      // 但**一条事件都收不到**（subscribe 成功、onChange 从不触发），于是 `link/jobs`
      // 永远不推、手机只能显示建连那一刻的名单（2026-10-17 owner 报"任务结束了手机还显示在跑"）。
      // `scope` 在同一宿主上按预期收到 registered/settled/removed，因此改用它。
      unsubscribe = events.subscribe({ owners: 'scope' }, onChange)
    } catch (error) {
      logger.warn?.(`mobile-link: subscribing to jobs events failed: ${messageOf(error)}`)
    }
  }

  function releaseSubscription() {
    const dispose = unsubscribe
    unsubscribe = undefined
    if (typeof dispose !== 'function') return
    try {
      dispose()
    } catch (error) {
      logger.debug?.(`mobile-link: releasing jobs events failed: ${messageOf(error)}`)
    }
  }

  function onChange(event) {
    if (!LIFECYCLE_TYPES.has(event?.type)) return
    // 帧只描述"一个会话的那一格"；无主任务没有归属会话，放不进任何一格。
    // 它仍然会在 `_link/jobRoster` 的首答里出现（宿主对每个会话都可见）。
    const sessionId = event?.job?.owner
    if (typeof sessionId !== 'string' || sessionId.length === 0) return
    pending.add(sessionId)
    arm()
  }

  function arm() {
    if (timer !== undefined) return
    timer = schedule(flush, debounceMs)
  }

  function flush() {
    timer = undefined
    const dirty = [...pending]
    pending.clear()
    // 没有在线设备：不产帧、也不把变化攒着（契约 §3「设备未连接时不产生帧，不缓存」）。
    if (devices.size === 0 || dirty.length === 0) return
    const at = nextAt()
    for (const sessionId of dirty) {
      let cell
      try {
        cell = cellOf(sessionId)
      } catch (error) {
        // 读不到就不推：推一份空的 `running` 会把手机上正在跑的任务擦掉（比漏一帧更糟）。
        // 记 warn——这是一次手机可见的漏帧，不是无关噪音；这一格在下一轮事件到来时重算。
        logger.warn?.(`mobile-link: link/jobs skipped ${sessionId}: ${messageOf(error)}`)
        continue
      }
      try {
        deliver({
          type: JOBS_FRAME,
          value: { at, sessionId, running: cell.running, settled: cell.settled },
        })
      } catch (error) {
        // 投递失败只算这一帧丢了：若让异常掀掉整个 flush，同一窗口里其它会话的帧会一起
        // 发不出去，而且它会冲进定时器回调，把进程级异常变成无人接的错误。
        logger.warn?.(`mobile-link: link/jobs delivery failed: ${messageOf(error)}`)
      }
    }
  }

  /**
   * 帧处理（`_link/jobRoster`）。回包形状与 history 一族一致：`{ok:true,value}` 或
   * `{ok:false,error:{code,message,details}}`。
   */
  async function handle(args) {
    const rejected = checkArgs(args)
    if (rejected !== undefined) return rejected
    // 没有 ctx.jobs 时**不能**回空名单：空名单会被手机读成"没有活"，
    // 把"这台连接器不支持"说成了事实（契约 §4.3）。
    if (!available()) return failure('link/unsupported', 'this Host does not expose the jobs service')
    try {
      return { ok: true, value: sample() }
    } catch (error) {
      logger.warn?.(`mobile-link: jobRoster failed: ${messageOf(error)}`)
      return failure('link/failed', messageOf(error))
    }
  }

  function addDevice(deviceId) {
    if (typeof deviceId !== 'string' || deviceId.length === 0) return false
    if (devices.has(deviceId)) return false
    devices.add(deviceId)
    // 第一台设备连上才订阅：没人收的帧不值得算（契约 §3）。
    if (devices.size === 1) subscribe()
    return true
  }

  function removeDevice(deviceId) {
    if (!devices.delete(deviceId)) return false
    if (devices.size === 0) {
      // 最后一台设备走了：订阅与服务一起放掉，窗口里的变化也不留。
      releaseSubscription()
      pending.clear()
      if (timer !== undefined) {
        cancel(timer)
        timer = undefined
      }
    }
    return true
  }

  /** 进程收尾（`router.teardownAll`）：全部设备、订阅、定时器都不留。 */
  function releaseAll() {
    devices.clear()
    releaseSubscription()
    pending.clear()
    if (timer !== undefined) {
      cancel(timer)
      timer = undefined
    }
  }

  return {
    bindServices,
    handle,
    addDevice,
    removeDevice,
    releaseAll,
    dispose: releaseAll,
    get available() {
      return available()
    },
    get subscribed() {
      return unsubscribe !== undefined
    },
    get deviceCount() {
      return devices.size
    },
  }
}

export function isJobsMethod(method) {
  return method === ROSTER_METHOD
}

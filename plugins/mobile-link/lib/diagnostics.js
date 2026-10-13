/**
 * 一次接入的计时与有界耗时汇总（spec 020）。
 *
 * 职责（只做这三件，别的都不做）：
 *   1. **阶段计时**：一次设备接入走完「接入 → `_link/hello` → 首个数据请求 → 首个响应」各用了多少毫秒；
 *      没发生的阶段必须是 `null` 并在 `missing` 里列出——**不许记 0**（0 与"没发生"在判读时是两回事）。
 *   2. **慢请求**：单次请求超过阈值时产出一条 `request.slow`（方法名、耗时、字节数）。
 *   3. **有界汇总**：一次接入的 `requests / slow / maxMs / p50Ms / p95Ms / top3`，
 *      用**定长水库**估分位，数组长度不随请求数增长（否则"记日志"本身会变成新的性能问题）。
 *
 * 本模块是纯逻辑：它不认识 socket、不认识 journal，事件由上层通过 `onEvent` 注入
 * （宪法原则 VII.1：能力注入，不在内部读全局状态）。
 *
 * 契约：`specs/020-link-diagnostics/contracts/diagnostics-events.md`
 * 数据模型：`specs/020-link-diagnostics/data-model.md` §3–§5
 */

/** 水库样本容量：估 p50/p95 够用，且不随请求数增长。 */
export const RESERVOIR_SIZE = 256
/** 每累计这么多请求写一条汇总（加上断开时那条，构成"条数常数级"的上界）。 */
export const SUMMARY_EVERY = 200
/** `top3` 保留几条最慢的请求。 */
export const TOP_SLOWEST = 3

/** 阶段名（对外，出现在 `missing` 里）。 */
export const PHASES = Object.freeze({
  helloMs: 'hello',
  firstRequestMs: 'first-request',
  firstResponseMs: 'first-response',
})

/** 握手方法名（与 `hello.js` 同口径；这里只用来区分"握手"与"数据请求"）。 */
const HELLO_METHOD = '_link/hello'

/** 最近秩分位数：样本少的时候比插值更保守，也更容易在单测里核对。 */
function percentile(sorted, fraction) {
  if (sorted.length === 0) return 0
  const rank = Math.ceil(fraction * sorted.length)
  return sorted[Math.max(0, Math.min(sorted.length - 1, rank - 1))]
}

export class DeviceTimeline {
  /**
   * @param {object} [options]
   * @param {string} [options.deviceId]
   * @param {number} [options.slowRequestMs] 超过它才记 `request.slow`；0 表示关闭该逐条记录
   * @param {() => number} [options.now]
   * @param {(kind: string, detail: Record<string, unknown>) => void} [options.onEvent]
   */
  constructor({ deviceId, slowRequestMs = 2000, now = Date.now, onEvent = () => {} } = {}) {
    this.deviceId = deviceId
    this.slowRequestMs = Number(slowRequestMs) || 0
    this.now = now
    this.onEvent = onEvent
    this.attachedAt = now()
    this.helloAt = undefined
    this.firstRequestAt = undefined
    this.firstResponseAt = undefined
    this.requests = 0
    this.slow = 0
    this.maxMs = 0
    /** 定长水库：满了以后按步长覆盖（确定性的系统抽样，避免引入随机数让单测发抖）。 */
    this._samples = []
    this._sampleCursor = 0
    /** 最慢的若干条，长度恒 ≤ TOP_SLOWEST。 */
    this._top = []
    this._phaseEmitted = false
  }

  /** 收到 `_link/hello`（只在第一次生效）。 */
  noteHello(at = this.now()) {
    if (this.helloAt === undefined) this.helloAt = at
  }

  /**
   * 一次请求收尾。
   *
   * @param {{method: string, startedAt: number, ms: number, bytes: number}} request
   */
  noteRequest({ method, startedAt, ms, bytes }) {
    const isHello = method === HELLO_METHOD
    if (isHello) this.noteHello(startedAt)
    if (!isHello && this.firstRequestAt === undefined) this.firstRequestAt = startedAt
    // 只认**数据请求**的响应：握手响应不算。否则 `firstResponseMs` 会小于 `firstRequestMs`
    // （握手先回、数据请求后发），三段的阶梯就读不出来了。
    if (!isHello && this.firstResponseAt === undefined) this.firstResponseAt = startedAt + ms

    this.requests += 1
    this.maxMs = Math.max(this.maxMs, ms)
    this.#sample(ms)
    this.#keepTop({ method, ms, bytes })
    if (this.slowRequestMs > 0 && ms > this.slowRequestMs) {
      this.slow += 1
      // 字段叫 elapsedMs 而不是 ms：`ms` 是信封上的**时刻**，同名会把时刻冲掉（见 journal.js）。
      this.onEvent('request.slow', { deviceId: this.deviceId, method, elapsedMs: ms, bytes })
    }
    if (this.requests % SUMMARY_EVERY === 0) this.emitSummary()
    this.#maybeEmitPhase()
  }

  /** 阶段明细（`missing` 里的阶段名，其 `phases.*Ms` 必为 null）。 */
  phaseDetail() {
    const relative = (at) => (at === undefined ? null : at - this.attachedAt)
    const phases = {
      helloMs: relative(this.helloAt),
      firstRequestMs: relative(this.firstRequestAt),
      firstResponseMs: relative(this.firstResponseAt),
    }
    const missing = Object.entries(phases)
      .filter(([, value]) => value === null)
      .map(([key]) => PHASES[key])
    return { deviceId: this.deviceId, phases, missing }
  }

  /** 汇总明细（分位来自定长水库）。 */
  summaryDetail() {
    const sorted = [...this._samples].sort((a, b) => a - b)
    return {
      deviceId: this.deviceId,
      requests: this.requests,
      slow: this.slow,
      maxMs: this.maxMs,
      p50Ms: percentile(sorted, 0.5),
      p95Ms: percentile(sorted, 0.95),
      top3: this._top.map((entry) => ({ ...entry })),
    }
  }

  /** 断开时调用：补齐阶段事件（若还没写过）并在有请求时才写汇总。 */
  finish() {
    if (!this._phaseEmitted) {
      this._phaseEmitted = true
      this.onEvent('device.phase', this.phaseDetail())
    }
    if (this.requests > 0) this.emitSummary()
  }

  /** 写一条汇总（供断开与每 `SUMMARY_EVERY` 个请求两个时机调用）。 */
  emitSummary() {
    this.onEvent('device.summary', this.summaryDetail())
  }

  #sample(ms) {
    if (this._samples.length < RESERVOIR_SIZE) {
      this._samples.push(ms)
      return
    }
    const index = this._sampleCursor % RESERVOIR_SIZE
    this._samples[index] = ms
    this._sampleCursor += 1
  }

  #keepTop(entry) {
    this._top.push(entry)
    this._top.sort((a, b) => b.ms - a.ms)
    if (this._top.length > TOP_SLOWEST) this._top.length = TOP_SLOWEST
  }

  #maybeEmitPhase() {
    if (this._phaseEmitted) return
    // 三段**全齐**才写；缺哪一段就等 `finish()` 时按 missing 写（读者要知道"没发生"，而不是看到 0）。
    //
    // 为什么要求全齐而不是"有数据请求就写"：App 的真实顺序是**先探针（session/list）再握手**
    // （`ConnectionStore.connect()` 先 `sessions()`，再在 `install()` 里发 `_link/hello`）。
    // 按旧条件，阶段事件会在探针那一刻写出来、`missing: ['hello']`，于是最有用的
    // 「attach→hello 用了多久」在事件里永远是空的——2026-10-13 09:28 的中转运行实测到了这一条。
    if (this.helloAt === undefined) return
    if (this.firstRequestAt === undefined || this.firstResponseAt === undefined) return
    this._phaseEmitted = true
    this.onEvent('device.phase', this.phaseDetail())
  }
}

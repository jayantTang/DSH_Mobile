/**
 * 轮换统计：按天累计，落盘，重启不丢。
 *
 * 为什么必须落盘：这套东西是"事后回答'今天公司模型用了多少、哪把 key 被限流了、
 * 缓存命中多少'"的唯一依据。只在内存里计数的话，LaunchAgent 一重启（KeepAlive、
 * 开机、升级）数字就归零——而"哪把 key 什么时候被停用"恰恰是过几天才会被问到的事。
 *
 * 记的是**汇总**，不是每一次请求：一天的 byKey/byModel 加上少量"换线路"事件，
 * 既够回答问题，也不会把磁盘写成一个日志坟场。会话与 key 的对应关系不在这里，
 * 那属于粘性表（affinity.json）。
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

/** 保留天数：够看"这个月怎么样"，又不至于无限长。 */
export const DEFAULT_KEEP_DAYS = 90

function dayKey(at = Date.now()) {
  const date = new Date(at)
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}

function emptyDay() {
  return {
    requests: 0,
    failures: 0,
    retries: 0,
    failovers: 0,
    cacheHits: 0,
    /** 输出被 max_tokens 截断的次数（finish_reason=length）：这一项专门用来回答
     *  "用公司模型那次是不是又被截断了"——2026-09-24 就是它咬了我们一口。 */
    truncated: 0,
    promptTokens: 0,
    cachedTokens: 0,
    byKey: {},
    byModel: {},
    rotations: [],
  }
}

function bucket(map, name) {
  if (!map[name]) {
    map[name] = { requests: 0, failures: 0, rateLimited: 0, truncated: 0, promptTokens: 0, cachedTokens: 0 }
  }
  return map[name]
}

export class StatsStore {
  /**
   * @param {object} [options]
   * @param {string} [options.path] 落盘位置；省略则只在内存里活
   * @param {number} [options.keepDays]
   * @param {() => number} [options.now] 注入时钟（测试用）
   */
  constructor({ path, keepDays = DEFAULT_KEEP_DAYS, now = Date.now } = {}) {
    this.path = path
    this.keepDays = keepDays
    this.now = now
    /** @type {Record<string, ReturnType<typeof emptyDay>>} */
    this.days = {}
    this.dirty = false
    if (path) this.load()
  }

  load() {
    try {
      const raw = JSON.parse(readFileSync(this.path, 'utf8'))
      if (raw?.days && typeof raw.days === 'object') this.days = raw.days
    } catch {
      // 文件不在/坏了都从零开始：统计丢了不影响转发。
    }
  }

  save() {
    if (!this.path || !this.dirty) return
    try {
      mkdirSync(dirname(this.path), { recursive: true })
      const tmp = `${this.path}.tmp`
      writeFileSync(tmp, JSON.stringify({ version: 1, days: this.days }, null, 1), { mode: 0o600 })
      renameSync(tmp, this.path)
      this.dirty = false
    } catch {
      // 写不进去也只是这一次没记上。
    }
  }

  #today() {
    const key = dayKey(this.now())
    if (!this.days[key]) this.days[key] = emptyDay()
    return this.days[key]
  }

  /** 每 N 次写入落一次盘：转发路径上不做同步 I/O。 */
  #touch() {
    this.dirty = true
    this.writes = (this.writes ?? 0) + 1
    if (this.writes % 20 === 0) this.save()
  }

  /** 一次请求结束（无论成败）。 */
  noteRequest({ model, keyLabel, ok = true, promptTokens, cachedTokens } = {}) {
    const day = this.#today()
    day.requests += 1
    if (!ok) day.failures += 1
    if (typeof promptTokens === 'number') day.promptTokens += promptTokens
    if (typeof cachedTokens === 'number') day.cachedTokens += cachedTokens
    if (typeof cachedTokens === 'number' && cachedTokens > 0) day.cacheHits += 1
    if (model) {
      const modelBucket = bucket(day.byModel, model)
      modelBucket.requests += 1
      if (typeof cachedTokens === 'number') modelBucket.cachedTokens += cachedTokens
      if (typeof promptTokens === 'number') modelBucket.promptTokens += promptTokens
    }
    if (keyLabel) {
      const keyBucket = bucket(day.byKey, keyLabel)
      keyBucket.requests += 1
      if (!ok) keyBucket.failures += 1
      if (typeof cachedTokens === 'number') keyBucket.cachedTokens += cachedTokens
      if (typeof promptTokens === 'number') keyBucket.promptTokens += promptTokens
    }
    this.#touch()
  }

  /** 一次输出被截断（上游 finish_reason=length）。 */
  noteTruncation({ model, keyLabel, maxTokens } = {}) {
    const day = this.#today()
    day.truncated += 1
    if (model) bucket(day.byModel, model).truncated = (bucket(day.byModel, model).truncated ?? 0) + 1
    if (keyLabel) bucket(day.byKey, keyLabel).truncated = (bucket(day.byKey, keyLabel).truncated ?? 0) + 1
    day.rotations.push({ at: this.now(), kind: 'truncated', model, maxTokens, from: keyLabel })
    if (day.rotations.length > 500) day.rotations = day.rotations.slice(-500)
    this.#touch()
  }

  /** 一次重试 / 换线路。`reason` 取 router 给出的判定（rate-limited、key-dead…）。 */
  noteRotation({ from, to, reason, model, status } = {}) {
    const day = this.#today()
    day.retries += 1
    if (reason && reason !== 'transient-retry') day.failovers += 1
    if (from) {
      const keyBucket = bucket(day.byKey, from)
      if (reason === 'rate-limited') keyBucket.rateLimited += 1
    }
    day.rotations.push({ at: this.now(), from, to, reason, model, status })
    // 一天的换线路事件不该多到失控；超了只留最近的，避免统计文件被写爆。
    if (day.rotations.length > 500) day.rotations = day.rotations.slice(-500)
    this.#touch()
  }

  /** 回收过期的天。 */
  prune() {
    const cutoff = new Date(this.now() - this.keepDays * 86400_000)
    const limit = dayKey(cutoff.getTime())
    for (const key of Object.keys(this.days)) {
      if (key < limit) delete this.days[key]
    }
    this.dirty = true
  }

  /**
   * 给 `/stats` 与 CLI 的形状：最近 N 天（含今天）+ 汇总。
   * @param {number} [days]
   */
  snapshot(days = 7) {
    this.prune()
    const keys = Object.keys(this.days).sort().slice(-days)
    const totals = emptyDay()
    for (const key of keys) {
      const day = this.days[key]
      for (const field of ['requests', 'failures', 'retries', 'failovers', 'cacheHits', 'truncated', 'promptTokens', 'cachedTokens']) {
        totals[field] += day[field] ?? 0
      }
      for (const [name, value] of Object.entries(day.byKey ?? {})) {
        const into = bucket(totals.byKey, name)
        into.requests += value.requests ?? 0
        into.failures += value.failures ?? 0
        into.rateLimited += value.rateLimited ?? 0
        into.promptTokens += value.promptTokens ?? 0
        into.cachedTokens += value.cachedTokens ?? 0
      }
      for (const [name, value] of Object.entries(day.byModel ?? {})) {
        const into = bucket(totals.byModel, name)
        into.requests += value.requests ?? 0
        into.promptTokens += value.promptTokens ?? 0
        into.cachedTokens += value.cachedTokens ?? 0
      }
    }
    return {
      keepDays: this.keepDays,
      days: keys.map((key) => ({ day: key, ...this.days[key] })),
      totals,
    }
  }
}

export { dayKey }

/**
 * 链路与设备的生命周期流水。
 *
 * 为什么需要它（2026-10-12/13 那次"手机连不上"的教训）：连接器的日志走宿主
 * `ctx.logger`，而宿主既不落盘也不保留历史，于是"连接器为什么把这条中转链路拆了"
 * 只能靠中转侧日志反推——`lastError` 只留最后一条，中间发生过几次拆链、每次什么原因，
 * 事后一概查不到。这一族事件就是补这个洞。
 *
 * 两条出口，用途不同：
 *   * **内存环**（定长，默认 200 条）：随 `/mobile-link/status` 一起读，正在跑的时候看；
 *   * **JSONL 文件**（可选，默认写在身份文件旁边，超过上限滚动一次）：进程重启后还在，
 *     用于事后复盘——重连风暴的现场往往在重启之后就没了。
 *
 * 硬约束：**这里任何一步都不许抛**。它是诊断设施，不能因为磁盘满、权限错、
 * 路径怪就把链路带崩；写失败只记一条 `journal.error` 然后闭嘴。
 */

import { appendFileSync, mkdirSync, renameSync, statSync, unlinkSync } from 'node:fs'
import { dirname, join } from 'node:path'

import { defaultStatePath } from './state.js'

/** 内存环里保留多少条。 */
export const DEFAULT_LIMIT = 200
/** 单个 JSONL 文件的上限；超了就滚动成 `<path>.1`，所以磁盘占用上限约两倍。 */
export const DEFAULT_MAX_BYTES = 256 * 1024
/** 单条事件序列化后的上限；见 `#shrink` 的两步处理。 */
export const MAX_EVENT_BYTES = 2048

/**
 * 事件目录（`kind` 词表）——**与契约逐字一致**，由 `npm run check:contracts` 机械核对。
 *
 * 契约：`docs/diagnostics-events.md`（§2 既有 + §3 新增 + 内部）。
 * 为什么把词表放进代码：写入侧需要一个能自检的集合（防止手滑写错 kind 后没人发现），
 * 而插件是独立发布的包，不能运行时去读仓库里的 spec 文件。
 */
export const EVENT_KINDS = Object.freeze([
  // §2 既有（本次之前就有，语义不变）
  'link.start',
  'link.open',
  'link.close',
  'link.backoff',
  'link.failed',
  'link.unregistered',
  'link.stop',
  'watchdog.repull',
  'watchdog.drop',
  'dsh.ok',
  'dsh.unreachable',
  'device.attach',
  'device.reattach',
  'device.attach-again',
  'device.detach',
  'device.revoked',
  // §3 本次新增
  'device.phase',
  'request.slow',
  'device.summary',
  'app.dial',
  'app.hello',
  'app.first-request',
  'app.first-response',
  'app.request',
  'app.first-screen',
  'app.first-render',
  'app.scene',
  'app.push',
  // 内部：写失败与超大条目自报（不在契约的对外表里，但同属写入侧词表）
  'journal.error',
])

/** 信封字段：detail 里的同名键一律忽略（否则会把时刻/事件名冲掉）。 */
const PROTECTED_KEYS = new Set(['at', 'ms', 'kind'])

/** 单条事件里字符串值的最长保留长度（`#shrink` 用）。 */
const MAX_STRING_CHARS = 200


/** 默认落在身份文件旁边（`$DSH_HOME/mobile-link/`），测试用临时 DSH_HOME 时会自动隔离。 */
export function defaultJournalPath() {
  return join(dirname(defaultStatePath()), 'link-events.jsonl')
}

/**
 * 把一条事件序列化成一行 JSON。
 *
 * 同时给 `at`（给人看的 ISO 8601）与 `ms`（给脚本比对的整数），因为这两种读者都存在：
 * 人 grep 时想直接看到时刻，脚本算间隔时不想解析日期。
 */
function toLine(entry) {
  try {
    return `${JSON.stringify(entry)}\n`
  } catch {
    // 循环引用之类的 detail 不该让整条事件丢掉：退化成只留 kind。
    return `${JSON.stringify({ at: entry.at, ms: entry.ms, kind: entry.kind })}\n`
  }
}

export class LinkJournal {
  /**
   * @param {object} [options]
   * @param {string} [options.path] JSONL 路径；不传＝只留内存，不碰磁盘
   * @param {number} [options.limit] 内存环容量
   * @param {number} [options.maxBytes] 单个文件上限
   * @param {() => number} [options.now] 取时刻（测试注入）
   * @param {{ debug?: (message: string) => void }} [options.logger]
   */
  constructor({
    path, limit = DEFAULT_LIMIT, maxBytes = DEFAULT_MAX_BYTES,
    now = Date.now, logger,
  } = {}) {
    this._path = typeof path === 'string' && path.trim() ? path : undefined
    this.maxBytes = Math.max(1024, Number(maxBytes) || DEFAULT_MAX_BYTES)
    this.limit = Math.max(1, Number(limit) || DEFAULT_LIMIT)
    this.now = now
    this.logger = logger
    /** @type {Array<Record<string, unknown>>} */
    this._entries = []
    /** 因为环满而被挤掉的条数：读写两侧都不是无损的，得让读者知道。 */
    this.dropped = 0
    /** 落盘写坏了几次（第一次就停手，避免刷屏）。 */
    this.fileErrors = 0
    this._bytes = undefined
    this._fileBroken = false
    /** 写入过的总条数（含被挤掉的）。 */
    this.recorded = 0
  }

  /** 落盘路径；`null` 表示这份流水只在内存里。 */
  get path() {
    return this._path ?? null
  }

  /**
   * 记一条。**永不抛**。
   *
   * @param {string} kind 事件名（`link.open` / `device.detach` …），未知取值允许写入
   *   （老读者必须忽略不认识的 kind），但单测会盯住目录漂移
   * @param {Record<string, unknown>} [detail] 该事件自带的字段（`undefined` 一律丢弃）
   * @returns {Record<string, unknown>} 写进去的那条（测试要断言，所以返回）
   */
  record(kind, detail) {
    const entry = this.#build(kind, detail)
    const line = toLine(entry)
    // 两条分支必须返回同一形状：小的直接过，大的走两步降级。
    const sized = Buffer.byteLength(line) <= MAX_EVENT_BYTES ? { entry, line } : this.#shrink(entry)
    this.#push(sized.entry)
    this.#append(sized.line)
    return sized.entry
  }

  /**
   * 组装条目：信封 + 过滤掉 `undefined` 的 detail。
   *
   * **信封字段受保护**：`at`/`ms`/`kind` 不会被 detail 覆盖。这条是 2026-10-13 踩出来的——
   * 当时 `request.slow`/`app.hello` 的 detail 里也有一个 `ms`（含义是**耗时**），
   * 摊平后把事件的**时刻**冲掉了，时间线上那条事件会跑到 1970 年。耗时一律叫 `elapsedMs`。
   */
  #build(kind, detail) {
    const ms = this.now()
    const entry = { at: new Date(ms).toISOString(), ms, kind }
    if (detail && typeof detail === 'object') {
      for (const [key, value] of Object.entries(detail)) {
        if (value === undefined || PROTECTED_KEYS.has(key)) continue
        entry[key] = value
      }
    }
    return entry
  }

  /**
   * 记一条**别人钟上**的事件（App 推上来的那些）：时刻用给定的值，不用本机时钟。
   *
   * 单独一个入口而不是"让 detail 覆盖 ms"：覆盖是隐式的，谁都能不小心改掉时刻；
   * 这里只有显式调用才会保留外部时刻。
   */
  recordForeign(kind, { at, ms, ...detail } = {}) {
    const stamp = Number.isFinite(ms) ? ms : this.now()
    const entry = { at: typeof at === 'string' && at ? at : new Date(stamp).toISOString(), ms: stamp, kind }
    for (const [key, value] of Object.entries(detail)) {
      if (value === undefined || PROTECTED_KEYS.has(key)) continue
      entry[key] = value
    }
    const line = toLine(entry)
    const sized = Buffer.byteLength(line) <= MAX_EVENT_BYTES ? { entry, line } : this.#shrink(entry)
    this.#push(sized.entry)
    this.#append(sized.line)
    return sized.entry
  }

  /** 记进内存环（磁盘那半由 `record` 负责）。 */
  #push(entry) {
    this._entries.push(entry)
    this.recorded += 1
    while (this._entries.length > this.limit) {
      this._entries.shift()
      this.dropped += 1
    }
  }

  /**
   * 超大条目的两步降级：先把长字符串截短（保住这一条），仍超限则丢掉它并自报一条 `journal.error`。
   *
   * 为什么不在写入侧直接抛/直接丢：诊断设施最怕"因为自己太胖把现场弄没了"。
   * 截断会留 `truncated: true`，读者知道这条不完整；真的截不动（例如深嵌套对象）才丢，且丢也要留痕。
   */
  #shrink(entry) {
    const shortened = { ...entry }
    for (const [key, value] of Object.entries(shortened)) {
      if (typeof value === 'string' && value.length > MAX_STRING_CHARS) {
        shortened[key] = `${value.slice(0, MAX_STRING_CHARS)}…`
      }
    }
    shortened.truncated = true
    const line = toLine(shortened)
    if (Buffer.byteLength(line) <= MAX_EVENT_BYTES) return { entry: shortened, line }
    const fallback = this.#build('journal.error', {
      // 字段名不能叫 `kind`：`#build` 会把 detail 的键盖到信封上，那样这条自报就冒充成原事件了。
      originalKind: entry.kind,
      bytes: Buffer.byteLength(toLine(entry)),
      reason: 'event too large even after truncation',
    })
    return { entry: fallback, line: toLine(fallback) }
  }

  /** 最近的 `count` 条，最旧在前。 */
  recent(count = this.limit) {
    const size = Math.max(0, Number(count) || 0)
    return this._entries.slice(Math.max(0, this._entries.length - size))
  }

  /** 内存环里现有的全部条目（副本）。 */
  entries() {
    return this._entries.slice()
  }

  #append(line) {
    if (!this._path || this._fileBroken) return
    try {
      if (this._bytes === undefined) {
        mkdirSync(dirname(this._path), { recursive: true, mode: 0o700 })
        this._bytes = this.#sizeOf(this._path)
      }
      const bytes = Buffer.byteLength(line)
      if (this._bytes > 0 && this._bytes + bytes > this.maxBytes) this.#rotate()
      appendFileSync(this._path, line, { mode: 0o600 })
      this._bytes += bytes
    } catch (error) {
      this.fileErrors += 1
      this._fileBroken = true
      this.logger?.debug?.(`mobile-link: link journal disabled (${error?.message ?? error})`)
    }
  }

  #sizeOf(path) {
    try {
      return statSync(path).size
    } catch {
      return 0
    }
  }

  /** 滚一次：现文件改名成 `<path>.1`，旧的那份直接丢掉（只保两代）。 */
  #rotate() {
    const archived = `${this._path}.1`
    try {
      renameSync(this._path, archived)
    } catch {
      // Windows 上改名到已存在的目标会失败；删掉目标再试一次。
      try {
        unlinkSync(archived)
        renameSync(this._path, archived)
      } catch (error) {
        throw error
      }
    }
    this._bytes = 0
  }
}

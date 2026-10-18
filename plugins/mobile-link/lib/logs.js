/**
 * 设备日志落盘（`_link/logs`）。
 *
 * 与 `journal.js` 的分工：journal 记的是**连接器自己**的生命周期事件（几百条、可以随手丢），
 * 这里记的是**手机端**产生的日志行（量级大、需要按时间窗回看）。两者共用"诊断设施不许抛"
 * 这条硬约束，但容量与保留期完全不同。
 *
 * 保留期 **7 天**，清理不靠定时器、也不新增任何进程：每次 `append` 顺手做一次，
 * 且 60 秒内最多一次。理由是不引入定时任务就不会有"任务没跑起来、盘悄悄满了"这种状态。
 *
 * 目录布局：`<root>/<deviceId>/<YYYYMMDD>.jsonl`。按天分文件有三个好处：
 * 清理只需 unlink 整个文件，不必重写；`tail` 只需盯当天的文件；超限时按天淘汰。
 */

import { appendFileSync, mkdirSync, readdirSync, rmSync, statSync, unlinkSync } from 'node:fs'
import { dirname, join } from 'node:path'

import { defaultStatePath } from './state.js'

/** 日志保留期：7 天。 */
export const DEFAULT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000
/** 单台设备磁盘上限；超了按天淘汰最旧的。 */
export const DEFAULT_MAX_DEVICE_BYTES = 200 * 1024 * 1024
/** 单条日志正文上限；超长截断而不是丢弃（截断仍能看出是哪一行）。 */
export const MAX_TEXT_CHARS = 4000
/** 每批最多收多少条、多少字节；超了如实报 `accepted`，剩下的由手机下次推。 */
export const MAX_BATCH_ENTRIES = 500
export const MAX_BATCH_BYTES = 64 * 1024
/** 清理的最小间隔：清理一次最多 60 秒一次。 */
const PRUNE_INTERVAL_MS = 60 * 1000

/** 默认落在身份文件旁边：`$DSH_HOME/mobile-link/logs`。测试用临时 DSH_HOME 自动隔离。 */
export function defaultLogsRoot() {
  return join(dirname(defaultStatePath()), 'logs')
}

/** 本地日 `YYYYMMDD`，与 journal 的 `local_day` 口径一致。 */
export function dayStamp(ms) {
  const date = new Date(ms)
  const pad = (value) => String(value).padStart(2, '0')
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}`
}

/** 设备 id 会直接进路径：只留安全字符，避免 `../` 之类的路径穿越。 */
export function safeDeviceId(deviceId) {
  const text = String(deviceId ?? '').trim()
  if (!text) return 'unknown'
  return text.replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 120)
}

/** 一条上报 → 一行落盘 JSON；非法条目返回 null（调用方计入拒收）。 */
export function normalizeEntry(raw) {
  if (!raw || typeof raw !== 'object') return null
  const ms = Number(raw.ms)
  const text = typeof raw.text === 'string' ? raw.text : ''
  if (!Number.isFinite(ms) || !text) return null
  const seq = Number(raw.seq)
  return {
    seq: Number.isFinite(seq) ? seq : undefined,
    ms,
    at: typeof raw.at === 'string' && raw.at ? raw.at : new Date(ms).toISOString(),
    level: typeof raw.level === 'string' ? raw.level.slice(0, 16) : 'info',
    source: typeof raw.source === 'string' ? raw.source.slice(0, 32) : 'app',
    text: text.slice(0, MAX_TEXT_CHARS),
  }
}

export class LogSpool {
  /**
   * @param {object} [options]
   * @param {string} [options.root] 目录（默认 `$DSH_HOME/mobile-link/logs`）
   * @param {number} [options.retentionMs] 保留期
   * @param {number} [options.maxDeviceBytes] 单设备上限
   * @param {() => number} [options.now]
   * @param {{ debug?: (message: string) => void }} [options.logger]
   */
  constructor({
    root, retentionMs = DEFAULT_RETENTION_MS, maxDeviceBytes = DEFAULT_MAX_DEVICE_BYTES,
    now = Date.now, logger,
  } = {}) {
    this.root = typeof root === 'string' && root.trim() ? root : defaultLogsRoot()
    this.retentionMs = Math.max(60_000, Number(retentionMs) || DEFAULT_RETENTION_MS)
    this.maxDeviceBytes = Math.max(1024, Number(maxDeviceBytes) || DEFAULT_MAX_DEVICE_BYTES)
    this.now = now
    this.logger = logger
    /** 每台设备已接受的最高序号（幂等：同批重推不会写两遍）。 */
    this.watermarks = new Map()
    this._lastPruneAt = 0
  }

  /** 一台设备当天的文件路径。 */
  pathFor(deviceId, ms = this.now()) {
    return join(this.root, safeDeviceId(deviceId), `${dayStamp(ms)}.jsonl`)
  }

  /**
   * 收一批并落盘。
   *
   * @returns {{accepted: number, lastSeq: number, dropped: number}}
   *   `accepted` 是真正写下去的条数；被水位挡掉的重复条目不计入。
   */
  append(deviceId, entries, { full = false } = {}) {
    const result = { accepted: 0, lastSeq: this.watermarks.get(deviceId) ?? 0, dropped: 0 }
    if (!Array.isArray(entries) || entries.length === 0) return result
    let bytes = 0
    const byDay = new Map()
    for (const raw of entries) {
      const entry = normalizeEntry(raw)
      if (!entry) { result.dropped += 1; continue }
      const seq = Number(entry.seq)
      const watermark = this.watermarks.get(deviceId) ?? 0
      // `full` 是"整段重推"（App 冷启动回填或 `dsh://diag export`）：
      // 水位不参与判断，但仍然照常推进，避免之后的增量重复。
      if (!full && Number.isFinite(seq) && seq <= watermark) continue
      const line = `${JSON.stringify({ ...entry, deviceId, full: full || undefined })}\n`
      if (result.accepted > 0 && bytes + line.length > MAX_BATCH_BYTES) break
      if (result.accepted >= MAX_BATCH_ENTRIES) break
      const day = dayStamp(entry.ms)
      const bucket = byDay.get(day) ?? []
      bucket.push(line)
      byDay.set(day, bucket)
      bytes += line.length
      result.accepted += 1
      result.lastSeq = Math.max(result.lastSeq, Number.isFinite(seq) ? seq : result.lastSeq)
    }
    if (!byDay.size) return result
    for (const [day, lines] of byDay) this.#write(deviceId, day, lines)
    this.watermarks.set(deviceId, result.lastSeq)
    this.#pruneIfDue()
    return result
  }

  #write(deviceId, day, lines) {
    const path = join(this.root, safeDeviceId(deviceId), `${day}.jsonl`)
    try {
      mkdirSync(dirname(path), { recursive: true })
      appendFileSync(path, lines.join(''))
    } catch (error) {
      // 诊断设施不许把链路带崩：写不进去就只报一声。
      this.logger?.debug?.(`mobile-link: logs spool write failed (${error?.message ?? error})`)
    }
  }

  /** 60 秒内最多清理一次；清理本身不许抛。 */
  #pruneIfDue() {
    const now = this.now()
    if (now - this._lastPruneAt < PRUNE_INTERVAL_MS) return
    this._lastPruneAt = now
    try {
      this.prune(now)
    } catch (error) {
      this.logger?.debug?.(`mobile-link: logs prune failed (${error?.message ?? error})`)
    }
  }

  /**
   * 清理：先按保留期删整天文件，再按单设备上限删最旧的。
   * 返回删掉的字节数（测试用；生产只看副作用）。
   */
  prune(now = this.now()) {
    let freed = 0
    let devices = []
    try {
      devices = readdirSync(this.root, { withFileTypes: true }).filter((item) => item.isDirectory())
    } catch {
      return 0
    }
    for (const device of devices) {
      const dir = join(this.root, device.name)
      let files = []
      try {
        files = readdirSync(dir).filter((name) => name.endsWith('.jsonl'))
      } catch {
        continue
      }
      if (!files.length) {
        try { rmSync(dir, { recursive: true, force: true }) } catch { /* 目录删不掉无所谓 */ }
        continue
      }
      const stats = []
      for (const name of files.sort()) {
        const path = join(dir, name)
        try {
          const info = statSync(path)
          stats.push({ path, day: name.slice(0, 8), size: info.size, mtimeMs: info.mtimeMs })
        } catch { /* 文件刚被删掉 */ }
      }
      // 保留期按**文件名里的日**判定，不看 mtime：mtime 会被备份、拷贝、恢复改动，
      // 而"这是哪一天的日志"只写在名字里，判定必须与名字一致。
      const cutoff = dayStamp(now - this.retentionMs)
      for (const file of stats) {
        if (file.day >= cutoff) continue
        freed += this.#unlink(file)
      }
      let kept = stats.filter((file) => file.day >= cutoff)
      let total = kept.reduce((sum, file) => sum + file.size, 0)
      for (const file of kept) {
        if (total <= this.maxDeviceBytes) break
        total -= file.size
        freed += this.#unlink(file)
      }
    }
    return freed
  }

  #unlink(file) {
    try {
      unlinkSync(file.path)
      return file.size
    } catch {
      return 0
    }
  }

  /** 某台设备（或全部）的磁盘占用，给人看的。 */
  usage() {
    const rows = []
    let devices = []
    try {
      devices = readdirSync(this.root, { withFileTypes: true }).filter((item) => item.isDirectory())
    } catch {
      return rows
    }
    for (const device of devices) {
      const dir = join(this.root, device.name)
      let bytes = 0
      let files = 0
      let newest = 0
      try {
        for (const name of readdirSync(dir)) {
          if (!name.endsWith('.jsonl')) continue
          const info = statSync(join(dir, name))
          bytes += info.size
          files += 1
          newest = Math.max(newest, info.mtimeMs)
        }
      } catch { /* 忽略单台设备的读失败 */ }
      rows.push({ deviceId: device.name, bytes, files, newestMs: newest })
    }
    return rows.sort((a, b) => b.bytes - a.bytes)
  }
}

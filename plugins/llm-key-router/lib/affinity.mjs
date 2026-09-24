/**
 * 会话 → key 的粘性表。
 *
 * 这张表是"多把 key 与缓存效率"之间唯一的耦合点，所以它必须：
 *
 * - **按会话而不是按请求**记（同一个会话的每一轮都落回同一把 key）；
 * - **落在磁盘上**（进程重启、电脑重启之后不乱换：一次乱换 = 整个会话的前缀
 *   在上游重新算一遍，长会话就是几十秒与一笔不该花的输入费）；
 * - **会过期**（一个 24 小时没动静的会话，再回来时它的上游缓存早没了，这时重新
 *   分配反而能把空闲的 key 摊开）。
 *
 * 会话身份优先取上游网关头（pi-ai 的 `compat.sendSessionAffinityHeaders` 会把
 * DSH 的 sessionId 发成 `session_id` / `x-session-affinity` / `x-client-request-id`）；
 * 都没有时退回"前缀指纹"，见 `fingerprint.mjs`。
 */
import { readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

/** 默认 24 小时：足够长到"今天接着聊"仍然命中，也足够短到不把 key 永久钉死。 */
export const DEFAULT_TTL_MS = 24 * 60 * 60 * 1000

export class AffinityTable {
  /**
   * @param {object} [options]
   * @param {string} [options.path] 持久化文件；省略则只在内存里活
   * @param {number} [options.ttlMs]
   * @param {() => number} [options.now] 注入时钟，测试用
   */
  constructor({ path, ttlMs = DEFAULT_TTL_MS, now = Date.now } = {}) {
    this.path = path
    this.ttlMs = ttlMs
    this.now = now
    /** @type {Map<string, {label: string, at: number}>} */
    this.entries = new Map()
    /** 迁移与新建的次数，用来判断"分摊"有没有真的发生。 */
    this.stats = { hits: 0, assigned: 0, migrated: 0, expired: 0 }
    if (path) this.load()
  }

  load() {
    try {
      const raw = JSON.parse(readFileSync(this.path, 'utf8'))
      const entries = raw?.entries ?? {}
      for (const [session, value] of Object.entries(entries)) {
        if (typeof value?.label === 'string' && typeof value?.at === 'number') {
          this.entries.set(session, { label: value.label, at: value.at })
        }
      }
    } catch {
      // 没有文件 / 文件坏了都从空表开始：粘性表丢了只会多一次冷启动，不该拦住服务。
    }
  }

  save() {
    if (!this.path) return
    try {
      mkdirSync(dirname(this.path), { recursive: true })
      const tmp = `${this.path}.tmp`
      writeFileSync(tmp, JSON.stringify({
        version: 1,
        entries: Object.fromEntries(this.entries),
      }, null, 1), { mode: 0o600 })
      renameSync(tmp, this.path)
    } catch {
      // 写不进去也不能影响转发：下一次请求照样能工作，只是重启后要重新摊销。
    }
  }

  /** 该会话现在认的是哪个 label（过期即忘）。 */
  labelFor(session) {
    const entry = this.entries.get(session)
    if (!entry) return null
    if (this.now() - entry.at > this.ttlMs) {
      this.entries.delete(session)
      this.stats.expired += 1
      return null
    }
    return entry.label
  }

  remember(session, label) {
    this.entries.set(session, { label, at: this.now() })
  }

  /** 记一次"命中已有粘性"。 */
  noteHit(session) {
    const entry = this.entries.get(session)
    if (entry) entry.at = this.now()
    this.stats.hits += 1
  }

  /** 记一次新分配（新会话，或粘性过期后重新分配）。 */
  noteAssigned(session, label) {
    this.remember(session, label)
    this.stats.assigned += 1
  }

  /** 记一次迁移（原来那把 key 不能用了）。 */
  noteMigrated(session, label) {
    this.remember(session, label)
    this.stats.migrated += 1
  }

  forget(session) {
    this.entries.delete(session)
  }

  get size() { return this.entries.size }
}

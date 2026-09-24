/**
 * 选键与换键的决策层（不含 HTTP，方便单测）。
 *
 * 一次请求的完整决策：
 *   1. 会话有粘性且那把 key 可用 → 用它（这是"缓存最佳"的全部秘密）；
 *   2. 会话没有粘性 → 从健康 key 里轮转一把，记下粘性；
 *   3. 上游答复不可用 → 按性质处置：判死/冷却/原地重试；
 *   4. 换 key 只发生在**还没往客户端写过任何字节**的时候（见 `proxy.mjs`），
 *      这样重试对客户端与手机端完全不可见。
 */
import { AffinityTable } from './affinity.mjs'
import { KeyPool, KeyState } from './keys.mjs'

export class KeyRouter {
  /**
   * @param {object} options
   * @param {KeyPool} options.pool
   * @param {AffinityTable} [options.affinity]
   * @param {number} [options.cooldownSeconds] 429 时该 key 冷却多久（没有 Retry-After 的话）
   * @param {number} [options.maxAttempts] 一次请求最多换几把 key
   */
  constructor({ pool, affinity = new AffinityTable(), cooldownSeconds = 60, maxAttempts = 3 }) {
    this.pool = pool
    this.affinity = affinity
    this.cooldownSeconds = cooldownSeconds
    this.maxAttempts = maxAttempts
  }

  /**
   * 为一次尝试挑 key。
   *
   * @param {string} session 会话身份
   * @param {object} [options]
   * @param {Set<string>} [options.tried] 本次请求已经试过的 key label（换键时不再回头）
   * @returns {{key: import('./keys.mjs').Key, reason: string}|null}
   */
  pick(session, { tried = new Set() } = {}) {
    const stickyLabel = this.affinity.labelFor(session)
    if (stickyLabel && !tried.has(stickyLabel)) {
      const sticky = this.pool.byLabel(stickyLabel)
      if (sticky?.isAvailable()) {
        this.affinity.noteHit(session)
        return { key: sticky, reason: 'sticky' }
      }
      // 粘着的那把不在了：按轮转挑下一把，并记为一次迁移。
      const replacement = this.pool.next({ exclude: tried })
      if (!replacement) return null
      this.affinity.noteMigrated(session, replacement.label)
      return { key: replacement, reason: 'migrated' }
    }

    const candidate = this.pool.next({ exclude: tried })
    if (!candidate) return null
    if (stickyLabel) this.affinity.noteMigrated(session, candidate.label)
    else this.affinity.noteAssigned(session, candidate.label)
    return { key: candidate, reason: stickyLabel ? 'migrated' : 'assigned' }
  }

  /**
   * 上游答复回来之后：更新 key 状态，并告诉调用方要不要换一把重试。
   *
   * @param {object} args
   * @param {import('./keys.mjs').Key} args.key
   * @param {number} args.status HTTP 状态码（网络错误传 0）
   * @param {string} [args.body] 响应的开头片段（用来识别 QUOTA / balance 这类文案）
   * @param {string} [args.retryAfter] 上游给的 Retry-After（秒）
   * @param {number} [args.attempt] 这是第几次尝试（从 1 开始）
   * @param {string} args.session
   * @returns {{retry: boolean, reason: string}}
   */
  noteResult({ key, status, body = '', retryAfter, attempt = 1, session }) {
    key.noteFailure(`HTTP ${status}`)
    const verdict = this.pool.classify(status, body)

    if (verdict === 'dead') {
      key.kill(body.slice(0, 120) || `HTTP ${status}`)
      this.affinity.forget(session)
      return { retry: attempt < this.maxAttempts, reason: 'key-dead' }
    }

    if (verdict === 'rate-limit') {
      const seconds = Number.isFinite(Number(retryAfter)) && Number(retryAfter) > 0
        ? Number(retryAfter)
        : this.cooldownSeconds
      key.cool(seconds, body.slice(0, 120) || `HTTP ${status}`)
      this.affinity.forget(session)
      return { retry: attempt < this.maxAttempts, reason: 'rate-limited' }
    }

    if (verdict === 'transient') {
      // 上游抖动：先在同一把 key 上再试一次（不丢粘性），再失败才换。
      if (attempt === 1) return { retry: attempt < this.maxAttempts, reason: 'transient-retry' }
      this.affinity.forget(session)
      return { retry: attempt < this.maxAttempts, reason: 'transient-migrate' }
    }

    // 其它 4xx（请求本身有问题：模型名不对、参数非法）：换 key 也救不了。
    return { retry: false, reason: 'client-error' }
  }

  snapshot() {
    return {
      pool: this.pool.snapshot(),
      affinity: { sessions: this.affinity.size, ...this.affinity.stats },
      policy: {
        cooldownSeconds: this.cooldownSeconds,
        maxAttempts: this.maxAttempts,
        affinityTtlHours: Math.round(this.affinity.ttlMs / 3600000),
      },
    }
  }
}

export { KeyPool, KeyState }

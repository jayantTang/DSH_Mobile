/**
 * 一把上游 key 的状态。
 *
 * 为什么要有"冷却"这一态，而不是简单的"好/坏"：限流（429）与配额用尽（QUOTA）
 * 是会自己好的——把它们当死键会浪费一整把 key；把它们当好键又会一直撞墙。
 * 冷却期结束自动回到池子里，判死只留给 401/403 这种"再试也没用"的答复。
 */

/** 一把 key 的瞬时状态：healthy / cooling / dead。 */
export const KeyState = {
  healthy: 'healthy',
  cooling: 'cooling',
  dead: 'dead',
}

export class Key {
  /**
   * @param {string} secret 上游 key 本身，只在内存与日志标签间流转，从不回给客户端
   * @param {object} [options]
   * @param {string} [options.label] 日志与统计里显示的名字（默认取 key 的前 8 位）
   * @param {() => number} [options.now] 注入时钟（测试冷却与过期用）
   */
  constructor(secret, { label, now = Date.now } = {}) {
    this.secret = secret
    this.label = label ?? `${secret.slice(0, 8)}…`
    this.now = now
    this.state = KeyState.healthy
    this.cooldownUntil = 0
    this.requests = 0
    this.failures = 0
    this.rateLimited = 0
    this.lastError = null
    this.lastUsedAt = 0
    this.cachedTokens = 0
    this.promptTokens = 0
  }

  /** 现在能不能用（冷却到点的 key 自动转回 healthy）。 */
  isAvailable(now = this.now()) {
    if (this.state === KeyState.dead) return false
    if (this.state === KeyState.cooling) {
      if (now < this.cooldownUntil) return false
      this.state = KeyState.healthy
    }
    return true
  }

  /** 429 / 配额：进冷却，到点自己回来。 */
  cool(seconds, reason) {
    this.state = KeyState.cooling
    this.cooldownUntil = this.now() + Math.max(1, seconds) * 1000
    this.rateLimited += 1
    this.lastError = reason ?? 'rate limited'
  }

  /** 401/403：这把 key 不再参与轮换，直到有人把它救回来。 */
  kill(reason) {
    this.state = KeyState.dead
    this.lastError = reason ?? 'forbidden'
  }

  revive() {
    this.state = KeyState.healthy
    this.cooldownUntil = 0
    this.lastError = null
  }

  noteRequest() {
    this.requests += 1
    this.lastUsedAt = this.now()
  }

  noteFailure(reason) {
    this.failures += 1
    this.lastError = reason
  }

  noteUsage({ promptTokens, cachedTokens } = {}) {
    if (typeof promptTokens === 'number') this.promptTokens += promptTokens
    if (typeof cachedTokens === 'number') this.cachedTokens += cachedTokens
  }

  /** 给 `/stats` 与日志看的形状：绝不含 key 正文。 */
  snapshot() {
    return {
      label: this.label,
      state: this.state,
      requests: this.requests,
      failures: this.failures,
      rateLimited: this.rateLimited,
      cachedTokens: this.cachedTokens,
      promptTokens: this.promptTokens,
      lastError: this.lastError,
      cooldownSeconds: this.state === KeyState.cooling
        ? Math.max(0, Math.round((this.cooldownUntil - this.now()) / 1000))
        : 0,
    }
  }
}

/**
 * 上游 key 池。
 *
 * 选键规则只有两条，其余都是这两条的后果：
 *   1. **一个会话认准一把 key**（会话粘性，见 `affinity.mjs`）；
 *   2. **没有粘性时才摊开**——新会话按轮转分摊到健康 key 上，而不是全压第一把。
 * 之所以敢摊开：粘性保证了"同一个会话不会因为换 key 而重算前缀"，摊开只影响
 * 新会话，而新会话本来就没有可复用的前缀。
 */
export class KeyPool {
  /**
   * @param {Array<{secret: string, label?: string}>} entries
   * @param {object} [options]
   * @param {() => number} [options.now] 注入时钟（测试冷却用）
   */
  constructor(entries = [], { now = Date.now } = {}) {
    this.now = now
    this.keys = entries.map((entry) => new Key(entry.secret, { ...entry, now }))
    this.cursor = 0
  }

  get size() { return this.keys.length }

  available(now = this.now()) {
    return this.keys.filter((key) => key.isAvailable(now))
  }

  /**
   * 挑一把可用的 key：从游标处轮转，`exclude` 里的（本次请求已经试过的）跳过。
   *
   * 轮转而不是"最少使用"：少一次计数比较，且分摊得均匀；同一个会话的下一次请求
   * 会走粘性表，不会再碰这里——所以"新会话摊开"与"同会话钉死"互不干扰。
   */
  next({ exclude = new Set() } = {}) {
    for (let step = 0; step < this.keys.length; step += 1) {
      const candidate = this.keys[(this.cursor + step) % this.keys.length]
      if (exclude.has(candidate.label)) continue
      if (candidate.isAvailable()) {
        this.cursor = (this.cursor + step + 1) % this.keys.length
        return candidate
      }
    }
    return this.available().find((key) => !exclude.has(key.label)) ?? null
  }

  byLabel(label) {
    return this.keys.find((key) => key.label === label)
  }

  /**
   * 把上游的答复翻译成 key 的处置。
   *
   * 分类的依据是"再试一次会不会有用"，而不是状态码本身好不好看：
   * - 401/403 → 判死（key 被停用，重试无意义）；
   * - 429 / QUOTA → 冷却（会自己好，且冷却期该把流量让给别人）；
   * - 5xx / 网络错 → 不改状态（可能是上游抖动，先在原地重试）。
   */
  classify(status, body = '') {
    if (status === 401 || status === 403) return 'dead'
    if (status === 429) return 'rate-limit'
    const text = String(body).toLowerCase()
    if (text.includes('quota') || text.includes('insufficient') || text.includes('balance')) return 'rate-limit'
    if (status >= 500) return 'transient'
    return 'ok'
  }

  snapshot() {
    return {
      size: this.size,
      healthy: this.available().length,
      keys: this.keys.map((key) => key.snapshot()),
    }
  }
}

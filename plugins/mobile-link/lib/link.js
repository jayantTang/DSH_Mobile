/**
 * The DLP agent transport: identity, the relay socket, heartbeats, reconnect.
 * Device-level routing lives in `router.js`; this file owns every socket and
 * timer. Spec: docs/RELAY-PROTOCOL.md §4.
 */

import { EventEmitter } from 'node:events'

import { DshClient } from './dsh-client.js'
import { agentEndpoint, decodeFrame, encodeFrame, nextBackoff, normalizeRelayUrl, pongFor } from './dlp.js'

/**
 * 进程级登记表：**同一个进程里只允许有一条到中转的 agent 连接**。
 *
 * 为什么需要它：插件热更会重新求值模块、再建一个 Link，而旧的实例还占着那条连接
 * （中转只认一个 agent 会话）。新实例于是连不上、手机那侧"连上了却没有链路"。
 * 2026-10-09 00:00–00:42 真机连不上就是这个：连接器 43 分钟没回来。
 * 挂在 `globalThis` 上是因为模块重载会把模块作用域清掉，只有进程级才留得住。
 */
const LIVE_AGENT = Symbol.for('dsh.mobile-link.live-agent')
import { enrollAgent, enrollCommand, inviteFrom } from './enroll.js'
import { handoffFromEndpoint, writeHandoff } from './handoff.js'
import { LinkJournal, defaultJournalPath } from './journal.js'
import { statusSnapshot } from './status.js'
import { mintPairCode, regeneratePairCode } from './pairing.js'
import {
  DEFAULT_EVENTS_BACKLOG, DEFAULT_SLOW_REQUEST_MS,
  EVENTS_ENDPOINT, EVENTS_RESULT, DeviceRouter, messageOf,
} from './router.js'
import { SERVER_VERSION, SERVER_CAPABILITIES, hostVersion } from './hello.js'
import { createJobsRoster } from './jobs-roster.js'
import { MissingIdentity, resolveIdentity } from './state.js'
import { connect as wsConnect } from './ws.js'

const PROTOCOL_VERSION = 1


function sleep(ms, signal) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms)
    timer.unref?.()
    signal?.addEventListener?.('abort', () => {
      clearTimeout(timer)
      resolve()
    }, { once: true })
  })
}

/** Read a positive number from the environment; anything else falls back. */
function numberFromEnv(raw, fallback) {
  if (raw === undefined || raw === null || String(raw).trim() === '') return fallback
  const value = Number(raw)
  return Number.isFinite(value) && value >= 0 ? value : fallback
}

export class MobileLinkAgent extends EventEmitter {
  constructor({
    relayUrl, agentId, agentSecret, agentName, stateFile, dshUrl,
    logger = console, heartbeatMs = 20000, pongTimeoutMs = 60000, maxBackoffMs = 30000,
    random = Math.random, now = Date.now, dshClient, connectImpl = wsConnect, enabled = true,
    watchdogMs = 180000,
    // 慢请求阈值（毫秒）；0 = 关闭逐条慢请求记录。见 router.js 的 DEFAULT_SLOW_REQUEST_MS。
    slowRequestMs = DEFAULT_SLOW_REQUEST_MS,
    // 关掉手机推送的接收（回退闸）；见 contracts/connector-diagnostics-method.md §4。
    diagnostics = true,
    inviteCode, fetchImpl = fetch, env = process.env,
    // 生命周期流水（见 journal.js）：`journal` 传实例（测试注入），`journalPath`
    // 传路径（`defaultJournalPath()` 之外的位置），false 表示只留内存不落盘。
    journal, journalPath,
    // 手机不在时替它攒下来的提问条数上限（见 router.js）；环境变量给部署用，
    // 构造参数给测试用。**没有"留多久"这个旋钮**：`$events` 一直留到设备被撤销。
    eventsBacklog = numberFromEnv(env.DSH_MOBILE_LINK_EVENTS_BACKLOG, DEFAULT_EVENTS_BACKLOG),
  } = {}) {
    super()
    this.config = { relayUrl, agentId, agentSecret, agentName, stateFile, dshUrl, inviteCode }
    this.logger = logger
    this.heartbeatMs = heartbeatMs
    this.pongTimeoutMs = pongTimeoutMs
    this.maxBackoffMs = maxBackoffMs
    this.watchdogMs = watchdogMs
    this.slowRequestMs = Number(slowRequestMs) || 0
    this.diagnostics = diagnostics !== false
    this.random = random
    this.now = now
    this.connectImpl = connectImpl
    this.fetchImpl = fetchImpl
    this.env = env
    this.enabled = enabled
    //: Set when this computer has no identity yet: a setup problem for a person
    //: to fix, not a transport problem to retry.
    this.needsEnroll = false
    this.dsh = dshClient ?? new DshClient({ explicitUrl: dshUrl, logger })
    /** 生命周期流水：内存环 +（默认）一份 JSONL，见 journal.js 的文件头。 */
    this.journal = journal ?? new LinkJournal({
      path: journalPath === false
        ? undefined
        : (typeof journalPath === 'string' && journalPath ? journalPath : defaultJournalPath()),
      now,
      logger,
    })
    this.router = new DeviceRouter({
      dsh: this.dsh,
      logger,
      now,
      protocolVersion: PROTOCOL_VERSION,
      eventsBacklog,
      slowRequestMs: this.slowRequestMs,
      diagnostics: this.diagnostics,
      send: (deviceId, frame) => this.sendToDevice(deviceId, frame),
      // 设备侧的 attach/detach 与链路侧同源记进流水：事后想把"手机断了"和
      // "连接器拆链"对上时间，两边必须写在同一份文件里。
      // `options.foreign` 表示这条事件用的是**别人的钟**（App 推上来的），必须原样保留时刻。
      onEvent: (kind, detail, options) => (options?.foreign
        ? this.journal.recordForeign(kind, detail)
        : this.journal.record(kind, detail)),
      // 「跑完了 / 待你回应」到了就报一声（`{t:'notify'}`）。这是 agent 侧控制帧，
      // **不带 deviceId**：连接器不知道、也不需要知道这台电脑配了哪些手机，
      // 「该不该推给某台手机」由中转判（它手里才有"这台设备此刻在不在线"）。
      // `#rawSend` 自己处理"socket 不在就丢掉"，这里不必另判。
      notify: (payload) => this.#rawSend({ t: 'notify', ...payload }),
      onChange: () => this.emit('status'),
    })

    this.identity = undefined
    /** Which host form we are running in (`desktop` / `web` / `unknown`); set by the plugin. */
    this.hostForm = 'unknown'
    /// 历史读取（spec 007）：宿主 `sessionQuery` 就绪后由插件挂上；没挂上时
    /// 路由回 `link/unsupported`，手机继续走 `session/page`。
    this.setHistoryService = (service) => { this.router.history = service }
    /// 活动名单与 `link/jobs` 推帧（spec 018）：帧由 router 广播给在线设备，
    /// 订阅与去抖都在 roster 里。宿主服务由 `setJobsServices` 挂上。
    this.jobsRoster = createJobsRoster({
      deliver: (value) => this.router.publishEvent(value),
      logger,
      now,
    })
    this.router.bindJobsRoster(this.jobsRoster)
    this.setJobsServices = (services) => this.jobsRoster.bindServices(services)
    this.relay = undefined
    this.socket = undefined
    this.state = 'idle'
    this.lastError = undefined
    this.dshError = undefined
    this.startedAt = undefined
    this.connectedAt = undefined
    this.reconnectAttempts = 0
    /** 最近一次拆链的时刻（用来在 `link.open` 里报"距上次断开多久"）。 */
    this._lastClosedAt = undefined
    /**
     * socket 上最后一次系统错误（`onError` 的文本）。
     *
     * 为什么要专门留住它：链路被异常关闭时，`close` 回调只给一个代码（实测常见 1006，
     * 含义是"没有关闭帧"），据此无法判断是网络、代理还是对端。系统错误文本是唯一线索，
     * 而它以前只进了 debug 日志、不落流水（2026-10-13 现场诊断时卡在这里）。
     */
    this._socketError = undefined

    this._stopping = false
    this._sessionClosed = undefined
    this._heartbeat = undefined
    this._inbox = Promise.resolve()
    this._lastPong = 0
    this._loop = undefined
    this._loopActive = false
    this._watchdog = undefined
    this._lastProgressAt = 0
    this._abort = new AbortController()

    // The mux is shared by every device, so its events are wired once here.
    this.dsh.on?.('stream-item', (muxId, value) => this.onStreamItem(muxId, value))
    this.dsh.on?.('stream-error', (muxId, error) => this.onStreamError(muxId, error))
    this.dsh.on?.('stream-end', (muxId) => this.onStreamEnd(muxId))
    this.dsh.on?.('mux-down', (reason) => this.onMuxDown(reason))
  }

  // Routing state, exposed for status and for tests.
  get devices() {
    return this.router.devices
  }

  get streams() {
    return this.router.streams
  }

  get dedupe() {
    return this.router.dedupe
  }

  /** The most recent failure from either half of the link. */
  get failure() {
    return this.lastError ?? this.router.lastError
  }

  /**
   * Wire the in-process resolver the plugin learned from `ctx.inject`.
   *
   * Only the plugin can obtain it (it needs `webServer` + `connection`), and it
   * arrives asynchronously, so this is a setter rather than a constructor option.
   *
   * @param {(() => string | undefined) | undefined} resolver
   */
  setHostService(resolver) {
    if (typeof this.dsh?.setHostService === 'function') this.dsh.setHostService(resolver)
    // 解析器一到就试一次本机发现：交接文件服务的是"进程外工具"，**与中转链路无关**，
    // 因此不能只在连上中转之后才写（未登记的机器上那样永远写不出来）。
    if (typeof resolver === 'function') void this.refreshLocal()
    return this
  }

  /**
   * 与中转无关的本机发现：拿到带凭据地址就刷新交接文件。
   *
   * 这是 `/mobile-link/status` 与"进程外工具能不能工作"的共同前提，所以它在
   * 链路还没建立（甚至没登记）时也要跑。失败只记进 `dshError`，不影响链路。
   */
  async refreshLocal() {
    try {
      await this.dsh.refresh()
      this.dshError = undefined
      await this.#writeHandoff()
      this.emit('status')
      return this.dsh.endpoint
    } catch (error) {
      this.dshError = messageOf(error)
      this.emit('status')
      return undefined
    }
  }

  /**
   * Record which host form we are in, so the status payload can tell the user
   * which installation instructions apply to this machine.
   *
   * @param {'desktop' | 'web' | 'unknown'} form
   */
  setHostForm(form) {
    this.hostForm = form === 'desktop' || form === 'web' ? form : 'unknown'
    this.emit('status')
    return this
  }

  /**
   * Publish the current authenticated loopback address for out-of-process tools
   * (our dev/test scripts and the iOS test helpers).
   *
   * Best effort: a failed write must never take the link down.
   */
  async #writeHandoff() {
    const payload = handoffFromEndpoint(this.dsh?.endpoint)
    if (!payload) return
    try {
      await writeHandoff(payload)
    } catch (error) {
      this.logger.debug?.(`mobile-link: handoff file not written: ${messageOf(error)}`)
    }
  }

  // ── lifecycle ───────────────────────────────────────────────────────────

  async start() {
    if (this.enabled === false) {
      this.state = 'disabled'
      this.emit('status')
      return this
    }
    // 先把上一个实例停掉（热更留下的那条连接）：不停的话两个实例会抢同一个 agent 会话，
    // 表现就是"手机连上中转、却等不到任何回复"。
    const previous = globalThis[LIVE_AGENT]
    if (previous && previous !== this) {
      try {
        await previous.stop()
      } catch {
        /* 旧实例停不掉也不能挡住新的 */
      }
    }
    globalThis[LIVE_AGENT] = this
    if (this._loop) return this
    this._stopping = false
    this._abort = new AbortController()
    this.startedAt = this.now()
    this.state = 'connecting'
    this.journal.record('link.start', {
      // 这里只能报**配置值**：真身份（含实际中转地址）要等 `#session()` 里的
      // `resolveIdentity()` 才读到，那条记在 `link.open` 上。名字带 configured，
      // 免得读者把占位符 `wss://relay.example.com/dsh-link` 当成真的在连的地址。
      configuredRelay: this.config.relayUrl,
      agentId: this.config.agentId || undefined,
      attempt: this.reconnectAttempts,
      host: this.hostForm,
    })
    // 解析器可能在上一次会话里就已经装好；这里补一次本机发现（失败无妨）。
    void this.refreshLocal()
    this._lastProgressAt = this.now()
    this.#startWatchdog()
    this._loopActive = true
    this._loop = this.#run().catch((error) => {
      this.lastError = messageOf(error)
      this.state = 'failed'
      this.emit('status')
    }).finally(() => {
      this._loopActive = false
    })
    return this
  }

  async stop() {
    this.#stopWatchdog()
    if (globalThis[LIVE_AGENT] === this) globalThis[LIVE_AGENT] = undefined
    this._stopping = true
    this._abort.abort()
    this.#teardownSocket('agent stopped')
    try {
      await this._loop
    } catch {
      /* already reported */
    }
    this._loop = undefined
    this.dsh.close()
    this.state = 'stopped'
    this.journal.record('link.stop', {})
    this.emit('status')
  }

  async #run() {
    while (!this._stopping) {
      // First run on a computer that has never been registered: redeem the
      // invite code once, then carry on into the normal connect below. A
      // failure here is a setup error, so it is reported as such and not
      // retried in a loop.
      if (this.needsEnroll || this.#enrollPending()) {
        try {
          await this.enrollNow()
        } catch (error) {
          this.needsEnroll = true
          this.state = 'unregistered'
          this.lastError = messageOf(error)
          this.journal.record('link.unregistered', { error: this.lastError })
          this.logger.error?.(this.lastError)
          this.emit('status')
          return
        }
      }
      this.state = this.reconnectAttempts === 0 ? 'connecting' : 'reconnecting'
      this.emit('status')
      try {
        await this.#session()
        this.reconnectAttempts = 0
      } catch (error) {
        // A missing identity is a setup state, not a transport failure:
        // retrying it would only produce the same error every few seconds.
        if (error instanceof MissingIdentity) {
          this.needsEnroll = true
          this.state = 'unregistered'
          this.lastError = messageOf(error)
          this.journal.record('link.unregistered', { error: this.lastError })
          this.logger.error?.(`${this.lastError}\n  ${this.enrollHint()}`)
          this.emit('status')
          return
        }
        this.lastError = messageOf(error)
        this.journal.record('link.failed', { error: this.lastError, attempt: this.reconnectAttempts })
        this.logger.warn?.(`mobile-link: ${this.lastError}`)
      }
      if (this._stopping) break
      this.state = 'backoff'
      this.emit('status')
      const delay = nextBackoff(this.reconnectAttempts, { maxMs: this.maxBackoffMs, random: this.random })
      this.reconnectAttempts += 1
      this.journal.record('link.backoff', { attempt: this.reconnectAttempts, delayMs: Math.round(delay) })
      await sleep(delay, this._abort.signal)
    }
    this.state = 'stopped'
    this.emit('status')
  }

  /** An invite code was supplied and there is no identity file yet. */
  #enrollPending() {
    if (!inviteFrom({ inviteCode: this.config.inviteCode, env: this.env })) return false
    return !this.identity
  }

  /**
   * Redeem this computer's invite code.
   *
   * Exposed because the install path calls it directly (before the link ever
   * starts) and because `status()` reports whether it is still outstanding.
   */
  async enrollNow() {
    const relayUrl = this.config.relayUrl
    const settled = await enrollAgent({
      relayUrl,
      inviteCode: inviteFrom({ inviteCode: this.config.inviteCode, env: this.env }),
      name: this.config.agentName,
      stateFile: this.config.stateFile,
      fetchImpl: this.fetchImpl,
      logger: this.logger,
    })
    this.needsEnroll = false
    this.lastError = undefined
    this.emit('status')
    return settled
  }

  /** What a person has to run to register this computer. */
  enrollHint() {
    return enrollCommand(this.config.relayUrl, this.config.agentName)
  }

  /** One relay connection: resolves when the socket closes. */
  async #session() {
    const identity = await resolveIdentity(this.config)
    this.identity = identity
    this.needsEnroll = false
    this.relay = normalizeRelayUrl(identity.relayUrl)
    const url = `${agentEndpoint(identity.relayUrl)}?agentId=${encodeURIComponent(identity.agentId)}`
    const socket = await this.connectImpl(url, {
      headers: { authorization: `Bearer ${identity.agentSecret}` },
      timeoutMs: 20000,
    })
    this.socket = socket
    this.state = 'connected'
    this.connectedAt = this.now()
    this._lastProgressAt = this.now()
    this.lastError = undefined
    this.router.lastError = undefined
    this._lastPong = this.now()
    this.logger.info?.(`mobile-link: connected to ${this.relay.wsBase} as ${identity.agentId}`)
    this.journal.record('link.open', {
      relay: this.relay?.wsBase,
      agentId: identity.agentId,
      attempt: this.reconnectAttempts,
      sinceCloseMs: this._lastClosedAt === undefined ? undefined : this.now() - this._lastClosedAt,
      // 这次连接属于哪套版本：连接器 + 宿主 DSH。一连接一行，事后从本机流水就能
      // 认出"出问题的那天跑的是哪两个版本"，不必再去翻安装记录。
      serverVersion: SERVER_VERSION,
      hostVersion: hostVersion(),
    })
    this.emit('status')

    socket.onMessage((text) => {
      this._inbox = this._inbox
        .then(() => this.handleRelayFrame(decodeFrame(text)))
        .catch((error) => this.logger.debug?.(`mobile-link: frame handler error: ${messageOf(error)}`))
      return this._inbox
    })
    socket.onError((error) => {
      this._socketError = messageOf(error)
      this.logger.debug?.(`mobile-link: relay socket error: ${this._socketError}`)
    })
    socket.onClose((code, reason) => this.#teardownSocket(`relay closed the socket (${code ?? '?'} ${reason ?? ''})`))

    this.#startHeartbeat()
    // Verify discovery + auth as soon as the relay link is up, so /mobile-link/
    // status can report the real DSH port (and the failure, if any) before the
    // first device ever asks for anything.
    try {
      await this.dsh.refresh()
      this.dshError = undefined
      // 进程外工具（本机脚本、iOS 集成测试辅助）靠这份交接文件拿带凭据地址；
      // 写入失败不影响链路（`#writeHandoff` 自己吞异常）。
      await this.#writeHandoff()
      this.journal.record('dsh.ok', { endpoint: this.dsh?.endpoint?.base })
    } catch (error) {
      this.dshError = messageOf(error)
      this.lastError = this.dshError
      // 这一条很关键：本机 DSH 不可达时，手机那句 `_link/hello`/`sessions` 探针
      // 必然超时，App 会据此重建整条链路——于是"连接器在、手机却连不上"。
      this.journal.record('dsh.unreachable', { error: this.dshError, kind: this.dsh?.errorKind })
      this.logger.warn?.(`mobile-link: local DSH is not reachable yet: ${this.dshError}`)
    }
    this.emit('status')
    this.sendHostStatus()

    await new Promise((resolve) => {
      this._sessionClosed = resolve
    })
  }

  /**
   * 看门狗：**与单次会话的心跳无关**的兜底。
   *
   * 心跳只在"连上之后"跑，而且会话卡死时它依赖 `setInterval` 还在（热更把它换掉就没了）。
   * 看门狗每 `heartbeatMs` 看一次"链路最近有没有进展"：
   *  * 已连上但超过 `pongTimeoutMs` 没动静 ⇒ 强制拆掉这条 socket（会话随即返回、进重连）；
   *  * **循环已经不在了**（`_loopActive === false`，典型是热更换掉了实例）⇒ 重新拉起循环。
   * 正常重连退避期间（循环还在、状态是 connecting/backoff）它什么都不做，只在
   * 超过 `watchdogMs` 仍无进展时把 socket 拆掉重来一次，避免"半开连接永远挂着"。
   */
  #startWatchdog() {
    this.#stopWatchdog()
    // 检查频率：至少在"判定超时"的窗口里看两次，最多 5 秒一次、最少 1 秒一次。
    // 不能跟着 `heartbeatMs` 走——心跳间隔设得大（例如测试里 60s）会让看门狗也 20s 才醒一次。
    const every = Math.max(1000, Math.min(Math.floor(this.pongTimeoutMs / 2) || 1000, 5000))
    this._watchdog = setInterval(() => {
      if (this._stopping || this.enabled === false) return
      const idle = this.now() - this._lastProgressAt
      if (!this._loopActive) {
        this.lastError = `链路循环不在了（看门狗重拉，空闲 ${Math.round(idle / 1000)}s）`
        this.journal.record('watchdog.repull', { idleMs: Math.round(idle) })
        this.logger.warn?.(`mobile-link: ${this.lastError}`)
        this._loop = undefined
        this._lastProgressAt = this.now()
        void this.start()
        return
      }
      if (this.state === 'connected' && idle > this.pongTimeoutMs) {
        this.lastError = `relay 超过 ${Math.round(idle / 1000)}s 没有动静（看门狗拆连接）`
        this.journal.record('watchdog.drop', { idleMs: Math.round(idle), state: this.state })
        this.logger.warn?.(`mobile-link: ${this.lastError}`)
        this.#teardownSocket(this.lastError)
        this._lastProgressAt = this.now()
        return
      }
      if (this.state !== 'connected' && idle > this.watchdogMs) {
        this.lastError = `链路 ${Math.round(idle / 1000)}s 没有进展（看门狗重建连接）`
        this.journal.record('watchdog.drop', { idleMs: Math.round(idle), state: this.state })
        this.logger.warn?.(`mobile-link: ${this.lastError}`)
        this.#teardownSocket(this.lastError)
        this._lastProgressAt = this.now()
      }
    }, every)
    this._watchdog.unref?.()
  }

  #stopWatchdog() {
    if (this._watchdog) clearInterval(this._watchdog)
    this._watchdog = undefined
  }

  #startHeartbeat() {
    this.#stopHeartbeat()
    this._heartbeat = setInterval(() => {
      if (this.now() - this._lastPong > this.pongTimeoutMs) {
        this.lastError = `relay stopped answering pings (>${this.pongTimeoutMs}ms)`
        this.logger.warn?.(`mobile-link: ${this.lastError}`)
        this.#teardownSocket(this.lastError)
        return
      }
      this.#rawSend({ t: 'ping', ts: this.now() })
    }, this.heartbeatMs)
    this._heartbeat.unref?.()
  }

  #stopHeartbeat() {
    if (this._heartbeat) clearInterval(this._heartbeat)
    this._heartbeat = undefined
  }

  #teardownSocket(reason) {
    this.#stopHeartbeat()
    const socket = this.socket
    const from = this.state
    this.socket = undefined
    if (socket) {
      try {
        socket.close(1000, 'reconnecting')
      } catch {
        /* already gone */
      }
    }
    // The relay re-attaches devices on the next connection; drop their streams
    // now so nothing leaks while we are away.
    for (const muxId of this.router.teardownAll()) this.dsh.cancelStream(muxId)
    this.dsh.close()
    if (this.state !== 'stopped' && this.state !== 'disabled') this.state = 'disconnected'
    this.lastError = this.lastError ?? reason
    this._lastClosedAt = this.now()
    // 「为什么拆的」是这一族事件唯一要回答的问题：reason 来自调用点，
    // from 是拆之前的状态（connected / backoff / connecting），
    // connectedForMs 用来区分"刚连上就掉"和"挂了很久才掉"。
    this.journal.record('link.close', {
      reason,
      from,
      connectedForMs: this.connectedAt === undefined ? undefined : this.now() - this.connectedAt,
      // 有系统错误才带这个字段（正常关闭时不该凭空多一个 null）。
      socketError: this._socketError,
    })
    this._socketError = undefined
    const resolve = this._sessionClosed
    this._sessionClosed = undefined
    this.emit('status')
    resolve?.()
  }

  // ── relay I/O ───────────────────────────────────────────────────────────

  #rawSend(frame) {
    return this.#sendText(encodeFrame(frame))
  }

  /** 唯一的发送出口：socket 不在就丢掉，发送异常只记 debug、绝不抛。 */
  #sendText(text) {
    const socket = this.socket
    if (!socket || socket.closed) return false
    try {
      socket.send(text)
      return true
    } catch (error) {
      this.logger.debug?.(`mobile-link: send failed: ${messageOf(error)}`)
      return false
    }
  }

  sendToDevice(deviceId, frame) {
    // `deviceId` 为空＝这是一条**不带寻址**的帧（`fsPutAck`/`fsPutDone`/`fsErr` 那一族）：
    // relay 靠 `bid` 把回复对回发起的那个 HTTP 请求，多一个 deviceId 反而会让它对不上。
    if (deviceId === undefined || deviceId === null) return this.#rawSend(frame)
    const text = encodeFrame({ ...frame, deviceId })
    // 记字节给路由层的"慢请求/汇总"用（它按 deviceId 归）：只有这里知道真正上线了多少字节。
    this.router.noteSent?.(deviceId, Buffer.byteLength(text))
    return this.#sendText(text)
  }

  sendHostStatus() {
    return this.#rawSend({
      t: 'hostStatus',
      info: {
        online: true,
        agentId: this.identity?.agentId,
        name: this.identity?.agentName || undefined,
        dshPort: this.dsh?.endpoint?.port,
        protocol: PROTOCOL_VERSION,
        // 这台电脑的两段版本。中转据此按 agent 记一行（变化才写），手机据此
        // 在「关于」里显示 DSH 版本——只在控制帧上走一次，不进任何业务流。
        version: SERVER_VERSION,
        hostVersion: hostVersion(),
      },
    })
  }

  /** Route one frame from the relay. */
  async handleRelayFrame(frame) {
    // 中转来的任何一帧都算"链路有进展"——看门狗据此区分"半开连接"与"正在正常工作"。
    this._lastProgressAt = this.now()
    if (!frame || typeof frame !== 'object') return
    if (frame.t === 'pong') {
      this._lastPong = this.now()
      this._lastProgressAt = this.now()
      return
    }
    if (frame.t === 'ping') {
      this.#rawSend(pongFor(frame))
      return
    }
    if (frame.t === 'error') {
      this.lastError = `${frame.code}: ${frame.message}`
      this.emit('status')
      if (frame.fatal) this.socket?.close(4002, 'relay protocol error')
      return
    }
    await this.router.handleRelayFrame(frame)
  }

  // ── mux-event delegates ─────────────────────────────────────────────────

  onStreamItem(muxId, value) {
    this.router.onStreamItem(muxId, value)
  }

  onStreamError(muxId, error) {
    this.router.onStreamError(muxId, error)
  }

  onStreamEnd(muxId) {
    this.router.onStreamEnd(muxId)
  }

  onMuxDown(reason) {
    this.router.onMuxDown(reason)
  }

  // ── relay-side helpers ──────────────────────────────────────────────────

  /**
   * Ask the relay to mint a pairing code for this agent (relay NOTES.md §2).
   *
   * 032：默认持久（`ttlMs: null`）；传秒数得到限时码。
   */
  async mintPairCode({ ttlMs = null, fetchImpl = fetch } = {}) {
    const identity = this.identity ?? await resolveIdentity(this.config)
    return mintPairCode({ identity, ttlMs, fetchImpl })
  }

  /** 用户点「重新生成」：作废旧码、铸新的，**不碰已配对设备**（032）。 */
  async regeneratePairCode({ fetchImpl = fetch } = {}) {
    const identity = this.identity ?? await resolveIdentity(this.config)
    return regeneratePairCode({ identity, fetchImpl })
  }

  /** Snapshot for `GET /mobile-link/status`（载荷本身在 status.js，便于守住"只增不改"）。 */
  status() {
    return statusSnapshot(this)
  }
}

export { EVENTS_ENDPOINT, EVENTS_RESULT }

/**
 * The DLP agent transport: identity, the relay socket, heartbeats, reconnect.
 * Device-level routing lives in `router.js`; this file owns every socket and
 * timer. Spec: docs/RELAY-PROTOCOL.md §4.
 */

import { EventEmitter } from 'node:events'

import { DshClient } from './dsh-client.js'
import { agentEndpoint, decodeFrame, encodeFrame, nextBackoff, normalizeRelayUrl, pongFor } from './dlp.js'
import { enrollAgent, enrollCommand, inviteFrom } from './enroll.js'
import { handoffFromEndpoint, writeHandoff } from './handoff.js'
import { statusSnapshot } from './status.js'
import { mintPairCode } from './pairing.js'
import {
  DEFAULT_EVENTS_BACKLOG,
  EVENTS_ENDPOINT, EVENTS_RESULT, DeviceRouter, messageOf,
} from './router.js'
import { SERVER_VERSION, SERVER_CAPABILITIES } from './hello.js'
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
    inviteCode, fetchImpl = fetch, env = process.env,
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
    this.router = new DeviceRouter({
      dsh: this.dsh,
      logger,
      now,
      protocolVersion: PROTOCOL_VERSION,
      eventsBacklog,
      send: (deviceId, frame) => this.sendToDevice(deviceId, frame),
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
    this.relay = undefined
    this.socket = undefined
    this.state = 'idle'
    this.lastError = undefined
    this.dshError = undefined
    this.startedAt = undefined
    this.connectedAt = undefined
    this.reconnectAttempts = 0

    this._stopping = false
    this._sessionClosed = undefined
    this._heartbeat = undefined
    this._inbox = Promise.resolve()
    this._lastPong = 0
    this._loop = undefined
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
    if (this._loop) return this
    this._stopping = false
    this._abort = new AbortController()
    this.startedAt = this.now()
    this.state = 'connecting'
    // 解析器可能在上一次会话里就已经装好；这里补一次本机发现（失败无妨）。
    void this.refreshLocal()
    this._loop = this.#run().catch((error) => {
      this.lastError = messageOf(error)
      this.state = 'failed'
      this.emit('status')
    })
    return this
  }

  async stop() {
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
          this.logger.error?.(`${this.lastError}\n  ${this.enrollHint()}`)
          this.emit('status')
          return
        }
        this.lastError = messageOf(error)
        this.logger.warn?.(`mobile-link: ${this.lastError}`)
      }
      if (this._stopping) break
      this.state = 'backoff'
      this.emit('status')
      const delay = nextBackoff(this.reconnectAttempts, { maxMs: this.maxBackoffMs, random: this.random })
      this.reconnectAttempts += 1
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
    this.lastError = undefined
    this.router.lastError = undefined
    this._lastPong = this.now()
    this.logger.info?.(`mobile-link: connected to ${this.relay.wsBase} as ${identity.agentId}`)
    this.emit('status')

    socket.onMessage((text) => {
      this._inbox = this._inbox
        .then(() => this.handleRelayFrame(decodeFrame(text)))
        .catch((error) => this.logger.debug?.(`mobile-link: frame handler error: ${messageOf(error)}`))
      return this._inbox
    })
    socket.onError((error) => this.logger.debug?.(`mobile-link: relay socket error: ${messageOf(error)}`))
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
    } catch (error) {
      this.dshError = messageOf(error)
      this.lastError = this.dshError
      this.logger.warn?.(`mobile-link: local DSH is not reachable yet: ${this.dshError}`)
    }
    this.emit('status')
    this.sendHostStatus()

    await new Promise((resolve) => {
      this._sessionClosed = resolve
    })
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
    const resolve = this._sessionClosed
    this._sessionClosed = undefined
    this.emit('status')
    resolve?.()
  }

  // ── relay I/O ───────────────────────────────────────────────────────────

  #rawSend(frame) {
    const socket = this.socket
    if (!socket || socket.closed) return false
    try {
      socket.send(encodeFrame(frame))
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
    return this.#rawSend({ ...frame, deviceId })
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
      },
    })
  }

  /** Route one frame from the relay. */
  async handleRelayFrame(frame) {
    if (!frame || typeof frame !== 'object') return
    if (frame.t === 'pong') {
      this._lastPong = this.now()
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

  /** Ask the relay to mint a pairing code for this agent (relay NOTES.md §2). */
  async mintPairCode({ ttlMs = 10 * 60 * 1000, fetchImpl = fetch } = {}) {
    const identity = this.identity ?? await resolveIdentity(this.config)
    return mintPairCode({ identity, ttlMs, fetchImpl })
  }

  /** Snapshot for `GET /mobile-link/status`（载荷本身在 status.js，便于守住"只增不改"）。 */
  status() {
    return statusSnapshot(this)
  }
}

export { EVENTS_ENDPOINT, EVENTS_RESULT }

/**
 * The DLP agent transport: identity, the relay socket, heartbeats, reconnect.
 * Device-level routing lives in `router.js`; this file owns every socket and
 * timer. Spec: docs/RELAY-PROTOCOL.md §4.
 */

import { EventEmitter } from 'node:events'

import { DshClient } from './dsh-client.js'
import { agentEndpoint, decodeFrame, encodeFrame, nextBackoff, normalizeRelayUrl, pongFor } from './dlp.js'
import { enrollAgent, enrollCommand, inviteFrom } from './enroll.js'
import { mintPairCode } from './pairing.js'
import { EVENTS_ENDPOINT, EVENTS_RESULT, DeviceRouter, messageOf } from './router.js'
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

export class MobileLinkAgent extends EventEmitter {
  constructor({
    relayUrl, agentId, agentSecret, agentName, stateFile, dshUrl, endpointFile,
    logger = console, heartbeatMs = 20000, pongTimeoutMs = 60000, maxBackoffMs = 30000,
    random = Math.random, now = Date.now, dshClient, connectImpl = wsConnect, enabled = true,
    inviteCode, fetchImpl = fetch, env = process.env,
  } = {}) {
    super()
    this.config = { relayUrl, agentId, agentSecret, agentName, stateFile, dshUrl, endpointFile, inviteCode }
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
    this.dsh = dshClient ?? new DshClient({ endpointFile, explicitUrl: dshUrl, logger })
    this.router = new DeviceRouter({
      dsh: this.dsh,
      logger,
      now,
      protocolVersion: PROTOCOL_VERSION,
      send: (deviceId, frame) => this.sendToDevice(deviceId, frame),
      onChange: () => this.emit('status'),
    })

    this.identity = undefined
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

  /** Snapshot for `GET /mobile-link/status`. */
  status() {
    return {
      ok: true,
      enabled: this.enabled !== false,
      protocolVersion: PROTOCOL_VERSION,
      // Same facts as `_link/hello`, which is the channel the app actually
      // uses: this route only exists on the direct path.
      serverVersion: SERVER_VERSION,
      capabilities: SERVER_CAPABILITIES,
      enroll: {
        // A phone (or the user's browser) can read this to find out that the
        // computer half is installed but not yet registered, and what to run.
        registered: !this.needsEnroll,
        needsEnroll: this.needsEnroll,
        stateFile: this.identity?.stateFile ?? this.config.stateFile ?? null,
        relayUrl: this.config.relayUrl ?? null,
        command: this.needsEnroll ? this.enrollHint() : null,
        hint: this.needsEnroll
          ? '这台电脑还没有登记到中转。请带上邀请码运行一次登记命令，然后重启 DSH。'
          : null,
      },
      state: this.state,
      connected: this.state === 'connected',
      relayUrl: this.identity?.relayUrl ?? this.config.relayUrl ?? null,
      agentId: this.identity?.agentId ?? this.config.agentId ?? null,
      agentName: this.identity?.agentName ?? null,
      stateFile: this.identity?.stateFile ?? this.config.stateFile ?? null,
      dsh: {
        endpoint: this.dsh?.endpoint?.base ?? null,
        source: this.dsh?.endpoint?.source ?? null,
        port: this.dsh?.endpoint?.port ?? null,
        authenticated: Boolean(this.dsh?.cookie),
        muxUp: Boolean(this.dsh?.muxReady),
        error: this.dshError ?? null,
      },
      devices: this.router.snapshot(),
      deviceCount: this.devices.size,
      openStreams: this.streams.size,
      pendingWaterfalls: this.dedupe.size,
      lastError: this.failure ?? null,
      startedAt: this.startedAt ?? null,
      connectedAt: this.connectedAt ?? null,
      reconnectAttempts: this.reconnectAttempts,
    }
  }
}

export { EVENTS_ENDPOINT, EVENTS_RESULT }

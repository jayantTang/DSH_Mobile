/**
 * Client for the *local* DSH instance.
 *
 * Responsibilities (spec §4.1):
 *   1. Discover the endpoint as an ordered candidate list: explicit config, then the
 *      host's own in-process resolver, then `DSH_WEB_URL`, then `http://127.0.0.1:54499`.
 *      The authenticated value changes on every host restart, so it is re-resolved on
 *      every (re)connect.
 *   2. Exchange `?token=` for a `dsh-auth-*` cookie without following the 303.
 *      The cookie is bound to the authority, so the client always dials
 *      `127.0.0.1:<port>` and never rewrites `Host` (see NOTES.md on spec §7).
 *   3. Unary RPC via `POST /api/<method>` and one shared multiplexing
 *      WebSocket at `/api/remote.mux` for every logical stream.
 */

import { EventEmitter } from 'node:events'

import { connect as wsConnect } from './ws.js'

export class DshUnavailable extends Error {}

const FALLBACK_PORT = 54499
const MUX_PATH = '/api/remote.mux'

function portOf(url) {
  if (url.port) return Number(url.port)
  return url.protocol === 'https:' ? 443 : 80
}

function parseBase(raw, { forceLoopback = true } = {}) {
  const url = new URL(raw)
  const port = portOf(url)
  const host = forceLoopback ? '127.0.0.1' : url.hostname
  const scheme = url.protocol === 'https:' ? 'https' : 'http'
  return {
    base: `${scheme}://${host}:${port}`,
    wsBase: `${scheme === 'https' ? 'wss' : 'ws'}://${host}:${port}`,
    port,
    token: url.searchParams.get('token') || '',
  }
}

/**
 * Whether this answer is the binary form of an RPC result.
 *
 * A result that carries bytes **cannot** be JSON, so a Host that supports them
 * answers `multipart/form-data` instead. A client that only reads JSON sees an
 * unparsable body and reports `bad-response` — which is exactly how a Host
 * generation that started doing this broke every file read at once.
 */
function isBinaryAnswer(response) {
  const type = response.headers.get('content-type')?.split(';', 1)[0]?.trim().toLowerCase()
  return type === 'multipart/form-data'
}

/**
 * Decode that form into the envelope shape the JSON path also produces.
 *
 * Field for field the same contract the Host's own client implements: a
 * `metadata` part holds the envelope — with `null` wherever the bytes were —
 * plus one attachment per binary field, naming the part that carries it and the
 * path to walk from `result.value` to that `null`.
 */
async function decodeBinaryAnswer(response) {
  const body = await response.formData()
  const metadata = body.get('metadata')
  if (typeof metadata !== 'string') throw new TypeError('binary answer without metadata')
  const envelope = JSON.parse(metadata)
  const root = { value: envelope?.result?.value }
  for (const attachment of envelope?.attachments ?? []) {
    const part = attachment?.part
    const bytes = typeof part === 'string' ? body.get(part) : null
    if (!bytes || typeof bytes.arrayBuffer !== 'function') {
      throw new TypeError('binary answer with an unreadable part')
    }
    let parent = root
    let key = 'value'
    for (const segment of attachment?.path ?? []) {
      const value = parent[key]
      if (typeof value !== 'object' || value === null) {
        throw new TypeError('binary answer with an unreachable path')
      }
      parent = value
      key = segment
    }
    parent[key] = new Uint8Array(await bytes.arrayBuffer())
  }
  return envelope
}

/**
 * Resolve **all** ways this process might reach the local DSH, in the order they
 * must be tried (contract: `contracts/endpoint-discovery.md` §1).
 *
 * Pure and injectable on purpose: it only *produces candidates*. Authentication
 * happens in `DshClient`, because "this candidate works" must be decided by an
 * actual token → cookie exchange, not by the shape of the value.
 *
 * @param {object} [options]
 * @param {string} [options.explicitUrl] user-configured address (may carry a token)
 * @param {() => string | undefined} [options.hostService] in-process resolver: the host
 *   process hands us its current authenticated loopback URL (desktop + web hosts)
 * @param {NodeJS.ProcessEnv} [options.env]
 * @returns {Array<{base: string, wsBase: string, port: number, token: string, source: string}>}
 */
export function discoverCandidates({ explicitUrl, hostService, env = process.env } = {}) {
  const candidates = []
  if (explicitUrl) {
    const parsed = parseBase(explicitUrl, { forceLoopback: false })
    parsed.source = 'config'
    candidates.push(parsed)
  }
  if (typeof hostService === 'function') {
    try {
      const raw = hostService()
      if (typeof raw === 'string' && raw !== '') {
        const parsed = parseBase(raw)
        parsed.source = 'host-service'
        candidates.push(parsed)
      }
    } catch {
      /* the service is not usable in this host; fall through to the older sources */
    }
  }
  if (env.DSH_WEB_URL) {
    const parsed = parseBase(env.DSH_WEB_URL)
    parsed.source = 'DSH_WEB_URL'
    candidates.push(parsed)
  }
  const fallback = parseBase(`http://127.0.0.1:${FALLBACK_PORT}`)
  fallback.source = 'default'
  candidates.push(fallback)
  return candidates
}

/**
 * The first candidate, for callers that only need one address.
 * @returns {Promise<{base: string, wsBase: string, port: number, token: string, source: string}>}
 */
export async function discoverEndpoint(options = {}) {
  return discoverCandidates(options)[0]
}

/**
 * Classify why discovery/authentication failed, for the status payload and the
 * user-facing hint table (`contracts/status-endpoint.md` §3).
 *
 * The rule is "the candidate that got furthest": one that carried a token and
 * still failed says more about the situation than the bare fallback port.
 *
 * @param {{source?: string} | undefined} endpoint
 * @returns {'config' | 'host-service' | 'DSH_WEB_URL' | 'unreachable'}
 */
function kindFor(endpoint) {
  switch (endpoint?.source) {
    case 'config': return 'config'
    case 'host-service': return 'host-service'
    case 'DSH_WEB_URL': return 'DSH_WEB_URL'
    default: return 'unreachable'
  }
}

function cookieFrom(response) {
  const list = typeof response.headers.getSetCookie === 'function'
    ? response.headers.getSetCookie()
    : [response.headers.get('set-cookie')].filter(Boolean)
  const cookies = list
    .map((value) => String(value).split(';')[0].trim())
    .filter((value) => value.startsWith('dsh-auth-'))
  return cookies.join('; ')
}

export class DshClient extends EventEmitter {
  constructor({ explicitUrl, hostService, logger = console, fetchImpl = fetch, connectImpl = wsConnect, env = process.env } = {}) {
    super()
    this.explicitUrl = explicitUrl
    this.hostService = typeof hostService === 'function' ? hostService : undefined
    this.env = env
    this.logger = logger
    this.fetchImpl = fetchImpl
    this.connectImpl = connectImpl
    this.endpoint = undefined
    this.cookie = ''
    this.mux = undefined
    this.muxOpening = undefined
    this.muxReady = false
    this.pendingOpens = []
    this.lastError = undefined
    /** Failure classification for the status payload; see contracts/status-endpoint.md §3. */
    this.errorKind = undefined
  }

  /**
   * Wire (or replace) the in-process resolver after construction.
   *
   * The plugin learns about the host's services asynchronously — `ctx.inject`
   * callbacks fire once the service exists — so the agent cannot pass this in
   * the constructor.
   *
   * @param {(() => string | undefined) | undefined} resolver
   */
  setHostService(resolver) {
    this.hostService = typeof resolver === 'function' ? resolver : undefined
    return this
  }

  /**
   * Re-read endpoint discovery and re-do the token -> cookie exchange.
   *
   * Candidates are tried in order and the first one that *authenticates* wins:
   * a host that can hand us its current URL beats the environment variable and
   * the built-in default, while an older source is still used if the new one
   * turns out not to work (constitution §IV).
   */
  async refresh({ force = false } = {}) {
    const candidates = discoverCandidates({ explicitUrl: this.explicitUrl, hostService: this.hostService, env: this.env })
    let lastError
    let attemptedWithToken
    for (const candidate of candidates) {
      if (force || !this.endpoint || this.endpoint.base !== candidate.base) this.cookie = ''
      this.endpoint = candidate
      try {
        await this.authenticate()
        this.errorKind = undefined
        return this.endpoint
      } catch (error) {
        lastError = error
        if (candidate.token) attemptedWithToken = candidate
      }
    }
    this.cookie = ''
    this.errorKind = kindFor(attemptedWithToken ?? this.endpoint)
    throw lastError ?? new DshUnavailable('DSH is not reachable (no candidate answered)')
  }

  async authenticate() {
    const endpoint = this.endpoint
    if (!endpoint) throw new DshUnavailable('no DSH endpoint discovered yet')
    if (!endpoint.token) {
      throw new DshUnavailable(
        `no DSH launch token found (looked at ${endpoint.source}); restart the host or set dshUrl in the plugin config`,
      )
    }
    const url = `${endpoint.base}/?token=${encodeURIComponent(endpoint.token)}`
    let response
    try {
      response = await this.fetchImpl(url, { redirect: 'manual' })
    } catch (error) {
      throw new DshUnavailable(`cannot reach DSH at ${endpoint.base}: ${error instanceof Error ? error.message : error}`)
    }
    const cookie = cookieFrom(response)
    if (!cookie) {
      throw new DshUnavailable(`DSH auth handshake returned HTTP ${response.status} without a dsh-auth cookie`)
    }
    this.cookie = cookie
    this.logger.debug?.(`mobile-link: authenticated with DSH at ${endpoint.base} (source: ${endpoint.source})`)
    return cookie
  }

  async ensure() {
    if (!this.endpoint || !this.cookie) await this.refresh()
    return this.endpoint
  }

  /** One unary RPC. Returns the DSH `RemoteResult` object verbatim. */
  async rpc(method, args = {}, { retry = true } = {}) {
    await this.ensure()
    const rpcId = `ml-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
    const body = JSON.stringify({
      type: 'client-request',
      rpcId,
      method,
      payload: { args: args ?? {} },
    })
    let response
    try {
      response = await this.fetchImpl(`${this.endpoint.base}/api/${method}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', cookie: this.cookie },
        body,
      })
    } catch (error) {
      throw new DshUnavailable(`DSH request ${method} failed: ${error instanceof Error ? error.message : error}`)
    }
    if (response.status === 401 && retry) {
      this.logger.debug?.(`mobile-link: DSH session expired, re-authenticating (${method})`)
      this.cookie = ''
      await this.refresh({ force: true })
      return this.rpc(method, args, { retry: false })
    }
    let json
    try {
      json = isBinaryAnswer(response) ? await decodeBinaryAnswer(response) : await response.json()
    } catch {
      return { ok: false, error: { code: 'gateway/bad-response', message: `DSH returned HTTP ${response.status}`, details: {} } }
    }
    if (json?.result && typeof json.result === 'object') return json.result
    return { ok: false, error: { code: 'gateway/bad-response', message: 'DSH returned no result', details: {} } }
  }

  /** The single multiplexing socket; opened lazily and shared by every stream. */
  async ensureMux() {
    if (this.muxReady && this.mux && !this.mux.closed) return this.mux
    if (this.muxOpening) return this.muxOpening
    this.muxOpening = (async () => {
      await this.ensure()
      const handle = await this.connectImpl(`${this.endpoint.wsBase}${MUX_PATH}`, {
        headers: { cookie: this.cookie },
        timeoutMs: 20000,
      })
      this.mux = handle
      this.muxReady = true
      handle.onMessage((text) => this.#onMuxMessage(text))
      handle.onClose((code, reason) => this.#onMuxDown(`closed (${code ?? '?'} ${reason ?? ''})`))
      handle.onError((error) => this.logger.debug?.(`mobile-link: mux socket error: ${error?.message ?? error}`))
      for (const frame of this.pendingOpens.splice(0)) handle.send(frame)
      this.logger.debug?.('mobile-link: DSH mux socket open')
      return handle
    })()
    try {
      return await this.muxOpening
    } catch (error) {
      this.muxReady = false
      this.mux = undefined
      throw error
    } finally {
      this.muxOpening = undefined
    }
  }

  #onMuxMessage(text) {
    let frame
    try {
      frame = JSON.parse(text)
    } catch {
      return
    }
    const streamId = frame?.streamId
    if (typeof streamId !== 'string') return
    if (frame.type === 'item') this.emit('stream-item', streamId, frame.value)
    else if (frame.type === 'error') this.emit('stream-error', streamId, frame.error)
    else if (frame.type === 'end') this.emit('stream-end', streamId)
  }

  #onMuxDown(reason) {
    if (!this.muxReady && !this.mux) return
    this.muxReady = false
    this.mux = undefined
    this.logger.debug?.(`mobile-link: DSH mux socket down: ${reason}`)
    this.emit('mux-down', reason)
  }

  openStream(muxId, endpoint, args) {
    const text = JSON.stringify({ type: 'open', streamId: muxId, endpoint, payload: { args: args ?? {} } })
    if (this.muxReady && this.mux && !this.mux.closed) this.mux.send(text)
    else this.pendingOpens.push(text)
  }

  cancelStream(muxId) {
    const needle = `"streamId":${JSON.stringify(muxId)}`
    this.pendingOpens = this.pendingOpens.filter((text) => !text.includes(needle))
    if (this.muxReady && this.mux && !this.mux.closed) {
      try {
        this.mux.send(JSON.stringify({ type: 'cancel', streamId: muxId }))
      } catch {
        /* socket died between checks */
      }
    }
  }

  close() {
    this.muxReady = false
    this.pendingOpens = []
    try {
      this.mux?.close(1000, 'agent shutdown')
    } catch {
      /* already closed */
    }
    this.mux = undefined
  }
}

/**
 * Client for the *local* DSH instance.
 *
 * Responsibilities (spec §4.1):
 *   1. Discover the endpoint: `$DSH_HOME/desktop-shell/endpoint.json`, then
 *      `$DSH_WEB_URL`, then `http://127.0.0.1:54499`. The file changes on every
 *      DSH restart, so it is re-read on every (re)connect.
 *   2. Exchange `?token=` for a `dsh-auth-*` cookie without following the 303.
 *      The cookie is bound to the authority, so the client always dials
 *      `127.0.0.1:<port>` and never rewrites `Host` (see NOTES.md on spec §7).
 *   3. Unary RPC via `POST /api/<method>` and one shared multiplexing
 *      WebSocket at `/api/remote.mux` for every logical stream.
 */

import { EventEmitter } from 'node:events'
import { readFile } from 'node:fs/promises'

import { defaultEndpointFile, defaultShellLogFile } from './state.js'
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
 * Resolve where the local DSH web server lives.
 * @returns {Promise<{base: string, wsBase: string, port: number, token: string, source: string}>}
 */
export async function discoverEndpoint({
  endpointFile = defaultEndpointFile(),
  shellLogFile = defaultShellLogFile(),
  explicitUrl,
} = {}) {
  if (explicitUrl) {
    const parsed = parseBase(explicitUrl, { forceLoopback: false })
    parsed.source = 'config'
    return parsed
  }
  try {
    const raw = JSON.parse(await readFile(endpointFile, 'utf8'))
    const url = typeof raw?.url === 'string' && raw.url ? raw.url : `http://127.0.0.1:${raw?.port ?? FALLBACK_PORT}`
    const parsed = parseBase(url)
    if (!parsed.port) parsed.port = Number(raw?.port) || FALLBACK_PORT
    parsed.base = `http://127.0.0.1:${parsed.port}`
    parsed.wsBase = `ws://127.0.0.1:${parsed.port}`
    parsed.token = parsed.token || url.searchParams?.get?.('token') || ''
    parsed.source = `endpoint.json:${endpointFile}`
    return parsed
  } catch {
    /* fall through to the log, the environment and the built-in default */
  }
  // The handoff file can be missing while the host is very much alive: the
  // desktop shell deletes it when it quits, and a bare `dsh web --port 0` never
  // writes one at all. The shell's own log keeps every launch line, so the last
  // one that still answers is the live endpoint. This is the same second source
  // `test/tools/host.mjs` reads for the same reason.
  try {
    const log = await readFile(shellLogFile, 'utf8')
    const matches = log.match(/http:\/\/127\.0\.0\.1:(\d+)\/\?token=([A-Za-z0-9_-]+)/g)
    if (matches && matches.length) {
      const parsed = parseBase(matches[matches.length - 1])
      parsed.source = `dsh-shell.log:${shellLogFile}`
      return parsed
    }
  } catch {
    /* fall through to the environment and the built-in default */
  }
  if (process.env.DSH_WEB_URL) {
    const parsed = parseBase(process.env.DSH_WEB_URL)
    parsed.source = 'DSH_WEB_URL'
    return parsed
  }
  const parsed = parseBase(`http://127.0.0.1:${FALLBACK_PORT}`)
  parsed.source = 'default'
  return parsed
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
  constructor({ endpointFile, explicitUrl, logger = console, fetchImpl = fetch, connectImpl = wsConnect } = {}) {
    super()
    this.endpointFile = endpointFile || defaultEndpointFile()
    this.explicitUrl = explicitUrl
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
  }

  /** Re-read endpoint discovery and re-do the token -> cookie exchange. */
  async refresh({ force = false } = {}) {
    const endpoint = await discoverEndpoint({ endpointFile: this.endpointFile, explicitUrl: this.explicitUrl })
    if (force || !this.endpoint || this.endpoint.base !== endpoint.base) this.cookie = ''
    this.endpoint = endpoint
    if (!this.cookie) await this.authenticate()
    return this.endpoint
  }

  async authenticate() {
    const endpoint = this.endpoint ?? await discoverEndpoint({
      endpointFile: this.endpointFile, explicitUrl: this.explicitUrl,
    })
    this.endpoint = endpoint
    if (!endpoint.token) {
      throw new DshUnavailable(
        `no DSH launch token found (looked at ${this.endpoint.source}); restart DSH or set dshUrl in the plugin config`,
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
    this.logger.debug?.(`mobile-link: authenticated with DSH at ${endpoint.base}`)
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
      json = await response.json()
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

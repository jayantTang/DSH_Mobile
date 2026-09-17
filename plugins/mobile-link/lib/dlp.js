/**
 * Pure DLP v1 helpers: frame codec, stream-id mapping, waterfall dedupe and
 * reconnect backoff. No sockets, no timers, no filesystem — everything here is
 * driven by `node --test` without a DSH instance.
 *
 * Wire contract: docs/RELAY-PROTOCOL.md §3.
 */

/** Frame ceiling aligned with DSH's image-attachment limit (spec §5). */
export const MAX_FRAME_BYTES = 32 * 1024 * 1024

export const DEVICE_TO_AGENT = new Set(['req', 'open', 'cancel', 'eventResult', 'ping', 'hello'])
export const AGENT_TO_DEVICE = new Set(['res', 'item', 'end', 'streamError', 'event', 'hostStatus', 'pong', 'error'])
/** Relay-internal control frames carrying device lifecycle (see relay/NOTES.md). */
export const RELAY_CONTROL = new Set(['deviceAttach', 'deviceDetach'])

const ID_FRAMES = new Set(['req', 'open', 'cancel', 'res', 'item', 'end', 'streamError', 'eventResult'])

export function encodeFrame(frame) {
  return JSON.stringify(frame)
}

/**
 * Decode one wire payload.
 * @returns the frame object, or `undefined` when the payload is unusable
 *          (not JSON, not an object, or missing a non-empty string `t`).
 */
export function decodeFrame(raw) {
  if (typeof raw !== 'string') return undefined
  if (raw.length > MAX_FRAME_BYTES) return undefined
  let value
  try {
    value = JSON.parse(raw)
  } catch {
    return undefined
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined
  if (typeof value.t !== 'string' || value.t.length === 0) return undefined
  return value
}

export function frameType(frame) {
  return typeof frame?.t === 'string' ? frame.t : ''
}

/** Structural check for one device -> agent frame; returns an error string or undefined. */
export function deviceFrameError(frame) {
  const kind = frameType(frame)
  if (!DEVICE_TO_AGENT.has(kind)) return undefined
  if (ID_FRAMES.has(kind) && !nonEmptyString(frame.id)) return `${kind}: missing \`id\``
  if (kind === 'req' && !nonEmptyString(frame.method)) return 'req: missing `method`'
  if (kind === 'open' && !nonEmptyString(frame.endpoint)) return 'open: missing `endpoint`'
  return undefined
}

export function nonEmptyString(value) {
  return typeof value === 'string' && value.length > 0
}

export function deviceIdOf(frame) {
  return nonEmptyString(frame?.deviceId) ? frame.deviceId : undefined
}

/**
 * Exponential backoff with ±jitter, capped (spec §4.2: 1s -> 2s -> ... -> 30s ±20%).
 * @param attempt zero-based retry index.
 */
export function nextBackoff(attempt, { baseMs = 1000, maxMs = 30000, jitter = 0.2, random = Math.random } = {}) {
  const exponent = Math.max(0, Math.min(30, Number(attempt) || 0))
  const raw = Math.min(maxMs, baseMs * 2 ** exponent)
  const spread = raw * jitter
  const offset = (random() * 2 - 1) * spread
  return Math.max(0, Math.round(raw + offset))
}

/**
 * Split a relay URL into its HTTP and WebSocket bases, keeping the path prefix.
 *
 * The relay is published under a path on an existing site, so the configured
 * base carries a prefix (`wss://relay.example.com/dsh-link`) that must be
 * *kept* when an endpoint is appended — never replaced. A trailing slash is
 * tolerated and normalised away. Accepts `wss://host`, `https://host/prefix`,
 * `ws://127.0.0.1:8787` and bare hosts.
 */
export function normalizeRelayUrl(raw) {
  const text = String(raw ?? '').trim()
  if (!text) throw new Error('relay URL is required')
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(text) ? text : `wss://${text}`
  const url = new URL(withScheme)
  const secure = url.protocol === 'wss:' || url.protocol === 'https:'
  if (!['ws:', 'wss:', 'http:', 'https:'].includes(url.protocol)) {
    throw new Error(`unsupported relay scheme ${url.protocol}`)
  }
  const authority = `${url.host}`
  const basePath = url.pathname.replace(/\/+$/, '')
  return {
    httpBase: `${secure ? 'https' : 'http'}://${authority}${basePath}`,
    wsBase: `${secure ? 'wss' : 'ws'}://${authority}${basePath}`,
    secure,
    authority,
  }
}

/**
 * The relay address the repository ships as a placeholder.
 *
 * It is a *sentinel*, not a deployment: a value equal to it means "no relay has
 * been configured here", never "dial relay.example.com". The distinction is
 * load-bearing — a configured placeholder used to outrank the identity already
 * enrolled in `agent.json`, so one DSH restart pointed an enrolled computer at
 * the placeholder *and* wrote that back over the real address, which left the
 * phone unable to connect until somebody noticed. Anything that resolves an
 * address has to recognise the sentinel.
 */
export const PLACEHOLDER_RELAY_URL = 'wss://relay.example.com/dsh-link'

/**
 * True when `raw` is, or normalises to, the repository placeholder — a trailing
 * slash or an `https://` spelling of the same address still counts.
 */
export function isPlaceholderRelayUrl(raw) {
  if (typeof raw !== 'string' || !raw.trim()) return false
  try {
    return normalizeRelayUrl(raw).wsBase === normalizeRelayUrl(PLACEHOLDER_RELAY_URL).wsBase
  } catch {
    return false
  }
}

/**
 * Join one endpoint onto a relay base without losing the base's path prefix.
 * `('wss://host/prefix/', '/link/agent')` -> `'wss://host/prefix/link/agent'`.
 */
export function joinRelayPath(base, suffix) {
  const head = String(base ?? '').replace(/\/+$/, '')
  const tail = String(suffix ?? '').replace(/^\/+/, '')
  return `${head}/${tail}`
}

/** The connector's relay endpoint, keeping any configured path prefix. */
export function agentEndpoint(relayUrl) {
  return joinRelayPath(normalizeRelayUrl(relayUrl).wsBase, 'link/agent')
}

/** The relay's pairing-code endpoint, keeping any configured path prefix. */
export function pairCodeEndpoint(relayUrl) {
  return joinRelayPath(normalizeRelayUrl(relayUrl).httpBase, 'pair/code')
}

/** The relay's self-service enrollment endpoint (`POST /agents/enroll`). */
export function enrollEndpoint(relayUrl) {
  return joinRelayPath(normalizeRelayUrl(relayUrl).httpBase, 'agents/enroll')
}

/**
 * The `dsh://pair?relay=<relay>&code=<code>` deep link the desktop shows and
 * the iOS app scans. `relay` keeps the full path prefix so the phone can reach
 * `/pair/claim` and `/link/device` under exactly the same base.
 */
export function qrPayload({ relay, code }) {
  const params = new URLSearchParams({ relay: String(relay), code: String(code) })
  return `dsh://pair?${params.toString()}`
}

/**
 * DLP id <-> mux streamId mapping. One mux stream per (device, DLP stream) so
 * two devices can both call their stream `"2"` without colliding.
 */
export class StreamTable {
  constructor() {
    /** @type {Map<string, {deviceId: string, dlpId: string, muxId: string, endpoint: string}>} */
    this.byMux = new Map()
    /** @type {Map<string, string>} `${deviceId}\u0000${dlpId}` -> muxId */
    this.byDlp = new Map()
  }

  static key(deviceId, dlpId) {
    return `${deviceId}\u0000${dlpId}`
  }

  /** @returns {boolean} false when this device already owns that DLP id. */
  add({ deviceId, dlpId, muxId, endpoint }) {
    if (this.byDlp.has(StreamTable.key(deviceId, dlpId))) return false
    this.byMux.set(muxId, { deviceId, dlpId, muxId, endpoint })
    this.byDlp.set(StreamTable.key(deviceId, dlpId), muxId)
    return true
  }

  muxOf(deviceId, dlpId) {
    return this.byDlp.get(StreamTable.key(deviceId, dlpId))
  }

  entryOfMux(muxId) {
    return this.byMux.get(muxId)
  }

  /** Remove one (device, DLP) pair; returns its mux streamId when it existed. */
  removeByDlp(deviceId, dlpId) {
    const key = StreamTable.key(deviceId, dlpId)
    const muxId = this.byDlp.get(key)
    if (muxId === undefined) return undefined
    this.byDlp.delete(key)
    this.byMux.delete(muxId)
    return muxId
  }

  /** Remove one mux stream; returns its entry when it existed. */
  removeByMux(muxId) {
    const entry = this.byMux.get(muxId)
    if (entry === undefined) return undefined
    this.byMux.delete(muxId)
    this.byDlp.delete(StreamTable.key(entry.deviceId, entry.dlpId))
    return entry
  }

  /** Every mux streamId owned by one device (used when it disconnects). */
  removeDevice(deviceId) {
    const removed = []
    for (const entry of [...this.byMux.values()]) {
      if (entry.deviceId === deviceId) {
        removed.push(entry.muxId)
        this.byMux.delete(entry.muxId)
        this.byDlp.delete(StreamTable.key(entry.deviceId, entry.dlpId))
      }
    }
    return removed
  }

  get size() {
    return this.byMux.size
  }
}

/**
 * First-answer-wins bookkeeping for `$events` waterfalls (spec §4.1.6).
 *
 * `claim` reserves an event synchronously so two devices answering at the same
 * moment cannot both reach `$events/result`; `release` hands it back when the
 * reservation failed to produce a delivered answer.
 */
export class WaterfallDedupe {
  constructor({ ttlMs = 5 * 60 * 1000, now = Date.now } = {}) {
    this.ttlMs = ttlMs
    this.now = now
    /** @type {Map<string, number>} eventId -> claimedAt */
    this.claimed = new Map()
  }

  /** @returns {boolean} true when this caller won the right to answer. */
  claim(eventId) {
    if (!nonEmptyString(eventId)) return false
    this.prune()
    if (this.claimed.has(eventId)) return false
    this.claimed.set(eventId, this.now())
    return true
  }

  release(eventId) {
    this.claimed.delete(eventId)
  }

  has(eventId) {
    return this.claimed.has(eventId)
  }

  prune(at = this.now()) {
    for (const [eventId, claimedAt] of this.claimed) {
      if (at - claimedAt > this.ttlMs) this.claimed.delete(eventId)
    }
  }

  get size() {
    return this.claimed.size
  }
}

/** `{t:'pong', ts}` for a device/relay heartbeat, preserving `ts` verbatim. */
export function pongFor(frame) {
  return { t: 'pong', ts: frame?.ts }
}

/** `{t:'res', ...}` mapped from a DSH `RemoteResult` (`{ok,value}|{ok:false,error}`). */
export function resultFrame(dlpId, result, deviceId) {
  const base = { t: 'res', id: dlpId, deviceId }
  if (result && result.ok === true) return { ...base, ok: true, value: result.value }
  const error = result?.error
  return {
    ...base,
    ok: false,
    error: {
      code: nonEmptyString(error?.code) ? error.code : 'gateway/failed',
      message: nonEmptyString(error?.message) ? error.message : 'DSH request failed',
      details: error && typeof error.details === 'object' && error.details !== null ? error.details : {},
    },
  }
}

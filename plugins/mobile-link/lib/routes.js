/**
 * HTTP routes under `/mobile-link`, registered on DSH's own web server.
 *
 *   GET  /mobile-link/status     connection + device inventory + setup state
 *   POST /mobile-link/pair-code  mint a pairing code (and its QR payload + SVG)
 *
 * All sit behind DSH's own request fence, like every other plugin route:
 * `ctx.get('connection')?.requestRejection?.(req)` performs the Host/Origin check
 * and browser authentication. `/status` stays readable when the fence service is
 * missing (it is diagnostic); the other two mint a credential, so they fail
 * closed.
 */

import { qrSvg } from './qr.js'

const MAX_BODY_BYTES = 64 * 1024

export function sendJson(res, status, payload) {
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(JSON.stringify(payload))
}

export async function readJsonBody(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.byteLength
    if (size > MAX_BODY_BYTES) {
      req.resume()
      return undefined
    }
    chunks.push(chunk)
  }
  if (size === 0) return {}
  try {
    return JSON.parse(Buffer.concat(chunks, size).toString('utf8'))
  } catch {
    return undefined
  }
}

/**
 * @returns {boolean} true when the request was rejected and the response ended.
 */
export function makeGuard(ctx, logger) {
  const connectionOf = () => (typeof ctx.get === 'function' ? ctx.get('connection') : undefined)
  return function guard(req, res, { requireFence = false } = {}) {
    const connection = connectionOf()
    const fence = connection?.requestRejection
    // DSH's contract is "a status when refused, **undefined** when the request
    // may proceed" — so undefined is a pass, not an absence. Reading it as an
    // absence is what made every privileged route below answer 403 to everyone
    // with a perfectly authenticated request: the pairing page and
    // `POST /pair-code` never got past the guard. The service's own presence is
    // the only thing that can tell "no fence to consult" apart from "fence says
    // yes", so that is what is checked here.
    if (typeof fence !== 'function') {
      if (requireFence) {
        sendJson(res, 403, { ok: false, message: 'the DSH connection service is unavailable; refusing a privileged request' })
        return true
      }
      return false
    }
    let rejection
    try {
      rejection = fence.call(connection, req)
    } catch (error) {
      logger.warn?.(`mobile-link: request fence failed: ${error}`)
      sendJson(res, 403, { ok: false, message: 'request rejected by the DSH fence' })
      return true
    }
    if (rejection !== undefined && rejection !== null) {
      res.statusCode = Number(rejection) || 403
      res.end()
      return true
    }
    return false
  }
}

function ttlFrom(value, fallbackMs) {
  return Number.isFinite(Number(value)) && Number(value) > 0
    ? Math.min(Number(value), 60 * 60 * 1000)
    : fallbackMs
}

/** Map an enrollment error code onto the HTTP status the panel sees. */
export function enrollStatus(code) {
  switch (code) {
    case 'enroll/already-registered':
    case 'enroll/disabled':
      return 409
    case 'enroll/timeout':
      return 504
    case 'enroll/rate-limited':
      return 429
    case 'enroll/state-write':
    case 'enroll/internal':
      return 500
    case 'enroll/bad-request':
    case 'enroll/invalid-relay':
    case 'enroll/placeholder-relay':
    case 'enroll/unknown':
    case 'enroll/used':
    case 'enroll/expired':
      return 400
    default:
      return 502
  }
}

/**
 * Register the routes.
 * @returns {Array<() => void>} disposers (already wrapped by the caller in ctx.effect).
 */
export function registerMobileLinkRoutes(ctx, { agent, logger, config = {}, history }) {
  const guard = makeGuard(ctx, logger)
  const STATUS_ROUTE = '/mobile-link/status'
  const ENROLL_ROUTE = '/mobile-link/enroll'
  const PAIR_ROUTE = '/mobile-link/pair-code'
  const REGENERATE_ROUTE = '/mobile-link/pair-code/regenerate'
  const disposers = []

  disposers.push(ctx.webServer.register({
    kind: 'exact',
    path: STATUS_ROUTE,
    handler: async (req, res) => {
      if (guard(req, res)) return
      if (req.method !== 'GET') {
        res.statusCode = 405
        res.setHeader('allow', 'GET')
        res.end()
        return
      }
      try {
        sendJson(res, 200, agent.status())
      } catch (error) {
        sendJson(res, 500, { ok: false, message: String(error?.message ?? error) })
      }
    },
  }))

  disposers.push(ctx.webServer.register({
    kind: 'exact',
    path: ENROLL_ROUTE,
    handler: async (req, res) => {
      if (guard(req, res, { requireFence: true })) return
      if (req.method !== 'POST') {
        res.statusCode = 405
        res.setHeader('allow', 'POST')
        res.end()
        return
      }
      const body = await readJsonBody(req)
      if (body === undefined) {
        sendJson(res, 400, { ok: false, code: 'enroll/bad-request', message: 'invalid JSON body' })
        return
      }
      const relayUrl = typeof body.relayUrl === 'string' ? body.relayUrl.trim() : ''
      const inviteCode = typeof body.inviteCode === 'string' ? body.inviteCode.trim() : ''
      const agentName = typeof body.agentName === 'string' ? body.agentName.trim() : ''
      if (!relayUrl || !inviteCode) {
        sendJson(res, 400, {
          ok: false,
          code: 'enroll/bad-request',
          message: 'relayUrl and inviteCode are required',
        })
        return
      }
      try {
        const settled = await agent.enroll({ inviteCode, relayUrl, agentName: agentName || undefined })
        logger.info?.(`mobile-link: panel enrollment succeeded for ${settled.agentId}`)
        // Never return `agentSecret`: the browser has no use for it, and one
        // XSS in the panel would otherwise hand over the machine's credential.
        sendJson(res, 200, {
          ok: true,
          agentId: settled.agentId,
          agentName: settled.agentName,
          relayUrl: settled.relayUrl,
        })
      } catch (error) {
        // Read the code off the error rather than using `instanceof`: a hot
        // reload can leave the route and the link on different module
        // generations, and an identity check would then downgrade a precise
        // "already registered" into a generic 500.
        const code = typeof error?.code === 'string' && error.code.startsWith('enroll/')
          ? error.code
          : 'enroll/internal'
        const status = enrollStatus(code)
        if (code === 'enroll/internal') {
          logger.warn?.(`mobile-link: panel enrollment failed: ${String(error?.message ?? error)}`)
        }
        sendJson(res, status, { ok: false, code, message: String(error?.message ?? error) })
      }
    },
  }))

  disposers.push(ctx.webServer.register({
    kind: 'exact',
    path: PAIR_ROUTE,
    handler: async (req, res) => {
      if (guard(req, res, { requireFence: true })) return
      if (req.method !== 'POST') {
        res.statusCode = 405
        res.setHeader('allow', 'POST')
        res.end()
        return
      }
      const body = await readJsonBody(req)
      if (body === undefined) {
        sendJson(res, 400, { ok: false, message: 'invalid JSON body' })
        return
      }
      // 032：调用方**没提** ttlMs 就要一张持久码（面板走这条路）；显式给了才限时，
      // 那是老行为，留给还在用的调用方。
      const wantsTtl = Object.prototype.hasOwnProperty.call(body, 'ttlMs')
      const ttlMs = wantsTtl ? ttlFrom(body.ttlMs, Number(config.pairTtlMs) || 10 * 60 * 1000) : null
      try {
        const minted = await agent.mintPairCode({ ttlMs })
        logger.info?.(`mobile-link: minted a ${minted.persistent ? 'persistent' : 'time-limited'}`
          + ` pairing code for ${minted.agentId}`)
        // The picture travels with the code. It used to be a route of its own
        // (`GET /mobile-link/qr`) that a person opened in a browser; the pairing
        // entry is now the connector's own panel in the DSH client, so the one
        // caller left is that panel, and it wants the code and the symbol in the
        // same answer. No caption: the panel runs its own countdown, and a
        // server-rendered "还剩 N 分钟" freezes the moment the window is up.
        sendJson(res, 200, { ok: true, ...minted, svg: qrSvg(minted.qrPayload) })
      } catch (error) {
        sendJson(res, 502, { ok: false, code: 'relay/unavailable', message: String(error?.message ?? error) })
      }
    },
  }))

  disposers.push(ctx.webServer.register({
    kind: 'exact',
    path: REGENERATE_ROUTE,
    handler: async (req, res) => {
      if (guard(req, res, { requireFence: true })) return
      if (req.method !== 'POST') {
        res.statusCode = 405
        res.setHeader('allow', 'POST')
        res.end()
        return
      }
      const body = await readJsonBody(req)
      if (body === undefined) {
        sendJson(res, 400, { ok: false, message: 'invalid JSON body' })
        return
      }
      try {
        const minted = await agent.regeneratePairCode()
        logger.info?.(`mobile-link: regenerated the pairing code for ${minted.agentId}`
          + ` (revoked ${minted.revoked})`)
        sendJson(res, 200, { ok: true, ...minted, svg: qrSvg(minted.qrPayload) })
      } catch (error) {
        sendJson(res, 502, { ok: false, code: 'relay/unavailable', message: String(error?.message ?? error) })
      }
    },
  }))

  return disposers
}

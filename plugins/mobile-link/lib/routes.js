/**
 * HTTP routes under `/mobile-link`, registered on DSH's own web server.
 *
 *   GET  /mobile-link/status     connection + device inventory + setup state
 *   POST /mobile-link/pair-code  mint a pairing code (and its QR payload)
 *   GET  /mobile-link/qr         mint a pairing code and render it as a QR SVG
 *
 * All sit behind DSH's own request fence, exactly like dsh-plugin-desktop-shell:
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

export function sendSvg(res, status, svg) {
  res.statusCode = status
  res.setHeader('content-type', 'image/svg+xml; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(svg)
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
    let rejection
    try {
      rejection = connectionOf()?.requestRejection?.(req)
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
    if (requireFence && rejection === undefined) {
      sendJson(res, 403, { ok: false, message: 'the DSH connection service is unavailable; refusing a privileged request' })
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

/**
 * Register the routes.
 * @returns {Array<() => void>} disposers (already wrapped by the caller in ctx.effect).
 */
export function registerMobileLinkRoutes(ctx, { agent, logger, config = {} }) {
  const guard = makeGuard(ctx, logger)
  const STATUS_ROUTE = '/mobile-link/status'
  const PAIR_ROUTE = '/mobile-link/pair-code'
  const QR_ROUTE = '/mobile-link/qr'
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
      const ttlMs = ttlFrom(body.ttlMs, Number(config.pairTtlMs) || 10 * 60 * 1000)
      try {
        const minted = await agent.mintPairCode({ ttlMs })
        logger.info?.(`mobile-link: minted a pairing code for ${minted.agentId}`)
        sendJson(res, 200, { ok: true, ...minted })
      } catch (error) {
        sendJson(res, 502, { ok: false, code: 'relay/unavailable', message: String(error?.message ?? error) })
      }
    },
  }))

  // The QR a phone camera can actually read. Rendered here rather than in the
  // desktop UI so the pairing screen is one URL: anyone can open
  // `http://127.0.0.1:<port>/mobile-link/qr` (with DSH's own authentication)
  // and see a scannable code, with no client-side work and no extra dependency.
  //
  // `?format=json` returns the payload and the code without the picture, which
  // is what the automated tests use.
  disposers.push(ctx.webServer.register({
    kind: 'exact',
    path: QR_ROUTE,
    handler: async (req, res) => {
      if (guard(req, res, { requireFence: true })) return
      if (req.method !== 'GET') {
        res.statusCode = 405
        res.setHeader('allow', 'GET')
        res.end()
        return
      }
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      const ttlMs = ttlFrom(url.searchParams.get('ttlMs'), Number(config.pairTtlMs) || 10 * 60 * 1000)
      let minted
      try {
        minted = await agent.mintPairCode({ ttlMs })
      } catch (error) {
        sendJson(res, 502, { ok: false, code: 'relay/unavailable', message: String(error?.message ?? error) })
        return
      }
      const payload = minted.qrPayload
      const wantsJson = (url.searchParams.get('format') ?? '').toLowerCase() === 'json'
      logger.info?.(`mobile-link: rendered a pairing QR for ${minted.agentId}`)
      if (wantsJson) {
        sendJson(res, 200, { ok: true, ...minted, svg: qrSvg(payload) })
        return
      }
      sendSvg(res, 200, qrSvg(payload))
    },
  }))

  return disposers
}

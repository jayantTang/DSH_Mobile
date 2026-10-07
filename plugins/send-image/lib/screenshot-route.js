/**
 * `POST /send-image/screenshot` —— 用户按 ⌃⌘A（或点输入区按钮）时走的那条路。
 *
 * 契约见 `specs/002-screenshot-hotkey/contracts/screenshot-endpoint.md`：
 *   成功 → `200 image/png`（客户端据此构造 File 交给附件栏，**不发送**）
 *   其它 → `200 application/json { kind, message? }`（客户端按 kind 决定静默还是提示）
 *
 * 鉴权沿用 DSH 自己的请求围栏（`connection.requestRejection`：Host/Origin 校验 + 浏览器认证）。
 * 围栏服务缺失时**失败关闭**：这条路由会真的去截用户的屏幕，不能在拿不到围栏时放行。
 */

import { readFileSync } from 'node:fs'
import { capture } from './capture.js'

const MAX_BODY_BYTES = 8 * 1024
export const SCREENSHOT_ROUTE = '/send-image/screenshot'

function sendJson(res, status, payload) {
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(JSON.stringify(payload))
}

async function readJsonBody(req) {
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

function makeGuard(ctx, logger) {
  const connectionOf = () => (typeof ctx.get === 'function' ? ctx.get('connection') : undefined)
  return function guard(req, res) {
    let rejection
    try {
      rejection = connectionOf()?.requestRejection?.(req)
    } catch (error) {
      logger?.warn?.(`send-image: request fence failed: ${error}`)
      sendJson(res, 403, { kind: 'failed', message: '请求被 DSH 的围栏拒绝' })
      return true
    }
    if (rejection !== undefined && rejection !== null) {
      res.statusCode = Number(rejection) || 403
      res.end()
      return true
    }
    if (rejection === undefined) {
      sendJson(res, 403, {
        kind: 'failed',
        message: 'DSH 的连接服务不可用，拒绝这次截屏请求',
      })
      return true
    }
    return false
  }
}

/**
 * 注册路由。
 * @returns {() => void} disposer（调用方用 ctx.effect 托管）
 */
/** 处理一次截图请求：先过围栏，再取图，最后按契约回 PNG 或分类 JSON。 */
async function handleScreenshot(req, res, { guard, captureFn, logger }) {
  if (guard(req, res)) return
  if (req.method !== 'POST') {
    res.statusCode = 405
    res.setHeader('allow', 'POST')
    res.end()
    return
  }
  const body = await readJsonBody(req)
  if (body === undefined) {
    sendJson(res, 400, { kind: 'failed', message: '请求体不是合法 JSON' })
    return
  }
  const sessionId = typeof body.sessionId === 'string' ? body.sessionId : ''
  if (!sessionId) {
    sendJson(res, 200, { kind: 'no-session', message: '先打开一个会话再截图。' })
    return
  }

  let result
  try {
    result = await captureFn({})
  } catch (error) {
    logger?.warn?.(`send-image: capture failed: ${error}`)
    sendJson(res, 200, { kind: 'failed', message: `截屏失败：${error?.message ?? error}` })
    return
  }

  if (result?.kind === 'ok' && result.path) {
    let bytes
    try {
      bytes = readFileSync(result.path)
    } catch (error) {
      logger?.warn?.(`send-image: screenshot vanished: ${error}`)
      sendJson(res, 200, { kind: 'failed', message: '截图文件在读取前消失了，请再试一次。' })
      return
    }
    res.statusCode = 200
    res.setHeader('content-type', 'image/png')
    res.setHeader('cache-control', 'no-store')
    res.setHeader('x-dsh-screenshot', result.path)
    res.end(bytes)
    return
  }

  sendJson(res, 200, { kind: result?.kind ?? 'failed', message: result?.message })
}

/**
 * 注册路由。
 * @returns {() => void} disposer（调用方用 ctx.effect 托管）
 */
export function registerScreenshotRoute(ctx, { logger, captureFn = capture } = {}) {
  const guard = makeGuard(ctx, logger)
  return ctx.webServer.register({
    kind: 'exact',
    path: SCREENSHOT_ROUTE,
    handler: (req, res) => handleScreenshot(req, res, { guard, captureFn, logger }),
  })
}

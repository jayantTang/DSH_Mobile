/**
 * Minimal Chrome DevTools Protocol client for the Doubao desktop app.
 *
 * Doubao ships a full Chromium (`Contents/Helpers/Doubao Browser.app`) and its
 * main binary forwards unknown flags to it, so `--remote-debugging-port=<n>`
 * gives us a real CDP endpoint. That is the whole reason this plugin can drive
 * Doubao without the macOS Accessibility permission `osascript` would need.
 *
 * Deliberately dependency-free: a browser-level HTTP discovery call plus one
 * WebSocket per page target, built on Node's own `fetch` and the `ws` package
 * that DSH already ships.
 */

import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { requireFromDsh } from './dsh-install.mjs'

/**
 * Resolve `ws` from the DSH install, since this plugin has no node_modules.
 * The anchor ladder (and the `DSH_INSTALL_DIR` override) lives in dsh-install.mjs.
 */
function loadWebSocket() {
  const loaded = requireFromDsh('ws')
  const ctor = loaded?.WebSocket ?? loaded
  if (typeof ctor !== 'function') {
    throw new Error('找不到 ws 模块（DSH 安装目录解析失败；可用 DSH_INSTALL_DIR 指定）')
  }
  return ctor
}

let WebSocketImpl
function WebSocketCtor() {
  if (!WebSocketImpl) WebSocketImpl = loadWebSocket()
  return WebSocketImpl
}

/** The CDP HTTP discovery endpoint for a given port. */
export function endpoint(port, path = '/json/version') {
  return `http://127.0.0.1:${port}${path}`
}

/**
 * Whether a CDP endpoint is already answering on this port.
 *
 * A running Doubao that was started *normally* does NOT answer here: Doubao
 * holds a singleton lock, so a second launch with the debug flag just hands the
 * request to the existing instance and the port never opens. Callers must treat
 * "false while Doubao is running" as "needs a relaunch", not as an error.
 */
export async function probe(port, timeoutMs = 1500) {
  try {
    const res = await fetch(endpoint(port), { signal: AbortSignal.timeout(timeoutMs) })
    if (!res.ok) return null
    const version = await res.json()
    return typeof version?.webSocketDebuggerUrl === 'string' ? version : null
  } catch {
    return null
  }
}

/** Every page target the browser exposes. */
export async function targets(port, timeoutMs = 4000) {
  const res = await fetch(endpoint(port, '/json/list'), { signal: AbortSignal.timeout(timeoutMs) })
  if (!res.ok) throw new Error(`CDP /json/list 返回 ${res.status}`)
  const list = await res.json()
  return Array.isArray(list) ? list : []
}

/**
 * A single page target over one WebSocket.
 *
 * `send` resolves with the CDP `result`, or rejects with the protocol error —
 * a page that navigates away mid-call is a normal occurrence here, so callers
 * are expected to catch and retry rather than treat it as fatal.
 */
export class PageSession {
  #ws
  #nextId = 1
  #pending = new Map()
  #closed = false

  constructor(ws) {
    this.#ws = ws
    ws.on('message', (raw) => {
      let msg
      try {
        msg = JSON.parse(raw.toString())
      } catch {
        return
      }
      const entry = this.#pending.get(msg.id)
      if (!entry) return
      this.#pending.delete(msg.id)
      if (msg.error) entry.reject(new Error(`${msg.error.message ?? 'CDP 错误'} (code ${msg.error.code})`))
      else entry.resolve(msg.result)
    })
    ws.on('close', () => {
      this.#closed = true
      for (const [, entry] of this.#pending) entry.reject(new Error('CDP 连接已关闭'))
      this.#pending.clear()
    })
    ws.on('error', (error) => {
      this.#closed = true
      for (const [, entry] of this.#pending) entry.reject(error)
      this.#pending.clear()
    })
  }

  get closed() {
    return this.#closed
  }

  static async open(webSocketDebuggerUrl, timeoutMs = 8000) {
    const WebSocket = WebSocketCtor()
    const ws = new WebSocket(webSocketDebuggerUrl, { perMessageDeflate: false })
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('连接 CDP WebSocket 超时')), timeoutMs)
      ws.once('open', () => {
        clearTimeout(timer)
        resolve()
      })
      ws.once('error', (error) => {
        clearTimeout(timer)
        reject(error)
      })
    })
    return new PageSession(ws)
  }

  send(method, params = {}) {
    if (this.#closed) return Promise.reject(new Error('CDP 连接已关闭'))
    const id = this.#nextId++
    return new Promise((resolve, reject) => {
      this.#pending.set(id, { resolve, reject })
      this.#ws.send(JSON.stringify({ id, method, params }))
    })
  }

  /**
   * Evaluate an expression in the page and return its value.
   *
   * `awaitPromise` is on because every probe here is an async IIFE (a fetch, a
   * settle loop); a rejected promise surfaces as a thrown Error carrying the
   * page-side message, which is the only debugging signal available.
   */
  async evaluate(expression, { awaitPromise = true, timeoutMs = 60_000 } = {}) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise,
      timeout: timeoutMs,
    })
    if (result?.exceptionDetails) {
      const detail =
        result.exceptionDetails.exception?.description ??
        result.exceptionDetails.text ??
        '页面内脚本抛错'
      throw new Error(String(detail).split('\n')[0])
    }
    return result?.result?.value
  }

  close() {
    try {
      this.#ws.close()
    } catch {
      /* already gone */
    }
  }
}

/**
 * Attach to the Doubao chat window — the one target that carries the real UI.
 *
 * Doubao exposes several pages and the obvious pick is the wrong one:
 *
 * - `doubao-background` is declared "不可见的页面" (an invisible page).
 * - `doubao-launcher` is a 400x600 sidebar strip. It *does* contain a
 *   ProseMirror editor and *does* answer prompts, which makes it a convincing
 *   trap: driving it produces generated results rendered at 90x135 in a
 *   sidebar, and the results grid never reaches full size.
 * - `doubao-chat` is the real 1200x800 chat window. This is the one to drive.
 *
 * The window is identified by URL, and the size check is a second gate so a
 * future reordering cannot silently put us back on a sidebar.
 */
export async function attachLauncher(port, { retries = 15, delayMs = 600 } = {}) {
  let lastError
  for (let attempt = 0; attempt < retries; attempt++) {
    try {
      const list = await targets(port)
      const pages = list.filter((t) => t.type === 'page' && typeof t.webSocketDebuggerUrl === 'string')
      const ordered = [
        ...pages.filter((t) => t.url.includes('doubao-chat')),
        ...pages.filter(
          (t) => !t.url.includes('doubao-chat') && !t.url.includes('doubao-background') && !t.url.includes('doubao-launcher'),
        ),
        ...pages.filter((t) => t.url.includes('doubao-launcher')),
      ]
      for (const candidate of ordered) {
        const session = await PageSession.open(candidate.webSocketDebuggerUrl)
        const probeResult = await session
          .evaluate(
            `JSON.stringify({
               w: window.innerWidth,
               h: window.innerHeight,
               editor: document.querySelectorAll('[contenteditable=true]').length,
               text: (document.body ? document.body.innerText : '').length,
             })`,
            { timeoutMs: 10_000 },
          )
          .then((raw) => JSON.parse(raw))
          .catch(() => null)
        session.close()
        if (!probeResult) continue
        // A real chat window is wide, has the ProseMirror editor, and carries
        // sidebar content. The `doubao-chat` URL is also served as an empty
        // `<html>hello</html>` shell, so URL alone is not enough to identify it.
        const real = probeResult.w >= 700 && probeResult.editor > 0 && probeResult.text > 80
        if (real) {
          const attached = await PageSession.open(candidate.webSocketDebuggerUrl)
          return { session: attached, target: candidate, width: probeResult.w, height: probeResult.h }
        }
      }
    } catch (error) {
      lastError = error
    }
    await sleep(delayMs)
  }
  throw new Error(
    `连不上豆包聊天窗口（CDP ${port}）${lastError ? `：${lastError.message}` : '：没有合适尺寸的页面'}`,
  )
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/** Where the Doubao app bundle lives, if it is installed. */
export function doubaoAppPath(override) {
  const candidates = [
    override,
    '/Applications/Doubao.app',
    join(process.env.HOME ?? '', 'Applications', 'Doubao.app'),
  ].filter(Boolean)
  return candidates.find((path) => existsSync(join(path, 'Contents', 'MacOS', 'Doubao'))) ?? null
}

/** The launchable binary inside the bundle. */
export function doubaoBinary(appPath) {
  return join(appPath, 'Contents', 'MacOS', 'Doubao')
}

export { dirname }

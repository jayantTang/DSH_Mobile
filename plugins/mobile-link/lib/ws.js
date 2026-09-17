/**
 * A tiny WebSocket adapter.
 *
 * DSH runs on modern Node, where `globalThis.WebSocket` exists and accepts a
 * non-standard `{ headers }` option — that is what carries the DLP bearer token
 * without putting it in the URL. When the global is missing we fall back to the
 * `ws` package resolved from the DSH install. Everything above this file only
 * sees `send` / `close` / `onMessage` / `onClose` / `onError`, so a future
 * transport swap stays local.
 */

import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'

export class SocketError extends Error {}

let cachedFactory

function candidateAnchors() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  const anchors = [import.meta.url]
  anchors.push(join(home, 'profiles', 'web', 'package.json'))
  anchors.push(join(dirname(fileURLToPath(import.meta.url)), '..', 'package.json'))
  if (process.argv[1]) anchors.push(process.argv[1])
  return anchors
}

/** Resolve a WebSocket constructor, or throw with an actionable message. */
export function resolveWebSocket() {
  if (cachedFactory) return cachedFactory
  if (typeof globalThis.WebSocket === 'function') {
    cachedFactory = globalThis.WebSocket
    return cachedFactory
  }
  for (const anchor of candidateAnchors()) {
    try {
      const require = createRequire(anchor)
      const loaded = require('ws')
      const Ctor = loaded?.WebSocket ?? loaded
      if (typeof Ctor === 'function') {
        cachedFactory = Ctor
        return cachedFactory
      }
    } catch {
      /* try the next anchor */
    }
  }
  throw new SocketError(
    'no WebSocket implementation available: DSH mobile-link needs Node >= 22 (global WebSocket) or the `ws` package',
  )
}

function isEventTargetStyle(socket) {
  return typeof socket.addEventListener === 'function' && typeof socket.removeEventListener === 'function'
}

export class WebSocketHandle {
  constructor(socket) {
    this.socket = socket
    this.closed = false
    this.closeCode = undefined
    this.closeReason = undefined
    this._messageHandlers = []
    this._closeHandlers = []
    this._errorHandlers = []
    this._opened = new Promise((resolve, reject) => {
      this._resolveOpen = resolve
      this._rejectOpen = reject
    })
    this._opened.catch(() => {})
    this._attach()
  }

  _attach() {
    const socket = this.socket
    if (isEventTargetStyle(socket)) {
      socket.addEventListener('open', () => this._resolveOpen())
      socket.addEventListener('message', (event) => {
        const data = event?.data
        if (typeof data === 'string') this._emitMessage(data)
        else if (data instanceof ArrayBuffer) this._emitMessage(Buffer.from(data).toString('utf8'))
        else if (ArrayBuffer.isView(data)) this._emitMessage(Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('utf8'))
        else this._emitMessage(undefined, true)
      })
      socket.addEventListener('close', (event) => this._finish(event?.code, event?.reason))
      socket.addEventListener('error', (event) => this._emitError(event?.error ?? new SocketError('websocket error')))
      return
    }
    socket.on('open', () => this._resolveOpen())
    socket.on('message', (data, isBinary) => {
      if (isBinary) this._emitMessage(undefined, true)
      else if (typeof data === 'string') this._emitMessage(data)
      else this._emitMessage(Buffer.from(data).toString('utf8'))
    })
    socket.on('close', (code, reason) => this._finish(code, reason === undefined ? undefined : String(reason)))
    socket.on('error', (error) => this._emitError(error instanceof Error ? error : new SocketError(String(error))))
    socket.on('unexpected-response', (_request, response) => {
      this._emitError(new SocketError(`relay rejected the upgrade with HTTP ${response?.statusCode}`))
    })
  }

  _emitMessage(text, binary = false) {
    for (const handler of [...this._messageHandlers]) {
      try {
        handler(text, binary)
      } catch {
        /* a handler must never break the socket loop */
      }
    }
  }

  _emitError(error) {
    for (const handler of [...this._errorHandlers]) handler(error)
    this._rejectOpen(error)
  }

  _finish(code, reason) {
    if (this.closed) return
    this.closed = true
    this.closeCode = code
    this.closeReason = reason
    this._rejectOpen(new SocketError(`websocket closed before opening (${code ?? 'unknown'})`))
    for (const handler of [...this._closeHandlers]) handler(code, reason)
  }

  /** @returns {Promise<void>} resolves once the upgrade completed. */
  opened(timeoutMs = 20000) {
    if (timeoutMs <= 0) return this._opened
    return Promise.race([
      this._opened,
      new Promise((_resolve, reject) => {
        const timer = setTimeout(
          () => reject(new SocketError(`websocket did not open within ${timeoutMs}ms`)),
          timeoutMs,
        )
        timer.unref?.()
        this._opened.then(() => clearTimeout(timer), () => clearTimeout(timer))
      }),
    ])
  }

  onMessage(handler) {
    this._messageHandlers.push(handler)
  }

  onClose(handler) {
    this._closeHandlers.push(handler)
  }

  onError(handler) {
    this._errorHandlers.push(handler)
  }

  send(text) {
    if (this.closed) throw new SocketError('websocket is closed')
    this.socket.send(text)
  }

  close(code = 1000, reason = '') {
    this.closed = true
    try {
      this.socket.close(code, reason)
    } catch {
      /* already gone */
    }
  }
}

/** Open a WebSocket and resolve once it is usable. */
export async function connect(url, { headers = {}, timeoutMs = 20000, impl } = {}) {
  const factory = impl ?? resolveWebSocket()
  let socket
  try {
    socket = new factory(url, { headers })
  } catch (error) {
    throw new SocketError(`cannot open ${url}: ${error instanceof Error ? error.message : error}`)
  }
  const handle = new WebSocketHandle(socket)
  await handle.opened(timeoutMs)
  return handle
}

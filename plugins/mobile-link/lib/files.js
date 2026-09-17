/**
 * Files the phone sends, staged on this computer.
 *
 * The Host has no upload endpoint — `workspaceFiles/*` is read-only and the
 * protocol's `{type:'file', receiptId}` part needs a receipt from an
 * `uploadFile` call that does not exist on this build. So the link carries the
 * bytes itself and writes them where the agent can read them with its ordinary
 * tools.
 *
 * The transfer rides the protocol's existing unary `req` frame, addressed to a
 * reserved method name the connector answers locally instead of forwarding, so
 * neither the relay nor the protocol needs to change.
 */

import { mkdirSync, writeFileSync, rmSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'

/** Reserved method names this module answers; never forwarded to the Host. */
export const FILE_BEGIN = '_link/fileBegin'
export const FILE_CHUNK = '_link/fileChunk'
export const FILE_END = '_link/fileEnd'

export function isFileMethod(method) {
  return method === FILE_BEGIN || method === FILE_CHUNK || method === FILE_END
}

/**
 * One in-flight transfer. Chunks are appended in order and the file only
 * appears at its final path once the end frame arrives, so a half-sent file is
 * never mistaken for a complete one.
 */
class Transfer {
  constructor({ sessionId, name, bytes }) {
    this.sessionId = sessionId
    this.name = basename(name || 'file')
    this.bytes = Number.isFinite(bytes) ? bytes : undefined
    this.parts = []
    this.received = 0
    this.expectedSeq = 0
    this.directory = join(homedir(), '.dsh', 'inbox', sessionId)
    mkdirSync(this.directory, { recursive: true, mode: 0o700 })
    this.staging = join(this.directory, `.${this.name}.part`)
  }

  append(seq, base64) {
    if (seq !== this.expectedSeq) {
      throw new Error(`chunk ${seq} arrived out of order (expected ${this.expectedSeq})`)
    }
    const buffer = Buffer.from(base64, 'base64')
    this.parts.push(buffer)
    this.received += buffer.length
    this.expectedSeq += 1
  }

  finish() {
    const body = Buffer.concat(this.parts)
    if (this.bytes !== undefined && body.length !== this.bytes) {
      throw new Error(`expected ${this.bytes} bytes but received ${body.length}`)
    }
    writeFileSync(this.staging, body, { mode: 0o600 })
    // Renamed only now: the final name means "complete".
    const final = join(this.directory, this.name)
    rmSync(final, { force: true })
    writeFileSync(final, body, { mode: 0o600 })
    rmSync(this.staging, { force: true })
    return { path: final, bytes: statSync(final).size }
  }

  dispose() {
    rmSync(this.staging, { force: true })
  }
}

/** Owns the transfers for one connector. */
export class FileInbox {
  #transfers = new Map()
  #logger

  constructor(logger) {
    this.#logger = logger
  }

  /** Answers one reserved call. Throws `Error` for the router to report. */
  handle(method, args = {}) {
    const transferId = String(args.transferId ?? '')
    if (!transferId) throw new Error('transferId is required')

    if (method === FILE_BEGIN) {
      const sessionId = String(args.sessionId ?? '')
      if (!sessionId) throw new Error('sessionId is required')
      this.#transfers.get(transferId)?.dispose()
      this.#transfers.set(
        transferId,
        new Transfer({ sessionId, name: args.name, bytes: Number(args.bytes) })
      )
      this.#logger.debug?.(`mobile-link: file transfer ${transferId} started for ${sessionId}`)
      return { accepted: true }
    }

    const transfer = this.#transfers.get(transferId)
    if (!transfer) throw new Error(`unknown transfer ${transferId}`)

    if (method === FILE_CHUNK) {
      transfer.append(Number(args.seq ?? 0), String(args.data ?? ''))
      return { received: transfer.received }
    }

    // FILE_END
    try {
      const done = transfer.finish()
      this.#logger.info?.(
        `mobile-link: file ${transfer.name} (${done.bytes} bytes) staged at ${done.path}`
      )
      return done
    } finally {
      transfer.dispose()
      this.#transfers.delete(transferId)
    }
  }

  /** Drops every in-flight transfer, e.g. when the link goes down. */
  clear() {
    for (const transfer of this.#transfers.values()) transfer.dispose()
    this.#transfers.clear()
  }
}

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

import { mkdirSync, openSync, closeSync, writeSync, renameSync, rmSync, statSync } from 'node:fs'
import { basename, join } from 'node:path'

import { dshHome } from './state.js'

/** Reserved method names this module answers; never forwarded to the Host. */
export const FILE_BEGIN = '_link/fileBegin'
export const FILE_CHUNK = '_link/fileChunk'
export const FILE_END = '_link/fileEnd'

export function isFileMethod(method) {
  return method === FILE_BEGIN || method === FILE_CHUNK || method === FILE_END
}

/**
 * 多久没有新分片就认定这次上传已经没人要了。
 *
 * 这个时限不是"请求超时"：正在慢慢传的上传每来一片就重新计时。它要解决的是
 * 一种**线上没有信号**的中断——relay 的 `PUT /files/up` 被手机掐掉之后，两个
 * 中转（Python 与 Go）都只在本地摘掉桥接，**不会给连接器发任何取消帧**，也不会
 * 断开 agent 的 WebSocket。连接器因此永远等不到下一次 `fsPutChunk`/`fsPutEnd`，
 * `.part` 的 fd 就一直开着（M8 文件联调实测）。
 *
 * 取值要能容下慢速链路：1 MiB 一片，即便链路慢到 100 KB/s 也约 10 秒一片；
 * 10 分钟的空档只可能是手机侧被系统挂起或请求早已死掉。真被清扫时，这次上传
 * 会以 `fsErr`/HTTP 错误明确失败，用户重传即可，不会静默写出半截文件。
 */
export const DEFAULT_TRANSFER_IDLE_MS = 10 * 60 * 1000

/** 空闲清扫的周期：只决定"最晚多久之后"释放，不决定"多久算空闲"。 */
export const DEFAULT_SWEEP_MS = 30 * 1000

/**
 * One in-flight transfer.
 *
 * Chunks are **appended to a staging file as they arrive**, so the memory a
 * transfer holds is one chunk, not the whole file. It used to accumulate every
 * chunk in an array and `Buffer.concat` at the end, which meant a 300 MB upload
 * needed 300 MB (plus the concatenation's copy) of RSS on this computer — fine
 * for the few-MB screenshots this path was written for, not fine for the large
 * files the background-URL-session path now sends through the same code.
 *
 * The final name only appears once the end frame has arrived and the byte count
 * checks out, so a half-sent file is never mistaken for a complete one.
 */
class Transfer {
  /** 注入的时钟；FileInbox 把它传给每次 Transfer，保证"空闲多久"只有一份口径。 */
  #now

  constructor({ sessionId, name, bytes, now = Date.now }) {
    this.sessionId = sessionId
    this.name = basename(name || 'file')
    this.bytes = Number.isFinite(bytes) ? bytes : undefined
    this.received = 0
    this.expectedSeq = 0
    // 认 `DSH_HOME`（不是写死 `~/.dsh`）：测试与验证都靠它隔离，
    // 混用两种口径会让隔离失效（宪法第 III 条）。
    this.directory = join(dshHome(), 'inbox', sessionId)
    mkdirSync(this.directory, { recursive: true, mode: 0o700 })
    this.staging = join(this.directory, `.${this.name}.part`)
    // 最后一次收到分片的时刻（空闲清扫用）。时钟由 FileInbox 注入，测试里可精确推进。
    this.#now = now
    this.lastActivityAt = now()
    // 释放只能发生一次：fd 与 `.part` 是同一份资源的两个面，重复释放要么是空操作、
    // 要么会删到别人刚建好的同路径文件（重传接管时正好是这种情况）。
    this.released = false
    // Opened once and kept: reopening per chunk would be a syscall per chunk for
    // no benefit. `w` truncates, which is what a retried transfer wants.
    this.fd = undefined
  }

  #handle() {
    if (this.fd === undefined) {
      rmSync(this.staging, { force: true })
      this.fd = openSync(this.staging, 'w', 0o600)
    }
    return this.fd
  }

  append(seq, base64) {
    if (seq !== this.expectedSeq) {
      throw new Error(`chunk ${seq} arrived out of order (expected ${this.expectedSeq})`)
    }
    const buffer = Buffer.from(base64, 'base64')
    writeSync(this.#handle(), buffer)
    this.received += buffer.length
    this.expectedSeq += 1
    this.lastActivityAt = this.#now()
  }

  finish() {
    if (this.bytes !== undefined && this.received !== this.bytes) {
      throw new Error(`expected ${this.bytes} bytes but received ${this.received}`)
    }
    this.#close()
    // Renamed only now: the final name means "complete".
    const final = join(this.directory, this.name)
    rmSync(final, { force: true })
    renameSync(this.staging, final)
    return { path: final, bytes: statSync(final).size }
  }

  #close() {
    if (this.fd === undefined) return
    try {
      closeSync(this.fd)
    } finally {
      this.fd = undefined
    }
  }

  /**
   * 放弃这次上传：关句柄、删暂存文件，幂等。
   *
   * **只碰 `.part`**：`finish()` 已把暂存改名成成品，这里再调一次也只是对一个
   * 不存在的暂存路径做 no-op，成品不会被误删（`已完成的文件不会被清理路径误删` 用例守着）。
   */
  dispose() {
    if (this.released) return
    this.released = true
    this.#close()
    rmSync(this.staging, { force: true })
  }
}

/** Owns the transfers for one connector. */
export class FileInbox {
  #transfers = new Map()
  #logger
  #idleMs
  #now
  #sweeper

  /**
   * @param {object} [logger]
   * @param {object} [options]
   * @param {number} [options.idleMs] 多久没有新分片算"没人要了"
   * @param {number} [options.sweepMs] 空闲清扫周期
   * @param {() => number} [options.now] 注入时钟（测试用；生产就是 `Date.now`）
   */
  constructor(logger, {
    idleMs = DEFAULT_TRANSFER_IDLE_MS,
    sweepMs = DEFAULT_SWEEP_MS,
    now = Date.now,
  } = {}) {
    this.#logger = logger
    this.#idleMs = idleMs
    this.#now = now
    // 定时器是**兜底信号**：relay 从不为上传发取消帧，也不在上传中断时断开
    // agent 的 WebSocket，所以"再也不会来分片"只能由时间发现。`unref` 掉，
    // 别让一个空的收件箱按住进程退出（与 link.js / jobs-roster.js 同一口径）。
    this.#sweeper = setInterval(() => this.sweep(), Math.max(1, sweepMs))
    this.#sweeper.unref?.()
  }

  /**
   * 释放空闲超过 `idleMs` 的上传；返回本次释放的个数。
   *
   * 单独暴露是为了让测试给出确定时刻，而不是 sleep 等定时器；生产里由构造时
   * 安好的 interval 调用。
   */
  sweep(now = this.#now()) {
    let released = 0
    for (const [transferId, transfer] of this.#transfers) {
      const idle = now - transfer.lastActivityAt
      if (idle < this.#idleMs) continue
      this.#release(transferId, transfer)
      this.#logger.warn?.(
        `mobile-link: file transfer ${transferId} released after ${Math.round(idle / 1000)}s idle`,
      )
      released += 1
    }
    return released
  }

  /** 收掉一次在传上传；释放本身幂等，重复到达的取消/清扫都是空操作。 */
  #release(transferId, transfer) {
    transfer.dispose()
    this.#transfers.delete(transferId)
  }

  /** Answers one reserved call. Throws `Error` for the router to report. */
  handle(method, args = {}) {
    const transferId = String(args.transferId ?? '')
    if (!transferId) throw new Error('transferId is required')

    if (method === FILE_BEGIN) {
      const sessionId = String(args.sessionId ?? '')
      if (!sessionId) throw new Error('sessionId is required')
      const transfer = new Transfer({
        sessionId, name: args.name, bytes: Number(args.bytes), now: this.#now,
      })
      // 一条 `.part` 同时只能有一个写者。两种"重来"都要在这里把旧的收掉：
      // 同一个 bid 重来，以及手机换了新 bid 但落盘路径相同（中断后重传）。
      // 不收的话旧 fd 会一直握着一个已被 unlink 的 inode——M8 联调实测的泄漏。
      for (const [id, existing] of this.#transfers) {
        if (id === transferId || existing.staging === transfer.staging) {
          this.#release(id, existing)
        }
      }
      this.#transfers.set(transferId, transfer)
      this.#logger.debug?.(
        `mobile-link: file transfer ${transferId} started for ${sessionId}`,
      )
      return { accepted: true }
    }

    const transfer = this.#transfers.get(transferId)
    if (!transfer) throw new Error(`unknown transfer ${transferId}`)

    if (method === FILE_CHUNK) {
      try {
        transfer.append(Number(args.seq ?? 0), String(args.data ?? ''))
      } catch (error) {
        // 这一片已经给这次上传判了死（调用方随后回 `fsErr`）：句柄与 `.part`
        // 一起收掉，别等空闲清扫——它可能永远等不到下一次触发。
        this.#release(transferId, transfer)
        throw error
      }
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
      this.#release(transferId, transfer)
    }
  }

  /** 放弃一次上传（relay 的 `fsPutCancel`）。未知 id 是空操作，与 `fsGetCancel` 同口径。 */
  cancel(transferId) {
    const id = String(transferId ?? '')
    const transfer = this.#transfers.get(id)
    if (transfer) this.#release(id, transfer)
  }

  /** Drops every in-flight transfer, e.g. when the link goes down. */
  clear() {
    for (const [transferId, transfer] of this.#transfers) {
      this.#release(transferId, transfer)
    }
  }
}

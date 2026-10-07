/**
 * Files the phone pulls **from** this computer, over the relay's HTTP surface.
 *
 * The mirror of `files.js`. Same reason for existing: the phone cannot reach the
 * computer (this connector dials out and listens on loopback only), so the relay
 * terminates the HTTP request — but only this side can drive the Host's
 * `workspaceFiles/readBytes`. The relay pumps `GET /files/down`, this module
 * answers `fsGetBegin` with a run of `fsGetChunk` frames, and the relay writes
 * each one straight into the response body. **Nothing is stored anywhere in
 * between.**
 *
 * Why not just let the app use `workspaceFiles/readBytes` over WSS, as it does
 * today? Because a socket dies when iOS suspends the app, and a large download
 * the user started before pocketing the phone would die with it. A background
 * `URLSessionDownloadTask` is the only kind of transfer the system finishes on
 * the app's behalf — and that needs an HTTP endpoint.
 *
 * Two shapes worth stating, because both differ from `files.js`:
 *
 * * the reads are **pulled a window at a time** by this module rather than
 *   pushed at it, so a slow or vanished reader costs at most one window in
 *   flight; and
 * * the replies carry **no `deviceId`** (like `fsPut*`): the relay correlates by
 *   `bid` alone, and adding an addressing field would break that.
 */

/** Reserved frame types this module answers; see `docs/relay-contract.json`. */
export const FSGET_BEGIN = 'fsGetBegin'
export const FSGET_CHUNK = 'fsGetChunk'
export const FSGET_END = 'fsGetEnd'
/**
 * The relay's "stop reading for this run" frame.
 *
 * The pull side can end without the connector ever noticing: the phone hangs up,
 * or the daily allowance cuts the response off mid-body. The relay sees that
 * immediately (`deliver` reports a full queue), this side does not — the reads
 * are driven here, so nothing would stop a run whose reader has left until the
 * whole file had been read and every window thrown away at the relay.
 *
 * Cancelling an unknown `bid` is a no-op, exactly like `fsGetCancel`'s sibling
 * `deviceDetach`: the relay is free to send one per dead bridge without tracking
 * which runs are live, and a duplicate cannot hurt a run that is already gone.
 */
export const FSGET_CANCEL = 'fsGetCancel'
/**
 * The connector's "I have the file, start reading" answer.
 *
 * Carries `size` and `version` when the Host could tell us (P-13b). The relay
 * needs the size to answer `Content-Length` and a full
 * `Content-Range: bytes N-M/TOTAL`, which is what makes an interrupted download
 * resumable by the system rather than restarted: a background
 * `URLSessionDownloadTask` only produces resume data when the response states
 * the total. The version becomes the `ETag`, so a `If-Range` on the retry can
 * tell "same file, keep going" from "the file changed under me, start over".
 *
 * Both fields are **optional on purpose**: a Host that cannot stat the file
 * still gets its download, just without the resume guarantee. A missing field
 * must degrade to the old behaviour, never to an error — that is what keeps
 * this a compatible addition rather than a protocol break.
 */
export const FSGET_ACK = 'fsGetAck'
export const FSERR = 'fsErr'

/**
 * The window this module asks the Host for, and therefore the size of one
 * `fsGetChunk` before base64.
 *
 * 2 MiB is the Host's own `maxBytes` for `workspaceFiles/readBytes`
 * (`DSHClient.swift`), so asking for exactly that means no window is ever
 * refused for being too large — and base64 makes the frame ~2.67 MB, well under
 * the 32 MB frame ceiling (`lib/dlp.js`).
 */
export const DEFAULT_WINDOW_BYTES = 2 * 1024 * 1024

/**
 * The floor a window shrinks to when the Host says `workspace-file/too-large`.
 *
 * The Host's limit is a deployment value, not a constant this side can read, so
 * it is discovered: refuse → halve, down to here. Same approach as the app's own
 * downloader (`WorkspaceFileDownloader.swift`), and the same floor.
 */
export const MIN_WINDOW_BYTES = 128 * 1024

/** How many refusals in a row before the fetch is abandoned rather than halved. */
const MAX_SHRINKS = 8

/**
 * Host error codes that mean "asking again will answer the same thing".
 *
 * The app decides whether to retry from the code, so these must travel verbatim
 * in the `fsErr` — a generic `file/rejected` would make a bad path look like a
 * flaky network and send the user round the retry loop for nothing. The list is
 * the connector's copy of the app's own `isRetryable` set
 * (`WorkspaceFileDownloader.swift`); it only has to be *wider* than reality,
 * never narrower, because a code that lands here wrongly turns a retryable
 * failure into a permanent one.
 */
export const NON_RETRYABLE_CODES = new Set([
  'workspace-file/not-found',
  'workspace-file/outside-workspace',
  'workspace-file/not-regular-file',
  'workspace-file/not-directory',
  'workspace-file/unknown-workspace',
  'gateway/lookup-not-found',
  'gateway/bad-request',
])

/**
 * Whether a failure should be reported as-is (the app must not retry it).
 *
 * Anything unrecognised is assumed retryable: the cost of one wasted retry is a
 * second of the user's time, while wrongly declaring a transient failure
 * permanent leaves them with a file they cannot fetch at all.
 */
export function isPermanent(error) {
  const code = error?.code
  return typeof code === 'string' && NON_RETRYABLE_CODES.has(code)
}

/** Normalise a thrown Host failure into the `{code, message}` shape `fsErr` wants. */
function failureOf(error) {
  const code = typeof error?.code === 'string' && error.code ? error.code : 'file/rejected'
  const message = error instanceof Error ? error.message : String(error ?? 'download failed')
  return { code, message }
}

/**
 * One fetch, as this connector runs it.
 *
 * Not stateful beyond one run: it opens no file (the Host does the reading), so
 * there is nothing to clean up but the cancellation flag.
 */
export class FetchRun {
  constructor({ bid, scopeId, path, offset = 0, windowBytes = DEFAULT_WINDOW_BYTES }) {
    this.bid = bid
    this.scopeId = scopeId
    this.path = path
    this.offset = Number.isFinite(offset) ? Math.max(0, offset) : 0
    this.windowBytes = windowBytes
    /** Set when the relay stopped reading (it hung up, or ran out of quota). */
    this.cancelled = false
  }
}

/** Owns the in-flight downloads for one connector. */
export class FileFetcher {
  #runs = new Map()
  #logger
  #sends
  #rpc

  /**
   * @param {object} options
   * @param {(frame: object) => boolean} options.send  one frame to the relay
   * @param {(method: string, args: object) => Promise<object>} options.rpc
   *        the ordinary Host call path (`this.dsh.rpc`). Injected rather than
   *        reached for, so `node --test` can run a whole download against a stub
   *        Host with no DSH process at all.
   * @param {object} options.logger
   */
  constructor({ send, rpc, logger = {} } = {}) {
    this.#sends = send ?? (() => false)
    this.#rpc = rpc ?? (async () => ({ ok: false, error: { code: 'host/unavailable' } }))
    this.#logger = logger
  }

  /**
   * Start one download and run it to completion.
   *
   * Deliberately **not** awaited by the caller's frame handler: the whole point
   * is that chunks go out while the relay reads, and a `handleRelayFrame` that
   * awaited the file would block every other frame on the same socket.
   * Resolves when the run finishes (or `false` if it never started).
   */
  start(frame) {
    const bid = String(frame?.bid ?? '')
    if (!bid) {
      this.#logger.warn?.('mobile-link: fsGetBegin without a bid')
      return false
    }
    const scopeId = String(frame?.scopeId ?? '')
    const path = String(frame?.path ?? '')
    if (!scopeId || !path) {
      this.#sendError(bid, { code: 'file/rejected', message: 'scopeId and path are required' })
      return false
    }
    // A retried `bid` replaces the previous run: the connector reuses the id
    // across attempts of the same fetch, and two runs writing the same bid
    // would interleave their chunks into one nonsense stream.
    this.cancel(bid)
    // **`replaces` is how the superseded run is named now that the relay mints
    // its own ids.** Each HTTP request gets a fresh `bid`, so the run left over
    // from an interrupted attempt is not reachable by this request's identifier —
    // and on a resumed download it is very much still there: the system's resume
    // data freezes the *original* request, so what arrives is the old identifier
    // replayed. Without this the old run would keep reading until the new
    // `fsGetBegin` reached it, and its windows are exactly the ones the relay
    // cannot recall. Advisory by construction: a name we do not know stops
    // nothing, which is what an older relay (which never sends it) relies on.
    const replaced = String(frame?.replaces ?? '')
    if (replaced && replaced !== bid) this.cancel(replaced)
    const run = new FetchRun({
      bid, scopeId, path,
      offset: Number(frame?.offset ?? 0),
      windowBytes: Number(frame?.window) > 0 ? Number(frame.window) : DEFAULT_WINDOW_BYTES,
    })
    this.#runs.set(bid, run)
    // The stat has to happen **before** the ack: the relay builds the response
    // (status, `Content-Length`, `Content-Range`, `ETag`) from this answer, and
    // it can only prepare a resumable response once it is told what it is
    // resuming. Statting after the ack would mean the headers were already sent.
    this.#ackNow(run)
    this.#drive(run).catch((error) => {
      this.#logger.warn?.(`mobile-link: download ${bid} failed: ${error?.message ?? error}`)
    })
    return true
  }

  /**
   * Answer the relay's `fsGetBegin`, with the file's size and version if the
   * Host can supply them.
   *
   * Never fails the transfer: `stat` is an enhancement (it is what makes the
   * download resumable), and a Host that refuses it — an older DSH, a file that
   * vanished between the request and the stat — must still get its bytes. The
   * ack goes out either way, just without the fields the relay would have used
   * to build a resumable response.
   */
  async #ackNow(run) {
    const extra = await this.#statFor(run)
    // A run superseded while the stat was in flight must not ack: the relay has
    // already opened a new bridge for that bid, and a late ack would be
    // answering the request it just replaced.
    if (run.cancelled) return
    this.#sends({ t: FSGET_ACK, bid: run.bid, ...extra })
  }

  /**
   * One `workspaceFiles/stat`, reduced to the two fields the relay uses.
   *
   * Returns `{}` rather than throwing: see `#ackNow`. A sized response is worth
   * a round trip, but never worth the transfer.
   */
  async #statFor(run) {
    try {
      const result = await this.#rpc('workspaceFiles/stat', {
        workspaceFileScopeId: run.scopeId,
        path: run.path,
      })
      if (result && result.ok === false) return {}
      const value = result?.value ?? result
      const size = Number.isFinite(value?.bytes) ? Number(value.bytes) : undefined
      const version = typeof value?.version === 'string' && value.version ? value.version : undefined
      if (size === undefined && version === undefined) return {}
      return {
        ...size === undefined ? {} : { size },
        ...version === undefined ? {} : { version },
      }
    } catch {
      return {}
    }
  }

  /** Stop one run. Safe for an unknown bid (a late cancel is not an error). */
  cancel(bid) {
    const run = this.#runs.get(bid)
    if (run) run.cancelled = true
  }

  /** Stop every run, e.g. when the link goes down. */
  clear() {
    for (const run of this.#runs.values()) run.cancelled = true
    this.#runs.clear()
  }

  async #drive(run) {
    let offset = run.offset
    let shrinks = 0
    let window = run.windowBytes
    try {
      for (;;) {
        if (run.cancelled) return
        let answer
        try {
          answer = await this.#readWindow(run.scopeId, run.path, offset, window)
        } catch (error) {
          const failure = failureOf(error)
          if (failure.code === 'workspace-file/too-large' && shrinks < MAX_SHRINKS
              && window > MIN_WINDOW_BYTES) {
            // The Host's cap is smaller than the window asked for. Halve and try
            // again — the cap is a deployment value nothing here can read.
            window = Math.max(MIN_WINDOW_BYTES, Math.floor(window / 2))
            shrinks += 1
            continue
          }
          if (!run.cancelled) this.#sendError(run.bid, failure)
          return
        }
        // A window that came back after the run was superseded or dropped: the
        // relay has already stopped listening for this bid, and appending more
        // chunks would interleave into whatever run owns the bid now.
        if (run.cancelled) return
        const data = typeof answer?.data === 'string' ? answer.data : ''
        const eof = answer?.eof === true
        const piece = Buffer.from(data, 'base64')
        if (piece.length > 0) {
          this.#sends({ t: FSGET_CHUNK, bid: run.bid, data, eof })
          offset += piece.length
        } else if (!eof) {
          // An empty window that is not the end means the Host has nothing more
          // at this offset. Asking again would spin forever, so this is an error.
          if (!run.cancelled) {
            this.#sendError(run.bid, {
              code: 'workspace-file/stalled',
              message: `the Host returned an empty window at offset ${offset}`,
            })
          }
          return
        }
        if (eof) {
          // The run may have been superseded while that window was in flight —
          // a stale `fsGetEnd` would tell the relay a download nobody wanted any
          // more is complete, and a retried bid would answer its HTTP request
          // twice.
          if (run.cancelled) return
          if (piece.length === 0) {
            // Nothing at all was read and it is already the end: an empty file,
            // or an offset past the end. Either way the stream is complete.
            this.#sends({ t: FSGET_CHUNK, bid: run.bid, data: '', eof: true })
          }
          this.#sends({ t: FSGET_END, bid: run.bid })
          return
        }
      }
    } finally {
      this.#runs.delete(run.bid)
    }
  }

  /** One `workspaceFiles/readBytes`, unwrapped to `{data, eof}`. */
  async #readWindow(scopeId, path, offset, length) {
    const result = await this.#rpc('workspaceFiles/readBytes', {
      workspaceFileScopeId: scopeId,
      path,
      range: { offset, length },
    })
    if (result && result.ok === false) {
      // The DSH client returns failures as values (`{ok:false, error}`) rather
      // than throwing; the code has to survive into the `fsErr`.
      throw Object.assign(new Error(result.error?.message ?? 'read failed'),
        { code: result.error?.code })
    }
    return result?.value ?? result
  }

  #sendError(bid, failure) {
    this.#logger.warn?.(`mobile-link: download ${bid} failed: ${failure.code} ${failure.message}`)
    this.#sends({ t: FSERR, bid, ...failure })
  }

  /** Whether a run is still wanted; a superseded one emits nothing more. */
  static isLive(run) {
    return run !== undefined && !run.cancelled
  }
}

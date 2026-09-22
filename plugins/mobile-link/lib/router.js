/**
 * Device-side routing for one agent connection.
 *
 * Owns the device registry, the DLP-id ↔ mux-stream table, the waterfall
 * dedupe set and every per-device `$events` stream. The transport concerns
 * live in `link.js`; everything here is driven by frames and by DSH mux events,
 * so `node --test` can exercise it without a socket.
 *
 * Spec: docs/RELAY-PROTOCOL.md §4.
 */

import {
  StreamTable, WaterfallDedupe, deviceFrameError, deviceIdOf, nonEmptyString, resultFrame,
} from './dlp.js'
import { FileInbox, isFileMethod } from './files.js'
import { GitBridge, isGitMethod } from './git.js'
import { isHelloMethod, helloPayload, parseClientInfo } from './hello.js'

export const EVENTS_ENDPOINT = '$events'
export const EVENTS_RESULT = '$events/result'

/**
 * 手机断了之后，这条 `$events` 流还替它留多久（毫秒）。
 *
 * 为什么需要：手机是唯一客户端时，它一断，DSH 那边就没人持有这条流了——
 * 提问（waterfall）会随 Agent Context 释放被撤掉，用户回到手机再也看不到
 * （根因见 maintainers/PENDING-WATERFALL-LOSS.md）。留着流就等于"代手机值班"：
 * 这期间来的提问先攒着，手机回来补发。
 *
 * 代价是这段时间里 DSH 认为"设备还在"，会话的 Agent Context 不会因此释放；
 * 所以必须有上限，不能无限留。
 */
export const DEFAULT_EVENTS_GRACE_MS = 15 * 60 * 1000

/** 离线期间最多替一台设备攒多少条 `$events` 项（只攒 waterfall/cancel）。 */
export const DEFAULT_EVENTS_BACKLOG = 50

/**
 * 手机不在时要攒下来的 `$events` 项：只有"待回答的提问"和"提问作废"两种。
 *
 * 别的一律不攒——emit 类的都是"某事刚发生"的通知，几分钟后补发只会让 App
 * 对着旧事件发通知（例如一条早就结束的 turn）。
 */
export function isBufferedEvent(value) {
  if (!value || typeof value !== 'object') return false
  return value.type === 'waterfall' || value.type === 'cancel'
}

export function messageOf(error) {
  return error instanceof Error ? error.message : String(error)
}

export function errorObject(code, message, details = {}) {
  return { code, message, details }
}

export class DeviceRouter {
  /**
   * @param {object} options
   * @param {object} options.dsh        local DSH client (rpc / ensureMux / openStream / cancelStream)
   * @param {(deviceId: string, frame: object) => boolean} options.send  deliver one frame to one device
   * @param {() => void} [options.onChange]    called whenever the status snapshot changes
   */
  constructor({
    dsh, send, logger = console, onChange = () => {}, now = Date.now, protocolVersion = 1,
    eventsGraceMs = DEFAULT_EVENTS_GRACE_MS, eventsBacklog = DEFAULT_EVENTS_BACKLOG,
    setTimeoutFn = setTimeout, clearTimeoutFn = clearTimeout,
  } = {}) {
    this.dsh = dsh
    this.eventsGraceMs = eventsGraceMs
    this.eventsBacklog = eventsBacklog
    this.setTimeoutFn = setTimeoutFn
    this.clearTimeoutFn = clearTimeoutFn
    // Reported to the app so it can tell which wire revision it is talking to.
    this.protocolVersion = protocolVersion
    this.send = send
    this.logger = logger
    this.onChange = onChange
    this.now = now
    this.devices = new Map()
    this.streams = new StreamTable()
    this.dedupe = new WaterfallDedupe({ now })
    this.lastError = undefined
    this.fileInbox = new FileInbox(logger)
    this.git = new GitBridge(logger)
  }

  #changed() {
    this.onChange()
  }

  #fail(message) {
    this.lastError = message
    this.logger.warn?.(`mobile-link: ${message}`)
    this.#changed()
  }

  /** Route one validated frame that the relay addressed to a device. */
  async handleRelayFrame(frame) {
    if (!frame || typeof frame !== 'object') return
    const deviceId = deviceIdOf(frame)
    if (frame.t === 'deviceAttach') {
      await this.attachDevice(deviceId, frame.device)
      return
    }
    if (frame.t === 'deviceDetach') {
      await this.detachDevice(deviceId, frame.reason)
      return
    }
    if (!deviceId) return
    const problem = deviceFrameError(frame)
    if (problem) {
      this.send(deviceId, { t: 'error', code: 'protocol/bad-frame', message: problem })
      return
    }
    switch (frame.t) {
      case 'req':
        await this.handleRequest(deviceId, frame)
        return
      case 'open':
        await this.handleOpen(deviceId, frame)
        return
      case 'cancel':
        this.handleCancel(deviceId, frame)
        return
      case 'eventResult':
        await this.handleEventResult(deviceId, frame)
        return
      default:
        /* Unknown frame types are ignored by design (spec §3). */
        return
    }
  }

  // ── device lifecycle ────────────────────────────────────────────────────

  async attachDevice(deviceId, info = {}) {
    if (!nonEmptyString(deviceId)) return
    const existing = this.devices.get(deviceId)
    if (existing) {
      // 回头客：宽限期内又连上了。流和攒下的提问都还在，交给 handleOpen 补发。
      if (existing.offlineSince !== undefined) {
        this.clearTimeoutFn(existing.offlineTimer)
        existing.offlineTimer = undefined
        existing.offlineSince = undefined
        this.logger.info?.(
          `mobile-link: device ${deviceId} reattached with ${existing.eventsBacklog.length} buffered event(s)`)
        this.#changed()
      }
      return
    }
    this.devices.set(deviceId, {
      deviceId,
      name: info?.name,
      model: info?.model,
      connectedAt: this.now(),
      clientId: undefined,
      readyValue: undefined,
      eventsMuxId: undefined,
      dlpIds: new Set(),
      // 手机不在时的"值班"状态：offlineSince 有值 = 这条流在替它留着，
      // eventsBacklog 里是这段时间攒下、还没送达的 waterfall/cancel。
      offlineSince: undefined,
      offlineTimer: undefined,
      eventsBacklog: [],
    })
    this.logger.info?.(`mobile-link: device ${deviceId} attached (${info?.name ?? 'unknown'})`)
    this.#changed()
    await this.ensureEventsStream(deviceId)
  }

  async detachDevice(deviceId, reason) {
    const record = this.devices.get(deviceId)
    if (!record) return
    // 除了 `$events`，其它流（文件、会话流）立刻撤掉：它们没有"值班"的意义，
    // 留着只会占资源。`$events` 留着，见 DEFAULT_EVENTS_GRACE_MS 的说明。
    const keep = []
    for (const entry of this.streams.byDevice(deviceId)) {
      if (entry.endpoint === EVENTS_ENDPOINT) {
        keep.push(entry)
        continue
      }
      this.streams.removeByMux(entry.muxId)
      this.dsh.cancelStream(entry.muxId)
    }
    record.dlpIds.clear()
    for (const entry of keep) record.dlpIds.add(entry.dlpId)

    if (record.offlineSince === undefined) {
      record.offlineSince = this.now()
      record.offlineTimer = this.setTimeoutFn(() => {
        void this.#expireOfflineDevice(deviceId)
      }, this.eventsGraceMs)
      // 定时器不该把进程钉住（CLI 与测试里尤其明显）。
      record.offlineTimer?.unref?.()
    }
    this.logger.info?.(
      `mobile-link: device ${deviceId} detached (${reason ?? 'closed'})；`
      + `$events 流替它留 ${Math.round(this.eventsGraceMs / 1000)} 秒，期间来的提问会攒着`)
    this.#changed()
  }

  /** 宽限期到点：真的把这台设备放下（撤流、清缓冲）。 */
  async #expireOfflineDevice(deviceId) {
    const record = this.devices.get(deviceId)
    if (!record || record.offlineSince === undefined) return
    for (const muxId of this.streams.removeDevice(deviceId)) this.dsh.cancelStream(muxId)
    this.devices.delete(deviceId)
    this.logger.info?.(
      `mobile-link: device ${deviceId} 宽限期结束，已放下（丢掉 ${record.eventsBacklog.length} 条未送达事件）`)
    this.#changed()
  }

  /** Each device gets its own `$events` stream, and therefore its own `clientId`. */
  async ensureEventsStream(deviceId) {
    const record = this.devices.get(deviceId)
    if (!record || record.eventsMuxId) return
    const muxId = `ev:${deviceId}`
    record.eventsMuxId = muxId
    this.streams.add({ deviceId, dlpId: '', muxId, endpoint: EVENTS_ENDPOINT })
    try {
      await this.dsh.ensureMux()
      this.dsh.openStream(muxId, EVENTS_ENDPOINT, {})
      this.logger.debug?.(`mobile-link: opened per-device $events stream ${muxId}`)
    } catch (error) {
      record.eventsMuxId = undefined
      record.readyValue = undefined
      this.streams.removeByMux(muxId)
      this.#fail(`$events stream unavailable: ${messageOf(error)}`)
    }
  }

  /** Drop every device and return the mux streams the caller must cancel. */
  teardownAll() {
    const muxIds = []
    for (const deviceId of [...this.devices.keys()]) {
      const record = this.devices.get(deviceId)
      this.clearTimeoutFn(record?.offlineTimer)
      muxIds.push(...this.streams.removeDevice(deviceId))
      this.devices.delete(deviceId)
    }
    this.streams = new StreamTable()
    return muxIds
  }

  // ── device requests ─────────────────────────────────────────────────────

  async handleRequest(deviceId, frame) {
    // Files the phone sends are answered here rather than forwarded: the Host
    // has no upload endpoint, and carrying them on the existing unary frame
    // means neither the relay nor the protocol has to change.
    // What this connector is and can do. Answered here for the same reason as
    // the file calls: the HTTP status route exists only on the direct path.
    if (isHelloMethod(frame.method)) {
      // Recorded before answering: this is the only frame in which the phone
      // says which build it is, and the relay cannot see it from the pairing
      // row it keeps.
      const client = parseClientInfo(frame.args)
      if (client) {
        const record = this.devices.get(deviceId)
        if (record) record.client = client
        if (record?.client?.build !== client.build || record?.clientLogged !== client.build) {
          if (record) record.clientLogged = client.build
          // One line per build per connection: enough to answer "did they
          // update?" from a log, without a line per reconnect.
          this.logger?.info?.(
            `mobile-link: device ${deviceId} is ${client.label}` +
            `${record?.name ? ` (${record.name})` : ''}`
          )
        }
      }
      const value = helloPayload({
        protocolVersion: this.protocolVersion,
        agentId: this.identity?.agentId,
        name: this.identity?.agentName,
      })
      this.send(deviceId, resultFrame(frame.id, { ok: true, value }, deviceId))
      return
    }

    if (isFileMethod(frame.method)) {
      let result
      try {
        result = { ok: true, value: this.fileInbox.handle(frame.method, frame.args ?? {}) }
      } catch (error) {
        result = { ok: false, error: errorObject('file/rejected', messageOf(error)) }
      }
      this.send(deviceId, resultFrame(frame.id, result, deviceId))
      return
    }

    // Git also runs here, on the machine that holds the work tree: the Host has
    // no endpoint that runs a command, and the review a person wants — what
    // changed, what the diff says, what the last commits were — is all local.
    // Read-only; see git.js for the command whitelist.
    if (isGitMethod(frame.method)) {
      let result
      try {
        result = { ok: true, value: await this.git.handle(frame.method, frame.args ?? {}) }
      } catch (error) {
        result = {
          ok: false,
          error: errorObject(error?.code ?? 'git/failed', messageOf(error), error?.details ?? {}),
        }
      }
      this.send(deviceId, resultFrame(frame.id, result, deviceId))
      return
    }

    let result
    try {
      result = await this.dsh.rpc(frame.method, frame.args ?? {})
    } catch (error) {
      result = { ok: false, error: errorObject('host/unavailable', messageOf(error)) }
      this.lastError = messageOf(error)
      this.#changed()
    }
    this.send(deviceId, resultFrame(frame.id, result, deviceId))
  }

  async handleOpen(deviceId, frame) {
    const record = this.devices.get(deviceId)
    if (!record) {
      this.send(deviceId, { t: 'streamError', id: frame.id, error: errorObject('stream/unavailable', 'device is not attached') })
      return
    }
    if (frame.endpoint === EVENTS_ENDPOINT) {
      if (!record.eventsMuxId) await this.ensureEventsStream(deviceId)
      if (!record.eventsMuxId) {
        this.send(deviceId, {
          t: 'streamError', id: frame.id,
          error: errorObject('stream/unavailable', this.lastError ?? 'DSH is unavailable'),
        })
        return
      }
      // Items from this device's $events stream are already flowing as `event`
      // frames; this binding re-delivers them as `item` frames for the id.
      record.dlpIds.add(frame.id)
      // A device that opens $events after the ready item already went by would
      // otherwise never learn its clientId, so replay it for the new binding.
      if (record.readyValue !== undefined) {
        this.send(deviceId, { t: 'item', id: frame.id, value: record.readyValue })
      }
      // 手机不在的这段时间攒下的提问（waterfall/cancel）在这里补发：
      // ready 已经发过，所以 App 拿得到 clientId，补发的提问是可以被回答的。
      if (record.eventsBacklog.length > 0) {
        const backlog = record.eventsBacklog
        record.eventsBacklog = []
        this.logger.info?.(`mobile-link: replaying ${backlog.length} buffered event(s) to ${deviceId}`)
        for (const value of backlog) {
          this.send(deviceId, { t: 'item', id: frame.id, value })
        }
      }
      return
    }
    const muxId = `s:${deviceId}:${frame.id}`
    if (!this.streams.add({ deviceId, dlpId: frame.id, muxId, endpoint: frame.endpoint })) {
      this.send(deviceId, {
        t: 'streamError', id: frame.id,
        error: errorObject('stream/duplicate', `stream ${frame.id} is already open`),
      })
      return
    }
    try {
      await this.dsh.ensureMux()
    } catch (error) {
      this.streams.removeByMux(muxId)
      this.#fail(messageOf(error))
      this.send(deviceId, {
        t: 'streamError', id: frame.id, error: errorObject('host/unavailable', messageOf(error)),
      })
      return
    }
    this.dsh.openStream(muxId, frame.endpoint, frame.args ?? {})
  }

  handleCancel(deviceId, frame) {
    const record = this.devices.get(deviceId)
    if (record) record.dlpIds.delete(frame.id)
    const muxId = this.streams.removeByDlp(deviceId, frame.id)
    if (muxId) this.dsh.cancelStream(muxId)
  }

  async handleEventResult(deviceId, frame) {
    const record = this.devices.get(deviceId)
    if (!record) return
    const payload = frame.result ?? {}
    const eventId = payload.eventId
    if (!nonEmptyString(eventId) || payload.outcome === null || typeof payload.outcome !== 'object') {
      this.send(deviceId, {
        t: 'error', code: 'protocol/bad-frame',
        message: 'eventResult needs result.eventId and result.outcome',
      })
      return
    }
    if (!nonEmptyString(record.clientId)) {
      this.send(deviceId, {
        t: 'error', code: 'events/not-ready',
        message: 'this device has no $events clientId yet',
      })
      return
    }
    // The clientId is always the one from *this device's* $events ready frame
    // (spec §4.1.5); any clientId the device echoed is ignored on purpose.
    if (!this.dedupe.claim(eventId)) return
    let result
    try {
      result = await this.dsh.rpc(EVENTS_RESULT, {
        clientId: record.clientId, eventId, outcome: payload.outcome,
      })
    } catch (error) {
      this.dedupe.release(eventId)
      this.logger.warn?.(`mobile-link: $events/result failed: ${messageOf(error)}`)
      return
    }
    if (result?.ok !== true) {
      this.dedupe.release(eventId)
      this.logger.warn?.(`mobile-link: $events/result rejected: ${result?.error?.code ?? 'unknown'}`)
    }
  }

  // ── DSH mux events ──────────────────────────────────────────────────────

  onStreamItem(muxId, value) {
    const entry = this.streams.entryOfMux(muxId)
    if (!entry) {
      this.logger.debug?.(`mobile-link: item for unknown mux stream ${muxId}`)
      return
    }
    if (entry.endpoint === EVENTS_ENDPOINT) {
      this.forwardEvent(entry.deviceId, value)
      return
    }
    this.send(entry.deviceId, { t: 'item', id: entry.dlpId, value })
  }

  forwardEvent(deviceId, value) {
    const record = this.devices.get(deviceId)
    if (!record) return
    if (record.offlineSince !== undefined && isBufferedEvent(value)) {
      // 手机不在：先攒着（只攒 waterfall/cancel——别的都是过期噪音，
      // 补发出去只会让 App 对着几分钟前的事件发通知）。
      record.eventsBacklog.push(value)
      if (record.eventsBacklog.length > this.eventsBacklog) record.eventsBacklog.shift()
      this.logger.debug?.(
        `mobile-link: buffered ${value.type} ${value.event ?? value.eventId ?? ''} for offline ${deviceId}`)
      return
    }
    if (value && value.type === 'ready' && nonEmptyString(value.clientId)) {
      record.clientId = value.clientId
      record.readyValue = value
      this.#changed()
    }
    for (const dlpId of record.dlpIds) this.send(deviceId, { t: 'item', id: dlpId, value })
    // Spec §4.1.5: every $events item is broadcast as an `event` frame until the
    // device opens the stream explicitly, so nothing is delivered twice.
    if (record.dlpIds.size === 0) this.send(deviceId, { t: 'event', value })
  }

  onStreamError(muxId, error) {
    const entry = this.streams.entryOfMux(muxId)
    if (!entry) return
    if (entry.endpoint === EVENTS_ENDPOINT) {
      this.logger.warn?.(`mobile-link: $events stream failed: ${error?.code ?? 'unknown'}`)
      this.#forgetEvents(entry.deviceId)
      this.streams.removeByMux(muxId)
      return
    }
    this.streams.removeByMux(muxId)
    this.send(entry.deviceId, {
      t: 'streamError', id: entry.dlpId,
      error: errorObject(error?.code ?? 'gateway/failed', error?.message ?? 'DSH stream failed',
        error?.details ?? {}),
    })
  }

  onStreamEnd(muxId) {
    const entry = this.streams.removeByMux(muxId)
    if (!entry) return
    if (entry.endpoint === EVENTS_ENDPOINT) {
      this.#forgetEvents(entry.deviceId)
      return
    }
    this.send(entry.deviceId, { t: 'end', id: entry.dlpId })
  }

  onMuxDown(reason) {
    // Every logical stream is gone; tell their devices so they can reopen.
    this.logger.warn?.(`mobile-link: DSH mux down (${reason})`)
    for (const entry of [...this.streams.byMux.values()]) {
      if (entry.endpoint === EVENTS_ENDPOINT) continue
      this.send(entry.deviceId, {
        t: 'streamError', id: entry.dlpId,
        error: errorObject('host/unavailable', 'the local DSH connection dropped'),
      })
    }
    for (const record of this.devices.values()) this.#forgetEvents(record.deviceId)
    this.streams = new StreamTable()
    // Re-arm each device's $events stream against the fresh mux.
    for (const deviceId of this.devices.keys()) void this.ensureEventsStream(deviceId)
    this.#changed()
  }

  #forgetEvents(deviceId) {
    const record = this.devices.get(deviceId)
    if (!record) return
    record.eventsMuxId = undefined
    record.clientId = undefined
    record.readyValue = undefined
  }

  /** Device inventory for `GET /mobile-link/status`. */
  snapshot() {
    return [...this.devices.values()].map((record) => ({
      deviceId: record.deviceId,
      name: record.name,
      model: record.model,
      // Which build that phone reported on its last handshake.
      client: record.client ?? null,
      connectedAt: record.connectedAt,
      offlineSince: record.offlineSince ?? null,
      bufferedEvents: record.eventsBacklog.length,
      eventsReady: Boolean(record.clientId),
      openStreams: record.dlpIds.size,
    }))
  }
}

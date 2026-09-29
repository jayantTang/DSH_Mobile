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
import { FileInbox, FILE_BEGIN, FILE_CHUNK, FILE_END, isFileMethod } from './files.js'
import { FileFetcher } from './files-out.js'
import { GitBridge, isGitMethod } from './git.js'
import { isHelloMethod, helloPayload, parseClientInfo } from './hello.js'

/**
 * 后台大文件上传的桥接帧（relay → 连接器），名字见 `docs/relay-contract.json`
 * 的 `agentControl`。转义成 `FileInbox` 的三件套，见 `handleFsPutBegin` 那段注释。
 */
export const FSPUT_BEGIN = 'fsPutBegin'
export const FSPUT_CHUNK = 'fsPutChunk'
export const FSPUT_END = 'fsPutEnd'

/**
 * 后台大文件下载的桥接帧（relay → 连接器），同一族的另一半：relay 终结
 * `GET /files/down` 并慢慢读，这里驱动 host 的 `workspaceFiles/readBytes`
 * 一片一片回。实现体在 `lib/files-out.js`。
 */
export const FSGET_BEGIN = 'fsGetBegin'

export const EVENTS_ENDPOINT = '$events'
export const EVENTS_RESULT = '$events/result'

/**
 * 手机不在时一直替它留 `$events`，直到设备被撤销或进程退出。
 *
 * 为什么需要：手机是唯一客户端时，它一断，DSH 那边就没人持有这条流了——
 * 提问（waterfall）会随 Agent Context 释放被撤掉，用户回到手机再也看不到——
 * 这正是留流的原因。留着流就等于"代手机值班"：这期间来的提问先攒着，手机回来补发。
 *
 * **没有时限**：这里曾经有一个 15 分钟的宽限期（`DEFAULT_EVENTS_GRACE_MS`），
 * 到点撤流；2026-09-28 的 R-1 把它拆掉了——手机离线超过 15 分钟提问就永远丢了，
 * 而那正是"值班"最该起作用的时候。唯一的出口是 `reason === 'revoked'`（见
 * `detachDevice`），以及进程退出（`teardownAll`）。
 *
 * 代价是这段时间里 DSH 认为"设备还在"，会话的 Agent Context 不会因此释放；
 * 也就是"挂着的提问所在会话的 Agent Context 长期不释放"。owner 已裁定这不是
 * 风险（电脑一直运行），所以不加上限、也不为此写额外的清理机制。
 */

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
    eventsBacklog = DEFAULT_EVENTS_BACKLOG, notify = () => {},
  } = {}) {
    this.dsh = dsh
    this.eventsBacklog = eventsBacklog
    // 「跑完了 / 待你回应」这类事件到了就报一声（见 `notifyFor`）。默认空函数，
    // 测试与不关心提醒的调用方可以不管它。帧由 link.js 发（router 不发帧）。
    this.notify = notify
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
    // 下载桥（`fsGetBegin`）：它自己经 `this.dsh.rpc` 读 host，回复只带 bid。
    // `send(undefined, frame)` 与 `fsPut*` 同路——relay 靠 bid 关联回 HTTP 请求。
    this.fileFetcher = new FileFetcher({
      send: (frame) => this.send(undefined, frame),
      rpc: (method, args) => dsh.rpc(method, args),
      logger,
    })
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
      case FSPUT_BEGIN:
        this.handleFsPutBegin(deviceId, frame)
        return
      case FSPUT_CHUNK:
        this.handleFsPutChunk(frame)
        return
      case FSPUT_END:
        this.handleFsPutEnd(frame)
        return
      case FSGET_BEGIN:
        this.handleFsGetBegin(frame)
        return
      default:
        /* Unknown frame types are ignored by design (spec §3). */
        return
    }
  }

  // ── background-transfer bridge (relay → connector) ──────────────────────
  //
  // 一族 agent 侧控制帧（`docs/relay-contract.json` 的 `agentControl`），由 relay 的
  // `PUT /files/up` 驱动。它们**不跨到设备**——手机走的是普通 HTTPS，relay 终结它、
  // 再把字节泵到这条 agent WSS 上，落盘仍然是连接器的活（中转不落盘）。
  //
  // 实现体复用 `FileInbox`：它的 begin/chunk/end 语义正好是这三帧要的。
  // **上行回复只带 `bid`，不带 `deviceId`**——relay 靠 `bid` 关联回那个 HTTP 请求。

  handleFsPutBegin(deviceId, frame) {
    // `deviceId` 只用来在出错时记账；**回复一律不带 deviceId**——relay 是靠
    // `bid` 把它对回那个 HTTP 请求的（见 `handleRelayFrame` 那段注释）。
    void deviceId
    try {
      this.fileInbox.handle(FILE_BEGIN, {
        transferId: frame.bid, sessionId: frame.sessionId, name: frame.name, bytes: frame.bytes,
      })
      this.send(undefined, { t: 'fsPutAck', bid: frame.bid, received: 0 })
    } catch (error) {
      this.sendFsError(frame.bid, error)
    }
  }

  handleFsPutChunk(frame) {
    // **不回 ack**：整条链是流水线，一片一个 RTT 会把吞吐毁掉（roof 见
    // `02-design.md` §4.4 第 3 条）。出错用 `fsErr` 中断。
    try {
      this.fileInbox.handle(FILE_CHUNK, {
        transferId: frame.bid, seq: frame.seq, data: frame.data,
      })
    } catch (error) {
      this.sendFsError(frame.bid, error)
    }
  }

  handleFsPutEnd(frame) {
    try {
      const done = this.fileInbox.handle(FILE_END, { transferId: frame.bid })
      this.send(undefined, { t: 'fsPutDone', bid: frame.bid, path: done.path, bytes: done.bytes })
    } catch (error) {
      this.sendFsError(frame.bid, error)
    }
  }

  /**
   * 开一次下载。**不 await**：分片要在 relay 读响应体时陆续发出去，一个 await
   * 会把这条 socket 上其它帧全挡住（与上传那条流水线的理由相同）。
   */
  handleFsGetBegin(frame) {
    this.fileFetcher.start(frame)
  }

  /** One failure shape for the whole family; the relay turns it into an HTTP error. */
  sendFsError(bid, error) {
    this.logger.warn?.(`mobile-link: file bridge ${bid} failed: ${messageOf(error)}`)
    this.send(undefined, { t: 'fsErr', bid, ...errorObject('file/rejected', messageOf(error)) })
  }

  // ── device lifecycle ────────────────────────────────────────────────────

  async attachDevice(deviceId, info = {}) {
    if (!nonEmptyString(deviceId)) return
    const existing = this.devices.get(deviceId)
    if (existing) {
      // 回头客：手机又连上了。流和攒下的提问都还在，交给 handleOpen 补发。
      if (existing.offlineSince !== undefined) {
        existing.offlineSince = undefined
        this.logger.info?.(
          `mobile-link: device ${deviceId} reattached with ${existing.eventsPending.size} unanswered question(s)`)
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
      // 手机不在时的"值班"状态：offlineSince 有值 = 这条流在替它留着；
      // eventsPending 是**还没被回答**的提问（按 eventId 存）。
      // 注意它不是一个"送一次就清空"的队列：送过也要留着，否则 App 再重启一次
      // （或崩一次）这条提问就永远丢了——2026-09-22 验收时正是这么发现的。
      offlineSince: undefined,
      eventsPending: new Map(),
    })
    this.logger.info?.(`mobile-link: device ${deviceId} attached (${info?.name ?? 'unknown'})`)
    this.#changed()
    await this.ensureEventsStream(deviceId)
  }

  /**
   * 手机断了。
   *
   * `reason === 'revoked'`（中转发来的"这台设备被撤销了"）是**放下**：撤掉它全部的流、
   * 删掉记录——不再有人会回来拿那些提问了，继续值班只是白占一条流。
   *
   * 别的 reason（socket closed、backpressure…）一律是"手机暂时不在"：普通流（文件、
   * 会话流）立刻撤，`$events` 留着替它值班——**一直留**，没有时限（见 `$events`
   * 那段的说明）。这也是「撤销即放下」是唯一出口的原因。
   */
  async detachDevice(deviceId, reason) {
    const record = this.devices.get(deviceId)
    if (!record) return
    if (reason === 'revoked') {
      await this.#dropDevice(deviceId)
      this.logger.info?.(`mobile-link: device ${deviceId} 已被撤销，放下（不再替它值班）`)
      return
    }
    // 除了 `$events`，其它流（文件、会话流）立刻撤掉：它们没有"值班"的意义，
    // 留着只会占资源。`$events` 留着，见上面那段说明。
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

    if (record.offlineSince === undefined) record.offlineSince = this.now()
    this.logger.info?.(
      `mobile-link: device ${deviceId} detached (${reason ?? 'closed'})；`
      + '$events 流一直替它留着，直到设备被撤销或进程退出')
    this.#changed()
  }

  /** 真的把这台设备放下：撤全部流、删记录。唯一调用点是撤销与进程收尾。 */
  async #dropDevice(deviceId) {
    const record = this.devices.get(deviceId)
    if (!record) return
    for (const muxId of this.streams.removeDevice(deviceId)) this.dsh.cancelStream(muxId)
    this.devices.delete(deviceId)
    this.logger.info?.(
      `mobile-link: 放下设备 ${deviceId}（丢掉 ${record.eventsPending.size} 条没人回答的提问）`)
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
      // 还没被回答的提问在这里补发：ready 已经发过，所以 App 拿得到 clientId，
      // 补发的提问是可以被回答的。**送出去不清空**——App 可能又崩/又重启，
      // 只要还没人回答，下次连上还得再给一遍（App 侧按 eventId 去重）。
      if (record.eventsPending.size > 0) {
        const pending = [...record.eventsPending.values()]
        this.logger.info?.(
          `mobile-link: replaying ${pending.length} unanswered question(s) to ${deviceId}`)
        for (const value of pending) {
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
    // 答过了就不再是"待答"：删掉它，免得下次重连又把已经回答过的问题推给 App。
    record.eventsPending.delete(eventId)
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
    // 只有"待回答的提问"值得留：别的都是"某事刚发生"的通知，补发只会让 App
    // 对着几分钟前的事件发通知（例如一条早就结束的 turn）。
    // 待答表：不管手机在不在都记下来，直到**有人回答**或 host 作废它。
    // 只记在线时的转发是不够的——App 收下提问后崩一次/重启一次，那条提问就再也没人
    // 记得了（host 认为已经投给这条流了，不会重发）。连接器记着，重连时再给一遍。
    if (nonEmptyString(value?.eventId)) {
      if (value.type === 'cancel') record.eventsPending.delete(value.eventId)
      else if (value.type === 'waterfall') {
        record.eventsPending.set(value.eventId, value)
        if (record.eventsPending.size > this.eventsBacklog) {
          // 超上限时丢最老的（Map 保持插入顺序）。
          const oldest = record.eventsPending.keys().next().value
          record.eventsPending.delete(oldest)
        }
      }
    }
    // 「报一声」与「要不要攒」是两件事：攒只对 waterfall/cancel，报的是"跑完了"与
    // "待你回应"两类。这里放在离线早退**之前**，所以在不在线都会报——
    // 手机在线时它自己会弹本地通知，这条 notify 到了中转会被判"在线不推"（不然重复）。
    this.notifyFor(value)
    if (record.offlineSince !== undefined && isBufferedEvent(value)) {
      this.logger.debug?.(
        `mobile-link: kept ${value.type} ${value.event ?? value.eventId ?? ''} for offline ${deviceId}`)
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

  /**
   * 要不要为这条 `$events` 项报一声（就是「提醒手机」）。
   *
   * 只有两类，判据都是现成的：
   *
   * - **跑完了**：`emit: api-session/status(sid, false)`。只能从这条 `emit` 认——
   *   `turn/end` 不在 `$events` 的转发白名单里（`docs/DSH-PROTOCOL.md:3141-3165`；
   *   `turn/end` 在 `:3229`，那是 `session/follow` 的事件），在这条流上永远看不到。
   * - **待你回应**：两种 `waterfall` 都算——`user-questions/request`（`:3164`）与
   *   `approval/request`（`:3145`），两者都让 host 停在那儿等人。App 侧本来就两种都认
   *   （`Support/HostEventHub.swift:191-198`）。
   *
   * `api-session/error`（`:3150`）**有意不推**：它不一定是"跑完了"（也可能是一轮中途
   * 报错后继续），拿它当"跑完了"会发出一堆噪音提醒。这是决定，不是漏做。
   *
   * 不做去抖、不做队列、不做重试：一轮才一条，发失败（中转断了）就丢。`turnEnd` 丢一条
   * 不值得为它做重试；`attention` 丢不了，它同时被记账，手机回来会补发。
   */
  notifyFor(value) {
    if (!value || typeof value !== 'object') return
    if (value.type === 'emit' && value.event === 'api-session/status' && value.args?.[1] === false) {
      const sid = String(value.args[0] ?? '')
      if (sid) this.notify({ kind: 'turnEnd', sid })
      return
    }
    if (value.type === 'waterfall') {
      this.notify({ kind: 'attention', sid: value.agentId, eid: value.eventId })
    }
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
      unansweredEvents: record.eventsPending.size,
      eventsReady: Boolean(record.clientId),
      openStreams: record.dlpIds.size,
    }))
  }
}

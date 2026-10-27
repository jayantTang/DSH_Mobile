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
import { FileFetcher, FSGET_CANCEL } from './files-out.js'
import { GitBridge, isGitMethod } from './git.js'
import { isHelloMethod, helloPayload, parseClientInfo } from './hello.js'
import { isHistoryMethod } from './history.js'
import { trimRecordsForWire } from './history/records.js'
import { isJobsMethod } from './jobs-roster.js'

/**
 * 后台大文件上传的桥接帧（relay → 连接器），名字见 `docs/relay-contract.json`
 * 的 `agentControl`。转义成 `FileInbox` 的三件套，见 `handleFsPutBegin` 那段注释。
 */
export const FSPUT_BEGIN = 'fsPutBegin'
export const FSPUT_CHUNK = 'fsPutChunk'
export const FSPUT_END = 'fsPutEnd'
/**
 * relay 叫停一次后台上传（占位型前向兼容）。
 *
 * 本仓库两个中转**目前都不发这一帧**：手机掐掉 `PUT /files/up` 时，它们在
 * `finally` 里只摘掉本地的桥接，既不发取消帧、也不断开 agent 的 WebSocket。
 * 因此真正兜住句柄的是 `FileInbox` 的空闲清扫与"重传接管暂存路径"；这一帧
 * 让将来的/第三方中转能提前释放。按 bid 寻址，可以不带 `deviceId`
 * （与 `fsGetCancel` 同口径，未知 bid 是空操作）。
 */
export const FSPUT_CANCEL = 'fsPutCancel'

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

/**
 * 旧分页通道（`session/page`）的下发形态清洗（016）。
 *
 * 这一路是**降级通道**：宿主自己回一页记录，连接器只是转发。它和精确窗口
 * （`_link/sessionWindow`）必须守同一条口径 —— 只用于诊断的宿主模型输出日志
 * 不下发（见 `specs/016-history-load-perf/contracts/history-record-trim.md`）。
 *
 * 两种形态都要认：宿主 RPC 的信封 `{ ok, value: { records } }`，以及直接给
 * `{ records }` 的桩/测试形态。其余方法或结构一律原样返回，不做推断。
 */
export function trimHistoryPageForWire(method, result) {
  if (method !== 'session/page') return result
  if (result === null || typeof result !== 'object') return result
  const page = result.value ?? result
  if (page === null || typeof page !== 'object' || !Array.isArray(page.records)) return result
  const trimmed = { ...page, records: trimRecordsForWire(page.records) }
  return result.value === undefined ? trimmed : { ...result, value: trimmed }
}

import { DeviceTimeline } from './diagnostics.js'
import { SESSION_DIGEST_METHOD, digestSessionList, encodeDigest, digestDelta } from './session-digest.js'
import { DIR_LISTING_METHOD, dirListing } from './dir-listing.js'

/** 慢请求阈值默认值（毫秒）；0 = 关闭逐条慢请求记录。 */
export const DEFAULT_SLOW_REQUEST_MS = 2000

/** App 把自己那份阶段记录推上来的方法（契约 connector-diagnostics-method.md）。 */
export const DIAGNOSTICS_METHOD = '_link/diagnostics'
/** 手机把运行日志推上来的方法；落盘在 `logs.js`，与 journal 分开。 */
export const LOGS_METHOD = '_link/logs'
/** 单批上限：超过就截断并如实报 `accepted`，剩下的由 App 下次再推（水位不推进）。 */
export const DIAGNOSTICS_BATCH_BYTES = 32 * 1024
/** 单条事件里字符串字段的保留长度。 */
const DIAGNOSTICS_MAX_TEXT = 400

/**
 * 只留标量（字符串/数字/布尔）与标量数组。
 *
 * **必须把 App 的 `detail` 摊平到顶层**：App 侧的 JSONL 信封是
 * `{kind, seq, ms, at, detail:{...}}`（见 DSHKit 的 `LinkDiagnostics.Event`），而连接器
 * 自己的流水是**扁平**的。不摊平的话 `phase`/`ms` 这些字段会在清洗时被当成嵌套对象丢掉——
 * 实测症状：`app.dial` 落盘后一个字段都没有（2026-10-13 09:25 的中转运行）。
 */
function sanitizeDiagnosticEvent(event) {
  if (!event || typeof event !== 'object' || typeof event.kind !== 'string') return null
  const { detail, ...envelope } = event
  const flat = { ...envelope, ...(detail && typeof detail === 'object' ? detail : {}) }
  const clean = { kind: event.kind }
  for (const [key, value] of Object.entries(flat)) {
    if (key === 'kind') continue
    if (typeof value === 'string') clean[key] = value.slice(0, DIAGNOSTICS_MAX_TEXT)
    else if (typeof value === 'number' || typeof value === 'boolean') clean[key] = value
    else if (Array.isArray(value) && value.every((item) => typeof item === 'string' || typeof item === 'number')) {
      clean[key] = value.slice(0, 32)
    }
  }
  return clean
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
    eventsBacklog = DEFAULT_EVENTS_BACKLOG, notify = () => {}, onEvent = () => {},
    slowRequestMs = DEFAULT_SLOW_REQUEST_MS, diagnostics = true, logs = null,
  } = {}) {
    this.dsh = dsh
    /** 设备日志落盘（见 logs.js）；null = 不接日志（老配置或单测）。 */
    this.logs = logs
    this.eventsBacklog = eventsBacklog
    this.slowRequestMs = Number(slowRequestMs) || 0
    this.diagnosticsEnabled = diagnostics !== false
    /** 每个 deviceId 当前这次接入的计时（attach 时建、detach 时收）。 */
    this.timelines = new Map()
    /**
     * 当前这次请求已经发出去的字节数（在 `noteSent` 里累加、在请求收尾时取走）。
     *
     * 同一设备上并发请求会把字节算到一起——诊断只要量级对得上（"这次响应是几 KB 还是几 MB"），
     * 不值得为它引入逐请求关联（那要改所有回包点的形状）。
     */
    this._sentBytes = new Map()
    // 「跑完了 / 待你回应」这类事件到了就报一声（见 `notifyFor`）。默认空函数，
    // 测试与不关心提醒的调用方可以不管它。帧由 link.js 发（router 不发帧）。
    this.notify = notify
    // 生命周期事件（设备 attach/detach 等）的去处，由 link.js 接到流水（journal.js）。
    // 默认空函数，所以 router 单独用时（单测、本地脚本）不需要日志设施。
    this.onEvent = onEvent
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
    // 历史窗口/检索（spec 007）：由 index.js 注入宿主 `sessionQuery` 后交给它。
    // 没绑上就回 `link/unsupported`，手机端退回 `session/page`。
    this.history = undefined
    // 活动名单与 `link/jobs` 推帧（spec 018）。订阅与去抖都在 roster 里，router 只负责
    // 转交设备生命周期与把帧广播出去。
    this.jobsRoster = undefined
  }

  /**
   * 挂上活动名单（spec 018）。
   *
   * 注入可能晚于第一台设备连接（`ctx.inject` 的时序），所以这里要对**已经挂着**的
   * 设备补报一遍：只在 attach 时通知的话，这台连接会一直到下一次 attach 才开始推帧。
   */
  bindJobsRoster(roster) {
    this.jobsRoster = roster
    if (roster === undefined) return
    for (const deviceId of this.devices.keys()) roster.addDevice(deviceId)
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
    // **Before the `deviceId` guard, not after it.** The download bridge family
    // is addressed by `bid` alone — the relay is the one that terminates the
    // HTTP request and it knows which device it is for; putting a `deviceId` on
    // these frames would break the correlation the whole family rests on. So a
    // cancel legitimately arrives with no `deviceId`, and the guard below would
    // have dropped it silently: the connector would read the whole file for a
    // reader that left. Found by probe (the run kept pumping past the cancel),
    // which is why this is a test and not a comment.
    if (frame.t === FSGET_CANCEL) {
      this.handleFsGetCancel(frame)
      return
    }
    // 上传的取消帧同样是 bid 寻址，可能不带 `deviceId`；放在守卫之前，理由同上。
    if (frame.t === FSPUT_CANCEL) {
      this.handleFsPutCancel(frame)
      return
    }
    if (!deviceId) return
    const problem = deviceFrameError(frame)
    if (problem) {
      this.send(deviceId, { t: 'error', code: 'protocol/bad-frame', message: problem })
      return
    }
    switch (frame.t) {
      case 'req': {
        const startedAt = this.now()
        await this.handleRequest(deviceId, frame)
        this.#noteRequest(deviceId, frame.method, startedAt)
        return
      }
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
   * relay 叫停一次上传：立刻关句柄、删 `.part`。
   *
   * 不回帧：取消本身不是一次请求，也没有可报的错（与 `handleFsGetCancel` 同）。
   */
  handleFsPutCancel(frame) {
    const bid = String(frame?.bid ?? '')
    if (!bid) return
    this.fileInbox.cancel(bid)
  }

  /**
   * 开一次下载。**不 await**：分片要在 relay 读响应体时陆续发出去，一个 await
   * 会把这条 socket 上其它帧全挡住（与上传那条流水线的理由相同）。
   */
  handleFsGetBegin(frame) {
    this.fileFetcher.start(frame)
  }

  /**
   * relay 叫停一次下载读取（手机挂断 / 额度截断）。
   *
   * 只置 `cancelled`，**不回任何帧**：这不是一次请求，取消一个已经没人要的
   * 传输也没有可报的错。`#drive` 在每次窗口返回后检查这个标志，所以最多再
   * 多读一个窗口就停——不是立刻，但也不是读完整个文件。
   */
  handleFsGetCancel(frame) {
    const bid = String(frame?.bid ?? '')
    if (!bid) return
    this.fileFetcher.cancel(bid)
  }

  /** One failure shape for the whole family; the relay turns it into an HTTP error. */
  sendFsError(bid, error) {
    this.logger.warn?.(`mobile-link: file bridge ${bid} failed: ${messageOf(error)}`)
    this.send(undefined, { t: 'fsErr', bid, ...errorObject('file/rejected', messageOf(error)) })
  }

  // ── device lifecycle ────────────────────────────────────────────────────

  /**
   * 记一条请求的耗时与字节（spec 020 的 FR-001–FR-003）。
   *
   * `bytes` 取"这次请求期间发出去的字节"（见 `noteSent`）——它是一个近似值，
   * 只在同一设备上并发请求时才会串味，而诊断要回答的是"这次响应是几 KB 还是几 MB"。
   */
  #noteRequest(deviceId, method, startedAt) {
    const timeline = this.timelines.get(deviceId)
    if (!timeline) return
    const bytes = this._sentBytes.get(deviceId) ?? 0
    this._sentBytes.set(deviceId, 0)
    timeline.noteRequest({ method, startedAt, ms: this.now() - startedAt, bytes })
  }

  /** 每发一帧给某台设备就累加它的字节数（由 `link.js` 的 `sendToDevice` 调用）。 */
  noteSent(deviceId, bytes) {
    if (!deviceId || !Number.isFinite(bytes)) return
    this._sentBytes.set(deviceId, (this._sentBytes.get(deviceId) ?? 0) + bytes)
  }

  /**
   * 收下 App 推来的阶段记录（spec 020 的 FR-011 / 契约 §2）。
   *
   * 三条硬规则：
   *   1. **时刻照抄**：App 事件的 `at`/`ms` 是它自己钟上的读数，连接器不许改写
   *      （否则"手机侧几点了"这条信息就没了，而它正是区分"App 挂起"与"拨号卡住"的依据）；
   *   2. **按序号幂等**：同一批重推不会写两遍（水位记在设备记录上）；
   *   3. **超批上限就截断**：只收前若干条并如实报 `accepted`/`lastSeq`，剩下的下次再推——
   *      绝不假装收全了。
   *
   * @returns {{ok: true, value: {accepted: number, lastSeq: number}}}
   */
  acceptDiagnostics(deviceId, args = {}) {
    if (!this.diagnosticsEnabled) {
      // 回退闸：关掉时明确拒绝，手机据此静默忽略（不影响连接）。
      return { ok: false, error: errorObject('diagnostics/disabled', 'diagnostics intake is disabled on this connector') }
    }
    const record = this.devices.get(deviceId)
    const watermark = Number(record?.diagnosticsSeq) || 0
    const events = Array.isArray(args.events) ? args.events : []
    let accepted = 0
    let lastSeq = watermark
    let bytes = 0
    for (const raw of events) {
      const event = sanitizeDiagnosticEvent(raw)
      if (!event) continue
      const seq = Number(event.seq)
      if (Number.isFinite(seq) && seq <= watermark) continue
      const size = JSON.stringify(event).length
      if (bytes > 0 && bytes + size > DIAGNOSTICS_BATCH_BYTES) break
      // 用 recordForeign：App 的时刻照抄（它是"手机侧几点"的唯一来源）。
      // 补 `deviceId`：App 自己不知道它的 id，而多设备时没有这一列就没法把事件归到某台手机上。
      this.onEvent(event.kind, { ...event, deviceId, source: 'app' }, { foreign: true })
      bytes += size
      accepted += 1
      if (Number.isFinite(seq)) lastSeq = Math.max(lastSeq, seq)
    }
    if (record) record.diagnosticsSeq = lastSeq
    const sentAt = Number(args.sentAt)
    this.onEvent('app.push', {
      deviceId,
      count: accepted,
      dropped: Number(args.dropped) || 0,
      sentAt: Number.isFinite(sentAt) ? sentAt : undefined,
      // 手机时钟与本机时钟的差（单向延迟几十毫秒）；采集侧的对齐就靠这一个数。
      skewMs: Number.isFinite(sentAt) ? this.now() - sentAt : undefined,
    })
    return { ok: true, value: { accepted, lastSeq } }
  }

  /**
   * 收下手机推来的日志行。
   *
   * 与 `acceptDiagnostics` 的区别：这里不产生任何生命周期事件（日志是数据，不是状态），
   * 也不做批量解释；`logs.js` 只负责按天落盘与 7 天清理。失败一律当无事：
   * 手机侧把未确认的条目留在自己的环里，下次再推。
   */
  acceptLogs(deviceId, args = {}) {
    if (!this.logs) {
      return { ok: false, error: errorObject('logs/disabled', 'log intake is disabled on this connector') }
    }
    const entries = Array.isArray(args.entries) ? args.entries : []
    const result = this.logs.append(deviceId, entries, { full: args.full === true })
    return { ok: true, value: result }
  }

  /** 起一次新的接入计时（回头客也重起：那确实是一次新连接）。 */
  #startTimeline(deviceId) {
    this.timelines.get(deviceId)?.finish()
    this.timelines.set(deviceId, new DeviceTimeline({
      deviceId,
      slowRequestMs: this.slowRequestMs,
      now: this.now,
      onEvent: this.onEvent,
    }))
    this._sentBytes.set(deviceId, 0)
  }

  /** 收掉一次接入计时（断开、撤销、进程收尾都走这里）。 */
  #finishTimeline(deviceId) {
    const timeline = this.timelines.get(deviceId)
    if (!timeline) return
    timeline.finish()
    this.timelines.delete(deviceId)
    this._sentBytes.delete(deviceId)
  }

  async attachDevice(deviceId, info = {}) {
    if (!nonEmptyString(deviceId)) return
    this.#startTimeline(deviceId)
    // 活动名单（018）：第一台设备连上才订阅宿主任务事件；回头客这里也要补一次
    // （detach 时它从名单里撤下过）。
    this.jobsRoster?.addDevice(deviceId)
    const existing = this.devices.get(deviceId)
    if (existing) {
      // 回头客：手机又连上了。流和攒下的提问都还在，交给 handleOpen 补发。
      if (existing.offlineSince !== undefined) {
        const offlineForMs = this.now() - existing.offlineSince
        existing.offlineSince = undefined
        this.onEvent('device.reattach', { deviceId, offlineForMs, pending: existing.eventsPending.size })
        this.logger.info?.(
          `mobile-link: device ${deviceId} reattached with ${existing.eventsPending.size} unanswered question(s)`)
        this.#changed()
      } else {
        // **这条是"同一台设备同时又开了一条"**：中转的 `attach_device` 会直接覆盖旧
        // 链路，旧的那条既不会再收到 `deviceDetach`、也不会出现在任何一方的状态里
        // （2026-10-13 01:10 实测：attach 与上一条 detach 之间空了 34 秒）。记下来，
        // 否则事后只看得到"它连上了"，看不到"它连了两条"。
        this.onEvent('device.attach-again', { deviceId, connectedForMs: this.now() - existing.connectedAt })
        this.logger.warn?.(`mobile-link: device ${deviceId} attached again while still attached`)
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
    this.onEvent('device.attach', { deviceId, name: info?.name, model: info?.model })
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
    this.#finishTimeline(deviceId)
    const record = this.devices.get(deviceId)
    if (!record) return
    // 活动名单（018）：断了就不再往它那儿推任务帧（离线补发旧任务状态没有意义），
    // 最后一台设备离开时 roster 自己会释放宿主订阅。
    this.jobsRoster?.removeDevice(deviceId)
    if (reason === 'revoked') {
      await this.#dropDevice(deviceId)
      this.onEvent('device.revoked', { deviceId })
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
    this.onEvent('device.detach', { deviceId, reason: reason ?? 'closed' })
    this.logger.info?.(
      `mobile-link: device ${deviceId} detached (${reason ?? 'closed'})；`
      + '$events 流一直替它留着，直到设备被撤销或进程退出')
    this.#changed()
  }

  /** 真的把这台设备放下：撤全部流、删记录。唯一调用点是撤销与进程收尾。 */
  async #dropDevice(deviceId) {
    const record = this.devices.get(deviceId)
    if (!record) return
    this.jobsRoster?.removeDevice(deviceId)
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
      // 进程收尾/链路重建也要把这次接入的汇总写掉，否则"连上过、发过请求"这件事没有数字。
      this.#finishTimeline(deviceId)
      muxIds.push(...this.streams.removeDevice(deviceId))
      this.devices.delete(deviceId)
    }
    this.streams = new StreamTable()
    // 不该有残留：上面的循环已经逐个收过；这里兜底，防止 attach 之后没进 devices 的路径留下脏项。
    this.timelines.clear()
    this._sentBytes.clear()
    // 链路断了：在传的上传与下载都不可能再完成。上传要关句柄、删 `.part`；
    // 下载要停掉还没读完的窗口。
    this.fileInbox.clear()
    this.fileFetcher.clear()
    // 活动名单（018）：设备都没了，宿主任务订阅与排队的帧一起放掉。
    this.jobsRoster?.releaseAll()
    return muxIds
  }

  // ── device requests ─────────────────────────────────────────────────────

  async handleRequest(deviceId, frame) {
    // App 推上来的阶段记录：**只落盘，不影响任何连接行为**（契约
    // connector-diagnostics-method.md §4）。放在最前面，免得被后面的方法族顺序影响。
    // 精简版会话列表（spec 021）：同一份宿主数据，去掉 App 侧零读取点的字段，可按要求 gzip。
    // 老方法 `session/list` 一个字节都不改——老版本手机继续走它，这是兼容的前提。
    if (frame.method === SESSION_DIGEST_METHOD) {
      const args = frame.args ?? {}
      let result
      try {
        result = await this.dsh.rpc('session/list', { _request: args._request ?? {} })
      } catch (error) {
        result = { ok: false, error: errorObject('host/unavailable', messageOf(error)) }
        this.lastError = messageOf(error)
        this.#changed()
      }
      let payload = result
      if (result?.ok === true) {
        const trimmed = digestSessionList(result)
        const items = Array.isArray(trimmed?.items) ? trimmed.items : []
        const since = typeof args.since === 'string' ? args.since : null
        this.digestCursors ??= new Map()
        const previous = since ? this.digestCursors.get(deviceId) : null
        // 版本对得上才认那份指纹表；对不上（首次、连接器重启、设备被清理）就当没有历史。
        // 能不能当增量发由 digestDelta 决定：它持有指纹，也只有它能判断身份是否可识别。
        const usable = previous && previous.version === since ? previous : null
        const delta = digestDelta(usable ? usable.fingerprints : null, items)
        this.digestCursors.set(deviceId, { version: delta.version, fingerprints: delta.fingerprints })
        if (this.digestCursors.size > 32) {
          const oldest = this.digestCursors.keys().next().value
          this.digestCursors.delete(oldest)
        }
        const value = {
          ...trimmed,
          items: delta.changed,
          removed: delta.removed,
          version: delta.version,
          full: delta.full,
        }
        payload = { ok: true, value: encodeDigest(value, args.encoding) }
      }
      this.send(deviceId, resultFrame(frame.id, payload, deviceId))
      return
    }

    // 目录清单的本机增强（设计 20261024）：连接器读宿主的 `workspaceFiles/list`，
    // 在电脑本机对每个条目 `fs.stat` 补一个 `mtimeMs`——宿主没有时间字段，而
    // `workspaceFiles/stat` 的 `version` 是 opaque token（推不出时间）。
    // 与 sessionDigest 同款：清单的内容仍是宿主的，连接器只加字段；任何一步出问题
    // 都退回未增强的原始清单（装饰永不弄坏清单）。
    if (frame.method === DIR_LISTING_METHOD) {
      let result
      try {
        // `dirListing` 认宿主信封本身（`{ ok, value: { entries } }`）并原样回同形状的值：
        // 宿主报错时**信封逐字透传**，`resultFrame` 照常把它翻成 `ok:false` + 原错误码。
        // 这里不能再包一层 `{ ok: true, value }`——那会把宿主的失败塞进 `value` 里，
        // 帧上反而成了 `ok:true`（手机就会把"目录不存在"读成"空目录"）。
        result = await dirListing({ dsh: this.dsh, args: frame.args ?? {}, logger: this.logger })
      } catch (error) {
        result = { ok: false, error: errorObject(error?.code ?? 'link/failed', messageOf(error), error?.details ?? {}) }
      }
      this.send(deviceId, resultFrame(frame.id, result, deviceId))
      return
    }

    if (frame.method === DIAGNOSTICS_METHOD) {
      const result = this.acceptDiagnostics(deviceId, frame.args ?? {})
      this.send(deviceId, resultFrame(frame.id, result, deviceId))
      return
    }

    if (frame.method === LOGS_METHOD) {
      const result = this.acceptLogs(deviceId, frame.args ?? {})
      this.send(deviceId, resultFrame(frame.id, result, deviceId))
      return
    }

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

    // History reads run here too (spec 007): the Host owns a seq-exact reader but
    // does not expose it on the remote surface the phone talks to. Answered
    // locally when the injected `sessionQuery` is present; otherwise the phone is
    // told plainly that the capability is missing, so it can keep using
    // `session/page` instead of reading the failure as "no older history".
    if (isHistoryMethod(frame.method)) {
      let result
      try {
        result = this.history === undefined
          ? { ok: false, error: errorObject('link/unsupported', 'history reads are unavailable on this connector') }
          : await this.history.handle(frame.method, frame.args ?? {})
      } catch (error) {
        result = { ok: false, error: errorObject(error?.code ?? 'link/failed', messageOf(error), error?.details ?? {}) }
      }
      this.send(deviceId, resultFrame(frame.id, result, deviceId))
      return
    }

    // 活动名单（spec 018）与 history 同一条短路：连接器自己回答，不转发宿主。
    // 没挂上宿主 `ctx.jobs` 时回 `link/unsupported`——**不**回空名单，否则手机
    // 会把"这台连接器不支持"显示成"没有任务在跑"。
    if (isJobsMethod(frame.method)) {
      let result
      try {
        result = this.jobsRoster === undefined
          ? { ok: false, error: errorObject('link/unsupported', 'job roster is unavailable on this connector') }
          : await this.jobsRoster.handle(frame.args ?? {})
      } catch (error) {
        result = { ok: false, error: errorObject(error?.code ?? 'link/failed', messageOf(error), error?.details ?? {}) }
      }
      this.send(deviceId, resultFrame(frame.id, result, deviceId))
      return
    }

    let result
    try {
      result = await this.dsh.rpc(frame.method, frame.args ?? {})
      result = trimHistoryPageForWire(frame.method, result)
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
    this.#sendEventItem(deviceId, record, value)
  }

  /**
   * 向一台设备投递一条 `$events` 形态的项（item，或未开流时的 event 帧）。
   *
   * 抽出来是为了让连接器自造的帧（`link/jobs`，见 `publishEvent`）与宿主事件走**同一段**
   * 投递口径，帧语义不变：开了 `$events` 的按 dlpId 走 item，没开的按 event 广播。
   */
  #sendEventItem(deviceId, record, value) {
    for (const dlpId of record.dlpIds) this.send(deviceId, { t: 'item', id: dlpId, value })
    // Spec §4.1.5: every $events item is broadcast as an `event` frame until the
    // device opens the stream explicitly, so nothing is delivered twice.
    if (record.dlpIds.size === 0) this.send(deviceId, { t: 'event', value })
  }

  /**
   * 把一条连接器自造的项广播给**每台在线设备**（活动名单的 `link/jobs`，spec 018）。
   *
   * 与 `forwardEvent` 的区别是来源：那条项来自某台设备自己的 `$events` 流，只回给它；
   * 这条是宿主任务事件的产物，没有归属设备，所以每台在线设备各收一份。
   *
   * **离线设备不推**：`$events` 还替它留着（见 `detachDevice`），但旧任务状态没有补发
   * 意义——重连后手机重新问一次 `_link/jobRoster` 即可（契约 §3）。
   */
  publishEvent(value) {
    for (const record of this.devices.values()) {
      if (record.offlineSince !== undefined) continue
      this.#sendEventItem(record.deviceId, record, value)
    }
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

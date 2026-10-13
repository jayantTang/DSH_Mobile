#!/usr/bin/env node
/**
 * 一条命令产出诊断包（spec 020 的 US4）。
 *
 * 契约：`specs/020-link-diagnostics/contracts/collect-command.md`（CLI、包布局、退出码、脱敏）
 * 数据模型：`specs/020-link-diagnostics/data-model.md` §7–§8
 *
 * 为什么要有这条命令：诊断能力如果要求人记 ssh 与 `journalctl` 的用法，等于没有。它做的事只有
 * 「把三侧已有的记录按同一个时钟拼成一个自解释的包」——**不新增任何被采集侧的能力**，
 * 也**不配对设备、不改中转数据**（宪法 III）。
 *
 * 退出码：0 出包且无缺失 / 1 出包但有缺失来源 / 2 未出包（脱敏检查失败、参数非法、输出已存在）。
 */

import { execFileSync } from 'node:child_process'

import { buildFindings, slowSideSummary } from './diagnostics-findings.mjs'
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

import { checkDiagnosticsPack, redactHome } from './check-diagnostics.mjs'

// 这个 import 有两个作用：① 复用"怎么读 endpoint.json、怎么换 cookie"的既有口径（契约 §5 要求
// 不出现第二份实现）；② 它的模块顶层会加载仓库根的 `.env.local`（真值不入库），
// 于是 `DSH_OTA_HOST` / `DSH_SITE` 在这里也能读到。
import { cookie, endpoint } from './dsh-probe.mjs'

const USAGE = `用法: node scripts/dev/collect-diagnostics.mjs [选项]

选项:
  --since <duration>   采集窗口（默认 30m；接受 30m / 6h / 2d 或 ISO 时刻）
  --out <path>         输出目录（默认 ~/dsh-diagnostics/diagnostics-<YYYYMMDD-HHMMSS>）
  --device <id>        只采这些设备（可重复；默认全部在用设备）
  --no-relay           跳过中转侧（无 ssh 时用；包内记为"主动跳过"而不是缺失）
  --json               把 coverage/missing 打到 stdout（便于脚本消费）
  -h, --help           显示本帮助

产物（详见契约 §2）:
  README.md  timeline.jsonl  clock.json  coverage.json  missing.json  sources/{connector.jsonl,relay.log,status.json}
`

/** 诊断事件里允许出现的字符串长度上限（防呆；真正的上限在写入侧）。 */
const MAX_TEXT = 400

// ── 纯函数（全部由 collect-diagnostics.test.mjs 直接测） ────────────────────

/** 采集窗口：`30m` / `6h` / `2d`，或一个 ISO 时刻（表示"从那时到现在"）。 */
export function parseSince(value, now = Date.now()) {
  const raw = String(value ?? '').trim()
  const relative = /^(\d+)([mhd])$/.exec(raw)
  if (relative) {
    const scale = { m: 60_000, h: 3_600_000, d: 86_400_000 }[relative[2]]
    const spanMs = Number(relative[1]) * scale
    return { sinceMs: now - spanMs, untilMs: now, spanMs, label: raw }
  }
  const at = Date.parse(raw)
  if (Number.isFinite(at)) return { sinceMs: at, untilMs: now, spanMs: now - at, label: raw }
  throw new Error(`无法解析窗口：${value}（示例：30m / 6h / 2d / 2026-10-13T01:00:00Z）`)
}

/** 只留窗口内的事件（写入侧的时刻为准）。 */
export function sliceByWindow(events, { sinceMs, untilMs }) {
  return events.filter((event) => Number.isFinite(event.ms) && event.ms >= sinceMs && event.ms <= untilMs)
}

/**
 * 一条 journald JSON 记录 → 诊断事件（契约 §4 的稳定片段）。
 *
 * 用 `journalctl -o json` 而不是默认文本：JSON 里带 `__REALTIME_TIMESTAMP`（epoch 微秒），
 * 不必猜服务器的时区——猜错时区会让整条时间线偏 8 小时，而那是"看起来很正常"的错误。
 */
export function parseRelayJsonRecord(record) {
  const message = typeof record?.MESSAGE === 'string' ? record.MESSAGE : ''
  const micros = Number(record?.__REALTIME_TIMESTAMP)
  if (!Number.isFinite(micros)) return null
  return parseRelayMessage(message, Math.round(micros / 1000))
}

/** 中转日志行的解析（契约 §4）。未匹配的行返回 null，由调用方计入 coverage。 */
export function parseRelayMessage(message, ms) {
  const text = String(message ?? '')
  const at = Number.isFinite(ms) ? ms : undefined
  const base = at === undefined ? {} : { at: new Date(at).toISOString(), ms: at }
  // 行尾的 ` (agent <id>)`：四类设备行以前不带 agentId，采集侧因此无法按 agent 收窄
  // （2026-10-13 实测：111 条中转行只有 9 条是本机的）。没有后缀的老行按"归属未知"处理。
  const suffix = / \(agent (\S+)\)\s*$/.exec(text)
  const agent = suffix ? { agentId: suffix[1] } : {}

  let match = /relay: device (\S+) \((\S+)\) attached to agent (\S+)/.exec(text)
  if (match) return { ...base, kind: 'relay.device-attach', deviceId: match[1], name: match[2], agentId: match[3] }
  match = /relay: device (\S+) detached \(([^)]*)\)/.exec(text)
  if (match) return { ...base, kind: 'relay.device-detach', deviceId: match[1], reason: match[2], ...agent }
  match = /relay: device (\S+) attached again while its previous socket is still open/.exec(text)
  if (match) return { ...base, kind: 'relay.device-replaced', deviceId: match[1], ...agent }
  match = /relay: device (\S+) closed a socket that had already been replaced/.exec(text)
  if (match) return { ...base, kind: 'relay.device-superseded-close', deviceId: match[1], ...agent }
  match = /relay: device (\S+) socket error: (.*)$/.exec(text)
  if (match) {
    // 后缀要从错误文本里摘掉，否则错误里会带上 "(agent agt_…)"，
    // 读者会把归属当成错误内容的一部分。
    const detail = suffix ? match[2].slice(0, -suffix[0].length) : match[2]
    return { ...base, kind: 'relay.pong-timeout', deviceId: match[1], error: detail.trim().slice(0, MAX_TEXT), ...agent }
  }
  match = /relay: agent (\S+) connected \(([^)]*)\)/.exec(text)
  if (match) return { ...base, kind: 'relay.agent-connect', agentId: match[1], name: match[2] }
  match = /relay: agent (\S+) disconnected/.exec(text)
  if (match) return { ...base, kind: 'relay.agent-disconnect', agentId: match[1] }
  match = /relay: agent (\S+) superseded by a new connection/.exec(text)
  if (match) return { ...base, kind: 'relay.agent-superseded', agentId: match[1] }
  return null
}

/** 把一段 journald 输出（JSON 行，容许夹杂非 JSON）解析成事件 + 计数。 */
export function parseRelayLines(text, { deviceIds = [], agentIds = [] } = {}) {
  const events = []
  let readLines = 0
  let unmatched = 0
  for (const line of String(text ?? '').split('\n')) {
    if (!line.trim()) continue
    readLines += 1
    let record
    try {
      record = JSON.parse(line)
    } catch {
      unmatched += 1
      continue
    }
    const event = parseRelayJsonRecord(record)
    if (!event) {
      unmatched += 1
      continue
    }
    if (deviceIds.length > 0 && event.deviceId && !deviceIds.includes(event.deviceId)) continue
    if (agentIds.length > 0 && event.agentId && !agentIds.includes(event.agentId)) continue
    events.push(event)
  }
  return { events, readLines, unmatched }
}

/**
 * 用 `/stats` 的 `now` 算偏移（每次采样：发请求前后各取一次本机时刻）。
 *
 * `offsetMs > 0` = 中转时钟比本机快。`rttMs` 要如实带出来：走 ssh 时它有一两百毫秒，
 * 那是这套方法的精度上限，读者必须看得到。
 */
export function computeOffsetFromStats(samples) {
  const usable = (samples ?? []).filter((s) => Number.isFinite(s?.now) && Number.isFinite(s?.t0) && Number.isFinite(s?.t1))
  if (usable.length === 0) return null
  const best = usable.reduce((a, b) => ((b.t1 - b.t0) < (a.t1 - a.t0) ? b : a))
  const rttMs = Math.round(best.t1 - best.t0)
  return {
    source: 'relay',
    offsetMs: Math.round(best.now - (best.t0 + rttMs / 2)),
    method: 'stats-rtt',
    rttMs,
    samples: usable.length,
  }
}

/** 中位数（偶数个取中间两个的平均）：对"同一件事在两侧的差值"比取某一条更稳。 */
function median(values) {
  const sorted = [...values].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  if (sorted.length % 2 === 1) return sorted[middle]
  return Math.round((sorted[middle - 1] + sorted[middle]) / 2)
}

/**
 * 用"同一条连接在两侧各留了一条记录"算偏移。
 *
 * 比 RTT 法精确得多（两侧记的是**同一个事件**，误差是几毫秒的传播延迟，而不是 ssh 的往返），
 * 所以有共同事件时优先用它。
 *
 * **配对规则**：对中转的每一条 attach，在连接器那一侧找**同一 deviceId 最近的**接入类事件
 * （`device.attach` / `device.reattach` / `device.attach-again`），距离超过 `toleranceMs` 就不算数。
 * 不能拿"连接器的第一条"去配每一条中转 attach——实测那样差值会散布到 17 分钟（连接器只在
 * 第一次接入时写 `device.attach`，之后同一设备再接入写的是 `attach-again`），中位数毫无意义。
 *
 * 要求至少 `minSamples` 条命中、且彼此相差不超过 `spreadMs`：只有一两条时无法判断是不是巧合。
 */
export function computeOffsetFromCommonEvents(connectorEvents, relayEvents,
  { spreadMs = 500, toleranceMs = 5000, minSamples = 2 } = {}) {
  const attachish = new Map()
  for (const event of connectorEvents ?? []) {
    if (!CONNECTOR_ATTACH_KINDS.has(event.kind) || !Number.isFinite(event.ms)) continue
    if (!attachish.has(event.deviceId)) attachish.set(event.deviceId, [])
    attachish.get(event.deviceId).push(event.ms)
  }
  for (const list of attachish.values()) list.sort((a, b) => a - b)

  const deltas = []
  for (const event of relayEvents ?? []) {
    if (event.kind !== 'relay.device-attach' || !Number.isFinite(event.ms)) continue
    const nearest = nearestWithin(attachish.get(event.deviceId), event.ms, toleranceMs)
    if (nearest !== null) deltas.push(event.ms - nearest)
  }
  if (deltas.length < minSamples) return null
  const sorted = [...deltas].sort((a, b) => a - b)
  if (sorted[sorted.length - 1] - sorted[0] > spreadMs) return null
  return {
    source: 'relay',
    offsetMs: median(deltas),
    method: 'common-event',
    rttMs: null,
    samples: deltas.length,
  }
}

/** 连接器侧"一次接入"的 kind（首次、回头、以及未断开就又开一条）。 */
const CONNECTOR_ATTACH_KINDS = new Set(['device.attach', 'device.reattach', 'device.attach-again'])

/** 在有序数组里找距 `value` 最近且不超过 `tolerance` 的那个；没有就 null。 */
function nearestWithin(sorted, value, tolerance) {
  if (!sorted || sorted.length === 0) return null
  let low = 0
  let high = sorted.length - 1
  while (low < high) {
    const middle = (low + high) >> 1
    if (sorted[middle] < value) low = middle + 1
    else high = middle
  }
  const candidates = [sorted[low], sorted[Math.max(0, low - 1)]]
  let best = null
  for (const candidate of candidates) {
    const distance = Math.abs(candidate - value)
    if (distance <= tolerance && (best === null || distance < Math.abs(best - value))) best = candidate
  }
  return best
}

/**
 * 把中转事件收窄到本机 agent 自己的设备（FR-021）。
 *
 * 为什么需要：中转的 `detach` / `replaced` / `superseded-close` / `socket error` 四类行在
 * 2026-10-13 之前**不带 agentId**，而采集侧只能按 agentId 过滤 → 别的账号的设备行全部混进包
 * （实测 111 条里只有 9 条是本机的），甚至误导过一次判断。
 *
 * 判定规则（从严到宽）：
 *   1. 行上有 agentId 且不是我们 → **别的账号**，丢；
 *   2. 行上有 agentId 且是我们 → 留；
 *   3. 没有 agentId 但有 deviceId，且该 deviceId 在本机设备清单里 → 留（老行靠清单兜底）；
 *   4. 其余（没有 agentId、deviceId 也不认识）→ 丢，并单独计数：这类最可能是别人的设备。
 *
 * @returns {{kept: Array, excludedOtherAgent: number, excludedUnknownDevice: number}}
 */
export function scopeRelayEvents(events, { agentId, deviceIds = [] } = {}) {
  const known = new Set(deviceIds)
  const kept = []
  let excludedOtherAgent = 0
  let excludedUnknownDevice = 0
  for (const event of events ?? []) {
    if (event.agentId) {
      if (agentId && event.agentId === agentId) kept.push(event)
      else excludedOtherAgent += 1
      continue
    }
    if (event.deviceId && known.has(event.deviceId)) kept.push(event)
    else excludedUnknownDevice += 1
  }
  return { kept, excludedOtherAgent, excludedUnknownDevice }
}

/**
 * 手机是**第三个时钟**：它的 `app.*` 时刻用的是手机自己钟。
 *
 * 偏移取自连接器在收到那批推送时记下的 `skewMs`（= 连接器本机时刻 − App 上报的 `sentAt`），
 * 所以它含一次单向传输的误差（实测量级是几十毫秒）。取最近一条：
 * 手机时钟可能被用户改过，越新越可信。
 */
export function computeAppOffset(connectorEvents) {
  const pushes = (connectorEvents ?? []).filter((event) => event.kind === 'app.push' && Number.isFinite(event.skewMs))
  if (pushes.length === 0) return { source: 'app', offsetMs: null, method: 'none', rttMs: null, samples: 0 }
  const latest = pushes[pushes.length - 1]
  return {
    source: 'app',
    offsetMs: latest.skewMs,
    method: 'push-skew',
    rttMs: null,
    samples: pushes.length,
  }
}

/**
 * 把三侧事件按"一次接入"分组，算出一张阶段表（spec 020 的 US2）。
 *
 * 为什么要它：`timeline.jsonl` 是**流水**，人要在里面自己找"这次接入的五个数字"。这张表直接给
 * 每次接入一行：拨号 → 传输建立 → 首个数据请求 → 首个数据响应 → 握手 → 首屏，缺的阶段写 `missing`
 * 而不是 0（与连接器侧同一条口径）。
 *
 * 归属规则：连接器的 `device.attach`/`attach-again`/`reattach` 各开一段；App 的事件按
 * "同一个 deviceId、且时刻落在该接入前后 `toleranceMs` 内"归到那一段——App 的拨号**早于**
 * 中转/连接器记到的接入（实测领先约 150 ms），所以不能用"接入之后"当唯一条件。
 */
export function summarizeAttaches({ connector = [], app = [], relay = [] } = {},
  { toleranceMs = 5000 } = {}) {
  const segments = []
  const deviceOf = (event) => event.deviceId
  for (const event of [...connector].sort((a, b) => a.ms - b.ms)) {
    if (!CONNECTOR_ATTACH_KINDS.has(event.kind) || !event.deviceId) continue
    segments.push({ deviceId: event.deviceId, attachAtMs: event.ms, connector: {}, app: {}, relay: {} })
  }
  /**
   * 归到"哪一段接入"：取该设备**最后一段已经开始的接入**（起点往前放宽 `toleranceMs`，
   * 因为 App 的拨号早于中转/连接器记到的接入），事件落在它之后就一直属于它——
   * 直到下一段接入开始。不能用"距接入最近"：握手可能在接入之后十几秒（实测 19 s），
   * 那样会被判成"不在任何一段里"。
   */
  const segmentFor = (deviceId, ms) => {
    let found = null
    for (const segment of segments) {
      if (segment.deviceId !== deviceId) continue
      if (segment.attachAtMs - toleranceMs > ms) continue
      if (found === null || segment.attachAtMs > found.attachAtMs) found = segment
    }
    return found
  }
  for (const event of connector) {
    if (event.kind !== 'device.phase' || !event.deviceId) continue
    const segment = segmentFor(event.deviceId, event.ms)
    if (segment && segment.connector.phases === undefined) {
      segment.connector = { phases: event.phases ?? null, missing: event.missing ?? [] }
    }
  }
  for (const event of relay) {
    if (event.kind !== 'relay.device-attach' || !event.deviceId) continue
    const segment = segmentFor(event.deviceId, event.ms)
    if (segment && segment.relay.attachAtMs === undefined) segment.relay.attachAtMs = event.ms
  }
  for (const event of app) {
    if (!event.deviceId || !event.kind.startsWith('app.')) continue
    const segment = segmentFor(event.deviceId, event.ms)
    if (!segment) continue
    if (event.kind === 'app.dial' && event.phase === 'start' && segment.app.dialAtMs === undefined) {
      segment.app.dialAtMs = event.ms
    } else if (event.kind === 'app.dial' && event.phase === 'transport-up' && segment.app.transportUpAtMs === undefined) {
      segment.app.transportUpAtMs = event.ms
    } else if (event.kind === 'app.first-request' && segment.app.firstRequestAtMs === undefined) {
      segment.app.firstRequestAtMs = event.ms
    } else if (event.kind === 'app.first-response' && segment.app.firstResponseAtMs === undefined) {
      segment.app.firstResponseAtMs = event.ms
      if (typeof event.bytes === 'number') segment.app.firstResponseBytes = event.bytes
    } else if (event.kind === 'app.hello' && segment.app.helloAtMs === undefined) {
      segment.app.helloAtMs = event.ms
    } else if (event.kind === 'app.first-screen' && segment.app.firstScreenAtMs === undefined) {
      segment.app.firstScreenAtMs = event.ms
    }
  }
  // 连接器自己的重启（插件热更 / dsh 重启）会让手机重挂，但手机并没有重新拨号：
  // 这种"半次接入"不是故障，判读时要能认出来，否则每次开发热更都会刷一片告警。
  const restartMarks = [...connector]
    .filter((event) => event.kind === 'link.start' || event.kind === 'link.open')
    .map((event) => event.ms)
    .sort((a, b) => a - b)

  return segments.map((segment) => {
    // App 侧一律相对**拨号起点**算；没有拨号起点时相对接入时刻（并记进 note）。
    const base = segment.app.dialAtMs ?? segment.attachAtMs
    const at = (value) => (value === undefined ? null : Math.round(value - base))
    const stages = {
      dialMs: at(segment.app.dialAtMs),
      transportUpMs: at(segment.app.transportUpAtMs),
      firstRequestMs: at(segment.app.firstRequestAtMs),
      firstResponseMs: at(segment.app.firstResponseAtMs),
      helloMs: at(segment.app.helloAtMs),
      firstScreenMs: at(segment.app.firstScreenAtMs),
    }
    const missing = Object.entries(stages).filter(([, value]) => value === null).map(([key]) => STAGE_NAMES[key])
    // ── 派生指标（FR-028）：把"哪一侧慢"变成现成字段，不再要人肉相减 ──
    //
    // 两侧的毫秒各自相对自己的起点（App 相对拨号、连接器相对接入），这里只换算一次。
    const phases = segment.connector.phases ?? null
    const connectorHandlingMs = phases && phases.firstRequestMs !== null && phases.firstResponseMs !== null
      ? Math.round(phases.firstResponseMs - phases.firstRequestMs)
      : null
    // 连接器的"首个响应"换算到拨号起点：+ (接入 − 拨号)
    const leadMs = segment.app.dialAtMs === undefined ? null : segment.attachAtMs - segment.app.dialAtMs
    const phoneHandlingMs = (connectorHandlingMs !== null && stages.firstResponseMs !== null && leadMs !== null)
      ? Math.round(stages.firstResponseMs - (phases.firstResponseMs + leadMs))
      : null
    const relayEvents = { attach: 0, replaced: 0, detach: 0, supersededClose: 0, pongTimeout: 0 }
    for (const event of relay) {
      if (event.deviceId !== segment.deviceId) continue
      if (event.kind === 'relay.device-attach') relayEvents.attach += 1
      else if (event.kind === 'relay.device-replaced') relayEvents.replaced += 1
      else if (event.kind === 'relay.device-detach') relayEvents.detach += 1
      else if (event.kind === 'relay.device-superseded-close') relayEvents.supersededClose += 1
      else if (event.kind === 'relay.pong-timeout') relayEvents.pongTimeout += 1
    }
    return {
      deviceId: segment.deviceId,
      attachAt: new Date(segment.attachAtMs).toISOString(),
      attachMs: segment.attachAtMs,
      relayAttachMs: segment.relay.attachAtMs ?? null,
      appStages: stages,
      appMissing: missing,
      appBytes: segment.app.firstResponseBytes ?? null,
      connectorPhases: phases,
      connectorMissing: segment.connector.missing ?? [],
      connectorHandlingMs,
      // 手机侧处理耗时：连接器答完到 App 认定拿到数据之间的时间。负数说明对齐或归属有问题。
      phoneHandlingMs: phoneHandlingMs !== null && phoneHandlingMs >= 0 ? phoneHandlingMs : null,
      phoneHandlingNegative: phoneHandlingMs !== null && phoneHandlingMs < 0,
      relayEvents,
      // 这次接入距最近一次连接器重启多少毫秒（没重启过就是 null）。
      afterConnectorRestartMs: (() => {
        let latest = null
        for (const ms of restartMarks) {
          if (ms <= segment.attachAtMs && (latest === null || ms > latest)) latest = ms
        }
        return latest === null || segment.attachAtMs - latest > 120000 ? null : segment.attachAtMs - latest
      })(),
      // 两侧对"拨号→握手"的读数：差得多说明归属配错了——这是自检，不是结论。
      helloSkewMs: (phases?.helloMs ?? null) !== null && stages.helloMs !== null && leadMs !== null
        ? Math.round(stages.helloMs - (phases.helloMs + leadMs))
        : null,
    }
  })
}

/** 阶段名（`missing` 里出现的那套，与连接器侧同名）。 */
export const STAGE_NAMES = Object.freeze({
  dialMs: 'dial',
  transportUpMs: 'transport-up',
  firstRequestMs: 'first-request',
  firstResponseMs: 'first-response',
  helloMs: 'hello',
  firstScreenMs: 'first-screen',
})

/** 选一个偏移：共同事件优先（更精确），否则 RTT 法；都没有就是 `none`（不合并时间线）。 */
export function chooseOffset({ common = null, stats = null } = {}) {
  const chosen = common ?? stats
  if (!chosen) {
    return { source: 'relay', offsetMs: null, method: 'none', rttMs: null, samples: 0, alternatives: [] }
  }
  const alternatives = [common, stats].filter(Boolean).filter((entry) => entry.method !== chosen.method)
  return { ...chosen, alternatives }
}

/**
 * 合并时间线：把中转侧与手机侧都换算到本机时钟后按时刻排序。
 *
 * **逐来源尽力**：某一侧的偏移拿不到（`method: 'none'`）时，只把那部分事件排除在时间线之外
 * 并在 `mergedSources` 里如实说明——绝不拿一个猜的偏移去对齐。各来源自己的**耗时**（如
 * `app.hello.ms`）是来源内部量，不依赖这一步。
 */
export function mergeTimeline({ connector = [], relay = [], app = [], offsetRelay, offsetApp } = {}) {
  const mergedSources = ['connector']
  const rows = (connector ?? []).map((event) => ({ ...event, source: 'connector', localMs: event.ms }))
  for (const [list, source, offset] of [[app, 'app', offsetApp], [relay, 'relay', offsetRelay]]) {
    if (!offset || offset.method === 'none' || !Number.isFinite(offset.offsetMs)) continue
    mergedSources.push(source)
    for (const event of list ?? []) {
      rows.push({ ...event, source, ms: event.ms - offset.offsetMs, localMs: event.ms - offset.offsetMs })
    }
  }
  return {
    mergedSources,
    rows: rows
      .filter((row) => Number.isFinite(row.localMs))
      .sort((a, b) => a.localMs - b.localMs)
      .map((row) => ({ ...row, at: new Date(row.localMs).toISOString() })),
  }
}

export function parseArgs(argv) {
  const options = { since: '30m', out: undefined, devices: [], relay: true, json: false, help: false }
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '-h' || arg === '--help') options.help = true
    else if (arg === '--json') options.json = true
    else if (arg === '--no-relay') options.relay = false
    else if (arg === '--since') options.since = argv[++index]
    else if (arg === '--out') options.out = argv[++index]
    else if (arg === '--device') options.devices.push(argv[++index])
    else throw new Error(`未知参数：${arg}`)
  }
  return options
}

// ── IO（薄壳；真正的判断都在上面的纯函数里） ────────────────────────────────

export function dshHome() {
  return process.env.DSH_HOME || join(homedir(), '.dsh')
}

/** 读连接器流水（含滚走的 `.1`），并如实报出"更早的已被滚动丢弃"。 */
export function readConnectorJournal({ dshHome: home = dshHome() } = {}) {
  const path = join(home, 'mobile-link', 'link-events.jsonl')
  const archived = `${path}.1`
  const events = []
  const counts = { current: 0, archived: 0, droppedEarlier: 0 }
  for (const [file, key] of [[archived, 'archived'], [path, 'current']]) {
    if (!existsSync(file)) continue
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      if (!line.trim()) continue
      try {
        events.push(JSON.parse(line))
        counts[key] += 1
      } catch {
        counts.droppedEarlier += 1
      }
    }
  }
  return { path, events, counts }
}

/**
 * journalctl 认的时间写法与我们的窗口标签不一样：它要 `-30m`（带前导减号）或 `30 min ago`，
 * 直接给 `30m` 会回 `Failed to parse timestamp`（实测）。ISO 时刻原样传。
 */
export function journalSince(label) {
  const raw = String(label ?? '').trim()
  return /^\d+[mhd]$/.test(raw) ? `-${raw}` : raw
}

/** 走 ssh 取中转日志（`-o json`：带 epoch 微秒，不必猜时区）。 */
export function readRelayLog({ host, since, agentIds = [], deviceIds = [] } = {}) {
  const command = `journalctl -u dsh-relay --since '${journalSince(since)}' --no-pager -o json`
  const text = execFileSync('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', `root@${host}`, command],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 60_000 })
  return { text, ...parseRelayLines(text, { agentIds, deviceIds }) }
}

/**
 * 走 ssh 取本机 agent 名下的**全部**设备 id（含已撤销的老设备）。
 *
 * 用途只有一个：给中转日志行判归属。清单来自权威侧（中转库），不是从日志里猜的。
 */
export function readRelayDeviceIds({ host, agentId, db = process.env.DSH_RELAY_DB || '/var/lib/dsh-relay/state.db' } = {}) {
  const text = execFileSync('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', `root@${host}`,
    `/opt/dsh-relay/.venv/bin/python /opt/dsh-relay/admin.py --db ${db} device-list`],
  { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, timeout: 30_000 })
  const rows = JSON.parse(text)
  return rows.filter((row) => !agentId || row.agentId === agentId).map((row) => row.deviceId)
}

/** 走 ssh 取 `/stats`（它只监听回环，从公网拿不到——这是设计，不是缺陷）。 */
export function readRelayStats({ host } = {}) {
  const t0 = Date.now()
  const text = execFileSync('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', `root@${host}`,
    'curl -s localhost:8787/stats'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 30_000 })
  const t1 = Date.now()
  const stats = JSON.parse(text)
  return { stats, sample: { now: stats.now, t0, t1 } }
}

/** 取连接器自己的状态快照。 */
export async function readConnectorStatus() {
  const { port, cookie: session } = await cookie()
  const response = await fetch(`http://127.0.0.1:${port}/mobile-link/status`, {
    headers: { cookie: session, Origin: `http://127.0.0.1:${port}` },
  })
  if (!response.ok) throw new Error(`/mobile-link/status 回 HTTP ${response.status}`)
  return response.json()
}

/** 诊断包目录名。 */
export function bundleName(at = new Date()) {
  const stamp = at.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, '').replace('T', '-')
  return `diagnostics-${stamp}`
}

/** 默认输出根目录（不放进仓库，也不放进 `~/.dsh`——它是一次性的产物）。 */
export function defaultOutRoot() {
  return join(homedir(), 'dsh-diagnostics')
}

/** 事件是不是 App 侧写进来的（连接器原样落盘时打了 `source: "app"`）。 */
function isAppEvent(event) {
  return event?.source === 'app' || (typeof event?.kind === 'string' && event.kind.startsWith('app.'))
}

/**
 * 调试设备（名字以 `DSH-` 开头）的 deviceId：它们整条不进包（宪法 III 与 spec 的边界）。
 *
 * **例外**：`explicit` 里的 id 不排除。默认采集是"给支持排障用"的包，不该带调试设备；
 * 但 owner 显式点名 `--device <id>` 时它知道自己在看什么（自验时的仿真器设备就属于这一类）。
 */
export function debugDeviceIds({ events = [], status = null, explicit = [] } = {}) {
  const ids = new Set()
  const asked = new Set(explicit)
  for (const event of events) {
    if (typeof event?.name === 'string' && event.name.startsWith('DSH-') && event.deviceId) ids.add(event.deviceId)
  }
  for (const device of status?.devices ?? []) {
    if (typeof device?.name === 'string' && device.name.startsWith('DSH-') && device.deviceId) ids.add(device.deviceId)
  }
  for (const id of asked) ids.delete(id)
  return ids
}

/** 把一个对象写成 JSON 文件（统一 0600：包里可能有设备 id 与文件名）。 */
function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
}

/** 逐行写 JSONL（同样 0600）。 */
function writeJsonl(path, rows) {
  writeFileSync(path, rows.map((row) => JSON.stringify(row)).join('\n') + (rows.length ? '\n' : ''), { mode: 0o600 })
}

/**
 * 采一次并出包。**任何一侧失败都不中断**：记进 `missing.json`，包照样出得来（FR-015）。
 *
 * @returns {Promise<{outDir: string, coverage: object, missing: Array}>}
 */
async function collect({ options, window, log = () => {} }) {
  const missing = []
  const coverage = {}
  const relayHost = process.env.DSH_OTA_HOST
  const agentIds = []

  // ① 连接器流水（含 App 推上来的那部分）
  let raw = { events: [], counts: { current: 0, archived: 0, droppedEarlier: 0 }, path: null }
  try {
    raw = readConnectorJournal({ dshHome: dshHome() })
  } catch (error) {
    missing.push({ source: 'connector-journal', reason: error.message,
      nextStep: '确认本机 DSH 正在运行、且连接器写过 ~/.dsh/mobile-link/link-events.jsonl' })
  }
  const inWindow = sliceByWindow(raw.events, window)
  let status = null
  try {
    status = await readConnectorStatus()
    agentIds.push(status.agentId)
  } catch (error) {
    missing.push({ source: 'connector-status', reason: error.message,
      nextStep: '确认本机 DSH 在跑（endpoint.json 的令牌还有效）' })
  }
  const debugIds = debugDeviceIds({ events: inWindow, status, explicit: options.devices })
  const kept = inWindow.filter((event) => !debugIds.has(event.deviceId))
  const appEvents = kept.filter(isAppEvent)
  const connectorEvents = kept.filter((event) => !isAppEvent(event))
  for (const event of connectorEvents) if (event.agentId) agentIds.push(event.agentId)

  // ② 中转：日志与 /stats 都只能走 ssh（服务只监听回环）
  let relayText = ''
  let relayEvents = []
  const relaySamples = []
  if (!options.relay) {
    missing.push({ source: 'relay', reason: '--no-relay：主动跳过', nextStep: '去掉 --no-relay 再采一次' })
  } else if (!relayHost) {
    missing.push({ source: 'relay', reason: '.env.local 里没有 DSH_OTA_HOST',
      nextStep: '在仓库根 .env.local 写上 DSH_OTA_HOST，或加 --no-relay' })
  } else {
    try {
      // 本机设备清单（权威侧）：状态里的在用设备 ∪ 中转库里该 agent 的全部设备（含已撤销）。
      const statusDevices = (status?.devices ?? []).map((device) => device.deviceId).filter(Boolean)
      let knownDeviceIds = [...new Set(statusDevices)]
      try {
        knownDeviceIds = [...new Set([...knownDeviceIds, ...readRelayDeviceIds({ host: relayHost, agentId: status?.agentId })])]
      } catch (error) {
        // 拿不到清单也能继续：靠 agentId 后缀收窄（新行都带），只是老行会更保守地被丢掉。
        missing.push({ source: 'relay-device-list', reason: error.message,
          nextStep: '确认 admin.py 路径与 db 路径（可用 DSH_RELAY_DB 覆盖）' })
      }
      const log_ = readRelayLog({ host: relayHost, since: options.since, agentIds: [...new Set(agentIds)] })
      relayText = log_.text
      const scoped = scopeRelayEvents(log_.events, { agentId: status?.agentId, deviceIds: knownDeviceIds })
      relayEvents = sliceByWindow(scoped.kept, window)
      coverage.relay = {
        lines: log_.readLines,
        parsed: log_.events.length,
        unmatched: log_.unmatched,
        kept: scoped.kept.length,
        excludedOtherAgent: scoped.excludedOtherAgent,
        excludedUnknownDevice: scoped.excludedUnknownDevice,
        knownDevices: knownDeviceIds.length,
      }
    } catch (error) {
      missing.push({ source: 'relay-log', reason: error.message,
        nextStep: `确认能 ssh root@${relayHost}（密钥/网络），或加 --no-relay` })
    }
    // 两次采样：RTT 小的那次算偏移（ssh 往返是一两百毫秒，精度上限就在这）
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const { stats, sample } = readRelayStats({ host: relayHost })
        relaySamples.push(sample)
        status = status ?? { relay: stats }
      } catch (error) {
        if (attempt === 0) {
          missing.push({ source: 'relay-stats', reason: error.message,
            nextStep: '同上（/stats 只监听回环，必须走 ssh）' })
        }
      }
    }
  }

  // ③ 时钟：中转优先共同事件，其次 ssh-RTT；手机取最近一条推送的 skewMs
  //
  // 用了 `--device` 时，上面那份中转事件只剩一台设备的记录，常常凑不到两条匹配（时钟是
  // **系统的属性，不是某台设备的**）。所以再取一次 agent 全量的片段，**只用于对齐**——
  // 包里的 relay 切片仍然按 `--device` 收窄（那是"我只要这几台"的意思）。
  let alignmentEvents = relayEvents
  if (options.devices.length > 0 && options.relay && relayHost) {
    try {
      const wide = readRelayLog({ host: relayHost, since: options.since,
        agentIds: [...new Set(agentIds)] })
      alignmentEvents = sliceByWindow(wide.events, window)
    } catch {
      // 拿不到就退回收窄那份：offset 可能算不出来，但**不编**，只是按来源分节。
    }
  }
  const common = computeOffsetFromCommonEvents(connectorEvents, alignmentEvents)
  const stats = computeOffsetFromStats(relaySamples)
  const relayOffset = chooseOffset({ common, stats })
  // 注意传**全部**事件：`app.push` 自己就是 `app.*`（被分到 appEvents 里了），
  // 只传 connectorEvents 的话永远找不到 skewMs——手机那一半就永远对不齐。
  const appOffset = computeAppOffset([...connectorEvents, ...appEvents])

  // ④ 合并时间线（逐来源尽力；拿不到偏移的来源只在 sources/ 里分节）
  const merged = mergeTimeline({
    connector: connectorEvents, relay: relayEvents, app: appEvents,
    offsetRelay: relayOffset, offsetApp: appOffset,
  })

  return { missing, coverage, raw, connectorEvents, appEvents, relayEvents, relayText, status,
    relayOffset, appOffset, merged, debugIds }
}

/** 组装并写出诊断包（写前先脱敏与自检，命中就不出包）。 */
function writeBundle({ outDir, collected, window, options, log }) {
  const { relayOffset, appOffset, merged } = collected
  mkdirSync(outDir, { recursive: true, mode: 0o700 })
  mkdirSync(join(outDir, 'sources'), { recursive: true, mode: 0o700 })
  const home = homedir()
  const scrub = (value) => redactHome(typeof value === 'string' ? value : JSON.stringify(value), home)

  writeJsonl(join(outDir, 'sources', 'connector.jsonl'),
    [...collected.connectorEvents, ...collected.appEvents].map((event) => JSON.parse(scrub(event))))
  writeFileSync(join(outDir, 'sources', 'relay.log'), scrub(collected.relayText), { mode: 0o600 })
  writeJson(join(outDir, 'sources', 'status.json'),
    JSON.parse(scrub({ connector: collected.status?.state ? collected.status : null })))

  const clocks = [relayOffset, appOffset]
  writeJson(join(outDir, 'clock.json'), clocks)
  const coverage = {
    window: { since: new Date(window.sinceMs).toISOString(), until: new Date(window.untilMs).toISOString(),
      label: window.label },
    mergedSources: merged.mergedSources,
    connector: {
      events: collected.connectorEvents.length + collected.appEvents.length,
      appEvents: collected.appEvents.length,
      current: collected.raw.counts.current,
      archived: collected.raw.counts.archived,
      droppedEarlier: collected.raw.counts.droppedEarlier,
      rolledOut: collected.raw.counts.archived > 0,
    },
    relay: collected.coverage.relay ?? null,
    excludedDebugDevices: [...collected.debugIds],
    ...collected.coverage,
  }
  writeJson(join(outDir, 'coverage.json'), coverage)
  writeJson(join(outDir, 'missing.json'), collected.missing)

  const timeline = merged.rows.map((row) => JSON.parse(scrub(row)))
  writeJsonl(join(outDir, merged.rows.length ? 'timeline.jsonl' : 'timeline.by-source.jsonl'), timeline)

  // 每次接入一行：人要的就是这张表，而不是在流水里自己找五个数字。
  const attaches = summarizeAttaches({ connector: collected.connectorEvents, app: collected.appEvents,
    relay: collected.relayEvents })
  writeJsonl(join(outDir, 'attaches.jsonl'), attaches.map((row) => JSON.parse(scrub(row))))

  // 自动判读：把"哪一跳缺/有没有双 socket/哪一侧慢"变成机器可核对的清单（US9）。
  const findings = buildFindings({
    attaches,
    connectorEvents: collected.connectorEvents,
    appEvents: collected.appEvents,
    relayEvents: collected.relayEvents,
    coverage: collected.coverage,
  })
  writeJson(join(outDir, 'findings.json'), findings.map((row) => JSON.parse(scrub(row))))
  const slowSide = slowSideSummary(attaches)

  writeFileSync(join(outDir, 'README.md'),
    readme({ ...collected, coverage, window, options, outDir, attaches, findings, slowSide }),
    { mode: 0o600 })
  return { coverage, missing: collected.missing }
}

/** README 顶部的告警行：没有告警就明说"无"，不要留空白让人猜。 */
function warnLines(findings) {
  const warn = findings.filter((item) => item.level === 'warn')
  if (warn.length === 0) {
    const info = findings.length
    return [`**告警：无。**${info > 0 ? `（另有 ${info} 条提示级发现，见 \`findings.json\`）` : ''}`]
  }
  return warn.map((item) => `- **${item.id}**：${item.summary}`)
}

/** 表格单元格：`null`（没发生）与 0 要分得开。 */
function cell(value) {
  return value === null || value === undefined ? '—' : String(value)
}

/** 包内自解释：这次采了什么、怎么判读四类问题、缺了什么。 */
function readme({ missing, coverage, window, options, outDir, attaches = [], findings = [], slowSide = null }) {
  const lines = [
    '# 诊断包', '',
    `- 采集窗口：${coverage.window.since} → ${coverage.window.until}（${window.label}）`,
    `- 输出：${outDir}`,
    `- 并进时间线的来源：${coverage.mergedSources.join(', ')}`,
    missing.length ? `- **缺失来源 ${missing.length} 个**（见 missing.json）：${missing.map((m) => m.source).join(', ')}`
      : '- 缺失来源：无',
    coverage.connector?.rolledOut ? '- 注意：连接器流水已滚动过，更早的事件不在本包里。' : '',
    '', '## 怎么判读（spec 020 的四类问题）', '',
    '1. **哪一跳没连上**：看 timeline 上有没有 `app.dial(start)`（App 拨号）、`relay.device-attach`（中转收到）、',
    '   `device.attach`（连接器收到）。三者缺哪个就停在那一跳；只有 start 没有 `transport-up` = 拨号卡在握手前。',
    '2. **连上耗时长 / 加载慢**：`app.hello.ms` / `app.first-screen.ms` / `device.phase.phases` 是各段毫秒。',
    '3. **同步慢**：`device.summary`（p50/p95/top3）与 `request.slow`（方法名 + 耗时 + 字节）。',
    '4. **记录有没有失控**：`coverage.connector.droppedEarlier` 与 `journal.fileErrors`（在 status.json 里）。',
    '', '## 先看这里：自动判读（findings.json）', '',
    ...warnLines(findings),
    ...(slowSide ? ['', slowSide] : []),
    '', '## 每次接入的阶段耗时（毫秒，相对该次拨号；`—` = 没发生）', '',
    '| 设备 | 接入时刻 | 拨号 | 传输建立 | 首请求 | 首响应 | 握手 | 首屏 | 连接器侧 |',
    '|---|---|---|---|---|---|---|---|---|',
    ...attaches.map((row) => `| ${row.deviceId} | ${row.attachAt.slice(11, 19)} | ${
      cell(row.appStages.dialMs)} | ${cell(row.appStages.transportUpMs)} | ${cell(row.appStages.firstRequestMs)} | ${
      cell(row.appStages.firstResponseMs)} | ${cell(row.appStages.helloMs)} | ${cell(row.appStages.firstScreenMs)} | ${
      row.connectorPhases ? `hello ${cell(row.connectorPhases.helloMs)} / 首响应 ${cell(row.connectorPhases.firstResponseMs)}` : '（缺）'
    } |`),
    '', '两侧对「接入→握手」的读数应当接近（`attaches.jsonl` 的 `helloSkewMs`）；差得多说明归属配错了。',
    '', '## 常用命令', '```bash',
    `jq -r '"\\(.at[11:19]) \\(.source) \\(.kind)"' ${join(outDir, 'timeline.jsonl')} | less`,
    `jq -c 'select(.kind=="device.summary") | {deviceId, requests, p95Ms, top3}' ${join(outDir, 'sources/connector.jsonl')}`,
    `jq . ${join(outDir, 'clock.json')}`,
    '```',
  ]
  return `${lines.filter((line) => line !== '').join('\n')}\n`
}

/** 出包（含脱敏自检）：命中就删掉并让调用方以 2 退出。 */
export async function runCollect({ options, log = () => {} } = {}) {
  const window = parseSince(options.since)
  const outDir = options.out ?? join(defaultOutRoot(), bundleName())
  if (existsSync(outDir)) {
    return { ok: false, reason: `输出目录已存在：${outDir}（不覆盖）`, outDir }
  }
  const collected = await collect({ options, window, log })
  const { coverage, missing } = writeBundle({ outDir, collected, window, options, log })
  // 契约 §2 硬规则 6：脱敏或机械检查失败就**不出包**（退出码 2）。
  const check = checkDiagnosticsPack(outDir)
  if (!check.ok) {
    rmSync(outDir, { recursive: true, force: true })
    return { ok: false, reason: `脱敏/结构检查未通过，已删除未发出的包：${[
      ...check.issues, ...check.hits.map((hit) => `${hit.rule}@${hit.file}`)].join('；')}`, outDir }
  }
  return { ok: true, outDir, coverage, missing, exitCode: missing.length ? 1 : 0 }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const options = (() => {
    try {
      return parseArgs(process.argv.slice(2))
    } catch (error) {
      process.stderr.write(`${error.message}\n\n${USAGE}`)
      process.exit(2)
      return null
    }
  })()
  if (options?.help) {
    process.stdout.write(USAGE)
    process.exit(0)
  }
  if (options) {
    runCollect({ options, log: (message) => process.stderr.write(`${message}\n`) })
      .then((result) => {
        if (!result.ok) {
          process.stderr.write(`采集失败：${result.reason}\n`)
          process.exit(2)
        }
        if (options.json) process.stdout.write(`${JSON.stringify({ coverage: result.coverage, missing: result.missing }, null, 2)}\n`)
        else process.stdout.write(`诊断包已生成：${result.outDir}\n`)
        if (result.missing.length) {
          process.stderr.write(`有 ${result.missing.length} 个来源缺失（见包内 missing.json）\n`)
        }
        process.exit(result.exitCode)
      })
      .catch((error) => {
        process.stderr.write(`采集工具自身出错：${error.stack ?? error}\n`)
        process.exit(2)
      })
  }
}

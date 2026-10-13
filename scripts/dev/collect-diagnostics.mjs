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
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

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

  let match = /relay: device (\S+) \((\S+)\) attached to agent (\S+)/.exec(text)
  if (match) return { ...base, kind: 'relay.device-attach', deviceId: match[1], name: match[2], agentId: match[3] }
  match = /relay: device (\S+) detached \(([^)]*)\)/.exec(text)
  if (match) return { ...base, kind: 'relay.device-detach', deviceId: match[1], reason: match[2] }
  match = /relay: device (\S+) attached again while its previous socket is still open/.exec(text)
  if (match) return { ...base, kind: 'relay.device-replaced', deviceId: match[1] }
  match = /relay: device (\S+) closed a socket that had already been replaced/.exec(text)
  if (match) return { ...base, kind: 'relay.device-superseded-close', deviceId: match[1] }
  match = /relay: device (\S+) socket error: (.*)$/.exec(text)
  if (match) return { ...base, kind: 'relay.pong-timeout', deviceId: match[1], error: match[2].slice(0, MAX_TEXT) }
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
 * 所以有共同事件时优先用它。要求至少两条匹配、且彼此相差不超过 `spreadMs`——
 * 只有一条匹配时无法判断是不是巧合。
 */
export function computeOffsetFromCommonEvents(connectorEvents, relayEvents, { spreadMs = 500 } = {}) {
  const connectorAttach = new Map()
  for (const event of connectorEvents ?? []) {
    if (event.kind === 'device.attach' && !connectorAttach.has(event.deviceId)) {
      connectorAttach.set(event.deviceId, event.ms)
    }
  }
  const deltas = []
  for (const event of relayEvents ?? []) {
    if (event.kind !== 'relay.device-attach') continue
    const local = connectorAttach.get(event.deviceId)
    if (Number.isFinite(local)) deltas.push(event.ms - local)
  }
  if (deltas.length < 2) return null
  const sorted = [...deltas].sort((a, b) => a - b)
  const spread = sorted[sorted.length - 1] - sorted[0]
  if (spread > spreadMs) return null
  return {
    source: 'relay',
    offsetMs: median(deltas),
    method: 'common-event',
    rttMs: null,
    samples: deltas.length,
  }
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

/** 走 ssh 取中转日志（`-o json`：带 epoch 微秒，不必猜时区）。 */
export function readRelayLog({ host, since, agentIds = [], deviceIds = [] } = {}) {
  const command = `journalctl -u dsh-relay --since '${since}' --no-pager -o json`
  const text = execFileSync('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', `root@${host}`, command],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 60_000 })
  return { text, ...parseRelayLines(text, { agentIds, deviceIds }) }
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

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const options = parseArgs(process.argv.slice(2))
    if (options.help) {
      process.stdout.write(USAGE)
      process.exit(0)
    }
    process.stderr.write('collect-diagnostics: 出包流程尚未接完（tasks.md T039）\n')
    process.exit(2)
  } catch (error) {
    process.stderr.write(`${error.message}\n\n${USAGE}`)
    process.exit(2)
  }
}

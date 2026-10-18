#!/usr/bin/env node
/**
 * 看手机端日志（OTA 诊断构建推上来的那些）。
 *
 * 数据来源：连接器的落盘目录 `$DSH_HOME/mobile-link/logs/<deviceId>/<YYYYMMDD>.jsonl`，
 * 写入方是 `plugins/mobile-link/lib/logs.js`（保留 7 天，清理在写入路径上，没有定时任务）。
 * 本脚本只读，不连中转、不连 DSH、不改任何状态。
 *
 * 用法：
 *   node scripts/dev/ios-logs.mjs list
 *   node scripts/dev/ios-logs.mjs tail [--device <id|名字片段>] [--level warn] [--grep <正则>]
 *   node scripts/dev/ios-logs.mjs pull [--since 30m|6h|2d|ISO] [--device …] [--out 文件]
 *
 * `tail` 与 `pull` 共用同一套过滤；`tail` 跟随当天文件（跨零点自动换文件）。
 * 退出码：0 正常（Ctrl-C 也算 0）、1 参数或读取错误、2 用法错误。
 */

import { closeSync, openSync, readFileSync, readSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const USAGE = `用法: node scripts/dev/ios-logs.mjs <命令> [选项]

命令:
  list                          列出有日志的设备、占用与最后写入时间
  tail                          实时跟随（默认最新一天），Ctrl-C 结束
  pull                          把时间窗内的日志打到 stdout 或写文件

选项:
  --device <片段>               设备 id 或名字片段（不区分大小写；缺省＝全部设备）
  --level <级别>                只看该级别及以上（debug/info/warn/error）
  --grep <正则>                 只看匹配的日志正文
  --since <窗口>                pull 的时间窗（默认 1h；接受 30m/6h/2d 或 ISO 时刻）
  --out <文件>                  pull 写到文件而不是 stdout
  --root <目录>                 覆盖日志根目录（默认 $DSH_HOME/mobile-link/logs）
  --with-journal                pull 时把连接器 journal 合并进来（每条请求的耗时/字节）
  -h, --help                    显示本帮助
`

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 }

/** DSH_HOME 的口径与连接器一致（state.js 的 dshHome）。 */
export function dshHome(env = process.env) {
  const configured = String(env.DSH_HOME ?? '').trim()
  return configured || join(homedir(), '.dsh')
}

export function defaultLogsRoot(env = process.env) {
  return join(dshHome(env), 'mobile-link', 'logs')
}

/** 连接器 journal：与 App 日志同一个窗口合并读，才能把"整次取页"拆成每条请求。 */
export function defaultJournalPath(env = process.env) {
  return join(dshHome(env), 'mobile-link', 'link-events.jsonl')
}

/** 一条 journal 记录 → 与 App 日志同形的条目；不认识的 kind 原样保留关键字段。 */
export function journalEntry(raw) {
  if (!raw || typeof raw !== 'object') return null
  const ms = Number(raw.ms)
  if (!Number.isFinite(ms)) return null
  const parts = [String(raw.kind ?? 'journal')]
  for (const key of ['method', 'elapsedMs', 'bytes', 'ok', 'reason', 'error', 'deviceId',
                     'requests', 'slow', 'maxMs', 'p50Ms', 'p95Ms']) {
    if (raw[key] !== undefined) parts.push(`${key}=${raw[key]}`)
  }
  return {
    at: typeof raw.at === 'string' ? raw.at : new Date(ms).toISOString(),
    ms,
    level: raw.ok === false ? 'error' : 'info',
    source: 'connector',
    text: parts.join(' '),
  }
}

/** `30m` / `6h` / `2d` / ISO → 起始毫秒；解析失败抛错。 */
export function parseSince(value, now = Date.now()) {
  const raw = String(value ?? '').trim()
  const relative = /^(\d+)([mhd])$/.exec(raw)
  if (relative) {
    const scale = { m: 60_000, h: 3_600_000, d: 86_400_000 }[relative[2]]
    return now - Number(relative[1]) * scale
  }
  const at = Date.parse(raw)
  if (Number.isFinite(at)) return at
  throw new Error(`无法解析时间窗：${value}（示例：30m / 6h / 2d / 2026-10-18T10:00:00Z）`)
}

/** 目录列表；不存在时返回空（没日志不是错误）。 */
export function deviceDirs(root) {
  try {
    return readdirSync(root, { withFileTypes: true })
      .filter((item) => item.isDirectory())
      .map((item) => item.name)
      .sort()
  } catch {
    return []
  }
}

/** 某台设备的日文件，按名字（日期）升序。 */
export function dayFiles(root, deviceId) {
  const dir = join(root, deviceId)
  try {
    return readdirSync(dir)
      .filter((name) => name.endsWith('.jsonl'))
      .sort()
      .map((name) => join(dir, name))
  } catch {
    return []
  }
}

/** 设备过滤：子串匹配，不区分大小写；不传＝全部。 */
export function matchDevice(deviceId, selector) {
  if (!selector) return true
  return String(deviceId).toLowerCase().includes(String(selector).toLowerCase())
}

/** 一行 JSONL → 过滤判定。坏行（截断、写了一半）原样放过，否则丢的是现场。 */
export function keepLine(line, { level, grep } = {}) {
  const text = line.trimEnd()
  if (!text) return false
  let entry
  try {
    entry = JSON.parse(text)
  } catch {
    return true
  }
  if (level) {
    const rank = LEVELS[String(level).toLowerCase()] ?? 0
    const own = LEVELS[String(entry.level ?? 'info').toLowerCase()] ?? LEVELS.info
    if (own < rank) return false
  }
  if (grep && !grep.test(String(entry.text ?? ''))) return false
  return true
}

function formatLine(line) {
  const text = line.trimEnd()
  let entry
  try {
    entry = JSON.parse(text)
  } catch {
    return text
  }
  const at = typeof entry.at === 'string' ? entry.at.replace('T', ' ').replace('Z', '') : ''
  const level = String(entry.level ?? 'info').toUpperCase().padEnd(5)
  const source = entry.source ? ` ${entry.source}` : ''
  return `${at} ${level}${source} ${entry.text ?? ''}`
}

function readRange(path, from, to) {
  const size = statSync(path).size
  if (size <= from) return Buffer.alloc(0)
  const length = Math.min(size, to ?? size) - from
  const fd = openSync(path, 'r')
  try {
    const buffer = Buffer.alloc(length)
    readSync(fd, buffer, 0, length, from)
    return buffer
  } finally {
    closeSync(fd)
  }
}

function cmdList({ root }) {
  const devices = deviceDirs(root)
  if (!devices.length) {
    console.log(`没有日志（${root}）；OTA 诊断构建连上连接器后才会有。`)
    return 0
  }
  for (const deviceId of devices) {
    const files = dayFiles(root, deviceId)
    let bytes = 0
    let newest = 0
    for (const file of files) {
      try {
        const info = statSync(file)
        bytes += info.size
        newest = Math.max(newest, info.mtimeMs)
      } catch { /* 正在滚动 */ }
    }
    const when = newest ? new Date(newest).toLocaleString() : '—'
    console.log(`${deviceId}\t${(bytes / 1024).toFixed(1)} KB\t${files.length} 天\t最后写入 ${when}`)
  }
  return 0
}

function cmdPull({ root, device, since, out, level, grep, withJournal }) {
  const fromMs = parseSince(since)
  const devices = deviceDirs(root).filter((id) => matchDevice(id, device))
  if (!devices.length) {
    console.error(`没有匹配的设备（${root}）`)
    return 1
  }
  const lines = []
  for (const deviceId of devices) {
    for (const file of dayFiles(root, deviceId)) {
      let text = ''
      try {
        text = readFileSync(file, 'utf8')
      } catch {
        continue
      }
      for (const line of text.split('\n')) {
        const kept = keepLine(line, { level, grep })
        if (!kept) continue
        let entry = null
        try { entry = JSON.parse(line) } catch { /* 坏行照收 */ }
        if (entry && Number.isFinite(entry.ms) && entry.ms < fromMs) continue
        lines.push(line)
      }
    }
  }
  if (withJournal) {
    // 连接器 journal 与 App 日志按时刻归并：同一个窗口里既有"整次取页"，
    // 也有每一笔 sessionWindow 的耗时与字节，能直接看出瓶颈在宿主还是在本机。
    let text = ''
    try { text = readFileSync(defaultJournalPath(), 'utf8') } catch { /* 没有 journal 不算错 */ }
    const merged = []
    for (const line of text.split('\n')) {
      if (!line.trim()) continue
      let raw
      try { raw = JSON.parse(line) } catch { continue }
      if (Number.isFinite(raw.ms) && raw.ms < fromMs) continue
      if (device && raw.deviceId && !matchDevice(raw.deviceId, device)) continue
      const entry = journalEntry(raw)
      if (!entry) continue
      if (!keepLine(JSON.stringify(entry), { level, grep })) continue
      merged.push(JSON.stringify(entry))
    }
    lines.push(...merged)
    lines.sort((a, b) => {
      try { return (JSON.parse(a).ms ?? 0) - (JSON.parse(b).ms ?? 0) } catch { return 0 }
    })
  }
  const body = lines.join('\n') + (lines.length ? '\n' : '')
  if (out) {
    writeFileSync(out, body)
    console.error(`写入 ${out}（${lines.length} 行）`)
  } else {
    process.stdout.write(body)
  }
  return 0
}

async function cmdTail({ root, device, level, grep }) {
  // 跟随策略：每 400ms 读一次当天文件的新增部分；跨零点时自动切到新文件。
  // 不用 `watch`：日文件轮换、目录不存在、文件被清理这三种情况都要能自恢复，
  // 轮询是唯一不依赖平台差异的做法，代价是 400ms 的延迟。
  const state = new Map() // path -> offset
  let stopped = false
  process.on('SIGINT', () => { stopped = true })

  const pump = () => {
    const devices = deviceDirs(root).filter((id) => matchDevice(id, device))
    for (const deviceId of devices) {
      const files = dayFiles(root, deviceId)
      const file = files[files.length - 1]
      if (!file) continue
      const offset = state.get(file)
      if (offset === undefined) {
        // 第一次见到这个文件：从头读，但只保留最近 2KB，免得一开就把历史全刷出来。
        const size = statSync(file).size
        const start = Math.max(0, size - 2048)
        const buffer = readRange(file, start)
        state.set(file, start + buffer.length)
        for (const line of buffer.toString('utf8').split('\n')) {
          if (!line) continue
          if (keepLine(line, { level, grep })) console.log(`[${deviceId}] ${formatLine(line)}`)
        }
        continue
      }
      const size = statSync(file).size
      if (size <= offset) continue
      const buffer = readRange(file, offset, size)
      state.set(file, offset + buffer.length)
      for (const line of buffer.toString('utf8').split('\n')) {
        if (!line) continue
        if (keepLine(line, { level, grep })) console.log(`[${deviceId}] ${formatLine(line)}`)
      }
    }
  }

  console.log(`跟随 ${root}${device ? `（设备含「${device}」）` : ''}，Ctrl-C 结束`)
  while (!stopped) {
    try {
      pump()
    } catch (error) {
      console.error(`读取失败：${error.message}`)
    }
    await new Promise((resolve) => setTimeout(resolve, 400))
  }
  return 0
}

function parseArgs(argv) {
  const options = { level: '', grep: '', since: '1h', out: '', root: '', device: '',
                    command: '', withJournal: false }
  const rest = []
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '-h' || arg === '--help') return { help: true }
    if (!arg.startsWith('--')) { rest.push(arg); continue }
    const key = arg.slice(2)
    if (key === 'with-journal') { options.withJournal = true; continue }
    const value = argv[i + 1]
    if (value === undefined) throw new Error(`缺少 ${arg} 的值`)
    i += 1
    if (!(key in options)) throw new Error(`未知参数 --${key}`)
    options[key] = value
  }
  options.command = rest[0] ?? ''
  if (rest.length > 1) throw new Error(`多余的参数：${rest.slice(1).join(' ')}`)
  if (options.grep) options.grep = new RegExp(options.grep)
  return options
}

async function main() {
  let options
  try {
    options = parseArgs(process.argv.slice(2))
  } catch (error) {
    console.error(error.message)
    console.error(USAGE)
    return 2
  }
  if (options.help) { console.log(USAGE); return 0 }
  const root = options.root || defaultLogsRoot()
  const common = { root, device: options.device, level: options.level, grep: options.grep }
  switch (options.command) {
    case '': console.log(USAGE); return 2
    case 'list': return cmdList(common)
    case 'tail': return cmdTail(common)
    case 'pull': return cmdPull({ ...common, since: options.since, out: options.out,
                                  withJournal: options.withJournal })
    default:
      console.error(`未知命令：${options.command}`)
      console.error(USAGE)
      return 2
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const code = await main()
  process.exit(code)
}

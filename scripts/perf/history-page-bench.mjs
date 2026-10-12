/**
 * 历史页性能基准（离线、只读、可复跑）。
 *
 * 目的：给「会话历史加载提速」的每一项改动留下改前/改后的可比数字。它不联网、
 * 不启动 DSH、不写任何会话文件：只从本机 `~/.dsh/sessions` 里读一段真实日志，
 * 按连接器**现在的分页规则**（`lib/history/window.js`：limit 50 / maxBytes 256KB /
 * 每块 51 条原始事件）重放出一串页面，然后分别按「现在这样发」与「剔除
 * `data.stream` 之后发」统计字节、压缩比与往返次数。
 *
 *   node scripts/perf/history-page-bench.mjs                    # 自动挑最大的会话
 *   node scripts/perf/history-page-bench.mjs --session <id>
 *   node scripts/perf/history-page-bench.mjs --json             # 机器可读
 *
 * 口径与 `lib/history/records.js` 的默认值保持一致；若那边改了默认值，这里跟着改
 * （脚本会把它当参数打印出来，便于对账）。
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import zlib from 'node:zlib'
import { execFileSync } from 'node:child_process'

const LIMIT = 50
const MAX_BYTES = 256 * 1024
const WINDOW_CHUNK = 50

function parseArgs(argv) {
  const out = {
    json: false,
    session: undefined,
    maxPages: 400,
    dir: path.join(os.homedir(), '.dsh', 'sessions'),
    emitFixtures: undefined,
  }
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--json') out.json = true
    else if (arg === '--engine') out.engine = true
    else if (arg === '--session') out.session = argv[++i]
    else if (arg === '--max-pages') out.maxPages = Number(argv[++i])
    else if (arg === '--dir') out.dir = argv[++i]
    else if (arg === '--emit-fixtures') out.emitFixtures = argv[++i]
    else if (arg === '--help' || arg === '-h') out.help = true
  }
  return out
}

/** Newest `session.v*.jsonl.zstd` under one project directory. */
function sessionsIn(dir) {
  const found = []
  if (!fs.existsSync(dir)) return found
  for (const project of fs.readdirSync(dir)) {
    const projectPath = path.join(dir, project)
    let entries = []
    try { entries = fs.readdirSync(projectPath) } catch { continue }
    for (const entry of entries) {
      const sessionDir = path.join(projectPath, entry)
      let files = []
      try { files = fs.readdirSync(sessionDir) } catch { continue }
      for (const file of files) {
        if (!/^session\.v\d+\.jsonl\.zstd$/.test(file)) continue
        const full = path.join(sessionDir, file)
        found.push({ sessionId: entry, project, file: full, size: fs.statSync(full).size })
      }
    }
  }
  return found
}

function pickSession(args) {
  const all = sessionsIn(args.dir)
  if (all.length === 0) throw new Error(`no session logs under ${args.dir}`)
  if (args.session !== undefined) {
    const hit = all.filter((s) => s.sessionId.includes(args.session))
    if (hit.length === 0) throw new Error(`no session matching ${args.session}`)
    return hit.sort((a, b) => b.size - a.size)[0]
  }
  return all.sort((a, b) => b.size - a.size)[0]
}

function readEvents(file) {
  const raw = execFileSync('zstd', ['-d', '-c', file], { maxBuffer: 1 << 30 }).toString('utf8')
  const events = []
  for (const line of raw.split('\n')) {
    if (!line) continue
    try { events.push(JSON.parse(line)) } catch { /* a truncated tail line is not our business */ }
  }
  return events
}

/** Drop the host's raw model-output log; it is diagnostics the phone never renders. */
function withoutStream(event) {
  if (event === null || typeof event !== 'object') return event
  const data = event.data
  if (data === null || typeof data !== 'object' || !('stream' in data)) return event
  const { stream: _dropped, ...rest } = data
  return { ...event, data: rest }
}

function bytesOf(value) {
  return Buffer.byteLength(JSON.stringify(value), 'utf8')
}

function toRecord(event) {
  return { type: 'event', event }
}

/**
 * One backward scan with the connector's own rules (records.js + window.js).
 * Returns pages in the order the phone asks for them: newest edge first.
 */
function pages(events, { clean }) {
  const out = []
  let cursor = events.length - 1
  for (let guard = 0; guard < 10000 && cursor >= 0; guard += 1) {
    const start = Math.max(0, cursor - WINDOW_CHUNK)
    const batch = events.slice(start, cursor + 1).map((e) => (clean ? withoutStream(e) : e))
    let records = batch.map(toRecord)
    let trimming = 0
    while (records.length > 1 && bytesOf(records) > MAX_BYTES) { records.shift(); trimming += 1 }
    if (records.length > LIMIT) { trimming += records.length - LIMIT; records.splice(0, records.length - LIMIT) }
    if (records.length === 0) break
    out.push({
      records,
      bytes: bytesOf(records),
      dropped: trimming,
      startSeq: records[0].event.seq,
      endSeq: records[records.length - 1].event.seq,
    })
    const lowest = batch[0]?.seq ?? events[start].seq
    const next = lowest - 1
    if (next >= cursor) break
    cursor = next
  }
  return out
}

function summarize(name, list) {
  const sizes = list.map((p) => p.bytes)
  const sorted = [...sizes].sort((a, b) => a - b)
  const total = sizes.reduce((sum, n) => sum + n, 0)
  const median = sorted[Math.floor(sorted.length / 2)] ?? 0
  const all = list.flatMap((p) => p.records)
  const allBytes = bytesOf(all)
  const gz = zlib.gzipSync(JSON.stringify(all)).length
  const br = zlib.brotliCompressSync(JSON.stringify(all)).length
  return {
    name,
    pages: list.length,
    totalBytes: total,
    medianPageBytes: median,
    maxPageBytes: sorted[sorted.length - 1] ?? 0,
    records: all.length,
    gzipBytes: gz,
    brotliBytes: br,
    droppedRecords: list.reduce((sum, p) => sum + p.dropped, 0),
  }
}

function fmtMB(bytes) { return `${(bytes / 1048576).toFixed(2)}MB` }
function fmtKB(bytes) { return `${(bytes / 1024).toFixed(0)}KB` }

/**
 * 把「最大的一页」写成两个 fixture，供 iOS 侧解码基准（Swift 包）对照：
 * 全字段版与剔除 `data.stream` 版**是同一页**，所以两边的解码耗时可以直接比。
 */
function writeFixtures(dir, beforePages, afterPages) {
  fs.mkdirSync(dir, { recursive: true })
  let best = 0
  for (let i = 1; i < beforePages.length; i += 1) {
    if (beforePages[i].bytes > beforePages[best].bytes) best = i
  }
  const full = path.join(dir, 'page-full.json')
  const trimmed = path.join(dir, 'page-no-stream.json')
  fs.writeFileSync(full, JSON.stringify(beforePages[best].records))
  fs.writeFileSync(trimmed, JSON.stringify(afterPages[best].records))
  console.log(`fixtures  ${full}  ${fmtKB(beforePages[best].bytes)}`)
  console.log(`          ${trimmed}  ${fmtKB(afterPages[best].bytes)}`)
}

function report(session, before, after) {
  const pct = (a, b) => `${(100 * b / a).toFixed(0)}%`
  const lines = []
  lines.push(`session   ${session.sessionId}  (${session.project})`)
  lines.push(`log       ${session.file}`)
  lines.push(`rules     limit=${LIMIT} maxBytes=${MAX_BYTES} chunk=${WINDOW_CHUNK}`)
  lines.push('')
  lines.push('               pages    整段字节   单页中位   单页最大   gzip(整段)  brotli(整段)')
  for (const r of [before, after]) {
    lines.push(
      `${r.name.padEnd(14)} ${String(r.pages).padStart(5)}  ${fmtMB(r.totalBytes).padStart(9)}  ` +
      `${fmtKB(r.medianPageBytes).padStart(9)}  ${fmtKB(r.maxPageBytes).padStart(9)}  ` +
      `${fmtMB(r.gzipBytes).padStart(11)}  ${fmtMB(r.brotliBytes).padStart(12)}`
    )
  }
  lines.push('')
  lines.push(`剔除 data.stream 后：整段 ${pct(before.totalBytes, after.totalBytes)}、` +
    `单页中位 ${pct(before.medianPageBytes, after.medianPageBytes)}、往返次数 ${before.pages} → ${after.pages}`)
  return lines.join('\n')
}

/// 宿主 `ctx.sessionQuery` 的最小桩：只实现窗口读取与列表，语义与真机一致
/// （`before` 硬上限 50；seq 不存在时抛"has no event at seq"）。
function sessionQueryStub(log) {
  return {
    async readEvent({ sessionId, seq, before }) {
      if (!Number.isInteger(before) || before < 0 || before > WINDOW_CHUNK) {
        throw new Error('before must be an integer between 0 and 50')
      }
      if (!Number.isInteger(seq) || seq < 0 || seq >= log.length) {
        const error = new Error(`session "${sessionId}" has no event at seq ${seq}`)
        error.code = 'SESSION_QUERY_EVENT_NOT_FOUND'
        throw error
      }
      const start = Math.max(0, seq - before)
      return {
        sessionId, startSeq: start, endSeq: seq,
        events: log.slice(start, seq + 1).map((event) => ({ ...event })),
      }
    },
    async listEvents(sessionId) {
      return log.map((event) => ({ sessionId, seq: event.seq, type: event.type, time: event.time }))
    },
  }
}

/**
 * 用**真实连接器代码**（`plugins/mobile-link/lib/history.js` + `router.js` 的清洗）
 * 跑同一段日志，并给出两套数字。
 *
 * 为什么要有这一档：上面的 `pages()` 是本脚本按规则重放的（速度用），而这一档跑的是
 * 真实实现。真实分页有一条重放没有的规则——**一个 51 条的块可能整块被算作一页**
 * （字节预算超了就在块边界停），所以页数会比重放多；也正因如此，真实模式下的
 * 数字才是对外该引用的口径。
 *
 * 同一批记录同时算出「原样下发」与「剔除 `data.stream` 后下发」的字节，比例因此
 * 归因于清洗本身，而不是两个不同样本。
 */
async function enginePages(events, maxPages) {
  const { createHistoryService, WINDOW_METHOD } = await import('../../plugins/mobile-link/lib/history.js')
  const log = events.map((event) => ({ ...event }))
  const sessionId = 'bench-session'
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  service.bindQuery(sessionQueryStub(log))

  const newestSeq = log[log.length - 1]?.seq ?? -1
  const address = { kind: 'session', sessionId }
  const collected = []
  let before
  while (collected.length < maxPages) {
    const result = await service.handle(WINDOW_METHOD, {
      address, before: before ?? newestSeq + 1, limit: LIMIT, maxBytes: MAX_BYTES,
    })
    if (!result.ok) throw new Error(`engine page failed: ${JSON.stringify(result.error)}`)
    const page = result.value
    if (page.records.length === 0) break
    for (const record of page.records) {
      if ('stream' in (record.event?.data ?? {})) {
        throw new Error(`engine page still carries data.stream at seq ${record.event.seq}`)
      }
    }
    collected.push(page.records)
    if (page.hasMore !== true || page.startSeq === null || page.startSeq <= 0) break
    before = page.startSeq
  }

  // 旧分页通道走的是 router 的入口：同一段日志上它也必须清洗掉。
  const { trimHistoryPageForWire } = await import('../../plugins/mobile-link/lib/router.js')
  const lastEvent = log[log.length - 1]
  const legacy = trimHistoryPageForWire('session/page', {
    ok: true, value: { records: [{ type: 'event', event: lastEvent }], hasMore: true },
  })
  if ('stream' in (legacy.value.records[0].event.data ?? {})) throw new Error('router trim did not fire')

  // 连接器手里的记录已被清洗过（`seq` 保持原值），所以"原样下发"的那一份要按 seq
  // 从原始日志里取回来重建——同一批记录、两种下发形态，比例才归因于清洗本身。
  const bySeq = new Map(log.map((event) => [event.seq, event]))
  const original = collected.map((records) => records.map(({ event }) => ({ type: 'event', event: bySeq.get(event.seq) ?? event })))
  const stripped = collected.map((records) => records.map(({ event }) => ({ type: 'event', event: withoutStream(event) })))
  return { collected, original, withoutStream: stripped }
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.help) {
    console.log('usage: node scripts/perf/history-page-bench.mjs [--session <substring>] [--json] [--max-pages N] [--emit-fixtures DIR] [--engine]')
    return
  }
  const session = pickSession(args)
  const events = readEvents(session.file)
  const beforePages = pages(events, { clean: false }).slice(0, args.maxPages)
  const afterPages = pages(events, { clean: true }).slice(0, args.maxPages)
  if (args.emitFixtures !== undefined) {
    writeFixtures(args.emitFixtures, beforePages, afterPages)
  }
  const before = summarize('现在（全字段）', beforePages)
  const after = summarize('剔除 data.stream', afterPages)
  if (args.engine) {
    const { original, withoutStream } = await enginePages(events, args.maxPages)
    const engineBefore = summarize('connector·原样', original.map((records) => ({ records, bytes: bytesOf(records), dropped: 0 })))
    const engineAfter = summarize('connector·剔除', withoutStream.map((records) => ({ records, bytes: bytesOf(records), dropped: 0 })))
    console.log('（--engine：上面两行是脚本重放，下面两行是**真实连接器实现**跑出来的）')
    console.log(report(session, engineBefore, engineAfter))
    if (args.json) {
      console.log(JSON.stringify({ engine: { before: engineBefore, after: engineAfter } }, null, 2))
    }
  }
  if (args.json) {
    console.log(JSON.stringify({
      session: { sessionId: session.sessionId, project: session.project, file: session.file },
      rules: { limit: LIMIT, maxBytes: MAX_BYTES, chunk: WINDOW_CHUNK, events: events.length },
      before, after, engine,
      ratio: { bytes: after.totalBytes / before.totalBytes, median: after.medianPageBytes / before.medianPageBytes },
    }, null, 2))
    return
  }
  console.log(report(session, before, after))
}

await main()

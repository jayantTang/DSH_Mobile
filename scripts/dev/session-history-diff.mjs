#!/usr/bin/env node
/**
 * 手机侧 vs 电脑侧：同一条会话的历史记录逐条比对（只读）。
 *
 * 为什么要有这个工具：验证"历史是否完整/连续/一致"这类问题，截图和手动下拉既看不全
 * 又慢（2026-09-25 用户明确要求换思路）。这里直接读两边的原始记录做文本比对：
 *
 *   电脑侧：~/.dsh/sessions/*​/<sessionId>/session.v3.jsonl.zstd（host 的完整日志）
 *   手机侧：仿真器 App 容器里 Caches/transcripts/<scope>/<sessionId>.json（转写尾部）
 *           与 …/<sessionId>.older.json（搜索往前读过的更早历史）
 *
 * 输出：两边的 seq 覆盖、手机侧每一段的连续性、重叠区内容是否逐字节一致、
 * 手机侧最老一条是不是"该会话第一条可显示的消息"（照 App 的折叠规则判）。
 *
 * 用法：
 *   node scripts/dev/session-history-diff.mjs                    # 所有有缓存的会话
 *   node scripts/dev/session-history-diff.mjs --session <id>     # 指定会话
 *   node scripts/dev/session-history-diff.mjs --text <id>        # 顺带打印手机侧前 N 条
 *   node scripts/dev/session-history-diff.mjs --lines 20 --json
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const args = process.argv.slice(2)
const flag = (name, fallback = null) => {
  const i = args.indexOf(`--${name}`)
  if (i < 0) return fallback
  const next = args[i + 1]
  return next && !next.startsWith('--') ? next : true
}
const only = flag('session')
const textFor = flag('text')
const lines = Number(flag('lines', 12))
const json = flag('json') === true

/// App 的数据容器（取第一台装了 App 的已启动仿真器；可用 --device 指定）。
function appContainer() {
  const device = flag('device')
  const udids = device ? [device] : execFileSync('xcrun', ['simctl', 'list', 'devices', 'booted'], { encoding: 'utf8' })
    .split('\n').map((l) => /\(([0-9A-F-]{36})\)/.exec(l)?.[1]).filter(Boolean)
  for (const udid of udids) {
    try {
      return execFileSync('xcrun', ['simctl', 'get_app_container', udid, 'com.jayanttang.dsh', 'data'],
                          { encoding: 'utf8' }).trim()
    } catch { /* 这台没装 */ }
  }
  throw new Error('没有找到装了 com.jayanttang.dsh 的已启动仿真器')
}

function hostLog(sessionId) {
  const root = join(homedir(), '.dsh', 'sessions')
  for (const group of readdirSync(root)) {
    const file = join(root, group, sessionId, 'session.v3.jsonl.zstd')
    if (existsSync(file)) {
      return execFileSync('zstd', ['-dc', file], { encoding: 'utf8', maxBuffer: 1 << 30 })
    }
  }
  return null
}

/// 一行日志 → { seq, type, data, line }；没有 seq 的（会话头）跳过。
function recordsOf(text) {
  const out = new Map()
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    let event
    try { event = JSON.parse(line) } catch { continue }
    if (typeof event.seq !== 'number') continue
    // 首次出现优先：同一 seq 重复写时以后者为准（host 会重写被裁的段）
    out.set(event.seq, { seq: event.seq, type: event.type, data: event.data, line, event })
  }
  return out
}

/// 被后续 `agent/inbox/spliced`（removedCount>0 且同 start）撤销掉的插入 seq。
function cancelledSplices(host) {
  const insertedAt = new Map()   // start -> seq
  const cancelled = new Set()
  for (const seq of [...host.keys()].sort((a, b) => a - b)) {
    const event = host.get(seq).event
    if (event.type !== 'agent/inbox/spliced') continue
    const start = event.data?.start
    const removed = event.data?.removedCount ?? (event.data?.removed ?? []).length ?? 0
    if (removed > 0 && insertedAt.has(start)) cancelled.add(insertedAt.get(start))
    const inserted = event.data?.inserted ?? []
    if (inserted.length) insertedAt.set(start, seq)
  }
  return cancelled
}

/// 照 App 的折叠规则：这一条会不会被渲染成一行（用于判"第一条可显示的消息"）。
function renders(event) {
  if (event.type === 'user/message') {
    const kind = event.data?.source?.kind ?? 'user'
    if (kind !== 'user') return false
    const blocks = event.data?.content ?? []
    const text = blocks.filter((b) => b?.type === 'text').map((b) => b.text ?? '').join('')
    return text.trim().length > 0 || blocks.some((b) => b?.type === 'image')
  }
  if (event.type === 'assistant/message') {
    const blocks = event.data?.message?.content ?? []
    return blocks.some((b) => b?.type === 'text' && (b.text ?? '').trim()) ||
           blocks.some((b) => b?.type === 'tool_use' || b?.type === 'tool-call')
  }
  if (event.type === 'tool/call') return true
  if (event.type === 'agent/inbox/spliced') {
    // 排队的回显：插进来过才算一行（被撤销的那种 inserted 为空，App 不显示）。
    const kind = event.data?.source?.kind ?? 'user'
    if (kind !== 'user') return false
    const inserted = event.data?.inserted ?? []
    return inserted.some((message) => (message?.content ?? []).some((b) =>
      (b?.type === 'text' && (b.text ?? '').trim()) || b?.type === 'image'))
  }
  return false
}

function summarize(text) {
  if (!text) return null
  const brief = text.replace(/\s+/g, ' ').slice(0, 70)
  if (text.includes('"user/message"') || false) return brief
  return brief
}

/// 键序无关的深比较：手机侧是 App 重新编码过的 JSON，字段顺序与 host 原文不同，
/// 拿字符串比会把每一条都报成"不一致"（第一版就是这样，98/98 全红）。
function stable(value) {
  if (Array.isArray(value)) return value.map(stable)
  if (value && typeof value === 'object') {
    return Object.keys(value).sort().reduce((out, key) => { out[key] = stable(value[key]); return out }, {})
  }
  return value
}
/// 只比 App 模型真有的字段：host 的行还会带 `sourceEventSeqs` 之类模型外的字段，
/// 拿整行比会把"App 没存这个字段"报成内容不一致。
const MODEL_FIELDS = ['type', 'seq', 'time', 'data', 'surfaceOp']
const comparable = (value) => MODEL_FIELDS.reduce((out, key) => {
  if (value?.[key] !== undefined) out[key] = value[key]
  return out
}, {})
const sameEvent = (a, b) => JSON.stringify(stable(comparable(a))) === JSON.stringify(stable(comparable(b)))

function runsOf(seqs) {
  const sorted = [...seqs].sort((a, b) => a - b)
  const runs = []
  let start = sorted[0], prev = sorted[0]
  for (const s of sorted.slice(1)) {
    if (s === prev + 1) { prev = s; continue }
    runs.push([start, prev]); start = prev = s
  }
  if (sorted.length) runs.push([start, prev])
  return runs
}

const container = appContainer()
const cacheRoot = join(container, 'Library', 'Caches', 'transcripts')
if (!existsSync(cacheRoot)) throw new Error(`App 里还没有转写缓存：${cacheRoot}`)

const report = []
for (const scope of readdirSync(cacheRoot)) {
  const dir = join(cacheRoot, scope)
  for (const file of readdirSync(dir)) {
    if (!file.endsWith('.json') || file.endsWith('.older.json')) continue
    const sessionId = file.replace(/\.json$/, '')
    if (only && only !== true && only !== sessionId) continue
    const tail = JSON.parse(readFileSync(join(dir, file), 'utf8'))
    const olderFile = join(dir, `${sessionId}.older.json`)
    const older = existsSync(olderFile) ? JSON.parse(readFileSync(olderFile, 'utf8')) : null
    const hostText = hostLog(sessionId)
    const host = hostText ? recordsOf(hostText) : new Map()

    const phone = new Map()
    const duplicates = []
    for (const snap of [tail, older].filter(Boolean)) {
      for (const record of snap.records ?? []) {
        const seq = record.event?.seq
        if (phone.has(seq)) duplicates.push(seq)
        phone.set(seq, record.event)
      }
    }
    const phoneSeqs = [...phone.keys()]
    const hostSeqs = [...host.keys()]
    const overlap = phoneSeqs.filter((s) => host.has(s))
    const mismatch = overlap.filter((s) => !sameEvent(phone.get(s), host.get(s).event))
    const oldestPhone = phoneSeqs.length ? Math.min(...phoneSeqs) : null
    const cancelled = cancelledSplices(host)
    const firstRenderable = hostSeqs.length
      ? Math.min(...hostSeqs.filter((s) => !cancelled.has(s) && renders(host.get(s).event)))
      : null
    const missingBefore = oldestPhone === null ? [] : hostSeqs.filter((s) => s < oldestPhone)
    // 第一条可显示消息之前那些记录的类型清单——"为什么从第 8 条开始"就看这个。
    const beforeFirst = firstRenderable === null ? [] : hostSeqs
      .filter((s) => s < firstRenderable)
      .map((s) => host.get(s).type)
      .reduce((out, type) => { out[type] = (out[type] ?? 0) + 1; return out }, {})

    report.push({
      sessionId, scope,
      host: { records: hostSeqs.length, min: Math.min(...hostSeqs), max: Math.max(...hostSeqs),
              missing: hostSeqs.length ? (Math.max(...hostSeqs) - Math.min(...hostSeqs) + 1 - hostSeqs.length) : 0 },
      phone: { records: phoneSeqs.length, runs: runsOf(phoneSeqs), tail: tail?.records?.length ?? 0,
               older: older?.records?.length ?? 0, duplicates },
      overlap: { count: overlap.length, mismatch: mismatch.length, mismatchSeqs: mismatch.slice(0, 5) },
      oldestPhone, firstRenderable, beforeFirst,
      hostRecordsBeforePhone: missingBefore.length,
      phoneReachedStart: oldestPhone !== null && firstRenderable !== null && oldestPhone <= firstRenderable,
    })
  }
}

const head = (record) => {
  if (record.type === 'user/message') {
    const blocks = record.data?.content ?? []
    const t = blocks.filter((b) => b?.type === 'text').map((b) => b.text ?? '').join('')
    return `${record.data?.source?.kind ?? 'user'} 「${t.replace(/\s+/g, ' ').slice(0, 60)}」`
  }
  return String(record.type)
}

if (json) { console.log(JSON.stringify(report, null, 1)); process.exit(0) }

for (const r of report) {
  console.log(`\n=== ${r.sessionId}  (scope ${r.scope})`)
  console.log(`  电脑侧: ${r.host.records} 条, seq ${r.host.min}..${r.host.max}, 洞 ${r.host.missing}`)
  console.log(`  手机侧: ${r.phone.records} 条（尾部 ${r.phone.tail} + 更早 ${r.phone.older}），连续段:`)
  for (const [a, b] of r.phone.runs) console.log(`      ${a}..${b}  (${b - a + 1} 条)`)
  console.log(`  重叠 ${r.overlap.count} 条，逐字节不一致 ${r.overlap.mismatch}${r.overlap.mismatch ? ' → ' + r.overlap.mismatchSeqs.join(',') : ''}`)
  console.log(`  电脑侧第一条**可显示**的消息 seq ${r.firstRenderable}；它前面是 ` +
              Object.entries(r.beforeFirst).map(([t, n]) => `${t}×${n}`).join('、') +
              '（运行时簿记，App 不折叠成行）')
  console.log(`  手机侧最老一条 seq ${r.oldestPhone}：` +
              (r.phoneReachedStart ? '已覆盖到会话开头 ✓'
                                   : `还没读到开头，离第一条可显示的消息还差 ${(r.oldestPhone ?? 0) - (r.firstRenderable ?? 0)} 个 seq（按需加载的正常状态）`))
  if (r.phone.duplicates.length) console.log(`  ⚠️ 两个缓存文件里重复的 seq: ${r.phone.duplicates.slice(0, 8).join(',')}`)
  if (textFor === r.sessionId) {
    const text = hostLog(r.sessionId)
    const bySeq = recordsOf(text)
    const phoneSeqs = r.phone.runs.flatMap(([a, b]) => { const out = []; for (let s = a; s <= b; s++) out.push(s); return out })
    console.log(`  --- 手机侧最早 ${lines} 条（文本）:`)
    for (const seq of phoneSeqs.slice(0, lines)) {
      const event = JSON.parse(bySeq.get(seq).line)
      console.log(`      ${seq}  ${head(event)}`)
    }
    console.log(`  --- 电脑侧最早 ${lines} 条（文本）:`)
    for (const seq of [...bySeq.keys()].sort((a, b) => a - b).slice(0, lines)) {
      console.log(`      ${seq}  ${head(JSON.parse(bySeq.get(seq).line))}`)
    }
  }
}

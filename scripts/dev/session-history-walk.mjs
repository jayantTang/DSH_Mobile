#!/usr/bin/env node
/**
 * 手机侧"能"加载到哪：照 App 的翻页算法把 host 的整段历史走一遍（只读，不碰 App）。
 *
 * 与 session-history-diff.mjs 是一对：
 *   * 这个回答"能不能全量、连续地读到会话开头"（走 host 的 session/page + 边界校正）；
 *   * 那个回答"手机上实际存下来的，与电脑侧逐条是否一致"（比缓存文件与日志）。
 * 两者都不需要截图或手动下拉（用户 2026-09-25 要求）。
 *
 * 用法：
 *   node scripts/dev/session-history-walk.mjs <sessionId> [<sessionId> …]
 *   node scripts/dev/session-history-walk.mjs --top 8      # 取记录最多的 8 个会话
 */

import { readFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'

const raw = JSON.parse(readFileSync(join(homedir(), '.dsh', 'desktop-shell', 'endpoint.json'), 'utf8'))
const token = /token=([^&]+)/.exec(raw.url)?.[1]
const res = await fetch(`http://127.0.0.1:${raw.port}/?token=${token}`, { redirect: 'manual' })
const cookie = (res.headers.getSetCookie?.()[0] ?? res.headers.get('set-cookie')).split(';')[0]
let seqNo = 0
async function call(method, args) {
  const r = await fetch(`http://127.0.0.1:${raw.port}/api/${method}`, {
    method: 'POST', headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ type: 'client-request', rpcId: `x${++seqNo}`, method, payload: { args } }),
  })
  return (await r.json()).result
}
const listValue = (await call('session/list', { _request: {} })).value
const cursorOf = new Map((listValue.items ?? []).map((i) => [i.sessionId, i.projections?.asOfSeq ?? 1 << 30]))
const logDir = join(homedir(), '.dsh', 'sessions')
const groups = execFileSync('ls', ['-1', logDir], { encoding: 'utf8' }).trim().split('\n')
function logPath(id) {
  for (const g of groups) { const p = join(logDir, g, id, 'session.v3.jsonl.zstd'); if (existsSync(p)) return p }
  return null
}

/// 盘上真值：seq 集合、人类提问（带 seq / 有没有正文 / 有没有图）、非人类 user/message 数。
function groundTruth(id) {
  const out = execFileSync('zstd', ['-dc', logPath(id)], { encoding: 'utf8', maxBuffer: 1 << 30 })
  const seqs = []
  const questions = []
  let nonHuman = 0, emptyQuestions = 0
  for (const line of out.split('\n')) {
    if (!line.trim()) continue
    let e; try { e = JSON.parse(line) } catch { continue }
    if (typeof e.seq === 'number') seqs.push(e.seq)
    if (e.type !== 'user/message') continue
    const kind = e.data?.source?.kind ?? 'user'
    if (kind !== 'user') { nonHuman++; continue }
    const blocks = e.data?.content ?? []
    const text = blocks.filter((b) => b?.type === 'text').map((b) => b.text ?? '').join('').trim()
    const hasImage = blocks.some((b) => b?.type === 'image')
    if (!text && !hasImage) { emptyQuestions++; continue }
    if (!text) emptyQuestions++      // 只有图片：App 的"我的提问"列表会跳过它（正文为空）
    questions.push({ seq: e.seq, text, hasImage, textless: !text })
  }
  const set = new Set(seqs), min = Math.min(...seqs), max = Math.max(...seqs)
  let missing = 0
  for (let s = min; s <= max; s++) if (!set.has(s)) missing++
  return { seqs: set, questions, nonHuman, emptyQuestions, lines: seqs.length, min, max, missing }
}

const ADDRESS = (id) => ({ kind: 'session', sessionId: id })
async function fetchPage(id, beforeSeq, maxMessages) {
  const request = { address: ADDRESS(id), throughSeq: cursorOf.get(id) ?? 1 << 30, maxMessages }
  if (beforeSeq !== null) request.beforeSeq = beforeSeq
  const r = await call('session/page', { request })
  if (!r || r.ok === false) return { error: r?.error?.message ?? 'no result' }
  return r.value
}

/// 照 App 的算法一路往前翻，直到 seq 1；返回可达 seq 集合与统计。
async function appWalk(id, pageCap = 400) {
  let seen = new Map()
  const first = await fetchPage(id, null, 20)
  if (first.error) return { error: first.error }
  for (const rec of first.records ?? []) seen.set(rec.event.seq, rec)
  let oldest = (first.records ?? [])[0]?.event.seq ?? null
  const windowNewest = (first.records ?? []).at(-1)?.event.seq ?? 0
  let pages = 0, corrections = 0, duplicates = 0
  const holes = [], errors = []
  while (oldest !== null && oldest > 1 && pages < pageCap) {
    let requested = oldest, accepted = null
    for (let attempt = 1; attempt <= 3; attempt++) {
      const p = await fetchPage(id, requested, 60)
      if (p.error) { errors.push(`${requested}: ${p.error}`); break }
      const recs = p.records ?? []
      if (!recs.length) { accepted = { records: [], hasMore: false }; break }
      const last = recs.at(-1).event.seq, target = oldest - 1
      if (last < target && attempt < 3) {
        const next = requested + (target - last)
        if (next > requested) { corrections++; requested = next; continue }
      }
      accepted = { records: recs, hasMore: p.hasMore }
      break
    }
    if (!accepted) break
    if (!accepted.records.length) { oldest = null; break }
    const fresh = accepted.records.filter((r) => r.event.seq < oldest)
    if (!fresh.length) { holes.push(`@${oldest} 空页`); break }
    if (fresh.at(-1).event.seq !== oldest - 1) holes.push(`req=${oldest} 最新=${fresh.at(-1).event.seq}`)
    for (const r of fresh) { if (seen.has(r.event.seq)) duplicates++; seen.set(r.event.seq, r) }
    oldest = fresh[0].event.seq
    pages++
    if (accepted.hasMore === false && oldest > 1) holes.push(`hasMore=false@${oldest}`)
  }
  return { seen, pages, corrections, duplicates, holes, errors, windowNewest,
           reachedStart: oldest !== null && oldest <= 1, stoppedAt: oldest }
}

/// 搜索列表（"只看我的提问"）实际能覆盖多少：App 的规则是"攒够 30 条提问或最多 6 页"。
async function browseCoverage(id, truth, walk) {
  let seen = new Map()
  const first = await fetchPage(id, null, 20)
  for (const rec of first.records ?? []) seen.set(rec.event.seq, rec)
  let oldest = (first.records ?? [])[0]?.event.seq ?? null
  const qSeqs = truth.questions.map((q) => q.seq)
  const covered = () => qSeqs.filter((s) => seen.has(s) && truth.questions.find((q) => q.seq === s)?.text)
  let pages = 0
  while (oldest !== null && oldest > 1 && pages < 6 && covered().length < 30) {
    const p = await fetchPage(id, oldest, 60)
    if (p.error || !(p.records ?? []).length) break
    const fresh = p.records.filter((r) => r.event.seq < oldest)
    if (!fresh.length) break
    for (const r of fresh) seen.set(r.event.seq, r)
    oldest = fresh[0].event.seq
    pages++
  }
  const listed = covered().length
  const allTextQuestions = truth.questions.filter((q) => q.text).length
  const textless = truth.questions.filter((q) => q.textless).length
  return { pages, listed, allTextQuestions, textless, oldestLoaded: oldest,
           unreachable: allTextQuestions - listed, pagesToStart: walk.pages }
}

const ids = process.argv.slice(2)
console.log('| 会话 | 盘上记录 | 盘上洞 | 人类提问 | 正文为空 | App可达 | 缺 | 校正 | 重复 | 翻到最老 | 需页数 |')
console.log('|---|---|---|---|---|---|---|---|---|---|---|')
const details = []
for (const id of ids) {
  const truth = groundTruth(id)
  const walk = await appWalk(id)
  if (walk.error) { console.log(`| ${id.slice(0, 20)} | ERR ${walk.error} |`); continue }
  // 只统计"窗口范围内"的缺失：比窗口更新的记录本来就该由实时流补上，不算翻页的洞。
  const missingForApp = [...truth.seqs].filter((s) => s <= walk.windowNewest && !walk.seen.has(s)).length
  const browse = await browseCoverage(id, truth, walk)
  console.log(`| ${id.slice(8, 16)} | ${truth.lines} | ${truth.missing} | ${truth.questions.length} | ${truth.emptyQuestions} | ${walk.seen.size} | ${missingForApp} | ${walk.corrections} | ${walk.duplicates} | ${walk.reachedStart ? '是' : '否@' + walk.stoppedAt} | ${walk.pages} |`)
  details.push({ id, truth, walk, browse })
}
console.log('')
for (const d of details) {
  const b = d.browse
  console.log(`${d.id}  列表最多列 ${b.listed}/${b.allTextQuestions} 条提问（自动翻 ${b.pages} 页，读到 seq ${b.oldestLoaded}）；还有 ${b.unreachable} 条更早的提问在列表外；只有图片、列表会跳过的 ${b.textless} 条；非人类(插件/运行时) user/message ${d.truth.nonHuman} 条`)
  if (d.walk.holes.length) console.log('   ⚠️ 洞:', d.walk.holes.slice(0, 5).join(' | '))
  if (d.walk.errors.length) console.log('   ⚠️ RPC 错:', d.walk.errors.slice(0, 3).join(' | '))
}

#!/usr/bin/env node
// 有人用邀请码登记时，去公开那条试用 issue 下面留一条评论。
//
// 为什么不做在中转上：那边要在登记这条路径上多一个"给 GitHub 发请求"的失败点，
// 还得把 GitHub token 放到公网服务器上。这里反过来——**中转只存事实**（谁在什么时候
// 用哪张码登记了），由这台电脑（token 在钥匙串、仓库在这里）定期去读，读到新的就评论。
// 于是：中转重启、GitHub 挂了、电脑睡了都不会丢事件，醒来补上就是。
//
//   node scripts/dev/watch-enrolls.mjs            # 跑一次；有新的就评论（幂等）
//   node scripts/dev/watch-enrolls.mjs --dry-run  # 只打印要发什么，不碰 GitHub
//   node scripts/dev/watch-enrolls.mjs --count    # 只看现在的账（含电脑名，本地用）
//   node scripts/dev/watch-enrolls.mjs --summary  # 重新发一条汇总（不碰"谁已报过"）
//   node scripts/dev/watch-enrolls.mjs --details  # 公开评论里带上电脑名与账号
//
// 状态写在 ~/.dsh/mobile-link/enroll-reported.json（已评论过的 agentId）。
// 第一次跑不会把历史登记刷成一片评论，而是发一条汇总，然后从"下一位"开始逐条报。
//
// 配置来自 .env.local：DSH_OTA_HOST（中转主机）、DSH_ENROLL_ISSUE（owner/repo#编号）。
// GitHub token 从钥匙串读（scripts/dev/gh-token.sh），不落盘、不进仓库。

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')
const STATE = join(homedir(), '.dsh', 'mobile-link', 'enroll-reported.json')
/// 内部测试的登记不进公开评论（用的是本人的码，不是试用者的）。
const INTERNAL = /测试|test|e2e/i

const argv = process.argv.slice(2)
const has = (name) => argv.includes(`--${name}`)
const value = (name, fallback = '') => {
  const at = argv.indexOf(`--${name}`)
  return at >= 0 && at + 1 < argv.length ? argv[at + 1] : fallback
}

function localEnv() {
  const out = {}
  const path = join(ROOT, '.env.local')
  if (!existsSync(path)) return out
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (line.trimStart().startsWith('#')) continue
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line)
    if (match) out[match[1]] = match[2].replace(/^(['"])(.*)\1$/, '$2')
  }
  return out
}

const env = { ...localEnv(), ...process.env }
const issue = value('issue', env.DSH_ENROLL_ISSUE || 'jayantTang/DSH_Mobile#1')
const [repo, number] = issue.split('#')
if (!repo || !number) throw new Error(`DSH_ENROLL_ISSUE 形如 owner/repo#1，现在是「${issue}」`)

/// 问中转要事实：谁用哪张码在什么时候登记了，以及码的账。
function enrollments() {
  const host = env.DSH_OTA_HOST
  if (!host) throw new Error('.env.local 里没有 DSH_OTA_HOST')
  const remote = env.DSH_ENROLLS_CMD
    || '/opt/dsh-relay/.venv/bin/python /opt/dsh-relay/admin.py '
       + '--db /var/lib/dsh-relay/state.db enrollments'
  const raw = execFileSync('ssh', ['-q', '-o', 'BatchMode=yes', `root@${host}`, remote],
                           { encoding: 'utf8' })
  return JSON.parse(raw)
}

function token() {
  return execFileSync(join(ROOT, 'scripts/dev/gh-token.sh'), { encoding: 'utf8' }).trim()
}

function beijing(ms) {
  if (!ms) return '—'
  const parts = new Intl.DateTimeFormat('zh-CN', {
    timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(new Date(Number(ms)))
  const get = (type) => parts.find((part) => part.type === type)?.value ?? ''
  return `${get('year')}-${get('month')}-${get('day')} ${get('hour')}:${get('minute')}`
}

function loadState() {
  try {
    return JSON.parse(readFileSync(STATE, 'utf8'))
  } catch {
    return { reported: {}, summaryAt: null }
  }
}

function saveState(state) {
  mkdirSync(dirname(STATE), { recursive: true })
  writeFileSync(STATE, JSON.stringify(state, null, 2) + '\n')
}

async function comment(body) {
  const response = await fetch(
    `https://api.github.com/repos/${repo}/issues/${number}/comments`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token()}`,
        accept: 'application/vnd.github+json',
        'user-agent': 'dsh-watch-enrolls',
      },
      body: JSON.stringify({ body }),
    })
  if (!response.ok) {
    throw new Error(`GitHub 评论失败 HTTP ${response.status}：${(await response.text()).slice(0, 200)}`)
  }
  return response.json()
}

const tally = (data) => {
  const trials = data.enrollments.filter((row) => !INTERNAL.test(row.inviteNote ?? ''))
  const internal = data.enrollments.length - trials.length
  return { total: data.totals, trials, internal }
}

const line = (row, details) => {
  const who = details ? ` · ${row.agentName}（${row.accountId}）` : ''
  const batch = row.inviteNote ? `「${row.inviteNote}」` : ''
  return `- ${beijing(row.usedAt)}　${batch}${who}`
}

function summaryBody(trials, total, internal) {
  return [
    '### 试用登记汇总（自动更新）',
    '',
    `邀请码 **${total.minted}** 张 · 已用 **${total.used}** 张`
      + `（其中 ${internal} 张为内部测试）· 剩 **${total.remaining}** 张`,
    '',
    `已登记 **${trials.length}** 位试用者：`,
    ...trials.map((row) => line(row, has('details'))),
    '',
    '<sub>由 `scripts/dev/watch-enrolls.mjs` 自动维护；下一位登记后会单独回一条。</sub>',
  ].join('\n')
}

function enrollBody(row, index, trials, total, internal) {
  return [
    `### 第 ${index} 位试用者已登记`,
    '',
    `${beijing(row.usedAt)}（北京时间）· 邀请码批次${row.inviteNote ? `「${row.inviteNote}」` : '（无备注）'}`
      + (has('details') ? ` · ${row.agentName}（${row.accountId}）` : ''),
    '',
    `累计：邀请码 ${total.minted} 张 · 已用 ${total.used} 张（其中 ${internal} 张为内部测试）`
      + `· 剩 ${total.remaining} 张 · 已登记 ${trials.length} 位`,
    '',
    '<sub>由 `scripts/dev/watch-enrolls.mjs` 自动更新。</sub>',
  ].join('\n')
}

const data = enrollments()
const { total, trials, internal } = tally(data)

if (has('count')) {
  console.log(`邀请码：${total.minted} 张 · 已用 ${total.used}（内部测试 ${internal}）· 剩 ${total.remaining}`)
  for (const row of data.enrollments) {
    console.log(`${beijing(row.usedAt)}  ${row.inviteNote ?? '—'}  ${row.agentName}  ${row.accountId}`
      + `  ${row.agentId}  设备 ${row.devices}`)
  }
  process.exit(0)
}

const state = loadState()
const reported = state.reported ?? {}
const fresh = trials.filter((row) => !reported[row.agentId]).sort((a, b) => a.usedAt - b.usedAt)

if (has('summary')) {
  const body = summaryBody(trials, total, internal)
  if (has('dry-run')) {
    console.log(body)
  } else {
    const posted = await comment(body)
    console.log(`已发汇总评论：${posted.html_url}`)
  }
  process.exit(0)
}

if (!existsSync(STATE)) {
  // 第一次跑：不把历史刷成一片评论，发一条汇总，然后从下一位开始逐条报。
  const body = summaryBody(trials, total, internal)
  if (has('dry-run')) {
    console.log('（首次运行，将发一条汇总）\n' + body)
    process.exit(0)          // 预览不写状态：否则真正的第一次就被"消耗"掉了
  }
  const posted = await comment(body)
  console.log(`已发汇总评论：${posted.html_url}`)
  for (const row of trials) reported[row.agentId] = new Date().toISOString()
  saveState({ reported, summaryAt: new Date().toISOString() })
  process.exit(0)
}

if (!fresh.length) {
  console.log(`没有新登记（已登记 ${trials.length} 位试用者，码剩 ${total.remaining} 张）`)
  process.exit(0)
}

for (const [offset, row] of fresh.entries()) {
  const index = trials.length - fresh.length + offset + 1
  const body = enrollBody(row, index, trials, total, internal)
  if (has('dry-run')) {
    console.log(`（将发评论）\n${body}\n`)
    continue
  }
  const posted = await comment(body)
  console.log(`第 ${index} 位：${posted.html_url}`)
  // 一条一发一存：中途失败时，已经发出去的不会下次再发一遍。
  reported[row.agentId] = new Date().toISOString()
  saveState({ reported, summaryAt: state.summaryAt ?? null })
}

#!/usr/bin/env node
/**
 * 诊断包的机械检查：脱敏、上限、结构（spec 020 的 FR-014/FR-018），
 * 以及**事件目录漂移**（写入侧 `EVENT_KINDS` 与契约文档必须逐字一致）。
 *
 * 契约：`specs/020-link-diagnostics/contracts/collect-command.md` §2/§4、
 *       `specs/020-link-diagnostics/contracts/diagnostics-events.md`
 *
 * 为什么必须是**机械检查**而不是"写的时候小心点"：脱敏规则一旦只活在人的记忆里，下一次
 * "顺手加个字段"就会把凭据带进要发出去的包；事件词表同理，加了 kind 忘了改契约，
 * 下一个人就会按旧契约读新事件。
 *
 * 退出码：0 无命中 / 1 有命中（逐条打印）/ 2 工具自身错误或用法错。
 */

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

import { EVENT_KINDS } from '../../plugins/mobile-link/lib/journal.js'

const REPO_ROOT = join(import.meta.dirname, '..', '..')

const USAGE = `用法: node scripts/dev/check-diagnostics.mjs [--pack <目录>] [--contract]

  --pack <目录>   检查一个诊断包目录（默认：最近一次 ~/dsh-diagnostics/ 下的包）
  --contract      只核对事件目录：连接器 EVENT_KINDS 与契约文档逐字一致
  -h, --help      显示本帮助
`

/** 写入侧与文档比对的那份契约。 */
export const EVENT_CONTRACT = 'specs/020-link-diagnostics/contracts/diagnostics-events.md'

/**
 * 从契约文档里取出事件词表（只取 §2 既有 与 §3 新增两张表的**第一列**）。
 *
 * 不解析 §4：那张表是"中转日志行的片段 → 事件"的映射，第一列是行内片段不是 kind。
 */
export function parseContractKinds(markdown) {
  const kinds = new Set()
  for (const section of String(markdown ?? '').split(/^## /m)) {
    if (!/^[23]\./.test(section)) continue
    for (const line of section.split('\n')) {
      const match = /^\|\s*`([a-z][a-z0-9]*(?:[.-][a-z0-9-]+)+)`\s*\|/.exec(line)
      if (match) kinds.add(match[1])
    }
  }
  return kinds
}

/**
 * 写入侧词表 vs 契约文档：双向都要一致（少一个 = 文档过期；多一个 = 有人加了 kind 没记账）。
 *
 * @returns {{ok: boolean, issues: string[], codeKinds: string[], docKinds: string[]}}
 */
export function checkEventContract({ repoRoot = REPO_ROOT } = {}) {
  const issues = []
  let docKinds = new Set()
  try {
    docKinds = parseContractKinds(readFileSync(join(repoRoot, EVENT_CONTRACT), 'utf8'))
  } catch (error) {
    return { ok: false, issues: [`读不到契约 ${EVENT_CONTRACT}：${error.message}`], codeKinds: [...EVENT_KINDS], docKinds: [] }
  }
  const code = new Set(EVENT_KINDS)
  if (docKinds.size === 0) issues.push(`${EVENT_CONTRACT} 里没解析出任何 kind（表格格式变了？）`)
  for (const kind of code) if (!docKinds.has(kind)) issues.push(`代码里有、契约里没有：${kind}`)
  for (const kind of docKinds) if (!code.has(kind)) issues.push(`契约里有、代码里没有：${kind}`)
  return { ok: issues.length === 0, issues, codeKinds: [...code].sort(), docKinds: [...docKinds].sort() }
}

// ── 脱敏：规则只有一份，采集侧与检查侧共用（契约 §4） ────────────────────────

/**
 * 不许出现在诊断包里的东西。每条都配 `why`：命中时人要知道自己在看什么。
 *
 * 这些规则**故意宽松**（宁可多报一次也不放过）：命中就是失败，由人看一眼再决定。
 */
export const LEAK_RULES = Object.freeze([
  { id: 'agent-secret', pattern: /as_[A-Za-z0-9_-]{12,}/g, why: '连接器身份密钥' },
  { id: 'bearer', pattern: /Bearer\s+[A-Za-z0-9._~+/-]{16,}=*/g, why: 'Authorization 头' },
  { id: 'launch-token', pattern: /[?&]token=[A-Za-z0-9._~-]{12,}/g, why: '本机 DSH 启动令牌' },
  { id: 'auth-cookie', pattern: /dsh-auth[^\s;"]{0,80}/g, why: '本机会话 cookie' },
  { id: 'invite-code', pattern: /(?:invite|DSH_MOBILE_LINK_INVITE)[=:"'\s]+[A-Za-z0-9_-]{16,}/g, why: '邀请码' },
  { id: 'env-secret', pattern: /(?:SECRET|TOKEN|PASSWORD|APIKEY|API_KEY)\s*[=:]\s*\S{8,}/g, why: '环境变量里的凭据' },
])

/** 把绝对家目录换成 `~`（`/Users/x/...` 与 `file:///Users/x/...` 两种形状都覆盖）。 */
export function redactHome(text, home = homedir()) {
  if (typeof text !== 'string' || !home) return text
  const escaped = home.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return text.replace(new RegExp(escaped, 'g'), '~')
}

/** 扫一段文本，返回命中（每个规则最多留一条样本，够定位又不至于把包灌满）。 */
export function scanForLeaks(text, { home = homedir() } = {}) {
  const hits = []
  const redacted = redactHome(text, home)
  // 家目录没被替换干净（例如换了别的用户路径）时也要报：`/Users/<别人>` 同样是真值。
  for (const match of redacted.matchAll(/\/Users\/[A-Za-z0-9._-]+/g)) {
    hits.push({ rule: 'foreign-home', sample: match[0], why: '真实家目录' })
  }
  for (const rule of LEAK_RULES) {
    for (const match of redacted.matchAll(rule.pattern)) {
      hits.push({ rule: rule.id, sample: clip(match[0]), why: rule.why })
      break
    }
  }
  return hits
}

function clip(text, limit = 60) {
  const single = String(text).replace(/\s+/g, ' ')
  return single.length > limit ? `${single.slice(0, limit)}…` : single
}

/** 递归列出目录里的文件（不跟符号链接）。 */
export function listFiles(dir, base = dir) {
  const out = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...listFiles(path, base))
    else if (entry.isFile()) out.push({ path, relative: path.slice(base.length + 1), bytes: statSync(path).size })
  }
  return out
}

/**
 * 检查一个诊断包：逐文件按 LEAK_RULES 核对，并核对结构（README/timeline/coverage/missing）。
 *
 * @returns {{ok: boolean, hits: Array, files: number, bytes: number, issues: string[]}}
 */
export function checkDiagnosticsPack(directory, { home = homedir() } = {}) {
  const files = listFiles(directory)
  const hits = []
  const issues = []
  let bytes = 0
  for (const file of files) {
    bytes += file.bytes
    let text
    try {
      text = readFileSync(file.path, 'utf8')
    } catch {
      continue
    }
    for (const hit of scanForLeaks(text, { home })) hits.push({ ...hit, file: file.relative })
  }
  const names = new Set(files.map((file) => file.relative))
  for (const required of ['README.md', 'clock.json', 'coverage.json', 'missing.json']) {
    if (!names.has(required)) issues.push(`缺 ${required}`)
  }
  if (!names.has('timeline.jsonl') && !names.has('timeline.by-source.jsonl')) {
    issues.push('既没有 timeline.jsonl 也没有 timeline.by-source.jsonl（拿不到偏移时后者是替代）')
  }
  return { ok: hits.length === 0 && issues.length === 0, hits, issues, files: files.length, bytes }
}

export function parseArgs(argv) {
  const options = { pack: undefined, contract: false, help: false }
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '-h' || arg === '--help') options.help = true
    else if (arg === '--contract') options.contract = true
    else if (arg === '--pack') options.pack = argv[++index]
    else throw new Error(`未知参数：${arg}`)
  }
  return options
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const options = parseArgs(process.argv.slice(2))
    if (options.help) {
      process.stdout.write(USAGE)
      process.exit(0)
    }
    if (options.contract) {
      const result = checkEventContract()
      console.log(`事件目录（写入侧 ${result.codeKinds.length} 个 vs 契约 ${result.docKinds.length} 个）：`)
      for (const issue of result.issues) console.log(`  FAIL ${issue}`)
      if (result.ok) console.log('  ok   写入侧与契约逐字一致')
      process.exit(result.ok ? 0 : 1)
    }
    const directory = options.pack
    if (!directory) {
      process.stderr.write(`需要一个诊断包目录：--pack <目录>\n\n${USAGE}`)
      process.exit(2)
    }
    const result = checkDiagnosticsPack(directory)
    console.log(`诊断包 ${directory}：${result.files} 个文件 / ${result.bytes} 字节`)
    for (const issue of result.issues) console.log(`  FAIL ${issue}`)
    for (const hit of result.hits) console.log(`  FAIL ${hit.rule}（${hit.why}）出现在 ${hit.file}：${hit.sample}`)
    if (result.ok) console.log('  ok   结构齐备、没有命中脱敏规则')
    process.exit(result.ok ? 0 : 1)
  } catch (error) {
    process.stderr.write(`${error.message}\n\n${USAGE}`)
    process.exit(2)
  }
}


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

import { readFileSync } from 'node:fs'
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
    process.stderr.write('check-diagnostics: 诊断包检查尚未实现（tasks.md T037）\n')
    process.exit(2)
  } catch (error) {
    process.stderr.write(`${error.message}\n\n${USAGE}`)
    process.exit(2)
  }
}


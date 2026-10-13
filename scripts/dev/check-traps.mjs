#!/usr/bin/env node
/**
 * Swift 里"会 SIGTRAP 的写法"体检（崩溃类问题的静态闸门）。
 *
 * 为什么需要它：Swift 的整数溢出、非法闭区间、`precondition`、`try!` 都是**进程级 trap**，
 * 不是可捕获的错误——一旦触发就是用户侧崩溃，没有任何补救机会。2026-10-13 TestFlight
 * 崩溃（build 20261012.1310）就是这么来的：磁盘聚合列被 pending 行的合成 seq 抬到
 * `Int.max`，冷启动预取拿它算页边界，`start + pageSize - 1` 第二次循环整数溢出。
 *
 * 这个脚本拦的是**写法**，不是值：它不知道某个 Int 是从 host JSON 还是 SQLite 行里来的。
 * 值的来源要靠数据层不变量与类型收口（另议），本闸门负责"新写出的 trap 组合当场现形"。
 *
 * 规则集（信噪比优先，宁可少一条也不要让人习惯性豁免）：
 *   R1 range     闭区间 `a...b`，两端都非字面量（`ClosedRange` 的 lower > upper 直接 trap）
 *   R2 sentinel  `Int.max` / `Int.min` 当**值**用（赋值、实参）——哨兵值一旦落库或被
 *                host 看到，就会在下游某个算术里溢出
 *   R3 force     `try!` / `as!`（编译期放弃检查，运行期直接 trap）
 *   R4 trap      `precondition` / `preconditionFailure` / `fatalError` / `assertionFailure`
 *   R5 dbl2int   `Int(<标识符>)`（`Double → Int` 越界或 NaN 是 trap，`Int(1e30)` 就崩）
 *
 * 已知不覆盖：变量除数（`/`，实测 200+ 处全是常量，噪声太大）、字符串下标、数组下标。
 * 那几类的噪声会淹没真信号，等有 AST 级规则时再说。
 *
 * 扫描范围：**生产源码**（DSHKit/Sources 与 DSHMobile App），不含测试——测试里故意用
 * `Int.max` 造边界，那是它该干的事。
 *
 * 用法:
 *   node scripts/dev/check-traps.mjs               # 闸门：只报未豁免命中
 *   node scripts/dev/check-traps.mjs --report      # 台账：连已豁免的一起列出来
 *   node scripts/dev/check-traps.mjs --paths a.swift b.swift
 *
 * 退出码：0 无未豁免命中 / 1 有未豁免命中（逐条打印）/ 2 工具自身错误（含豁免缺 reason）
 *
 * 豁免：`scripts/dev/trap-exemptions.json`，按「文件 + 规则 + 命中的代码片段」记账，
 * 不按行号（行号会漂）。**每条必须写 reason**：说明为什么这里不会 trap（通常是有守卫、
 * 有同源不变量，或属于已知风险且另开任务）。片段改了就重新说明一次，这是有意的。
 */

import { existsSync, readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join } from 'node:path'

const REPO_ROOT = join(import.meta.dirname, '..', '..')
const EXEMPTIONS_PATH = join(import.meta.dirname, 'trap-exemptions.json')

const SCAN_ROOTS = [
  'ios/DSHMobile/DSHKit/Sources',
  'ios/DSHMobile/DSHMobile',
]

const USAGE = `用法: node scripts/dev/check-traps.mjs [--report] [--paths <file...>]

  --report         列出全部命中（含已豁免），当台账看
  --paths <file>   只扫指定文件（调试规则用）
  -h, --help       显示本帮助
`

/**
 * 规则集。`pattern` 逐行匹配源码，`skip` 是同一行上的豁免形状（注释、字面量声明等）。
 * 每条规则只保留"几乎必然是真问题"的形状：过宽的规则会被豁免清单磨平，最后等于没有。
 */
export const RULES = [
  {
    id: 'range',
    title: '闭区间两端非字面量',
    // 左端是标识符/右括号/右方括号，右端是标识符/左括号：`a...b`。
    // 数字字面量端点（`1...8`、`0x30...0x39`）不可能是非法区间，不报；
    // 单边区间 `x...` 与可变参数 `T...` 也不会命中（右侧分别是 ] 和 )）。
    pattern: /(?:[A-Za-z_][A-Za-z0-9_]*|\]|\))\s*\.\.\.\s*(?:[A-Za-z_][A-Za-z0-9_]*|\()/,
    skip: /^\s*(\/\/|\/\/\/|\*)/,
  },
  {
    id: 'sentinel',
    title: 'Int.max / Int.min 当值用',
    pattern: /[:=(,]\s*Int\.(?:max|min)\b/,
    skip: /^\s*(\/\/|\/\/\/|\*)/,
  },
  {
    id: 'force',
    title: 'try! / as!',
    pattern: /\btry!|\bas!\s/,
    skip: /^\s*(\/\/|\/\/\/|\*)/,
  },
  {
    id: 'trap',
    title: 'precondition / fatalError',
    pattern: /\b(?:precondition|preconditionFailure|fatalError|assertionFailure)\s*\(/,
    skip: /^\s*(\/\/|\/\/\/|\*)/,
  },
  {
    id: 'dbl2int',
    title: 'Double → Int 转换',
    pattern: /\bInt\(\s*[a-zA-Z_][A-Za-z0-9_.]*\s*\)/,
    skip: /^\s*(\/\/|\/\/\/|\*)/,
  },
]

function fail(message) {
  console.error(message)
  process.exit(2)
}

/** 校验豁免条目：结构或 reason 不合格一律抛错（调用方转成 exit 2）。 */
export function validateExemptions(entries, path = EXEMPTIONS_PATH) {
  if (!Array.isArray(entries)) throw new Error(`${path} 缺 exemptions 数组`)
  for (const entry of entries) {
    for (const key of ['file', 'rule', 'snippet', 'reason']) {
      if (typeof entry?.[key] !== 'string' || !entry[key].trim()) {
        throw new Error(`${path}: 豁免条目缺 ${key}（或为空）：${JSON.stringify(entry).slice(0, 160)}`)
      }
    }
    if (!RULES.some((rule) => rule.id === entry.rule)) {
      throw new Error(`${path}: 未知规则 id '${entry.rule}'`)
    }
    if (entry.count !== undefined && (!Number.isInteger(entry.count) || entry.count < 1)) {
      throw new Error(`${path}: count 必须是 ≥1 的整数：${JSON.stringify(entry).slice(0, 160)}`)
    }
  }
  return entries
}

/** 读豁免清单；文件不存在按空基线处理。 */
export function loadExemptions(path = EXEMPTIONS_PATH) {
  if (!existsSync(path)) return []
  let parsed
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    fail(`豁免清单不是合法 JSON：${path}\n${error.message}`)
  }
  try {
    return validateExemptions(parsed?.exemptions, path)
  } catch (error) {
    return fail(error.message)
  }
}

function swiftFilesUnder(roots) {
  const found = []
  for (const root of roots) {
    const absolute = join(REPO_ROOT, root)
    if (!existsSync(absolute)) continue
    const listed = execFileSync('find', [absolute, '-name', '*.swift', '-not', '-path', '*/.build/*'], {
      encoding: 'utf8',
    })
    for (const line of listed.split('\n')) {
      if (line.trim()) found.push(line.trim())
    }
  }
  return found
}

/** 扫一个文件，返回逐条命中（不含豁免判定）。 */
export function scanFile(path, relative) {
  const hits = []
  const lines = readFileSync(path, 'utf8').split('\n')
  for (const rule of RULES) {
    lines.forEach((line, index) => {
      if (rule.skip?.test(line)) return
      const match = rule.pattern.exec(line)
      if (!match) return
      hits.push({
        rule: rule.id,
        file: relative,
        line: index + 1,
        snippet: line.trim(),
      })
    })
  }
  return hits
}

/** 按「文件 + 规则 + 片段」记账：行号会漂，片段变了要重新说明。 */
function exemptionKey(hit) {
  return `${hit.file}\u0000${hit.rule}\u0000${hit.snippet}`
}

export function partition(hits, exemptions) {
  const budget = new Map()
  for (const entry of exemptions) {
    const key = `${entry.file}\u0000${entry.rule}\u0000${entry.snippet}`
    budget.set(key, (budget.get(key) ?? 0) + (entry.count ?? 1))
  }
  const unexempted = []
  const exempted = []
  for (const hit of hits) {
    const key = exemptionKey(hit)
    const left = budget.get(key) ?? 0
    if (left > 0) {
      budget.set(key, left - 1)
      exempted.push(hit)
    } else {
      unexempted.push(hit)
    }
  }
  return { unexempted, exempted }
}

function main() {
  const args = process.argv.slice(2)
  if (args.includes('-h') || args.includes('--help')) {
    process.stdout.write(USAGE)
    return
  }
  const report = args.includes('--report')
  const pathsIndex = args.indexOf('--paths')
  let files
  let relativeOf
  if (pathsIndex >= 0) {
    const explicit = args.slice(pathsIndex + 1).filter((value) => !value.startsWith('--'))
    if (!explicit.length) fail('--paths 需要至少一个文件')
    files = explicit
    relativeOf = (absolute) => absolute.replace(`${REPO_ROOT}/`, '')
  } else {
    files = swiftFilesUnder(SCAN_ROOTS)
    relativeOf = (absolute) => absolute.replace(`${REPO_ROOT}/`, '')
  }

  const hits = []
  for (const file of files) {
    const relative = relativeOf(file)
    const absolute = file.startsWith('/') ? file : join(REPO_ROOT, file)
    if (!existsSync(absolute)) fail(`扫不到文件：${file}`)
    hits.push(...scanFile(absolute, relative))
  }

  const exemptions = loadExemptions()
  const { unexempted, exempted } = partition(hits, exemptions)

  if (report) {
    const byRule = new Map(RULES.map((rule) => [rule.id, []]))
    for (const hit of hits) byRule.get(hit.rule).push(hit)
    for (const rule of RULES) {
      const list = byRule.get(rule.id)
      console.log(`\n[${rule.id}] ${rule.title}：${list.length} 处`)
      for (const hit of list) {
        const exempt = exempted.some((e) => e.file === hit.file && e.line === hit.line
          && e.rule === hit.rule && e.snippet === hit.snippet)
        console.log(`  ${exempt ? '·' : '!'} ${hit.file}:${hit.line}  ${hit.snippet.slice(0, 96)}`)
      }
    }
    console.log(`\n合计 ${hits.length} 处，已豁免 ${exempted.length} 处，未豁免 ${unexempted.length} 处`)
  }

  if (unexempted.length) {
    console.error(`会 trap 的写法新增了 ${unexempted.length} 处（规则见 scripts/dev/check-traps.mjs）：\n`)
    for (const hit of unexempted) {
      console.error(`  [${hit.rule}] ${hit.file}:${hit.line}`)
      console.error(`      ${hit.snippet.slice(0, 140)}`)
    }
    console.error(`\n要么改成不会 trap 的写法，要么加进 scripts/dev/trap-exemptions.json 并写明 reason。`)
    process.exit(1)
  }
  // 基线里的已知风险（reason 以 TODO: 开头）每次都点名，避免"豁免完就忘了"。
  const known = exemptions.filter((entry) => entry.reason.trimStart().startsWith('TODO:'))
  for (const entry of known) {
    console.log(`已知风险待处理：${entry.file} [${entry.rule}] ${entry.reason.trim()}`)
  }
  console.log(`check-traps: ${hits.length} 处命中全部已豁免（${exempted.length} 条基线，`
    + `其中已知风险 ${known.length} 条）`)
}

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) main()

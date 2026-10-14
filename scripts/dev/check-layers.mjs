#!/usr/bin/env node
/**
 * 模块边界守卫（spec 023 的 R1–R6）：**谁能看见谁**。
 *
 * 为什么需要它：DSHKit 与 App 之间今天不是边界，只是编译单元——DSHKit 对外 1,201 个 public
 * 符号 / 165 个 public 类型，App 52 个文件任意穿四层，于是近一个月 70% 的 DSHKit 改动被迫
 * 同时改 App（spec 023「问题」表的实测）。相邻的 `check-structure.mjs` 管"文件/函数有多大"，
 * 本脚本管"依赖方向"，两者互补、都不改判定权归属（超限与命中归人判）。
 *
 * 规则集（信噪比优先，宁可少一条也不要让人习惯性豁免）：
 *   R1 UI 依赖   DSHKit/Sources/** 不得 import UIKit/SwiftUI/UserNotifications/WebKit/
 *                PhotosUI/VisionKit/QuickLook/AVFoundation/CoreGraphics。
 *                CoreGraphics 也在内：它只在 Apple 平台可用，用了 DSHKit 就在 Linux
 *                Swift 工具链上构建不了，等于关掉一条验证渠道（lanes.json 的 protocol×l2）。
 *   R2 整包 import  App 侧 `import DSHKit` / `import RelayKit` 只允许出现在白名单文件里。
 *   R3 实现层标识符  白名单之外不得出现 DSHClient / MessageStore / SessionPipeline /
 *                MessagePipeline / LinkCarrier / RelayDevices / RelayFeedback / RelayFileTransfer。
 *   R4 白名单不许长 UI  白名单文件里不得声明 `: View` / UIViewRepresentable / UIViewControllerRepresentable。
 *   R5 零新增依赖  本脚本只允许 node: 内置模块与相对路径。
 *   R6 台账显式  白名单必须是具体文件（不许通配），条数受 SC-002 约束（≤8）；豁免台账每条必须有 reason。
 *
 * 注释与字符串先被抹掉再匹配：文档性注释里写 `import UIKit` 不该判违规。
 *
 * 用法:
 *   node scripts/dev/check-layers.mjs              # 拦截模式（默认）：未豁免的**拦截规则**命中即 1
 *   node scripts/dev/check-layers.mjs --report-only # 报告模式：只打印证据，恒 0（排查时用）
 *   node scripts/dev/check-layers.mjs --report      # 台账视图：连已豁免的一起列出来
 *   node scripts/dev/check-layers.mjs --paths a.swift b.swift
 *
 * 退出码：台账类错误恒为 2（缺 note/reason、白名单文件不存在、通配、脚本自身引了第三方依赖）；
 *         规则命中看模式——报告模式恒 0，拦截模式有未豁免命中即 1。
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const REPO_ROOT = join(import.meta.dirname, '..', '..')
const WHITELIST_PATH = join(import.meta.dirname, 'layer-whitelist.json')
const EXEMPTIONS_PATH = join(import.meta.dirname, 'layer-exemptions.json')

/** SC-002：白名单文件数上限。 */
export const WHITELIST_LIMIT = 8

const APP_ROOT = 'ios/DSHMobile/DSHMobile'
const KIT_ROOT = 'ios/DSHMobile/DSHKit/Sources'

/** 命中多的时候默认只打这么多行，`--report` 才全列。 */
const HEAD_LINES = 25

const UI_FRAMEWORKS = [
  'UIKit', 'SwiftUI', 'UserNotifications', 'WebKit', 'PhotosUI',
  'VisionKit', 'QuickLook', 'AVFoundation', 'CoreGraphics',
]

const IMPLEMENTATION_NAMES = [
  'DSHClient', 'MessageStore', 'SessionPipeline', 'MessagePipeline', 'LinkCarrier',
  'RelayDevices', 'RelayFeedback', 'RelayFileTransfer',
]

const USAGE = `用法: node scripts/dev/check-layers.mjs [--enforce] [--report] [--paths <file...>]

  --report-only    报告模式：只打印证据、不拦截（默认是拦截）
  --report         台账视图：连已豁免的命中一起列出
  --paths <file>   只扫指定文件（调试规则用）
  -h, --help       显示本帮助
`

function fail(message) {
  console.error(message)
  process.exit(2)
}

/**
 * 把注释（以及可选的字符串字面量）抹成空格，长度与换行保持不变。
 * 只做"够用"的扫描：行注释、块注释、单双引号字符串、Swift 多行字符串（"""）、JS 模板串。
 *
 * `maskStrings: false` 用于 R5 的自我检查：import 的模块名本身就是字符串字面量，抹掉就查不出
 * 第三方依赖了；但仍然要认字符串状态，否则字符串里的 `//`（例如 `file://`）会被当成行注释。
 */
export function maskNonCode(source, { maskStrings = true } = {}) {
  const chars = [...source]
  const blank = (index) => {
    if (index < chars.length && chars[index] !== '\n') chars[index] = ' '
  }
  const inString = (index) => {
    if (maskStrings) blank(index)
  }
  let state = 'code'
  let quote = ''
  let i = 0
  while (i < chars.length) {
    const c = chars[i]
    const next = chars[i + 1]
    if (state === 'code') {
      if (c === '/' && next === '/') { state = 'line'; blank(i); blank(i + 1); i += 2; continue }
      if (c === '/' && next === '*') { state = 'block'; blank(i); blank(i + 1); i += 2; continue }
      if (c === '"' || c === "'" || c === '`') {
        if (c === '"' && next === '"' && chars[i + 2] === '"') {
          state = 'string'; quote = '"""'; inString(i); inString(i + 1); inString(i + 2); i += 3; continue
        }
        state = 'string'; quote = c; inString(i); i += 1; continue
      }
      i += 1
      continue
    }
    if (state === 'line') {
      if (c === '\n') { state = 'code'; i += 1; continue }
      blank(i); i += 1; continue
    }
    if (state === 'block') {
      if (c === '*' && next === '/') { blank(i); blank(i + 1); state = 'code'; i += 2; continue }
      blank(i); i += 1; continue
    }
    // state === 'string'
    if (quote === '"""') {
      if (c === '"' && next === '"' && chars[i + 2] === '"') {
        inString(i); inString(i + 1); inString(i + 2); state = 'code'; i += 3; continue
      }
      inString(i); i += 1; continue
    }
    if (c === '\\') { inString(i); inString(i + 1); i += 2; continue }
    if (c === quote) { inString(i); state = 'code'; i += 1; continue }
    inString(i); i += 1; continue
  }
  return chars.join('')
}

/**
 * 规则集。`scope` 决定扫哪些文件，`applies` 决定命中是否算数（白名单/台账依赖在这里收口）。
 */
export const RULES = [
  {
    id: 'R1',
    title: 'DSHKit 不得依赖 UI 框架',
    scope: (relative) => relative.startsWith(`${KIT_ROOT}/`),
    pattern: new RegExp(`^\\s*import\\s+(${UI_FRAMEWORKS.join('|')})\\b`),
  },
  {
    id: 'R2',
    title: 'App 侧整包 import 只允许白名单文件',
    scope: (relative) => relative.startsWith(`${APP_ROOT}/`),
    pattern: /^\s*import\s+(?:DSHKit|RelayKit)\b/,
    onlyOutsideWhitelist: true,
    // **报告指标，不拦截**（owner 2026-10-14 决定）。理由：门面（`LinkGateway` /
    // `SessionHandle` / 只读模型）就在 DSHKit 里，产品文件要用它就必须 `import DSHKit`，
    // 于是"整包 import 一律违规"与"门面在包内"这两件事天生冲突。真正要拦的是
    // **实现层标识符**（R3）与 **DSHKit 侧的 UI 依赖**（R1）——那两条现在都是 0。
    // 这个数仍然每次都打印，用来观察"有没有文件开始绕过门面自己拼东西"。
    advisory: true,
  },
  {
    id: 'R3',
    title: '白名单之外不得出现实现层标识符',
    scope: (relative) => relative.startsWith(`${APP_ROOT}/`),
    pattern: new RegExp(`\\b(${IMPLEMENTATION_NAMES.join('|')})\\b`),
    onlyOutsideWhitelist: true,
  },
  {
    id: 'R4',
    title: '白名单文件不得声明 UI 类型',
    scope: (relative) => relative.startsWith(`${APP_ROOT}/`),
    pattern: /:\s*(?:View|UIViewRepresentable|UIViewControllerRepresentable)\b/,
    onlyInsideWhitelist: true,
  },
]

/** 读一个 JSON 台账；不是合法 JSON 一律抛错（由 main 转成退出码 2，测试里直接断言抛）。 */
function readJson(path, label) {
  if (!existsSync(path)) return null
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    throw new Error(`${label}不是合法 JSON：${path}\n${error.message}`)
  }
}

/**
 * 读并校验白名单。返回 `{ files: Set<相对路径>, entries }`。
 * 台账类问题（缺 note、不存在、通配）直接抛出，由调用方转成 exit 2。
 */
export function loadWhitelist(path = WHITELIST_PATH) {
  const parsed = readJson(path, '白名单')
  if (parsed === null) return { files: new Set(), entries: [] }
  const entries = parsed?.files
  if (!Array.isArray(entries)) throw new Error(`${path} 缺 files 数组`)
  const files = new Set()
  for (const entry of entries) {
    const relative = entry?.path
    if (typeof relative !== 'string' || !relative.trim()) {
      throw new Error(`${path}: 白名单条目缺 path：${JSON.stringify(entry).slice(0, 160)}`)
    }
    if (typeof entry?.note !== 'string' || !entry.note.trim()) {
      throw new Error(`${path}: 白名单条目缺 note（说明为什么这个文件可以直接碰整包）：${relative}`)
    }
    if (/[*?[\]]/.test(relative)) {
      throw new Error(`${path}: 白名单必须列具体文件，不允许通配：${relative}`)
    }
    if (!existsSync(join(REPO_ROOT, relative))) {
      throw new Error(`${path}: 白名单文件不存在（防台账腐烂）：${relative}`)
    }
    files.add(relative)
  }
  return { files, entries }
}

/** 读并校验豁免台账；每条必须有 reason，规则 id 必须存在。 */
export function loadExemptions(path = EXEMPTIONS_PATH) {
  const parsed = readJson(path, '豁免台账')
  if (parsed === null) return []
  const entries = parsed?.exemptions
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
  }
  return entries
}

/** R5：本脚本只允许 node: 内置模块与相对路径。 */
export function checkOwnImports(source) {
  const issues = []
  for (const line of maskNonCode(source, { maskStrings: false }).split('\n')) {
    const match = /^\s*import\s+(?:[^'"]*from\s+)?['"]([^'"]+)['"]/.exec(line)
    if (!match) continue
    const specifier = match[1]
    if (!specifier.startsWith('node:') && !specifier.startsWith('.')) {
      issues.push(specifier)
    }
  }
  return issues
}

function swiftFilesUnder(roots) {
  const found = []
  for (const root of roots) {
    const absolute = join(REPO_ROOT, root)
    if (!existsSync(absolute)) continue
    const listed = execFileSync('find', [absolute, '-name', '*.swift', '-not', '-path', '*/.build/*'], {
      encoding: 'utf8',
    })
    for (const line of listed.split('\n')) if (line.trim()) found.push(line.trim())
  }
  return found
}

/** 扫一个文件，返回逐条命中（不含白名单/豁免判定）。 */
export function scanFile(path, relative, whitelist = new Set()) {
  const masked = maskNonCode(readFileSync(path, 'utf8'))
  const hits = []
  for (const rule of RULES) {
    if (!rule.scope(relative)) continue
    if (rule.onlyOutsideWhitelist && whitelist.has(relative)) continue
    if (rule.onlyInsideWhitelist && !whitelist.has(relative)) continue
    masked.split('\n').forEach((line, index) => {
      const match = rule.pattern.exec(line)
      if (!match) return
      hits.push({ rule: rule.id, file: relative, line: index + 1, snippet: line.trim().replace(/\s+/g, ' ') })
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

/** 解析命令行：`--paths` 之后的非开关值都是文件。 */
function parseArgs(args) {
  const pathsIndex = args.indexOf('--paths')
  const paths = pathsIndex >= 0
    ? args.slice(pathsIndex + 1).filter((value) => !value.startsWith('--'))
    : []
  if (pathsIndex >= 0 && !paths.length) fail('--paths 需要至少一个文件')
  return {
    help: args.includes('-h') || args.includes('--help'),
    // 默认**拦截**（owner 2026-10-14 决定：R3 归零、白名单 4/8 之后切过来）。
    // 排查时用 `--report-only` 看证据；`--enforce` 保留为显式写法，老脚本不会失效。
    enforce: !args.includes('--report-only'),
    report: args.includes('--report'),
    paths,
  }
}

/** 逐文件扫出命中；`--paths` 之外走扫描根。 */
function collectHits(paths, whitelist) {
  const files = paths.length ? paths : swiftFilesUnder([KIT_ROOT, APP_ROOT])
  const hits = []
  for (const file of files) {
    const relative = file.startsWith('/') ? file.replace(`${REPO_ROOT}/`, '') : file
    const absolute = file.startsWith('/') ? file : join(REPO_ROOT, file)
    if (!existsSync(absolute)) fail(`扫不到文件：${file}`)
    hits.push(...scanFile(absolute, relative, whitelist.files))
  }
  return hits
}

/** 按规则分组打印：默认只打未豁免的，`--report` 打全部（含已豁免，当台账看）。 */
function printByRule(hits, unexempted, report) {
  const byRule = new Map(RULES.map((rule) => [rule.id, []]))
  for (const hit of hits) byRule.get(hit.rule).push(hit)
  for (const rule of RULES) {
    const list = byRule.get(rule.id)
    const open = list.filter((hit) => unexempted.includes(hit))
    console.log(`\n[${rule.id}] ${rule.title}：命中 ${list.length} 处（未豁免 ${open.length}）`)
    const shown = report ? list : open
    for (const hit of shown.slice(0, HEAD_LINES)) {
      const exempt = !unexempted.includes(hit)
      console.log(`  ${exempt ? '·' : '!'} ${hit.file}:${hit.line}  ${hit.snippet.slice(0, 110)}`)
    }
    if (shown.length > HEAD_LINES) console.log(`  …另有 ${shown.length - HEAD_LINES} 处（加 --report 看全）`)
  }
}

/** 拦截模式的失败输出。 */
function reportViolations(unexempted) {
  console.error(`\n边界被穿 ${unexempted.length} 处（规则见 scripts/dev/check-layers.mjs）：\n`)
  for (const hit of unexempted.slice(0, 40)) {
    console.error(`  [${hit.rule}] ${hit.file}:${hit.line}`)
    console.error(`      ${hit.snippet.slice(0, 140)}`)
  }
  console.error('\n要么把依赖收进白名单适配层，要么加进 scripts/dev/layer-exemptions.json 并写明 reason。')
}

function main() {
  const { help, enforce, report, paths } = parseArgs(process.argv.slice(2))
  if (help) {
    process.stdout.write(USAGE)
    return
  }
  // R5：守卫自身不许引第三方依赖（先查自己，坏了就别谈别人的边界）。
  const own = checkOwnImports(readFileSync(new URL(import.meta.url), 'utf8'))
  if (own.length) fail(`check-layers.mjs 引了非内置依赖（R5）：${own.join(', ')}`)

  let whitelist
  let exemptions
  try {
    whitelist = loadWhitelist()
    exemptions = loadExemptions()
  } catch (error) {
    return fail(error.message)
  }

  const hits = collectHits(paths, whitelist)
  const { unexempted, exempted } = partition(hits, exemptions)
  // 咨询类规则（R2）不算穿层：它们是"值得看一眼的数"，不是"必须修的问题"。
  const advisoryRules = new Set(RULES.filter((rule) => rule.advisory).map((rule) => rule.id))
  const blocking = unexempted.filter((hit) => !advisoryRules.has(hit.rule))
  const advisory = unexempted.filter((hit) => advisoryRules.has(hit.rule))
  printByRule(hits, unexempted, report)

  const ledger = []
  if (whitelist.files.size > WHITELIST_LIMIT) {
    ledger.push(`白名单文件数 ${whitelist.files.size} 超出 SC-002 的上限 ${WHITELIST_LIMIT}`)
  }
  for (const issue of ledger) console.log(`\n[R6] ${issue}`)
  console.log(`\ncheck-layers: 白名单 ${whitelist.files.size} 个文件，命中 ${hits.length} 处，`
    + `已豁免 ${exempted.length} 处，拦截规则未豁免 ${blocking.length} 处`
    + (advisory.length ? `，报告指标 ${advisory.length} 处（${[...advisoryRules].join('/')}，不拦截）` : ''))

  if (!enforce) {
    console.log('（报告模式：只给证据、不拦截。默认是拦截；这个模式用于排查。）')
    return
  }
  if (blocking.length) {
    reportViolations(blocking)
    process.exit(1)
  }
  if (ledger.length) process.exit(1)
}

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) main()

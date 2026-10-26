#!/usr/bin/env node
/**
 * iOS 崩溃风险静态扫描。
 *
 * 只找“会直接把 App 带走”的写法：强制解码、强制转换、fatalError、unowned、
 * 首元素强制解包。测试/夹具与明确的不可达分支走 allowlist，并写清理由。
 * 退出码：0 无未豁免命中；1 有命中；2 工具错误。
 */
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = 'ios/DSHMobile'
const ALLOW = [
  { file: 'DSHMobile/Diagnostics/', reason: 'OTA 诊断，独立编译' },
  { file: 'Modules/Testing/', reason: '测试支撑' },
  { file: '/Tests/', reason: '测试' },
  { file: 'CodeHighlighting.swift:88', reason: '关键字字符串，不是 unowned 捕获' },
  { file: 'ChatPagingService.swift:7', reason: 'service 由 model 持有，生命周期嵌套' },
  { file: 'ChatSendService.swift:11', reason: 'service 由 model 持有，生命周期嵌套' },
  { file: 'RPC.swift:23', reason: '泛型已判 Value == DSHEmpty，分支内安全' },
  { file: 'SessionPipeline.swift:691', reason: '非空 pageRecords 分支内' },
  { file: 'ProcessFoldFixture.swift', reason: 'DEBUG 夹具，固定 JSON' },
  { file: 'TranscriptListSpikeView.swift', reason: 'spike 调试视图' },
  { file: 'TranscriptListHost.swift:403', reason: 'UIView coder 初始化不可达' },
  { file: 'Fakes.swift', reason: '测试替身' },
]
const RULES = [
  { name: 'try!', re: /\btry!/ },
  { name: 'as!', re: /\bas!/ },
  { name: 'fatalError', re: /\bfatalError\s*\(/ },
  { name: 'preconditionFailure', re: /\bpreconditionFailure\s*\(/ },
  { name: 'unowned', re: /\bunowned\b/ },
  { name: 'first!', re: /\.first!/ },
]

function* swiftFiles(dir) {
  for (const entry of readdirSync(dir)) {
    if (entry === '.build' || entry === 'DerivedData') continue
    const path = join(dir, entry)
    const stat = statSync(path)
    if (stat.isDirectory()) yield* swiftFiles(path)
    else if (entry.endsWith('.swift')) yield path
  }
}

const hits = []
for (const path of swiftFiles(ROOT)) {
  const rel = relative(ROOT, path)
  const lines = readFileSync(path, 'utf8').split('\n')
  lines.forEach((line, index) => {
    const trimmed = line.trim()
    if (trimmed.startsWith('//')) return
    for (const rule of RULES) {
      if (!rule.re.test(line)) continue
      const where = `${rel}:${index + 1}`
      const allowed = ALLOW.some((entry) =>
        where.startsWith(entry.file) || where === entry.file || where.includes(entry.file))
      if (!allowed) hits.push({ where, rule: rule.name, line: line.trim() })
    }
  })
}

if (hits.length === 0) {
  console.log('crash-risks: clean')
  process.exit(0)
}
for (const hit of hits) console.log(`${hit.where}  [${hit.rule}]  ${hit.line}`)
console.log(`crash-risks: ${hits.length} hit(s) outside allowlist`)
process.exit(1)

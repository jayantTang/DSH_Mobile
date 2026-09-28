#!/usr/bin/env node
/**
 * 契约守卫：**文本级**检查，不是运行时验证。
 *
 *   node scripts/dev/check-contracts.mjs     # 有漂移就非零退出
 *
 * 这个脚本管三件事，各自有更强的运行时版本（那些才是真正的守门人）：
 *
 *   1. DLP 帧契约：三个测试文件必须都读 `test/contract/dlp-vectors.json`
 *      （而不是各自抄一份常量）。真正的断言在 `swift test` / `npm test` /
 *      `pytest` 里，这里只拦「有人把某端改回自己的硬编码」。
 *   2. 安装目录阶梯：`test/contract/dsh-install-ladder.json` 记的四份实现，
 *      锚点集合与相对顺序必须与契约一致。第四份（mobile-link 的 lib/ws.js）
 *      随 npm 发布、单列，差异只打印不失败。
 *   3. 调试钩子闸门：`-DSHDemoMode` / `-DSHForgetDirect` / `-DSHFailAttachmentLoad`
 *      在 iOS 源码里的每一处都必须在 `#if DEBUG` 区间内，Release 分支里不许有。
 *
 * **这是文本解析**：它拦得住「改了一份忘了另一份/把锚点顺序调了/把调试钩子移出门外」，
 * 拦不住等价重写。不要把它当成契约测试来宣传。
 */

import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const read = (relative) => readFileSync(join(REPO_ROOT, relative), 'utf8')
const readJson = (relative) => JSON.parse(read(relative))

const problems = []
const fail = (message) => problems.push(message)

// ── ① DLP 帧契约：三端读同一份向量 ──────────────────────────────────────────

/**
 * 每端引用向量文件时用的相对路径写法（三端目录深度不同，所以各写各的）。
 *
 * 注意：**契约检查不看代码逻辑，只看接线**。真正的断言在各自的测试文件里，
 * 这里的价值是「谁把某端改回自己的硬编码常量，这里会红」。
 */
const VECTOR_CONSUMERS = [
  { file: 'plugins/mobile-link/test/dlp-contract.test.js', needle: "'test/contract/dlp-vectors.json'" },
  { file: 'relay/tests/test_dlp_contract.py', needle: '"test" / "contract" / "dlp-vectors.json"' },  { file: 'ios/DSHMobile/DSHKit/Tests/DSHKitTests/DLPContractTests.swift', needle: '"test/contract/dlp-vectors.json"' },
]

const vectorPath = 'test/contract/dlp-vectors.json'
const vectors = readJson(vectorPath)
const contract = readJson('docs/relay-contract.json')

if (vectors.contract !== 'docs/relay-contract.json') {
  fail(`${vectorPath}: contract 字段应指向 docs/relay-contract.json`)
}

for (const { file, needle } of VECTOR_CONSUMERS) {
  const text = read(file)
  if (!text.includes(needle)) {
    fail(`${file}: 没有引用共享向量（应出现 ${needle}）——它可能抄了一份自己的常量`)
  }
}

/** 向量里每行的 t 必须落在契约的三张表之一（或明确标为未知帧）。 */
const declared = new Set([
  ...contract.deviceToAgent, ...contract.agentToDevice, ...contract.relayControl,
])
for (const vector of vectors.vectors) {
  if (vector.direction === 'unknown') continue
  if (!declared.has(vector.t)) {
    fail(`${vectorPath}: 向量 ${vector.name} 的 t=${vector.t} 不在契约的任何一张表里`)
  }
}

/** 六个 knownDrift 一条不少。 */
const DRIFT_IDS = ['hello-unused', 'ping-3-ways', 'validation-asymmetric',
                   'two-error-code-sets', 'hostStatus-fields', 'reassembly-only-ios']
const driftIds = new Set(contract.knownDrift.map((entry) => entry.id))
for (const id of DRIFT_IDS) {
  if (!driftIds.has(id)) fail(`docs/relay-contract.json: 少了 knownDrift ${id}`)
}
/** 每条漂移至少有一条向量在记账。 */
for (const id of DRIFT_IDS) {
  if (!vectors.vectors.some((vector) => (vector.why || '').includes(id))) {
    fail(`${vectorPath}: knownDrift ${id} 没有任何一条向量在 why 里引用它`)
  }
}

// ── ② 安装目录阶梯 ─────────────────────────────────────────────────────────

const ladder = readJson('test/contract/dsh-install-ladder.json')

/** 每个锚点在源码里的可识别写法（按出现位置判定顺序）。 */
const ANCHOR_PATTERNS = {
  'DSH_INSTALL_DIR': /DSH_INSTALL_DIR/,
  'self': /selfUrl|\bimport\.meta\.url\b/,
  '$DSH_HOME/profiles/web': /profiles['",\s]*,\s*['"]web['"]|profiles\/web/,
  'which dsh': /anchorFromExecutable|fromExecutable|which['"],\s*\[['"]dsh['"]\]/,
  'npm root -g': /anchorFromNpmRoot|fromNpmRoot|['"]root['"],\s*['"]-g['"]/,
  'process.argv[1]': /process\.argv\[1\]/,
}

/**
 * 抽出入口函数里锚点**按代码顺序出现**的那一段。
 *
 * 只取返回值，不取整个函数体：三个副本里 `anchorFromExecutable` /
 * `anchorFromNpmRoot` 这些辅助函数的**定义**出现在 `return [...]` 之前，
 * 按整个函数体扫位置会把它们的先后次序当成锚点次序，得到假结果。
 *
 * `ws.js` 的 `candidateAnchors` 不用数组字面量，而是 `anchors.push(...)` 逐个追加，
 * 所以两种写法都要认：有 `return [` 就切到它，否则从函数头切到函数尾。
 */
function anchoredList(source, entry) {
  const start = source.search(new RegExp(`(export\\s+)?function\\s+${entry}\\s*\\(`))
  if (start < 0) return undefined
  const returnAt = source.indexOf('return [', start)
  if (returnAt >= 0) {
    const end = source.indexOf(']', returnAt)
    return end < 0 ? source.slice(returnAt) : source.slice(returnAt, end)
  }
  // push 式：到下一个顶层 `}` 为止，并把 return 之前的语句也算进去。
  const end = source.indexOf('\n}\n', start)
  return end < 0 ? source.slice(start) : source.slice(start, end)
}

console.log('安装目录阶梯（契约 test/contract/dsh-install-ladder.json）：')
for (const copy of ladder.copies) {
  const body = anchoredList(read(copy.file), copy.entry)
  if (body === undefined) {
    fail(`${copy.file}: 找不到入口函数 ${copy.entry} 的 return [...] 列表`)
    continue
  }
  const found = Object.entries(ANCHOR_PATTERNS)
    .map(([name, pattern]) => [name, body.search(pattern)])
    .filter(([, index]) => index >= 0)
    .sort((a, b) => a[1] - b[1])
    .map(([name]) => name)
  const expected = copy.matches === 'canonical'
    ? ladder.canonical
    : ladder.canonical.filter((name) => !(copy.missing || []).includes(name))
      .concat(copy.extra || [])
  // 第四份（pendingAlignment）只打印：它的差异是有意保留的。
  const same = found.join(' → ') === expected.join(' → ')
  const tag = same ? 'ok  ' : (copy.pendingAlignment ? 'note' : 'FAIL')
  console.log(`  ${tag} ${copy.file} (${copy.entry})`)
  console.log(`        顺序: ${found.join(' → ') || '(一个都没找到)'}`)
  if (!same) {
    console.log(`        契约: ${expected.join(' → ')}`)
    console.log(`        差异: ${copy.pendingAlignment ? copy.reason : '与契约不符'}`)
    if (!copy.pendingAlignment) fail(`${copy.file}: 锚点集合/顺序与契约不符`)
  }
}

// ── ③ 调试钩子必须在 #if DEBUG 内 ──────────────────────────────────────────

const DEBUG_HOOKS = ['-DSHDemoMode', '-DSHForgetDirect', '-DSHFailAttachmentLoad']

/**
 * 把注释行挖空（保留行数），这样闸门只看**代码**。
 *
 * 否则一处 `/// Set by -DSHDemoMode` 的文档注释就会被当成泄漏的钩子：
 * 注释不产生二进制，判据关心的是那个字符串有没有真的进产物。
 */
function withoutComments(line) {
  const trimmed = line.trimStart()
  if (trimmed.startsWith('//') || trimmed.startsWith('///') || trimmed.startsWith('*')) return ''
  const at = line.indexOf('//')
  return at < 0 ? line : line.slice(0, at)
}

/** 逐行跟踪 `#if DEBUG / #else / #endif` 嵌套，返回每行是否处于 DEBUG 区间。 */
function debugMask(source) {
  const mask = []
  const stack = []
  for (const line of source.split('\n')) {
    const trimmed = line.trim()
    if (/^#if\b/.test(trimmed)) {
      stack.push({ isDebug: /^#if\s+DEBUG\b/.test(trimmed), inElse: false })
    } else if (/^#elseif\b/.test(trimmed)) {
      if (stack.length) stack[stack.length - 1].isDebug = false
    } else if (/^#else\b/.test(trimmed)) {
      if (stack.length) {
        const frame = stack[stack.length - 1]
        frame.isDebug = !frame.isDebug || !frame.inElse ? !frame.isDebug : frame.isDebug
        frame.inElse = true
      }
    }
    const active = stack.length > 0 && stack[stack.length - 1].isDebug
    mask.push(active)
    if (/^#endif\b/.test(trimmed)) stack.pop()
  }
  return mask
}

console.log('调试钩子闸门（每个字面量都必须在 `#if DEBUG` 区间内，只看代码不看注释）：')
for (const hook of DEBUG_HOOKS) {
  let hits = 0
  const files = []
  for (const file of listSwiftSources()) {
    const source = read(file)
    if (!source.includes(hook)) continue
    const mask = debugMask(source)
    source.split('\n').forEach((line, index) => {
      if (!withoutComments(line).includes(hook)) return
      hits += 1
      if (!mask[index]) {
        files.push(`${file}:${index + 1}`)
      }
    })
  }
  if (files.length) {
    fail(`${hook}: 有 ${files.length} 处在 #if DEBUG 之外 → ${files.join(', ')}`)
    console.log(`  FAIL ${hook}  ${hits} 处命中，其中 ${files.length} 处没加门`)
  } else {
    console.log(`  ok   ${hook}  ${hits} 处命中，全在 #if DEBUG 内（Release 分支 0 处）`)
  }
}

/** 所有 Swift 源文件（App + DSHKit），跳过构建产物。 */
function listSwiftSources() {
  return execFileSync('git', ['ls-files', '-z', '--', 'ios/**/*.swift'], {
    cwd: REPO_ROOT, encoding: 'utf8',
  }).split('\0').filter(Boolean)
}

// ── 结论 ───────────────────────────────────────────────────────────────────

if (problems.length) {
  console.error('\n契约漂移：')
  for (const problem of problems) console.error(`  - ${problem}`)
  process.exit(1)
}
console.log('\nok  契约检查通过（DLP 向量接线 / 安装阶梯 / 调试钩子闸门）')

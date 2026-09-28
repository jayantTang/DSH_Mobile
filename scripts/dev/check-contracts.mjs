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
 *   4. send-image 采集脚本：包内副本与 `skills/` 下的 canonical 必须逐字节相同。
 *   5. 能力词汇表：`hello.js` 是全集，Swift 常量只能取子集，App 不许写裸字面量。
 *   6. RPC catalog 自洽：`endpointCount` 与 `endpoints` / `kindCounts` 对得上。
 *   7. 连接器版本基线：契约里的 `connectorBaseline.minVersion` 与生成的 Swift 常量一致，
 *      且不高于仓库连接器版本、必须是 CHANGELOG 里已发布的连接器版本。
 *   8. `test:scripts` 列出的每个文件都已入库（`node --test` 会静默跳过缺失的）。
 *
 * **这是文本解析**：它拦得住「改了一份忘了另一份/把锚点顺序调了/把调试钩子移出门外」，
 * 拦不住等价重写。不要把它当成契约测试来宣传。
 */

import { execFileSync } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
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

// ── ④ send-image 采集脚本：包内副本与 canonical 必须逐字节相同 ──────────────
//
// 两份副本是**有意**的：canonical 在 `skills/` 下（skill 用），另一份在 npm 包里
// （npm 用户没有 `skills/` 目录，那是他们唯一能命中的候选）。人不会记得同时改两处，
// 所以由这条检查兜着。漂移了就 `node scripts/dev/sync-send-image-script.mjs`。

const sendImageContract = readJson('test/contract/send-image-script.json')

console.log('send-image 采集脚本（包内副本必须与 canonical 逐字节相同）：')
for (const { file, canonical } of sendImageContract.copies) {
  if (read(file) === read(canonical)) {
    console.log(`  ok   ${file} == ${canonical}`)
  } else {
    fail(`${file} 与 ${canonical} 不一致——跑 node scripts/dev/sync-send-image-script.mjs`)
    console.log(`  FAIL ${file} != ${canonical}`)
  }
}

// ── ⑤ 能力词汇表：JS 定义全集，Swift 只能取子集，App 不许写裸字面量 ──────────
//
// 能力名散落在三处（连接器 JS、iOS 常量、App 调用点）。契约文件是单一来源，
// 三端各自被钉在上面。**这不是运行时校验**：真正的行为在 `_link/hello` 交换里。

const CAPABILITY_CONTRACT = 'docs/relay-contract.json'
const HELLO_JS = 'plugins/mobile-link/lib/hello.js'
const LINK_HANDSHAKE_SWIFT = 'ios/DSHMobile/DSHKit/Sources/DSHKit/LinkHandshake.swift'
const APP_SWIFT_DIR = 'ios/DSHMobile/DSHMobile'

/** 从 `hello.js` 的 `SERVER_CAPABILITIES = [...]` 里抠出字符串元素。 */
function serverCapabilities() {
  const text = read(HELLO_JS)
  const match = text.match(/SERVER_CAPABILITIES\s*=\s*\[([\s\S]*?)\]/)
  if (!match) return null
  return [...match[1].matchAll(/'([^']+)'/g)].map((entry) => entry[1])
}

/** 从 Swift 的 `Capability` 枚举里抠出 `static let x = "..."` 的值。 */
function swiftCapabilityValues() {
  const text = read(LINK_HANDSHAKE_SWIFT)
  const block = text.match(/enum Capability\s*\{([\s\S]*?)\n\}/)
  if (!block) return null
  return [...block[1].matchAll(/static let \w+\s*=\s*"([^"]+)"/g)].map((entry) => entry[1])
}

console.log('能力词汇表（契约是全集；Swift 取子集；App 不写裸字面量）：')
const contractCapabilities = contract.capabilities ?? []
const jsCapabilities = serverCapabilities()

if (!Array.isArray(contractCapabilities) || contractCapabilities.length === 0) {
  fail(`${CAPABILITY_CONTRACT}: 缺少 capabilities 数组（能力词表的单一来源）`)
  console.log('  FAIL 契约里没有 capabilities')
} else if (!jsCapabilities) {
  fail(`${HELLO_JS}: 没找到 SERVER_CAPABILITIES 数组`)
  console.log('  FAIL hello.js 里没找到 SERVER_CAPABILITIES')
} else {
  const sorted = (list) => [...list].sort().join(',')
  if (sorted(jsCapabilities) !== sorted(contractCapabilities)) {
    fail(`${HELLO_JS} 的 SERVER_CAPABILITIES 与契约不一致：`
      + `JS=[${jsCapabilities.join(', ')}] 契约=[${contractCapabilities.join(', ')}]`)
    console.log(`  FAIL JS [${jsCapabilities.join(', ')}] != 契约 [${contractCapabilities.join(', ')}]`)
  } else {
    console.log(`  ok   JS 全集 == 契约（${contractCapabilities.length} 个：${contractCapabilities.join(', ')}）`)
  }

  const known = new Set(contractCapabilities)
  const swiftValues = swiftCapabilityValues()
  if (!swiftValues) {
    fail(`${LINK_HANDSHAKE_SWIFT}: 没找到 Capability 枚举`)
    console.log('  FAIL LinkHandshake.swift 里没找到 Capability')
  } else {
    const unknown = swiftValues.filter((value) => !known.has(value))
    if (unknown.length) {
      fail(`${LINK_HANDSHAKE_SWIFT} 的 Capability 里有契约之外的值：${unknown.join(', ')}`)
      console.log(`  FAIL Swift 常量不在契约里：${unknown.join(', ')}`)
    } else {
      console.log(`  ok   Swift 常量是契约子集（${swiftValues.length} 个：${swiftValues.join(', ')}）`)
    }
  }
}

// App 源码里不许再出现裸能力字面量：`store.supports("git")` 绕过了常量。
//
// 只看 `supports(`（ConnectionStore 的能力查询 API）。**不看 `contains(`**：那个名字
// 在这份代码里被用来问字符串/数组，18 处命中里 16 处是 `arguments.contains("-DSH…")`
// 这类无关调用，把它们算进来只会让检查变成噪音。
const nakedCapabilityUse = []
for (const file of listAppSwiftSources()) {
  read(file).split('\n').forEach((line, index) => {
    const code = withoutComments(line)
    if (/\bsupports\s*\(\s*"/.test(code)) {
      nakedCapabilityUse.push(`${file}:${index + 1}`)
    }
  })
}
if (nakedCapabilityUse.length) {
  fail(`App 里有裸能力字面量（应传 LinkHandshake.Capability 常量）：${nakedCapabilityUse.join(', ')}`)
  console.log(`  FAIL 裸字面量 ${nakedCapabilityUse.join(', ')}`)
} else {
  console.log('  ok   App 源码里没有 supports("…")')
}

// ── ⑥ RPC catalog 自洽 ─────────────────────────────────────────────────────
//
// catalog 没有消费者（没有脚本读它），所以它不会因为真实 host 变了而红。
// 这是**降级后的最低保证**：至少它自己不矛盾，不会被当成"活契约"引用。

const catalog = readJson('docs/dsh-rpc-catalog.json')

console.log('RPC catalog 自洽（端点计数与分类计数对得上）：')
{
  const endpoints = Array.isArray(catalog.endpoints) ? catalog.endpoints.length : -1
  const kindSum = Object.values(catalog.kindCounts ?? {}).reduce((sum, n) => sum + n, 0)
  const problemsHere = []
  if (catalog.endpointCount !== endpoints) {
    problemsHere.push(`endpointCount=${catalog.endpointCount} 但 endpoints.length=${endpoints}`)
  }
  if (kindSum !== catalog.endpointCount) {
    problemsHere.push(`kindCounts 之和=${kindSum} 但 endpointCount=${catalog.endpointCount}`)
  }
  if (problemsHere.length) {
    fail(`docs/dsh-rpc-catalog.json 自相矛盾：${problemsHere.join('；')}`)
    console.log(`  FAIL ${problemsHere.join('；')}`)
  } else {
    console.log(`  ok   endpointCount ${catalog.endpointCount} == endpoints.length；`
      + `kindCounts 之和 ${kindSum}（${JSON.stringify(catalog.kindCounts)}）`)
  }
}

// ── ⑦ 连接器版本基线：契约与生成的 Swift 常量必须一致 ──────────────────────
//
// App 运行时读不到 `docs/`，所以基线要生成成 Swift 常量。两处手改必然漂，
// 这条检查兜着：改了契约就重跑生成脚本。
//
// 除一致性外还有两条护栏（都是离线、CI 可跑的文本级断言）：
//   (b1) 基线不许高于仓库里的连接器版本——写高了会天天误报；
//   (b2) 基线必须是**已发布的连接器版本**（CHANGELOG 有 `## 连接器 <v>` 条目）——
//        这条正是「基线被写成 DSH host 版本、提示永不出现」那个事故的机械护栏。
//
// 已知限制（不必修）：CHANGELOG.md 缺 `## 连接器 0.2.0` 条目，所以将来若要把基线
// 降到 0.2.0，得先补那条变更记录，(b2) 才会绿。

const CONNECTOR_BASELINE_SWIFT = 'ios/DSHMobile/DSHMobile/Support/ConnectorBaseline.swift'

/** 与 `HostVersion` 同口径的数字段比较：`split('-')[0].split('.').map(Number)`，缺段补 0。 */
const versionSegments = (value) => value.split('-')[0].split('.').map(Number)

/** > 0 表示 a 比 b 新；只比数字段，rc 后缀不比（与 HostVersion 一致）。 */
const compareVersions = (a, b) => {
  const left = versionSegments(a)
  const right = versionSegments(b)
  const length = Math.max(left.length, right.length)
  for (let index = 0; index < length; index += 1) {
    const diff = (left[index] ?? 0) - (right[index] ?? 0)
    if (diff !== 0) return diff
  }
  return 0
}

console.log('连接器版本基线（契约 == 生成的 Swift 常量）：')
{
  const baseline = contract.connectorBaseline?.minVersion
  const generatedText = existsSync(join(REPO_ROOT, CONNECTOR_BASELINE_SWIFT))
    ? read(CONNECTOR_BASELINE_SWIFT) : null
  const generated = generatedText?.match(/minVersion\s*=\s*"([^"]+)"/)?.[1]
  if (!baseline) {
    fail(`${CAPABILITY_CONTRACT}: 缺少 connectorBaseline.minVersion`)
    console.log('  FAIL 契约里没有 connectorBaseline.minVersion')
  } else if (!generatedText) {
    fail(`${CONNECTOR_BASELINE_SWIFT} 不存在——跑 npm run gen:connector-baseline 生成`)
    console.log(`  FAIL 生成物不存在（${CONNECTOR_BASELINE_SWIFT}）`)
  } else if (!generated) {
    fail(`${CONNECTOR_BASELINE_SWIFT}: 没找到 minVersion 常量`)
    console.log('  FAIL 生成物里没有 minVersion')
  } else if (baseline !== generated) {
    fail(`连接器基线不一致：契约=${baseline} 生成物=${generated}——`
      + `跑 npm run gen:connector-baseline 重新生成`)
    console.log(`  FAIL 契约 ${baseline} != 生成物 ${generated}`)
  } else {
    console.log(`  ok   契约与生成物都是 ${baseline}`)
  }
}

// ── ⑦(b1) 基线不许高于仓库里的连接器版本 ───────────────────────────────────

console.log('连接器基线不高于仓库连接器（写高了会天天误报）：')
{
  const baseline = contract.connectorBaseline?.minVersion
  const repoVersion = readJson('plugins/mobile-link/package.json')?.version
  if (!baseline) {
    console.log('  SKIP 契约里没有 connectorBaseline.minVersion')
  } else if (!repoVersion) {
    fail('plugins/mobile-link/package.json 里没有 version，(b1) 无法判定')
    console.log('  FAIL 读不到仓库连接器版本')
  } else if (compareVersions(baseline, repoVersion) > 0) {
    fail(`基线 ${baseline} 高于仓库连接器 ${repoVersion}——写高了会天天误报`)
    console.log(`  FAIL 基线 ${baseline} > 仓库连接器 ${repoVersion}`)
  } else {
    console.log(`  ok   基线 ${baseline} <= 仓库连接器 ${repoVersion}`)
  }
}

// ── ⑦(b2) 基线必须是已发布的连接器版本（CHANGELOG 有 `## 连接器 <v>`）──────

console.log('连接器基线是已发布的连接器版本（CHANGELOG 有 `## 连接器 <v>`）：')
{
  const baseline = contract.connectorBaseline?.minVersion
  if (!baseline) {
    console.log('  SKIP 契约里没有 connectorBaseline.minVersion')
  } else {
    const changelog = read('CHANGELOG.md')
    const heading = `## 连接器 ${baseline}`
    const found = changelog.split('\n').some((line) => line.startsWith(heading))
    if (!found) {
      fail(`基线 ${baseline} 不是已发布的连接器版本——命名空间写错了？`
        + `（CHANGELOG.md 里没有以 \`${heading}\` 开头的行）`)
      console.log(`  FAIL 基线 ${baseline} 在 CHANGELOG.md 里没有 \`${heading}\` 条目`)
    } else {
      console.log(`  ok   CHANGELOG.md 有 \`${heading}\``)
    }
  }
}


// ── ⑧ test:scripts 里列的每个文件都必须入库 ────────────────────────────────
//
// `node --test` 对不存在的路径**只打印 `Could not find …` 然后 exit 0**——
// 漏提交一个测试文件，CI 会照绿，只是少跑若干条用例（本批实测：24 → 20）。
// 只有 git 层面拦得住，所以这里逐个 `git ls-files --error-unmatch`。

const packageJson = readJson('package.json')
const testScripts = packageJson.scripts?.['test:scripts'] ?? ''

console.log('test:scripts 的文件都在库里（防 --test 静默跳过）：')
{
  const listed = [...testScripts.matchAll(/(\S+\.mjs)/g)].map((entry) => entry[1])
  if (listed.length === 0) {
    fail('package.json 的 test:scripts 里没解析出任何 .mjs 文件')
    console.log('  FAIL 没解析出文件')
  } else {
    const missing = listed.filter((file) => {
      try {
        execFileSync('git', ['ls-files', '--error-unmatch', '--', file], {
          cwd: REPO_ROOT, stdio: 'ignore',
        })
        return false
      } catch {
        return true
      }
    })
    if (missing.length) {
      fail(`这些文件列在 test:scripts 里但没入库（node --test 会静默跳过）：${missing.join(', ')}`)
      console.log(`  FAIL 未入库：${missing.join(', ')}`)
    } else {
      console.log(`  ok   ${listed.length} 个文件都已入库`)
    }
  }
}

/** 所有 Swift 源文件（App + DSHKit），跳过构建产物。 */
function listSwiftSources() {
  return execFileSync('git', ['ls-files', '-z', '--', 'ios/**/*.swift'], {
    cwd: REPO_ROOT, encoding: 'utf8',
  }).split('\0').filter(Boolean)
}

/** 只属于 App 目标的 Swift 源（不含 DSHKit / 测试）。 */
function listAppSwiftSources() {
  return listSwiftSources().filter((file) => file.startsWith(`${APP_SWIFT_DIR}/`))
}

// ── 结论 ───────────────────────────────────────────────────────────────────

if (problems.length) {
  console.error('\n契约漂移：')
  for (const problem of problems) console.error(`  - ${problem}`)
  process.exit(1)
}
console.log('\nok  契约检查通过（DLP 向量接线 / 安装阶梯 / 调试钩子闸门 / send-image 脚本一致性 / 能力词表 / catalog 自洽 / host 基线 / test:scripts 入库）')

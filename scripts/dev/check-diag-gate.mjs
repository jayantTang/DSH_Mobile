#!/usr/bin/env node
/**
 * OTA 诊断闸门：**文本级**检查，配合发布脚本里的**产物级**断言。
 *
 *   node scripts/dev/check-diag-gate.mjs
 *
 * 三件事：
 *   1. `DIAGNOSTICS` 只出现在 App target 的 `OTA` 配置，`Debug` / `Release` 都不许有；
 *   2. 诊断源文件整段在 `#if DIAGNOSTICS` 内，且 App 里每一处 `AppDiagnostics` 引用
 *      也在同一道门内（否则 Release 编译会直接失败，而不是"悄悄带上"）；
 *   3. 两个发布脚本都带着哨兵断言（OTA 必须命中、TestFlight 必须不命中）。
 *
 * 这是文本解析：它拦得住「配置被改错、引用漏进门」，拦不住等价重写。
 * 真正的保证在产物上：`deploy-ota.sh` / `deploy-testflight.sh` 对导出的二进制跑 `strings`。
 *
 * 退出码：0 通过、1 有漂移、2 工具自身错误（文件读不到）。
 */

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const PBXPROJ = 'ios/DSHMobile/DSHMobile.xcodeproj/project.pbxproj'
const DIAG_SOURCE = 'ios/DSHMobile/DSHMobile/Diagnostics/AppDiagnostics.swift'
const APP_DIR = 'ios/DSHMobile/DSHMobile'
const SENTINEL = 'DSHDIAG-OTA-'

const read = (relative) => readFileSync(join(REPO_ROOT, relative), 'utf8')
const problems = []
const fail = (message) => problems.push(message)

/** 取出全部 `XCBuildConfiguration` 块：id、配置名、原文。 */
export function configBlocks(text) {
  const blocks = []
  const pattern = /^\t\t([0-9A-F]{24}) \/\* (Debug|Release|OTA) \*\/ = \{\n\t\t\tisa = XCBuildConfiguration;[\s\S]*?\n\t\t\tname = \2;\n\t\t\};$/gm
  for (const match of text.matchAll(pattern)) {
    blocks.push({ id: match[1], name: match[2], body: match[0] })
  }
  return blocks
}

/** App target 的配置块：带 bundle id 的那三个（项目级的没有）。 */
export function appTargetConfigs(pbxproj) {
  return configBlocks(pbxproj)
    .filter((block) => block.body.includes('PRODUCT_BUNDLE_IDENTIFIER = com.jayanttang.dsh;'))
}

/** 逐行跟踪 `#if` 栈，返回每个引用行是否在所有条件门内。 */
export function referencesInsideGate(text, needle) {
  const violations = []
  const stack = []
  for (const [index, line] of text.split('\n').entries()) {
    const trimmed = line.trim()
    if (trimmed.startsWith('#if ')) stack.push(trimmed.includes('DIAGNOSTICS'))
    else if (trimmed.startsWith('#else')) { if (stack.length) stack[stack.length - 1] = false }
    else if (trimmed.startsWith('#endif')) stack.pop()
    else if (trimmed.includes(needle) && !stack.every(Boolean)) violations.push(index + 1)
  }
  return violations
}

function listSwift(relativeRoot) {
  const out = []
  const walk = (absolute, relative) => {
    for (const name of readdirSync(absolute)) {
      if (name === '.build' || name === 'DerivedData') continue
      const childAbs = join(absolute, name)
      const childRel = `${relative}/${name}`
      if (statSync(childAbs).isDirectory()) walk(childAbs, childRel)
      else if (name.endsWith('.swift')) out.push(childRel)
    }
  }
  walk(join(REPO_ROOT, relativeRoot), relativeRoot)
  return out
}

try {
  const pbxproj = read(PBXPROJ)
  const configs = appTargetConfigs(pbxproj)
  if (configs.length === 0) fail(`${PBXPROJ}: 找不到 App target 的构建配置`)

  const ota = configs.find((block) => block.name === 'OTA')
  const release = configs.find((block) => block.name === 'Release')
  if (!ota) fail(`${PBXPROJ}: 没有 OTA 配置，deploy-ota.sh 依赖它`)
  if (!release) fail(`${PBXPROJ}: 没有 Release 配置，deploy-testflight.sh 依赖它`)

  if (ota && !/SWIFT_ACTIVE_COMPILATION_CONDITIONS = DIAGNOSTICS;/.test(ota.body)) {
    fail(`${PBXPROJ}: App target 的 OTA 配置缺 SWIFT_ACTIVE_COMPILATION_CONDITIONS = DIAGNOSTICS;`)
  }
  for (const block of configs) {
    if (block.name === 'OTA') continue
    if (/SWIFT_ACTIVE_COMPILATION_CONDITIONS = [^;]*DIAGNOSTICS/.test(block.body)) {
      fail(`${PBXPROJ}: ${block.name} 配置里出现了 DIAGNOSTICS，发布包会被带上诊断代码`)
    }
  }

  const source = read(DIAG_SOURCE)
  if (!source.trimStart().startsWith('#if DIAGNOSTICS')) {
    fail(`${DIAG_SOURCE}: 整段必须在 #if DIAGNOSTICS 内（第一行不是门就会进发布包）`)
  }
  if (!source.trimEnd().endsWith('#endif')) {
    fail(`${DIAG_SOURCE}: 末尾缺 #endif，诊断代码会漏进所有配置`)
  }

  for (const file of listSwift(APP_DIR)) {
    if (!read(file).includes('AppDiagnostics')) continue
    const lines = referencesInsideGate(read(file), 'AppDiagnostics')
    for (const line of lines) fail(`${file}:${line}: AppDiagnostics 引用不在 #if DIAGNOSTICS 内`)
  }

  for (const script of ['scripts/release/deploy-ota.sh', 'scripts/release/deploy-testflight.sh']) {
    if (!read(script).includes(SENTINEL)) fail(`${script}: 缺少产物哨兵断言（${SENTINEL}）`)
  }
} catch (error) {
  console.error(`check-diag-gate: ${error.message}`)
  process.exit(2)
}

if (problems.length) {
  console.error('OTA 诊断闸门未通过：')
  for (const problem of problems) console.error(`  - ${problem}`)
  process.exit(1)
}
console.log('ok  OTA 诊断闸门：DIAGNOSTICS 只在 OTA 配置、引用都在同一道门内、两个发布脚本都带哨兵断言')

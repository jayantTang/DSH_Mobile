#!/usr/bin/env node
/**
 * `check-layers.mjs` 自己的用例（跑法：`npm run test:scripts`）。
 *
 * 为什么这些用例值得写：守卫是"判定口径"而不是"便利工具"——它一旦把注释里的 import 当成
 * 违规、或把台账错误吞成 0，后面所有批次的判断都会建在错的地基上。所以这里钉的是四件事：
 *   1. 注释与字符串里的形状**不**命中；
 *   2. 白名单能真的放行 R2/R3，并且挡不住 R4；
 *   3. 台账坏了必须抛（调用方转成退出码 2），不许静默放过；
 *   4. 守卫自身不许引第三方依赖（R5）。
 */

import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import {
  RULES,
  WHITELIST_LIMIT,
  checkOwnImports,
  loadExemptions,
  loadWhitelist,
  maskNonCode,
  partition,
  scanFile,
} from './check-layers.mjs'

const KIT_FILE = 'ios/DSHMobile/DSHKit/Sources/DSHKit/Synthetic.swift'
const APP_FILE = 'ios/DSHMobile/DSHMobile/Runtime/Synthetic.swift'

/** 把一段源码落进临时文件，返回 (真实路径, 逻辑相对路径)。 */
function fixture(source, relative) {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-layers-'))
  const path = join(dir, 'Synthetic.swift')
  writeFileSync(path, source, 'utf8')
  return [path, relative]
}

function hitsFor(source, relative, whitelist = new Set()) {
  const [path] = fixture(source, relative)
  return scanFile(path, relative, whitelist)
}

test('注释与字符串里的 import 不算命中', () => {
  const source = [
    '// import UIKit',
    '/// 曾经写过 import SwiftUI',
    '/*',
    'import WebKit',
    '*/',
    'let note = "import UserNotifications"',
    'import Foundation',
  ].join('\n')
  assert.deepEqual(hitsFor(source, KIT_FILE), [])
})

test('Swift 多行字符串里的 import 也不算命中', () => {
  const source = ['let doc = """', 'import CoreGraphics', '"""', 'import Foundation'].join('\n')
  assert.deepEqual(hitsFor(source, KIT_FILE), [])
})

test('R1 命中 DSHKit 侧的 UI 框架 import', () => {
  const hits = hitsFor('import UIKit\n', KIT_FILE)
  assert.equal(hits.length, 1)
  assert.equal(hits[0].rule, 'R1')
  assert.equal(hits[0].line, 1)
})

test('R1 把 CoreGraphics 也算 UI 依赖（保住 Linux 构建）', () => {
  assert.equal(hitsFor('import CoreGraphics\n', KIT_FILE)[0].rule, 'R1')
})

test('R1 不扫 App 侧（App 当然可以用 UIKit）', () => {
  assert.deepEqual(hitsFor('import UIKit\n', APP_FILE), [])
})

test('R2/R3 在非白名单文件上命中', () => {
  const source = 'import DSHKit\n\nfunc f(client: DSHClient?) {}\n'
  const rules = hitsFor(source, APP_FILE).map((hit) => hit.rule).sort()
  assert.deepEqual(rules, ['R2', 'R3'])
})

test('R2/R3 对白名单文件放行', () => {
  const source = 'import DSHKit\nimport RelayKit\n\nfunc f(client: DSHClient?) {}\n'
  assert.deepEqual(hitsFor(source, APP_FILE, new Set([APP_FILE])), [])
})

test('R4 挡住白名单文件里的 UI 声明', () => {
  const source = 'import SwiftUI\n\nstruct Adapter: View { var body: some View { EmptyView() } }\n'
  const hits = hitsFor(source, APP_FILE, new Set([APP_FILE]))
  assert.equal(hits.length, 1)
  assert.equal(hits[0].rule, 'R4')
})

test('R4 不扫非白名单文件', () => {
  const source = 'import SwiftUI\n\nstruct Screen: View { var body: some View { EmptyView() } }\n'
  assert.deepEqual(hitsFor(source, APP_FILE), [])
})

test('R3 只按整词匹配，不做子串误伤', () => {
  const source = 'struct MyMessageStoreLike {}\nlet x = "DSHClientish"\n'
  assert.deepEqual(hitsFor(source, APP_FILE), [])
})

test('豁免按「文件 + 规则 + 片段」记账', () => {
  const [path] = fixture('import DSHKit\n', APP_FILE)
  const hit = scanFile(path, APP_FILE, new Set())[0]
  const exemption = { file: hit.file, rule: hit.rule, snippet: hit.snippet, reason: '测试用' }
  const { unexempted, exempted } = partition([hit], [exemption])
  assert.equal(unexempted.length, 0)
  assert.equal(exempted.length, 1)
})

test('片段变了就不再被豁免（行号漂移不影响）', () => {
  const [path] = fixture('import DSHKit\n', APP_FILE)
  const hit = scanFile(path, APP_FILE, new Set())[0]
  const stale = { file: hit.file, rule: hit.rule, snippet: 'import RelayKit', reason: '旧片段' }
  const { unexempted } = partition([hit], [stale])
  assert.equal(unexempted.length, 1)
})

test('白名单缺 note / 通配 / 文件不存在都抛错（调用方转 2）', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-layers-'))
  const withoutNote = join(dir, 'a.json')
  writeFileSync(withoutNote, JSON.stringify({ files: [{ path: 'package.json' }] }), 'utf8')
  assert.throws(() => loadWhitelist(withoutNote), /缺 note/)

  const wildcard = join(dir, 'b.json')
  writeFileSync(wildcard, JSON.stringify({ files: [{ path: 'ios/DSHMobile/DSHMobile/**', note: 'n' }] }), 'utf8')
  assert.throws(() => loadWhitelist(wildcard), /不允许通配/)

  const missing = join(dir, 'c.json')
  writeFileSync(missing, JSON.stringify({ files: [{ path: 'ios/nope.swift', note: 'n' }] }), 'utf8')
  assert.throws(() => loadWhitelist(missing), /不存在/)

  const broken = join(dir, 'd.json')
  writeFileSync(broken, '{ not json', 'utf8')
  assert.throws(() => loadWhitelist(broken), /不是合法 JSON/)
})

test('白名单上限与 SC-002 一致', () => {
  assert.equal(WHITELIST_LIMIT, 8)
})

test('豁免缺 reason 或规则未知都抛错', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-layers-'))
  const noReason = join(dir, 'e.json')
  writeFileSync(noReason, JSON.stringify({
    exemptions: [{ file: 'a.swift', rule: 'R2', snippet: 'import DSHKit' }],
  }), 'utf8')
  assert.throws(() => loadExemptions(noReason), /缺 reason/)

  const unknownRule = join(dir, 'f.json')
  writeFileSync(unknownRule, JSON.stringify({
    exemptions: [{ file: 'a.swift', rule: 'R9', snippet: 'x', reason: 'y' }],
  }), 'utf8')
  assert.throws(() => loadExemptions(unknownRule), /未知规则/)
})

test('规则 id 就是契约里的 R1–R4', () => {
  assert.deepEqual(RULES.map((rule) => rule.id), ['R1', 'R2', 'R3', 'R4'])
})

test('R5：守卫自身不引第三方依赖', () => {
  assert.deepEqual(checkOwnImports("import { join } from 'node:path'\nimport './x.mjs'\n"), [])
  assert.deepEqual(checkOwnImports("import yaml from 'yaml'\n"), ['yaml'])
})

// ── 拦截口径（owner 2026-10-14：R2 降为报告指标，默认改拦截）────────────────

test('R2 是报告指标：它不参与拦截', () => {
  const r2 = RULES.find((rule) => rule.id === 'R2')
  const r3 = RULES.find((rule) => rule.id === 'R3')
  assert.equal(r2.advisory, true, 'R2 必须标成 advisory —— 门面在 DSHKit 里，产品文件要用它就得 import')
  assert.notEqual(r3.advisory, true, 'R3（实现层标识符）必须仍然拦截')
})

test('默认拦截：--report-only 才退回报告模式', async () => {
  const { spawnSync } = await import('node:child_process')
  const repo = new URL('../..', import.meta.url).pathname
  const run = (args) => spawnSync(process.execPath, ['scripts/dev/check-layers.mjs', ...args], {
    cwd: repo, encoding: 'utf8',
  })
  // 默认（拦截）在"拦截规则未豁免 = 0"的当前库里应当是 0，并且明确写出报告指标。
  const enforced = run([])
  assert.equal(enforced.status, 0, `默认拦截应当在拦截命中为 0 时通过，实得 ${enforced.status}\n${enforced.stdout}`)
  assert.match(enforced.stdout, /拦截规则未豁免 0 处/)
  assert.match(enforced.stdout, /报告指标 \d+ 处（R2，不拦截）/)

  // 报告模式：恒 0，且明说这是排查用的模式。
  const reportOnly = run(['--report-only'])
  assert.equal(reportOnly.status, 0)
  assert.match(reportOnly.stdout, /报告模式：只给证据、不拦截/)
})

test('已知盲区：字符串插值里的实现层引用抓不到（待做插值感知的掩码）', () => {
  // 2026-10-14 在 ChatModel.swift 真抓到一处：`"(\(RelayFileTransfer.fileSize(url)) bytes)"`。
  // 掩码把整段字面量抹掉，所以插值里的代码也看不见。这条用例**固化当前行为**，
  // 等掩码学会认 `\(...)` 之后应当把它反过来（那时这里要有命中）。
  const dir = mkdtempSync(join(tmpdir(), 'dsh-layers-'))
  const file = join(dir, 'Interpolated.swift')
  writeFileSync(file, 'let text = "size: \\(RelayFileTransfer.fileSize(url)) bytes"\n', 'utf8')
  const hits = scanFile(file, 'ios/DSHMobile/DSHMobile/Features/Chat/Interpolated.swift', new Set())
  assert.deepEqual(hits.filter((hit) => hit.rule === 'R3'), [],
    '当前确实抓不到；这不是"没问题"，是掩码的已知盲区')
})

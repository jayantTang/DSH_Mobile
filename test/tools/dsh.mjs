#!/usr/bin/env node
// The tester's console: the verbs, called one at a time.
//
//   dsh.mjs prepare [--build]          查端点、起仿真器、必要时编译
//   dsh.mjs plan <用例>                把用例翻译成执行计划，只打印不执行
//   dsh.mjs run <用例> [--no-build]    执行一条用例，产出判定与截图
//   dsh.mjs shot <名字> [--note "…"]   立刻截一张当前画面
//   dsh.mjs report [--verdict 通过]    把结果写成 HTML 报告
//   dsh.mjs ls                         列出已有运行
//   dsh.mjs release                    用 Release / 真机配置编译（发布前必跑）
//
// The verbs are split because the tester decides what to run, when to look
// again, and what the outcome is. None of them decides anything.
import { existsSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

import {
  BUILD, DEFAULT_SIM, DERIVED, HERE, PROJECT, ROOT, RUNS, TEST_DIR,
  appVersion, bootSimulator, build, ensureRunDir, gitCommit, host, installRunner, log,
  parseArgs, pickSession, resolveRun, run, stagePlan, stamp, warn,
} from './context.mjs'
import { execute } from './run.mjs'

const USAGE = `用法：
  dsh.mjs prepare [--build]               准备环境（端点、仿真器、必要时编译）
  dsh.mjs plan <用例.md>                  看用例被翻译成什么（不执行）
  dsh.mjs run <用例.md> [--no-build]      执行用例
  dsh.mjs shot <名字> [--note "说明"]     截取当前画面
  dsh.mjs scaffold                        生成本次运行的 review.md 骨架
  dsh.mjs report --verdict 通过|可疑|失败|未验证 [--note "结论"] [--basis "依据"]
  dsh.mjs ls                              列出运行记录
  dsh.mjs release                         用 Release / 真机配置编译（发布前必跑）

报告规范见 test/REPORT-CONTRACT.md：缺声明、缺步骤、实际复述期望都会被判为
「报告不完整」并在报告顶部列出，补齐 review.md 后重跑 report 即可。

公共选项：--run <id> 指定或复用某次运行目录；--sim <udid> 换仿真器。`

async function prepare(flags) {
  const simId = flags.sim ?? DEFAULT_SIM
  log('读取本机 DSH 端点')
  const live = host()
  console.log(`    port=${live.port}（来源 ${live.source}）`)
  log('挑选只读会话')
  const sessionId = await pickSession(live)
  console.log(`    session=${sessionId || '（无）'}`)
  log('准备仿真器')
  bootSimulator(simId)
  log('编译（增量，产物已最新则跳过）')
  const result = build(simId, { force: Boolean(flags.build) })
  console.log(result.skipped ? '    产物已是最新' : `    编译完成 ${result.seconds.toFixed(1)}s`)
  installRunner(simId)
  const state = { simId, port: live.port, source: live.source, sessionId,
                  built: !result.skipped, builtSeconds: result.seconds ?? 0,
                  appVersion: appVersion(), gitCommit: gitCommit() }
  writeFileSync(join(BUILD, 'ready.json'), JSON.stringify(state, null, 2))
  console.log(JSON.stringify(state, null, 2))
}

/// One picture of whatever is on screen right now.
///
/// Runs through the same engine as a case so the capture does not depend on the
/// simulator's own display, which an app under test never appears on.
async function shot(flags, positional) {
  const name = positional[0]
  if (!name) throw new Error('shot 需要一个名字，例如 `dsh.mjs shot composer`')
  const simId = flags.sim ?? DEFAULT_SIM
  const runId = flags.run && flags.run !== true ? flags.run : stamp()
  const { runDir, shotsDir, detailDir } = ensureRunDir(runId)
  const note = flags.note && flags.note !== true ? flags.note : name

  const plan = {
    run: runId,
    case: `${name}（随手截图）`,
    caseTitle: note,
    caseVersion: '',
    caseFile: '',
    bundleId: 'com.jayanttang.dsh',
    screens: [],
    shots: [{ name, note }],
  }
  writeFileSync(join(BUILD, 'plan.json'), JSON.stringify(plan, null, 2))
  bootSimulator(simId)
  installRunner(simId)
  stagePlan(simId, plan)

  const resultBundle = join(detailDir, 'result.xcresult')
  rmSync(resultBundle, { recursive: true, force: true })
  log('截取当前画面')
  run('xcodebuild', ['-project', join(PROJECT, 'DSHMobile.xcodeproj'), '-scheme', 'DSHMobile',
    '-configuration', 'Debug', '-destination', `platform=iOS Simulator,id=${simId}`,
    '-derivedDataPath', DERIVED, '-resultBundlePath', resultBundle, 'test-without-building',
    '-only-testing:DSHMobileUITests/Engine'], { quiet: true })

  const staging = join(detailDir, 'attachments')
  rmSync(staging, { recursive: true, force: true })
  run('xcrun', ['xcresulttool', 'export', 'attachments', '--path', resultBundle,
                '--output-path', staging], { quiet: true })
  const listed = JSON.parse(readFileSync(join(staging, 'manifest.json'), 'utf8'))
  let saved = null
  for (const group of listed) {
    for (const attachment of group.attachments ?? []) {
      if (!(attachment.suggestedHumanReadableName ?? '').startsWith('shot~')) continue
      saved = join(shotsDir, `01-shot-${name}.png`)
      writeFileSync(saved, readFileSync(join(staging, attachment.exportedFileName)))
    }
  }
  rmSync(staging, { recursive: true, force: true })
  if (!saved) throw new Error('没有拿到截图')
  console.log(`    已保存 test/runs/${runId}/shots/01-shot-${name}.png`)
  return { runId, runDir, file: saved }
}

/// The HTML report, and the lint verdict that gates it.
///
/// report.py is run for its JSON result, not just its output file: a report that
/// failed lint is rendered anyway (so the file exists and can be looked at) but
/// the verdict becomes 报告不完整, and this call has to say so loudly — the whole
/// point of the gate is that "跑完了" cannot be mistaken for "测过了".
function report(flags) {
  const { runId, runDir } = resolveRun(flags)
  const verdict = typeof flags.verdict === 'string' ? flags.verdict : ''
  if (!verdict) {
    throw new Error('report 必须给判定：--verdict 通过|可疑|失败|未验证\n' +
                    '  报告不再有「待审视」默认值——没判定就是没判定。')
  }
  const argv = [join(HERE, 'report.py'), '--run-dir', runDir, '--verdict', verdict,
                '--note', typeof flags.note === 'string' ? flags.note : '']
  if (typeof flags.basis === 'string') argv.push('--basis', flags.basis)
  if (flags['allow-lint-errors']) argv.push('--allow-lint-errors')
  const result = run(join(TEST_DIR, '.venv/bin/python'), argv, { quiet: true })
  const parsed = JSON.parse(result.trim().split('\n').at(-1))
  const file = `${parsed.report.slice(ROOT.length + 1)}`
  for (const item of parsed.lint.warnings) console.log(`  提醒 [${item.code}] ${item.message}`)
  if (parsed.lint.ok) {
    console.log(`报告：${file}　判定 ${parsed.verdict}`)
    return { runId, file }
  }
  warn(`报告不完整（${parsed.lint.errors.length} 项必须补齐），已按「报告不完整」出图：${file}`)
  for (const item of parsed.lint.errors.slice(0, 12)) console.log(`  阻断 [${item.code}] ${item.message}`)
  if (parsed.lint.errors.length > 12) console.log(`  …另有 ${parsed.lint.errors.length - 12} 项`)
  console.log('  补齐 review.md 后重跑 report 即可，不需要重跑用例。')
  return { runId, file }
}

/// Writes the review.md skeleton: every step's id, wording and expectation.
function scaffold(flags) {
  const { runId, runDir } = resolveRun(flags)
  const result = run(join(TEST_DIR, '.venv/bin/python'),
                     [join(HERE, 'report.py'), '--run-dir', runDir, '--scaffold'],
                     { quiet: true })
  const parsed = JSON.parse(result.trim().split('\n').at(-1))
  if (parsed.existed) {
    console.log(`已有 review.md，未覆盖：${runDir}/review.md`)
    return { runId, created: false }
  }
  console.log(`已生成 ${parsed.scaffolded.slice(ROOT.length + 1)}` +
              '（声明+逐步记录+发现+回归，填空即可）')
  return { runId, created: true }
}

function list() {
  if (!existsSync(RUNS)) { console.log('（还没有运行记录）'); return }
  for (const id of readdirSync(RUNS).sort()) {
    const summary = join(RUNS, id, 'summary.json')
    let line = id
    if (existsSync(summary)) {
      const data = JSON.parse(readFileSync(summary, 'utf8'))
      const shots = (data.screenshots ?? []).filter((entry) => entry.file).length
      const blocked = (data.lint?.errors ?? []).length
      line += `  ${data.case}  引擎 ${data.engineVerdict}  截图 ${shots} 张` +
              (data.judgement ? `  判定 ${data.judgement}` : '  未判定') +
              (blocked ? `  报告不完整(${blocked})` : '')
    }
    console.log(line)
  }
}

const { flags, positional } = parseArgs()
const verb = positional.shift() ?? 'help'

try {
  switch (verb) {
    case 'prepare': await prepare(flags); break
    case 'plan': await execute({ ...flags, 'plan-only': true, 'no-build': true }, positional); break
    case 'run': await execute(flags, positional); break
    case 'shot': await shot(flags, positional); break
    case 'scaffold': scaffold(flags); break
    case 'report': report(flags); break
    case 'ls': list(); break
    case 'release': {
      // Imported lazily: an archive takes a minute and only a publish needs it.
      const module = await import('./release-check.mjs')
      await module.default()
      break
    }
    default: console.log(USAGE)
  }
} catch (error) {
  warn(error.message)
  process.exit(2)
}

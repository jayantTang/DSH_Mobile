#!/usr/bin/env node
/**
 * 选择性拦截：一次改动 → 该在哪几级渠道取得证据 → 缺哪一级就非零退出。
 *
 * 判定口径**只**来自 `scripts/verify/lanes.json`（矩阵）。这里不写第二份规则：
 * 要改判定就改矩阵；矩阵本身坏掉（缺格、重复、枚举越界、理由缺失、入口与
 * package.json 漂移）按工具自身错误退出 2。
 *
 *   node scripts/dev/check-lanes.mjs --changed plugins/mobile-link/lib/link.js
 *   node scripts/dev/check-lanes.mjs --changed-from changed.txt --json
 *
 * 证据"新鲜"的判据是机械的：证据包的 mtime 必须不早于被改文件里最新的那个。
 */

import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'

import { readEvidence } from '../verify/evidence.mjs'
import { createRegistry } from '../verify/lane.mjs'
import { REPO_ROOT, loadMatrix, requiredLanes, validateLaneEntries, validateMatrix } from '../verify/matrix.mjs'

const DEFAULT_EVIDENCE_ROOT = join(REPO_ROOT, '.lanes', 'runs')

/** 改动清单：显式给的优先；否则用 git（工作区 + 已暂存 + 未跟踪）。 */
export function collectChangedFiles({ changed = [], from = undefined, repo = REPO_ROOT, git = runGit } = {}) {
  if (changed.length > 0) return changed
  if (from) return readFileSync(from, 'utf8').split('\n').map((line) => line.trim()).filter(Boolean)
  const files = new Set()
  for (const args of [['diff', '--name-only', 'HEAD'], ['ls-files', '--others', '--exclude-standard']]) {
    const result = git(args, repo)
    for (const line of result.split('\n')) if (line.trim()) files.add(line.trim())
  }
  return [...files]
}

/**
 * 校验必跑集合的证据。
 *
 * 两种"不算缺"的来源必须与"真的验过"分开记：
 *   - `ciCovered`：CI 模式下 L1/L2 由 workflow 自己的作业覆盖（它们挂了 PR 就红）；
 *   - `exempt`：L3 这类 CI 跑不了的格子，改动记录里给了 `L3: <verdict 路径>` 或
 *     `L3: 未跑 — <理由>` 的声明。声明是"允许未跑但要留痕"，不是"验过"。
 */
export function evaluateEvidence({ required, reasons, entries, evidenceRoot = DEFAULT_EVIDENCE_ROOT, changedFiles = [], ciCovered = [], l3Declaration = '', scenarios = {} } = {}) {
  const newestChange = newestMtime(changedFiles)
  const satisfied = []
  const covered = []
  const exempt = []
  const missing = []
  const blocked = []
  const evidence = {}
  const stale = {}
  for (const lane of required) {
    const allowed = Array.isArray(scenarios[lane]) && scenarios[lane].length > 0
      ? new Set(scenarios[lane])
      : null
    const candidates = entries.filter((entry) => entry.verdict?.lane === lane
      && entry.issues.length === 0
      && (allowed === null || allowed.has(entry.verdict?.scenario)))
    const passes = candidates.filter((entry) => entry.verdict.status === 'pass')
    const blocks = candidates.filter((entry) => entry.verdict.status === 'blocked')
    const fresh = passes.filter((entry) => mtimeOf(entry.path) >= newestChange)
    if (fresh.length > 0) {
      satisfied.push(lane)
      evidence[lane] = relative(fresh[fresh.length - 1].path)
      continue
    }
    if (passes.length > 0) stale[lane] = `证据比改动旧（${relative(passes[passes.length - 1].path)}）`
    if (ciCovered.includes(lane)) {
      covered.push(lane)
      continue
    }
    const declared = lane === 'l3' ? parseL3Declaration(l3Declaration) : undefined
    if (declared !== undefined) {
      exempt.push({ lane, reason: declared })
      continue
    }
    if (blocks.length > 0) {
      blocked.push({ lane, reason: blocks[blocks.length - 1].verdict.blockedReason, nextStep: blocks[blocks.length - 1].verdict.nextStep })
    }
    missing.push(lane)
  }
  return { required, satisfied, covered, exempt, missing, blocked, reasons, scenarios, evidence, stale }
}

/**
 * 改动记录里的 L3 声明。两种写法都认：
 *   `L3: .lanes/runs/l3/<run-id>/verdict.json`（本机跑过，附证据路径）
 *   `L3: 未跑 — <理由>`（明确没跑，但说清为什么）
 * 认不出的写法一律不算声明——"没写"与"写了看不懂"都要挡下来。
 */
export function parseL3Declaration(text) {
  const source = String(text ?? '')
  const withEvidence = /L3[:：]\s*(\S*\.lanes\/runs\/l3\/\S*verdict\.json)/.exec(source)
  if (withEvidence !== null) return `本机已跑 L3：${withEvidence[1]}`
  const notRun = /L3[:：]\s*(未跑|不跑)\s*[—\-:：]?\s*([^\n]{4,})/.exec(source)
  if (notRun !== null) return `L3 ${notRun[1]}：${notRun[2].trim()}`
  return undefined
}

function newestMtime(files) {
  let newest = 0
  for (const file of files) {
    const path = resolve(REPO_ROOT, file)
    if (!existsSync(path)) continue
    newest = Math.max(newest, statSync(path).mtimeMs)
  }
  return newest
}

function mtimeOf(path) {
  try {
    return statSync(path).mtimeMs
  } catch {
    return 0
  }
}

function relative(path) {
  return path.startsWith(`${REPO_ROOT}/`) ? path.slice(REPO_ROOT.length + 1) : path
}

function runGit(args, repo) {
  const result = spawnSync('git', args, { cwd: repo, encoding: 'utf8' })
  return result.status === 0 ? result.stdout : ''
}

function parseArgs(argv) {
  const changed = []
  const require = []
  const flags = {}
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (token === '--changed') changed.push(argv[++index])
    else if (token === '--require') require.push(argv[++index])
    else if (token === '--changed-from') flags.from = argv[++index]
    else if (token === '--evidence-root') flags.evidenceRoot = argv[++index]
    else if (token === '--l3-declaration') flags.l3Declaration = argv[++index]
    else if (token === '--ci') flags.ci = true
    else if (token === '--json') flags.json = true
    else if (token === '--help' || token === '-h') flags.help = true
    else throw new Error(`未知参数：${token}`)
  }
  return { changed, require, flags }
}

export function gate({ changed = [], from, require: forced = [], evidenceRoot = DEFAULT_EVIDENCE_ROOT, matrixPath, ci = false, l3Declaration = '', registry } = {}) {
  const matrix = loadMatrix(matrixPath)
  const pkg = JSON.parse(readFileSync(join(REPO_ROOT, 'package.json'), 'utf8'))
  const issues = [...validateMatrix(matrix), ...validateLaneEntries(matrix, pkg.scripts ?? {})]
  if (issues.length > 0) return { exitCode: 2, toolError: issues }

  const files = collectChangedFiles({ changed, from })
  const decision = requiredLanes(matrix, files)
  const required = [...new Set([...decision.required, ...forced])].sort()
  const entries = readEvidence(evidenceRoot)
  // CI 里 L1/L2 由 workflow 自己的作业覆盖（它们红了 PR 就红）；L3 跑不了，只能要声明。
  const ciCovered = ci ? required.filter((lane) => lane === 'l1' || lane === 'l2') : []
  const verdict = evaluateEvidence({ required, reasons: decision.reasons, scenarios: decision.scenarios, entries, evidenceRoot, changedFiles: files, ciCovered, l3Declaration })
  const ok = verdict.missing.length === 0
  return {
    exitCode: ok ? 0 : 1,
    ok,
    changedFiles: files,
    subjects: decision.subjects,
    required,
    ci,
    ...verdict,
    hints: laneHints(verdict.missing, registry ?? safeRegistry()),
  }
}

/**
 * 缺证据时顺手问一句那一级"现在能不能跑"：缺工具就说缺什么、下一步装什么。
 * 不这么做的话，使用者只会看到一行 MISS，得自己猜到"其实这一级根本没装"（T031）。
 */
function laneHints(missing, registry) {
  const hints = {}
  for (const lane of missing) {
    const definition = registry?.[lane]
    if (definition === undefined) continue
    try {
      const report = definition.doctor({ env: process.env })
      if (!report.available) hints[lane] = { blockedReason: report.blockedReason, nextStep: report.nextStep }
    } catch (error) {
      hints[lane] = { blockedReason: `doctor 抛错：${error.message}`, nextStep: '先修 doctor 自身' }
    }
  }
  return hints
}

/** 拿不到渠道定义时不要连累判定：提示是附加信息，不是判据。 */
function safeRegistry() {
  try {
    return createRegistry()
  } catch {
    return {}
  }
}

function format(result) {
  if (result.toolError) return `矩阵/入口自身有问题（退出码 2）：\n  ${result.toolError.join('\n  ')}`
  const lines = [`改动命中：${result.subjects.join('、') || '（没有命中任何被测对象）'}`]
  lines.push(`必跑渠道：${result.required.join('、') || '（无）'}${result.ci ? '（CI 模式：L1/L2 由本 workflow 的作业覆盖）' : ''}`)
  for (const lane of result.required) {
    const why = result.reasons[lane] ?? '被 --require 强制要求'
    if (result.satisfied.includes(lane)) lines.push(`  ok      ${lane} — ${result.evidence[lane]}（${why}）`)
    else if (result.covered.includes(lane)) lines.push(`  CI      ${lane} — 由 workflow 作业覆盖（${why}）`)
    else if (result.exempt.some((item) => item.lane === lane)) {
      const item = result.exempt.find((entry) => entry.lane === lane)
      lines.push(`  声明    ${lane} — ${item.reason}（${why}）`)
    } else {
      const hint = result.hints?.[lane]
      const want = result.scenarios?.[lane]
      const scenarioNote = want ? `；只认场景：${want.join('/')}` : ''
      const suffix = hint ? `；这一级当前不可用：${hint.blockedReason} → ${hint.nextStep}` : ''
      lines.push(`  MISS    ${lane} — ${why}${scenarioNote}${result.stale[lane] ? `；${result.stale[lane]}` : ''}${suffix}`)
    }
  }
  for (const block of result.blocked) lines.push(`  BLOCKED ${block.lane} — ${block.reason}；下一步：${block.nextStep}`)
  if (!result.ok) {
    lines.push('缺证据：跑 `npm run lane:<id> -- run --scenario <name>` 补齐；L3 已降为手动清单，')
    lines.push('需要强制时用 `--require l3` 并在改动记录里写 `L3: 未跑 — <理由>`。')
  }
  return lines.join('\n')
}

async function main(argv = process.argv.slice(2)) {
  let args
  try {
    args = parseArgs(argv)
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    return 2
  }
  if (args.flags.help) {
    process.stdout.write('用法：check-lanes.mjs [--changed <file>]… [--changed-from <file>] [--require <lane>]…\n'
      + '                    [--ci] [--l3-declaration <text>] [--json]\n')
    return 0
  }
  let result
  try {
    result = gate({
      changed: args.changed,
      from: args.flags.from,
      require: args.require,
      evidenceRoot: args.flags.evidenceRoot ?? DEFAULT_EVIDENCE_ROOT,
      ci: args.flags.ci === true,
      l3Declaration: args.flags.l3Declaration ?? process.env.DSH_L3_DECLARATION ?? '',
    })
  } catch (error) {
    process.stderr.write(`工具错误：${error.message}\n`)
    return 2
  }
  process.stdout.write(args.flags.json ? `${JSON.stringify(result, null, 2)}\n` : `${format(result)}\n`)
  return result.exitCode
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().then((code) => process.exit(code), (error) => {
    process.stderr.write(`${error.stack ?? error}\n`)
    process.exit(2)
  })
}

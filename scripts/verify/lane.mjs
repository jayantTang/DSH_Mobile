#!/usr/bin/env node
/**
 * 两级验证渠道的统一入口。
 *
 *   npm run lane:doctor                     # 两级自检（只报告，不装东西）
 *   npm run lane:l1                         # 单级自检
 *   npm run lane:l1 -- run --scenario smoke # 跑一个场景，写证据包
 *
 * 渠道以**注入**的方式接入（`createRegistry`），所以单测可以塞一个假渠道进来，
 * 不需要真的起宿主或容器（宪法 VII.1）。
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

import { formatDoctor, runDoctor } from './doctor.mjs'
import { runId, writeEvidence } from './evidence.mjs'
import { lane as l1 } from './l1.mjs'
import { lane as l2 } from './l2.mjs'
import { REPO_ROOT } from './matrix.mjs'

const EVIDENCE_ROOT = join(REPO_ROOT, '.lanes', 'runs')

/** 默认两级；单测传自己的 registry 即可替换。 */
export function createRegistry(overrides = {}) {
  return { l1, l2, ...overrides }
}

/**
 * 跑一个场景并写证据包。
 * @param {{registry: object, laneId: string, scenario: string, evidenceRoot?: string,
 *          force?: boolean, env?: object, log?: Function}} input
 */
export async function runScenario({ registry, laneId, scenario, evidenceRoot = EVIDENCE_ROOT, force = false, env = process.env, log = console.log }) {
  const lane = registry[laneId]
  if (lane === undefined) throw new Error(`未知渠道：${laneId}（可用：${Object.keys(registry).join('/')}）`)
  const definition = lane.scenarios?.[scenario]
  const id = runId(new Date(), scenario)
  const outDir = join(evidenceRoot, laneId, id)
  mkdirSync(outDir, { recursive: true })
  const base = { lane: laneId, runId: id, scenario, startedAt: new Date().toISOString() }

  if (definition === undefined) {
    return persist({
      verdict: blockedVerdict({
        base,
        reason: `渠道 ${laneId} 里没有场景 ${scenario}`,
        nextStep: `可选场景：${Object.keys(lane.scenarios ?? {}).join('、') || '（还没有实现，见 specs/006-verify-lanes/tasks.md）'}`,
        argv: ['lane', laneId, 'run', '--scenario', scenario],
      }),
      evidenceRoot, outDir,
    })
  }

  const health = safeDoctor(lane, env)
  if (!health.available && !force) {
    return persist({
      verdict: blockedVerdict({
        base,
        reason: health.blockedReason,
        nextStep: health.nextStep,
        argv: ['lane', laneId, 'doctor'],
        note: '自检未通过，未执行场景',
      }),
      evidenceRoot, outDir,
    })
  }

  log(`lane ${laneId}: 跑场景 ${scenario} → ${outDir}`)
  const result = await definition.run({ outDir, env, log, root: REPO_ROOT })
  return persist({ verdict: assembleVerdict({ base, laneId, scenario, result }), evidenceRoot, outDir })
}

/** 把场景返回的东西补成一份完整证据包。 */
function assembleVerdict({ base, laneId, scenario, result }) {
  return {
    ...base,
    status: result.status,
    commands: result.commands ?? [{ argv: ['lane', laneId, 'run', '--scenario', scenario], exitCode: 0 }],
    isolation: result.isolation,
    observations: result.observations,
    blockedReason: result.blockedReason,
    nextStep: result.nextStep,
    notes: result.note,
    finishedAt: new Date().toISOString(),
  }
}

/** 写证据；不合法时把原始内容留在 outDir，别让几分钟的实跑白跑。 */
function persist({ verdict, evidenceRoot, outDir }) {
  try {
    writeEvidence({ root: evidenceRoot, verdict })
  } catch (error) {
    const fallback = join(outDir, 'verdict.invalid.json')
    writeFileSync(fallback, `${JSON.stringify(verdict, null, 2)}\n`)
    throw new Error(`${error.message}\n  （原始证据已留在 ${fallback}）`)
  }
  return verdict
}

/** 渠道不可用 / 场景不存在时统一写成 blocked：必须带原因与下一步，否则证据包不合法。 */
function blockedVerdict({ base, reason, nextStep, argv, note = '未执行任何命令，真实数据自然未动' }) {
  return {
    ...base,
    status: 'blocked',
    blockedReason: reason,
    nextStep,
    commands: [{ argv, exitCode: 2, note: '未执行' }],
    isolation: { dshHome: '(未起环境)', realHomeUntouched: true, proof: `未起隔离环境（${note}），因此真实数据未被动过` },
    finishedAt: new Date().toISOString(),
  }
}

function safeDoctor(lane, env) {
  try {
    return lane.doctor({ env })
  } catch (error) {
    return { available: false, blockedReason: `doctor 抛错：${error.message}`, nextStep: '先修 doctor' }
  }
}

function parseArgs(argv) {
  const args = { _: [], flags: {} }
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (!token.startsWith('--')) {
      args._.push(token)
      continue
    }
    const key = token.slice(2)
    const next = argv[index + 1]
    if (next === undefined || next.startsWith('--')) args.flags[key] = true
    else {
      args.flags[key] = next
      index += 1
    }
  }
  return args
}

async function main(argv = process.argv.slice(2)) {
  const { _, flags } = parseArgs(argv)
  const registry = createRegistry()
  const command = _[0] ?? 'doctor'

  if (command === 'doctor' || _[0] === undefined) {
    const report = runDoctor(registry)
    process.stdout.write(flags.json ? `${JSON.stringify(report, null, 2)}\n` : `${formatDoctor(report)}\n`)
    return report.ok ? 0 : 1
  }

  if (!['l1', 'l2'].includes(command)) {
    process.stderr.write(`用法：lane.mjs doctor | <l1|l2> [doctor|run --scenario <name>] [--json]\n`)
    return 2
  }

  const action = _[1] ?? 'doctor'
  if (action === 'doctor') {
    const report = runDoctor({ [command]: registry[command] })
    process.stdout.write(flags.json ? `${JSON.stringify(report, null, 2)}\n` : `${formatDoctor(report)}\n`)
    return report.ok ? 0 : 1
  }
  if (action !== 'run') {
    process.stderr.write(`未知动作：${action}（只支持 doctor / run）\n`)
    return 2
  }
  const scenario = typeof flags.scenario === 'string' ? flags.scenario : 'smoke'
  const verdict = await runScenario({
    registry,
    laneId: command,
    scenario,
    force: flags.force === true,
    log: flags.json ? () => {} : (line) => process.stderr.write(`${line}\n`),
  })
  if (flags.json) process.stdout.write(`${JSON.stringify(verdict, null, 2)}\n`)
  else process.stderr.write(`lane ${command} ${scenario}: ${verdict.status}${verdict.notes ? ` — ${verdict.notes}` : ''}\n`)
  return verdict.status === 'pass' ? 0 : 1
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().then((code) => process.exit(code), (error) => {
    process.stderr.write(`${error.stack ?? error}\n`)
    process.exit(2)
  })
}

export { main }

/**
 * L3 macOS 客体 VM 渠道（脚手架）。
 *
 * 渠道本体（Tart 创建/启动/执行/销毁、guest 内跑"从零启用"）在 T022–T024 落地；
 * 现在只提供自检与"不可用"的如实报告。
 *
 * 选型见 `specs/006-verify-lanes/research.md` 决策 4：Tart（CLI 优先、可脚本化），
 * 备选 VirtualBuddy（GUI，只能手工走查）。
 */

import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const lane = {
  id: 'l3',
  title: '干净环境（手动清单）',
  optional: true,
  isolation: '干净环境：macOS 客体 VM / 真实干净机器 / 干净 CI runner；当前无自动场景，不计入必跑',
  requiresCopyIn: false,
  doctor: doctorL3,
  scenarios: {},
}

/** 自检：Tart 在不在、有没有可用的 guest 模板。 */
export function doctorL3({ env = process.env } = {}) {
  const checks = []
  const tart = whichBinary('tart')
  checks.push({
    name: 'tart 在（本机 VM 路线的前提）',
    ok: Boolean(tart),
    detail: tart ?? 'PATH 上找不到 tart',
    // L3 不要求本机装虚拟机：真实干净机器 / 干净 CI runner 都算，见 README
    fix: tart ? undefined : '要本机起 VM：brew install cirruslabs/cli/tart；否则在那台干净机器上装本仓库后直接 `npm run lane:l3 -- run --scenario <name>`',
  })
  const images = tart ? run(tart, ['list']) : undefined
  const templates = (images?.stdout ?? '').split('\n').map((line) => line.trim()).filter(Boolean)
  checks.push({
    name: '至少一个 macOS guest 模板',
    ok: templates.length > 0,
    detail: templates[0] ?? 'tart list 为空',
    fix: '准备一个干净环境：本机 `tart clone` 一份 guest 模板，或用真实干净机器 / 干净 CI runner',
  })
  const homedirOk = existsSync(join(env.HOME || homedir(), 'Library'))
  checks.push({
    name: '宿主 macOS 环境可读（用于比对"真实数据未动"）',
    ok: homedirOk,
    detail: env.HOME || homedir(),
    fix: homedirOk ? undefined : 'HOME 不可读，先修环境',
  })
  const failed = checks.filter((check) => !check.ok)
  return {
    available: failed.length === 0,
    checks,
    blockedReason: failed.length > 0 ? failed.map((check) => check.name).join('、') : undefined,
    nextStep: failed.length > 0 ? failed.map((check) => check.fix).filter(Boolean).join('；') : undefined,
  }
}

function run(command, args) {
  return spawnSync(command, args, { encoding: 'utf8', timeout: 20_000 })
}

function whichBinary(name) {
  const result = spawnSync('which', [name], { encoding: 'utf8' })
  return result.status === 0 ? result.stdout.trim() : undefined
}

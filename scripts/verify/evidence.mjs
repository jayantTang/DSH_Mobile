/**
 * 三级验证渠道的证据包（`.lanes/runs/<lane>/<run-id>/verdict.json`）。
 *
 * 判定只有四态，与 `test/RULES.md` 一致：pass / fail / blocked / not-run。
 * `blocked`（渠道不可用）与 `fail`（结论为否）必须分开——把"跑不起来"写成"失败"
 * 或反之，都会让人做出错误决定。
 *
 * 契约见 `specs/006-verify-lanes/contracts/verdict.schema.json`。
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

export const STATUSES = ['pass', 'fail', 'blocked', 'not-run']
export const LANE_IDS = ['l1', 'l2']

/** `20261008T101500Z-plugin-install-hot`。目录名与 runId 相同，便于互指。 */
export function runId(date = new Date(), slug = 'run') {
  const stamp = date.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z')
  return `${stamp}-${String(slug).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-|-$/g, '') || 'run'}`
}

/**
 * 校验一份证据包；返回问题列表（空数组 = 合法）。
 * @param {unknown} verdict
 * @param {string} [prefix] 报错前缀，便于在批量校验里定位
 */
export function validateVerdict(verdict, prefix = 'verdict') {
  const issues = []
  if (verdict === null || typeof verdict !== 'object') return [`${prefix}: 不是对象`]
  const v = /** @type {Record<string, any>} */ (verdict)
  if (!LANE_IDS.includes(v.lane)) issues.push(`${prefix}: lane 必须是 l1/l2`)
  if (typeof v.runId !== 'string' || !/^\d{8}T\d{6}Z-[a-z0-9-]+$/.test(v.runId)) {
    issues.push(`${prefix}: runId 形状应为 YYYYMMDDThhmmssZ-<slug>`)
  }
  if (typeof v.scenario !== 'string' || v.scenario.length < 3) issues.push(`${prefix}: 缺 scenario`)
  if (!STATUSES.includes(v.status)) issues.push(`${prefix}: status 必须是 ${STATUSES.join('/')}`)
  if (!Array.isArray(v.commands) || v.commands.length === 0) issues.push(`${prefix}: commands 不得为空`)
  const isolation = v.isolation
  if (isolation === null || typeof isolation !== 'object') {
    issues.push(`${prefix}: 缺 isolation`)
  } else {
    if (typeof isolation.dshHome !== 'string' || !isolation.dshHome) issues.push(`${prefix}: isolation.dshHome 必填`)
    if (typeof isolation.realHomeUntouched !== 'boolean') issues.push(`${prefix}: isolation.realHomeUntouched 必填`)
    if (isolation.realHomeUntouched === true && !isolation.proof) {
      issues.push(`${prefix}: realHomeUntouched=true 时必须给 proof（怎么证明的）`)
    }
  }
  if (v.status === 'blocked' && (!v.blockedReason || !v.nextStep)) {
    issues.push(`${prefix}: blocked 必须带 blockedReason 与 nextStep`)
  }
  return issues
}

/**
 * 写一份证据包。
 * @param {{root: string, verdict: Record<string, any>}} input
 * @returns {string} verdict.json 的绝对路径
 */
export function writeEvidence({ root, verdict }) {
  const issues = validateVerdict(verdict)
  if (issues.length > 0) throw new Error(`evidence: 证据包不合法\n  ${issues.join('\n  ')}`)
  const dir = join(root, verdict.lane, verdict.runId)
  mkdirSync(dir, { recursive: true })
  const file = join(dir, 'verdict.json')
  writeFileSync(file, `${JSON.stringify(verdict, null, 2)}\n`)
  return file
}

/** 读回所有证据包（`.lanes/runs/**\/verdict.json`），非法包不抛错、只在返回里带 issues。 */
export function readEvidence(root) {
  const found = []
  if (!existsSync(root)) return found
  for (const lane of readdirSync(root)) {
    const laneDir = join(root, lane)
    for (const run of safeReaddir(laneDir)) {
      const file = join(laneDir, run, 'verdict.json')
      if (!existsSync(file)) continue
      let verdict
      try {
        verdict = JSON.parse(readFileSync(file, 'utf8'))
      } catch (error) {
        found.push({ path: file, verdict: undefined, issues: [`JSON 解析失败：${error.message}`] })
        continue
      }
      found.push({ path: file, verdict, issues: validateVerdict(verdict, file) })
    }
  }
  return found
}

function safeReaddir(dir) {
  try {
    return readdirSync(dir)
  } catch {
    return []
  }
}

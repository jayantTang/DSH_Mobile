/**
 * 矩阵：隔离强度（l1/l2/l3）× 被测对象，单一来源 `scripts/verify/lanes.json`。
 *
 * 拦截脚本与渠道入口都从这里读判定口径——不允许在别处再写一份
 * （宪法 VI：同一类逻辑只允许一份实现）。改动文件 → 被测对象 → 必跑渠道，
 * 三步都在这个模块里，谁要改判定就改矩阵。
 */

import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
export const MATRIX_PATH = join(REPO_ROOT, 'scripts', 'verify', 'lanes.json')
export const LANE_IDS = ['l1', 'l2', 'l3']
export const VALUES = ['required', 'usable', 'limited', 'not-applicable']

/** 读矩阵；文件缺失或不是 JSON 时抛错（工具自身错误，对应退出码 2）。 */
export function loadMatrix(path = MATRIX_PATH) {
  return JSON.parse(readFileSync(path, 'utf8'))
}

/**
 * 校验矩阵；返回问题列表。空数组 = 合法。
 * 校验的是"结构上自相矛盾"的部分：缺格、重复、枚举越界、理由缺失。
 */
export function validateMatrix(matrix) {
  if (matrix === null || typeof matrix !== 'object') return ['matrix: 不是对象']
  const issues = []
  if (!Number.isInteger(matrix.version) || matrix.version < 1) issues.push('matrix: version 必须是正整数')
  issues.push(...validateLanes(matrix.lanes ?? {}))
  const subjects = validateSubjects(matrix.subjects)
  issues.push(...subjects.issues)
  const entries = Array.isArray(matrix.matrix) ? matrix.matrix : []
  issues.push(...validateEntries(entries, subjects.ids))
  for (const subject of subjects.ids) {
    for (const lane of LANE_IDS) {
      if (!entries.some((entry) => entry?.subject === subject && entry?.lane === lane)) {
        issues.push(`matrix ${subject}×${lane}: 缺格（每个对象必须三级各一条）`)
      }
    }
  }
  return issues
}

function validateLanes(lanes) {
  const issues = []
  for (const id of LANE_IDS) {
    const lane = lanes[id]
    if (lane === undefined) {
      issues.push(`lane ${id}: 缺失`)
      continue
    }
    for (const field of ['title', 'entry', 'isolation']) {
      if (typeof lane[field] !== 'string' || lane[field].length === 0) issues.push(`lane ${id}: 缺 ${field}`)
    }
    for (const field of ['canVerify', 'cannotVerify']) {
      if (!Array.isArray(lane[field]) || lane[field].length === 0) issues.push(`lane ${id}: ${field} 至少要一条`)
    }
  }
  for (const id of Object.keys(lanes)) {
    if (!LANE_IDS.includes(id)) issues.push(`lane ${id}: 不在 l1/l2/l3 之内`)
  }
  return issues
}

function validateSubjects(subjects) {
  const issues = []
  const ids = new Set()
  if (!Array.isArray(subjects) || subjects.length === 0) {
    issues.push('subjects: 不得为空')
    return { issues, ids }
  }
  for (const subject of subjects) {
    if (!subject?.id) {
      issues.push('subject: 缺 id')
      continue
    }
    if (ids.has(subject.id)) issues.push(`subject ${subject.id}: 重复`)
    ids.add(subject.id)
    if (!subject.title) issues.push(`subject ${subject.id}: 缺 title`)
    if (!Array.isArray(subject.globs) || subject.globs.length === 0) {
      issues.push(`subject ${subject.id}: globs 至少要一条，否则这一行永远不会被触发`)
    }
  }
  return { issues, ids }
}

function validateEntries(entries, ids) {
  const issues = []
  const seen = new Set()
  for (const entry of entries) {
    const key = `${entry?.subject}×${entry?.lane}`
    if (!ids.has(entry?.subject)) issues.push(`matrix ${key}: subject 不存在`)
    if (!LANE_IDS.includes(entry?.lane)) issues.push(`matrix ${key}: lane 不在 l1/l2/l3 之内`)
    if (seen.has(key)) issues.push(`matrix ${key}: 重复`)
    seen.add(key)
    if (!VALUES.includes(entry?.value)) issues.push(`matrix ${key}: value 必须是 ${VALUES.join('/')}`)
    if (typeof entry?.reason !== 'string' || entry.reason.trim().length < 8) {
      issues.push(`matrix ${key}: reason 太短——取值必须附理由（不用理由的格子等于没判定）`)
    }
    // 必跑格可以声明"只认哪些场景"的证据；声明了就必须是非空字符串数组，
    // 否则一旦写错会让 check:lanes 退回"同渠道任意场景都算"，等于安静地关掉绑定。
    if (entry?.scenarios !== undefined) {
      if (!Array.isArray(entry.scenarios) || entry.scenarios.length === 0
        || entry.scenarios.some((name) => typeof name !== 'string' || name.trim().length === 0)) {
        issues.push(`matrix ${key}: scenarios 必须是非空字符串数组`)
      }
    }
  }
  return issues
}

/** 改动文件 → 被测对象 id（多命中取并集：宁可多跑一级）。 */
export function matchSubjects(matrix, files) {
  const matched = new Set()
  for (const subject of matrix.subjects ?? []) {
    const patterns = (subject.globs ?? []).map(globToRegExp)
    if (files.some((file) => patterns.some((pattern) => pattern.test(normalize(file))))) matched.add(subject.id)
  }
  return [...matched]
}

/**
 * 改动文件 → 必跑渠道集合。
 * @returns {{subjects: string[], required: string[], reasons: Record<string,string>,
 *            scenarios: Record<string,string[]>, entries: object[]}}
 */
export function requiredLanes(matrix, files) {
  const subjects = matchSubjects(matrix, files)
  const required = new Set()
  const reasons = {}
  const entries = []
  const scenarios = {}
  const unbound = new Set()
  for (const entry of matrix.matrix ?? []) {
    if (!subjects.includes(entry.subject) || entry.value !== 'required') continue
    entries.push(entry)
    required.add(entry.lane)
    reasons[entry.lane] = `${entry.subject} × ${entry.lane} = required（${entry.reason}）`
    if (Array.isArray(entry.scenarios) && entry.scenarios.length > 0) {
      scenarios[entry.lane] = [...new Set([...(scenarios[entry.lane] ?? []), ...entry.scenarios])]
    } else {
      // 同一渠道下只要有一个必跑格没声明场景，就不能拿它去过滤别的格：
      // 保守退回"任意场景"。
      unbound.add(entry.lane)
    }
  }
  for (const lane of unbound) delete scenarios[lane]
  return {
    subjects,
    required: LANE_IDS.filter((id) => required.has(id)),
    reasons,
    scenarios,
    entries,
  }
}

/**
 * 入口漂移守卫：矩阵里写的 `npm run <name>` 必须真的存在于 package.json。
 * 只在一边改名（矩阵或脚本）时判红——这是"两处口径漂移"的最常见形态。
 */
export function validateLaneEntries(matrix, scripts = {}) {
  const issues = []
  for (const [id, lane] of Object.entries(matrix.lanes ?? {})) {
    const entry = String(lane?.entry ?? '')
    const match = /^npm run ([a-z0-9:_-]+)$/i.exec(entry)
    if (match === null) {
      issues.push(`lane ${id}: entry「${entry}」不是 \`npm run <script>\` 形式`)
      continue
    }
    if (!(match[1] in scripts)) issues.push(`lane ${id}: package.json 里没有脚本 ${match[1]}`)
  }
  return issues
}

/** glob → RegExp：支持 `**`（跨目录）、`*`（段内）、`?`。 */
export function globToRegExp(pattern) {
  let out = '^'
  for (let index = 0; index < pattern.length; index += 1) {
    const char = pattern[index]
    if (char === '*') {
      if (pattern[index + 1] === '*') {
        index += 1
        // 末尾的 `**` 要能匹配任意深度的文件（`plugins/**` → `plugins/.*`）；
        // 后面还有段时用 `(?:.*/)?`，这样 `docs/**/*.md` 也匹配 `docs/a.md`。
        if (pattern[index + 1] === '/') {
          index += 1
          out += '(?:.*/)?'
        } else {
          out += '.*'
        }
        continue
      }
      out += '[^/]*'
      continue
    }
    if (char === '?') {
      out += '[^/]'
      continue
    }
    out += /[.+^${}()|[\]\\]/.test(char) ? `\\${char}` : char
  }
  return new RegExp(`${out}$`)
}

function normalize(file) {
  return String(file).replace(/^\.\//, '').replace(/\\/g, '/')
}

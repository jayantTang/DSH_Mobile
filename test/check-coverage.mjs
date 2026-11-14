#!/usr/bin/env node
// 校验 test/requirements-coverage.md 与 IR-08 需求、证据路径的一致性。

import { existsSync, readFileSync } from 'node:fs'

const requirements = readFileSync('handbook/requirements/requirements.md', 'utf8')
const coverage = readFileSync('test/requirements-coverage.md', 'utf8')
const start = requirements.indexOf('- **IR-08')
if (start < 0) {
  console.error('找不到 IR-08')
  process.exit(2)
}
const rest = requirements.slice(start + 1)
const next = rest.search(/\n- \*\*IR-\d{2}/)
const block = next >= 0 ? rest.slice(0, next) : rest
const expected = [...block.matchAll(/^  - \*\*(SR-\d{2}\.\d{2})\b/gm)].map((m) => m[1])
const rows = new Map()
for (const line of coverage.split('\n')) {
  const match = line.match(/^\|\s*(SR-\d{2}\.\d{2})\b[^|]*\|\s*(covered|partial|gap)\s*\|([^|]*)\|/)
  if (!match) continue
  const paths = [...match[3].matchAll(/`([^`]+)`/g)].map((m) => m[1])
  rows.set(match[1], { status: match[2], paths })
}

const problems = []
for (const id of expected) {
  const row = rows.get(id)
  if (!row) problems.push(`${id} 未在覆盖矩阵登记`)
  else {
    if (!row.paths.length) problems.push(`${id} 没有证据路径`)
    for (const path of row.paths) {
      if (!existsSync(path)) problems.push(`${id} 证据路径不存在：${path}`)
    }
  }
}
for (const id of rows.keys()) {
  if (!expected.includes(id)) problems.push(`矩阵登记了不存在的 SR：${id}`)
}

if (problems.length) {
  console.error('需求覆盖矩阵未通过：')
  for (const problem of problems) console.error(`  - ${problem}`)
  process.exit(1)
}
const partial = [...rows.values()].filter((row) => row.status === 'partial').length
const gaps = [...rows.values()].filter((row) => row.status === 'gap').length
console.log(`ok  ${expected.length} 条 SR 已登记；partial ${partial}，gap ${gaps}`)

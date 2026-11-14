#!/usr/bin/env node
// Generate the suite-level coverage table for every SR. Detailed per-test
// evidence for IR-08 lives in requirements-coverage.md; this file answers
// "does every requirement have at least one owning suite?".

import { readFileSync, writeFileSync } from 'node:fs'

const requirements = readFileSync('handbook/requirements/requirements.md', 'utf8')
const srs = [...requirements.matchAll(/^  - \*\*(SR-\d{2}\.\d{2})\b/gm)].map((m) => m[1])
const suites = JSON.parse(readFileSync('test/suites.json', 'utf8')).suites
const wildcard = (pattern) => new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replaceAll('*', '[^/]*')}$`)

const rows = srs.map((sr) => {
  const owners = suites.filter((suite) => (suite.requirements ?? []).some((pattern) => wildcard(pattern).test(sr)))
  const functional = owners.filter((suite) => suite.id !== 'requirements')
  return { sr, owners, weak: functional.length === 0 }
})
const gaps = rows.filter((row) => row.owners.length === 0)
const weak = rows.filter((row) => row.weak)
const lines = [
  '# 全量需求覆盖（套件级）',
  '',
  '> 本文由 `node test/generate-coverage-all.mjs` 生成。它是套件级映射，证明每条 SR 至少有一个负责套件；`IR-08` 的逐测试证据见 `requirements-coverage.md`。',
  '',
  '| SR | 状态 | 覆盖套件 |',
  '|---|---|---|',
  ...rows.map((row) => `| ${row.sr} | ${row.weak ? 'weak' : 'ok'} | ${row.owners.map((suite) => `\`${suite.id}\``).join('、') || '**未覆盖**'} |`),
  '',
  `共 ${rows.length} 条 SR；无套件覆盖 ${gaps.length} 条；只有需求自审、没有功能套件 ${weak.length} 条。`,
  '',
]
writeFileSync('test/requirements-coverage-all.md', lines.join('\n'))
console.log(`wrote ${rows.length} SR, gaps ${gaps.length}`)
if (gaps.length) {
  console.error(gaps.map((row) => row.sr).join(', '))
  process.exit(1)
}

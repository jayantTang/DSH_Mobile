#!/usr/bin/env node
// Programmatic coverage dashboard: every SR gets one of four evidence states.
//   verified   exact test file exists AND contains the named assertion marker
//   partial    exact evidence declared, but a file/marker is missing
//   suite-only only a suite claims the requirement; no exact test assertion
//   gap        neither exact evidence nor a suite
//
// Usage: node test/check-test-coverage.mjs [--check]
// Default writes test/TEST-COVERAGE.md. --check fails if the generated file drifts.

import { existsSync, readFileSync, writeFileSync } from 'node:fs'

const CHECK = process.argv.includes('--check')
const STRICT = process.argv.includes('--strict')
const requirements = readFileSync('handbook/requirements/requirements.md', 'utf8')
const srs = [...requirements.matchAll(/^  - \*\*(SR-\d{2}\.\d{2})\b/gm)].map((m) => m[1])
const suites = JSON.parse(readFileSync('test/suites.json', 'utf8')).suites
const evidence = JSON.parse(readFileSync('test/coverage-evidence.json', 'utf8'))
const wildcard = (pattern) => new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replaceAll('*', '[^/]*')}$`)

const rows = srs.map((sr) => {
  const declared = evidence[sr] ?? []
  const missing = []
  for (const item of declared) {
    if (!existsSync(item.path) || !readFileSync(item.path, 'utf8').includes(item.contains)) {
      missing.push(`${item.path} 缺少 ${item.contains}`)
    }
  }
  const owners = suites.filter((suite) => (suite.requirements ?? []).some((pattern) => wildcard(pattern).test(sr)))
  const state = declared.length === 0
    ? (owners.length ? 'suite-only' : 'gap')
    : (missing.length ? 'partial' : 'verified')
  return { sr, state, declared, missing, owners }
})

const counts = rows.reduce((acc, row) => ({ ...acc, [row.state]: (acc[row.state] ?? 0) + 1 }), {})
const icon = { verified: '✅', partial: '🟡', 'suite-only': '🟠', gap: '❌' }
const evidenceText = (row) => row.declared.map((item) => `\`${item.path}\`：\`${item.contains}\``).join('<br>') || '—'
const suiteText = (row) => row.owners.map((suite) => `\`${suite.id}\``).join('、') || '—'
const gapText = (row) => row.state === 'verified' ? '' : row.state === 'partial' ? row.missing.join('；') : row.state === 'suite-only' ? '只有套件级映射，未逐测试' : '无套件、无测试证据'

const lines = [
  '# 全量需求测试覆盖',
  '',
  '> 由 `node test/check-test-coverage.mjs` 生成。只有 ✅ 代表精确测试文件与断言标记都存在；🟠 只是套件级映射，不得当作已完成。',
  '',
  `汇总：共 ${rows.length} 条 · ✅ verified ${counts.verified ?? 0} · 🟡 partial ${counts.partial ?? 0} · 🟠 suite-only ${counts['suite-only'] ?? 0} · ❌ gap ${counts.gap ?? 0}`,
  '',
  '| SR | 状态 | 精确测试证据 | 负责套件 | 缺口 |',
  '|---|---|---|---|---|',
  ...rows.map((row) => `| ${row.sr} | ${icon[row.state]} ${row.state} | ${evidenceText(row)} | ${suiteText(row)} | ${gapText(row)} |`),
  '',
]
const generated = lines.join('\n')
if (CHECK) {
  const current = existsSync('test/TEST-COVERAGE.md') ? readFileSync('test/TEST-COVERAGE.md', 'utf8') : ''
  if (current !== generated) {
    console.error('test/TEST-COVERAGE.md 与生成结果不一致；重跑 node test/check-test-coverage.mjs')
    process.exit(1)
  }
  if (STRICT && (counts.verified ?? 0) !== rows.length) {
    console.error(`strict: ${rows.length - (counts.verified ?? 0)} 条 SR 还没有逐测试证据`)
    process.exit(1)
  }
  console.log(`ok   ${rows.length} 条 SR；${counts.verified ?? 0} verified，其余 ${rows.length - (counts.verified ?? 0)} 未逐测试`)
  process.exit(0)
}
writeFileSync('test/TEST-COVERAGE.md', generated)
console.log(`wrote test/TEST-COVERAGE.md: ${rows.length} SR; verified ${counts.verified ?? 0}, partial ${counts.partial ?? 0}, suite-only ${counts['suite-only'] ?? 0}, gap ${counts.gap ?? 0}`)

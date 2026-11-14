#!/usr/bin/env node
// Programmatic coverage dashboard: every SR gets one of four evidence states.
//   verified   exact test file exists AND contains the named assertion marker
//   partial    exact evidence declared, but a file/marker is missing
//   suite-only only a suite claims the requirement; no exact test assertion
//   gap        neither exact evidence nor a suite
//
// Usage: node test/coverage/check-test-coverage.mjs [--check]
// Default writes test/coverage/TEST-COVERAGE.md. --check fails if the generated file drifts.

import { existsSync, readFileSync, writeFileSync } from 'node:fs'

const CHECK = process.argv.includes('--check')
const STRICT = process.argv.includes('--strict')
const requirements = readFileSync('handbook/requirements/requirements.md', 'utf8')
const srs = [...requirements.matchAll(/^  - \*\*(SR-\d{2}\.\d{2})\b/gm)].map((m) => m[1])
const suites = JSON.parse(readFileSync('test/suites.json', 'utf8')).suites
const evidence = JSON.parse(readFileSync('test/coverage/coverage-evidence.json', 'utf8'))
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
  let state
  if (declared.length === 0) state = owners.length ? 'suite-only' : 'gap'
  else if (missing.length) state = 'partial'
  else if (declared.some((item) => item.kind === 'manual')) state = 'manual'
  else if (declared.some((item) => item.kind === 'static')) state = 'static'
  else state = 'verified'
  return { sr, state, declared, missing, owners }
})

const counts = rows.reduce((acc, row) => ({ ...acc, [row.state]: (acc[row.state] ?? 0) + 1 }), {})
const icon = { verified: '✅', static: '🔵', manual: '✍️', partial: '🟡', 'suite-only': '🟠', gap: '❌' }
const evidenceText = (row) => row.declared.map((item) => `\`${item.path}\`：\`${item.contains}\``).join('<br>') || '—'
const suiteText = (row) => row.owners.map((suite) => `\`${suite.id}\``).join('、') || '—'
const gapText = (row) => row.state === 'verified' ? '' : row.state === 'static' ? '静态策略检查' : row.state === 'manual' ? '人工验收待填写' : row.state === 'partial' ? row.missing.join('；') : row.state === 'suite-only' ? '只有套件级映射，未逐测试' : '无套件、无测试证据'

const lines = [
  '# 全量需求测试覆盖',
  '',
  '> 由 `node test/coverage/check-test-coverage.mjs` 生成。✅ 精确测试；🔵 静态策略；✍️ 人工待验收；🟠 只是套件级映射，不得当作已完成。',
  '',
  `汇总：共 ${rows.length} 条 · ✅ verified ${counts.verified ?? 0} · 🔵 static ${counts.static ?? 0} · ✍️ manual ${counts.manual ?? 0} · 🟡 partial ${counts.partial ?? 0} · 🟠 suite-only ${counts['suite-only'] ?? 0} · ❌ gap ${counts.gap ?? 0}`,
  '',
  '| SR | 状态 | 精确测试证据 | 负责套件 | 缺口 |',
  '|---|---|---|---|---|',
  ...rows.map((row) => `| ${row.sr} | ${icon[row.state]} ${row.state} | ${evidenceText(row)} | ${suiteText(row)} | ${gapText(row)} |`),
  '',
]
const generated = lines.join('\n')
if (CHECK) {
  const current = existsSync('test/coverage/TEST-COVERAGE.md') ? readFileSync('test/coverage/TEST-COVERAGE.md', 'utf8') : ''
  if (current !== generated) {
    console.error('test/coverage/TEST-COVERAGE.md 与生成结果不一致；重跑 node test/coverage/check-test-coverage.mjs')
    process.exit(1)
  }
  const automatic = (counts.verified ?? 0) + (counts.static ?? 0)
  if (STRICT && automatic !== rows.length) {
    console.error(`strict: ${rows.length - automatic} 条 SR 还没有自动测试证据`)
    process.exit(1)
  }
  console.log(`ok   ${rows.length} 条 SR；${counts.verified ?? 0} verified + ${counts.static ?? 0} static，其余 ${rows.length - automatic} 未自动验证`)
  process.exit(0)
}
writeFileSync('test/coverage/TEST-COVERAGE.md', generated)
console.log(`wrote test/coverage/TEST-COVERAGE.md: ${rows.length} SR; verified ${counts.verified ?? 0}, partial ${counts.partial ?? 0}, suite-only ${counts['suite-only'] ?? 0}, gap ${counts.gap ?? 0}`)

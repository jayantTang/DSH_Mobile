#!/usr/bin/env node
// 需求关键层变更的“自审 + 变更清单”。
//
// 这是 agent 在向 owner 汇报前必须跑的入口：先自审，冲突自己修；只有自审通过后，
// 才把变更清单交给 owner，owner 只决定是否保存。
//
// 跑法：npm run review:requirements

import { execFileSync, spawnSync } from 'node:child_process'

const ROOT = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
process.chdir(ROOT)
const git = (list, options = {}) => execFileSync('git', list, { cwd: ROOT, ...options })

console.log('[review] 自审需求结构与细节冲突')
const check = spawnSync(process.execPath, ['scripts/dev/check-requirements.mjs'], { stdio: 'inherit' })
if (check.status !== 0) {
  console.error('\n[review] 自审未通过。先修冲突，不要把这份变更交给 owner。')
  process.exit(check.status ?? 1)
}

const stat = git(['diff', 'HEAD', '--stat', '--', 'handbook/requirements'], { encoding: 'utf8' }).trim()
console.log('\n[review] 需求关键层变更：')
console.log(stat || '  无改动')

const diff = git(['diff', 'HEAD', '-U0', '--', 'handbook/requirements/requirements.md'], { encoding: 'utf8' })
const added = []
const removed = []
for (const line of diff.split('\n')) {
  const match = line.match(/^([+-])\s+- \*\*((?:IR|SR|AR)-[0-9.]+)\s+(.+?)\*\*/)
  if (!match) continue
  const target = match[1] === '+' ? added : removed
  target.push(`${match[2]} ${match[3]}`)
}

if (added.length) {
  console.log('\n新增：')
  for (const item of added) console.log(`  + ${item}`)
}
if (removed.length) {
  console.log('\n删除：')
  for (const item of removed) console.log(`  - ${item}`)
}

console.log('\n[review] 自审通过。把以上变更清单交给 owner；得到 owner 明确同意后，再运行：')
console.log('  npm run approve:requirements -- --owner-approved "<owner 的原话>"')
console.log('  git commit')

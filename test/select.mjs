#!/usr/bin/env node
// 测试套件选择器：清单在 test/suites.json，执行入口在 test/run.sh 与各套件命令。
//
//   node test/select.mjs                        列出全部套件
//   node test/select.mjs --req SR-03.06         按需求选
//   node test/select.mjs --affected <文件...>   按改动文件选
//   node test/select.mjs --affected --run      选中后执行
//   node test/select.mjs --json                 输出机器可读结果

import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const MANIFEST = resolve(ROOT, 'test/suites.json')
const args = process.argv.slice(2)
const flags = new Set(args.filter((arg) => arg.startsWith('--')))
const values = args.filter((arg) => !arg.startsWith('--'))
const json = flags.has('--json')
const run = flags.has('--run')
const affected = flags.has('--affected')
const reqIndex = args.indexOf('--req')
const req = reqIndex >= 0 ? args[reqIndex + 1] : null
const explicitFiles = values.filter((arg) => arg !== req && !arg.startsWith('--'))

const suites = JSON.parse(readFileSync(MANIFEST, 'utf8')).suites ?? []

function escapeRegex(value) {
  return value.replace(/[.+?^${}()|[\]\\]/g, '\\$&')
}

/// 只支持 `**`、`*`、`?`，足够表达 suite 的 paths/requirements，不引入 glob 依赖。
function wildcard(value) {
  let pattern = escapeRegex(value)
  pattern = pattern.replaceAll('**', '§ALL§')
  pattern = pattern.replaceAll('*', '[^/]*').replaceAll('§ALL§', '.*')
  pattern = pattern.replaceAll('?', '.')
  return new RegExp(`^${pattern}$`)
}

function matchesPath(path, patterns) {
  return patterns.some((pattern) => wildcard(pattern).test(path))
}

function matchesRequirement(requirement, patterns) {
  return patterns.some((pattern) => wildcard(pattern).test(requirement))
}

function changedFiles() {
  const staged = execFileSync('git', ['diff', '--name-only', 'HEAD'], { cwd: ROOT, encoding: 'utf8' })
  const untracked = execFileSync('git', ['ls-files', '--others', '--exclude-standard'], { cwd: ROOT, encoding: 'utf8' })
  return [...new Set(`${staged}\n${untracked}`.split('\n').filter(Boolean))]
}

let selected = suites
if (req) {
  selected = suites.filter((suite) => matchesRequirement(req, suite.requirements ?? []))
} else if (affected) {
  const files = explicitFiles.length ? explicitFiles : changedFiles()
  if (!files.length) {
    console.log('没有改动文件；不猜套件。')
    process.exit(0)
  }
  selected = suites.filter((suite) => files.some((file) => matchesPath(file, suite.paths ?? [])))
  if (!selected.length) {
    console.error(`没有套件匹配这些改动：${files.join(', ')}`)
    process.exit(2)
  }
}

if (!selected.length) {
  console.error(req ? `没有套件覆盖需求 ${req}` : '没有匹配的套件')
  process.exit(1)
}

if (json) {
  console.log(JSON.stringify(selected, null, 2))
  process.exit(0)
}

for (const suite of selected) {
  const where = suite.cwd ? ` (${suite.cwd})` : ''
  console.log(`${suite.id}\t${suite.layer}\t${suite.budget ?? '?'}s\t${suite.title}${where}`)
  console.log(`  ${suite.command.join(' ')}`)
}

if (!run) process.exit(0)

let failed = 0
for (const suite of selected) {
  const cwd = suite.cwd ? resolve(ROOT, suite.cwd) : ROOT
  console.log(`\n[run] ${suite.id}: ${suite.command.join(' ')}`)
  const result = spawnSync(suite.command[0], suite.command.slice(1), {
    cwd,
    stdio: 'inherit',
    timeout: (suite.budget ?? 600) * 1000,
    env: { ...process.env },
  })
  if (result.error || result.status !== 0) {
    console.error(`[fail] ${suite.id}${result.error ? `: ${result.error.message}` : `: exit ${result.status}`}`)
    failed += 1
  } else {
    console.log(`[ok  ] ${suite.id}`)
  }
}
process.exit(failed ? 1 : 0)

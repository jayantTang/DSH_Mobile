#!/usr/bin/env node
// 需求关键层审批台账。
//
// 审批的对象是 git 暂存区里的文件内容 hash，不是工作区文件。
// 用法：
//   npm run requirements:status
//   npm run approve:requirements -- --owner-approved "<owner 的原话>"
//
// pre-commit 会调用 check-requirements.mjs --staged 校验同一批 hash；
// 任何需求文件改动后未重新审批，hash 不匹配即拒绝提交。

import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, appendFileSync, readFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

const ROOT = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
process.chdir(ROOT)
const KEY_PREFIX = 'handbook/requirements/'
const LEDGER = 'handbook/history/approvals.jsonl'
const args = process.argv.slice(2)
const command = args[0]
const ownerIndex = args.indexOf('--owner-approved')
const ownerStatement = ownerIndex >= 0 ? args[ownerIndex + 1] : ''

const git = (list, options = {}) => execFileSync('git', list, { cwd: ROOT, ...options })
const sha256 = (buffer) => createHash('sha256').update(buffer).digest('hex')

function stagedKeyFiles() {
  const output = git(['diff', '--cached', '--name-status', '--diff-filter=ACMRD'], { encoding: 'utf8' })
  return output
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      const [status, path] = line.split('\t')
      return { status, path }
    })
    .filter((entry) => entry.path.startsWith(KEY_PREFIX) && entry.path.endsWith('.md'))
}

function indexHash(path) {
  try {
    return sha256(git(['show', `:${path}`]))
  } catch {
    return 'DELETED'
  }
}

function readApprovals() {
  if (!existsSync(LEDGER)) return []
  return readFileSync(LEDGER, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line)
      } catch {
        return null
      }
    })
    .filter(Boolean)
}

function untrackedKeyFiles() {
  return git(['ls-files', '--others', '--exclude-standard'], { encoding: 'utf8' })
    .split('\n')
    .filter(Boolean)
    .filter((path) => path.startsWith(KEY_PREFIX) && path.endsWith('.md'))
}

if (command === 'status') {
  const files = stagedKeyFiles()
  if (!files.length) {
    console.log('暂存区没有需求关键文件改动。')
    process.exit(0)
  }
  const approvals = readApprovals()
  for (const { path } of files) {
    const hash = indexHash(path)
    const ok = approvals.some((entry) => entry.path === path && entry.sha256 === hash)
    console.log(`${ok ? '已批准' : '未批准'}  ${path}  ${hash.slice(0, 12)}…`)
  }
  process.exit(0)
}

if (command !== 'approve') {
  console.error('用法：requirements-approval.mjs status | approve --owner-approved "<owner 的原话>"')
  process.exit(2)
}

if (!ownerStatement.trim()) {
  console.error('拒绝审批：必须提供 --owner-approved "<owner 的原话>"。')
  process.exit(2)
}

const files = stagedKeyFiles()
if (!files.length) {
  console.error('暂存区没有需求关键文件改动。先修改并 git add，再审批。')
  process.exit(2)
}
const untracked = untrackedKeyFiles()
if (untracked.length) {
  console.error(`有未跟踪的需求文件，先 git add：${untracked.join(', ')}`)
  process.exit(2)
}

console.log('[approve] 先跑需求自审')
execFileSync(process.execPath, ['scripts/dev/check-requirements.mjs', '--staged', '--no-approval'], { stdio: 'inherit' })

mkdirSync(dirname(LEDGER), { recursive: true })
const at = new Date().toISOString()
for (const { path } of files) {
  const sha256Hash = indexHash(path)
  appendFileSync(LEDGER, `${JSON.stringify({ path, sha256: sha256Hash, owner_approved: ownerStatement, at })}\n`)
  console.log(`[approve] ${path}  ${sha256Hash.slice(0, 12)}…`)
}
console.log(`[approve] 已记录 ${files.length} 个文件；现在可以 git commit。`)

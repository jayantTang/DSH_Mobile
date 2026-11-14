#!/usr/bin/env node
// 需求关键层自审：结构、编号、追溯、细节文档冲突。
//
// 只做机械判定；语义是否真正冲突仍需 owner 阅读。跑法：
//   npm run check:requirements
//   node scripts/dev/check-requirements.mjs --staged
//
// --staged 额外要求：需求关键文件若有暂存改动，必须存在与暂存内容 hash 匹配的 owner 审批记录；
// 同时拒绝“工作区与暂存区不一致”的需求文件，避免审的是旧内容、提交的是新内容。

import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
process.chdir(ROOT)

const REQ_DIR = 'handbook/requirements'
const REQ_FILE = `${REQ_DIR}/requirements.md`
const PRODUCT_FILE = `${REQ_DIR}/product.md`
const DETAIL_DIR = `${REQ_DIR}/details`
const LEDGER = 'handbook/history/approvals.jsonl'
const KEY_PREFIX = `${REQ_DIR}/`
const args = new Set(process.argv.slice(2))
const staged = args.has('--staged')
const noApproval = args.has('--no-approval')
const problems = []

const sha256 = (buffer) => createHash('sha256').update(buffer).digest('hex')
const git = (list, options = {}) => execFileSync('git', list, { cwd: ROOT, ...options })

function readText(path) {
  if (!existsSync(path)) {
    problems.push(`缺少文件：${path}`)
    return ''
  }
  return readFileSync(path, 'utf8')
}

function parseRequirements(text) {
  const nodes = []
  let current = null
  for (const line of text.split('\n')) {
    const match = line.match(/^( *)- \*\*(IR|SR|AR)-(\d{2}(?:\.\d{2})*)\s+(.+?)\*\*\s*$/)
    if (match) {
      current = {
        id: `${match[2]}-${match[3]}`,
        type: match[2],
        indent: match[1].length,
        title: match[4].trim(),
        body: [],
      }
      nodes.push(current)
    } else if (current) {
      current.body.push(line)
    }
  }
  return nodes
}

function fieldsOf(node) {
  return new Set([...node.body.join('\n').matchAll(/\*\*(目标|成功度量|行为|约束|验收|模块|职责)\*\*/g)].map((m) => m[1]))
}

function checkRequirements(nodes) {
  const ids = new Set()
  const irs = new Set()
  let currentIR = null
  let currentSR = null
  const required = {
    IR: ['目标', '成功度量'],
    SR: ['行为', '验收'],
    AR: ['模块', '职责', '验收'],
  }

  for (const node of nodes) {
    if (ids.has(node.id)) problems.push(`重复编号：${node.id}`)
    ids.add(node.id)
    if (!node.title) problems.push(`缺少标题：${node.id}`)

    const expectedIndent = node.type === 'IR' ? 0 : node.type === 'SR' ? 2 : 4
    if (node.indent !== expectedIndent) {
      problems.push(`${node.id} 缩进应为 ${expectedIndent} 格，实际 ${node.indent} 格`)
    }

    const fields = fieldsOf(node)
    for (const field of required[node.type]) {
      if (!fields.has(field)) problems.push(`${node.id} 缺少「${field}」`)
    }

    if (node.type === 'IR') {
      const expected = `IR-${node.id.slice(3)}`
      if (node.id !== expected) problems.push(`IR 编号不合法：${node.id}`)
      currentIR = node.id
      currentSR = null
    } else if (node.type === 'SR') {
      if (!currentIR) problems.push(`${node.id} 不在任何 IR 下`)
      const expected = `SR-${currentIR?.slice(3)}.${node.id.split('.')[1]}`
      if (node.id !== expected) problems.push(`${node.id} 父级应为 ${currentIR}`)
      currentSR = node.id
    } else {
      if (!currentSR) problems.push(`${node.id} 不在任何 SR 下`)
      const parent = `SR-${node.id.slice(3).split('.').slice(0, 2).join('.')}`
      if (parent !== currentSR) problems.push(`${node.id} 父级应为 ${currentSR}，按编号应为 ${parent}`)
    }
  }

  for (const node of nodes) if (node.type === 'IR') irs.add(node.id)
  return { ids, irs }
}

function checkProductScope(irs) {
  const text = readText(PRODUCT_FILE)
  const refs = new Set([...text.matchAll(/\bIR-\d{2}\b/g)].map((m) => m[0]))
  for (const ref of refs) if (!irs.has(ref)) problems.push(`product.md 引用了不存在的 ${ref}`)
  for (const ir of irs) if (!refs.has(ir)) problems.push(`product.md 未列出 ${ir}`)
}

function checkDetails(ids) {
  if (!existsSync(DETAIL_DIR)) return
  const headings = new Map()
  for (const name of readdirSync(DETAIL_DIR).filter((n) => n.endsWith('.md')).sort()) {
    if (name === 'README.md') continue
    const file = join(DETAIL_DIR, name)
    const text = readText(file)
    const sections = text.split(/^(## .*)$/m)
    let current = null
    for (const part of sections) {
      if (part.startsWith('## ')) {
        const match = part.match(/^## ((?:SR|AR)-\d{2}(?:\.\d{2})*)\b/)
        if (!match) {
          problems.push(`${file} 有无法识别的标题：${part.trim()}`)
          current = null
          continue
        }
        const id = match[1]
        if (!ids.has(id)) problems.push(`${file} 引用了不存在的 ${id}`)
        if (headings.has(id)) problems.push(`${id} 在细节文档中重复：${headings.get(id)} 与 ${file}`)
        headings.set(id, file)
        current = { file, id, body: '' }
        continue
      }
      if (current) {
        current.body += part
        if (/\*\*(行为|验收|职责)\*\*/.test(part)) {
          problems.push(`${file} 的 ${current.id} 重复写了行为/验收/职责，细节层只补充边界`)
        }
      }
    }
  }
}

function checkLinks() {
  const files = [REQ_FILE, PRODUCT_FILE]
  if (existsSync(DETAIL_DIR)) {
    for (const name of readdirSync(DETAIL_DIR).filter((n) => n.endsWith('.md'))) files.push(join(DETAIL_DIR, name))
  }
  for (const file of files) {
    if (!existsSync(file)) continue
    const text = readFileSync(file, 'utf8')
    for (const match of text.matchAll(/`((?:handbook|docs)\/[^`\s]+\.md)`/g)) {
      const target = match[1]
      if (!existsSync(target)) problems.push(`${file} 指向不存在的文件：${target}`)
    }
  }
}

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

function checkApproval() {
  if (!staged || noApproval) return
  const changed = stagedKeyFiles()
  if (!changed.length) return
  const unstaged = git(['diff', '--name-only'], { encoding: 'utf8' })
    .split('\n')
    .filter(Boolean)
    .filter((path) => path.startsWith(KEY_PREFIX) && path.endsWith('.md'))
  if (unstaged.length) {
    problems.push(`需求文件有未暂存改动，先 git add 再提交：${unstaged.join(', ')}`)
  }
  const approvals = readApprovals()
  for (const { path } of changed) {
    const hash = indexHash(path)
    if (!approvals.some((entry) => entry.path === path && entry.sha256 === hash)) {
      problems.push(`${path} 缺少与暂存内容匹配的 owner 审批记录（${hash.slice(0, 12)}…）`)
    }
  }
  if (problems.some((p) => p.includes('缺少与暂存内容匹配'))) {
    problems.push('先跑 npm run check:requirements 自审，再让 owner 批准，最后运行：npm run approve:requirements -- --owner-approved "<owner 的原话>"')
  }
}

const nodes = parseRequirements(readText(REQ_FILE))
if (!nodes.length) problems.push('没有解析到任何 IR/SR/AR 节点')
const { ids, irs } = checkRequirements(nodes)
checkProductScope(irs)
checkDetails(ids)
checkLinks()
checkApproval()

if (problems.length) {
  console.error('需求自审未通过：\n')
  for (const problem of problems) console.error(`  - ${problem}`)
  console.error('\n规则见 scripts/dev/check-requirements.mjs；修完重跑 npm run check:requirements。')
  process.exit(1)
}

const counts = { IR: 0, SR: 0, AR: 0 }
for (const node of nodes) counts[node.type] += 1
console.log(`ok  需求自审通过：${counts.IR} IR / ${counts.SR} SR / ${counts.AR} AR，细节文档编号与结构一致。`)
console.log('注意：语义冲突仍需 owner 阅读；程序只校验结构、编号、追溯与链接。')

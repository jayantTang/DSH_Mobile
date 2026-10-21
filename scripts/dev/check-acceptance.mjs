#!/usr/bin/env node
// 静态校验验收子集：文件成对、front matter 完整、ID 唯一、无固定会话/真实 home。
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const dir = 'test/acceptance'
const errors = []
const files = readdirSync(dir).filter((name) => name.endsWith('.md') && name !== 'README.md').sort()
const ids = new Set()
for (const name of files) {
  const md = readFileSync(join(dir, name), 'utf8')
  const stepsPath = join(dir, name.replace(/\.md$/, '.steps'))
  let steps
  try { steps = readFileSync(stepsPath, 'utf8') } catch { errors.push(`${name}: 缺少 .steps`); continue }
  const id = /^id:\s*(\S+)/m.exec(md)?.[1]
  const title = /^title:\s*(.+)$/m.exec(md)?.[1]
  const criteria = /^通过判据:\s*(.+)$/m.exec(md)?.[1]
  if (!id) errors.push(`${name}: 缺少 id`)
  if (id && ids.has(id)) errors.push(`${name}: id 重复 ${id}`)
  if (id) ids.add(id)
  if (!title) errors.push(`${name}: 缺少 title`)
  if (!criteria) errors.push(`${name}: 缺少 通过判据`)
  if (/^会话:/m.test(md)) errors.push(`${name}: 不得写死 会话`)
  if (/session-[0-9a-f]{8}-/i.test(md + steps)) errors.push(`${name}: 出现固定 session id`)
  if (/\/Users\/[^/]+/.test(md + steps)) errors.push(`${name}: 出现本机 home 路径`)
  const stepSection = md.split('## 步骤')[1] ?? ''
  const prose = (stepSection.match(/^\d+\.\s+/gm) ?? []).length
  const commands = (steps.match(/^\d+\s+do:/gm) ?? []).length
  if (prose && prose !== commands) errors.push(`${name}: 步骤 ${prose} 条，指令 ${commands} 条`)
}
if (files.length !== 6) errors.push(`验收子集应为 6 条，实际 ${files.length}`)
if (errors.length) {
  for (const error of errors) console.error(`✗ ${error}`)
  process.exit(1)
}
console.log(`✓ 验收子集 ${files.length} 条：${[...ids].join(', ')}`)

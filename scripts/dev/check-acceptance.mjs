#!/usr/bin/env node
// 静态校验验收子集：文件成对、front matter 完整、ID 唯一、会话夹具可复现、无真实 home。
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
  // 图片类用例的夹具由 scripts/dev/image-scratch-session.mjs 生成，只能钉住一个会话；
  // 钉住时必须写清重建方式，且正文与指令里不能再出现别的会话 id。
  const pinned = /^会话:\s*(\S+)/m.exec(md)?.[1]
  const remark = /^备注:\s*(.+)$/m.exec(md)?.[1] ?? ''
  if (pinned && !/重建|重新生成|image-scratch-session/.test(remark)) {
    errors.push(`${name}: 钉住 会话 但 备注 未写重建方式`)
  }
  for (const match of (md + steps).matchAll(/session-[0-9a-f]{8}-[0-9a-f-]+/gi)) {
    if (!pinned || match[0].toLowerCase() !== pinned.toLowerCase()) {
      errors.push(`${name}: 出现不属于本条夹具的固定 session id ${match[0]}`)
    }
  }
  if (/\/Users\/[^/]+/.test(md + steps)) errors.push(`${name}: 出现本机 home 路径`)
  const stepSection = md.split('## 步骤')[1] ?? ''
  const prose = (stepSection.match(/^\d+\.\s+/gm) ?? []).length
  const commands = (steps.match(/^\d+\s+do:/gm) ?? []).length
  if (prose && prose !== commands) errors.push(`${name}: 步骤 ${prose} 条，指令 ${commands} 条`)
}
// 条数与 README 表一致；加用例时两处一起改。
if (files.length !== 18) errors.push(`验收子集应为 18 条，实际 ${files.length}`)
if (errors.length) {
  for (const error of errors) console.error(`✗ ${error}`)
  process.exit(1)
}
console.log(`✓ 验收子集 ${files.length} 条：${[...ids].join(', ')}`)

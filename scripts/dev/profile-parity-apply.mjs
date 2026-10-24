#!/usr/bin/env node
/**
 * 把对等检查报出来的配置块，从**一个宿主档案**补到**另一个**。
 *
 *   node scripts/dev/profile-parity-apply.mjs                     # 预演：说要补什么，不写盘
 *   node scripts/dev/profile-parity-apply.mjs --write             # 真写：先备份，再补
 *   node scripts/dev/profile-parity-apply.mjs --block permission --write
 *   node scripts/dev/profile-parity-apply.mjs --from web --to desktop（默认方向）
 *
 * 为什么需要它：这两个档案是**用户本机**的配置（`~/\.dsh/profiles/<宿主>/cordis.patch.yml`），
 * 不在仓库里，agent 的沙箱通常写不到；而"照着检查输出手抄一段 YAML"最容易抄错。
 * 所以：检查（`profile-parity.mjs`）负责说清楚缺什么，本脚本负责**幂等**地补上——
 * 抄写这件事只有一份实现，和检查共用同一个解析器（`profile-patch.mjs`）。
 *
 * 行为：
 *   - 缺的块 → 追加到目标档案末尾（带一行来源注释）；
 *   - 在但内容不同 → **拒绝**，除非显式 `--overwrite`（那时按来源档案覆盖那一段）；
 *   - 已经一致 → 跳过，重复执行是空操作；
 *   - 写盘前把目标档案备份成 `cordis.patch.yml.bak-004-apply-<时间戳>`；
 *   - 宿主专属块（`profile-patch.mjs` 的 `HOST_OWNED`）不会被搬过去。
 *
 * 退出码：0 = 已一致或（预演/写入）成功；1 = 有内容漂移且没给 `--overwrite`；
 *        2 = 用法或环境错误（档案不存在、未知块名）。
 */

import { copyFileSync, existsSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

import { HOST_OWNED, dshHome, parseBlockRanges, parseBlocks, profileDir, readPatch } from './profile-patch.mjs'

const argv = process.argv.slice(2)
const valueOf = (name, fallback) => {
  const at = argv.indexOf(`--${name}`)
  return at >= 0 && at + 1 < argv.length ? argv[at + 1] : fallback
}
const write = argv.includes('--write')
const overwrite = argv.includes('--overwrite')
const from = valueOf('from', 'web')
const to = valueOf('to', 'desktop')
const only = argv.reduce((acc, arg, index) => (arg === '--block' ? [...acc, argv[index + 1]] : acc), [])

function fail(message, code = 2) {
  process.stderr.write(`profile-parity-apply: ${message}\n`)
  process.exit(code)
}

const home = dshHome()
const fromDir = profileDir(from, home)
const toDir = profileDir(to, home)
for (const [side, dir] of [[from, fromDir], [to, toDir]]) {
  if (!existsSync(join(dir, 'package.json'))) fail(`${side} 档案不存在：${dir}（该宿主没装过）`)
}

const fromText = readPatch(join(fromDir, 'cordis.patch.yml'))
const toPath = join(toDir, 'cordis.patch.yml')
const toText = readPatch(toPath)
if (fromText.trim() === '') fail(`${from} 档案没有 cordis.patch.yml（没有可搬的配置块）`)

const source = new Map(parseBlocks(fromText).map((block) => [block.id, block]))
const target = new Map(parseBlocks(toText).map((block) => [block.id, block]))

// 候选：来源档案里、不属于来源宿主的块；`--block` 可只挑几段。
let candidates = [...source.keys()].filter((id) => !HOST_OWNED[from].has(id))
if (only.length) {
  for (const id of only) {
    if (!source.has(id)) fail(`未知块名 ${id}；${from} 档案里的块：${[...source.keys()].join(', ')}`)
  }
  candidates = only
}

const plan = []
for (const id of candidates) {
  const block = source.get(id)
  const here = target.get(id)
  if (!here) plan.push({ id, action: 'add', block })
  else if (here.body !== block.body) plan.push({ id, action: 'drift', block })
}

if (plan.length === 0) {
  process.stdout.write(`${to} 档案已经与 ${from} 对齐（候选 ${candidates.length} 段，没有要改的）。\n`)
  process.exit(0)
}

const drifted = plan.filter((item) => item.action === 'drift')
process.stdout.write(write ? `将写入 ${to} 档案：\n` : `预演（没有写盘，加 --write 才写）：\n`)
for (const item of plan) {
  process.stdout.write(`  ${item.action === 'add' ? '补' : '覆盖'} ${item.id}\n`)
}
if (drifted.length && !overwrite) {
  process.stderr.write(`\n${drifted.length} 段内容不同（${drifted.map((d) => d.id).join(', ')}）：`
    + '内容不同的块不会自动覆盖，确认要以来源档案为准后加 --overwrite。\n')
  process.exit(1)
}
if (!write) {
  process.stdout.write('\n写入后要重启对应宿主：官方桌面版 `npm run restart`；再把 `npm run check:parity` 跑到 0。\n')
  process.exit(0)
}

// 就地把"漂移"的段换掉，缺的段追加到末尾。
const targetRanges = new Map(parseBlockRanges(toText).map((range) => [range.id, range]))
let lines = toText.split('\n')
const replacements = []
for (const item of plan) {
  if (item.action !== 'drift') continue
  const range = targetRanges.get(item.id)
  if (!range) fail(`内部错误：${item.id} 的区间找不到`)
  replacements.push({ ...range, text: item.block.text })
}
for (const range of replacements.sort((a, b) => b.start - a.start)) {
  lines = [...lines.slice(0, range.start), ...range.text.split('\n'), ...lines.slice(range.end)]
}
let text = lines.join('\n')
if (!text.endsWith('\n')) text += '\n'

const added = plan.filter((item) => item.action === 'add')
if (added.length) {
  text += `\n# 004 对齐（${new Date().toISOString().slice(0, 10)}）：以下配置从 ${from} 档案补齐，\n`
    + `# 让 ${to} 宿主与它功能对等；根因与验证见 maintainers/验收/004-桌面宿主对等.md。\n`
  for (const item of added) text += `${item.block.text}\n\n`
}

const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14)
const backup = `${toPath}.bak-004-apply-${stamp}`
copyFileSync(toPath, backup)
writeFileSync(toPath, text.endsWith('\n') ? text : `${text}\n`)
process.stdout.write(`\n已写入 ${toPath}\n备份 ${backup}\n`
  + `重启 ${to === 'desktop' ? '官方桌面版（npm run restart）' : 'web 宿主'} 后生效，再跑 npm run check:parity 确认到 0。\n`)

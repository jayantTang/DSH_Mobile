#!/usr/bin/env node
/**
 * 两个宿主档案的**功能对等**检查（只报告）。
 *
 *   node scripts/dev/profile-parity.mjs            # 打印差异
 *   node scripts/dev/profile-parity.mjs --strict   # 有差异就非零退出（用于手工闸门）
 *
 * 为什么需要：官方桌面版用 `profiles/desktop`，命令行 web 版用 `profiles/web`，
 * 两个档案的**插件与配置互相独立**。只在一边做过的事，换宿主就会失效——实测过一次：
 * 只在 web 档案注册的模型提供方（company-gateway）在桌面版里报
 * "no adapter registered for provider"，手机发消息当场失败。
 *
 * 检查三类：
 *   1. dependencies（装了哪些插件）
 *   2. dsh.profile.bundles（哪些 bundle 被启用）
 *   3. cordis.patch.yml 的顶层条目 id（哪些配置块存在）
 */

import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = process.env.DSH_HOME || join(homedir(), '.dsh')
const PROFILES = { web: join(HOME, 'profiles', 'web'), desktop: join(HOME, 'profiles', 'desktop') }
const strict = process.argv.includes('--strict')
const asJson = process.argv.includes('--json')

/**
 * 只属于某个档案的配置块（不是差异，别去对齐）。
 * 官方桌面版启动时会自己写这几条客户端设置；web 档案没有它们是对的。
 */
const HOST_OWNED = {
  desktop: new Set(['ui-chat', 'ui-settings', 'ui-settings-account']),
}

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return undefined }
}

/** 顶层 patch 条目 id：行首 `- id: xxx`。 */
function patchIds(path) {
  if (!existsSync(path)) return []
  return [...readFileSync(path, 'utf8').matchAll(/^- id: (\S+)/gm)].map((m) => m[1])
}

function profileState(dir) {
  const manifest = readJson(join(dir, 'package.json'))
  return {
    deps: Object.keys(manifest?.dependencies ?? {}),
    bundles: manifest?.dsh?.profile?.bundles ?? [],
    patches: patchIds(join(dir, 'cordis.patch.yml')),
  }
}

const states = Object.fromEntries(Object.entries(PROFILES).map(([name, dir]) => [name, profileState(dir)]))
const gaps = []
const owned = []
for (const field of ['deps', 'bundles', 'patches']) {
  const web = new Set(states.web[field])
  const desktop = new Set(states.desktop[field])
  for (const item of web) if (!desktop.has(item)) gaps.push({ field, item, missingIn: 'desktop' })
  for (const item of desktop) {
    if (web.has(item)) continue
    if (field === 'patches' && HOST_OWNED.desktop?.has(item)) { owned.push(item); continue }
    gaps.push({ field, item, missingIn: 'web' })
  }
}

if (asJson) {
  process.stdout.write(`${JSON.stringify({ states, gaps }, null, 2)}\n`)
} else {
  for (const name of ['web', 'desktop']) {
    const s = states[name]
    process.stdout.write(`${name}: 插件 ${s.deps.length} · bundle ${s.bundles.length} · 配置块 ${s.patches.length}\n`)
  }
  process.stdout.write('\n')
  if (owned.length) {
    process.stdout.write(`宿主专属配置块（不算差异）：${owned.join(', ')}\n—— 官方桌面版自己写的客户端设置，web 档案不需要。\n\n`)
  }
  if (!gaps.length) {
    process.stdout.write('两个档案功能对等：插件、bundle、配置块三类的 id 集合一致。\n')
  } else {
    process.stdout.write(`差异 ${gaps.length} 处（"missingIn" = 只缺这一边）：\n`)
    for (const gap of gaps) process.stdout.write(`  [${gap.field}] ${gap.item}  ← 缺少：${gap.missingIn}\n`)
    process.stdout.write('\n对齐命令示例：\n'
      + '  插件：用目标宿主自带的 dsh 装（桌面版用应用包里的那条）\n'
      + '  配置块：把 `- id: <名字>` 那一段原样复制到另一个档案的 cordis.patch.yml，然后重启该宿主\n')
  }
}

process.exitCode = strict && gaps.length ? 1 : 0

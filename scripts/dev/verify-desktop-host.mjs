#!/usr/bin/env node
/**
 * 官方桌面版验收助手：断言"装进 desktop 档案的连接器能在宿主进程内拿到本机访问方式"。
 *
 *   node scripts/dev/verify-desktop-host.mjs                 # 用 $DSH_HOME/mobile-link/endpoint.json 里的地址
 *   node scripts/dev/verify-desktop-host.mjs --url 'http://127.0.0.1:19387/?token=...'
 *   node scripts/dev/verify-desktop-host.mjs --home /tmp/dsh-verify-desktop
 *
 * 前置（见 specs/001-connector-host-compat/quickstart.md §A）：
 *   1. 用隔离的 DSH_HOME 冷启官方桌面版（应用先启动过一次以初始化档案）；
 *   2. 完全退出应用，用应用自带的 CLI 把连接器装进 desktop 档案；
 *   3. 重新打开应用，让它把连接器加载起来。
 *
 * 退出码：0 = 断言全过；1 = 有断言失败（逐条打印实际值）；2 = 工具自身出错。
 */

import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const argv = process.argv.slice(2)
function value(name) {
  const at = argv.indexOf(`--${name}`)
  return at >= 0 && at + 1 < argv.length ? argv[at + 1] : undefined
}

const home = value('home') ?? process.env.DSH_HOME ?? join(homedir(), '.dsh')
const handoffPath = join(home, 'mobile-link', 'endpoint.json')

function tokenizedUrl() {
  const explicit = value('url')
  if (explicit) return explicit
  try {
    const raw = JSON.parse(readFileSync(handoffPath, 'utf8'))
    if (typeof raw?.url === 'string' && raw.url) return raw.url
  } catch {
    /* fall through to the actionable error below */
  }
  throw new Error(
    `读不到 ${handoffPath}。请先确认：官方桌面版正在运行、连接器已装进 desktop 档案（见 quickstart §A），` +
    '或用 --url 直接给出带令牌的地址。',
  )
}

const failures = []
function check(label, actual, expected) {
  const ok = actual === expected
  process.stdout.write(`${ok ? '✔' : '✖'} ${label}：${JSON.stringify(actual)}（期望 ${JSON.stringify(expected)}）\n`)
  if (!ok) failures.push(label)
}

async function main() {
  const url = tokenizedUrl()
  const base = new URL(url)
  const token = base.searchParams.get('token')
  if (!token) throw new Error('地址里没有 token（官方桌面版的地址形如 http://127.0.0.1:19387/?token=…）')

  // 令牌换 cookie（不跟随 303）。
  const handshake = await fetch(url, { redirect: 'manual' })
  const setCookie = typeof handshake.headers.getSetCookie === 'function'
    ? handshake.headers.getSetCookie()
    : [handshake.headers.get('set-cookie')].filter(Boolean)
  const cookie = setCookie.map((item) => String(item).split(';')[0]).filter((item) => item.startsWith('dsh-auth-')).join('; ')
  if (!cookie) throw new Error(`换 cookie 失败：HTTP ${handshake.status}`)

  const response = await fetch(`${base.origin}/mobile-link/status`, { headers: { cookie } })
  const status = await response.json()

  process.stdout.write(`\n官方桌面版状态（${base.origin}）：\n`)
  if (!status.ok) {
    process.stdout.write(`✖ /mobile-link/status 不可用：${JSON.stringify(status)}\n`)
    failures.push('status endpoint')
  } else {
    check('host', status.host, 'desktop')
    check('dsh.source', status.dsh?.source, 'host-service')
    check('dsh.authenticated', status.dsh?.authenticated, true)
    check('dsh.error', status.dsh?.error, null)
    check('dsh.errorKind', status.dsh?.errorKind, null)
  }

  process.stdout.write(failures.length === 0
    ? '\n结论：通过——连接器在官方桌面版里用宿主内注入拿到了本机访问方式。\n'
    : `\n结论：失败——${failures.length} 项不符（${failures.join(', ')}）。\n`)
  return failures.length === 0 ? 0 : 1
}

main().then((code) => { process.exitCode = code }).catch((error) => {
  process.stderr.write(`verify-desktop-host: ${error?.message ?? error}\n`)
  process.exitCode = 2
})

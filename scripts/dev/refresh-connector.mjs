#!/usr/bin/env node
/**
 * 本机连接器刷新保护：改 `plugins/mobile-link` 前拍快照，改完自动等链路恢复；
 * 超时未恢复就把快照放回去，避免一次热更把本机连接器留在离线状态。
 *
 * 用法：
 *   node scripts/dev/refresh-connector.mjs prepare
 *   # 编辑 plugins/mobile-link/lib/*.js
 *   node scripts/dev/refresh-connector.mjs verify
 *
 * 退出码：0 健康或没有源码变化；1 已自动回滚并恢复；2 用法/前置不满足；
 *         3 回滚后仍不健康，需要人工处理。`rollback` 可随时恢复最近一次快照。
 *
 * 只读写 `$DSH_HOME/mobile-link`（默认 `~/.dsh/mobile-link`）与连接器源码目录；
 * 不读取、不打印 agentSecret，也不自动改身份文件。身份 hash 变化会直接判失败，
 * 交给人恢复，避免把重新登记之类的正常操作回滚掉。
 */

import { createHash } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const SLEEP_MS = 500
const KEEP_SNAPSHOTS = 5
const CLOSED_KINDS = new Set(['link.close', 'link.stop', 'link.failed', 'link.start'])

function usage() {
  console.log(`用法：
  node scripts/dev/refresh-connector.mjs prepare [--home DIR] [--connector DIR]
  node scripts/dev/refresh-connector.mjs verify [--timeout 120] [--no-restore]
  node scripts/dev/refresh-connector.mjs rollback [--timeout 120]
  node scripts/dev/refresh-connector.mjs status`)
}

function die(message, code = 2) {
  console.error(`refresh-connector: ${message}`)
  process.exit(code)
}

function parseArgs(argv) {
  const flags = {}
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (!arg.startsWith('--')) die(`未知参数 ${arg}`)
    const key = arg.slice(2)
    if (key === 'no-restore') {
      flags.noRestore = true
      continue
    }
    const value = argv[index + 1]
    if (value === undefined || value.startsWith('--')) die(`--${key} 需要值`)
    flags[key] = value
    index += 1
  }
  return flags
}

const command = process.argv[2]
const flags = parseArgs(process.argv.slice(3))
if (!command || command === '--help' || command === '-h') {
  usage()
  process.exit(command ? 0 : 2)
}
const home = resolve(flags.home || process.env.DSH_HOME || join(homedir(), '.dsh'))
const connector = resolve(flags.connector || join(ROOT, 'plugins/mobile-link'))
const journalPath = join(home, 'mobile-link', 'link-events.jsonl')
const identityPath = join(home, 'mobile-link', 'agent.json')
const stateRoot = join(home, 'mobile-link', 'rollback')
const timeoutMs = Number(flags.timeout ?? 120) * 1000
const settleMs = Number(flags.settle ?? 5) * 1000

if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) die('--timeout 必须是正数')
if (!Number.isFinite(settleMs) || settleMs < 0) die('--settle 不能为负')

const sleep = (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms))

function sha256File(path) {
  try {
    return createHash('sha256').update(readFileSync(path)).digest('hex')
  } catch {
    return null
  }
}

function treeHash(base, entries) {
  const hash = createHash('sha256')
  const walk = (path, relative) => {
    const stat = statSync(path)
    if (stat.isDirectory()) {
      for (const name of readdirSync(path).sort()) walk(join(path, name), `${relative}/${name}`)
      return
    }
    hash.update(relative)
    hash.update('\0')
    hash.update(readFileSync(path))
  }
  for (const entry of [...entries].sort()) {
    const path = join(base, entry)
    if (existsSync(path)) walk(path, entry)
  }
  return hash.digest('hex')
}

function copyTree(source, target) {
  mkdirSync(dirname(target), { recursive: true })
  cpSync(source, target, { recursive: true, force: true, preserveTimestamps: true })
}

function removeExtras(source, target) {
  if (!existsSync(target)) return
  const sourceEntries = new Set(existsSync(source) ? readdirSync(source) : [])
  for (const name of readdirSync(target)) {
    const targetPath = join(target, name)
    const sourcePath = join(source, name)
    if (!sourceEntries.has(name)) {
      rmSync(targetPath, { recursive: true, force: true })
      continue
    }
    if (statSync(targetPath).isDirectory() && statSync(sourcePath).isDirectory()) {
      removeExtras(sourcePath, targetPath)
    }
  }
}

function restoreSnapshot(directory) {
  copyTree(join(directory, 'lib'), join(connector, 'lib'))
  removeExtras(join(directory, 'lib'), join(connector, 'lib'))
  if (existsSync(join(directory, 'package.json'))) {
    copyTree(join(directory, 'package.json'), join(connector, 'package.json'))
  }
}

function readJournal() {
  const entries = []
  for (const name of ['link-events.jsonl', 'link-events.jsonl.1']) {
    const path = join(home, 'mobile-link', name)
    if (!existsSync(path)) continue
    for (const line of readFileSync(path, 'utf8').split('\n')) {
      if (!line.trim()) continue
      try {
        const entry = JSON.parse(line)
        if (entry && typeof entry.at === 'string') entries.push(entry)
      } catch {
        /* 坏行跳过：流水只用于健康判断，不能因此挡住回滚 */
      }
    }
  }
  return entries.sort((left, right) => Date.parse(left.at) - Date.parse(right.at))
}

function latestLifecycle(entries) {
  let open
  let closed
  for (const entry of entries) {
    if (entry.kind === 'link.open') open = entry
    else if (CLOSED_KINDS.has(entry.kind)) closed = entry
  }
  return { open, closed }
}

function isHealthy(entries) {
  const { open, closed } = latestLifecycle(entries)
  return Boolean(open) && (!closed || Date.parse(open.at) > Date.parse(closed.at))
}

async function waitHealthySince(sinceMs, timeout) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const { open, closed } = latestLifecycle(readJournal())
    if (open && Date.parse(open.at) >= sinceMs && (!closed || Date.parse(open.at) > Date.parse(closed.at))) {
      if (Date.now() - Date.parse(open.at) >= settleMs) return open
    }
    await sleep(SLEEP_MS)
  }
  return undefined
}

function readIdentity() {
  if (!existsSync(identityPath)) return { hash: null, agentId: '' }
  try {
    const payload = JSON.parse(readFileSync(identityPath, 'utf8'))
    return { hash: sha256File(identityPath), agentId: String(payload.agentId || '') }
  } catch {
    return { hash: sha256File(identityPath), agentId: '' }
  }
}

function latestStateDir() {
  if (!existsSync(stateRoot)) return undefined
  const candidates = readdirSync(stateRoot)
    .map((name) => join(stateRoot, name))
    .filter((path) => existsSync(join(path, 'state.json')))
    .sort()
    .reverse()
  return candidates[0]
}

function readState(directory) {
  if (!directory) die('没有可用的快照；先运行 prepare')
  try {
    return JSON.parse(readFileSync(join(directory, 'state.json'), 'utf8'))
  } catch (error) {
    die(`读取快照失败：${error.message}`)
  }
}

function pruneSnapshots() {
  if (!existsSync(stateRoot)) return
  const entries = readdirSync(stateRoot)
    .map((name) => join(stateRoot, name))
    .filter((path) => statSync(path).isDirectory())
    .sort()
    .reverse()
  for (const path of entries.slice(KEEP_SNAPSHOTS)) rmSync(path, { recursive: true, force: true })
}

function snapshot(entries) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  const directory = join(stateRoot, `refresh-${stamp}`)
  mkdirSync(directory, { recursive: true, mode: 0o700 })
  copyTree(join(connector, 'lib'), join(directory, 'lib'))
  if (existsSync(join(connector, 'package.json'))) {
    copyTree(join(connector, 'package.json'), join(directory, 'package.json'))
  }
  const identity = readIdentity()
  const state = {
    preparedAt: new Date().toISOString(),
    preparedMs: Date.now(),
    agentId: identity.agentId,
    identityHash: identity.hash,
    sourceHash: treeHash(directory, entries),
    connector,
    home,
  }
  writeFileSync(join(directory, 'state.json'), `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 })
  return { directory, state }
}

function currentSourceHash() {
  return treeHash(connector, ['lib', 'package.json'])
}

async function prepare() {
  const entries = readJournal()
  if (!entries.length) die(`找不到链路流水：${journalPath}（本机连接器没启动过？）`)
  if (!isHealthy(entries)) die('当前连接器不在健康状态；先恢复链路，再拍刷新快照')
  const { directory, state } = snapshot(['lib', 'package.json'])
  pruneSnapshots()
  console.log(`快照已保存：${directory}`)
  console.log(`agentId=${state.agentId || '(未登记)'} identity=${state.identityHash?.slice(0, 12) ?? 'none'}`)
  console.log('现在修改 plugins/mobile-link，然后运行 verify')
}

async function verify() {
  const directory = flags.state ? resolve(flags.state) : latestStateDir()
  const state = readState(directory)
  const identity = readIdentity()
  if (identity.hash !== state.identityHash) {
    die('身份文件在刷新期间发生变化；不自动回滚身份，先人工确认 agent.json', 3)
  }
  if (currentSourceHash() === state.sourceHash) {
    console.log('连接器源码与快照一致，没有需要验证的热更')
    return
  }
  console.log(`等待链路在新的热更后恢复（最多 ${Math.round(timeoutMs / 1000)} 秒）…`)
  const open = await waitHealthySince(state.preparedMs, timeoutMs)
  if (open) {
    console.log(`刷新成功：link.open at ${open.at}，agentId=${open.agentId || state.agentId}`)
    return
  }
  console.error('链路未恢复，自动回滚到快照')
  if (flags.noRestore) {
    console.error('已指定 --no-restore，保留当前源码；需要人工处理')
    process.exit(3)
  }
  const restoreAt = Date.now()
  restoreSnapshot(directory)
  const recovered = await waitHealthySince(restoreAt, timeoutMs)
  if (recovered) {
    console.log(`已回滚并恢复：link.open at ${recovered.at}（快照 ${directory}）`)
    process.exit(1)
  }
  console.error('回滚后链路仍未恢复；保留快照，需要人工处理（不要反复重启宿主）')
  process.exit(3)
}

async function rollback() {
  const directory = flags.state ? resolve(flags.state) : latestStateDir()
  readState(directory)
  const restoreAt = Date.now()
  restoreSnapshot(directory)
  console.log(`已恢复快照 ${directory}`)
  const recovered = await waitHealthySince(restoreAt, timeoutMs)
  if (recovered) {
    console.log(`链路已恢复：link.open at ${recovered.at}`)
    return
  }
  console.error('恢复快照后链路仍未恢复；需要人工处理')
  process.exit(3)
}

function status() {
  const entries = readJournal()
  const { open, closed } = latestLifecycle(entries)
  const identity = readIdentity()
  const directory = latestStateDir()
  console.log(`connector=${connector}`)
  console.log(`home=${home}`)
  console.log(`agentId=${identity.agentId || '(未登记)'}`)
  console.log(`identity=${identity.hash?.slice(0, 12) ?? 'none'}`)
  console.log(`link=${isHealthy(entries) ? 'healthy' : 'down'} latestOpen=${open?.at ?? '-'} latestClose=${closed?.at ?? '-'}`)
  console.log(`latestSnapshot=${directory ?? '-'}`)
  if (directory) {
    const state = readState(directory)
    console.log(`snapshotPreparedAt=${state.preparedAt} sourceChanged=${currentSourceHash() !== state.sourceHash}`)
  }
}

const actions = { prepare, verify, rollback, status }
if (!actions[command]) die(`未知子命令 ${command}`)
await actions[command]()

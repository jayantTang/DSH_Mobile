#!/usr/bin/env node
/**
 * Ask this machine's DSH to restart itself — including the process running this
 * very turn.
 *
 * Why it exists: plugins, skills and the connector are read at startup, so every
 * change to them needs a restart. That used to mean "quit DSH.app and open it
 * again", i.e. a human at the computer. This turns it into one command the agent
 * can run itself.
 *
 * How it survives its own restart: the work is handed to a **detached** worker
 * (`dsh-restart-worker.mjs`) that outlives the process it is about to kill. The
 * worker kills the backend, waits for a new one (DSH.app respawns its own, and
 * the worker falls back to launching one if it does not), and then submits a
 * resume prompt into the same session — which is how the agent is woken up again
 * with its conversation intact.
 *
 *   node scripts/dev/dsh-restart.mjs                      # restart, then resume this session
 *   node scripts/dev/dsh-restart.mjs --resume "继续刚才的验证"
 *   node scripts/dev/dsh-restart.mjs --delay 5            # let the tool result land first
 *   node scripts/dev/dsh-restart.mjs --dry-run            # print what would happen
 *
 * The turn that runs this **ends** when the backend goes down; expect it. The
 * resume prompt is what continues the work, so put everything the next turn
 * needs to know into `--resume` (or leave it to read the state file).
 */

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
export const WORKER = join(HERE, 'dsh-restart-worker.mjs')

/** Where the handoff lives: the worker's log and the record of what was asked. */
export function stateDir(home = process.env.DSH_HOME || join(homedir(), '.dsh')) {
  return join(home, 'restart')
}

export const DEFAULT_RESUME =
  '［自动重启］DSH 已经重启完成。先读 ~/.dsh/restart/state.json 与 worker.log ' +
  '确认重启过程，然后继续上一轮没做完的事。'

/** `--flag value` pairs, with the few defaults this script has. */
export function parseArgs(argv) {
  const args = { delayMs: 3000, resume: DEFAULT_RESUME, dryRun: false, session: undefined }
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (token === '--dry-run') args.dryRun = true
    else if (token === '--resume') args.resume = String(argv[++index] ?? '')
    else if (token === '--delay') args.delayMs = Math.max(0, Number(argv[++index] ?? 3) * 1000)
    else if (token === '--session') args.session = String(argv[++index] ?? '')
    else if (token === '--help') args.help = true
  }
  return args
}

/**
 * What the worker needs to know, from the files the backend itself writes.
 *
 * `endpoint.json` is the harness's own handoff: it names the port and the pid of
 * the backend DSH.app is supervising. Reading it rather than guessing the port
 * is what lets this work on a machine where the backend was started with
 * `--port 0`.
 */
export function readEndpoint(home = process.env.DSH_HOME || join(homedir(), '.dsh')) {
  const path = join(home, 'desktop-shell', 'endpoint.json')
  if (!existsSync(path)) return undefined
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8'))
    if (!parsed?.port) return undefined
    return {
      path,
      port: Number(parsed.port),
      pid: Number(parsed.pid) || undefined,
      desktopShell: parsed.desktopShell === true,
      url: typeof parsed.url === 'string' ? parsed.url : undefined,
    }
  } catch {
    return undefined
  }
}

function usage() {
  console.log(`dsh-restart — 让本机 DSH 自己重启，并在重启后把本会话叫醒

  --resume "<文本>"   重启完成后提交给本会话的提示（默认写了一句「继续」）
  --session <id>     要唤醒的会话；默认取 $DSH_SESSION_ID
  --delay <秒>       重启前等多久（默认 3 秒，够工具结果先回到客户端）
  --dry-run          只打印计划，不真的重启

重启过程写进 ~/.dsh/restart/（state.json 与 worker.log），重启后的第一轮先读它。`)
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.help) return usage()

  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  const endpoint = readEndpoint(home)
  if (!endpoint) {
    throw new Error(`读不到 DSH 的 endpoint.json（${join(home, 'desktop-shell', 'endpoint.json')}）`)
  }

  const sessionId = args.session || process.env.DSH_SESSION_ID || ''
  const directory = stateDir(home)
  const statePath = join(directory, 'state.json')
  const logPath = join(directory, 'worker.log')
  const state = {
    requestedAt: new Date().toISOString(),
    fromPid: endpoint.pid,
    port: endpoint.port,
    desktopShell: endpoint.desktopShell,
    sessionId,
    resume: args.resume,
    delayMs: args.delayMs,
    logPath,
    status: 'scheduled',
  }

  if (args.dryRun) {
    console.log(JSON.stringify({ plan: 'restart', ...state, worker: WORKER }, null, 2))
    return
  }

  mkdirSync(directory, { recursive: true })
  writeFileSync(statePath, JSON.stringify(state, null, 2))

  // Detached and unref'd: this is the process that must not die with the backend
  // it is about to kill. `stdio: 'ignore'` plus the worker's own log file keeps
  // it independent of the parent's pipes.
  const worker = spawn(process.execPath, [WORKER, statePath], {
    detached: true,
    stdio: 'ignore',
    env: { ...process.env, DSH_RESTART_HOME: home },
  })
  worker.unref()

  console.log(
    `已排程重启：${args.delayMs / 1000} 秒后结束后端进程 ${endpoint.pid ?? '(未知)'}（端口 ${endpoint.port}），` +
    `随后拉起新的后端并把会话 ${sessionId || '(未指定)'} 叫醒。\n` +
    `本轮对话会在后端退出时中断，这是预期；重启后的第一轮由 worker 提交的提示触发。\n` +
    `过程记录：${logPath}`
  )
}

const isDirectRun = process.argv[1] !== undefined && process.argv[1].endsWith('dsh-restart.mjs')

if (isDirectRun) {
  main().catch((error) => {
    console.error(`dsh-restart: ${error.message}`)
    process.exit(1)
  })
}

export { main, usage }

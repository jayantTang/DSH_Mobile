#!/usr/bin/env node
/**
 * The detached half of `dsh-restart.mjs`: kill this machine's DSH backend, wait
 * for a new one, and wake the session that asked for the restart.
 *
 * It runs *outside* the process it kills, which is the whole trick — the agent's
 * turn dies with the backend, and this worker is what brings both back:
 *
 *   1. wait a moment, so the tool result reaches the client before the socket dies
 *   2. SIGTERM the backend, SIGKILL if it will not go
 *   3. wait for DSH.app to respawn its own backend (it supervises one);
 *      if it does not, `open -a DSH`; if that does not either, launch
 *      `dsh web --no-open --port 0` ourselves, which is what writes endpoint.json
 *   4. submit the resume prompt into the recorded session
 *
 * Every step is appended to `<DSH_HOME>/restart/worker.log`, and the state file
 * is updated as it goes, because the first thing the resumed turn does is read
 * them to find out what happened while it was gone.
 *
 * Run by `dsh-restart.mjs`; not meant to be run by hand (it would kill the
 * terminal's own backend).
 */

import { execFileSync, spawn } from 'node:child_process'
import { appendFileSync, existsSync, openSync, readFileSync, readlinkSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = process.env.DSH_RESTART_HOME || process.env.DSH_HOME || join(homedir(), '.dsh')
const ENDPOINT = join(HOME, 'mobile-link', 'endpoint.json')

/**
 * Read once, at the start of `main` — not at module load: importing this file
 * for its helpers (the tests do) must not exit the importing process.
 */
let state = {}
let logPath = join(HOME, 'restart', 'worker.log')

function log(message) {
  const line = `${new Date().toISOString()} ${message}\n`
  try {
    appendFileSync(logPath, line)
  } catch {
    /* the log is a courtesy; never let it stop the restart */
  }
}

function save(patch) {
  Object.assign(state, patch)
  try {
    writeFileSync(process.argv[2], JSON.stringify(state, null, 2))
  } catch (error) {
    log(`state write failed: ${error.message}`)
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** 应用二进制与这次启动的日志/诊断文件（诊断文件是应用自己写的）。 */
const APP_BINARY_PATH = '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'
export function appLogPaths(home = HOME) {
  const dir = join(home, 'restart')
  return { appLog: join(dir, 'desktop-app.log'), diagnostic: join(dir, 'desktop-diagnostic.json') }
}

/**
 * 直接启动应用二进制（绕开 LaunchServices）。
 *
 * 为什么要绕：`open -a` 走 LaunchServices，而应用刚退出时新实例会被 spawn 出来又在 ~60ms 内
 * 被回收（系统日志实测；重试还会把等待越拖越长，第六次 7 次请求共 93 秒）。直接起进程不经过
 * 那套节流，同时能把 stdout/stderr 和应用自己的诊断文件抓下来。
 *
 * 环境必须**清干净**：我们跑在 Electron 宿主里，环境里有 `ELECTRON_RUN_AS_NODE=1`，
 * 原样传给应用二进制会让它当成普通 Node 启动（不是应用）。
 */
export function launchAppDirect({ log = () => {}, home = HOME, spawnFn = spawn } = {}) {
  const { appLog, diagnostic } = appLogPaths(home)
  const env = { ...process.env, DSH_DESKTOP_DIAGNOSTIC_FILE: diagnostic }
  delete env.ELECTRON_RUN_AS_NODE
  delete env.NODE_OPTIONS
  delete env.ELECTRON_NO_ATTACH_CONSOLE
  const out = openSync(appLog, 'a')
  const child = spawnFn(APP_BINARY_PATH, [], { detached: true, stdio: ['ignore', out, out], env })
  child.unref()
  log(`直接启动应用二进制 pid=${child.pid}（日志 ${appLog}，诊断 ${diagnostic}）`)
  return child.pid
}


/** 官方桌面版的用户数据目录（单实例文件在这里）。 */
export const APP_USER_DATA = join(homedir(), 'Library', 'Application Support', '@deepseek-ai', 'dsh-desktop')

/**
 * 清掉上一次运行留下的**陈旧单实例文件**。
 *
 * 不清理会怎样：应用被 SIGTERM 后，`SingletonLock` 里仍指着已经死掉的旧 pid；新实例启动时据此
 * 认为"已有一个实例在跑"，于是**干净退出**（系统日志实测：spawn 后约 60ms 报 termination 0,0,0），
 * 这段时间约 30 秒——用户看到的就是"关掉了但一直不自己起来"。
 *
 * 只在该应用确实没有主进程时清理；应用在跑时绝不动它（会破坏它的单实例保证）。
 */
export function clearStaleSingleton({
  dir = APP_USER_DATA, log = () => {}, remove = rmSync, exists = existsSync, appAlive = () => appMainPids().length > 0,
} = {}) {
  if (appAlive()) {
    log('应用仍在运行，跳过单实例文件清理')
    return []
  }
  const cleared = []
  for (const name of ['SingletonLock', 'SingletonCookie', 'SingletonSocket']) {
    const target = join(dir, name)
    if (!exists(target)) continue
    try {
      let points = ''
      try {
        points = ` → ${readlinkSync(target)}`
      } catch { /* 不是符号链接就算 */ }
      remove(target, { force: true })
      cleared.push(name)
      log(`清理陈旧单实例文件：${name}${points}`)
    } catch (error) {
      log(`清理 ${name} 失败：${error.message}`)
    }
  }
  return cleared
}


/**
 * 后端跑在哪种宿主里：官方桌面版（Electron 管的私有宿主进程）还是命令行 `dsh web`。
 *
 * 判断依据是**进程树**：看后端进程的父进程是不是应用包里的可执行文件。这比环境变量可靠
 * （从桌面版里敲 `dsh web` 会继承 `ELECTRON_RUN_AS_NODE`，早期实现因此在慢闸里误判过）。
 */
export function hostFormOf(pid, { run = execFileSync } = {}) {
  if (!pid) return 'unknown'
  try {
    const ppid = String(run('ps', ['-o', 'ppid=', '-p', String(pid)], { encoding: 'utf8' })).trim()
    if (!ppid) return 'unknown'
    const parent = String(run('ps', ['-o', 'command=', '-p', ppid], { encoding: 'utf8' })).trim()
    if (/DeepSeek Harness\.app|dsh-desktop-host/.test(parent)) return 'desktop'
    return 'web'
  } catch {
    return 'unknown'
  }
}

/**
 * 官方桌面版：让**应用主进程**自己退出（宿主子进程随它一起走），再重新打开。
 *
 * 三条实测教训：
 *  ① 不能单独杀宿主子进程——那会让应用立刻弹「宿主异常退出」的恢复弹窗，用户还得手点一次；
 *  ② 不能对整个应用包路径 `pkill -f`——宿主子进程的命令行是同一个二进制加了
 *     `--expose-internals`，一样会被命中，于是又回到 ①；
 *  ③ 有弹窗挂着的应用不会乖乖退出，此时 `open -a` 只会激活旧实例，不会拉起新实例。
 *
 * 所以这里只给"命令行里没有 `--expose-internals` 的那个进程"发 SIGTERM，并等它真的退出。
 */
const APP_BINARY = 'DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'
/** argv[0] 正好是应用二进制（后面可以跟参数，也可以没有）。 */
const APP_ARGV0 = new RegExp(`^(/\\S*${APP_BINARY.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})(?:\\s|$)`)

/**
 * 应用主进程的 pid（排除宿主子进程与各 Helper）。
 *
 * 用 `ps` 扫全量而不是 `pgrep -f`：这台机器上 pgrep 只列得出 Helper 进程，
 * 应用主进程与宿主子进程都不出现（实测），照着它过滤会得到空集、什么都退不掉。
 */
export function appMainPids({ run = execFileSync } = {}) {
  let out
  try {
    out = String(run('ps', ['-eo', 'pid=,command='], { encoding: 'utf8' }))
  } catch {
    return []
  }
  return out.split('\n')
    .map((line) => line.trim())
    .map((line) => {
      const match = /^(\d+)\s+(.*)$/.exec(line)
      return match ? { pid: match[1], command: match[2] } : undefined
    })
    .filter(Boolean)
    // argv[0] 必须是应用二进制本身——Helper 在 Frameworks 下、grep/bash 那些行也不匹配，
    // 一次性排掉它们，不必逐个判断进程名。
    .filter((row) => APP_ARGV0.test(row.command))
    .filter((row) => !row.command.includes('--expose-internals')) // 宿主子进程：不能单独杀
    .map((row) => row.pid)
}


async function quitDesktopApp({ log = () => {}, hostPid } = {}) {
  log('宿主是官方桌面版：让应用自己退出（不单独杀宿主子进程，避免恢复弹窗）')
  let pids = appMainPids()
  if (!pids.length) {
    log('没找到应用主进程（可能已经退出）')
    return 'gone'
  }
  for (const pid of pids) {
    try {
      process.kill(Number(pid), 'SIGTERM')
    } catch { /* 已经没了 */ }
  }
  for (let waited = 0; waited < 30_000; waited += 500) {
    if (!appMainPids().length) {
      // 应用主进程没了不等于退干净：宿主子进程还在收尾时，新实例起来后会因单实例锁
      // 立刻自行退出（launchd 实测：spawn 后 70ms 报 termination）。等它也没了再开。
      for (let extra = 0; hostPid && alive(hostPid) && extra < 30_000; extra += 500) await sleep(500)
      if (hostPid && alive(hostPid)) log('警告：30s 内旧宿主子进程仍未退出')
      return 'term'
    }
    // 到 10 秒还不退，再补一次信号（有的版本会忽略第一次 TERM）
    if (waited === 10_000) for (const pid of appMainPids()) {
      try {
        process.kill(Number(pid), 'SIGTERM')
      } catch { /* 忽略 */ }
    }
    await sleep(500)
  }
  log('警告：30s 内应用主进程没有退出')
  return 'timeout'
}

/**
 * 反复轻推直到**新的交接文件**出现。
 *
 * 不以"应用进程出现"为准：实测新实例可能被 launchd spawn 出来、70ms 后又自行退出
 * （旧实例还在收尾时会发生），按进程判断会以为成功、然后干等 180 秒。
 */
async function relaunchUntilBackend({ log = () => {}, previousPid, timeoutMs = 180_000 } = {}) {
  const deadline = Date.now() + timeoutMs
  let opens = 0
  let killedBySystem = 0
  while (Date.now() < deadline) {
    if (!appMainPids().length) {
      opens += 1
      clearStaleSingleton({ log })
      if (opens === 1) {
        try {
          launchAppDirect({ log })
        } catch (error) {
          log(`直接启动失败：${error.message}`)
        }
      } else {
        try {
          execFileSync('open', ['-a', 'DeepSeek Harness'], { stdio: 'ignore' })
        } catch (error) {
          log(`open -a 失败：${error.message}`)
        }
      }
      // 应用退出后有几十秒的「静默期」：此时 open 会被 launchd 拉起来又在 ~60ms 内杀掉
      // （2026-10-07 系统日志实测：连续四次都是 spawn 后 58–62ms 报 termination）。
      // 这不是失败，只是还没到时候——记一笔，继续轻推。
      await sleep(3_000)
      if (!appMainPids().length) killedBySystem += 1
    }
    for (let waited = 0; waited < 20_000 && Date.now() < deadline; waited += 500) {
      const endpoint = readEndpoint()
      if (endpoint?.pid && endpoint.pid !== previousPid && alive(endpoint.pid)) {
        log(`官方桌面版已起来：open 请求 ${opens} 次`
          + `${killedBySystem ? `（其中 ${killedBySystem} 次被系统静默期立刻回收）` : ''}`
          + `，新后端 pid=${endpoint.pid} port=${endpoint.port}`)
        return endpoint
      }
      await sleep(500)
    }
  }
  log(`请求 ${opens} 次后仍没有新后端`)
  return undefined
}


/**
 * What the backend last handed out: port, pid, and the authenticated URL.
 *
 * The URL carries the launch token, and the token is the whole reason the
 * endpoint file exists — a resume that keeps the port but drops the token gets
 * `401` from the cookie exchange (the first real restart did exactly that,
 * twenty times, and the agent was never woken).
 */
export function readEndpoint(path = ENDPOINT) {
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8'))
    if (!parsed?.port) return undefined
    return {
      port: Number(parsed.port),
      pid: Number(parsed.pid) || undefined,
      url: typeof parsed.url === 'string' ? parsed.url : undefined,
      updatedAt: typeof parsed.updatedAt === 'string' ? parsed.updatedAt : undefined,
    }
  } catch {
    return undefined
  }
}

/** Whether a process is still there (signal 0 = "may I signal you?"). */
export function alive(pid) {
  if (!pid) return false
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

/**
 * Stop one process, politely then not.
 *
 * Returns what it took: `term`, `kill`, or `gone` when it had already exited.
 * Exported for testing — this is the part that must not leave a half-dead
 * backend holding the port.
 */
export async function stop(pid, {
  timeoutMs = 8000, pollMs = 200, kill = process.kill, isAlive = alive,
} = {}) {
  if (!isAlive(pid)) return 'gone'
  try {
    kill(pid, 'SIGTERM')
  } catch {
    return 'gone'
  }
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (!isAlive(pid)) return 'term'
    await sleep(pollMs)
  }
  try {
    kill(pid, 'SIGKILL')
  } catch {
    return 'gone'
  }
  for (let waited = 0; waited < 2000; waited += pollMs) {
    if (!isAlive(pid)) return 'kill'
    await sleep(pollMs)
  }
  return 'kill'
}

/** Wait for a backend whose pid is not the one we stopped. */
export async function waitForNewBackend({ previousPid, timeoutMs = 90_000, pollMs = 500, read = readEndpoint } = {}) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const endpoint = read()
    if (endpoint && endpoint.pid && endpoint.pid !== previousPid && alive(endpoint.pid)) {
      return endpoint
    }
    await sleep(pollMs)
  }
  return undefined
}

/** The session prompt that wakes the agent up again. */
export function resumePayload(sessionId, text) {
  return {
    request: {
      requestId: `restart-${Date.now().toString(36)}`,
      sessionId,
      mode: 'queue',
      content: [{ type: 'text', text }],
      clientTimeZone: 'Asia/Shanghai',
    },
  }
}

/** Exchange the endpoint's launch token for the cookie the API wants. */
async function authenticate(url) {
  const response = await fetch(url, { redirect: 'manual' })
  const header = response.headers.getSetCookie?.()[0] ?? response.headers.get('set-cookie')
  if (!header) throw new Error(`换 cookie 失败：HTTP ${response.status}`)
  return header.split(';')[0]
}

async function resumeSession(endpoint, sessionId, text) {
  if (!endpoint.url) throw new Error('endpoint.json 里没有带 token 的 url，无法换 cookie')
  const origin = new URL(endpoint.url)
  const cookie = await authenticate(origin.toString())
  const response = await fetch(`http://127.0.0.1:${endpoint.port}/api/session/prompt`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({
      type: 'client-request',
      rpcId: `restart-${Date.now().toString(36)}`,
      method: 'session/prompt',
      payload: { args: resumePayload(sessionId, text) },
    }),
  })
  const body = await response.json()
  if (body?.result?.ok !== true) {
    throw new Error(`session/prompt 被拒：${JSON.stringify(body?.result?.error ?? body).slice(0, 300)}`)
  }
}

async function main() {
  const statePath = process.argv[2]
  if (!statePath) {
    console.error('usage: dsh-restart-worker.mjs <state.json>')
    process.exit(2)
  }
  state = JSON.parse(readFileSync(statePath, 'utf8'))
  logPath = state.logPath || join(HOME, 'restart', 'worker.log')

  log(`worker start pid=${process.pid} from=${state.fromPid} port=${state.port} session=${state.sessionId}`)

  await sleep(state.delayMs ?? 3000)

  // 形态要在**杀之前**看清楚：进程一死，父进程就查不到了，实测因此把桌面版判成 unknown，
  // 走成"自己起一个 dsh web"，把桌面版的宿主进程留在了死状态。
  const form = state.hostForm ?? hostFormOf(state.fromPid)
  log(`宿主形态：${form}${state.hostForm ? '（排程时判定）' : '（杀进程前判定）'}`)

  // 桌面形态**不单独停宿主**：宿主是被应用监督的子进程，单独杀它会让应用弹恢复弹窗。
  // 让应用退出即可，宿主随应用一起走。
  let stopping
  if (form === 'desktop') {
    stopping = await quitDesktopApp({ log, hostPid: state.fromPid })
    log(`应用退出结果：${stopping}`)
  } else {
    stopping = await stop(state.fromPid)
    log(`backend ${state.fromPid} stopped (${stopping})`)
  }
  save({ status: 'stopped', stoppedAt: new Date().toISOString(), stop: stopping })

  // DSH.app is the parent of the backend it supervises, and it needs a moment to
  // notice the child is gone (the first real restart took ~30 s end to end). A
  // short wait here would start a second backend next to the app's own.
  let startedByUs
  // 官方桌面版不会自己把宿主进程拉回来（实测三次都没有），所以只做 5 秒探测就走重启流程；
  // 命令行 web 宿主可能由别人的终端持有，仍给它 25 秒。
  const respawnWindow = form === 'desktop' ? 5_000 : 25_000
  let endpoint = await waitForNewBackend({ previousPid: state.fromPid, timeoutMs: respawnWindow })
  if (endpoint) {
    log(`宿主自己把后端拉回来了：pid=${endpoint.pid} port=${endpoint.port}`)
  } else if (form === 'desktop') {
    // 应用与旧宿主都已经退干净，现在反复轻推直到新交接文件出现。
    endpoint = await relaunchUntilBackend({ log, previousPid: state.fromPid })
  } else {
    // 命令行 web 宿主的后端可能由用户的终端持有：我们起一个自己的。
    log('没有自动恢复；自己起一个 `dsh web --no-open --port 0`')
    const child = spawn('dsh', ['web', '--no-open', '--port', '0'], {
      detached: true,
      stdio: 'ignore',
      env: { ...process.env, DSH_DESKTOP_SHELL: '1' },
    })
    child.unref()
    startedByUs = child.pid
    endpoint = await waitForNewBackend({ previousPid: state.fromPid, timeoutMs: 60_000 })
  }

  if (!endpoint) {
    log(form === 'desktop'
      ? 'FAILED: 官方桌面版没能在 180s 内起来；需要人到电脑前打开它'
      : 'FAILED: 没有后端起来；需要人打开 DSH')
    save({ status: 'failed', failedAt: new Date().toISOString() })
    return
  }

  save({ status: 'up', newPid: endpoint.pid, newPort: endpoint.port, upAt: new Date().toISOString() })

  if (!state.sessionId) {
    log('no session to resume; done')
    save({ status: 'up-no-resume' })
    return
  }

  // The endpoint file appears before the plugin tree has settled, and a prompt
  // sent too early is refused as an unknown session. It is also re-read on every
  // attempt: DSH.app may replace the backend we found, and the file is the only
  // place that says so — with a new port and a new token.
  for (let attempt = 1; attempt <= 20; attempt += 1) {
    const freshest = readEndpoint() ?? endpoint
    if (freshest.pid !== endpoint.pid) {
      log(`endpoint moved to pid=${freshest.pid} port=${freshest.port} (updatedAt=${freshest.updatedAt})`)
      endpoint = freshest
      // If the app brought up its own backend after our fallback, ours is now the
      // orphan: two servers would both be listening, and only one is supervised.
      if (startedByUs && freshest.pid !== startedByUs && alive(startedByUs)) {
        const outcome = await stop(startedByUs)
        log(`our fallback backend ${startedByUs} retired (${outcome}); the app's own took over`)
        startedByUs = undefined
      }
    }
    try {
      await resumeSession(freshest, state.sessionId, state.resume)
      log(`resumed ${state.sessionId} on attempt ${attempt} (pid=${freshest.pid} port=${freshest.port})`)
      save({
        status: 'resumed',
        resumedAt: new Date().toISOString(),
        attempts: attempt,
        resumedPid: freshest.pid,
        resumedPort: freshest.port,
      })
      return
    } catch (error) {
      log(`resume attempt ${attempt} failed against pid=${freshest.pid} port=${freshest.port}: ${error.message}`)
      await sleep(1500)
    }
  }
  log('FAILED: could not resume the session')
  save({ status: 'up-resume-failed' })
}

const isDirectRun = process.argv[1] !== undefined && process.argv[1].endsWith('dsh-restart-worker.mjs')
if (isDirectRun) {
  main().catch((error) => {
    log(`worker crashed: ${error?.stack ?? error}`)
    save({ status: 'failed', error: String(error?.message ?? error) })
  })
}

export { main }

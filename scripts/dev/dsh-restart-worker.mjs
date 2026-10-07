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
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
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

/** 官方桌面版：退出整个应用再打开（它的宿主是应用自己拉起的，杀了不会自己回来）。 */
async function relaunchDesktopApp({ log = () => {} } = {}) {
  log('宿主是官方桌面版：退出应用再打开')
  try {
    execFileSync('osascript', ['-e', 'quit app "DeepSeek Harness"'], { stdio: 'ignore' })
  } catch (error) {
    log(`osascript 退出失败（改用信号）：${error.message}`)
  }
  for (let waited = 0; waited < 8000; waited += 500) {
    try {
      execFileSync('pgrep', ['-f', 'DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'], { stdio: 'ignore' })
    } catch {
      break // 已经退出
    }
    await sleep(500)
  }
  try {
    execFileSync('pkill', ['-TERM', '-f', 'DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'], { stdio: 'ignore' })
  } catch { /* 已经没了 */ }
  await sleep(1500)
  execFileSync('open', ['-a', 'DeepSeek Harness'], { stdio: 'ignore' })
  log('已请求重新打开官方桌面版')
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

  const stopping = await stop(state.fromPid)
  log(`backend ${state.fromPid} stopped (${stopping})`)
  save({ status: 'stopped', stoppedAt: new Date().toISOString(), stop: stopping })

  // DSH.app is the parent of the backend it supervises, and it needs a moment to
  // notice the child is gone (the first real restart took ~30 s end to end). A
  // short wait here would start a second backend next to the app's own.
  let startedByUs
  let endpoint = await waitForNewBackend({ previousPid: state.fromPid, timeoutMs: 25_000 })
  if (endpoint) {
    log(`宿主自己把后端拉回来了：pid=${endpoint.pid} port=${endpoint.port}`)
  } else if (form === 'desktop') {
    // 官方桌面版：后端是它自己 spawn 的，杀了不会自己回来——退出应用再打开，
    // 这与"人手动关了重开"等价，而且两个档案都不会串。
    await relaunchDesktopApp({ log })
    endpoint = await waitForNewBackend({ previousPid: state.fromPid, timeoutMs: 90_000 })
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
      ? 'FAILED: 官方桌面版没能在 90s 内起来；需要人到电脑前打开它'
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

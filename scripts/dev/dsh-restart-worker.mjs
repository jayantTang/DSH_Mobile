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
const ENDPOINT = join(HOME, 'desktop-shell', 'endpoint.json')

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

/** The port/pid the backend last handed out; `undefined` when the file is gone. */
export function readEndpoint(path = ENDPOINT) {
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8'))
    if (!parsed?.port) return undefined
    return { port: Number(parsed.port), pid: Number(parsed.pid) || undefined }
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
  const origin = new URL(endpoint.url ?? `http://127.0.0.1:${endpoint.port}/`)
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

  const stopping = await stop(state.fromPid)
  log(`backend ${state.fromPid} stopped (${stopping})`)
  save({ status: 'stopped', stoppedAt: new Date().toISOString(), stop: stopping })

  let endpoint = await waitForNewBackend({ previousPid: state.fromPid, timeoutMs: 12_000 })
  if (endpoint) {
    log(`DSH.app respawned the backend: pid=${endpoint.pid} port=${endpoint.port}`)
  } else {
    // The app did not bring it back on its own. Asking the app to open is the
    // closest thing to the user quitting and reopening it.
    log('no respawn yet; asking DSH.app to open')
    try {
      execFileSync('open', ['-a', 'DSH'], { stdio: 'ignore' })
    } catch (error) {
      log(`open -a DSH failed: ${error.message}`)
    }
    endpoint = await waitForNewBackend({ previousPid: state.fromPid, timeoutMs: 20_000 })
  }

  if (!endpoint) {
    // Last resort: become the backend ourselves. DSH.app may later spawn its own;
    // endpoint.json is the handoff every client follows, so whichever is written
    // last is the one the phone talks to.
    log('still nothing; starting `dsh web --no-open --port 0` ourselves')
    const child = spawn('dsh', ['web', '--no-open', '--port', '0'], {
      detached: true,
      stdio: 'ignore',
      env: { ...process.env, DSH_DESKTOP_SHELL: '1' },
    })
    child.unref()
    endpoint = await waitForNewBackend({ previousPid: state.fromPid, timeoutMs: 60_000 })
  }

  if (!endpoint) {
    log('FAILED: no backend came up; a human has to open DSH')
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
  // sent too early is refused as an unknown session.
  for (let attempt = 1; attempt <= 20; attempt += 1) {
    try {
      await resumeSession(endpoint, state.sessionId, state.resume)
      log(`resumed ${state.sessionId} on attempt ${attempt}`)
      save({ status: 'resumed', resumedAt: new Date().toISOString(), attempts: attempt })
      return
    } catch (error) {
      log(`resume attempt ${attempt} failed: ${error.message}`)
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

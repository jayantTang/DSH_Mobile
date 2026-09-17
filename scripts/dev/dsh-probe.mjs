#!/usr/bin/env node
/**
 * Small DSH helper for the UI-test harness.
 *
 * The UI tests run inside the simulator and cannot read this Mac's
 * ~/.dsh/desktop-shell/endpoint.json, so anything that needs the live host —
 * picking a session with real history, creating a throwaway one, cleaning it up
 * again — is done here and handed to the tests as environment variables.
 *
 * Subcommands:
 *   endpoint                 print "<port> <token>"
 *   pick-rich                print the id of the session with the most history
 *   create-scratch           create an isolated session and print its id
 *   cleanup <sessionId>      remove that session from disk
 *   mint-code                print one pairing code
 *   mint-codes <dir> <n>     mint n codes into <dir>/01, 02, … (one per pairing)
 */

import { mkdirSync, readFileSync, rmSync, existsSync, readdirSync, writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = homedir()
const ENDPOINT = join(HOME, '.dsh', 'desktop-shell', 'endpoint.json')

// 仓库里只有占位符地址（relay.example.com），真值放仓库根的 .env.local（不入库）。
// 这里补一层最小加载：只填没设过的变量，不覆盖调用方显式传进来的值。
const ENV_FILE = join(import.meta.dirname, '..', '..', '.env.local')
if (existsSync(ENV_FILE)) {
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    if (line.trimStart().startsWith('#')) continue
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line)
    if (!match) continue
    const [, key, raw] = match
    if (process.env[key] === undefined) process.env[key] = raw.replace(/^(['"])(.*)\1$/, '$2')
  }
}

function endpoint() {
  const raw = JSON.parse(readFileSync(ENDPOINT, 'utf8'))
  const token = /token=([^&]+)/.exec(raw.url)?.[1]
  if (!token) throw new Error('endpoint.json carries no launch token')
  return { port: raw.port ?? 54499, token }
}

async function cookie() {
  const { port, token } = endpoint()
  const res = await fetch(`http://127.0.0.1:${port}/?token=${token}`, { redirect: 'manual' })
  const header = res.headers.getSetCookie?.()[0] ?? res.headers.get('set-cookie')
  if (!header) throw new Error(`token exchange failed with HTTP ${res.status}`)
  return { port, cookie: header.split(';')[0] }
}

let rpcSeq = 0
async function rpc(method, args) {
  const { port, cookie: c } = await cookie()
  const res = await fetch(`http://127.0.0.1:${port}/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie: c },
    body: JSON.stringify({ type: 'client-request', rpcId: `ui${++rpcSeq}`, method, payload: { args } }),
  })
  const json = await res.json()
  if (!json.result?.ok) throw new Error(`${method}: ${JSON.stringify(json.result?.error)}`)
  return json.result.value
}

/**
 * Mints one pairing code through the connector's own pairing path.
 *
 * The agent identity is read from this machine's own file — never from a
 * literal here. A commit is forever and a shared repository is the easiest way
 * to leak a credential without noticing.
 */
function mintCode() {
  const identityPath = join(homedir(), '.dsh', 'mobile-link', 'agent.json')
  const identity = existsSync(identityPath)
    ? JSON.parse(readFileSync(identityPath, 'utf8'))
    : {}
  const agentId = process.env.DSH_AGENT_ID ?? identity.agentId
  const agentSecret = process.env.DSH_AGENT_SECRET ?? identity.agentSecret
  if (!agentId || !agentSecret) {
    throw new Error(
      `no agent identity: set DSH_AGENT_ID/DSH_AGENT_SECRET or write ${identityPath}`,
    )
  }

  const out = execFileSync('node', [
    // `plugins/`, not the old `agent/`: the directory was renamed and this path
    // was left behind, so minting a code — which is what puts the simulator on
    // the relay channel — failed with ENOENT.
    join(import.meta.dirname, '..', '..', 'plugins', 'mobile-link', 'lib', 'cli.js'),
    '--mint-pair-code', '--relay', process.env.DSH_RELAY_URL ?? 'wss://relay.example.com/dsh-link',
    '--agent-id', agentId,
    '--agent-secret', agentSecret,
  ], { encoding: 'utf8' })
  return JSON.parse(out).code
}

const [, , command, argument] = process.argv

switch (command) {
  case 'endpoint': {
    const { port, token } = endpoint()
    // A trailing newline matters: `read` returns non-zero at EOF, which a
    // `set -e` caller treats as a failure.
    console.log(`${port} ${token}`)
    break
  }

  case 'pick-rich': {
    // A session with plenty of history, preferring one that is NOT running.
    //
    // The read-only tests drive scrolling and keyboard changes; pointed at a
    // session that is streaming at the same time, every query races the app's
    // own rendering and the suite flakes. A settled session still exercises the
    // same rendering, deterministically.
    const list = await rpc('session/list', { _request: {} })
    const pool = list.items.filter(
      (s) => s.origin !== 'subagent' && !s.blank && s.cwd
        // Also skip the harness's own workspace: those are throwaways.
        && !(s.cwd ?? '').includes('uitest-workspace'),
    )
    const byHistory = (a, b) =>
      ((b.projections || {}).asOfSeq || 0) - ((a.projections || {}).asOfSeq || 0)
    const settled = pool.filter((s) => !s.running).sort(byHistory)
    const fallback = [...pool].sort(byHistory)
    console.log((settled[0] ?? fallback[0])?.sessionId ?? '')
    break
  }

  case 'mint-code': {
    console.log(mintCode())
    break
  }

  case 'mint-codes': {
    // One code per pairing: a code is single-use, so a suite that pairs several
    // times needs several. Minted here, on the Mac, because a UI test runs
    // inside the simulator and cannot spawn this script from there.
    const dir = argument
    const count = Number(process.argv[4] ?? 1)
    if (!dir || !Number.isInteger(count) || count < 1) {
      throw new Error('usage: dsh-probe.mjs mint-codes <dir> <count>')
    }
    rmSync(dir, { recursive: true, force: true })
    mkdirSync(dir, { recursive: true })
    const codes = Array.from({ length: count }, () => mintCode())
    codes.forEach((code, index) => {
      writeFileSync(join(dir, String(index + 1).padStart(2, '0')), `${code}\n`)
    })
    console.log(`${codes.length} 个配对码 -> ${dir}`)
    break
  }

  case 'pick-images': {
    // The session with the most image attachments, so the rendering tests have
    // something real to draw.
    const list = await rpc('session/list', { _request: {} })
    let best = ''
    let bestCount = 0
    for (const s of list.items) {
      if (s.origin === 'subagent' || s.blank) continue
      if ((s.cwd ?? '').includes('uitest-workspace')) continue
      const through = s.projections?.asOfSeq || 0
      if (!through) continue
      let page
      try {
        page = await rpc('session/page', {
          request: { address: { kind: 'session', sessionId: s.sessionId }, throughSeq: through, maxMessages: 80 },
        })
      } catch {
        continue
      }
      let count = 0
      const walk = (blocks) => {
        for (const b of blocks ?? []) {
          if (b?.type === 'image') count += 1
          if (b?.content) walk(b.content)
        }
      }
      for (const rec of page.records) {
        const d = rec.event.data
        walk(d?.content)
        walk(d?.message?.content)
        walk(d?.inserted?.[0]?.content)
      }
      if (count > bestCount) { bestCount = count; best = s.sessionId }
    }
    console.log(best)
    break
  }

  case 'pick-phone': {
    // The session with the most messages that were submitted from the phone.
    // Those are recognisable by their request id: the iOS client mints them
    // with Swift's `UUID().uuidString`, which is upper case, while the desktop
    // client's are lower case.
    const list = await rpc('session/list', { _request: {} })
    const candidates = list.items
      .filter((s) => s.origin !== 'subagent' && !s.blank && !(s.cwd ?? '').includes('uitest-workspace'))
      .sort((a, b) => (b.projections?.asOfSeq || 0) - (a.projections?.asOfSeq || 0))
      .slice(0, 12)
    let best = ''
    let bestCount = 0
    for (const s of candidates) {
      const through = s.projections?.asOfSeq || 0
      if (!through) continue
      let page
      try {
        page = await rpc('session/page', {
          request: { address: { kind: 'session', sessionId: s.sessionId }, throughSeq: through, maxMessages: 200 },
        })
      } catch {
        continue
      }
      const phone = page.records.filter((r) => {
        const e = r.event
        if (e.type !== 'user/message') return false
        const rpc = e.data?.source?.rpcId
        return typeof rpc === 'string' && /[A-F]/.test(rpc) && !/[a-f]/.test(rpc)
      }).length
      if (phone > bestCount) { bestCount = phone; best = s.sessionId }
    }
    console.log(best)
    break
  }

  case 'create-scratch': {
    // A dedicated workspace so the throwaway session groups on its own and is
    // trivially recognisable when it is cleaned up.
    const dir = join(HOME, '.dsh', 'uitest-workspace')
    const created = await rpc('session/create', { request: { cwd: dir, agentPreset: 'standard' } })
    console.log(created.sessionId ?? created.id ?? '')
    break
  }

  case 'cleanup-workspace': {
    // Cancel before deleting. A test that is torn down mid-turn leaves the host
    // believing the session is still running, and because `session/list` reads
    // the host's live registry, that phantom survives the file removal and
    // shows up as "N running" on every client until the host restarts.
    try {
      const list = await rpc('session/list', { _request: {} })
      const mine = list.items.filter(
        (s) => (s.cwd ?? '').includes('uitest-workspace') || (s.cwd ?? '') === '/tmp',
      )
      for (const s of mine) {
        if (s.running) await rpc('session/cancel', { request: { sessionId: s.sessionId } })
      }
      if (mine.some((s) => s.running)) {
        process.stderr.write(`cancelled ${mine.filter((s) => s.running).length} stray turn(s)\n`)
      }
    } catch {
      // Best effort: the file removal below still runs.
    }
    // Every session the suite created lives under the dedicated test
    // workspace, so the whole group can be removed in one go — including
    // sessions created by tests themselves, which the shell script never sees.
    const group = join(HOME, '.dsh', 'sessions', '--Users-jayanttang-.dsh-uitest-workspace--')
    let removed = 0
    if (existsSync(group)) {
      for (const id of readdirSync(group)) {
        rmSync(join(group, id), { recursive: true, force: true })
        const cache = join(HOME, '.dsh', 'storages', 'session_projcache', 'sessions', `${id}.json`)
        if (existsSync(cache)) rmSync(cache, { force: true })
        removed += 1
      }
      rmSync(group, { recursive: true, force: true })
    }
    rmSync(join(HOME, '.dsh', 'uitest-workspace'), { recursive: true, force: true })
    console.log(`cleaned UI-test workspace (${removed} sessions)`)
    break
  }

  case 'cleanup': {
    const id = argument
    if (!id) throw new Error('cleanup needs a session id')
    const sessionsRoot = join(HOME, '.dsh', 'sessions')
    let removed = 0
    for (const group of readdirSync(sessionsRoot)) {
      const dir = join(sessionsRoot, group, id)
      if (existsSync(dir)) {
        rmSync(dir, { recursive: true, force: true })
        removed += 1
      }
    }
    const cache = join(HOME, '.dsh', 'storages', 'session_projcache', 'sessions', `${id}.json`)
    if (existsSync(cache)) {
      rmSync(cache, { force: true })
      removed += 1
    }
    console.log(`cleaned ${id} (${removed} entries)`)
    break
  }

  default:
    process.stderr.write(`unknown command: ${command}\n`)
    process.exit(2)
}

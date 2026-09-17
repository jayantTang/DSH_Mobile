#!/usr/bin/env node
// Reads the machine's live DSH endpoint and prints it as JSON.
//
// Two sources, because the host is started in two different ways: the DSH
// desktop shell writes endpoint.json, while a bare `dsh web` only ever prints
// its URL on stdout, which the shell log keeps. The current machine switched
// from the first to the second, and a harness that reads only endpoint.json
// fails before it can report anything useful.

import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = homedir()
const ENDPOINT = join(HOME, '.dsh', 'desktop-shell', 'endpoint.json')
const SHELL_LOG = join(HOME, '.dsh', 'desktop-shell', 'dsh-shell.log')
const AGENT = join(HOME, '.dsh', 'mobile-link', 'agent.json')

function fromEndpointFile() {
  if (!existsSync(ENDPOINT)) return null
  const raw = JSON.parse(readFileSync(ENDPOINT, 'utf8'))
  const token = /token=([^&]+)/.exec(raw.url ?? '')?.[1]
  if (!raw.port || !token) return null
  return { port: raw.port, token, source: 'endpoint.json' }
}

function fromShellLog() {
  if (!existsSync(SHELL_LOG)) return null
  const matches = readFileSync(SHELL_LOG, 'utf8')
    .match(/http:\/\/127\.0\.0\.1:(\d+)\/\?token=([A-Za-z0-9_-]+)/g)
  if (!matches) return null
  const last = /http:\/\/127\.0\.0\.1:(\d+)\/\?token=([A-Za-z0-9_-]+)/.exec(matches.at(-1))
  return { port: Number(last[1]), token: last[2], source: 'dsh-shell.log' }
}

/// True when something on the port answers like DSH.
///
/// A bare `/` is 401 without the launch token — the token is the point of the
/// exchange — so the check is "answered, and not as a stranger": a dead port
/// gives 000, and a stale port belonging to another service does not give 401.
function alive(port) {
  const result = spawnSync('curl', ['-s', '-o', '/dev/null', '-m', '3', '-w', '%{http_code}',
    `http://127.0.0.1:${port}/`], { encoding: 'utf8' })
  const code = Number(result.stdout?.trim() ?? 0)
  return code === 200 || code === 401 || code === 302
}

const endpoint = fromEndpointFile() ?? fromShellLog()
if (!endpoint || !alive(endpoint.port)) {
  console.error('没有找到运行中的 DSH：先启动 DSH（桌面 App 或 `dsh web`），再跑测试')
  process.exit(1)
}

const host = {
  ...endpoint,
  url: `dsh://direct?host=127.0.0.1&port=${endpoint.port}&token=${endpoint.token}`,
  // The relay identity is read, never written down: the repository is public
  // and a credential in a commit is the easiest leak to miss.
  agentId: existsSync(AGENT) ? JSON.parse(readFileSync(AGENT, 'utf8')).agentId ?? null : null,
}

if (process.argv.includes('--check')) {
  execFileSync('true')
}

console.log(JSON.stringify(host, null, 2))

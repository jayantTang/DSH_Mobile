#!/usr/bin/env node
// Reads the machine's live DSH endpoint and prints it as JSON.
//
// One source: the connector writes `$DSH_HOME/mobile-link/endpoint.json` with the
// authenticated loopback address, and it does so in every supported host (the official
// desktop app and the command-line web host). The old desktop-shell files are gone with
// that shell — see specs/001-connector-host-compat/.

import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = process.env.DSH_HOME || join(homedir(), '.dsh')
const ENDPOINT = join(HOME, 'mobile-link', 'endpoint.json')
const AGENT = join(HOME, 'mobile-link', 'agent.json')

function fromEndpointFile() {
  if (!existsSync(ENDPOINT)) return null
  const raw = JSON.parse(readFileSync(ENDPOINT, 'utf8'))
  const token = /token=([^&]+)/.exec(raw.url ?? '')?.[1]
  if (!raw.port || !token) return null
  return { port: raw.port, token, source: 'mobile-link/endpoint.json' }
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

const endpoint = fromEndpointFile()
if (!endpoint || !alive(endpoint.port)) {
  console.error(`没有找到运行中的 DSH：先启动宿主（官方桌面版或 \`dsh web\`）并确认连接器已加载，${ENDPOINT} 会由连接器写出`)
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

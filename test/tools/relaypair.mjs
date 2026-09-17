#!/usr/bin/env node
// Pairs a device with the relay the way the product does, and hands the caller
// the credential — so the run that used it can revoke it again.
//
// Why the *runner* claims the code and not the app: a pairing code is one-time,
// so whoever claims it is the only party that learns the device id. When the app
// claimed it, every simulator run left a paired device on the relay that nobody
// could clean up — the user's device list slowly filled with `DSH-Test` rows.
// Claiming here keeps the whole lifecycle in one place: pair when the run needs
// the relay channel, revoke in a `finally` when it ends.
//
// The identity is read from this machine's own connector file, never written
// here: the repository is public and a credential in a commit is the leak that
// is easiest to miss.

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const IDENTITY = join(homedir(), '.dsh', 'mobile-link', 'agent.json')
const CLI = join(import.meta.dirname, '..', '..', 'plugins', 'mobile-link', 'lib', 'cli.js')

/// The connector's own relay identity and address.
export function identity() {
  if (!existsSync(IDENTITY)) throw new Error(`没有连接器身份：${IDENTITY}`)
  const raw = JSON.parse(readFileSync(IDENTITY, 'utf8'))
  if (!raw.relayUrl || !raw.agentId || !raw.agentSecret) {
    throw new Error(`${IDENTITY} 缺少 relayUrl/agentId/agentSecret`)
  }
  return raw
}

/// The relay's HTTP origin, with the mount prefix kept.
///
/// The relay is published under a path (`…/dsh-link`) so it can share an
/// existing domain; every route is appended to that prefix, never replaces it.
/// Mirrors `LinkConfiguration.normalizedRelayURL` + `appending(path:to:)`.
export function httpBase(relayUrl) {
  const url = new URL(relayUrl)
  url.protocol = url.protocol === 'wss:' ? 'https:' : url.protocol === 'ws:' ? 'http:' : url.protocol
  url.search = ''
  url.hash = ''
  return url
}

function route(relayUrl, suffix) {
  const base = httpBase(relayUrl)
  const prefix = base.pathname.replace(/\/+$/, '')
  base.pathname = `${prefix}${suffix}`
  return base
}

async function post(url, body, token) {
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  })
  const text = await response.text()
  let parsed = null
  try { parsed = JSON.parse(text) } catch { /* a non-JSON body is reported below */ }
  if (!response.ok || parsed?.ok === false) {
    const detail = parsed?.error ? JSON.stringify(parsed.error) : text.slice(0, 200)
    throw new Error(`${url.pathname} HTTP ${response.status}: ${detail}`)
  }
  return parsed
}

/// Mints a one-time pairing code through the connector's own pairing path.
export function mintPairCode({ relayUrl = identity().relayUrl } = {}) {
  const who = identity()
  const out = execFileSync('node', [
    CLI, '--mint-pair-code', '--relay', relayUrl,
    '--agent-id', who.agentId, '--agent-secret', who.agentSecret,
  ], { encoding: 'utf8' })
  const minted = JSON.parse(out)
  if (!minted.code) throw new Error(`配对码没有生成：${out.slice(0, 200)}`)
  return minted
}

/// Mints a code, claims it, and returns the device the relay now knows about.
///
/// `deviceName` is what the user sees in their device list, so the run's device
/// is identifiable while it exists — it says what it is, rather than looking
/// like a phone that lost its way.
export async function pairDevice({
  deviceName = 'DSH-Test',
  deviceModel = 'simulator',
  appVersion = 'test-harness',
} = {}) {
  const who = identity()
  const minted = mintPairCode({ relayUrl: who.relayUrl })
  const claim = await post(route(who.relayUrl, '/pair/claim'), {
    pairCode: minted.code,
    deviceName,
    deviceModel,
    appVersion,
  })
  return {
    relayUrl: who.relayUrl,
    agentId: claim.agentId,
    agentName: claim.agentName ?? deviceName,
    deviceId: claim.deviceId,
    deviceToken: claim.deviceToken,
  }
}

/// Revokes one device, authenticated as another device of the same agent.
export async function revokeDevice({ relayUrl, deviceToken, deviceId }) {
  await post(route(relayUrl, '/devices/revoke'), { deviceId }, deviceToken)
}

/// The devices the relay currently lists for this agent.
export async function listDevices({ relayUrl, deviceToken }) {
  const url = route(relayUrl, '/devices')
  const response = await fetch(url, { headers: { authorization: `Bearer ${deviceToken}` } })
  const body = await response.json()
  if (!response.ok || body?.ok === false) throw new Error(`/devices HTTP ${response.status}`)
  return body
}

/// The launch argument that carries a claimed credential into the app.
///
/// Same channel as the other connect links, so a case does not have to know how
/// the device was paired. The app accepts this shape in Debug builds only.
export function claimedRelayLink(pairing) {
  const query = new URLSearchParams({
    relay: pairing.relayUrl,
    agent: pairing.agentId,
    token: pairing.deviceToken,
    name: pairing.agentName ?? '',
  })
  return `dsh://relay?${query.toString()}`
}

// ---------------------------------------------------------------- CLI
//
// Guarded: this module is imported by `run.mjs`, and an unguarded argument
// switch here would read *its* command line and exit the harness.

const isMain = import.meta.url === `file://${process.argv[1]}`
const [command, ...rest] = isMain ? process.argv.slice(2) : []
if (isMain && command === 'pair') {
  const pairing = await pairDevice()
  console.log(JSON.stringify({ ...pairing, link: claimedRelayLink(pairing) }, null, 2))
} else if (isMain && command === 'list') {
  // Maintenance: list what the relay thinks is paired, given any live token.
  const [token] = rest
  console.log(JSON.stringify(await listDevices({ relayUrl: identity().relayUrl, deviceToken: token }), null, 2))
} else if (isMain && command === 'revoke') {
  const [token, ...ids] = rest
  for (const deviceId of ids) {
    await revokeDevice({ relayUrl: identity().relayUrl, deviceToken: token, deviceId })
    console.log(`revoked ${deviceId}`)
  }
} else if (isMain && command) {
  console.error('用法: relaypair.mjs pair | list <deviceToken> | revoke <deviceToken> <deviceId…>')
  process.exit(2)
}

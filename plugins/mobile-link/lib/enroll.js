/**
 * First-run enrollment: turn an invite code into a durable agent identity.
 *
 * Until now an identity could only be provisioned by whoever owns the relay
 * (`dsh-relay admin agent-register --write-config`). That does not distribute:
 * somebody else installs DSH plus this connector on their own computer and has
 * to be handed a credential by the operator, out of band.
 *
 * So the relay grew `POST /agents/enroll` (relay-go/internal/httpapi), which redeems a
 * one-time invite code for a fresh `agentId` / `agentSecret`. This module is the
 * connector half: one call, then the identity is written to the same
 * `~/.dsh/mobile-link/agent.json` (mode 0600) that `agent-register` writes, so
 * nothing downstream can tell the two apart.
 *
 * Enrollment is deliberately *not* automatic against an open endpoint: an
 * invite code must be present, because the relay is on the public internet.
 */

import { execFileSync } from 'node:child_process'
import { hostname, networkInterfaces } from 'node:os'

import { agentMachineEndpoint, enrollEndpoint, isPlaceholderRelayUrl, normalizeRelayUrl } from './dlp.js'
import { DEFAULT_AGENT_NAME, INVITE_ENV, defaultStatePath, readState, writeState } from './state.js'

/**
 * Normalize a MAC-48 address to uppercase colon form.
 * Returns '' for anything that is not a MAC.
 */
export function normalizeMacAddress(value) {
  const compact = String(value ?? '').trim().replace(/[-.:\s]/g, '').toUpperCase()
  if (!/^[0-9A-F]{12}$/.test(compact)) return ''
  return compact.match(/.{2}/g).join(':')
}

/**
 * Pick the computer's primary physical interface MAC.
 *
 * This is an *identifier*, not an authenticator: a MAC can be spoofed. It is
 * used only so the relay can associate repeat enrollments of the same machine.
 * Virtual/VPN interfaces are skipped (they change or reflect tunnels), and
 * common primary interface names win over the rest. If nothing is found the
 * field is omitted rather than inventing a value.
 */
export function primaryMacAddress(interfaces) {
  // macOS 的 Node 经常只拿到 02:00:00:00:00:00（系统隐私/沙箱占位），
  // 而 networksetup 仍能读到真实硬件地址；优先向它要，读不到再走接口枚举。
  if (interfaces === undefined && process.platform === 'darwin') {
    const mac = darwinMacAddress()
    if (mac) return mac
  }
  const virtual = /^(lo|docker|veth|br-|virbr|vmnet|vboxnet|utun|tun|tap|wg|tailscale|zt|bridge|awdl|llw)/i
  const preferred = /^(en0|eth0|wlan0|wi-?fi|ethernet)$/i
  const seen = new Set()
  const candidates = []
  for (const [name, entries] of Object.entries(interfaces ?? networkInterfaces())) {
    if (!entries || virtual.test(name)) continue
    for (const entry of entries) {
      if (!entry || entry.internal) continue
      const mac = normalizeMacAddress(entry.mac)
      if (!mac || mac === '00:00:00:00:00:00' || mac === '02:00:00:00:00:00' || seen.has(mac)) continue
      seen.add(mac)
      candidates.push({ name, mac, preferred: preferred.test(name) ? 0 : 1 })
    }
  }
  candidates.sort((a, b) => a.preferred - b.preferred || a.name.localeCompare(b.name))
  return candidates[0]?.mac ?? ''
}

/// macOS 的硬件端口表是唯一能稳定拿到真实 MAC 的入口：Node 的
/// `os.networkInterfaces()` 在部分系统上被隐私层替换成 02:00:00:00:00:00。
function darwinMacAddress() {
  const activeDevice = darwinDefaultInterface()
  let output
  try {
    output = execFileSync('/usr/sbin/networksetup', ['-listallhardwareports'], {
      encoding: 'utf8', timeout: 2000, stdio: ['ignore', 'pipe', 'ignore'],
    })
  } catch {
    return ''
  }
  const blocks = []
  let current = {}
  const flush = () => {
    if (current.mac) blocks.push(current)
    current = {}
  }
  for (const line of output.split('\n')) {
    const match = line.match(/^\s*(Hardware Port|Device|Ethernet Address):\s*(.+?)\s*$/)
    if (!match) continue
    if (match[1] === 'Hardware Port') {
      flush()
      current.port = match[2]
    }
    if (match[1] === 'Device') current.device = match[2]
    if (match[1] === 'Ethernet Address') current.mac = normalizeMacAddress(match[2])
  }
  flush()
  const active = blocks.find((block) => block.device === activeDevice)
  if (active?.mac) return active.mac
  const preferred = /(wi-?fi|ethernet|lan)/i
  const chosen = blocks.find((block) => preferred.test(block.port ?? block.device ?? ''))
  return chosen?.mac ?? blocks[0]?.mac ?? ''
}

/// 默认路由对应的接口：优先用它，避免机器同时插网线和 Wi-Fi 时选到未使用的网口。
function darwinDefaultInterface() {
  try {
    const output = execFileSync('/sbin/route', ['-n', 'get', 'default'], {
      encoding: 'utf8', timeout: 2000, stdio: ['ignore', 'pipe', 'ignore'],
    })
    return output.match(/^\s*interface:\s*(\S+)/m)?.[1] ?? ''
  } catch {
    return ''
  }
}

/**
 * A failed enrollment, tagged with a machine-readable code.
 *
 * The CLI prints `.message`; the panel maps `.code` to Chinese copy. Keeping both
 * on one error is deliberate: the relay's three invite failures need different
 * advice, and the UI must not re-parse English text to find out which one it got.
 */
export class EnrollError extends Error {
  constructor(code, message, { status, retryable = false, stateFile } = {}) {
    super(message)
    this.name = 'EnrollError'
    this.code = code
    this.status = status
    this.retryable = Boolean(retryable)
    if (stateFile) this.stateFile = stateFile
  }
}

/** How long a relay may take to answer an enrollment before it is called stuck. */
export const ENROLL_TIMEOUT_MS = 15000

/** Where the invite code may come from: explicit argument, then environment. */
export function inviteFrom({ inviteCode, env = process.env } = {}) {
  const value = typeof inviteCode === 'string' && inviteCode.trim() ? inviteCode : env?.[INVITE_ENV]
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}

/**
 * Whether an enrollment should be attempted, and with what code.
 *
 * Enrollment happens only when there is no identity yet; an existing identity is
 * never replaced behind the user's back (that would silently unpair every phone
 * they had already paired).
 */
export async function enrollPlan({ stateFile, inviteCode, relayUrl, env = process.env } = {}) {
  const path = stateFile || defaultStatePath()
  const existing = await readState(path)
  if (existing?.agentId && existing?.agentSecret) {
    return { needed: false, stateFile: path, agentId: existing.agentId }
  }
  const invite = inviteFrom({ inviteCode, env })
  const relay = relayUrl || env?.DSH_MOBILE_LINK_RELAY || ''
  return { needed: true, stateFile: path, invite, relayUrl: relay, canEnroll: Boolean(relay) }
}

/**
 * Redeem one invite code and persist the resulting identity.
 *
 * The state file is written **after** the relay has answered, and atomically, so
 * a failure anywhere leaves whatever was there before untouched.
 *
 * @param {object} options
 * @param {string} options.relayUrl relay origin, e.g. `wss://host/dsh-link`
 * @param {string} options.inviteCode the one-time code
 * @param {string} [options.name] what this computer is called on the phone
 * @param {string} [options.stateFile] override, for tests and `$DSH_HOME`
 * @param {typeof fetch} [options.fetchImpl] injectable for tests
 * @returns {Promise<{agentId: string, agentSecret: string, agentName: string, relayUrl: string, stateFile: string}>}
 */
export async function enrollAgent({
  relayUrl, inviteCode, name, stateFile, deviceName, macAddress,
  fetchImpl = fetch, logger = undefined, timeoutMs = ENROLL_TIMEOUT_MS,
} = {}) {
  const invite = typeof inviteCode === 'string' ? inviteCode.trim() : ''
  if (!relayUrl || !String(relayUrl).trim()) {
    throw new EnrollError('enroll/bad-request', 'mobile-link: a relay URL is required to enroll (--relay <url>)')
  }
  // Validate before the network call: a typo in the relay address should not
  // look like a rejected invite, and the placeholder shipped in the repository
  // must never be dialed as if it were a deployment.
  try {
    normalizeRelayUrl(relayUrl)
  } catch (error) {
    throw new EnrollError('enroll/invalid-relay',
      `mobile-link: invalid relay URL ${JSON.stringify(relayUrl)}: ${messageOf(error)}`)
  }
  if (isPlaceholderRelayUrl(relayUrl)) {
    throw new EnrollError('enroll/placeholder-relay',
      'mobile-link: the relay address is the repository placeholder; use the address your provider gave you')
  }

  const path = stateFile || defaultStatePath()
  const agentName = (name || deviceName || '').trim() || hostname().trim() || DEFAULT_AGENT_NAME
  const machineMac = normalizeMacAddress(macAddress ?? primaryMacAddress())
  const waitMs = Number.isFinite(Number(timeoutMs)) && Number(timeoutMs) > 0
    ? Number(timeoutMs)
    : ENROLL_TIMEOUT_MS

  // `Promise.race` rather than relying on the signal alone: an injected fetch
  // (or a runtime that does not honour AbortSignal) must still surface a
  // timeout instead of leaving the panel on "登记中" forever.
  const controller = new AbortController()
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort()
      reject(new EnrollError('enroll/timeout',
        `mobile-link: the relay did not answer within ${waitMs} ms`, { retryable: true }))
    }, waitMs)
    // Deliberately NOT unref'd: if an injected fetch holds no handle, an unref'd
    // timer lets Node decide the event loop is empty and exit with the promise
    // still pending (caught by the Linux L2 run). The timer is cleared on every
    // settled fetch, so it only keeps the process alive while a request is
    // genuinely outstanding.
  })

  let response
  try {
    response = await Promise.race([
      fetchImpl(enrollEndpoint(relayUrl), {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        // 有邀请码就带上（老的邀请码发放方式仍可用）；没有就是开放登记。
        body: JSON.stringify({
          ...(invite ? { inviteCode: invite } : {}),
          name: agentName,
          ...(machineMac ? { macAddress: machineMac } : {}),
        }),
        signal: controller.signal,
      }),
      timeout,
    ])
  } catch (error) {
    if (error instanceof EnrollError) throw error
    throw new EnrollError('enroll/unreachable',
      `mobile-link: cannot reach the relay at ${relayUrl}: ${messageOf(error)}`, { retryable: true })
  } finally {
    clearTimeout(timer)
  }

  let body
  try {
    body = await response.json()
  } catch {
    throw new EnrollError('enroll/bad-response',
      `mobile-link: the relay answered HTTP ${response.status} to /agents/enroll`,
      { status: response.status })
  }
  if (!response.ok || body?.ok !== true || !body.agentId || !body.agentSecret) {
    const code = body?.error?.code
    throw new EnrollError(typeof code === 'string' && code ? code : 'enroll/relay-error',
      describeEnrollFailure(body, response.status), {
        status: response.status,
        retryable: code === 'enroll/rate-limited' || code === 'enroll/store-error' || code === 'internal/error',
      })
  }

  try {
    await writeState(path, {
      relayUrl,
      agentId: body.agentId,
      agentSecret: body.agentSecret,
      agentName: body.agentName || agentName,
    })
  } catch (error) {
    // The code has already been redeemed at this point. Say so explicitly:
    // retrying with the same code will fail with "already used", and the person
    // needs to know the identity could not be saved (and where).
    throw new EnrollError('enroll/state-write',
      `mobile-link: the identity was redeemed but could not be saved to ${path}: ${messageOf(error)}`,
      { stateFile: path })
  }
  logger?.info?.(`mobile-link: enrolled as ${body.agentId} (${body.agentName || agentName})`)
  return {
    agentId: body.agentId,
    agentSecret: body.agentSecret,
    agentName: body.agentName || agentName,
    macAddress: body.macAddress || machineMac,
    relayUrl,
    stateFile: path,
  }
}

/**
 * Backfill the MAC for an identity enrolled before the relay stored one.
 *
 * Runs on every connector start, authenticated with the agent secret. The relay
 * only fills an empty slot, so a later network/interface change cannot rewrite
 * the machine index. An old relay answers 404: that is "not supported", not a
 * connection failure, and startup must continue.
 */
export async function reportMachineAddress({
  relayUrl, agentSecret, macAddress, fetchImpl = fetch, timeoutMs = 8000,
} = {}) {
  const mac = normalizeMacAddress(macAddress ?? primaryMacAddress())
  if (!mac || !relayUrl || !agentSecret) return { ok: false, skipped: 'missing-mac-or-identity' }
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const response = await fetchImpl(agentMachineEndpoint(relayUrl), {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${agentSecret}`,
      },
      body: JSON.stringify({ macAddress: mac }),
      signal: controller.signal,
    })
    let body
    try { body = await response.json() } catch { body = undefined }
    if (response.status === 404) return { ok: false, unsupported: true, macAddress: mac }
    if (!response.ok || body?.ok !== true) {
      throw new Error(body?.error?.message ?? `mobile-link: the relay rejected the machine MAC (HTTP ${response.status})`)
    }
    return { ok: true, macAddress: body.macAddress || mac, updated: body.updated === true }
  } finally {
    clearTimeout(timer)
  }
}

/**
 * Turn the relay's failure into something a person can act on.
 *
 * The three invite failures need different advice, so the relay's error code is
 * mapped rather than replaced by a generic message.
 */
export function describeEnrollFailure(body, status) {
  const code = body?.error?.code ?? ''
  const message = body?.error?.message
  switch (code) {
    case 'enroll/unknown':
      return 'mobile-link: that invite code is not valid — check it for a typo, and that it was issued by this relay'
    case 'enroll/used':
      return 'mobile-link: that invite code has already been used — each code enrolls exactly one computer'
    case 'enroll/expired':
      return 'mobile-link: that invite code has expired — ask for a new one'
    case 'enroll/rate-limited':
      return 'mobile-link: too many failed attempts with that code — wait a few minutes and try again'
    default:
      return `mobile-link: enrollment failed (HTTP ${status})${message ? `: ${message}` : ''}`
  }
}

/** The one-liner a fresh install runs, quoted for copy/paste. */
export function enrollCommand(relayUrl, name = undefined) {
  // 开放登记后命令不再必须带激活码；老的邀请码仍可用 `--invite` 传。
  const parts = ['dsh-mobile-link enroll', `--relay ${relayUrl || '<relay-url>'}`]
  if (name) parts.push(`--name ${JSON.stringify(name)}`)
  return parts.join(' ')
}

function messageOf(error) {
  return error instanceof Error ? error.message : String(error)
}

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

import { enrollEndpoint, isPlaceholderRelayUrl, normalizeRelayUrl } from './dlp.js'
import { DEFAULT_AGENT_NAME, INVITE_ENV, defaultStatePath, readState, writeState } from './state.js'

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
  return { needed: true, stateFile: path, invite, relayUrl: relay, canEnroll: Boolean(invite && relay) }
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
  relayUrl, inviteCode, name, stateFile, deviceName,
  fetchImpl = fetch, logger = undefined, timeoutMs = ENROLL_TIMEOUT_MS,
} = {}) {
  if (!inviteCode || !String(inviteCode).trim()) {
    throw new EnrollError('enroll/bad-request', 'mobile-link: an invite code is required to enroll (--invite <code>)')
  }
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
  const agentName = (name || deviceName || '').trim() || DEFAULT_AGENT_NAME
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
        body: JSON.stringify({ inviteCode: String(inviteCode).trim(), name: agentName }),
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
    relayUrl,
    stateFile: path,
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
  const parts = ['dsh-mobile-link enroll', `--relay ${relayUrl || '<relay-url>'}`, '--invite <code>']
  if (name) parts.push(`--name ${JSON.stringify(name)}`)
  return parts.join(' ')
}

function messageOf(error) {
  return error instanceof Error ? error.message : String(error)
}

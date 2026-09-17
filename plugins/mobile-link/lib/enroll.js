/**
 * First-run enrollment: turn an invite code into a durable agent identity.
 *
 * Until now an identity could only be provisioned by whoever owns the relay
 * (`relay/admin.py agent-register --write-config`). That does not distribute:
 * somebody else installs DSH plus this connector on their own computer and has
 * to be handed a credential by the operator, out of band.
 *
 * So the relay grew `POST /agents/enroll` (relay/api.py), which redeems a
 * one-time invite code for a fresh `agentId` / `agentSecret`. This module is the
 * connector half: one call, then the identity is written to the same
 * `~/.dsh/mobile-link/agent.json` (mode 0600) that `agent-register` writes, so
 * nothing downstream can tell the two apart.
 *
 * Enrollment is deliberately *not* automatic against an open endpoint: an
 * invite code must be present, because the relay is on the public internet.
 */

import { enrollEndpoint } from './dlp.js'
import { DEFAULT_AGENT_NAME, INVITE_ENV, defaultStatePath, readState, writeState } from './state.js'

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
  fetchImpl = fetch, logger = undefined,
} = {}) {
  if (!inviteCode || !String(inviteCode).trim()) {
    throw new Error('mobile-link: an invite code is required to enroll (--invite <code>)')
  }
  if (!relayUrl || !String(relayUrl).trim()) {
    throw new Error('mobile-link: a relay URL is required to enroll (--relay <url>)')
  }
  const path = stateFile || defaultStatePath()
  const agentName = (name || deviceName || '').trim() || DEFAULT_AGENT_NAME

  let response
  try {
    response = await fetchImpl(enrollEndpoint(relayUrl), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ inviteCode: String(inviteCode).trim(), name: agentName }),
    })
  } catch (error) {
    throw new Error(`mobile-link: cannot reach the relay at ${relayUrl}: ${messageOf(error)}`)
  }

  let body
  try {
    body = await response.json()
  } catch {
    throw new Error(`mobile-link: the relay answered HTTP ${response.status} to /agents/enroll`)
  }
  if (!response.ok || body?.ok !== true || !body.agentId || !body.agentSecret) {
    throw new Error(describeEnrollFailure(body, response.status))
  }

  await writeState(path, {
    relayUrl,
    agentId: body.agentId,
    agentSecret: body.agentSecret,
    agentName: body.agentName || agentName,
  })
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

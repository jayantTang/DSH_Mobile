/**
 * Pairing helper: ask the relay to mint a one-time code and build the QR
 * payload the desktop shows. Spec §2.1 plus relay/NOTES.md §2 (the endpoint the
 * spec's table is missing).
 */

import { pairCodeEndpoint, qrPayload } from './dlp.js'

/**
 * @param {object} options
 * @param {{agentId: string, agentSecret: string, relayUrl: string}} options.identity
 * @param {number} [options.ttlMs] requested lifetime (the relay caps it at 1 hour)
 * @param {typeof fetch} [options.fetchImpl] injectable for tests
 */
export async function mintPairCode({ identity, ttlMs = 10 * 60 * 1000, fetchImpl = fetch }) {
  const response = await fetchImpl(pairCodeEndpoint(identity.relayUrl), {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${identity.agentSecret}`,
    },
    body: JSON.stringify({ agentId: identity.agentId, ttlMs }),
  })
  let body
  try {
    body = await response.json()
  } catch {
    throw new Error(`relay returned HTTP ${response.status} for /pair/code`)
  }
  if (!response.ok || body?.ok !== true) {
    throw new Error(body?.error?.message ?? `relay rejected the pairing request (HTTP ${response.status})`)
  }
  return {
    code: body.code,
    expiresAt: body.expiresAt,
    ttlMs: body.ttlMs ?? ttlMs,
    relayUrl: identity.relayUrl,
    agentId: identity.agentId,
    qrPayload: qrPayload({ relay: identity.relayUrl, code: body.code }),
  }
}

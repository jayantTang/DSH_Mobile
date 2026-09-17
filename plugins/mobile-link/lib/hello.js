/**
 * What this connector is and what it can do.
 *
 * The connector and the app are deployed separately, so the app has to ask
 * rather than assume. It asks over the link — a reserved method the connector
 * answers locally — because the HTTP status route only exists on the direct
 * path, and the direct path is not what users run.
 *
 * Feature detection, not version comparison: a connector that lacks a
 * capability simply does not list it, and the app hides that entry instead of
 * calling something that would come back as a 404 from the Host.
 */

import { createRequire } from 'node:module'

/** Reserved method the app calls once per connection. */
export const HELLO_METHOD = '_link/hello'

/**
 * The connector's own version.
 *
 * Read from package.json rather than written out twice: the two drifting apart
 * is exactly the kind of thing nobody notices until a support question depends
 * on it (they had drifted: the manifest said 0.1.0 and this said 0.2.0).
 */
export const SERVER_VERSION = readManifestVersion()

function readManifestVersion() {
  try {
    const require = createRequire(import.meta.url)
    return require('../package.json').version ?? '0.0.0'
  } catch {
    return '0.0.0'
  }
}

/**
 * Capabilities the app may rely on.
 *
 * - `file-transfer`  files can be staged on the computer (see files.js)
 * - `events`         the per-device `$events` stream is served
 * - `session-streams` logical streams (`session/follow`, …) are served
 * - `pair-code`      this connector can mint a pairing code on request
 * - `qr-pairing`     this connector can render the pairing QR itself
 *                    (`GET /mobile-link/qr`), so the desktop needs no client
 * - `self-enroll`    this connector can register itself with an invite code
 */
export const SERVER_CAPABILITIES = [
  'file-transfer', 'events', 'session-streams', 'pair-code', 'qr-pairing', 'self-enroll',
]

export function isHelloMethod(method) {
  return method === HELLO_METHOD
}

/** The answer to {@link HELLO_METHOD}. */
export function helloPayload({ protocolVersion, agentId, name } = {}) {
  return {
    serverVersion: SERVER_VERSION,
    capabilities: SERVER_CAPABILITIES,
    protocolVersion,
    agentId: agentId ?? null,
    name: name ?? null,
  }
}

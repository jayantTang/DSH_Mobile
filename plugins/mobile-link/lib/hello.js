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
 * - `git`            git status / diff / log / show can be read from the work
 *                    tree on this computer (see git.js)
 */
export const SERVER_CAPABILITIES = [
  'file-transfer', 'events', 'session-streams', 'pair-code', 'qr-pairing', 'self-enroll', 'git',
]

export function isHelloMethod(method) {
  return method === HELLO_METHOD
}

/**
 * What the phone says it is, out of the handshake arguments.
 *
 * The app sends this on every connection — the only place the *client's* build
 * travels, since the relay's device row is otherwise written once at pairing and
 * then never again. Older clients send `{}`, which yields nulls: reporting
 * "unknown" beats reporting a version that may be days old.
 *
 * Exported for testing: what it returns ends up in a log line a person will read
 * when they ask "did that phone update?".
 */
export function parseClientInfo(args) {
  const text = (value) => (typeof value === 'string' && value.trim().length > 0 ? value.trim() : null)
  const name = text(args?.clientName)
  const version = text(args?.clientVersion)
  const build = text(args?.clientBuild)
  if (!name && !version && !build) return null
  return {
    name,
    version,
    build,
    // `DSHMobile 1.0 (20260919.0005)`, skipping whatever is missing.
    label: [name, version ? `${version}${build ? ` (${build})` : ''}` : build].filter(Boolean).join(' '),
    at: Date.now(),
  }
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

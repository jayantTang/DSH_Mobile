/**
 * Agent identity persistence: `~/.dsh/mobile-link/agent.json`, mode 0600.
 *
 * The file holds the long-lived `agentId` / `agentSecret` for this computer.
 * There are two ways it gets there, and they are deliberately indistinguishable
 * afterwards: the relay operator provisions it by hand (relay/admin.py
 * `agent-register --write-config`), or the person running the computer redeems
 * an invite code themselves (`dsh-mobile-link enroll`, see enroll.js).
 * Environment variables and the plugin config block override the file, which is
 * how the integration test injects a throwaway identity.
 */

import { chmod, mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

import { isPlaceholderRelayUrl } from './dlp.js'

/**
 * Raised when no identity exists yet — a *setup* state, not a failure.
 *
 * The live agent treats it differently from a transport error: retrying a
 * missing credential forever would be noise, and the fix is a person running
 * one command, not a reconnect.
 */
export class MissingIdentity extends Error {
  constructor(message, { stateFile } = {}) {
    super(message)
    this.name = 'MissingIdentity'
    this.stateFile = stateFile
  }
}

/** The environment variable a packaged install can pre-seed with an invite. */
export const INVITE_ENV = 'DSH_MOBILE_LINK_INVITE'

/** What a computer calls itself before its owner renames it. */
export const DEFAULT_AGENT_NAME = 'My computer'

export function dshHome() {
  return process.env.DSH_HOME || join(homedir(), '.dsh')
}

export function defaultStatePath() {
  return join(dshHome(), 'mobile-link', 'agent.json')
}

export function defaultEndpointFile() {
  return join(dshHome(), 'desktop-shell', 'endpoint.json')
}

/**
 * The desktop shell's log, which is the *second* place the live endpoint can be
 * read from.
 *
 * The shell writes `endpoint.json` as a handoff, but it also removes it again
 * (observed after the shell quit and re-attached to an already running `dsh
 * web`), and a machine whose host was started as a bare `dsh web --port 0` only
 * ever sees the URL printed into this log. Both spellings appear here, so the
 * log is a usable last resort — without it the connector sits at the default
 * port with no launch token and every phone request fails.
 */
export function defaultShellLogFile() {
  return join(dshHome(), 'desktop-shell', 'dsh-shell.log')
}

/** @returns {Promise<Record<string, unknown> | undefined>} */
export async function readState(path) {
  try {
    const raw = JSON.parse(await readFile(path, 'utf8'))
    return raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? raw : undefined
  } catch {
    return undefined
  }
}

/** Write the identity atomically and with mode 0600. */
export async function writeState(path, state) {
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${process.pid}.tmp`
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 })
  await rename(temporary, path)
  await chmod(path, 0o600).catch(() => {})
  return path
}

/**
 * Resolve the effective identity from (in order) explicit config, the
 * environment, then the state file. Secrets are never logged.
 *
 * One exception to that order: the repository's placeholder relay address (see
 * `PLACEHOLDER_RELAY_URL`) counts as *unset*, so an address already enrolled in
 * the state file outranks it. Without this, the placeholder — which ships in the
 * plugin config and is what an unconfigured environment falls back to — would
 * beat the real address of a computer that is already enrolled, and the next
 * restart would both dial the placeholder and overwrite the file with it.
 *
 * When the identity comes from config or the environment (rather than the file)
 * and differs from what is on disk, it is persisted to `stateFile` with mode
 * 0600 — that is how a fresh install turns a pasted config into the durable
 * `~/.dsh/mobile-link/agent.json` the spec calls for. A read-only home
 * directory is not fatal: the in-memory identity is still returned.
 */
export async function resolveIdentity({ stateFile, agentId, agentSecret, relayUrl } = {}) {
  const path = stateFile || defaultStatePath()
  const file = await readState(path)
  const configured = relayUrl || process.env.DSH_MOBILE_LINK_RELAY || ''
  const resolved = {
    stateFile: path,
    relayUrl: isPlaceholderRelayUrl(configured) ? (file?.relayUrl || configured) : (configured || file?.relayUrl || ''),
    agentId: agentId || process.env.DSH_MOBILE_LINK_AGENT_ID || file?.agentId || '',
    agentSecret: agentSecret || process.env.DSH_MOBILE_LINK_AGENT_SECRET || file?.agentSecret || '',
    agentName: file?.agentName || '',
    exists: Boolean(file),
  }
  if (!resolved.agentId || !resolved.agentSecret) {
    throw new MissingIdentity(
      `mobile-link: this computer is not registered yet. Run "dsh-mobile-link enroll`
      + ` --invite <code> --relay <relay-url>" with the invite code you were given, or set`
      + ` ${INVITE_ENV} and restart DSH. (Provisioning by hand is still possible:`
      + ` "python3 relay/admin.py agent-register --account <acc> --name <name>`
      + ` --write-config ${path}".)`,
      { stateFile: path },
    )
  }
  if (!resolved.relayUrl) throw new Error('mobile-link: no relay URL configured')

  const stale = !file
    || file.agentId !== resolved.agentId
    || file.agentSecret !== resolved.agentSecret
    || file.relayUrl !== resolved.relayUrl
  if (stale) {
    try {
      await writeState(path, {
        relayUrl: resolved.relayUrl,
        agentId: resolved.agentId,
        agentSecret: resolved.agentSecret,
        ...(resolved.agentName ? { agentName: resolved.agentName } : {}),
      })
      resolved.exists = true
      resolved.persisted = true
    } catch (error) {
      resolved.persisted = false
      resolved.persistError = error instanceof Error ? error.message : String(error)
    }
  }
  return resolved
}

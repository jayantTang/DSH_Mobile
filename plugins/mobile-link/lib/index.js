/**
 * dsh-plugin-mobile-link — host half.
 *
 * Scope (deliberately tiny so a DSH upgrade can never make it fatal):
 *   1. Run the DLP agent: dial the relay over WSS, serve the iOS client's
 *      session/event traffic from the local DSH instance. On a computer that has
 *      never been registered, redeem the invite code from the environment (or
 *      the config) first, so a fresh install becomes usable without the relay
 *      operator provisioning anything by hand.
 *   2. Three routes under `/mobile-link` behind DSH's own connection fence:
 *      GET  /status     — is the link up, which devices are attached, and is
 *                         this computer registered yet
 *      POST /pair-code  — mint a pairing code + QR payload through the relay
 *      GET  /qr         — the same code rendered as a scannable QR SVG
 *
 * Deliberate design choices:
 *   * The plugin declares **no required services** (`inject` is empty). The DLP
 *     agent must run even if a future DSH renames or drops `webServer` /
 *     `connection`, so the routes are attached through `ctx.inject([...])`
 *     instead of a top-level requirement. Only `ctx.logger` / `ctx.effect` /
 *     `ctx.get` (all optional-chained) are used.
 *   * Nothing outside `lib/` is imported, and no DSH business API is touched:
 *     the tunnel is protocol-transparent by construction (spec §1).
 *
 * Disable by removing the row from the profile's cordis.patch.yml or by setting
 * `enabled: false` in the config block.
 */

import { MobileLinkAgent } from './link.js'
import { registerMobileLinkRoutes } from './routes.js'

/** Cordis function-plugin name (the loader row id is separate). */
export const name = 'mobile-link'

const DEFAULTS = {
  enabled: true,
  // 仓库里只留占位符：真值走 config.relayUrl，或 DSH_RELAY_URL / DSH_MOBILE_LINK_RELAY
  // 环境变量（本机的 .env.local 里写着，见 README「配置」一节）。
  relayUrl: process.env.DSH_RELAY_URL
    || process.env.DSH_MOBILE_LINK_RELAY
    || 'wss://relay.example.com/dsh-link',
  agentId: '',
  agentSecret: '',
  stateFile: '',
  dshUrl: '',
  endpointFile: '',
  inviteCode: '',
  heartbeatMs: 20000,
  pongTimeoutMs: 60000,
  maxBackoffMs: 30000,
  pairTtlMs: 10 * 60 * 1000,
}

/** @param {unknown} value */
function asRecord(value) {
  return value !== null && typeof value === 'object' ? value : {}
}

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {Record<string, unknown>} rawConfig
 */
export function apply(ctx, rawConfig) {
  const config = { ...DEFAULTS, ...asRecord(rawConfig) }
  const logger = ctx.logger ?? console

  const agent = new MobileLinkAgent({
    enabled: config.enabled !== false,
    relayUrl: typeof config.relayUrl === 'string' ? config.relayUrl : DEFAULTS.relayUrl,
    agentId: typeof config.agentId === 'string' ? config.agentId : '',
    agentSecret: typeof config.agentSecret === 'string' ? config.agentSecret : '',
    stateFile: typeof config.stateFile === 'string' && config.stateFile ? config.stateFile : undefined,
    // An invite code may be pinned in the plugin config for a packaged install;
    // otherwise the agent reads DSH_MOBILE_LINK_INVITE (see enroll.js).
    inviteCode: typeof config.inviteCode === 'string' && config.inviteCode ? config.inviteCode : undefined,
    dshUrl: typeof config.dshUrl === 'string' && config.dshUrl ? config.dshUrl : undefined,
    endpointFile: typeof config.endpointFile === 'string' && config.endpointFile ? config.endpointFile : undefined,
    heartbeatMs: Number(config.heartbeatMs) || DEFAULTS.heartbeatMs,
    pongTimeoutMs: Number(config.pongTimeoutMs) || DEFAULTS.pongTimeoutMs,
    maxBackoffMs: Number(config.maxBackoffMs) || DEFAULTS.maxBackoffMs,
    logger,
  })

  ctx.effect(() => {
    let disposed = false
    agent.emit('status')
    agent.start().catch((error) => {
      if (!disposed) logger.warn?.(`mobile-link: start failed: ${error}`)
    })
    return () => {
      disposed = true
      void agent.stop().catch(() => {})
    }
  }, 'mobile-link: DLP agent')

  // Routes ride on DSH's web server when that service exists. `ctx.inject`
  // scopes them without making the service a hard requirement for the agent.
  try {
    ctx.inject(['webServer'], (scope) => {
      const disposers = registerMobileLinkRoutes(scope, { agent, logger, config })
      scope.effect?.(() => () => {
        for (const dispose of disposers) {
          try {
            dispose()
          } catch {
            /* route table already torn down */
          }
        }
      }, 'mobile-link: routes')
      logger.info?.('mobile-link: routes ready under /mobile-link')
    })
  } catch (error) {
    logger.warn?.(`mobile-link: routes unavailable (the link itself keeps running): ${error}`)
  }

  logger.info?.(`mobile-link: ready (relay ${config.relayUrl})`)
}

export { MobileLinkAgent } from './link.js'
export { DshClient, discoverEndpoint, DshUnavailable } from './dsh-client.js'
export {
  MAX_FRAME_BYTES, StreamTable, WaterfallDedupe, agentEndpoint, decodeFrame, encodeFrame,
  joinRelayPath, nextBackoff, normalizeRelayUrl, pairCodeEndpoint, qrPayload,
} from './dlp.js'
export { resolveIdentity, defaultStatePath, defaultEndpointFile, MissingIdentity } from './state.js'
export { enrollAgent, enrollPlan, enrollCommand, describeEnrollFailure } from './enroll.js'
export { INVITE_ENV, DEFAULT_AGENT_NAME } from './state.js'
export { qrMatrix, qrSvg, versionFor } from './qr.js'

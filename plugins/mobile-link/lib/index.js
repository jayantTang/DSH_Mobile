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
 * 当前宿主属于哪一种形态。**按证据判断，不猜**：
 *   - 官方桌面版：它用 Electron 当 Node 跑私有宿主进程（`ELECTRON_RUN_AS_NODE=1`，
 *     入口脚本是 `dsh-desktop-host`）；
 *   - 其余把本插件加载进宿主进程的情况都是命令行 web 版（含 `dsh web --port 0`）。
 * 形状契约见 `specs/001-connector-host-compat/data-model.md` §1。
 *
 * @param {{env?: NodeJS.ProcessEnv, argv?: string[]}} [context]
 * @returns {'desktop' | 'web'}
 */
export function detectHostForm({ env = process.env, argv = process.argv } = {}) {
  if (env.ELECTRON_RUN_AS_NODE === '1') return 'desktop'
  if (/dsh-desktop-host/.test(argv[1] ?? '')) return 'desktop'
  return 'web'
}

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {Record<string, unknown>} rawConfig
 */
/** 构造 agent：把配置逐字段钳制成 agent 认的类型。 */
function buildAgent(config, logger) {
  return new MobileLinkAgent({
    enabled: config.enabled !== false,
    relayUrl: typeof config.relayUrl === 'string' ? config.relayUrl : DEFAULTS.relayUrl,
    agentId: typeof config.agentId === 'string' ? config.agentId : '',
    agentSecret: typeof config.agentSecret === 'string' ? config.agentSecret : '',
    stateFile: typeof config.stateFile === 'string' && config.stateFile ? config.stateFile : undefined,
    // An invite code may be pinned in the plugin config for a packaged install;
    // otherwise the agent reads DSH_MOBILE_LINK_INVITE (see enroll.js).
    inviteCode: typeof config.inviteCode === 'string' && config.inviteCode ? config.inviteCode : undefined,
    dshUrl: typeof config.dshUrl === 'string' && config.dshUrl ? config.dshUrl : undefined,
    heartbeatMs: Number(config.heartbeatMs) || DEFAULTS.heartbeatMs,
    pongTimeoutMs: Number(config.pongTimeoutMs) || DEFAULTS.pongTimeoutMs,
    maxBackoffMs: Number(config.maxBackoffMs) || DEFAULTS.maxBackoffMs,
    logger,
  })
}

/** 启动/停止 agent 的生命周期 effect。 */
function startAgent(ctx, agent, logger) {
  ctx.effect(() => {
    let disposed = false
    agent.setHostForm(detectHostForm())
    agent.emit('status')
    agent.start().catch((error) => {
      if (!disposed) logger.warn?.(`mobile-link: start failed: ${error}`)
    })
    return () => {
      disposed = true
      void agent.stop().catch(() => {})
    }
  }, 'mobile-link: DLP agent')
}

/** 三条本机 HTTP 路由；只依赖 `webServer`，缺了也不影响链路。 */
function registerRoutes(ctx, agent, logger, config) {
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
}

/**
 * 进程内发现（本特性的核心）：宿主把"当前带凭据的回环地址"交给我们。
 *
 * 必须声明注入（`ctx.inject(['webServer','connection'])`）——`ctx.get('connection')` 在插件
 * 作用域里取不到，官方桌面版与 web 版都一样（实测）。与路由分开注入：`connection` 缺失时
 * 路由照常注册，agent 也照常跑。
 */
function wireEndpointResolver(ctx, agent, logger) {
  try {
    ctx.inject(['webServer', 'connection'], (scope) => {
      agent.setHostService(() => scope.connection.authenticatedUrl(`http://127.0.0.1:${scope.webServer.port}`))
      logger.info?.('mobile-link: in-process endpoint resolver ready')
    })
  } catch (error) {
    logger.warn?.(`mobile-link: in-process endpoint resolver unavailable: ${error}`)
  }
}

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {Record<string, unknown>} rawConfig
 */
export function apply(ctx, rawConfig) {
  const config = { ...DEFAULTS, ...asRecord(rawConfig) }
  const logger = ctx.logger ?? console
  const agent = buildAgent(config, logger)

  startAgent(ctx, agent, logger)
  registerRoutes(ctx, agent, logger, config)
  wireEndpointResolver(ctx, agent, logger)
  logger.info?.(`mobile-link: ready (relay ${config.relayUrl})`)
}

export { MobileLinkAgent } from './link.js'
export { DshClient, discoverEndpoint, discoverCandidates, DshUnavailable } from './dsh-client.js'
export { writeHandoff, handoffFromEndpoint } from './handoff.js'
export {
  MAX_FRAME_BYTES, StreamTable, WaterfallDedupe, agentEndpoint, decodeFrame, encodeFrame,
  joinRelayPath, nextBackoff, normalizeRelayUrl, pairCodeEndpoint, qrPayload,
} from './dlp.js'
export { resolveIdentity, defaultStatePath, defaultHandoffFile, MissingIdentity } from './state.js'
export { enrollAgent, enrollPlan, enrollCommand, describeEnrollFailure } from './enroll.js'
export { INVITE_ENV, DEFAULT_AGENT_NAME } from './state.js'
export { qrMatrix, qrSvg, versionFor } from './qr.js'

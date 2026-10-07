/**
 * `GET /mobile-link/status` 的快照。
 *
 * 单独成文件的目的：这份载荷是**对外契约**（`contracts/status-endpoint.md` 规定了
 * "只增不改"），把它和传输/生命周期代码分开，改动时更容易看出"是不是又动了老字段"。
 * 函数只读 agent 的字段，不持有状态，因此可以直接被单测调用。
 */

import { SERVER_CAPABILITIES, SERVER_VERSION } from './hello.js'

const PROTOCOL_VERSION = 1

/**
 * 失败分类 → 用户可读的一句话 + 文档锚点（FR-012）。
 *
 * 锚点标题与 `docs/ONBOARDING.md` 里的小节标题**逐字一致**，这样"锚点存在"可以机械核对。
 */
export const DSH_HINTS = {
  config: { hint: '你手工配置的本机地址不对或已失效', docAnchor: '手工指定本机地址' },
  'host-service': { hint: '当前宿主没有把本机访问方式交给插件（多为插件没装进正在运行的宿主）', docAnchor: '装在哪里：档案与插件入口' },
  DSH_WEB_URL: { hint: '环境变量里的本机地址已过期', docAnchor: '手工指定本机地址' },
  unreachable: { hint: '本机 DSH 不可达；请确认宿主正在运行', docAnchor: '排查：连不上时看这里' },
}

/** 本机 DSH 侧的诊断块（老字段一个不少，新字段只增）。 */
function dshBlock(agent) {
  const errorKind = agent.dshError ? (agent.dsh?.errorKind ?? 'unreachable') : null
  const entry = errorKind ? DSH_HINTS[errorKind] : undefined
  return {
    endpoint: agent.dsh?.endpoint?.base ?? null,
    source: agent.dsh?.endpoint?.source ?? null,
    port: agent.dsh?.endpoint?.port ?? null,
    authenticated: Boolean(agent.dsh?.cookie),
    muxUp: Boolean(agent.dsh?.muxReady),
    error: agent.dshError ?? null,
    // 新增（只增不改）：失败分类 + 用户可读的一句话 + 文档锚点。
    errorKind,
    hint: entry?.hint ?? null,
    docAnchor: entry?.docAnchor ?? null,
  }
}

/**
 * @param {import('./link.js').MobileLinkAgent} agent
 * @returns {Record<string, unknown>} 可直接序列化给 `/status` 的对象
 */
export function statusSnapshot(agent) {
  return {
    ok: true,
    enabled: agent.enabled !== false,
    // 新增（只增不改）：宿主形态，决定用户该按哪条说明安装/排障。
    host: agent.hostForm,
    protocolVersion: PROTOCOL_VERSION,
    // Same facts as `_link/hello`, which is the channel the app actually uses:
    // this route only exists on the direct path.
    serverVersion: SERVER_VERSION,
    capabilities: SERVER_CAPABILITIES,
    enroll: {
      // A phone (or the user's browser) can read this to find out that the
      // computer half is installed but not yet registered, and what to run.
      registered: !agent.needsEnroll,
      needsEnroll: agent.needsEnroll,
      stateFile: agent.identity?.stateFile ?? agent.config.stateFile ?? null,
      relayUrl: agent.config.relayUrl ?? null,
      command: agent.needsEnroll ? agent.enrollHint() : null,
      hint: agent.needsEnroll
        ? '这台电脑还没有登记到中转。请带上邀请码运行一次登记命令，然后重启 DSH。'
        : null,
    },
    state: agent.state,
    connected: agent.state === 'connected',
    relayUrl: agent.identity?.relayUrl ?? agent.config.relayUrl ?? null,
    agentId: agent.identity?.agentId ?? agent.config.agentId ?? null,
    agentName: agent.identity?.agentName ?? null,
    stateFile: agent.identity?.stateFile ?? agent.config.stateFile ?? null,
    dsh: dshBlock(agent),
    devices: agent.router.snapshot(),
    deviceCount: agent.devices.size,
    openStreams: agent.streams.size,
    pendingWaterfalls: agent.dedupe.size,
    lastError: agent.failure ?? null,
    startedAt: agent.startedAt ?? null,
    connectedAt: agent.connectedAt ?? null,
    reconnectAttempts: agent.reconnectAttempts,
  }
}

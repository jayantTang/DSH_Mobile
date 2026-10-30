/**
 * `GET /mobile-link/status` 的快照。
 *
 * 单独成文件的目的：这份载荷是**对外契约**（`contracts/status-endpoint.md` 规定了
 * "只增不改"），把它和传输/生命周期代码分开，改动时更容易看出"是不是又动了老字段"。
 * 函数只读 agent 的字段，不持有状态，因此可以直接被单测调用。
 */

import { isPlaceholderRelayUrl } from './dlp.js'
import { SERVER_CAPABILITIES, SERVER_VERSION, hostVersion } from './hello.js'

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

/**
 * 宿主形态 → 用户可读的一句话 + 文档锚点（FR-012：分类必须可行动，不能只给分类名）。
 *
 * 锚点标题与 `docs/ONBOARDING.md` 的小节标题逐字一致，`test/status.test.js` 会核对。
 */
export const HOST_HINTS = {
  desktop: { hint: '你正在用官方桌面版（连接器已装进它的档案）', docAnchor: '安装：官方桌面版' },
  web: { hint: '你正在用命令行 web 版', docAnchor: '安装：命令行 web 版' },
  unknown: { hint: '无法识别当前宿主；若连不上，请按"排查"一节处理', docAnchor: '排查：连不上时看这里' },
}

/** 本机 DSH 侧的诊断块（老字段一个不少，新字段只增）。 */function dshBlock(agent) {
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
 * 生命周期流水的读法（只增字段）。
 *
 * 为什么状态接口要给这一块：`lastError` 只有最后一条，而"手机为什么连不上"往往要
 * 看**之前**发生过什么（拆了几次链、每次什么原因、设备是不是同时开了两条）。
 *
 * 读法要说清楚：`recent` / `recorded` / `dropped` 都是**当前这个实例**的（热更会换实例，
 * 换完这几个数从零开始）；跨实例的完整历史只在 `path` 指的 JSONL 文件里——两者互补，
 * 别拿 `recorded` 当"这台机器一共连过几次"。没有流水对象（老调用方、单测的假 agent）
 * 时给空块，不是 `undefined`——读者不用做判空。
 */
function journalBlock(agent) {
  const journal = agent.journal
  return {
    path: journal?.path ?? null,
    recorded: journal?.recorded ?? 0,
    dropped: journal?.dropped ?? 0,
    fileErrors: journal?.fileErrors ?? 0,
    recent: journal?.recent?.(STATUS_JOURNAL_ENTRIES) ?? [],
  }
}

/** `/status` 里随每次轮询带出的流水条数。完整历史读 `journal.path` 那个文件。 */
const STATUS_JOURNAL_ENTRIES = 20

/**
 * @param {import('./link.js').MobileLinkAgent} agent
 * @returns {Record<string, unknown>} 可直接序列化给 `/status` 的对象
 */
export function statusSnapshot(agent) {
  const hostEntry = HOST_HINTS[agent.hostForm] ?? HOST_HINTS.unknown
  // One resolved view of the relay address, shared by the form and the panel:
  // a configured address outranks the identity, but the repository placeholder
  // is "unset", never a value to prefill. `relayLocked` says the address came
  // from config/env, so the form must be read-only — otherwise the panel would
  // enroll with one address and the next boot would dial another.
  const configuredRelay = typeof agent.config?.relayUrl === 'string' ? agent.config.relayUrl : ''
  const realConfiguredRelay = configuredRelay && !isPlaceholderRelayUrl(configuredRelay)
    ? configuredRelay
    : null
  // `defaultRelayUrl` is a *form default*, not a dialing override: it only
  // prefills the input, so the user can replace it and the identity file still
  // wins on the next boot. A real `relayUrl` is the operator pin and locks it.
  const configuredDefault = typeof agent.config?.defaultRelayUrl === 'string'
    ? agent.config.defaultRelayUrl
    : ''
  const defaultRelay = configuredDefault && !isPlaceholderRelayUrl(configuredDefault)
    ? configuredDefault
    : null
  const effectiveRelay = agent.identity?.relayUrl ?? realConfiguredRelay ?? null
  const relayPrefill = realConfiguredRelay ?? defaultRelay ?? agent.identity?.relayUrl ?? null
  return {
    ok: true,
    enabled: agent.enabled !== false,
    // 新增（只增不改）：宿主形态 + 它对应的一句话与文档锚点，
    // 决定用户该按哪条说明安装/排障（FR-012）。
    host: agent.hostForm,
    hostHint: hostEntry.hint,
    hostDocAnchor: hostEntry.docAnchor,
    protocolVersion: PROTOCOL_VERSION,
    // Same facts as `_link/hello`, which is the channel the app actually uses:
    // this route only exists on the direct path.
    serverVersion: SERVER_VERSION,
    // 宿主 DSH 的版本（`null` = 这个宿主没把版本放进环境）。与 `serverVersion`
    // 是两个命名空间：前者是连接器，后者是跑它的 DSH。
    hostVersion: hostVersion(),
    capabilities: SERVER_CAPABILITIES,
    enroll: {
      // A phone (or the user's browser) can read this to find out that the
      // computer half is installed but not yet registered, and what to run.
      registered: !agent.needsEnroll,
      needsEnroll: agent.needsEnroll,
      // `panel` is a host-UI capability, not a phone capability: an older
      // connector omits it, and the panel falls back to the command. It is
      // deliberately not in SERVER_CAPABILITIES (that list is what the app asks
      // for over `_link/hello`; the phone has no use for a panel form).
      panel: true,
      stateFile: agent.identity?.stateFile ?? agent.config.stateFile ?? null,
      relayUrl: effectiveRelay,
      relayPrefill,
      relayLocked: Boolean(realConfiguredRelay),
      command: agent.needsEnroll ? agent.enrollHint() : null,
      hint: agent.needsEnroll
        ? '这台电脑还没有登记到中转。在「移动端连接」面板里填入中转地址与激活码即可。'
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
    // 新增（只增不改）：生命周期流水的摘要与最近若干条，见上面的 journalBlock。
    journal: journalBlock(agent),
  }
}

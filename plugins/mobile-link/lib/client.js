/**
 * 客户端半边：DSH 界面里的移动端连接入口（spec 010）。界面只用官方原子组件
 * （`@deepseek-ai/dsh-client-ui-primitives`）拼装：遮罩、顶层 Esc、焦点归位归官方 `Modal`，
 * 视觉跟官方 token 走，这里的 CSS 只管版式。小窗自己持有那张配对码（每次打开新签一张）。
 *
 * 形状抄 `plugins/send-image/lib/client.js`（契约见 specs/002-.../contracts/client-plugin.md）：
 * CJS 命名空间、只 require 平台 seed 字、顶层除 load 外无副作用、整份脚本套 IIFE。
 * 热更：改本文件不需要重启 DSH，也不用刷新页面（`dsh-client-hmr`，实测约 3 秒生效）。
 */
;(() => {
/** 路由用相对路径：宿主把插件路由挂在同一个源上。 */
const STATUS_ROUTE = 'mobile-link/status'
const ENROLL_ROUTE = 'mobile-link/enroll'
const DEVICES_ROUTE = 'mobile-link/devices'
const REVOKE_ROUTE = 'mobile-link/devices/revoke'
const PAIR_ROUTE = 'mobile-link/pair-code'
const REGENERATE_ROUTE = 'mobile-link/pair-code/regenerate'
const SLOT_ENTRY = 'sidebar.footer.action'
const SLOT_OVERLAY = 'shell.overlay'
const ENTRY_ID = 'mobile-link-entry'
const PANEL_ID = 'mobile-link-panel'
const STYLE_ID = 'dsh-mobile-link-style'
const LABEL = '移动端连接'
const TITLE = '移动端连接：二维码、已配对的手机与连接状态'
const PRIMITIVES = '@deepseek-ai/dsh-client-ui-primitives'
/** GitHub 仓库与 iOS 公开测试链接；都只做展示，不参与准入。 */
const GITHUB_URL = 'https://github.com/jayantTang/DSH_Mobile'
const TESTFLIGHT_URL = 'https://testflight.apple.com/join/tHKQsbCk'
/** 小窗打开时的状态轮询间隔；关闭时只为让侧栏状态点别停在旧值上。 */
const OPEN_POLL_MS = 2500
/** 已配对设备全量列表的刷新间隔；在线状态仍由 /status 的 2.5 秒轮询负责。 */
const PAIRED_POLL_MS = 10000
const IDLE_POLL_MS = 20000
/** 剩余寿命低于这个值就换一张：只剩几秒的码，扫它失败的原因用户看不见。 */
const CODE_FLOOR_MS = 60 * 1000
/** 向宿主请求的码长；宿主与中转各自还有兜底上限。 */
const CODE_TTL_MS = 10 * 60 * 1000
/** 「已复制」提示的停留时间。 */
const COPIED_MS = 2000
/** 版式。颜色与圆角取官方 token 并带兜底值：插件可能装在没有这些变量的宿主上。 */
const CSS = [
  '.dsh-mobile-link-entry{display:flex;align-items:center;justify-content:flex-start;gap:8px;width:100%;font-size:13px}',
  '.dsh-mobile-link-entry-label{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
  '.dsh-mobile-link-dialog{width:min(500px,94vw)}',
  '.dsh-mobile-link-body{position:relative;display:flex;flex-direction:column;gap:16px}',
  '.dsh-mobile-link-status{display:flex;align-items:center;gap:8px;font-size:13px;font-weight:500}',
  '.dsh-mobile-link-section-title{font-size:11px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--dsw-alias-label-tertiary,inherit)}',
  '.dsh-mobile-link-kv{display:grid;grid-template-columns:auto minmax(0,1fr);gap:8px 16px;font-size:13px}',
  '.dsh-mobile-link-k{color:var(--dsw-alias-label-tertiary,inherit);white-space:nowrap}',
  '.dsh-mobile-link-v{min-width:0;text-align:right;color:var(--dsw-alias-label-primary,inherit);overflow-wrap:anywhere}',
  '.dsh-mobile-link-mono,.dsh-mobile-link-note,.dsh-mobile-link-device-meta{font-size:12px;color:var(--dsw-alias-label-tertiary,inherit)}',
  '.dsh-mobile-link-mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}',
  '.dsh-mobile-link-card{display:flex;flex-direction:column;align-items:center;gap:14px;padding:20px 18px;border-radius:12px;background:var(--dsw-alias-bg-module-platform,rgba(15,17,21,.04))}',
  '.dsh-mobile-link-qr{display:block;width:248px;max-width:100%;height:auto;box-sizing:border-box;padding:10px;border-radius:10px;background:#fff}',
  '.dsh-mobile-link-code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:20px;font-weight:600;letter-spacing:.16em;line-height:1;color:var(--dsw-alias-label-primary,inherit)}',
  '.dsh-mobile-link-count{display:flex;flex-direction:column;align-items:center;gap:6px;font-size:12px;color:var(--dsw-alias-label-tertiary,inherit)}',
  '.dsh-mobile-link-bar{width:180px;height:3px;border-radius:2px;overflow:hidden;background:var(--dsw-alias-border-secondary,rgba(15,17,21,.12))}',
  '.dsh-mobile-link-bar i{display:block;height:100%;border-radius:2px;background:var(--dsw-alias-state-business-primary,#4176e6);transition:width .9s linear}',
  '.dsh-mobile-link-actions{display:flex;align-items:center;gap:8px}',
  '.dsh-mobile-link-section{display:flex;flex-direction:column;gap:8px}',
  '.dsh-mobile-link-devices{display:flex;flex-direction:column;gap:6px;max-height:184px;overflow:auto}',
  '.dsh-mobile-link-device{display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:10px;background:var(--dsw-alias-bg-module-platform,rgba(15,17,21,.04))}',
  '.dsh-mobile-link-device-name{font-size:13px;font-weight:500}',
  '.dsh-mobile-link-device-line{display:flex;align-items:center;gap:6px;min-width:0}',
  '.dsh-mobile-link-revoke{flex:0 0 auto;margin-left:auto;border:0;background:transparent;padding:4px 0 4px 8px;font:inherit;font-size:12px;color:var(--dsw-alias-label-tertiary,#8a919d);cursor:pointer}',
  '.dsh-mobile-link-revoke:hover{color:var(--dsw-alias-label-secondary,#5f6672)}',
  '.dsh-mobile-link-error{color:var(--dsw-alias-state-error-primary,#d1242f)}',
  '.dsh-mobile-link-note{font-size:12px;line-height:1.65;color:var(--dsw-alias-label-tertiary,inherit)}',
  '.dsh-mobile-link-form{display:flex;flex-direction:column;gap:12px}',
  '.dsh-mobile-link-field{display:flex;flex-direction:column;gap:6px}',
  '.dsh-mobile-link-field>span{width:100%}',
  '.dsh-mobile-link-label{font-size:12px;font-weight:600;color:var(--dsw-alias-label-primary,inherit)}',
  '.dsh-mobile-link-input{width:100%;height:36px;box-sizing:border-box;border:1px solid var(--dsw-alias-border-secondary,rgba(15,17,21,.16));border-radius:8px;padding:0 10px;font-size:13px;font-family:inherit;color:var(--dsw-alias-label-primary,inherit);background:var(--dsw-alias-bg-module-platform,#fff)}',
  '.dsh-mobile-link-input:focus{outline:none;border-color:var(--dsw-alias-state-business-primary,#4176e6);box-shadow:0 0 0 3px rgba(65,118,230,.14)}',
  '.dsh-mobile-link-input[readonly]{opacity:.78}',
  '.dsh-mobile-link-input.dsh-mobile-link-code-input{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.12em}',
  '.dsh-mobile-link-error-inline{padding:8px 10px;border-radius:8px;font-size:12px;line-height:1.6;color:var(--dsw-alias-state-error-primary,#d1242f);background:var(--dsw-alias-bg-error,rgba(209,36,47,.08))}',
  '.dsh-mobile-link-link{color:var(--dsw-alias-state-business-primary,#4176e6);text-decoration:underline;text-underline-offset:2px}',
  '.dsh-mobile-link-cmd{font-size:11px;line-height:1.65;color:var(--dsw-alias-label-tertiary,inherit)}',
  '.dsh-mobile-link-cmd summary{cursor:pointer;user-select:none}',
  '.dsh-mobile-link-cmd .dsh-mobile-link-mono{margin-top:6px;white-space:nowrap;overflow-x:auto}',
  '.dsh-mobile-link-github{display:flex;flex-direction:column;gap:3px}',
  '.dsh-mobile-link-github-line{display:flex;justify-content:space-between;gap:12px;font-size:13px;align-items:baseline}',
  '.dsh-mobile-link-github-line .dsh-mobile-link-k{color:var(--dsw-alias-label-tertiary,inherit)}',
  '.dsh-mobile-link-github-line a{flex:1 1 auto;min-width:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;color:var(--dsw-alias-state-business-primary,#4176e6);text-decoration:none;text-decoration:underline;text-underline-offset:2px;overflow-wrap:anywhere;word-break:break-all;text-align:right}',
  '.dsh-mobile-link-welcome{font-size:11px;color:var(--dsw-alias-label-tertiary,inherit);text-align:right}',
  '.dsh-mobile-link-ioslink{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 10px;border-radius:9px;background:var(--dsw-alias-bg-module-platform,rgba(15,17,21,.04));font-size:12px;color:var(--dsw-alias-label-secondary,inherit)}',
  '.dsh-mobile-link-ioslink a{color:var(--dsw-alias-state-business-primary,#4176e6);text-decoration:none;font-weight:600;white-space:nowrap}',
  '.dsh-mobile-link-overlay{position:absolute;inset:0;z-index:2;display:flex;align-items:center;justify-content:center;padding:18px;background:rgba(23,33,52,.30);border-radius:16px}',
  '.dsh-mobile-link-alert{width:min(360px,100%);display:flex;flex-direction:column;gap:12px;padding:16px;border-radius:12px;background:var(--dsw-alias-bg-module-platform,#fff);border:1px solid var(--dsw-alias-border-secondary,#e2e6ec);box-shadow:0 18px 40px rgba(23,33,52,.20)}',
  '.dsh-mobile-link-alert-title{font-size:14px;font-weight:700}',
  '.dsh-mobile-link-alert-actions{display:flex;gap:10px}',
  '.dsh-mobile-link-alert-actions .dsh-mobile-link-btn{flex:1}',
  '.dsh-mobile-link-guide{width:min(420px,100%);max-height:calc(100% - 36px);overflow:auto;display:flex;flex-direction:column;gap:12px;padding:16px;border-radius:12px;background:var(--dsw-alias-bg-module-platform,#fff);border:1px solid var(--dsw-alias-border-secondary,#e2e6ec);box-shadow:0 18px 40px rgba(23,33,52,.20)}',
  '.dsh-mobile-link-guide-title{font-size:15px;font-weight:700}',
  '.dsh-mobile-link-step{display:flex;gap:9px;align-items:flex-start}',
  '.dsh-mobile-link-step-n{flex:0 0 18px;height:18px;border-radius:50%;background:rgba(65,118,230,.12);color:var(--dsw-alias-state-business-primary,#4176e6);display:grid;place-items:center;font-size:10px;font-weight:700}',
  '.dsh-mobile-link-step-t{font-size:12px;line-height:1.6}',
  '.dsh-mobile-link-testflight{padding:9px;border-radius:8px;background:var(--dsw-alias-bg-module-platform,rgba(15,17,21,.04));font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:10px;color:var(--dsw-alias-state-business-primary,#4176e6);overflow-wrap:anywhere}',
  '.dsh-mobile-link-alert-actions>*{flex:1}',
  '.dsh-mobile-link-danger{height:36px;border:0;border-radius:9px;background:var(--dsw-alias-state-error-primary,#d1242f);color:#fff;font:inherit;font-size:12px;font-weight:600;cursor:pointer}',
  '.dsh-mobile-link-danger:disabled{opacity:.65;cursor:default}',
].join('')

function report(ctx, message) {
  const text = `mobile-link: ${message}`
  try {
    if (typeof ctx?.logger?.warn === 'function') ctx.logger.warn(text)
    else console.warn(text)
  } catch {
    /* 连日志都写不了就算了，不能因此让界面起不来 */
  }
}
function describe(error) {
  return error instanceof Error ? error.message : String(error)
}
/** 样式节点上的"认领者"标记：谁最后认领，谁负责撤。 */
const STYLE_OWNER_ATTR = 'data-owner'
/** 认领序号：同一次 enable 一个 token，跨热更两代不会撞。 */
let styleOwnerSeq = 0

/**
 * 样式表：页面上只留一份，**但所有权要认**。
 *
 * 为什么不能"存在就复用、退场就删"：热更时两代插件可能同时在世，且顺序可能是
 * "新一代先起来认领同一个 `<style>`、上一代后退场"。上一代若无条件删节点，新面板就
 * 变成没有样式的裸 HTML——2026-10-17 owner 看到配对面板"突然不像原版"就是这个。
 * 所以认领时写下自己的 token，退场时只撤自己认领的那一份。
 */
function ensureStyle() {
  if (typeof document === 'undefined' || !document.head) return null
  const token = `o${++styleOwnerSeq}-${Date.now()}`
  let node = document.getElementById(STYLE_ID)
  if (!node) {
    node = document.createElement('style')
    node.id = STYLE_ID
    node.textContent = CSS
    document.head.appendChild(node)
  }
  node.setAttribute?.(STYLE_OWNER_ATTR, token)
  return { node, token }
}

/** 退场：只有这个节点仍归本次 enable 时才撤掉它。 */
function releaseStyle(style) {
  const node = style?.node
  if (!node) return
  if (node.getAttribute?.(STYLE_OWNER_ATTR) !== style.token) return
  node.remove?.()
}
/** 极小的外部状态容器：按钮与小窗是两个独立注册项，需要共享的只有几个字段。 */
function createStore(initial) {
  let state = { ...initial }
  const listeners = new Set()
  return {
    get: () => state,
    set(patch) {
      state = { ...state, ...patch }
      for (const listener of listeners) listener()
    },
    subscribe(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  }
}
function useStore(React, store) {
  return React.useSyncExternalStore(store.subscribe, store.get, store.get)
}
/** 一个 GET/POST，把失败统一成带可读 message 的 Error。 */
async function requestJson(path, init) {
  let response
  try {
    response = await fetch(path, init)
  } catch (error) {
    throw new Error(`连不上本机连接器：${describe(error)}`)
  }
  let body
  try {
    body = await response.json()
  } catch {
    throw new Error(`连接器应答无法解析（HTTP ${response.status}）`)
  }
  if (!response.ok || body?.ok === false) {
    const error = new Error(body?.message ?? `连接器应答 HTTP ${response.status}`)
    // Keep the machine code: the panel maps it to Chinese copy and must not
    // parse English messages to tell "used" from "expired".
    error.code = body?.code
    error.status = response.status
    throw error
  }
  return body
}
function needsEnroll(status) {
  if (!status) return false
  if (status.enroll?.needsEnroll !== undefined) return Boolean(status.enroll.needsEnroll)
  return status.enroll?.registered === false
}
/** 状态点与状态词的唯一来源：侧栏入口与标题行共用，不会出现"点上是绿的、文字说断开"。 */
function connectionState(state) {
  if (state.statusError) return { dot: 'error', text: '状态未知' }
  if (!state.status) return { dot: 'ongoing', text: '正在读取状态…' }
  if (needsEnroll(state.status)) return { dot: 'error', text: '此电脑尚未登记' }
  if (state.status.enabled === false) return { dot: 'idle', text: '连接器已停用' }
  if (state.status.connected) return { dot: 'done', text: '已连接' }
  return { dot: 'warning', text: '未连接，正在重新连接' }
}
/** 手机报上来的版本：`hello` 存的是 `{name,version,build,label}`，直接插值会渲染成 [object Object]。 */
function clientLabel(client) {
  if (!client) return null
  if (typeof client === 'string') return client
  return client.label ?? [client.name, client.version].filter(Boolean).join(' ') ?? null
}
/** 在线/总数分开说：`deviceCount` 把"连着但已离线"的记录也算进去了。 */
function deviceSummary(devices) {
  const list = Array.isArray(devices) ? devices : []
  if (list.length === 0) return '暂无已配对设备'
  const online = list.filter((device) => device.offlineSince === null || device.offlineSince === undefined).length
  return online === list.length ? `${online} 台在线` : `${online} 台在线，共 ${list.length} 台`
}
/** 全量已配对设备 + /status 的在线标记；离线设备也要有行。 */
function pairedRows(state) {
  // 全量列表是行集合的所有者；/status 只补在线标记与运行时元数据。
  // 反过来把 status 独有项也拼进来，会把已撤销但本地 router 还留着的记录
  // 重新显示出来（计数与行数再次不一致）。
  const roster = Array.isArray(state.pairedDevices) ? state.pairedDevices : null
  const base = roster ?? (Array.isArray(state.status?.devices) ? state.status.devices : [])
  const rows = new Map()
  for (const device of base) {
    if (device?.deviceId) rows.set(device.deviceId, { ...device })
  }
  const statusDevices = Array.isArray(state.status?.devices) ? state.status.devices : []
  for (const device of statusDevices) {
    const existing = rows.get(device.deviceId)
    if (!existing) continue
    rows.set(device.deviceId, { ...existing, ...device })
  }
  const online = new Set(statusDevices
    .filter((device) => device.offlineSince === null || device.offlineSince === undefined)
    .map((device) => device.deviceId))
  return [...rows.values()].map((device) => ({ ...device, online: online.has(device.deviceId) }))
}
function pairedTotal(state) {
  if (typeof state.pairedCount === 'number') return state.pairedCount
  if (Array.isArray(state.pairedDevices)) return state.pairedDevices.length
  return Array.isArray(state.status?.devices) ? state.status.devices.length : 0
}
function deviceSummaryOf(state) {
  const total = pairedTotal(state)
  if (total === 0) return '暂无已配对设备'
  const online = pairedRows(state).filter((device) => device.online).length
  return online === total ? `${total} 台在线` : `${online} 台在线，共 ${total} 台已配对`
}
function clockText(expiresAt) {
  const date = new Date(Number(expiresAt))
  const pad = (value) => String(value).padStart(2, '0')
  return `${pad(date.getHours())}:${pad(date.getMinutes())}`
}
function remainingText(ms) {
  const total = Math.max(0, Math.floor(Number(ms) / 1000))
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`
}
/** 面板的可变状态：一个插件实例一份。 */
function createPanel() {
  return {
    store: createStore({
      open: false,
      status: null,
      statusError: null,
      code: null,
      codeError: null,
      busy: false,
      copied: false,
      showError: false,
      now: Date.now(),
      // 登记表单只属于本次界面：草稿不落 localStorage，提交成功后清空。
      enrolling: false,
      enrollDraft: { relay: '', relayTouched: false },
      enrollError: null,
      pairedDevices: null,
      pairedMax: null,
      pairedCount: null,
      pairedError: null,
      pairedBusy: false,
      revokeTarget: null,
      revoking: false,
      revokeError: null,
      guideOpen: false,
    }),
    disposed: false,
    style: null,
    idleTimer: null,
    tickTimer: null,
    copiedTimer: null,
    lastStatusAt: 0,
  }
}
async function loadStatus(panel) {
  try {
    const status = await requestJson(STATUS_ROUTE, { method: 'GET' })
    if (panel.disposed) return undefined
    panel.store.set({ status, statusError: null })
    return status
  } catch (error) {
    if (panel.disposed) return undefined
    panel.store.set({ statusError: describe(error) })
    return undefined
  }
}
/**
 * 读中转上的全部已配对设备（含离线）。/status 里的 devices 只含当前接上的，
 * 单看它会把离线设备藏起来，导致“已配对 2/8”却只列出一台。二者在这里合并：
 * 全量列表决定行与配额，/status 决定在线标记。
 */
async function loadPairedDevices(panel) {
  if (panel.disposed) return
  const status = panel.store.get().status
  if (!status || needsEnroll(status)) {
    panel.store.set({ pairedDevices: null, pairedCount: null, pairedMax: null, pairedError: null })
    return
  }
  panel.store.set({ pairedBusy: true })
  try {
    const body = await requestJson(DEVICES_ROUTE, { method: 'GET' })
    if (panel.disposed) return
    panel.store.set({
      pairedDevices: Array.isArray(body.devices) ? body.devices : [],
      pairedCount: body.pairedDevices ?? null,
      pairedMax: body.maxPairedDevices ?? null,
      pairedError: null,
      pairedBusy: false,
    })
  } catch (error) {
    if (panel.disposed) return
    panel.store.set({
      pairedError: '无法读取全部已配对设备。',
      pairedBusy: false,
    })
  }
}

/**
 * 取一张码。
 *
 * 032 起默认是**持久码**：它一直有效，直到用户点「重新生成」。所以这里有两个与旧实现
 * 相反的行为，都是有意的：
 *
 * * **复用已有的那张**——旧实现每次"换一张"，因为一次性码用过就废；持久码换掉等于
 *   把用户刚发给别人的那张悄悄作废。
 * * **不再因为"配过一台"就自动换码**——同一张码本来就是要给多台设备用的。
 */
async function refreshCode(panel, { regenerate = false } = {}) {
  if (panel.disposed || panel.store.get().busy) return
  if (needsEnroll(panel.store.get().status)) {
    panel.store.set({ code: null, codeError: null })
    return
  }
  // 登记成功 ≠ 已连接：链路还没起来时去取码只会失败，界面应该显示
  // "正在连接中转"，而不是把一次连接等待误报成取码失败。
  if (panel.store.get().status?.connected !== true) {
    panel.store.set({ code: null, codeError: null })
    return
  }
  // 只有**持久码**才复用：限时码到期就得重新取一张（老行为），否则屏幕上会留一张死码。
  if (!regenerate && panel.store.get().code?.persistent) return
  panel.store.set({ busy: true, codeError: null })
  try {
    // 两条意图分得很清楚：
    // * `regenerate`：用户点「重新生成」→ 让中转**作废旧码**再铸一张（新端点）。
    // * 其余（首次取码、限时码到期续期）→ 走原来的取码端点。老中转没有 regenerate，
    //   续期这条路必须留在老端点上，否则连着老中转的连接器会在这里失败。
    const body = await requestJson(regenerate ? REGENERATE_ROUTE : PAIR_ROUTE, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({}),
    })
    if (panel.disposed) return
    panel.store.set({
      code: {
        code: body.code,
        qrPayload: body.qrPayload,
        svg: body.svg,
        // 持久码没有 expiresAt：界面上不再有倒计时（见 codeSection）。
        expiresAt: body.expiresAt == null ? null : Number(body.expiresAt),
        ttlMs: Number(body.ttlMs) || null,
        persistent: body.persistent === true || body.expiresAt == null,
        maxPairedDevices: Number(body.maxPairedDevices ?? 0) || null,
        pairedDevices: Number(body.pairedDevices ?? 0),
        revoked: Number(body.revoked ?? 0),
      },
      codeError: null,
    })
  } catch (error) {
    if (panel.disposed) return
    // 码撤掉而不是留着：一张取不到的码继续摆在屏幕上，就是在骗人去扫。
    panel.store.set({ code: null, codeError: describe(error) })
  } finally {
    if (!panel.disposed) panel.store.set({ busy: false })
  }
}
/** 每秒一拍：倒计时、状态轮询、以及"这张码该换了"。 */
function tick(panel) {
  if (panel.disposed || !panel.store.get().open) return
  const now = Date.now()
  panel.store.set({ now })
  if (now - panel.lastStatusAt >= OPEN_POLL_MS) {
    panel.lastStatusAt = now
    void loadStatus(panel)
  }
  if (now - (panel.lastPairedAt ?? 0) >= PAIRED_POLL_MS
      && !panel.store.get().pairedBusy
      && panel.store.get().status
      && !needsEnroll(panel.store.get().status)) {
    panel.lastPairedAt = now
    void loadPairedDevices(panel)
  }
  // 持久码不因时间换码（032）：只有用户点「重新生成」才换。限时码（老中转/老调用方）
  // 仍然按原来的规则在快过期时换一张，免得把一张马上就要失效的码摆在屏幕上。
  const state = panel.store.get()
  const code = state.code
  if (code && !code.persistent && code.expiresAt != null && code.expiresAt - now <= CODE_FLOOR_MS) {
    void refreshCode(panel)
  }
  // 连接恢复/登记完成后自动补一张码；取码失败后不自动重试（会把中转打爆，
  // 也让"重试"按钮失去意义），由用户点按钮重试。
  if (state.status?.connected === true && !needsEnroll(state.status)
      && !state.code && !state.codeError && !state.busy) {
    void refreshCode(panel)
  }
}
function openPanel(panel) {
  if (panel.disposed) return
  // 自愈：样式若在某次热更里被带走（见 ensureStyle 的头注），打开面板时补回来。
  if (!panel.style?.node?.isConnected) panel.style = ensureStyle()
  panel.store.set({ open: true, now: Date.now(), copied: false })
  panel.lastStatusAt = Date.now()
  void loadStatus(panel).then((status) => {
    if (!panel.disposed && status?.connected === true && !needsEnroll(status)) {
      void refreshCode(panel)
      void loadPairedDevices(panel)
    }
  })
}
function closePanel(panel) {
  if (panel.disposed) return
  // 032：**不丢码**。持久码要一直有效，关掉面板再打开必须还是同一张——否则用户刚发给
  // 别人的码就被这次开关悄悄换掉了（旧实现丢码是对的，因为那时码是一次性的）。
  panel.store.set({ open: false, codeError: null, copied: false })
}
function disposePanel(panel) {
  panel.disposed = true
  if (panel.idleTimer) clearInterval(panel.idleTimer)
  if (panel.tickTimer) clearInterval(panel.tickTimer)
  if (panel.copiedTimer) clearTimeout(panel.copiedTimer)
  panel.idleTimer = null
  panel.tickTimer = null
  panel.copiedTimer = null
  releaseStyle(panel.style)
  panel.style = null
}
/** 插件启用时建立的页面资源；返回退场时用的清理函数。 */
function startPanel(panel) {
  panel.style = ensureStyle()
  panel.store.set({ now: Date.now() })
  void loadStatus(panel)
  panel.idleTimer = setInterval(() => {
    if (panel.disposed || panel.store.get().open) return
    void loadStatus(panel)
  }, IDLE_POLL_MS)
  panel.tickTimer = setInterval(() => tick(panel), 1000)
  return () => disposePanel(panel)
}
/** 复制配对码：选中态两秒后自己退回去。 */
function copyCode(panel) {
  const code = panel.store.get().code
  if (!code) return
  const done = () => {
    panel.store.set({ copied: true })
    if (panel.copiedTimer) clearTimeout(panel.copiedTimer)
    panel.copiedTimer = setTimeout(() => {
      if (!panel.disposed) panel.store.set({ copied: false })
    }, COPIED_MS)
  }
  try {
    void navigator.clipboard?.writeText(code.code).then(done, done)
  } catch {
    done()
  }
}
/** 服务端的机器码 → 面板上的中文；原始 message 留在 details 里给排障。 */
const ENROLL_ERRORS = {
  'enroll/bad-request': '请输入中转地址。',
  'enroll/invalid-relay': '中转地址无效。',
  'enroll/placeholder-relay': '请输入有效的中转地址。',
  'enroll/unknown': '激活码无效。',
  'enroll/used': '激活码已被使用。',
  'enroll/expired': '激活码已过期。',
  'enroll/rate-limited': '尝试次数过多，请稍后重试。',
  'enroll/unreachable': '无法连接中转服务器，请检查地址与网络。',
  'enroll/timeout': '中转服务器未响应，请稍后重试。',
  'enroll/bad-response': '中转服务器返回了无法识别的响应。',
  'enroll/already-registered': '此电脑已登记。',
  'enroll/disabled': '连接器已停用。',
  'enroll/unavailable': '连接器正在停止，请稍后重试。',
  'enroll/state-write': '登记信息未能保存到此电脑，请检查磁盘权限。',
  'enroll/relay-error': '中转服务器登记失败，请稍后重试。',
  'enroll/internal': '连接器内部错误，请稍后重试。',
}
function enrollMessage(error) {
  return ENROLL_ERRORS[error?.code] ?? describe(error) ?? '登记失败，请重试。'
}
function revokeMessage(error) {
  const code = error?.code
  if (code === 'request/unknown-device') return '设备不存在或已被撤销。'
  if (code === 'auth/agent-mismatch') return '这台设备不属于此电脑。'
  return '撤销失败，请稍后重试。'
}
/** 表单字段只改草稿；不在这里写“是否已登记”之类的业务状态。 */
function setEnrollField(panel, field, value) {
  if (panel.disposed) return
  if (field !== 'relay') return
  const draft = { ...panel.store.get().enrollDraft, [field]: String(value ?? '') }
  draft.relayTouched = true
  panel.store.set({ enrollDraft: draft, enrollError: null })
}
/**
 * 提交登记。
 *
 * 开放登记：只提交中转地址；电脑名称由连接器自动获取。成功时先乐观地切到
 * “已登记 / 正在连接”，随后用 `/status` 覆盖。
 */
async function submitEnroll(panel) {
  if (panel.disposed || panel.store.get().enrolling) return
  const state = panel.store.get()
  const status = state.status
  const draft = state.enrollDraft
  const locked = Boolean(status?.enroll?.relayLocked)
  const relayUrl = (locked
    ? status?.enroll?.relayPrefill
    : (draft.relayTouched ? draft.relay : status?.enroll?.relayPrefill) || '').trim()
  if (!relayUrl) {
    panel.store.set({
      enrollError: { code: 'enroll/bad-request', message: '请输入中转地址。' },
    })
    return
  }

  panel.store.set({ enrolling: true, enrollError: null })
  try {
    const body = await requestJson(ENROLL_ROUTE, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ relayUrl }),
    })
    if (panel.disposed) return
    const previous = panel.store.get().status ?? {}
    const enroll = previous.enroll ?? {}
    panel.store.set({
      enrolling: false,
      enrollDraft: { relay: '', relayTouched: false },
      enrollError: null,
      status: {
        ...previous,
        state: previous.connected ? previous.state : 'connecting',
        connected: previous.connected === true,
        relayUrl: body.relayUrl ?? previous.relayUrl,
        agentId: body.agentId ?? previous.agentId,
        agentName: body.agentName ?? previous.agentName,
        enroll: {
          ...enroll,
          registered: true,
          needsEnroll: false,
          relayUrl: body.relayUrl ?? enroll.relayUrl ?? null,
          hint: null,
          command: null,
        },
      },
      statusError: null,
    })
    const next = await loadStatus(panel)
    if (!panel.disposed && next?.connected === true && !needsEnroll(next)) {
      void refreshCode(panel)
      void loadPairedDevices(panel)
    }
  } catch (error) {
    if (panel.disposed) return
    panel.store.set({
      enrolling: false,
      enrollError: {
        code: error?.code ?? 'enroll/internal',
        message: enrollMessage(error),
        detail: describe(error),
      },
    })
  }
}

/** 打开撤销确认：只记录目标，不发送请求。 */
function requestRevoke(panel, device) {
  if (panel.disposed || !device?.deviceId) return
  panel.store.set({ revokeTarget: device, revokeError: null, guideOpen: false })
}
function cancelRevoke(panel) {
  if (panel.disposed || panel.store.get().revoking) return
  panel.store.set({ revokeTarget: null, revokeError: null })
}
/** 确认后才调用宿主路由；成功后刷新状态，失败留在确认窗口里。 */
async function confirmRevoke(panel) {
  const target = panel.store.get().revokeTarget
  if (panel.disposed || !target || panel.store.get().revoking) return
  panel.store.set({ revoking: true, revokeError: null })
  try {
    await requestJson(REVOKE_ROUTE, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: target.deviceId }),
    })
    if (panel.disposed) return
    panel.store.set({ revoking: false, revokeTarget: null, revokeError: null })
    await loadStatus(panel)
    await loadPairedDevices(panel)
  } catch (error) {
    if (panel.disposed) return
    panel.store.set({
      revoking: false,
      revokeError: { message: revokeMessage(error), detail: describe(error) },
    })
  }
}
function openGuide(panel) {
  if (panel.disposed) return
  panel.store.set({ guideOpen: true, revokeTarget: null, revokeError: null })
}
function closeGuide(panel) {
  if (panel.disposed) return
  panel.store.set({ guideOpen: false })
}

/**
 * 控制器：视图只读它的 store、只调它的动作。
 *
 * 032 起"码什么时候换"只有一处：用户点「重新生成」（`refreshCode({regenerate:true})`）。
 * 以前还有一条"配过一台就自动换一张"的规则，持久码下那条是错的——同一张码本来就
 * 要配多台设备。
 */
function createController() {
  const panel = createPanel()
  return {
    store: panel.store,
    open: () => openPanel(panel),
    close: () => closePanel(panel),
    refreshCode: (options) => refreshCode(panel, options),
    copy: () => copyCode(panel),
    toggleError: () => panel.store.set({ showError: !panel.store.get().showError }),
    enroll: () => submitEnroll(panel),
    setEnrollField: (field, value) => setEnrollField(panel, field, value),
    reloadStatus: () => { void loadStatus(panel).then(() => loadPairedDevices(panel)) },
    requestRevoke: (device) => requestRevoke(panel, device),
    cancelRevoke: () => cancelRevoke(panel),
    confirmRevoke: () => { void confirmRevoke(panel) },
    openGuide: () => openGuide(panel),
    closeGuide: () => closeGuide(panel),
    start: () => startPanel(panel),
  }
}

// ── 视图（官方原子组件拼装） ───────────────────────────────────────────────

function makeEntry(React, controller, ui) {
  return function MobileLinkEntry() {
    const state = useStore(React, controller.store)
    const conn = connectionState(state)
    return React.createElement(ui.Button, {
      variant: 'ghost', type: 'button', id: ENTRY_ID, className: 'dsh-mobile-link-entry',
      title: `${TITLE}（${conn.text}）`, 'aria-label': `${LABEL}：${conn.text}`,
      onClick: () => controller.open(),
    }, React.createElement(ui.StateDot, { state: conn.dot }),
    React.createElement('span', { className: 'dsh-mobile-link-entry-label' }, LABEL))
  }
}
function row(React, key, value, mono = false) {
  return React.createElement('div', { className: 'dsh-mobile-link-kv', key },
    React.createElement('span', { className: 'dsh-mobile-link-k' }, key),
    React.createElement('span', {
      className: mono ? 'dsh-mobile-link-v dsh-mobile-link-mono' : 'dsh-mobile-link-v',
    }, value))
}
/** 标题行 + 连接事实。 */
function statusSection(React, ui, state) {
  const conn = connectionState(state)
  return React.createElement('div', { className: 'dsh-mobile-link-section' },
    React.createElement('div', { className: 'dsh-mobile-link-status' },
      React.createElement(ui.StateDot, { state: conn.dot }),
      React.createElement('span', null, conn.text)),
    state.statusError ? React.createElement('div', { className: 'dsh-mobile-link-note dsh-mobile-link-error' },
      '无法读取连接状态。') : null,
    state.status && !needsEnroll(state.status)
      ? row(React, '中转服务器', state.status.relayUrl ?? '—', true)
      : null,
    state.status && !needsEnroll(state.status)
      ? row(React, '设备', deviceSummaryOf(state))
      : null)
}
/** 官方 Input 在旧宿主可能不存在；没有就用原生 input，表单不会因此消失。 */
function enrollInput(React, ui, props) {
  const official = ui?.Input != null
  const Input = official ? ui.Input : 'input'
  const { className, ...rest } = props
  return React.createElement(Input, official
    ? rest
    : { className: ['dsh-mobile-link-input', className].filter(Boolean).join(' '), ...rest })
}
function enrollField(React, id, labelText, children) {
  return React.createElement('div', { className: 'dsh-mobile-link-field', key: id },
    React.createElement('label', { className: 'dsh-mobile-link-label', htmlFor: id }, labelText),
    children)
}
/** 旧宿主没有面板登记能力时，退回命令行提示。 */
function enrollCommandSection(React, status) {
  return React.createElement('div', { className: 'dsh-mobile-link-section' },
    React.createElement('div', { className: 'dsh-mobile-link-note' },
      '此电脑尚未登记。请使用命令行完成登记：'),
    React.createElement('div', { className: 'dsh-mobile-link-mono dsh-mobile-link-v', style: { textAlign: 'left' } },
      status?.enroll?.command ?? 'dsh-mobile-link enroll --relay <中转地址>'))
}
/**
 * 未登记：开放登记。只提交中转地址；电脑名称由连接器自动获取。
 * 旧宿主没有 `enroll.panel` 时继续显示命令，作为半升级回退。
 */
function enrollSection(React, controller, ui, state) {
  const status = state.status
  if (status?.enroll?.panel !== true) return enrollCommandSection(React, status)
  if (status.enabled === false) {
    return React.createElement('div', { className: 'dsh-mobile-link-section' },
      React.createElement('div', { className: 'dsh-mobile-link-note' },
        '连接器已停用。请在插件配置中启用后重试。'))
  }
  const enroll = status.enroll
  const locked = Boolean(enroll.relayLocked)
  const prefill = typeof enroll.relayPrefill === 'string' ? enroll.relayPrefill : ''
  const draft = state.enrollDraft ?? { relay: '', relayTouched: false }
  const relayValue = locked ? prefill : (draft.relayTouched ? draft.relay : prefill)
  const submitting = Boolean(state.enrolling)
  const error = state.enrollError
  const setField = (field) => (event) => controller.setEnrollField(field, event?.target?.value ?? '')
  const submitOnEnter = (event) => {
    if (event?.key !== 'Enter') return
    event.preventDefault?.()
    if (!submitting) controller.enroll()
  }
  const command = enroll.command ?? 'dsh-mobile-link enroll --relay <中转地址>'

  return React.createElement('div', { className: 'dsh-mobile-link-form' },
    React.createElement('div', { className: 'dsh-mobile-link-note', key: 'intro' },
      '登记此电脑以连接中转服务器。'),
    enrollField(React, 'mobile-link-relay', '中转地址',
      enrollInput(React, ui, {
        id: 'mobile-link-relay', type: 'text', inputMode: 'url', value: relayValue,
        placeholder: 'wss://<中转地址>/dsh-link', readOnly: locked, disabled: submitting,
        autoComplete: 'off', spellCheck: false,
        onChange: setField('relay'), onKeyDown: submitOnEnter,
      })),
    React.createElement('div', { className: 'dsh-mobile-link-note', key: 'relay-hint' },
      locked ? '由配置指定，不可修改。' : '已预填，可修改。'),
    error ? React.createElement('div', {
      className: 'dsh-mobile-link-error-inline', role: 'alert', key: 'error',
      title: error.detail ?? undefined,
    }, error.message) : null,
    React.createElement(ui.Button, {
      key: 'submit', variant: 'primary', type: 'button', disabled: submitting,
      onClick: () => controller.enroll(),
    }, submitting ? '正在登记…' : (error ? '重试' : '登记')),
    React.createElement('div', { className: 'dsh-mobile-link-note', key: 'footnote' },
      '登记后将自动连接。'),
    React.createElement('details', { className: 'dsh-mobile-link-cmd', key: 'cli' },
      React.createElement('summary', null, '命令行登记（适用于无界面环境）'),
      React.createElement('div', { className: 'dsh-mobile-link-mono' }, command)))
}
function githubSection(React) {
  return React.createElement('div', { className: 'dsh-mobile-link-github', key: 'github' },
    React.createElement('div', { className: 'dsh-mobile-link-github-line' },
      React.createElement('span', { className: 'dsh-mobile-link-k' }, 'GitHub 仓库'),
      React.createElement('a', { href: GITHUB_URL, target: '_blank', rel: 'noreferrer' },
        'github.com/jayantTang/DSH_Mobile')),
    React.createElement('div', { className: 'dsh-mobile-link-welcome' },
      '欢迎在 GitHub 上为项目加星标。'))
}
function iosLinkSection(React, controller) {
  return React.createElement('div', { className: 'dsh-mobile-link-ioslink', key: 'ios-link' },
    React.createElement('span', null, '尚未安装 iOS App？'),
    React.createElement('a', {
      href: '#', onClick: (event) => { event?.preventDefault?.(); controller.openGuide() },
    }, '查看安装方式'))
}
/**
 * 二维码卡。默认是持久码，所以写“长期有效直到重新生成”，不再有倒计时；
 * 限时码（老中转/显式请求）仍然显示剩余时间。
 */
function codeSection(React, controller, ui, state) {
  const code = state.code
  const connecting = !code && !state.codeError && state.status?.connected !== true
  const children = []
  if (code) {
    children.push(React.createElement('div', { className: 'dsh-mobile-link-code', key: 'code' }, code.code))
    children.push(React.createElement('img', {
      key: 'qr', className: 'dsh-mobile-link-qr', alt: '配对二维码',
      src: `data:image/svg+xml;charset=utf-8,${encodeURIComponent(String(code.svg))}`,
    }))
    if (code.persistent || code.expiresAt == null) {
      children.push(React.createElement('div', { className: 'dsh-mobile-link-count', key: 'count' },
        React.createElement('span', null,
          `长期有效直到重新生成${code.maxPairedDevices
            ? `（已配对 ${state.pairedCount ?? (Array.isArray(state.pairedDevices)
              ? state.pairedDevices.length : (code.pairedDevices ?? 0))}/${code.maxPairedDevices}）` : ''}`)))
    } else {
      const remaining = Math.max(0, code.expiresAt - state.now)
      const percent = Math.max(0, Math.min(100, (remaining / (code.ttlMs || CODE_TTL_MS)) * 100))
      children.push(React.createElement('div', { className: 'dsh-mobile-link-count', key: 'count' },
        React.createElement('div', { className: 'dsh-mobile-link-bar' }, React.createElement('i', { style: { width: `${percent.toFixed(1)}%` } })),
        React.createElement('span', null, `有效期至 ${clockText(code.expiresAt)}（剩余 ${remainingText(remaining)}）`)))
    }
  } else if (state.codeError) {
    children.push(React.createElement('div', { className: 'dsh-mobile-link-note dsh-mobile-link-error', key: 'err' }, state.codeError))
  } else if (connecting) {
    children.push(React.createElement('div', { className: 'dsh-mobile-link-note', key: 'connecting' },
      state.enrolling ? '正在登记…' : '正在连接…'))
  } else {
    children.push(React.createElement('div', { className: 'dsh-mobile-link-note', key: 'loading' },
      state.busy ? '正在获取…' : '暂无配对码。'))
  }
  const buttons = connecting ? [] : [React.createElement(ui.Button, {
    key: 'swap', variant: 'primary', type: 'button', disabled: Boolean(state.busy),
    onClick: () => void controller.refreshCode({ regenerate: Boolean(state.code) }),
  }, state.busy ? '正在获取…'
    : (state.codeError ? '重试' : (state.code ? '重新生成' : '获取配对码')))]
  if (code) {
    buttons.push(React.createElement(ui.Button, {
      key: 'copy', variant: 'outline', type: 'button', onClick: () => controller.copy(),
    }, state.copied ? '已复制' : '复制配对码'))
  }
  children.push(React.createElement('div', { className: 'dsh-mobile-link-actions', key: 'actions' }, buttons))
  return React.createElement('div', { className: 'dsh-mobile-link-card' }, children)
}
function deviceRow(React, ui, device, online, controller) {
  const meta = [device.model, clientLabel(device.client)].filter(Boolean).join(' · ')
  return React.createElement('div', { className: 'dsh-mobile-link-device', key: device.deviceId ?? device.name },
    React.createElement(ui.StateDot, { state: online ? 'done' : 'idle' }),
    React.createElement('div', { style: { minWidth: 0 } },
      React.createElement('div', { className: 'dsh-mobile-link-device-line' },
        React.createElement('div', { className: 'dsh-mobile-link-device-name' }, device.name ?? '未命名设备'),
        React.createElement(ui.Tag, { tone: online ? 'success' : 'quiet', className: 'dsh-mobile-link-tag' },
          online ? '在线' : '离线')),
      meta ? React.createElement('div', { className: 'dsh-mobile-link-device-meta' }, meta) : null),
    React.createElement('button', {
      type: 'button', className: 'dsh-mobile-link-revoke',
      onClick: () => controller.requestRevoke(device),
    }, '撤销'))
}
function devicesSection(React, ui, state, controller) {
  const devices = pairedRows(state)
  const rows = devices.length === 0
    ? [React.createElement('div', { className: 'dsh-mobile-link-note', key: 'none' }, '暂无已配对设备。')]
    : devices.map((device) => deviceRow(React, ui, device, device.online, controller))
  return React.createElement('div', { className: 'dsh-mobile-link-section' },
    React.createElement('div', { className: 'dsh-mobile-link-section-title' }, '已配对设备'),
    React.createElement('div', { className: 'dsh-mobile-link-devices' }, rows),
    state.pairedError
      ? React.createElement('div', { className: 'dsh-mobile-link-note dsh-mobile-link-error' },
        state.pairedError)
      : null)
}
/** 最近一次失败：平时收起来。 */
function errorSection(React, controller, ui, status, open) {
  if (!status?.lastError) return null
  return React.createElement(ui.DisclosureRow, {
    title: '上次错误', open: Boolean(open), expandable: true,
    onToggle: () => controller.toggleError(),
  }, React.createElement('div', { className: 'dsh-mobile-link-mono dsh-mobile-link-error' }, status.lastError))
}
/** 撤销确认：浮层叠加在扫码页上，不重复设备列表。 */
function revokeOverlay(React, ui, state, controller) {
  const target = state.revokeTarget
  if (!target) return null
  const name = target.name ?? '这台设备'
  return React.createElement('div', { className: 'dsh-mobile-link-overlay', key: 'revoke-overlay' },
    React.createElement('div', {
      className: 'dsh-mobile-link-alert', role: 'dialog', 'aria-modal': 'true',
      'aria-label': '撤销这台设备',
    },
      React.createElement('div', { className: 'dsh-mobile-link-alert-title' }, '撤销这台设备？'),
      React.createElement('div', { className: 'dsh-mobile-link-note' },
        `“${name}”将无法继续连接。需要重新扫码才能再次配对。`),
      state.revokeError ? React.createElement('div', { className: 'dsh-mobile-link-error-inline', role: 'alert' },
        state.revokeError.message) : null,
      React.createElement('div', { className: 'dsh-mobile-link-alert-actions' },
        React.createElement(ui.Button, {
          variant: 'outline', type: 'button', disabled: Boolean(state.revoking),
          onClick: () => controller.cancelRevoke(),
        }, '取消'),
        React.createElement('button', {
          type: 'button', className: 'dsh-mobile-link-danger', disabled: Boolean(state.revoking),
          onClick: () => controller.confirmRevoke(),
        }, state.revoking ? '撤销中…' : '撤销设备'))))
}
/** iOS 安装指引：只给 TestFlight 公开链接。 */
function guideOverlay(React, ui, controller) {
  return React.createElement('div', { className: 'dsh-mobile-link-overlay', key: 'guide-overlay' },
    React.createElement('div', {
      className: 'dsh-mobile-link-guide', role: 'dialog', 'aria-modal': 'true',
      'aria-label': '安装 DSH Mobile',
    },
      React.createElement('div', { className: 'dsh-mobile-link-guide-title' }, '安装 DSH Mobile'),
      React.createElement('div', { className: 'dsh-mobile-link-note' }, '在 iPhone 或 iPad 上通过 TestFlight 安装。'),
      React.createElement('div', { className: 'dsh-mobile-link-step' },
        React.createElement('span', { className: 'dsh-mobile-link-step-n' }, '1'),
        React.createElement('span', { className: 'dsh-mobile-link-step-t' }, '从 App Store 安装 TestFlight。')),
      React.createElement('div', { className: 'dsh-mobile-link-step' },
        React.createElement('span', { className: 'dsh-mobile-link-step-n' }, '2'),
        React.createElement('span', { className: 'dsh-mobile-link-step-t' }, '打开 TestFlight 邀请链接，安装 DSH Mobile。')),
      React.createElement('div', { className: 'dsh-mobile-link-step' },
        React.createElement('span', { className: 'dsh-mobile-link-step-n' }, '3'),
        React.createElement('span', { className: 'dsh-mobile-link-step-t' }, '打开 DSH Mobile，扫描电脑上的配对二维码。')),
      React.createElement('a', {
        className: 'dsh-mobile-link-testflight', href: TESTFLIGHT_URL, target: '_blank', rel: 'noreferrer',
      }, TESTFLIGHT_URL),
      React.createElement('div', { className: 'dsh-mobile-link-note' }, '需要 iOS 17、iPadOS 17 或更高版本。'),
      React.createElement(ui.Button, {
        variant: 'primary', type: 'button', onClick: () => controller.closeGuide(),
      }, '完成')))
}
function panelBody(React, controller, ui, state) {
  const children = [statusSection(React, ui, state)]
  if (!state.status) {
    children.push(React.createElement('div', { className: 'dsh-mobile-link-note', key: 'loading' },
      state.statusError ? '无法读取连接状态。' : '正在读取状态…'))
    if (state.statusError) {
      children.push(React.createElement(ui.Button, {
        key: 'retry', variant: 'outline', type: 'button', onClick: () => controller.reloadStatus(),
      }, '重试'))
    }
    return React.createElement('div', { className: 'dsh-mobile-link-body' }, children)
  }
  if (needsEnroll(state.status)) {
    children.push(enrollSection(React, controller, ui, state))
    return React.createElement('div', { className: 'dsh-mobile-link-body' }, children)
  }
  children.push(codeSection(React, controller, ui, state))
  children.push(githubSection(React))
  children.push(iosLinkSection(React, controller))
  children.push(devicesSection(React, ui, state, controller))
  const error = errorSection(React, controller, ui, state.status, state.showError)
  if (error) children.push(error)
  if (state.revokeTarget) children.push(revokeOverlay(React, ui, state, controller))
  if (state.guideOpen) children.push(guideOverlay(React, ui, controller))
  return React.createElement('div', { className: 'dsh-mobile-link-body' }, children)
}
/** 小窗：官方 Modal 负责遮罩、顶层 Esc 与焦点归位；内容只在打开时渲染。 */
function makePanel(React, controller, ui) {
  return function MobileLinkPanel() {
    const state = useStore(React, controller.store)
    return React.createElement(ui.Modal, {
      open: state.open,
      onClose: () => controller.close(),
      title: LABEL,
      closeLabel: '关闭',
      className: 'dsh-mobile-link-dialog',
    }, panelBody(React, controller, ui, state))
  }
}

window.__ModuleLoader__.load({
  id: 'dsh-plugin-mobile-link',
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })
    const React = require('react')
    let ui
    try {
      ui = require(PRIMITIVES)
    } catch (error) {
      ui = undefined
    }
    /** 两个入口各自降级：一个注册不上，另一个仍然可用。 */
    function apply(ctx) {
      if (!ui?.Modal || !ui?.Button || !ui?.StateDot) {
        // 官方原子组件是平台 seed 字（宿主启动时就冻结在模块表里），正常不会缺；缺了说明
        // 宿主形态不对，此时宁可不注册，也不摆一个与官方视觉无关的入口。
        report(ctx, '官方原子组件不可用，移动端连接入口未注册')
        return
      }
      const controller = createController()
      try {
        ctx.effect(() => controller.start(), 'mobile-link: panel state')
      } catch (error) {
        report(ctx, `面板状态层没起来：${describe(error)}`)
      }
      try {
        ctx.slots.inject(SLOT_ENTRY, () => ctx.slots.register(
          { name: SLOT_ENTRY, id: ENTRY_ID, order: 20, label: () => LABEL },
          makeEntry(React, controller, ui),
        ))
      } catch (error) {
        report(ctx, `侧栏入口没注册上：${describe(error)}`)
      }
      try {
        ctx.slots.inject(SLOT_OVERLAY, () => ctx.slots.register(
          { name: SLOT_OVERLAY, id: PANEL_ID },
          makePanel(React, controller, ui),
        ))
      } catch (error) {
        report(ctx, `小窗没注册上：${describe(error)}`)
      }
    }

    exports.inject = ['slots']
    exports.apply = apply

    return module.exports
  },
})
})()

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
/** 小窗打开时的状态轮询间隔；关闭时只为让侧栏状态点别停在旧值上。 */
const OPEN_POLL_MS = 2500
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
  '.dsh-mobile-link-dialog{width:min(420px,94vw)}',
  '.dsh-mobile-link-body{display:flex;flex-direction:column;gap:16px}',
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
  '.dsh-mobile-link-device .dsh-mobile-link-tag{margin-left:auto}',
  '.dsh-mobile-link-error{color:var(--dsw-alias-state-error-primary,#d1242f)}',
  '.dsh-mobile-link-note{font-size:12px;line-height:1.65;color:var(--dsw-alias-label-tertiary,inherit)}',
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
/** 样式表：页面上只留一份，退场时随插件 fiber 一起清掉。 */
function ensureStyle() {
  if (typeof document === 'undefined' || !document.head) return null
  const existing = document.getElementById(STYLE_ID)
  if (existing) return existing
  const style = document.createElement('style')
  style.id = STYLE_ID
  style.textContent = CSS
  document.head.appendChild(style)
  return style
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
    throw new Error(body?.message ?? `连接器应答 HTTP ${response.status}`)
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
  if (!state.status) return { dot: 'ongoing', text: '正在读取连接状态' }
  if (needsEnroll(state.status)) return { dot: 'error', text: '这台电脑还没登记到中转' }
  if (state.status.enabled === false) return { dot: 'idle', text: '连接器已停用' }
  if (state.status.connected) return { dot: 'done', text: '已连接中转' }
  return { dot: 'warning', text: '未连接，正在重连' }
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
  if (list.length === 0) return '还没有手机配对过'
  const online = list.filter((device) => device.offlineSince === null || device.offlineSince === undefined).length
  return online === list.length ? `在线 ${online} 台` : `在线 ${online} 台 · 共 ${list.length} 台`
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
    if (panel.disposed) return
    panel.store.set({ status, statusError: null })
  } catch (error) {
    if (panel.disposed) return
    panel.store.set({ statusError: describe(error) })
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
  // 持久码不因时间换码（032）：只有用户点「重新生成」才换。限时码（老中转/老调用方）
  // 仍然按原来的规则在快过期时换一张，免得把一张马上就要失效的码摆在屏幕上。
  const code = panel.store.get().code
  if (code && !code.persistent && code.expiresAt != null && code.expiresAt - now <= CODE_FLOOR_MS) {
    void refreshCode(panel)
  }
}
function openPanel(panel) {
  if (panel.disposed) return
  panel.store.set({ open: true, now: Date.now(), copied: false })
  panel.lastStatusAt = Date.now()
  void loadStatus(panel)
  void refreshCode(panel)
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
  panel.style?.remove?.()
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
      `${state.statusError}（连接器可能刚重启，或插件没装进当前宿主）`) : null,
    row(React, '中转', state.status?.relayUrl ?? '—', true),
    state.status?.agentName ? row(React, '电脑', state.status.agentName) : null,
    state.status ? row(React, '手机', deviceSummary(state.status.devices)) : null)
}
/** 未登记：给命令，不给二维码（FR-008）。 */
function enrollSection(React, status) {
  return React.createElement('div', { className: 'dsh-mobile-link-section' },
    React.createElement('div', { className: 'dsh-mobile-link-note' },
      '这台电脑还没有登记到中转。登记是一次性的，登记完重启 DSH 就能扫码配对：'),
    React.createElement('div', { className: 'dsh-mobile-link-mono dsh-mobile-link-v', style: { textAlign: 'left' } },
      status?.enroll?.command ?? 'dsh-mobile-link enroll --invite <邀请码> --relay <中转地址>'))
}
/**
 * 二维码卡。
 *
 * 032 之前这里是"倒计时 + 换一张"（一次性码，10 分钟）。现在默认是**持久码**：
 * 所以卡片上写"长期有效，直到你点重新生成"，并且不再有进度条——一个永远走不到头的
 * 倒计时只会让人以为码快过期了。限时码（老中转/显式请求）仍然显示倒计时与剩余时间。
 */
function codeSection(React, controller, ui, state) {
  const code = state.code
  const children = []
  if (code) {
    children.push(React.createElement('div', { className: 'dsh-mobile-link-code', key: 'code' }, code.code))
    // 二维码：宿主给的 SVG 直接进 data URI，界面不碰图案本身。
    children.push(React.createElement('img', {
      key: 'qr', className: 'dsh-mobile-link-qr', alt: '配对二维码',
      src: `data:image/svg+xml;charset=utf-8,${encodeURIComponent(String(code.svg))}`,
    }))
    if (code.persistent || code.expiresAt == null) {
      children.push(React.createElement('div', { className: 'dsh-mobile-link-count', key: 'count' },
        React.createElement('span', null,
          `长期有效 · 直到你点「重新生成」${code.maxPairedDevices
            ? `（已配对 ${code.pairedDevices ?? 0}/${code.maxPairedDevices}）` : ''}`)))
    } else {
      const remaining = Math.max(0, code.expiresAt - state.now)
      const percent = Math.max(0, Math.min(100, (remaining / (code.ttlMs || CODE_TTL_MS)) * 100))
      children.push(React.createElement('div', { className: 'dsh-mobile-link-count', key: 'count' },
        React.createElement('div', { className: 'dsh-mobile-link-bar' }, React.createElement('i', { style: { width: `${percent.toFixed(1)}%` } })),
        React.createElement('span', null, `有效期至 ${clockText(code.expiresAt)}（还剩 ${remainingText(remaining)}）`)))
    }
  } else if (state.codeError) {
    children.push(React.createElement('div', { className: 'dsh-mobile-link-note dsh-mobile-link-error', key: 'err' }, state.codeError))
  } else {
    children.push(React.createElement('div', { className: 'dsh-mobile-link-note', key: 'loading' },
      state.busy ? '正在向中转取一张新码…' : '还没有可用的配对码。'))
  }
  const buttons = [React.createElement(ui.Button, {
    key: 'swap', variant: 'primary', type: 'button', disabled: Boolean(state.busy),
    onClick: () => void controller.refreshCode({ regenerate: Boolean(state.code) }),
  }, state.busy ? '取码中…'
    : (state.codeError ? '重试' : (state.code ? '重新生成' : '取一张码')))]
  if (code) {
    buttons.push(React.createElement(ui.Button, {
      key: 'copy', variant: 'outline', type: 'button', onClick: () => controller.copy(),
    }, state.copied ? '已复制' : '复制配对码'))
  }
  children.push(React.createElement('div', { className: 'dsh-mobile-link-actions', key: 'actions' }, buttons))
  return React.createElement('div', { className: 'dsh-mobile-link-card' }, children)
}
function deviceRow(React, ui, device) {
  const online = device.offlineSince === null || device.offlineSince === undefined
  const meta = [device.model, clientLabel(device.client)].filter(Boolean).join(' · ')
  return React.createElement('div', { className: 'dsh-mobile-link-device', key: device.deviceId ?? device.name },
    React.createElement(ui.StateDot, { state: online ? 'done' : 'idle' }),
    React.createElement('div', { style: { minWidth: 0 } },
      React.createElement('div', { className: 'dsh-mobile-link-device-name' }, device.name ?? '未命名设备'),
      meta ? React.createElement('div', { className: 'dsh-mobile-link-device-meta' }, meta) : null),
    React.createElement(ui.Tag, { tone: online ? 'success' : 'quiet', className: 'dsh-mobile-link-tag' },
      online ? '在线' : '离线'))
}
function devicesSection(React, ui, status) {
  const devices = Array.isArray(status?.devices) ? status.devices : []
  const rows = devices.length === 0
    ? [React.createElement('div', { className: 'dsh-mobile-link-note', key: 'none' }, '还没有手机配对过。')]
    : devices.map((device) => deviceRow(React, ui, device))
  return React.createElement('div', { className: 'dsh-mobile-link-section' },
    React.createElement('div', { className: 'dsh-mobile-link-section-title' }, '已配对的手机'),
    React.createElement('div', { className: 'dsh-mobile-link-devices' }, rows))
}
/** 最近一次失败：平时收起来，别让一行红字天天抢注意力。 */
function errorSection(React, controller, ui, status, open) {
  if (!status?.lastError) return null
  return React.createElement(ui.DisclosureRow, {
    title: '最近一次错误', open: Boolean(open), expandable: true,
    onToggle: () => controller.toggleError(),
  }, React.createElement('div', { className: 'dsh-mobile-link-mono dsh-mobile-link-error' }, status.lastError))
}
function panelBody(React, controller, ui, state) {
  const children = [statusSection(React, ui, state)]
  if (needsEnroll(state.status)) children.push(enrollSection(React, state.status))
  else children.push(codeSection(React, controller, ui, state))
  children.push(devicesSection(React, ui, state.status))
  const error = errorSection(React, controller, ui, state.status, state.showError)
  if (error) children.push(error)
  children.push(React.createElement('div', { className: 'dsh-mobile-link-note', key: 'hint' },
    '用 DSH Mobile App 扫码配对：这串码长期有效，可以配多台设备（手机／浏览器）。'
    + '换掉它点「重新生成」——已经在用的设备不会掉线，只有拿旧码来配的人需要重新扫。'
    + '相机不方便时，也可以把上面那串配对码手动输进 App 连接页底部的手输入口。'))
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

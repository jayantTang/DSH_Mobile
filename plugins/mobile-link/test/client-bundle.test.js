import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

/**
 * 客户端半边是手写的 `__ModuleLoader__` bundle，跑在浏览器里；这里用最小 stub 把它在 Node 里
 * 执行一遍，断言五类事情：
 *
 *   1. **形状**——宿主能否加载它（CJS 命名空间、包名一致、只 require 平台 seed 字）；
 *   2. **入口**——侧栏按钮与浮层各注册一次，状态点跟着连接状态走；
 *   3. **取码**——每次打开都取一张新码；被兑换（在线设备数增长）或快过期时自动换；
 *      取码失败要看得见，且不许把旧码继续摆在屏幕上；
 *   4. **界面拼装**——浮层走官方 `Modal`（遮罩/Esc/焦点归位都不是自己写的），按钮用官方
 *      `Button`，状态点用官方 `StateDot`；拿不到官方组件时退回等价原生元素，入口仍在；
 *   5. **热插拔与失败隔离**——禁用后入口与定时器归零、再启用原样回来；注册表抛错时 apply 不抛。
 *
 * 真实界面上的观感与行为由慢闸（真实宿主 + 浏览器 + 手机扫屏幕）验，单测只锁契约。
 */

const SOURCE = readFileSync(new URL('../lib/client.js', import.meta.url), 'utf8')
const STYLE_ID = 'dsh-mobile-link-style'
const ENTRY_ID = 'mobile-link-entry'
const PANEL_ID = 'mobile-link-panel'
const PRIMITIVES = '@deepseek-ai/dsh-client-ui-primitives'

function makeDom() {
  const nodes = []
  const listeners = []
  const document = {
    head: { appendChild: (node) => nodes.push(node) },
    body: { appendChild: (node) => nodes.push(node) },
    getElementById: (id) => nodes.find((node) => node.id === id) ?? null,
    createElement: () => ({
      id: '',
      textContent: '',
      style: {},
      attrs: {},
      setAttribute(key, value) { this.attrs[key] = String(value); this[key] = value },
      getAttribute(key) { return this.attrs[key] ?? null },
      remove() {
        const index = nodes.indexOf(this)
        if (index >= 0) nodes.splice(index, 1)
      },
    }),
    addEventListener: (type, handler) => listeners.push({ type, handler }),
    removeEventListener: (type, handler) => {
      const index = listeners.findIndex((entry) => entry.type === type && entry.handler === handler)
      if (index >= 0) listeners.splice(index, 1)
    },
  }
  return { document, nodes, listeners }
}

/** 官方 store 语义的最小替身：读当时的快照即可，无需真正的订阅通知。 */
function fakeReact() {
  return {
    createElement: (type, props, ...children) => ({ type, props: props ?? {}, children }),
    useSyncExternalStore: (_subscribe, getSnapshot) => getSnapshot(),
  }
}

/**
 * 官方原子组件的替身：只把 props 与 children 原样带出来，方便断言"用的是哪一个官方组件、
 * 传了什么"。行为（遮罩、Esc、焦点）属于官方实现，不在这里重复测。
 */
function fakePrimitives() {
  const passthrough = (type) => (props) => ({ type, props, children: props.children ?? [] })
  return {
    Button: (props) => ({ type: 'button', props, children: props.children ?? [] }),
    Input: (props) => ({ type: 'input', props, children: [] }),
    StateDot: ({ state }) => ({ type: 'dot', props: { state }, children: [] }),
    Tag: ({ tone, children }) => ({ type: 'tag', props: { tone }, children: [children] }),
    Modal: ({ open, title, onClose, className, children }) => (open
      ? { type: 'modal', props: { title, onClose, className }, children: [children] }
      : null),
    DisclosureRow: passthrough('disclosure'),
  }
}

const PANEL_STATUS = {
  ok: true,
  enabled: true,
  state: 'idle',
  connected: false,
  relayUrl: null,
  agentName: null,
  deviceCount: 0,
  devices: [],
  lastError: null,
  enroll: {
    registered: false,
    needsEnroll: true,
    panel: true,
    relayPrefill: 'wss://relay.test/dsh-link',
    relayLocked: false,
    command: 'dsh-mobile-link enroll --invite <邀请码> --relay wss://relay.test/dsh-link',
    hint: '先登记',
  },
}

const HEALTHY_STATUS = {
  ok: true,
  enabled: true,
  state: 'connected',
  connected: true,
  relayUrl: 'wss://relay.test/dsh-link',
  agentName: '书房的 Mac',
  deviceCount: 0,
  devices: [],
  lastError: null,
  enroll: { registered: true, needsEnroll: false, command: null, hint: null },
}

/**
 * fetch 替身：按路径分派，记录每次调用，可按需让状态或取码失败。
 * 取码每次给一张**不同的**码与图案——"每次都新签"正是被断言的行为。
 */
function makeFetch({ status = HEALTHY_STATUS, failStatus = false, failCode = false,
                     ttlMs = null, maxPairedDevices = 8, pairedDevices = 0,
                     failEnroll = null, onEnroll = null, enrollBody = {} } = {}) {
  const calls = []
  let mints = 0
  const impl = async (path, init) => {
    calls.push({ path, init })
    const json = (body) => ({ ok: true, status: 200, json: async () => body })
    if (String(path).includes('status')) {
      if (failStatus) throw new Error('fetch failed')
      return json({ ...status })
    }
    if (String(path).includes('enroll')) {
      if (failEnroll) {
        return json({ ok: false, code: failEnroll, message: `enrollment failed: ${failEnroll}` })
      }
      onEnroll?.()
      return json({
        ok: true,
        agentId: 'agt_panel',
        agentName: 'Panel Mac',
        relayUrl: 'wss://relay.test/dsh-link',
        ...enrollBody,
      })
    }
    if (failCode) return json({ ok: false, message: '中转不可达' })
    mints += 1
    // 032：面板请求的是**持久码**（不带 ttlMs），中转回 expiresAt:null。
    // 要测限时码那条分支就用 `ttlMs` 选项。
    const persistent = ttlMs == null
    return json({
      ok: true,
      persistent,
      code: `CODE-000${mints}`,
      qrPayload: `dsh://pair?relay=wss%3A%2F%2Frelay.test%2Fdsh-link&code=CODE-000${mints}`,
      svg: `<svg id="qr-${mints}"></svg>`,
      expiresAt: persistent ? null : Date.now() + ttlMs,
      ttlMs: ttlMs ?? null,
      maxPairedDevices,
      pairedDevices,
    })
  }
  return { impl, calls, mintCount: () => mints }
}

function loadBundle({ document, fetchImpl, clock, primitivesMissing = false } = {}) {
  const specs = []
  const timers = []
  const required = []
  const now = clock ?? { value: Date.now() }
  class FakeDate extends Date {
    constructor(...args) {
      super(...(args.length > 0 ? args : [now.value]))
    }

    static now() {
      return now.value
    }
  }
  const sandbox = {
    window: { __ModuleLoader__: { load: (spec) => specs.push(spec) } },
    document,
    fetch: fetchImpl ?? makeFetch().impl,
    setInterval: (fn, ms) => {
      const timer = { fn, ms }
      timers.push(timer)
      return timer
    },
    clearInterval: (timer) => {
      const index = timers.indexOf(timer)
      if (index >= 0) timers.splice(index, 1)
    },
    setTimeout, clearTimeout, encodeURIComponent, console, Date: FakeDate,
    Object, Symbol, JSON, String, Number, Boolean, Array, Math,
  }
  vm.runInNewContext(SOURCE, sandbox, { filename: 'client.js' })
  const spec = specs[0]
  const api = spec.factory((name) => {
    required.push(name)
    if (name === 'react') return fakeReact()
    if (name === PRIMITIVES) {
      if (primitivesMissing) throw new Error(`require("${name}") missed the module table`)
      return fakePrimitives()
    }
    throw new Error(`factory 只允许 require 平台 seed 字，收到 ${name}`)
  })
  const tick = () => {
    const oneSecond = timers.find((timer) => timer.ms === 1000)
    if (oneSecond) oneSecond.fn()
  }
  return { spec, api, timers, tick, clock: now, required }
}

/** 一个插件实例（fiber）的 stub：退出时按官方语义把注册与资源收回去。 */
function makeCtx({ registerThrows = false } = {}) {
  const state = { slots: [], slotKeys: [], cleanups: [], warnings: [] }
  const ctx = {
    effect: (callback) => {
      const cleanup = callback()
      if (typeof cleanup === 'function') state.cleanups.push(cleanup)
    },
    slots: {
      inject: (key, callback) => {
        state.slotKeys.push(key)
        const dispose = callback()
        if (typeof dispose === 'function') state.cleanups.push(dispose)
      },
      register: (spec, component) => {
        if (registerThrows) throw new Error('slot registry is busy')
        const entry = { spec, component }
        state.slots.push(entry)
        return () => state.slots.splice(state.slots.indexOf(entry), 1)
      },
    },
    logger: { warn: (message) => state.warnings.push(message) },
  }
  state.dispose = () => {
    for (const cleanup of state.cleanups.reverse()) cleanup()
    state.cleanups = []
  }
  return { ctx, state }
}

/**
 * 把元素树"渲染"出来：本测试的假 React 不自己渲染函数组件，所以遇到函数类型就调用它。
 * 这样断言看的就是真实渲染结果（官方组件替身返回的对象），而不是未展开的元素。
 */
function render(el) {
  if (!el || typeof el !== 'object') return el ?? null
  if (Array.isArray(el)) return el.map(render)
  const kids = el.children === undefined || el.children === null
    ? []
    : (Array.isArray(el.children) ? el.children : [el.children])
  if (typeof el.type === 'function') {
    return render(el.type({ ...el.props, children: kids.length <= 1 ? kids[0] : kids }))
  }
  return { ...el, children: kids.map(render) }
}

/** 深度优先找指定 id 的 input；元素树里可能嵌数组。 */
function findInputById(tree, id) {
  if (Array.isArray(tree)) {
    for (const item of tree) {
      const hit = findInputById(item, id)
      if (hit) return hit
    }
    return null
  }
  if (!tree || typeof tree !== 'object') return null
  if (tree.type === 'input' && tree.props?.id === id) return tree
  for (const child of tree.children ?? []) {
    const hit = findInputById(child, id)
    if (hit) return hit
  }
  return null
}

/** 让 fire-and-forget 的请求跑完（控制器不等它们）。 */
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function components(state) {
  return {
    entry: state.slots.find((slot) => slot.spec.name === 'sidebar.footer.action'),
    panel: state.slots.find((slot) => slot.spec.name === 'shell.overlay'),
  }
}

/** 深度优先找一个带某个 class 的元素。 */
function findByClass(tree, cls) {
  if (Array.isArray(tree)) {
    for (const item of tree) {
      const hit = findByClass(item, cls)
      if (hit) return hit
    }
    return null
  }
  if (!tree || typeof tree !== 'object') return null
  const className = tree.props?.className ?? ''
  if (String(className).includes(cls)) return tree
  for (const child of tree.children ?? []) {
    const hit = findByClass(child, cls)
    if (hit) return hit
  }
  return null
}

/** 深度优先找第一个 type 等于 `type` 的元素（数组会拆开继续找）。 */
function findByType(tree, type) {
  if (Array.isArray(tree)) {
    for (const item of tree) {
      const hit = findByType(item, type)
      if (hit) return hit
    }
    return null
  }
  if (!tree || typeof tree !== 'object') return null
  if (tree.type === type) return tree
  for (const child of tree.children ?? []) {
    const hit = findByType(child, type)
    if (hit) return hit
  }
  return null
}

/** 深度优先找一个 type 为 `type` 且文本里含 `text` 的元素。 */
function findByText(tree, type, text) {
  if (Array.isArray(tree)) {
    for (const item of tree) {
      const hit = findByText(item, type, text)
      if (hit) return hit
    }
    return null
  }
  if (!tree || typeof tree !== 'object') return null
  const flat = JSON.stringify(tree.children ?? [])
  if (tree.type === type && flat.includes(text)) return tree
  for (const child of tree.children ?? []) {
    const hit = findByText(child, type, text)
    if (hit) return hit
  }
  return null
}

test('the bundle declares the package id and the official CJS-namespace shape', () => {
  const { document } = makeDom()
  const { spec, api, required } = loadBundle({ document })
  assert.equal(spec.id, 'dsh-plugin-mobile-link', 'bundle id 必须等于包名，否则宿主图里找不到')
  assert.equal(typeof spec.factory, 'function')
  assert.equal(api[Symbol.toStringTag], 'Module', 'factory 必须返回 CJS 命名空间')
  assert.deepEqual([...api.inject], ['slots'])
  assert.equal(typeof api.apply, 'function')
  // 只允许平台 seed 字：react 与官方原子组件。
  assert.deepEqual(required, ['react', PRIMITIVES])
})

test('the sidebar gets one entry and the shell gets one panel', async () => {
  const { document, nodes } = makeDom()
  const { api } = loadBundle({ document })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()

  assert.deepEqual(state.slotKeys, ['sidebar.footer.action', 'shell.overlay'])
  const { entry, panel } = components(state)
  assert.equal(entry.spec.id, ENTRY_ID)
  assert.equal(panel.spec.id, PANEL_ID)
  assert.equal(nodes.filter((node) => node.id === STYLE_ID).length, 1, '样式只注入一份')

  const button = render(entry.component({}))
  assert.equal(button.type, 'button', '入口用官方 Button')
  assert.equal(button.props.id, ENTRY_ID)
  assert.equal(button.props.variant, 'ghost')
  assert.match(button.props['aria-label'], /移动端连接/)
})

test('the status dot answers the three questions a user has', async () => {
  // 注意别把这个局部函数叫 render：那会遮住上面那个渲染助手，变成自己调自己。
  const renderEntry = async (status) => {
    const { document } = makeDom()
    const fetchImpl = makeFetch({ status }).impl
    const { api } = loadBundle({ document, fetchImpl })
    const { ctx, state } = makeCtx()
    api.apply(ctx)
    await flush()
    return render(components(state).entry.component({}))
  }

  const connected = await renderEntry(HEALTHY_STATUS)
  assert.match(connected.props['aria-label'], /已连接中转/)
  assert.equal(connected.children[0].type, 'dot')
  assert.equal(connected.children[0].props.state, 'done')

  const offline = await renderEntry({ ...HEALTHY_STATUS, state: 'connecting', connected: false })
  assert.match(offline.props['aria-label'], /未连接/)
  assert.equal(offline.children[0].props.state, 'warning')

  const unregistered = await renderEntry({
    ...HEALTHY_STATUS,
    state: 'idle',
    connected: false,
    enroll: { registered: false, needsEnroll: true, command: 'dsh-mobile-link enroll --invite <code>', hint: '先登记' },
  })
  assert.match(unregistered.props['aria-label'], /还没登记到中转/)
  assert.equal(unregistered.children[0].props.state, 'error')
})

test('the panel is the official Modal: closed until the entry is clicked, then code + symbol', async () => {
  const { document } = makeDom()
  const fetch = makeFetch()
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()

  const { entry, panel } = components(state)
  assert.equal(render(panel.component({})), null, '没打开时官方 Modal 不渲染任何东西')

  render(entry.component({})).props.onClick()
  await flush()
  const tree = render(panel.component({}))
  assert.equal(tree.type, 'modal', '浮层走官方 Modal（遮罩、顶层 Esc、焦点归位归它管）')
  assert.equal(tree.props.title, '移动端连接')
  assert.equal(tree.props.className, 'dsh-mobile-link-dialog')
  const markup = JSON.stringify(tree)
  assert.match(markup, /dsh-mobile-link-qr/)
  assert.match(markup, /data:image\/svg\+xml/)
  assert.match(markup, /CODE-0001/, '配对码文本也要露出来，供手输')
  // 032：面板拿到的默认是持久码——没有倒计时，改为写"长期有效"与「已配对 N/8」。
  assert.match(markup, /长期有效/, '持久码要写清楚它不会自己过期')
  assert.match(markup, /已配对 0\/8/, '上限口径来自中转')
  assert.equal(fetch.calls.filter((call) => call.path.includes('pair-code')).length, 1)
})

test('a time-limited code still shows a live countdown and swaps before it dies', async () => {
  const { document } = makeDom()
  const clock = { value: Date.now() }
  const fetch = makeFetch({ ttlMs: 600_000 })
  const { api, tick } = loadBundle({ document, fetchImpl: fetch.impl, clock })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)

  render(entry.component({})).props.onClick()
  await flush()
  let markup = JSON.stringify(render(panel.component({})))
  assert.match(markup, /CODE-0001/)
  assert.match(markup, /还剩 10:00|还剩 9:5/, '限时码才有剩余时间')
  assert.match(markup, /dsh-mobile-link-bar/, '倒数条跟着剩余时间走')

  // 只剩 30 秒（不足以再扫一次），下一拍就该换一张。
  clock.value += 570_000
  tick()
  await flush()
  markup = JSON.stringify(render(panel.component({})))
  assert.match(markup, /CODE-0002/, '限时码快过期要换一张')
  assert.equal(fetch.calls.filter((call) => call.path.includes('pair-code')).length, 2)
  // 换码走的是同一个取码路由，不是「重新生成」：老语义下这里没有"作废旧码"这回事。
  assert.ok(!fetch.calls.some((call) => call.path.includes('regenerate')))
})


test('the regenerate button asks the relay for a new code and shows it', async () => {
  const { document } = makeDom()
  const fetch = makeFetch()
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)

  render(entry.component({})).props.onClick()
  await flush()
  assert.match(JSON.stringify(render(panel.component({}))), /CODE-0001/)

  const regenerate = findByText(render(panel.component({})), 'button', '重新生成')
  regenerate.props.onClick()
  await flush()

  const markup = JSON.stringify(render(panel.component({})))
  assert.match(markup, /CODE-0002/, '点了重新生成要换成新码')
  const regenerated = fetch.calls.filter((call) => call.path.includes('regenerate'))
  assert.equal(regenerated.length, 1, '走的是 /pair-code/regenerate')
  assert.equal(fetch.mintCount(), 2)
})


test('the panel offers the official Button for regenerate and copy', async () => {
  const { document } = makeDom()
  const fetch = makeFetch()
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)
  render(entry.component({})).props.onClick()
  await flush()

  const tree = render(panel.component({}))
  // 032：拿到码之后主按钮是「重新生成」（持久码不会自己过期，没必要"换一张"）。
  const swap = findByText(tree, 'button', '重新生成')
  const copy = findByText(tree, 'button', '复制配对码')
  assert.ok(swap, '主按钮是官方 Button')
  assert.equal(swap.props.variant, 'primary')
  assert.ok(copy)
  assert.equal(copy.props.variant, 'outline')

  copy.props.onClick()
  await flush()
  assert.match(JSON.stringify(render(panel.component({}))), /已复制/, '复制后按钮自己变文案')
})

test('closing and reopening keeps the same persistent code', async () => {
  const { document } = makeDom()
  const fetch = makeFetch()
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)

  render(entry.component({})).props.onClick()
  await flush()
  assert.match(JSON.stringify(render(panel.component({}))), /CODE-0001/)

  // 032：持久码要跨开关保持——否则用户刚发给别人的那张码会被这次开关悄悄换掉。
  render(panel.component({})).props.onClose()
  render(entry.component({})).props.onClick()
  await flush()
  const tree = render(panel.component({}))
  assert.match(JSON.stringify(tree), /CODE-0001/, '重开还是同一张')
  assert.equal(fetch.mintCount(), 1, '重开不该再向中转要一张')
})

test('a phone pairing does not rotate a persistent code', async () => {
  const { document } = makeDom()
  const clock = { value: Date.now() }
  const status = { ...HEALTHY_STATUS }
  const fetch = makeFetch({ status })
  const { api, tick } = loadBundle({ document, fetchImpl: fetch.impl, clock })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)

  render(entry.component({})).props.onClick()
  await flush()
  assert.match(JSON.stringify(render(panel.component({}))), /CODE-0001/)

  status.deviceCount = 1 // 一台手机刚用它配上来了
  clock.value += 3000   // 下一轮状态轮询（2.5s 一次）看到 1 台在线
  tick()
  await flush()
  await flush()
  assert.match(JSON.stringify(render(panel.component({}))), /CODE-0001/,
    '持久码不因为"配上一台"而换：同一张码本来就要配多台')
  assert.equal(fetch.mintCount(), 1)
})

test('a failed mint is visible and the dead code is taken off the screen', async () => {
  const { document } = makeDom()
  const fetch = makeFetch({ failCode: true })
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)

  render(entry.component({})).props.onClick()
  await flush()
  const markup = JSON.stringify(render(panel.component({})))
  assert.match(markup, /中转不可达/, '取不到码要说清原因')
  assert.doesNotMatch(markup, /dsh-mobile-link-qr/, '取不到码时不许摆一张旧图')
})

test('an unregistered computer is told what to run instead of being shown a code', async () => {
  const { document } = makeDom()
  const status = {
    ...HEALTHY_STATUS,
    state: 'idle',
    connected: false,
    enroll: { registered: false, needsEnroll: true, command: 'dsh-mobile-link enroll --invite <邀请码>', hint: '这台电脑还没有登记到中转' },
  }
  const fetch = makeFetch({ status })
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)

  render(entry.component({})).props.onClick()
  await flush()
  const markup = JSON.stringify(render(panel.component({})))
  assert.match(markup, /dsh-mobile-link enroll --invite/)
  assert.doesNotMatch(markup, /dsh-mobile-link-qr/)
  assert.equal(fetch.calls.filter((call) => call.path.includes('pair-code')).length, 0,
    '没登记就不该向中转要码')
})

test('an unregistered computer with panel capability gets the form, prefilled relay and no QR', async () => {
  const { document } = makeDom()
  const status = { ...PANEL_STATUS, enroll: { ...PANEL_STATUS.enroll } }
  const fetch = makeFetch({ status })
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)

  render(entry.component({})).props.onClick()
  await flush()
  const tree = render(panel.component({}))
  const markup = JSON.stringify(tree)
  assert.match(markup, /中转地址/)
  assert.match(markup, /激活码/)
  assert.match(markup, /登记并连接/)
  assert.doesNotMatch(markup, /dsh-mobile-link-qr/)
  assert.equal(fetch.calls.filter((call) => call.path.includes('pair-code')).length, 0)

  const relay = findInputById(tree, 'mobile-link-relay')
  const invite = findInputById(tree, 'mobile-link-invite')
  assert.equal(relay.props.value, 'wss://relay.test/dsh-link', '默认中转要预填')
  assert.equal(relay.props.readOnly, false, '默认中转只做预填，用户可改')
  assert.equal(invite.props.value, '', '激活码不预填')
})

test('an editable relay can be cleared and replaced without snapping back to the prefill', async () => {
  const { document } = makeDom()
  const status = {
    ...PANEL_STATUS,
    enroll: { ...PANEL_STATUS.enroll, relayLocked: false },
  }
  const fetch = makeFetch({ status })
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)
  render(entry.component({})).props.onClick()
  await flush()

  let tree = render(panel.component({}))
  const relay = () => findInputById(tree, 'mobile-link-relay')
  assert.equal(relay().props.value, 'wss://relay.test/dsh-link')
  relay().props.onChange({ target: { value: '' } })
  tree = render(panel.component({}))
  assert.equal(relay().props.value, '', 'clearing the field must not fall back to the default')
  relay().props.onChange({ target: { value: 'wss://other.test/dsh-link' } })
  tree = render(panel.component({}))
  assert.equal(relay().props.value, 'wss://other.test/dsh-link')
})

test('submitting the form posts the three fields and moves to the connected panel', async () => {
  const { document } = makeDom()
  const status = { ...PANEL_STATUS, enroll: { ...PANEL_STATUS.enroll } }
  const fetch = makeFetch({
    status,
    onEnroll: () => {
      status.enroll = {
        ...status.enroll, registered: true, needsEnroll: false,
        relayUrl: 'wss://relay.test/dsh-link', hint: null, command: null,
      }
      status.connected = true
      status.state = 'connected'
      status.relayUrl = 'wss://relay.test/dsh-link'
      status.agentId = 'agt_panel'
      status.agentName = 'Panel Mac'
    },
  })
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)
  render(entry.component({})).props.onClick()
  await flush()

  let tree = render(panel.component({}))
  findInputById(tree, 'mobile-link-invite').props.onChange({ target: { value: 'PANEL-CODE' } })
  tree = render(panel.component({}))
  const submit = findByText(tree, 'button', '登记并连接')
  submit.props.onClick()
  await flush()
  await flush()

  const call = fetch.calls.find((item) => item.path.includes('enroll'))
  assert.ok(call, 'submit must POST to the enrollment route')
  assert.deepEqual(JSON.parse(call.init.body), {
    relayUrl: 'wss://relay.test/dsh-link', inviteCode: 'PANEL-CODE', agentName: '',
  })
  const markup = JSON.stringify(render(panel.component({})))
  assert.match(markup, /CODE-0001/, 'after the status flips to connected the panel fetches a code')
  assert.doesNotMatch(markup, /登记并连接/)
})

test('after enrollment the panel says it is connecting instead of showing an empty code section', async () => {
  const { document } = makeDom()
  const status = { ...PANEL_STATUS, enroll: { ...PANEL_STATUS.enroll } }
  const fetch = makeFetch({
    status,
    onEnroll: () => {
      status.enroll = {
        ...status.enroll, registered: true, needsEnroll: false,
        relayUrl: 'wss://relay.test/dsh-link', hint: null, command: null,
      }
      status.connected = false
      status.state = 'connecting'
    },
  })
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)
  render(entry.component({})).props.onClick()
  await flush()

  let tree = render(panel.component({}))
  findInputById(tree, 'mobile-link-invite').props.onChange({ target: { value: 'PANEL-CODE' } })
  tree = render(panel.component({}))
  findByText(tree, 'button', '登记并连接').props.onClick()
  await flush()
  await flush()

  const markup = JSON.stringify(render(panel.component({})))
  assert.match(markup, /已登记，正在连接中转/)
  assert.doesNotMatch(markup, /取一张码/)
  assert.doesNotMatch(markup, /dsh-mobile-link-qr/)
  assert.equal(fetch.calls.filter((call) => call.path.includes('pair-code')).length, 0,
    'a not-yet-connected link must not try to mint a code')
})

test('a rejected code keeps the input and explains the failure in place', async () => {
  const { document } = makeDom()
  const status = { ...PANEL_STATUS, enroll: { ...PANEL_STATUS.enroll } }
  const fetch = makeFetch({ status, failEnroll: 'enroll/used' })
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)
  render(entry.component({})).props.onClick()
  await flush()

  let tree = render(panel.component({}))
  findInputById(tree, 'mobile-link-invite').props.onChange({ target: { value: 'USED-CODE' } })
  tree = render(panel.component({}))
  findByText(tree, 'button', '登记并连接').props.onClick()
  await flush()

  tree = render(panel.component({}))
  const markup = JSON.stringify(tree)
  assert.match(markup, /已经被使用/)
  assert.match(markup, /USED-CODE/, '失败后输入要保留，不能让用户重打')
  assert.doesNotMatch(markup, /dsh-mobile-link-qr/)
})

test('a status read failure shows a retry instead of an empty form or a fake QR', async () => {
  const { document } = makeDom()
  const fetch = makeFetch({ failStatus: true })
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)
  render(entry.component({})).props.onClick()
  await flush()

  const markup = JSON.stringify(render(panel.component({})))
  assert.match(markup, /读取连接状态失败/)
  assert.match(markup, /重试/)
  assert.doesNotMatch(markup, /mobile-link-invite/)
  assert.doesNotMatch(markup, /dsh-mobile-link-qr/)
})

test('the registered panel offers an optional Star link, not a gate', async () => {
  const { document } = makeDom()
  const fetch = makeFetch()
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)
  render(entry.component({})).props.onClick()
  await flush()

  const markup = JSON.stringify(render(panel.component({})))
  assert.match(markup, /github\.com\/jayantTang\/DSH_Mobile/)
  assert.match(markup, /Star/)
  assert.match(markup, /不影响连接/)
})

test('a recent failure is folded away, not a permanent red line', async () => {
  const { document } = makeDom()
  const fetch = makeFetch({ status: { ...HEALTHY_STATUS, lastError: '$events stream unavailable' } })
  const { api } = loadBundle({ document, fetchImpl: fetch.impl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  await flush()
  const { entry, panel } = components(state)
  render(entry.component({})).props.onClick()
  await flush()

  const tree = render(panel.component({}))
  const row = findByClass(tree, 'dsh-mobile-link-section')
  assert.ok(row, '有内容渲染')
  const disclosure = findByType(tree, 'disclosure')
  assert.ok(disclosure, '最近一次错误走官方 DisclosureRow')
  assert.equal(disclosure.props.title, '最近一次错误')
  assert.equal(disclosure.props.open, false, '默认收起来')
  disclosure.props.onToggle()
  await flush()
  assert.match(JSON.stringify(render(panel.component({}))), /\$events stream unavailable/)
})

test('without the official primitives nothing is registered, and the reason is logged', async () => {
  const { document } = makeDom()
  const { api } = loadBundle({ document, primitivesMissing: true })
  const { ctx, state } = makeCtx()
  assert.doesNotThrow(() => api.apply(ctx))
  await flush()
  // 官方原子组件是平台 seed 字，正常不会缺；缺了说明宿主形态不对——宁可不注册，
  // 也不摆一个与官方视觉无关的入口。
  assert.equal(state.slots.length, 0)
  assert.match(state.warnings.join('\n'), /官方原子组件不可用/)
})

test('disabling the plugin takes the entry, the panel and the timers with it', async () => {
  const { document, nodes } = makeDom()
  const fetch = makeFetch()
  const first = loadBundle({ document, fetchImpl: fetch.impl })
  const ctxOne = makeCtx()
  first.api.apply(ctxOne.ctx)
  await flush()
  assert.equal(ctxOne.state.slots.length, 2)
  assert.ok(first.timers.length > 0, '启用时应当有轮询定时器')

  ctxOne.state.dispose()
  assert.equal(ctxOne.state.slots.length, 0, '禁用后入口必须归零')
  assert.equal(nodes.filter((node) => node.id === STYLE_ID).length, 0, '样式也要撤掉')
  assert.equal(first.timers.length, 0, '定时器必须被清掉')

  // 再启用：入口数量与首轮一致，不累积。
  const second = loadBundle({ document, fetchImpl: fetch.impl })
  const ctxTwo = makeCtx()
  second.api.apply(ctxTwo.ctx)
  await flush()
  assert.equal(ctxTwo.state.slots.length, 2)
})

test('a hot reload does not steal the new panel stylesheet', async () => {
  // 热更的真实顺序可能是"新一代先起来、上一代后退场"：两代认领的是同一个 `<style>` 节点。
  // 上一代退场时若无条件节点删除，新面板就变成没有样式的裸 HTML（2026-10-17 实测到）。
  const { document, nodes } = makeDom()
  const fetch = makeFetch()
  const first = loadBundle({ document, fetchImpl: fetch.impl })
  const ctxOne = makeCtx()
  first.api.apply(ctxOne.ctx)
  await flush()

  const second = loadBundle({ document, fetchImpl: fetch.impl })
  const ctxTwo = makeCtx()
  second.api.apply(ctxTwo.ctx)
  await flush()
  assert.equal(nodes.filter((node) => node.id === STYLE_ID).length, 1)

  ctxOne.state.dispose()

  assert.equal(nodes.filter((node) => node.id === STYLE_ID).length, 1,
    '上一代的清理不得带走新一代仍在用的样式')
  assert.equal(ctxTwo.state.slots.length, 2, '新一代的入口不受上一代退场影响')

  ctxTwo.state.dispose()
  assert.equal(nodes.filter((node) => node.id === STYLE_ID).length, 0,
    '真正禁用之后样式仍要归零')
})

test('apply never throws when a slot registry refuses, and the other entry survives', async () => {
  const { document } = makeDom()
  const { api } = loadBundle({ document })
  const { ctx, state } = makeCtx({ registerThrows: true })
  assert.doesNotThrow(() => api.apply(ctx))
  await flush()
  assert.equal(state.warnings.length, 2, '两个入口各自降级并留日志')
  assert.match(state.warnings.join('\n'), /mobile-link:/)
})

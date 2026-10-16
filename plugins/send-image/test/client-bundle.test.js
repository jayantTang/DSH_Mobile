import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

/**
 * 客户端半边是手写的 `__ModuleLoader__` bundle，跑在浏览器里；这里用最小 stub 把它在 Node 里执行
 * 一遍，断言四类事情：
 *
 *   1. **形状**——宿主能否加载它（CJS 命名空间、包名一致、只 require 平台 seed 字）；
 *   2. **行为**——取消不打扰、权限失败要提示、成功只进草稿不发送、一次只跑一个；
 *   3. **热插拔**——启用/禁用可反复，入口与样式严格跟随插件的生命期（1 份 ↔ 0 份）；
 *   4. **失败隔离**——注册表抛错时 apply 不抛，按钮仍在（第一版正是死在这条上）。
 *
 * stub 的语义照官方服务写：`effect` 收集清理函数、`shortcuts.register` 返回注销函数、槽位注册随
 * 作用域退场。真实界面上的行为由慢闸（真实宿主 + 浏览器）验，单测只锁契约。
 */

const SOURCE = readFileSync(new URL('../lib/client.js', import.meta.url), 'utf8')
const STYLE_ID = 'dsh-send-image-style'
const LABEL = '截图并附上'

function makeDom() {
  const nodes = []
  const dispatched = []
  const document = {
    documentElement: { dataset: { platform: 'darwin' } },
    head: { appendChild: (node) => nodes.push(node) },
    body: { appendChild: (node) => nodes.push(node) },
    getElementById: (id) => nodes.find((node) => node.id === id) ?? null,
    createElement: () => ({
      id: '',
      textContent: '',
      style: {},
      setAttribute(key, value) { this[key] = value },
      remove() {
        const index = nodes.indexOf(this)
        if (index >= 0) nodes.splice(index, 1)
      },
    }),
    dispatchEvent: (event) => { dispatched.push(event); return true },
  }
  return { document, nodes, dispatched }
}

function loadBundle({ document, fetchImpl, withPrimitives = true } = {}) {
  const specs = []
  const sandbox = {
    window: { __ModuleLoader__: { load: (spec) => specs.push(spec) } },
    document,
    fetch: fetchImpl ?? (async () => ({
      ok: true, headers: { get: () => 'image/png' }, blob: async () => ({ size: 3 }),
    })),
    File: class { constructor(parts, name, options) { this.name = name; this.type = options?.type } },
    DataTransfer: class {
      constructor() {
        this.files = []
        this.items = { add: (file) => this.files.push(file) }
      }
    },
    DragEvent: class { constructor(type, init) { this.type = type; this.dataTransfer = init?.dataTransfer } },
    setTimeout, clearTimeout, console, Date, Object, Symbol, JSON, String, Number, Array,
  }
  vm.runInNewContext(SOURCE, sandbox, { filename: 'client.js' })
  const spec = specs[0]
  const fakeReact = { createElement: (type, props, children) => ({ type, props, children }) }
  // 官方界面件的替身：只认得「按钮交给了官方 Button」这一件事。
  const officialButton = function OfficialButton() {}
  const api = spec.factory((name) => {
    if (name === 'react') return fakeReact
    if (name === '@deepseek-ai/dsh-client-ui-primitives') {
      if (!withPrimitives) {
        throw new Error('require("@deepseek-ai/dsh-client-ui-primitives") missed the module table')
      }
      return { Button: officialButton }
    }
    assert.fail(`factory 只允许 require 平台 seed 字，实得 ${name}`)
  })
  return { spec, api, officialButton }
}

/** 一个插件实例（fiber）的 stub：退出时按官方语义把注册与资源都收回去。 */
function makeCtx({ registerThrows = false } = {}) {
  const state = { commands: [], slots: [], slotKeys: [], cleanups: [], warnings: [] }
  const ctx = {
    effect: (callback) => {
      const cleanup = callback()
      if (typeof cleanup === 'function') state.cleanups.push(cleanup)
    },
    shortcuts: {
      register: (command) => {
        if (registerThrows) throw new Error('Conflicting shortcut defaults: session.archive and send-image.screenshot')
        state.commands.push(command)
        return () => state.commands.splice(state.commands.indexOf(command), 1)
      },
    },
    slots: {
      inject: (key, callback) => {
        state.slotKeys.push(key)
        const dispose = callback()
        if (typeof dispose === 'function') state.cleanups.push(dispose)
      },
      register: (spec, component) => {
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

test('the bundle declares the package id and the official CJS-namespace shape', () => {
  const { document } = makeDom()
  const { spec, api } = loadBundle({ document })
  assert.equal(spec.id, 'dsh-plugin-send-image', 'bundle id 必须等于包名，否则宿主图里找不到')
  assert.equal(typeof spec.factory, 'function')
  assert.equal(api[Symbol.toStringTag], 'Module', 'factory 必须返回 CJS 命名空间')
  assert.deepEqual([...api.inject], ['shortcuts', 'slots'])
  assert.equal(typeof api.apply, 'function')
})

test('⌥⌘S is registered in page and editable regions, never inside modals', () => {
  const { document } = makeDom()
  const { api } = loadBundle({ document })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  const command = state.commands[0]
  assert.equal(command.id, 'send-image.screenshot')
  for (const profile of ['desktop:macos', 'desktop:windows', 'web:macos', 'web:windows']) {
    // 跨 realm（vm 里造出来的对象）只比字面值，别比原型
    assert.equal(command.defaults[profile].code, 'KeyS')
    assert.deepEqual([...command.defaults[profile].modifiers], ['primary', 'alt'])
  }
  assert.ok(command.defaults['web:macos'].modifiers.includes('alt'), 'web 运行时要求两修饰键含 primary 且带 alt/shift')
  assert.deepEqual([...command.regions], ['page', 'editable'])
  assert.deepEqual([...command.modals], [])
  assert.equal(command.resolve().status, 'handled')
})

test('the composer button writes 截图 and the shortcut on its face, with no hover hint', () => {
  const { document } = makeDom()
  const { api, officialButton } = loadBundle({ document })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  assert.deepEqual(state.slotKeys, ['conversation.input.left'])
  const { spec, component } = state.slots[0]
  assert.equal(spec.name, 'conversation.input.left')
  assert.equal(spec.id, 'send-image-screenshot')
  const element = component({ sessionId: 'session-1' })
  // 外观交给官方 Button（与旁边原生按钮同一套类），插件不再自带按钮样式
  assert.equal(element.type, officialButton, '按钮必须交给官方 primitives 的 Button')
  assert.equal(element.children, '截图 ⌥⌘S', '热键直接写在按钮正面')
  // 不挂任何悬停提示：原生 title 与官方 Tooltip 都不要（owner 2026-10-17 要求）
  assert.equal(element.props.title, undefined, '不要光标提示')
  assert.equal(element.props['aria-label'], '截图（快捷键：⌥⌘S）', '读屏名字仍要说清热键')
  assert.equal(element.props.className, undefined, '自有 class 不该出现在原生路径上')
})

test('a host without the official primitives still gets a working button', () => {
  // 老宿主没有 `@deepseek-ai/dsh-client-ui-primitives`：退回裸 button + 自带兜底样式，
  // 按钮不能因为"拿不到官方组件"就消失（失败隔离那条契约）。
  const { document, nodes } = makeDom()
  const { api } = loadBundle({ document, withPrimitives: false })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  const element = state.slots[0].component({ sessionId: 'session-1' })
  assert.equal(element.type, 'button')
  assert.equal(element.props.className, 'dsh-send-image-button')
  assert.equal(element.children, '截图 ⌥⌘S')
  assert.equal(element.props.title, undefined, '降级路径也不做悬停提示')
  const css = nodes.find((node) => node.id === STYLE_ID).textContent
  assert.match(css, /\.dsh-send-image-button:hover:not\(:disabled\)\{[^}]*--dsw-alias-interactive-bg-hover/)
  assert.match(css, /\.dsh-send-image-button:focus-visible\{[^}]*--dsw-focus-ring-color/)
  assert.doesNotMatch(css, /dsh-send-image-button[^}]*background:#/, '别写死颜色，跟随主题变量')
})

test('a cancelled capture says nothing and attaches nothing', async () => {
  const { document, dispatched, nodes } = makeDom()
  const fetchImpl = async () => ({
    ok: true, headers: { get: () => 'application/json' }, json: async () => ({ kind: 'cancelled' }),
  })
  const { api } = loadBundle({ document, fetchImpl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  state.slots[0].component({ sessionId: 'session-1' })
  await state.commands[0].resolve().run()
  assert.equal(nodes.filter((node) => node.id === STYLE_ID).length, 1, '样式应当已注入')
  assert.equal(nodes.filter((node) => node.id === 'dsh-send-image-toast').length, 0, '取消不得弹提示')
  assert.equal(dispatched.length, 0, '取消不得往草稿里塞东西')
  assert.equal(state.warnings.length, 0, '取消不该产生任何提示')
})

test('a permission failure shows the actionable message instead of attaching', async () => {
  const message = '屏幕录制权限没有生效。在「系统设置 → 隐私与安全性 → 屏幕录制」里勾选运行 DSH 的那个程序'
  const { document, nodes, dispatched } = makeDom()
  const fetchImpl = async () => ({
    ok: true, headers: { get: () => 'application/json' }, json: async () => ({ kind: 'permission', message }),
  })
  const { api } = loadBundle({ document, fetchImpl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  state.slots[0].component({ sessionId: 'session-1' })
  await state.commands[0].resolve().run()
  assert.equal(dispatched.length, 0, '失败不得往草稿里塞东西')
  assert.equal(nodes.at(-1).textContent, message)
})

test('a PNG response is handed to the composer as a drop, never sent', async () => {
  const { document, dispatched } = makeDom()
  const { api } = loadBundle({ document })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  state.slots[0].component({ sessionId: 'session-42' })
  await state.commands[0].resolve().run()
  assert.equal(dispatched.length, 1, '图片只进草稿：合成一次 drop')
  assert.equal(dispatched[0].type, 'drop')
  assert.equal(dispatched[0].dataTransfer.files.length, 1)
  assert.equal(dispatched[0].dataTransfer.files[0].type, 'image/png')
  assert.match(dispatched[0].dataTransfer.files[0].name, /^shot-\d+\.png$/)
})

test('a second trigger while capturing is ignored', async () => {
  let calls = 0
  const { document } = makeDom()
  const fetchImpl = async () => {
    calls += 1
    await new Promise((resolve) => setTimeout(resolve, 5))
    return { ok: true, headers: { get: () => 'application/json' }, json: async () => ({ kind: 'cancelled' }) }
  }
  const { api } = loadBundle({ document, fetchImpl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  const run = state.commands[0].resolve().run
  await Promise.all([run(), run(), run()])
  assert.equal(calls, 1, '一次只允许一个进行中的截图请求')
})

test('hot-plug: enable/disable three times leaves exactly one or zero of everything', () => {
  const { document, nodes } = makeDom()
  const { api } = loadBundle({ document })
  const countStyles = () => nodes.filter((node) => node.id === STYLE_ID).length

  for (let round = 1; round <= 3; round += 1) {
    const { ctx, state } = makeCtx()
    api.apply(ctx)
    assert.equal(state.commands.length, 1, `第 ${round} 轮启用：命令 1 条`)
    assert.equal(state.slots.length, 1, `第 ${round} 轮启用：按钮 1 个`)
    assert.equal(countStyles(), 1, `第 ${round} 轮启用：样式 1 份`)

    state.dispose()
    assert.equal(state.commands.length, 0, `第 ${round} 轮禁用：命令归零`)
    assert.equal(state.slots.length, 0, `第 ${round} 轮禁用：按钮归零`)
    assert.equal(countStyles(), 0, `第 ${round} 轮禁用：样式归零`)
  }
})

test('hot-plug: the same script can execute twice in one page', () => {
  // 启用过的插件被禁用后再启用时，宿主会让浏览器把同一个 bundle URL 再执行一遍。经典脚本的顶层
  // `const` 落在全局词法作用域里，所以只要脚本顶层有声明，第二次执行就会以
  // "Identifier 'ROUTE' has already been declared" 抛错——宿主只看到 "loaded without registering"，
  // 表现就是"禁用后再启用，入口再也不回来"。
  const { document } = makeDom()
  const specs = []
  const sandbox = {
    window: { __ModuleLoader__: { load: (spec) => specs.push(spec) } },
    document,
    fetch: async () => ({ ok: true, headers: { get: () => 'image/png' }, blob: async () => ({ size: 1 }) }),
    File: class {}, DataTransfer: class { constructor() { this.items = { add: () => {} } } },
    DragEvent: class {}, setTimeout, clearTimeout, console, Date,
  }
  const context = vm.createContext(sandbox)
  vm.runInContext(SOURCE, context, { filename: 'client.js' })
  assert.doesNotThrow(
    () => vm.runInContext(SOURCE, context, { filename: 'client.js' }),
    '第二次执行同一份脚本不得因顶层声明冲突而抛错（热重启用会走到这里）',
  )
  assert.equal(specs.length, 2, '两次执行各注册一次')
})

test('hot-plug: disabling while a toast is on screen removes it', async () => {
  const { document, nodes } = makeDom()
  const fetchImpl = async () => ({
    ok: true, headers: { get: () => 'application/json' }, json: async () => ({ kind: 'failed', message: '截屏失败' }),
  })
  const { api } = loadBundle({ document, fetchImpl })
  const { ctx, state } = makeCtx()
  api.apply(ctx)
  state.slots[0].component({ sessionId: 'session-1' })
  await state.commands[0].resolve().run()
  assert.equal(nodes.some((node) => node.id === 'dsh-send-image-toast'), true, '失败应当有浮层')
  state.dispose()
  assert.equal(nodes.some((node) => node.id === 'dsh-send-image-toast'), false, '禁用后浮层必须被撤掉')
})

test('failure isolation: a throwing registry never breaks the plugin or the caller', () => {
  const { document } = makeDom()
  const { api } = loadBundle({ document })
  const { ctx, state } = makeCtx({ registerThrows: true })
  assert.doesNotThrow(() => api.apply(ctx), '注册失败必须被吞掉，绝不能抛给宿主')
  assert.equal(state.commands.length, 0)
  assert.equal(state.slots.length, 1, '热键没注册上时按钮仍须可用')
  assert.match(state.warnings.join('\n'), /快捷键没注册上/)
})

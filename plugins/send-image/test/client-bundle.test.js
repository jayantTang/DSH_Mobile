import { test } from 'node:test'
import assert from 'node:assert/strict'

/**
 * 客户端半边是手写的 `__ModuleLoader__` bundle，跑在浏览器里；这里用最小 stub 把它在 Node 里
 * 执行一遍，断言两件事：**形状**（宿主能否加载、注册了什么）与**行为**（取消不打扰、
 * 权限失败要提示、成功只进草稿不发送）。
 */
let loadCount = 0

async function loadClient({ fetchImpl } = {}) {
  const state = { specs: [], shortcuts: [], slots: [], slotKeys: [], created: [], drops: [], files: [] }

  const makeElement = () => ({
    style: {}, textContent: '', removed: false,
    setAttribute() {}, remove() { this.removed = true }, appendChild() {},
  })
  globalThis.window = { __ModuleLoader__: { load: (spec) => state.specs.push(spec) } }
  globalThis.document = {
    body: { appendChild: () => {} },
    createElement: () => { const el = makeElement(); state.created.push(el); return el },
    dispatchEvent: (event) => { state.drops.push(event); return true },
  }
  globalThis.File = class { constructor(parts, name, options) { this.parts = parts; this.name = name; this.type = options?.type; state.files.push(this) } }
  globalThis.DataTransfer = class { constructor() { this.items = { add: () => {} } } }
  globalThis.DragEvent = class { constructor(type, init) { this.type = type; this.dataTransfer = init?.dataTransfer } }
  globalThis.fetch = fetchImpl ?? (async () => ({
    ok: true, headers: { get: () => 'image/png' }, blob: async () => ({ size: 3 }),
  }))

  // 每次用不同的查询串重新求值：同一个毫秒内多次 import 会命中模块缓存，
  // 那样 `__ModuleLoader__.load` 不会再次执行，第二个用例就拿到空 specs。
  await import(`../lib/client.js?case=${(loadCount += 1)}`)
  const spec = state.specs[0]
  const fakeReact = { createElement: (type, props, children) => ({ type, props, children }) }
  const api = spec.factory((name) => (name === 'react' ? fakeReact : {}))
  return { spec, api, state }
}

function makeCtx(state) {
  return {
    effect: (fn) => fn(),
    shortcuts: { register: (command) => { state.shortcuts.push(command); return () => {} } },
    slots: {
      inject: (key, callback) => { state.slotKeys.push(key); callback(); return () => {} },
      register: (slotSpec, component) => { state.slots.push({ slotSpec, component }); return () => {} },
    },
  }
}

test('the bundle declares the package id and injects shortcuts + slots', async () => {
  const { spec, api } = await loadClient()
  assert.equal(spec.id, 'dsh-plugin-send-image', 'bundle id 必须等于包名，否则宿主图里找不到')
  assert.equal(typeof spec.factory, 'function')
  assert.deepEqual(api.inject, ['shortcuts', 'slots'])
  assert.equal(typeof api.apply, 'function')
})

test('⌃⌘A is registered in both page and editable regions, never inside modals', async () => {
  const { api, state } = await loadClient()
  api.apply(makeCtx(state))
  const command = state.shortcuts[0]
  assert.equal(command.id, 'send-image.screenshot')
  assert.deepEqual(command.defaults['web:macos'], { code: 'KeyA', modifiers: ['control', 'meta'] })
  assert.deepEqual(command.defaults['desktop:macos'], { code: 'KeyA', modifiers: ['control', 'meta'] })
  assert.deepEqual(command.regions, ['page', 'editable'])
  assert.deepEqual(command.modals, [])
  assert.equal(command.resolve().status, 'handled')
})

test('the composer gets a button that names the shortcut', async () => {
  const { api, state } = await loadClient()
  api.apply(makeCtx(state))
  assert.deepEqual(state.slotKeys, ['conversation.input.left'])
  const { slotSpec, component } = state.slots[0]
  assert.equal(slotSpec.name, 'conversation.input.left')
  assert.equal(slotSpec.id, 'send-image-screenshot')
  const element = component({ sessionId: 'session-1' })
  assert.equal(element.type, 'button')
  assert.match(element.props.title, /⌃⌘A/)
  assert.match(element.props.title, /拖拽选择矩形范围/)
  assert.equal(element.props['aria-label'], '截图并附上（⌃⌘A）')
})

test('a cancelled capture says nothing and attaches nothing', async () => {
  const { api, state } = await loadClient({
    fetchImpl: async () => ({ ok: true, headers: { get: () => 'application/json' }, json: async () => ({ kind: 'cancelled' }) }),
  })
  api.apply(makeCtx(state))
  state.slots[0].component({ sessionId: 'session-1' })
  await state.shortcuts[0].resolve().run()
  assert.equal(state.drops.length, 0, '取消不得往草稿里塞东西')
  assert.equal(state.created.length, 0, '取消不得弹提示')
})

test('a permission failure shows the actionable message instead of attaching', async () => {
  const message = '屏幕录制权限没有生效。在「系统设置 → 隐私与安全性 → 屏幕录制」里勾选运行 DSH 的那个程序'
  const { api, state } = await loadClient({
    fetchImpl: async () => ({ ok: true, headers: { get: () => 'application/json' }, json: async () => ({ kind: 'permission', message }) }),
  })
  api.apply(makeCtx(state))
  state.slots[0].component({ sessionId: 'session-1' })
  await state.shortcuts[0].resolve().run()
  assert.equal(state.drops.length, 0)
  assert.equal(state.created.at(-1).textContent, message)
})

test('a PNG response is handed to the composer as a drop, never sent', async () => {
  const { api, state } = await loadClient({
    fetchImpl: async () => ({ ok: true, headers: { get: () => 'image/png' }, blob: async () => ({ size: 12 }) }),
  })
  api.apply(makeCtx(state))
  state.slots[0].component({ sessionId: 'session-42' })
  await state.shortcuts[0].resolve().run()
  assert.equal(state.drops.length, 1, '图片只进草稿：合成一次 drop')
  assert.equal(state.drops[0].type, 'drop')
  assert.equal(state.files.length, 1)
  assert.equal(state.files[0].type, 'image/png')
})

test('a second trigger while capturing is ignored', async () => {
  let calls = 0
  const { api, state } = await loadClient({
    fetchImpl: async () => {
      calls += 1
      await new Promise((resolve) => setTimeout(resolve, 5))
      return { ok: true, headers: { get: () => 'application/json' }, json: async () => ({ kind: 'cancelled' }) }
    },
  })
  api.apply(makeCtx(state))
  state.slots[0].component({ sessionId: 'session-1' })
  const run = state.shortcuts[0].resolve().run
  await Promise.all([run(), run(), run()])
  assert.equal(calls, 1, '一次只允许一个进行中的截图请求')
})

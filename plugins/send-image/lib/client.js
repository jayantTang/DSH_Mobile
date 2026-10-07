/**
 * 客户端半边：窗口内 `⌃⌘A` 截图 → 附到当前会话。
 *
 * 为什么要有这一半：截图能力在宿主（见 `lib/capture.js` 与 `lib/screenshot-route.js`），但
 * "哪个会话""只附加不发送"都是网页侧的事。自研外壳删掉后，旧实现在它自己的窗口里注入了
 * 脚本；现在改用 DSH 官方的客户端插件机制（`dsh.client` + `/plugins/*`），两种宿主共用一份。
 *
 * 三条实现事实（都来自读本机已安装的 DSH 包，见 specs/002-screenshot-hotkey/research.md）：
 *   1. `ctx.shortcuts.register(...)` 是官方快捷键契约；`code` 用物理键位，`regions` 决定在
 *      输入框里（editable）还是页面空白处（page）生效，`modals: []` 表示模态打开时不触发。
 *   2. 官方**没有**公开的"插入草稿附件"API；官方附件栏监听 `document` 上的 `drop` 事件并读
 *      `dataTransfer.files`。合成一次 drop 是唯一既走官方校验、又只进草稿不发送的路径。
 *   3. 输入区按钮用 `conversation.input.left`（官方 list 槽，追加式，不替换官方控件）。
 *
 * bundle 必须是 `window.__ModuleLoader__.load({ id, factory })` 形状：官方没有发布构建 preset，
 * 这里手写包装；只能 require 客户端 baseline（react / cordis / slots / primitives 等）。
 */

/** 文档相对路径：宿主把插件路由挂在同一个源上。 */
const ROUTE = 'send-image/screenshot'
const HOTKEY = { code: 'KeyA', modifiers: ['control', 'meta'] }
const HOTKEY_OTHER = { code: 'KeyA', modifiers: ['control', 'shift'] }
const TITLE = '截图并附上：拖拽选择矩形范围（⌃⌘A）'
const LABEL = '截图并附上'
const BUTTON_STYLE = {
  display: 'inline-flex', alignItems: 'center', height: '28px', padding: '0 8px',
  border: 'none', borderRadius: '8px', background: 'transparent', color: 'inherit',
  cursor: 'pointer', font: 'inherit', fontSize: '13px',
}

/** 失败提示：自己起一个小浮层，不阻塞页面（不用 alert），但必须让用户看见。 */
function notify(message) {
  const text = String(message ?? '').trim()
  if (!text) return
  if (typeof document === 'undefined' || !document.body) {
    console.warn(`send-image: ${text}`)
    return
  }
  const box = document.createElement('div')
  box.setAttribute('role', 'status')
  box.textContent = text
  box.style.cssText = [
    'position:fixed', 'z-index:2147483647', 'left:50%', 'transform:translateX(-50%)',
    'bottom:88px', 'max-width:min(560px,86vw)', 'padding:10px 14px', 'border-radius:10px',
    'background:rgba(32,32,36,.96)', 'color:#fff', 'font-size:13px', 'line-height:1.5',
    'box-shadow:0 8px 28px rgba(0,0,0,.28)',
  ].join(';')
  document.body.appendChild(box)
  setTimeout(() => box.remove(), 9000)
}

/** 让宿主去截一张；成功拿到 PNG 字节，否则拿到分类与提示。 */
async function requestCapture(sessionId) {
  const response = await fetch(ROUTE, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sessionId }),
  })
  const type = String(response.headers?.get?.('content-type') ?? '')
  if (response.ok && type.includes('image/png')) {
    return { kind: 'ok', blob: await response.blob() }
  }
  const payload = await response.json().catch(() => undefined)
  return { kind: payload?.kind ?? 'failed', message: payload?.message }
}

/** 把图片交给官方附件栏：合成一次 drop，只进待发送栏，不发送。 */
function attachToComposer(blob) {
  const file = new File([blob], `shot-${Date.now()}.png`, { type: 'image/png' })
  const dataTransfer = new DataTransfer()
  dataTransfer.items.add(file)
  document.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer }))
}

/** 一次截图的状态机：`busy` 保证同时只有一个请求，`session` 是当前正在看的会话。 */
function makeCaptureRunner() {
  const state = { session: '', busy: false }
  state.runCapture = async () => {
    if (state.busy) return
    state.busy = true
    try {
      const result = await requestCapture(state.session)
      if (result.kind === 'ok') attachToComposer(result.blob)
      else if (result.kind !== 'cancelled') notify(result.message ?? '截图失败')
    } catch (error) {
      notify(`截图失败：${error?.message ?? error}`)
    } finally {
      state.busy = false
    }
  }
  return state
}

/** 注册 ⌃⌘A：页面空白处与输入框里都生效，模态打开时不抢键。 */
function registerShortcut(ctx, state) {
  ctx.effect(() => ctx.shortcuts.register({
    id: 'send-image.screenshot',
    label: () => LABEL,
    aliases: ['screenshot'],
    defaults: {
      'web:macos': HOTKEY,
      'desktop:macos': HOTKEY,
      'web:windows': HOTKEY_OTHER,
      'desktop:windows': HOTKEY_OTHER,
    },
    regions: ['page', 'editable'],
    modals: [],
    resolve: () => ({ status: 'handled', run: state.runCapture }),
  }), 'send-image: screenshot shortcut')
}

/** 输入区左侧按钮：给不知道快捷键的人一个入口。 */
function registerButton(ctx, state, React) {
  ctx.slots.inject('conversation.input.left', () => ctx.slots.register(
    { name: 'conversation.input.left', id: 'send-image-screenshot', order: 40, label: () => LABEL },
    (props) => {
      state.session = props?.sessionId ?? ''
      return React.createElement('button', {
        type: 'button',
        title: TITLE,
        'aria-label': '截图并附上（⌃⌘A）',
        onClick: state.runCapture,
        style: BUTTON_STYLE,
      }, '⌃⌘A')
    },
  ))
}

window.__ModuleLoader__.load({
  id: 'dsh-plugin-send-image',
  factory(require) {
    const React = require('react')
    return {
      inject: ['shortcuts', 'slots'],
      apply(ctx) {
        const state = makeCaptureRunner()
        registerShortcut(ctx, state)
        registerButton(ctx, state, React)
      },
    }
  },
})

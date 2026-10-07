/**
 * 客户端半边：窗口内 `⌥⌘A` 截图 → 附到当前会话。
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
 * 形状必须抄官方 bundle：`window.__ModuleLoader__.load` 的 factory 返回 **CJS 命名空间**
 * （`module.exports` + `Symbol.toStringTag: 'Module'`），而不是普通对象——加载器对认不出的
 * 导出是 loud throw，表现为「web boot: 1 entry did not activate / <包名>: failed」。
 */

/** 文档相对路径：宿主把插件路由挂在同一个源上。 */
const ROUTE = 'send-image/screenshot'
/**
 * 统一快捷键：`⌥⌘A`（macOS）/ `Alt+Ctrl+A`（Windows）。四种档案（desktop/web × macos/windows）
 * 用**同一个**绑定。
 *
 * 为什么不是原来的 `⌃⌘A`：快捷键注册表对 **web 运行时**有白名单（`isWebBindingAllowed`）——
 * macos 上两修饰键必须含 primary 且带 alt 或 shift，而 `KeyA` 在 primary 下属保留键，
 * 所以 `⌃⌘A` 在浏览器里非法。给了非法的默认绑定会让整个客户端插件激活失败，而且只报
 * 「web boot: 1 entry did not activate / <包名>: failed」。`⌥⌘A` 两个运行时都合法，
 * 官方应用菜单与 Chrome/Safari 也都没占用它（`⇧⌘A` 被 Chrome 的「搜索标签页」占着）。
 */
const HOTKEY = { code: 'KeyA', modifiers: ['primary', 'alt'] }
const TITLE = '截图并附上：拖拽选择矩形范围（⌥⌘A）'
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

/** 注册 ⌥⌘A：页面空白处与输入框里都生效，模态打开时不抢键。 */
function registerShortcut(ctx, state) {
  ctx.effect(() => ctx.shortcuts.register({
    id: 'send-image.screenshot',
    label: () => LABEL,
    aliases: ['screenshot'],
    defaults: {
      'desktop:macos': HOTKEY,
      'desktop:windows': HOTKEY,
      'web:macos': HOTKEY,
      'web:windows': HOTKEY,
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
        'aria-label': '截图并附上（⌥⌘A）',
        onClick: state.runCapture,
        style: BUTTON_STYLE,
      }, '⌥⌘A')
    },
  ))
}

window.__ModuleLoader__.load({
  id: 'dsh-plugin-send-image',
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })
    const React = require('react')

    exports.inject = ['shortcuts', 'slots']
    exports.apply = (ctx) => {
      const state = makeCaptureRunner()
      registerShortcut(ctx, state)
      registerButton(ctx, state, React)
    }

    return module.exports
  },
})

/**
 * 客户端半边：窗口内 ⌥⌘S 截图 → 附到当前会话。
 *
 * 为什么要有这一半：截屏能力在宿主（`lib/capture.js` 跑 `screencapture`，`lib/screenshot-route.js`
 * 挂 `POST /send-image/screenshot`），但"当前是哪个会话""只附着不发送"是网页侧的事。自研外壳删掉
 * 之后，这里改用 DSH 官方的客户端插件机制（`dsh.client` + `exports['./client']`），两种宿主共用。
 *
 * 三条实现事实（读本机已安装的 DSH 包得到，见 `specs/002-screenshot-hotkey/research.md`）：
 *   1. `ctx.shortcuts.register(...)` 是官方命令注册；`code` 用物理键位，`regions` 决定在输入框里
 *      （editable）还是页面空白处（page）生效，`modals: []` 表示模态打开时不抢键。注册出来的命令
 *      会出现在官方快捷键设置里，用户可重绑。
 *   2. 官方**没有**公开的"插入草稿附件"API；官方附件栏监听 document 上的 `drop` 并读
 *      `dataTransfer.files`。合成一次 drop 是唯一既走官方校验、又只进草稿不发送的路径。
 *   3. 输入区按钮用 `conversation.input.left`（官方 list 槽，追加式，不替换官方控件）。
 *
 * 热插拔（本文件的硬约束，见 `specs/002-screenshot-hotkey/contracts/client-plugin.md`）：
 *   - 页面上的一切都归本插件的 fiber：命令与样式的 disposer 交给 `ctx.effect`，浮层与定时器记在
 *     state 上由同一处清理。插件被禁用时入口当场归零，再启用原样回来，可反复。
 *   - 形状必须抄官方 bundle：factory 返回 **CJS 命名空间**（`module.exports` +
 *     `Symbol.toStringTag: 'Module'`）；顶层除 `__ModuleLoader__.load` 外没有副作用。
 *   - 任何一步注册失败都**只降级自己**。第一版的教训：把有冲突风险的默认键带进共享注册表，会让
 *     官方插件在注册时抛错、整个界面起不来，而失败列表里还看不到我们。
 *   - 整份脚本套一层 IIFE：**热重启用会把同一个 URL 的脚本再执行一遍**，而经典脚本的顶层
 *     `const`/`let` 落在全局词法作用域里——不套起来，第二次执行会以
 *     `Identifier 'ROUTE' has already been declared` 抛语法错误，表现为"禁用后再启用，按钮再也不
 *     回来"（宿主只看到 `loaded without registering`）。官方 bundle 的位置都一样：顶层只有
 *     `__ModuleLoader__.load(...)` 这一句。
 */

;(() => {
/** 文档相对路径：宿主把插件路由挂在同一个源上。 */
const ROUTE = 'send-image/screenshot'

/**
 * 默认快捷键：`⌥⌘S`（macOS）/ `Alt+Ctrl+S`（Windows），四个档案统一。
 *
 * 取值是**机械验算**出来的，不是挑好看：官方对 web 运行时只允许"两修饰键含 primary 且带
 * alt/shift"这类组合（`isWebBindingAllowed`），并且注册表在注册时把新命令的默认键与已注册命令
 * 比对、重叠即抛 `Conflicting shortcut defaults`。第一版用 `⌥⌘A`，正是官方 `session.archive`
 * 的 web 默认键。`test/shortcut-default.test.js` 会读已安装的官方 bundle 抽出默认键集合，断言本键
 * 不在其中——官方哪天占了 `KeyS`，那条用例先红，不用等到启动崩溃。
 */
const HOTKEY = { code: 'KeyS', modifiers: ['primary', 'alt'] }
const COMMAND_ID = 'send-image.screenshot'
const LABEL = '截图并附上'
/** 按钮正面的固定前缀；热键拼在它后面（`截图 ⌥⌘S`，owner 2026-10-17 要求）。 */
const BUTTON_TEXT = '截图'
const SLOT_NAME = 'conversation.input.left'
const SLOT_ID = 'send-image-screenshot'
const STYLE_ID = 'dsh-send-image-style'
const BUTTON_CLASS = 'dsh-send-image-button'
/** 提示浮层自己消失的时间；插件被禁用时不等它，直接撤掉。 */
const TOAST_MS = 9000

/**
 * 当前是不是 macOS：热键写法跟平台走（`⌥⌘S` / `Ctrl+Alt+S`），按钮正面要写对。
 *
 * 先读宿主自己在 `<html data-platform>` 上写的判定（官方同一处），取不到再看 UA；
 * 两者都没有时按 macOS 处理（本机与官方桌面版都是 macOS）。
 */
function detectMac() {
  try {
    const flag = globalThis.document?.documentElement?.dataset?.platform
    if (typeof flag === 'string' && flag) return flag === 'darwin'
  } catch { /* 读不到就往下走 */ }
  try {
    return /Mac|iPhone|iPad|iPod/i.test(String(globalThis.navigator?.userAgent ?? ''))
  } catch {
    return true
  }
}

/** 按钮正面：`截图 ⌥⌘S`（Windows 为 `截图 Ctrl+Alt+S`）——热键直接写在字上，不做悬停提示。 */
function buttonText(isMac) {
  return `${BUTTON_TEXT} ${isMac ? '⌥⌘S' : 'Ctrl+Alt+S'}`
}

/** 读屏用的名字：把"这是截图按钮、热键是什么"说全（不是可见的悬停提示）。 */
function buttonAria(isMac) {
  return `${BUTTON_TEXT}（快捷键：${isMac ? '⌥⌘S' : 'Ctrl+Alt+S'}）`
}

/**
 * 注入的样式表。
 *
 * 按钮那几条**只在降级路径上生效**：正常路径用官方 primitives 的 `Button`（与输入区里
 * 官方按钮同一套 CSS-module 类，颜色随主题、也不需要我们猜 token）。只有当宿主没有
 * `@deepseek-ai/dsh-client-ui-primitives`（老宿主）时，才退回这个自带 class 的裸 `button`，
 * 此时这几条按官方输入区控件的 token 兜底（变量缺失还有字面兜底值）；
 * 所以它们不再参与"像不像原生"这件事，不要照着它们调外观。
 */
const CSS = [
  '#dsh-send-image-toast{position:fixed;z-index:2147483647;left:50%;transform:translateX(-50%);',
  'bottom:88px;max-width:min(560px,86vw);padding:10px 14px;border-radius:10px;',
  'background:rgba(32,32,36,.96);color:#fff;font-size:13px;line-height:1.5;',
  'box-shadow:0 8px 28px rgba(0,0,0,.28)}',
  // 降级路径（拿不到官方 primitives 时）的兜底观感：圆角/高度/字号/字重/内距照抄输入区里的
  // 官方触发器，文字用 `--dsw-alias-label-secondary`，`hover` 用官方交互底色，键盘聚焦用同一条
  // focus ring，禁用态用 `--dsw-alias-label-dimmed`；变量缺失时有兜底值。
  '.dsh-send-image-button{border-radius:var(--dsw-radius-sm,8px);height:28px;',
  'color:var(--dsw-alias-label-secondary,inherit);background:none;border:none;cursor:pointer;',
  'align-items:center;gap:4px;padding:0 8px;font:inherit;font-size:13px;font-weight:500;',
  'line-height:20px;display:inline-flex}',
  '.dsh-send-image-button:hover:not(:disabled){background:var(--dsw-alias-interactive-bg-hover,rgba(15,17,21,.06))}',
  '.dsh-send-image-button:focus-visible{outline:none;box-shadow:0 0 0 2px var(--dsw-focus-ring-color,var(--dsw-alias-state-business-primary,#4176e6))}',
  '.dsh-send-image-button:disabled{color:var(--dsw-alias-label-dimmed,inherit);cursor:default}',
].join('')

/** 出问题时只写日志，绝不把异常抛出插件边界。 */
function report(ctx, message) {
  const text = `send-image: ${message}`
  try {
    if (typeof ctx?.logger?.warn === 'function') ctx.logger.warn(text)
    else console.warn(text)
  } catch {
    /* 连日志都写不了就算了，不能因此失败 */
  }
}

/** 可读的失败原因。 */
function describe(error) {
  if (error instanceof Error) return error.message
  return String(error)
}

/**
 * 样式表：只在页面里存在一份。
 *
 * 用带 id 的 `<style>` 而不是给每个元素写内联样式，是为了"禁用即退场"只有一处要清。
 */
function ensureStyle() {
  if (typeof document === 'undefined' || !document.head) return null
  const existing = document.getElementById(STYLE_ID)
  if (existing !== null && existing !== undefined) return existing
  const style = document.createElement('style')
  style.id = STYLE_ID
  style.textContent = CSS
  document.head.appendChild(style)
  return style
}

/** 浮层：同一时刻最多一个；记在 state 上，插件退场时一起撤掉。 */
function notify(state, message) {
  const text = String(message ?? '').trim()
  if (!text) return
  if (typeof document === 'undefined' || !document.body) {
    console.warn(`send-image: ${text}`)
    return
  }
  state.dismissToast?.()
  const box = document.createElement('div')
  box.id = 'dsh-send-image-toast'
  box.setAttribute('role', 'status')
  box.textContent = text
  document.body.appendChild(box)
  const timer = setTimeout(() => dismiss(), TOAST_MS)
  const dismiss = () => {
    clearTimeout(timer)
    box.remove?.()
    if (state.dismissToast === dismiss) state.dismissToast = null
  }
  state.dismissToast = dismiss
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

/**
 * 把图片交给官方附件栏：合成一次 drop。
 *
 * 只进入待发送栏，不触发发送——这是官方没有公开"插入草稿附件"API 时唯一既走官方校验、
 * 又不发送的路径。
 */
function attachToComposer(blob) {
  const file = new File([blob], `shot-${Date.now()}.png`, { type: 'image/png' })
  const dataTransfer = new DataTransfer()
  dataTransfer.items.add(file)
  document.dispatchEvent(new DragEvent('drop', { dataTransfer, bubbles: true, cancelable: true }))
}

/** 插件实例的全部可变状态（fiber 一份；退场后不再写页面）。 */
function makeState() {
  return { session: '', busy: false, disposed: false, style: null, dismissToast: null }
}

/** 建立本插件在页面上持有的资源，返回它们的清理函数。 */
function ownPageResources(state) {
  state.style = ensureStyle()
  return () => {
    state.disposed = true
    state.dismissToast?.()
    state.style?.remove?.()
    state.style = null
  }
}

/** 一次触发的完整动作：请求宿主 → 成功则交给附件栏，其余按分类反馈。 */
function makeRunner(state) {
  return async () => {
    if (state.busy || state.disposed) return
    state.busy = true
    try {
      const result = await requestCapture(state.session)
      if (state.disposed) return
      if (result.kind === 'ok') attachToComposer(result.blob)
      else if (result.kind !== 'cancelled') notify(state, result.message ?? '截图失败')
    } catch (error) {
      if (!state.disposed) notify(state, `截图失败：${describe(error)}`)
    } finally {
      state.busy = false
    }
  }
}

/** 注册 ⌥⌘S：页面空白处与输入框里都生效，模态打开时不抢键。 */
function registerShortcut(ctx, state) {
  try {
    ctx.effect(() => ctx.shortcuts.register({
      id: COMMAND_ID,
      label: () => LABEL,
      aliases: ['screenshot', 'snip'],
      defaults: {
        'desktop:macos': HOTKEY,
        'desktop:windows': HOTKEY,
        'web:macos': HOTKEY,
        'web:windows': HOTKEY,
      },
      regions: ['page', 'editable'],
      modals: [],
      resolve: () => ({ status: 'handled', run: state.runCapture }),
    }), 'send-image: screenshot command')
  } catch (error) {
    report(ctx, `快捷键没注册上（按钮仍可用）：${describe(error)}`)
  }
}

/**
 * 输入区左侧按钮：给不知道快捷键的人一个入口，也是热键冲突时的唯一出路。
 *
 * 外观交给**官方 primitives 的 `Button`**（与旁边的官方按钮同一套 CSS-module 类）：宿主换主题、
 * 改按钮样式都自动跟随，不需要插件去猜 token。
 *
 * 热键直接写在按钮正面（`截图 ⌥⌘S`），**不做悬停提示**（owner 2026-10-17 要求：光标提示的
 * 出现时机不由插件掌握，写在字上最稳）。因此这里既不挂原生 `title`，也不用官方 `Tooltip`。
 * 拿不到 `Button`（老宿主）时退回自带 class 的裸 `button`（样式见 CSS 里那几条兜底规则），
 * 保证按钮在任何宿主上都还在。
 */
function registerButton(ctx, state, React, primitives) {
  const isMac = detectMac()
  const text = buttonText(isMac)
  const aria = buttonAria(isMac)
  const OfficialButton = primitives?.Button
  try {
    ctx.slots.inject(SLOT_NAME, () => ctx.slots.register(
      { name: SLOT_NAME, id: SLOT_ID, order: 40, label: () => LABEL },
      (props) => {
        state.session = props?.sessionId ?? state.session
        const onClick = () => state.runCapture()
        if (typeof OfficialButton === 'function') {
          return React.createElement(OfficialButton, {
            variant: 'ghost',
            'aria-label': aria,
            onClick,
          }, text)
        }
        return React.createElement('button', {
          type: 'button',
          className: BUTTON_CLASS,
          'aria-label': aria,
          onClick,
        }, text)
      },
    ))
  } catch (error) {
    report(ctx, `输入区按钮没注册上：${describe(error)}`)
  }
}

window.__ModuleLoader__.load({
  id: 'dsh-plugin-send-image',
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })
    const React = require('react')
    // 官方界面件：拿得到就用它的 `Button`（原生观感），拿不到只影响外观，不影响按钮本身。
    let primitives
    try {
      primitives = require('@deepseek-ai/dsh-client-ui-primitives')
    } catch {
      primitives = undefined
    }

    /** 挂上本插件的三个入口；每个入口自己负责失败降级，apply 本身不抛。 */
    function apply(ctx) {
      const state = makeState()
      state.runCapture = makeRunner(state)
      ctx.effect(() => ownPageResources(state), 'send-image: page resources')
      registerShortcut(ctx, state)
      registerButton(ctx, state, React, primitives)
    }

    exports.inject = ['shortcuts', 'slots']
    exports.apply = apply

    return module.exports
  },
})
})()

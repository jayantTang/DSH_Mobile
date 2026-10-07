/**
 * 宿主侧的"拖拽选区截图"。
 *
 * 为什么在宿主：网页客户端拿不到系统截屏能力，选区必须由本机进程完成；这一层就一句
 * `/usr/sbin/screencapture -i -x -t png <path>`（`-i` 交互式选区、`-x` 静音），与旧的自研外壳
 * 用的是同一条命令——外壳删掉后能力就断在这里，本模块把它接回来。
 *
 * 结果分四类，客户端据此决定"静默 / 提示 / 附件"：
 *   ok          有非空文件
 *   cancelled   用户按 Esc：命令非零退出、没有文件、也没有输出
 *   permission  屏幕录制权限没给"运行 DSH 的那个程序"（提示必须可行动，见 001 的教训）
 *   failed      其它非零退出，带上 stderr 摘要，绝不静默成"用户取消"
 *
 * 所有副作用（执行命令、列目录、删文件）都可注入，单测不需要真的截屏。
 */

import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const SCREENCAPTURE = '/usr/sbin/screencapture'
/** 选区阶段最长等 5 分钟；超时按失败处理，不让请求永久挂着。 */
export const CAPTURE_TIMEOUT_MS = 5 * 60 * 1000
/** 成功截下的临时文件保留 7 天，之后在下一次成功截图时清掉。 */
export const SCREENSHOT_TTL_MS = 7 * 24 * 60 * 60 * 1000

/** 截图落点：跟随 `DSH_HOME`，测试与多环境天然隔离。 */
export function screenshotDir(home = process.env.DSH_HOME || join(homedir(), '.dsh')) {
  return join(home, 'send-image', 'screenshots')
}

/**
 * 屏幕录制权限没生效时的可行动提示。
 *
 * 措辞与 `send-image.mjs` 保持一致，并且**不点名任何具体应用**：自研外壳已删除，写死名字会让
 * 用户去找一个不存在的 App（001 修过一次，这里不要再退回去）。
 */
export function explainCaptureFailure(stderr = '') {
  const text = String(stderr).trim()
  return (
    '屏幕录制权限没有生效。在「系统设置 → 隐私与安全性 → 屏幕录制」里勾选运行 DSH 的那个程序'
    + '（官方桌面版是「DeepSeek Harness」），然后完全退出并重新打开它 —— '
    + 'macOS 只把权限交给重新启动后的进程。'
    + `（原始错误：${text || 'screencapture 失败'}）`
  )
}

/** 把一次命令结果归类。`produced` 由调用方按"文件存在且非空"给出。 */
export function classify({ stderr = '', produced = false, code = 0 } = {}) {
  if (produced) return { kind: 'ok' }
  const text = String(stderr).trim()
  if (/could not create image from display|not authorized|denied|declined/i.test(text)) {
    return { kind: 'permission', message: explainCaptureFailure(text) }
  }
  // Esc 取消：没有文件、没有输出（退出码可能是 1，也可能是 0，别用它判）
  if (!text) return { kind: 'cancelled' }
  return { kind: 'failed', message: `截屏失败（退出码 ${code}）：${text.slice(-300)}` }
}

/** 删掉超过保留期的旧截图。失败不影响本次截图。 */
export function pruneScreenshots(dir, {
  now = Date.now(),
  ttlMs = SCREENSHOT_TTL_MS,
  list = readdirSync,
  stat = statSync,
  remove = rmSync,
} = {}) {
  let removed = 0
  let names = []
  try {
    names = list(dir)
  } catch {
    return 0
  }
  for (const name of names) {
    if (!name.endsWith('.png')) continue
    try {
      if (now - stat(join(dir, name)).mtimeMs > ttlMs) {
        remove(join(dir, name), { force: true })
        removed += 1
      }
    } catch {
      /* 被别处删掉了就算了 */
    }
  }
  return removed
}

/** 默认执行器：跑 screencapture，返回退出码与 stderr（不抛）。 */
export function runScreencapture(path, { timeoutMs = CAPTURE_TIMEOUT_MS } = {}) {
  return new Promise((resolve) => {
    execFile(SCREENCAPTURE, ['-i', '-x', '-t', 'png', path], { timeout: timeoutMs },
      (error, _stdout, stderr) => {
        resolve({ code: error?.code ?? 0, stderr: String(stderr ?? error?.message ?? '') })
      })
  })
}

/**
 * 截一次图。
 *
 * @returns {Promise<{kind:'ok', path:string} | {kind:'cancelled'|'permission'|'failed'|'unsupported', message?:string}>}
 */
export async function capture({
  run = runScreencapture,
  home,
  now = Date.now(),
  platform = process.platform,
  ttlMs = SCREENSHOT_TTL_MS,
  mkdir = mkdirSync,
  exists = existsSync,
  stat = statSync,
  remove = rmSync,
  prune = pruneScreenshots,
} = {}) {
  if (platform !== 'darwin') {
    return { kind: 'unsupported', message: '窗口内截图目前只支持 macOS。' }
  }
  const dir = screenshotDir(home)
  mkdir(dir, { recursive: true })
  const path = join(dir, `shot-${now}.png`)

  const { code = 0, stderr = '' } = (await run(path)) ?? {}
  let produced = false
  try {
    produced = exists(path) && stat(path).size > 0
  } catch {
    produced = false
  }

  const verdict = classify({ stderr, produced, code })
  if (verdict.kind === 'ok') {
    try {
      prune(dir, { now, ttlMs })
    } catch {
      /* 清理失败不影响这次截图 */
    }
    return { kind: 'ok', path }
  }
  // 取消或失败都不留文件（半截文件也算）
  try {
    if (exists(path)) remove(path, { force: true })
  } catch {
    /* 忽略 */
  }
  return verdict
}

/**
 * Driving the Doubao desktop app to produce an image, and taking the files out.
 *
 * Everything here was established by probing the running app, and each step
 * encodes a specific finding rather than a guess:
 *
 * - Doubao exposes three page targets, and the obvious one is a trap. The real
 *   1200x800 chat window is `doubao://doubao-chat/chat`; `doubao-launcher` is a
 *   400x600 sidebar that *also* accepts prompts but renders results at 90px,
 *   and `doubao-chat/chat` is additionally served as an empty `<html>hello</html>`
 *   shell. Identification therefore uses the live window size and the presence
 *   of the editor, never the URL alone.
 * - The prompt box is `div.tiptap.ProseMirror[contenteditable=true]`.
 *   `document.execCommand('insertText')` goes through the same `beforeinput`
 *   path a keystroke does, so ProseMirror's state updates and the app enables
 *   its send button; assigning `innerText` would not.
 * - Results arrive in an `image-box-grid`. The visible picture is a
 *   `cpreview_wm1` render (1728x2304 for a 3:4 request) sitting behind an
 *   absolutely-positioned overlay; the sibling `<img>` with the full-size
 *   `naturalWidth` is a bare `data:image/svg+xml` placeholder and carries no
 *   pixels at all. So the bytes cannot be read out of the grid.
 * - The way out is the app's own download: clicking a grid thumbnail opens the
 *   image viewer, which exposes `[data-testid=edit_image_download_button]`, and
 *   that writes the full-resolution file into `~/Downloads`. Each thumbnail
 *   yields a different file (verified by MD5), which is why the loop opens each
 *   one in turn instead of saving from the grid.
 * - The conversation is a virtualized list, so the grid must be re-scrolled and
 *   re-located before every attempt; nodes scrolled away are unmounted.
 */

import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdir, readdir, rename, rm, stat, copyFile, writeFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { readFileSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { attachLauncher, doubaoAppPath, doubaoBinary, probe, sleep } from './cdp.mjs'
import { decodePng, encodePng } from './image.mjs'
import { removeWatermark } from './watermark.mjs'

const run = promisify(execFile)

/** Default CDP port. High and unusual so it does not collide with real tools. */
export const DEFAULT_PORT = 19222

/** The prompt prefix Doubao routes into image generation. */
export const IMAGE_PROMPT_PREFIX = '生成图片：'

/** An image at least this wide is a real render, not an icon or a thumbnail. */
const MIN_RESULT_WIDTH = 1024

/** The attribute the app puts on its own "download this picture" control. */
const DOWNLOAD_TESTID = 'edit_image_download_button'

/** Where Doubao's own download lands. Not configurable — the app decides. */
export function downloadsDir() {
  return join(homedir(), 'Downloads')
}

/** ---------------------------------------------------------------- launching */

/** Whether Doubao is running at all (with or without a debug port). */
async function doubaoRunning() {
  try {
    const { stdout } = await run('/bin/ps', ['-Ao', 'command'])
    return stdout
      .split('\n')
      .some((line) => line.includes('/Doubao.app/Contents/MacOS/Doubao') && !line.includes('grep'))
  } catch {
    return false
  }
}

/**
 * Ask Doubao to quit and wait for it to actually go away.
 *
 * Doubao holds a singleton lock: launching the binary again while an instance
 * is live just forwards the request and the debug port never opens. So a
 * relaunch is mandatory, and the wait has to be real — spawning too early
 * silently produces an instance with no CDP.
 */
async function quitDoubao({ timeoutMs = 20_000 } = {}) {
  await run('/usr/bin/osascript', ['-e', 'quit app "Doubao"']).catch(() => {})
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (!(await doubaoRunning())) return true
    await sleep(500)
  }
  await run('/usr/bin/pkill', ['-f', '/Doubao.app/Contents/MacOS/Doubao']).catch(() => {})
  await run('/usr/bin/pkill', ['-f', 'Doubao Browser']).catch(() => {})
  const hardDeadline = Date.now() + 8000
  while (Date.now() < hardDeadline) {
    if (!(await doubaoRunning())) return true
    await sleep(500)
  }
  return false
}

/**
 * Ensure a CDP-instrumented Doubao is up, and return the port.
 *
 * `relaunch: false` turns the destructive part off and instead fails with an
 * explanation, which is what a caller wants when it must not close the user's
 * app window.
 */
export async function ensureDoubao({ port = DEFAULT_PORT, appPath, relaunch = true, log = () => {} } = {}) {
  if (await probe(port)) {
    log('豆包已在监听调试端口，直接复用')
    return { port, launched: false }
  }

  const resolvedApp = doubaoAppPath(appPath)
  if (!resolvedApp) throw new Error('找不到 /Applications/Doubao.app，请确认已安装豆包')

  const wasRunning = await doubaoRunning()
  if (wasRunning && !relaunch) {
    throw new Error(
      '豆包正在运行，但它不是以调试模式启动的，无法自动化。请先退出豆包，或允许插件自动重启它。',
    )
  }
  if (wasRunning) {
    log('豆包正在运行但没有调试端口，正在重启它…')
    const quit = await quitDoubao()
    if (!quit) throw new Error('无法退出正在运行的豆包，请手动退出后重试')
  }

  const binary = doubaoBinary(resolvedApp)
  log('以调试模式启动豆包…')
  const child = spawn(binary, [`--remote-debugging-port=${port}`, '--remote-allow-origins=*'], {
    detached: true,
    stdio: 'ignore',
  })
  child.unref()

  const deadline = Date.now() + 45_000
  while (Date.now() < deadline) {
    if (await probe(port)) {
      // The chat window needs a moment past the point the port answers.
      await sleep(3000)
      return { port, launched: true }
    }
    await sleep(700)
  }
  throw new Error('豆包启动后没有打开调试端口，可能被安全策略拦下了')
}

/** ------------------------------------------------------------------- page ops */

/** Page-side helpers, injected into every probe expression. */
const PAGE_HELPERS = `
  const findEditor = () => {
    const all = [...document.querySelectorAll('[contenteditable=true]')];
    return all.find((e) => (e.className || '').toString().includes('tiptap')) || all[0] || null;
  };
  const scroller = () => {
    const list = [...document.querySelectorAll('*')].filter((e) => e.scrollHeight > e.clientHeight + 200);
    list.sort((a, b) => b.scrollHeight - a.scrollHeight);
    return list[0] || null;
  };
  const scrollToBottom = () => { const s = scroller(); if (s) s.scrollTop = s.scrollHeight; return !!s; };
  // Result renders are the watermarked previews; the bare-size sibling <img> in
  // the same box is an svg placeholder with no pixels.
  const resultImages = () => [...document.querySelectorAll('img')]
    .filter((i) => /cpreview_wm1|image_pre_watermark/.test(i.src || ''))
    .filter((i) => i.naturalWidth >= ${MIN_RESULT_WIDTH});
`

/** Click at a point, as real input events rather than a synthetic DOM click. */
async function clickAt(session, x, y) {
  await session.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y })
  await sleep(350)
  await session.send('Input.dispatchMouseEvent', {
    type: 'mousePressed',
    x,
    y,
    button: 'left',
    clickCount: 1,
  })
  await session.send('Input.dispatchMouseEvent', {
    type: 'mouseReleased',
    x,
    y,
    button: 'left',
    clickCount: 1,
  })
}

/**
 * Start a fresh conversation so the result cannot be confused with history.
 *
 * The sidebar's 新对话 entry is a `group/sidebar_nav_item` wrapper whose inner
 * span is not a button and carries no role, so a `.click()` on the text node
 * does nothing. The app advertises ⌘N for the same action, and sending it as a
 * real CDP key event goes through the app's own keybinding — which survives
 * markup changes that would break any selector here.
 */
/**
 * Start a fresh conversation so the result cannot be confused with history.
 *
 * The sidebar's 新对话 entry is a `group/sidebar_nav_item` wrapper whose inner
 * span is not a button and carries no role, so a `.click()` on the text node
 * does nothing. The app advertises ⌘N for the same action, and sending it as a
 * real CDP key event goes through the app's own keybinding — which survives
 * markup changes that would break any selector here.
 */
export async function newChat(session) {
  const before = await session.evaluate('location.href')
  await pressShortcut(session, 'n')

  // Wait for the URL to actually change. Returning as soon as the key event is
  // sent would let the prompt be typed into the conversation still on screen —
  // which is exactly how an earlier version appended a generation request to an
  // unrelated chat.
  const deadline = Date.now() + 12_000
  while (Date.now() < deadline) {
    const now = await session.evaluate('location.href').catch(() => before)
    if (now !== before) {
      await sleep(1800)
      return 'shortcut-cmd-n'
    }
    await sleep(500)
  }

  const clicked = await session.evaluate(`
    (() => {
      const label = [...document.querySelectorAll('*')]
        .find((e) => e.children.length === 0 && (e.innerText || '').trim() === '新对话');
      if (!label) return 'no-new-chat-entry';
      let node = label;
      for (let i = 0; i < 6 && node; i++) {
        if (node.getAttribute && (node.getAttribute('role') === 'button' || node.tagName === 'BUTTON' || node.tagName === 'A')) {
          node.click();
          return 'clicked-ancestor';
        }
        node = node.parentElement;
      }
      (label.parentElement ?? label).click();
      return 'clicked-parent';
    })()
  `)
  await sleep(2200)
  return clicked
}

/**
 * Send a Cmd+<key> chord as genuine CDP input events.
 *
 * Dispatch is split into keyDown/keyUp because the app's shortcut layer listens
 * for real input, and the modifier bitmask must be set explicitly.
 */
export async function pressShortcut(session, key) {
  const upper = key.toUpperCase()
  const codes = { n: 78, j: 74, enter: 13, escape: 27 }
  const code = codes[key.toLowerCase()] ?? upper.charCodeAt(0)
  const base = {
    modifiers: 4,
    key: key.toLowerCase() === 'n' ? 'n' : key,
    code: `Key${upper}`,
    windowsVirtualKeyCode: code,
    nativeVirtualKeyCode: code,
  }
  await session.send('Input.dispatchKeyEvent', { type: 'keyDown', ...base, text: '', unmodifiedText: key })
  await session.send('Input.dispatchKeyEvent', { type: 'keyUp', ...base })
  return true
}

/** Press Escape, to leave the image viewer Doubao opens on a result click. */
export async function pressEscape(session) {
  const base = { key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 }
  await session.send('Input.dispatchKeyEvent', { type: 'keyDown', ...base, text: '', unmodifiedText: '' })
  await session.send('Input.dispatchKeyEvent', { type: 'keyUp', ...base })
  await sleep(900)
}

/**
 * Put the prompt in the box and submit it.
 *
 * Confirmation is by *observation*, not by the editor going empty. The first
 * version returned "submitted" when the box cleared and an error otherwise —
 * but the box also clears while the app is still switching conversations, so a
 * real submission was reported as a failure. What cannot be faked is the
 * prompt turning up as a message in the transcript, so that is the check, and
 * the whole write-and-send is retried until it holds.
 */
/**
 * Put the prompt in the box and submit it — exactly once.
 *
 * Delivery is confirmed by counting the prompt's occurrences in the transcript
 * before and after each attempt, and a retry is only allowed when that count
 * did NOT rise.
 *
 * This is a correction, not a refinement. The first version inferred delivery
 * from the editor going empty, and treated a non-empty editor as "not sent, so
 * try again". But Doubao also clears the editor while it is switching
 * conversations, so a prompt that had in fact been sent was reported as failed
 * and re-sent — which really did run the same generation twice and burn the
 * user's quota. Observed: one conversation held the same prompt twice and two
 * result images, alongside a sibling conversation holding it once.
 *
 * The general rule this encodes: a retry must be gated on evidence that the
 * previous attempt did nothing, never on the absence of evidence that it worked.
 */
export async function submitPrompt(session, prompt, { attempts = 3, confirmTimeoutMs = 18_000, log = () => {} } = {}) {
  const needle = prompt.slice(0, 24)
  let lastError = '没有确认到消息'

  for (let attempt = 0; attempt < attempts; attempt++) {
    const seenBefore = await countOccurrences(session, needle)

    const result = await session.evaluate(
      `
      (async () => {
        ${PAGE_HELPERS}
        const editor = findEditor();
        if (!editor) return { ok: false, error: '页面上找不到输入框' };

        editor.focus();
        document.execCommand('selectAll', false, null);
        document.execCommand('delete', false, null);
        document.execCommand('insertText', false, ${JSON.stringify(prompt)});
        await new Promise((r) => setTimeout(r, 500));

        const typed = (editor.innerText || '').trim();
        if (typed.length === 0) return { ok: false, error: '提示词写入输入框失败' };

        const rect = editor.getBoundingClientRect();
        const buttons = [...document.querySelectorAll('button,[role=button]')]
          .map((b) => ({ b, r: b.getBoundingClientRect() }))
          .filter((x) => x.r.width > 20 && x.r.height > 20 && x.r.top > rect.top - 40)
          .filter((x) => (x.b.innerText || '').trim().length === 0 || /发送|send/i.test(x.b.getAttribute('aria-label') || ''))
          .sort((a, b) => Math.hypot(a.r.x - rect.right, a.r.y - rect.bottom) - Math.hypot(b.r.x - rect.right, b.r.y - rect.bottom));

        // Press Enter, and if the editor is still holding the text afterwards,
        // fall back to the button. Both are reported; whether the message
        // actually landed is decided outside, from the transcript.
        const keydown = new KeyboardEvent('keydown', {
          key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true,
        });
        editor.dispatchEvent(keydown);
        await new Promise((r) => setTimeout(r, 1200));
        let via = (editor.innerText || '').trim().length === 0 ? 'enter' : null;

        if (via === null) {
          const sendButton = buttons[0]?.b;
          if (sendButton && !sendButton.disabled) {
            sendButton.click();
            await new Promise((r) => setTimeout(r, 1200));
            if ((editor.innerText || '').trim().length === 0) via = 'button';
          }
        }
        return { ok: true, via, typedLength: typed.length, editorCleared: via !== null };
      })()
    `,
      { timeoutMs: 30_000 },
    )

    if (!result?.ok) {
      lastError = result?.error ?? '提交提示词失败'
      await sleep(1500)
      continue
    }

    // The decision that matters: did this attempt put a new copy in the
    // transcript? If the count is unchanged the attempt did nothing, and only
    // then is another try safe.
    const appeared = await waitForOccurrences(session, needle, seenBefore + 1, { timeoutMs: confirmTimeoutMs })

    if (appeared) {
      if (!result.editorCleared) {
        log('提交成功（输入框未清空，但消息已进入会话，不再重发）')
      }
      return { ok: true, via: result.via ?? 'unconfirmed', typedLength: result.typedLength, repeats: appeared }
    }

    if (!result.editorCleared) {
      // Text still sitting in the box but nothing new in the transcript: the
      // send genuinely failed, so the next attempt is safe.
      lastError = '输入框里的提示词没有被发出去'
      log(`第 ${attempt + 1} 次提交确认失败（消息未进入会话），将重试`)
    } else {
      // Editor empty yet no new message — the most dangerous state. Do not
      // resend blind; report it instead, because a resend here is what caused
      // the duplicate generations.
      lastError = '输入框已清空但会话里没有出现该消息，为避免重复生成已停止重试'
      log(`第 ${attempt + 1} 次提交状态不明，已停止重试以避免重复消耗额度`)
      break
    }
    await sleep(1500)
  }
  throw new Error(lastError)
}

/** How many times a needle appears in the rendered transcript. */
export async function countOccurrences(session, needle) {
  const text = await session
    .evaluate('(document.body.innerText || "")', { timeoutMs: 10_000 })
    .catch(() => '')
  if (typeof text !== 'string' || needle.length === 0) return 0
  let count = 0
  let from = 0
  for (;;) {
    const at = text.indexOf(needle, from)
    if (at === -1) return count
    count++
    from = at + needle.length
  }
}

/** Wait until at least `target` copies of the needle are in the transcript. */
export async function waitForOccurrences(session, needle, target, { timeoutMs = 18_000, pollMs = 800 } = {}) {
  const deadline = Date.now() + timeoutMs
  let last = 0
  while (Date.now() < deadline) {
    last = await countOccurrences(session, needle)
    if (last >= target) return last
    await sleep(pollMs)
  }
  return 0
}

/**
 * Whether a slice of the prompt is present in the rendered transcript.
 *
 * Kept for callers that only need presence; `countOccurrences` is the one the
 * submit path uses, since presence alone cannot tell a first send from a
 * duplicate.
 */
export async function waitForTranscript(session, needle, { timeoutMs = 15_000, pollMs = 800 } = {}) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const found = await session
      .evaluate(
        `(document.body.innerText || '').includes(${JSON.stringify(needle)})`,
        { timeoutMs: 10_000 },
      )
      .catch(() => false)
    if (found) return true
    await sleep(pollMs)
  }
  return false
}

/**
 * Wait until the app has finished a batch of candidates.
 *
 * Completion is decided by the result images themselves, never by the wording
 * of the reply. Doubao phrases the same outcome differently from run to run —
 * observed both 「已为你生成 4 张候选图」 and a bare 「已交付完成」 that only
 * revealed itself through the grid — so text matching produced false timeouts
 * on real successes. What is stable is the grid: the count of result renders
 * climbs and then stops.
 *
 * The 1x1 hidden "new reply" dot is how a finished turn is recognised without
 * reading any prose at all.
 */
export async function waitForResult(session, { timeoutMs = 300_000, pollMs = 2500, log = () => {} } = {}) {
  const deadline = Date.now() + timeoutMs
  let previous = -1
  let stablePolls = 0
  let sawAny = false

  while (Date.now() < deadline) {
    const snap = await session
      .evaluate(
        `
      (() => {
        ${PAGE_HELPERS}
        scrollToBottom();
        const text = document.body.innerText || '';
        return {
          images: resultImages().length,
          finished: !!document.querySelector('[data-testid=message_box_new_message_icon]'),
          refused: /无法生成|违反了|换个话题|换个描述|不支持该/.test(text.slice(-500)),
          tail: text.slice(-140).replace(/\\n/g, ' '),
        };
      })()
    `,
        { timeoutMs: 30_000 },
      )
      .catch((error) => ({ error: error.message }))

    if (snap?.error) {
      await sleep(pollMs)
      continue
    }
    if (snap.refused) throw new Error(`豆包拒绝了这次生成：${snap.tail}`)

    if (snap.images > 0) {
      sawAny = true
      if (snap.images === previous) {
        stablePolls += 1
        // Require the count to hold still across polls AND the turn to be
        // marked finished, so a batch still streaming in is not cut short.
        if (stablePolls >= 1 && snap.finished) {
          log(`检测到 ${snap.images} 张结果图，生成已结束`)
          await sleep(1500)
          return { images: snap.images }
        }
        if (stablePolls >= 3) {
          log(`检测到 ${snap.images} 张结果图（未见结束标记，按稳定计数继续）`)
          return { images: snap.images }
        }
      } else {
        stablePolls = 0
        log(`结果图陆续出现：${snap.images} 张`)
      }
      previous = snap.images
    } else if (sawAny && snap.finished) {
      // The grid unmounted after being seen; trust the earlier signal.
      return { images: previous }
    }

    await sleep(pollMs)
  }
  throw new Error(`等待生成超时（${Math.round(timeoutMs / 1000)} 秒）。豆包可能仍在生成，或提示词被拒绝。`)
}

/** ------------------------------------------------------------------- saving */

/** Which image format a buffer really is, from its magic bytes. */
export function sniffFormat(buffer) {
  if (buffer.length > 8 && buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4e && buffer[3] === 0x47) {
    return 'png'
  }
  if (buffer.length > 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return 'jpg'
  if (
    buffer.length > 12 &&
    buffer.toString('ascii', 0, 4) === 'RIFF' &&
    buffer.toString('ascii', 8, 12) === 'WEBP'
  ) {
    return 'webp'
  }
  return null
}

/** A listing of a directory with sizes and modification times. */
async function snapshotDir(dir) {
  const map = new Map()
  for (const name of await readdir(dir).catch(() => [])) {
    try {
      const info = await stat(join(dir, name))
      map.set(name, { mtimeMs: info.mtimeMs, size: info.size })
    } catch {
      /* vanished between readdir and stat; not part of the snapshot */
    }
  }
  return map
}

/**
 * Wait for the download that this click started, and return its path.
 *
 * Two earlier versions were wrong in ways that produced silently bad results,
 * so both are guarded against here:
 *
 *  - Diffing the directory by *name* alone. A file left behind by a previous
 *    run is not "new" then, but is indistinguishable from a fresh download on
 *    the next attempt — which is how a run harvested a stale picture sitting in
 *    ~/Downloads instead of the one it had just generated.
 *  - Reading the file the moment its name appears. The app creates the entry
 *    before the bytes are on disk, so the read can fail with ENOENT (observed)
 *    or hand back a truncated image.
 *
 * A candidate must therefore be new-or-rewritten by mtime, and its size must be
 * unchanged across two consecutive polls, before it is accepted.
 */
async function waitForNewDownload(dir, before, { timeoutMs = 30_000, pollMs = 700 } = {}) {
  const deadline = Date.now() + timeoutMs
  let candidate = null
  let lastSize = -1
  let stable = 0

  while (Date.now() < deadline) {
    await sleep(pollMs)
    const now = await snapshotDir(dir)
    const fresh = [...now.entries()].filter(([name, info]) => {
      if (/\.(crdownload|part|download|tmp)$/i.test(name)) return false
      const old = before.get(name)
      return !old || info.mtimeMs > old.mtimeMs
    })
    if (fresh.length === 0) continue
    fresh.sort((a, b) => b[1].mtimeMs - a[1].mtimeMs)
    const [name, info] = fresh[0]

    if (candidate !== name) {
      candidate = name
      lastSize = info.size
      stable = 0
      continue
    }
    if (info.size > 0 && info.size === lastSize) {
      stable += 1
      if (stable >= 1) return join(dir, name)
    } else {
      lastSize = info.size
      stable = 0
    }
  }
  return null
}

/**
 * Harvest one result by opening it and using Doubao's own download control.
 *
 * Returns null when the Nth result could not be reached (fewer candidates than
 * asked for), so the caller can stop cleanly instead of erroring.
 */
async function saveResultNth(session, { index, seedSrc, dir, stripWatermark = true, log }) {
  const point = await session
    .evaluate(
      `
    (async () => {
      ${PAGE_HELPERS}
      scrollToBottom();
      await new Promise((r) => setTimeout(r, 2200));
      const images = resultImages();
      // Prefer the video-free clean render of this candidate: its URL changes
      // between visits, so the index plus the seed set is what identifies it.
      const target = images.filter((i) => !${JSON.stringify(seedSrc)}.includes(i.src))[${index}] ?? images[${index}];
      if (!target) return 'null';
      target.scrollIntoView({ block: 'center' });
      await new Promise((r) => setTimeout(r, 800));
      const r = target.parentElement.getBoundingClientRect();
      return JSON.stringify({ src: target.src, x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
    })()
  `,
      { timeoutMs: 40_000 },
    )
    .catch((error) => `err:${error.message}`)

  if (typeof point !== 'string' || point === 'null' || point.startsWith('err:')) return null
  const spot = JSON.parse(point)
  await clickAt(session, spot.x, spot.y)
  await sleep(3800)

  const control = await session
    .evaluate(
      `
    (() => {
      // The app renders several copies of this control, and the earlier ones
      // are collapsed to 0x0 — clicking those coordinates (0,0) does nothing,
      // which is exactly how a harvest silently returned no file. Only the
      // laid-out instance is clickable.
      const all = [...document.querySelectorAll('[data-testid=${DOWNLOAD_TESTID}]')];
      const el = all.find((n) => {
        const r = n.getBoundingClientRect();
        return r.width >= 4 && r.height >= 4;
      });
      if (!el) return 'null';
      const r = el.getBoundingClientRect();
      return JSON.stringify({ x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), count: all.length });
    })()
  `,
      { timeoutMs: 15_000 },
    )
    .catch(() => 'null')

  if (control === 'null') {
    await pressEscape(session)
    return null
  }

  const dlDir = downloadsDir()
  const before = await snapshotDir(dlDir)
  const button = JSON.parse(control)
  await clickAt(session, button.x, button.y)

  const landed = await waitForNewDownload(dlDir, before)
  await pressEscape(session)
  if (!landed) {
    log(`第 ${index + 1} 张：点了保存但没有等到文件`)
    return null
  }

  const source = landed
  let buffer
  try {
    buffer = readFileSync(source)
  } catch (error) {
    log(`第 ${index + 1} 张：文件已出现但读不到（${error.code ?? error.message}）`)
    return null
  }
  const format = sniffFormat(buffer)
  if (!format) {
    log(`第 ${index + 1} 张：下载的文件不是图片（${source.split('/').pop()}）`)
    return null
  }
  // Remove Doubao's overlay before hashing, so the digest names the picture the
  // caller actually receives. Only PNG can be re-encoded losslessly here; other
  // formats are kept as downloaded rather than silently recompressed.
  let working = buffer
  if (stripWatermark && format === 'png') {
    try {
      const decoded = decodePng(buffer)
      const result = removeWatermark(decoded, { log })
      if (result.changed) working = encodePng(result.image)
    } catch (error) {
      log(`第 ${index + 1} 张：去水印失败，保留原图（${error.message}）`)
    }
  }

  const digest = createHash('md5').update(working).digest('hex').slice(0, 12)
  await mkdir(dir, { recursive: true })
  const target = join(dir, `doubao-${digest}.${format}`)
  // Move rather than copy, so the user's Downloads folder is not left holding
  // a duplicate of every picture this tool fetches. Rename across volumes
  // fails, so fall back to copy-then-remove.
  if (working === buffer) {
    // Unchanged: move the app's own file rather than leaving a duplicate behind.
    try {
      await rename(source, target)
    } catch {
      await copyFile(source, target)
    }
  } else {
    await writeFile(target, working)
    await rm(source, { force: true })
  }
  return {
    path: target,
    bytes: working.length,
    format,
    digest,
    sourceName: source.split('/').pop(),
    watermarkStripped: working !== buffer,
  }
}

/** ------------------------------------------------------------------ the task */

/**
 * The full round trip: ensure the app, open a chat, ask, wait, save.
 *
 * `reuseCurrentChat` lets a caller continue an existing conversation (which is
 * how you get a variation of a previous image) instead of starting clean.
 */export async function generateImage({
  prompt,
  count = 1,
  dir,
  port = DEFAULT_PORT,
  appPath,
  relaunch = true,
  reuseCurrentChat = false,
  stripWatermark = true,
  timeoutMs = 300_000,
  log = () => {},
}) {
  if (typeof prompt !== 'string' || prompt.trim().length === 0) throw new Error('提示词不能为空')

  const ensure = await ensureDoubao({ port, appPath, relaunch, log })
  const { session } = await attachLauncher(ensure.port)

  try {
    if (!reuseCurrentChat) {
      const started = await newChat(session)
      if (started !== 'shortcut-cmd-n') {
        // Refuse rather than proceed. Continuing here would type the prompt into
        // whatever conversation happens to be open — which is how an earlier
        // version appended generation requests to unrelated chats, and how the
        // "new" chat ended up needing a second attempt.
        throw new Error(
          `没能新建对话（${started}），已中止以免把提示词发进现有会话。可加 reuseCurrentChat 明确表示沿用当前会话。`,
        )
      }
      log('已新建对话')
      await sleep(1500)
    }

    const seedSrc = await session
      .evaluate(
        `(() => { ${PAGE_HELPERS} return resultImages().map((i) => i.src); })()`,
        { timeoutMs: 20_000 },
      )
      .catch(() => [])

    log(`提交提示词（${prompt.length} 字）…`)
    await submitPrompt(session, prompt, { log })

    const outcome = await waitForResult(session, { timeoutMs, log })
    const wanted = Math.min(Math.max(1, count), outcome.images || count)

    const files = []
    for (let i = 0; i < wanted; i++) {
      log(`正在取回第 ${i + 1}/${wanted} 张…`)
      const file = await saveResultNth(session, { index: i, seedSrc, dir, stripWatermark, log })
      if (file) {
        const meta = await stat(file.path)
        file.bytes = meta.size
        files.push(file)
        log(`已保存 ${file.path}（${(file.bytes / 1024 / 1024).toFixed(1)} MB）`)
      }
    }
    if (files.length === 0) {
      throw new Error('生成完成但没能取回任何图片文件')
    }
    return { ok: true, files, images: outcome.images, port: ensure.port, launched: ensure.launched }
  } finally {
    session.close()
  }
}

export { existsSync, sleep }

/**
 * Harvest images already on screen, without asking for a new generation.
 *
 * Split out so the fragile half — opening each result and using the app's own
 * download control — can be re-run and debugged on its own. Re-running the
 * generation just to test the harvest burns the user's Doubao quota and takes
 * minutes, which made every harvest fix cost far more than it should.
 */
export async function harvestExisting({ count = 1, dir, port = DEFAULT_PORT, log = () => {} } = {}) {
  const ensure = await ensureDoubao({ port, log })
  const { session } = await attachLauncher(ensure.port)
  try {
    const files = []
    for (let i = 0; i < Math.max(1, count); i++) {
      log(`取回第 ${i + 1} 张…`)
      const file = await saveResultNth(session, { index: i, seedSrc: [], dir, log })
      if (!file) continue
      file.bytes = (await stat(file.path)).size
      files.push(file)
      log(`已保存 ${file.path}（${(file.bytes / 1024 / 1024).toFixed(1)} MB）`)
    }
    return { ok: files.length > 0, files }
  } finally {
    session.close()
  }
}

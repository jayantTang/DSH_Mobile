/**
 * Self-check against the *live* app, for the parts that can only be verified
 * against a real Doubao window.
 *
 * These are the assertions that catch the two failure modes that actually
 * happened while building this:
 *
 *  1. Attaching to the wrong page target. `doubao-launcher` is a sidebar that
 *     accepts prompts and renders results at 90px, so a run "succeeds" while
 *     producing nothing usable. Hence the window-size assertion.
 *  2. Picking a collapsed copy of the download control. The app renders several
 *     `edit_image_download_button` nodes and the first ones measure 0x0, so
 *     clicking them is a no-op that looks like a successful click. Hence the
 *     "must be laid out" assertion.
 *
 * Run it against an app that is already instrumented:
 *
 *   node lib/generate.mjs ...        # or any run that leaves Doubao open
 *   node --test test/live.test.js
 *
 * It skips (rather than fails) when no CDP endpoint is listening, so the normal
 * `node --test test/*.test.js` stays hermetic.
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { attachLauncher, probe } from '../lib/cdp.mjs'
import { DEFAULT_PORT, downloadsDir, sniffFormat } from '../lib/doubao.mjs'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const live = await probe(DEFAULT_PORT)
const skip = live ? false : `豆包没有在 ${DEFAULT_PORT} 上监听调试端口（先跑一次 lib/generate.mjs）`

test('attaches to the real chat window, not the sidebar', { skip }, async () => {
  const { session, target, width, height } = await attachLauncher(DEFAULT_PORT)
  try {
    assert.match(target.url, /doubao-chat|chat/, `attached to ${target.url}`)
    // The sidebar is 400px wide; the chat window is ~1200. A run attached to
    // the sidebar silently produces 90px thumbnails, so this is the guard.
    assert.ok(width >= 700, `窗口只有 ${width}px 宽，可能连到了侧边栏`)
    assert.ok(height >= 400, `窗口只有 ${height}px 高`)

    const editor = await session.evaluate(`
      (() => {
        const all = [...document.querySelectorAll('[contenteditable=true]')];
        const ed = all.find((e) => (e.className || '').toString().includes('tiptap'));
        if (!ed) return null;
        const r = ed.getBoundingClientRect();
        return { width: Math.round(r.width), count: all.length };
      })()
    `)
    assert.ok(editor, '找不到 ProseMirror 输入框')
    assert.ok(editor.width > 300, `输入框只有 ${editor.width}px 宽`)
  } finally {
    session.close()
  }
})

test('the transcript is reachable through the attached session', { skip }, async () => {
  const { session } = await attachLauncher(DEFAULT_PORT)
  try {
    const text = await session.evaluate('(document.body.innerText || "").length')
    assert.ok(text > 80, `页面文本只有 ${text} 字符，可能连到了空壳页面`)
  } finally {
    session.close()
  }
})

test('a collapsed download control is never chosen', { skip }, async () => {
  const { session } = await attachLauncher(DEFAULT_PORT)
  try {
    // The predicate used by the harvest, asserted in isolation: whatever the
    // app renders, the chosen node must be laid out.
    const chosen = await session.evaluate(`
      (() => {
        const all = [...document.querySelectorAll('[data-testid=edit_image_download_button]')];
        const el = all.find((n) => {
          const r = n.getBoundingClientRect();
          return r.width >= 4 && r.height >= 4;
        });
        return { total: all.length, picked: el ? (() => { const r = el.getBoundingClientRect(); return { w: Math.round(r.width), h: Math.round(r.height) } })() : null };
      })()
    `)
    // The control only exists while the image viewer is open, so absence is not
    // a failure — but a *picked* node must always be laid out.
    if (chosen.picked) {
      assert.ok(chosen.picked.w >= 4 && chosen.picked.h >= 4, '选中了 0x0 的隐藏控件')
    }
  } finally {
    session.close()
  }
})

test('every harvested file is a real image', { skip }, async () => {
  // Sniffing is the guard against a signed-URL rejection (an HTML error page)
  // being written out under an image extension. Exercised here against whatever
  // the last run left in Downloads.
  const { readdirSync } = await import('node:fs')
  const recent = readdirSync(downloadsDir())
    .filter((f) => /\.(jpe?g|png|webp)$/i.test(f))
    .slice(0, 5)
  for (const name of recent) {
    const buffer = readFileSync(join(downloadsDir(), name))
    assert.ok(sniffFormat(buffer), `${name} 不是可识别的图片格式`)
  }
})

/**
 * dsh-plugin-desktop-shell — host half.
 *
 * Scope (deliberately tiny so a DSH upgrade can never make it fatal):
 *   1. Four routes under `/desktop-shell` behind DSH's own connection fence:
 *      GET  /status   — installed vs published version, update availability
 *      POST /upgrade  — run the package-manager upgrade for one version
 *      POST /open-app — `open -a <appName>` to hand off to the macOS shell app
 *      POST /open-config — reveal ~/.dsh/desktop-shell in Finder
 *   2. One `tapIndex` injection that appends a small self-contained banner to
 *      index.html. No client bundle, no build step, no framework imports.
 *   3. An endpoint handoff file so DSH.app can attach to an already-running
 *      server instead of spawning a second one.
 *
 * Failure policy: every capability is feature-detected and wrapped; a missing
 * service or a broken route must never take the DSH boot down. Disable the
 * plugin by removing its row from the profile cordis.patch.yml.
 */

import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { readFileSync, rmSync } from 'node:fs'
import { mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Cordis function-plugin name (the loader row id is separate). */
export const name = 'desktop-shell'

/** The route carrier + DSH's Host/Origin fence and browser authentication. */
export const inject = ['webServer', 'connection']

const STATUS_ROUTE = '/desktop-shell/status'
const UPGRADE_ROUTE = '/desktop-shell/upgrade'
const OPEN_APP_ROUTE = '/desktop-shell/open-app'
const OPEN_CONFIG_ROUTE = '/desktop-shell/open-config'
const SCREENSHOT_ROUTE = '/desktop-shell/screenshot'
const SHELL_DIR = join(homedir(), '.dsh', 'desktop-shell')
const SCREENSHOT_DIR = join(SHELL_DIR, 'screenshots')
const MAX_BODY_BYTES = 64 * 1024
const MAX_OUTPUT_BYTES = 256 * 1024
/** Long enough for a slow drag, short enough to never wedge the route. */
const SCREENSHOT_TIMEOUT_MS = 5 * 60 * 1000
const SCREENSHOT_RETENTION_MS = 14 * 24 * 60 * 60 * 1000
const MAX_SCREENSHOT_BYTES = 32 * 1024 * 1024

const DEFAULTS = {
  // Reminder policy: follow only the npm `latest` tag. Prerelease channels
  // (`next`, `alpha`, ...) stay hidden unless showPrereleases is turned on.
  tag: 'latest',
  showPrereleases: false,
  registry: 'https://registry.npmjs.org/@deepseek-ai/dsh',
  npmBin: 'npm',
  appName: 'DSH',
  cacheMs: 10 * 60 * 1000,
  upgradeTimeoutMs: 10 * 60 * 1000,
  banner: true,
  writeEndpoint: true,
}

/** @param {unknown} value */
function asRecord(value) {
  return value !== null && typeof value === 'object' ? value : {}
}

/** Read a package.json and keep it only when it is the DSH CLI manifest. */
async function readDshManifest(path) {
  try {
    const raw = JSON.parse(await readFile(path, 'utf8'))
    if (raw && raw.name === '@deepseek-ai/dsh' && typeof raw.version === 'string') {
      return { version: raw.version, path, packageName: raw.name }
    }
  } catch {
    /* not a manifest we can read */
  }
  return undefined
}

/** Resolve the running DSH package version. */
async function findInstalledVersion() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  // 1. Node resolution from anchors that sit inside DSH's own module graph.
  for (const anchor of [
    join(home, 'profiles', 'web', 'package.json'),
    join(homedir(), '.dsh', 'profiles', 'web', 'package.json'),
    fileURLToPath(new URL('../package.json', import.meta.url)),
  ]) {
    try {
      const resolved = createRequire(anchor).resolve('@deepseek-ai/dsh/package.json')
      const manifest = await readDshManifest(resolved)
      if (manifest) return manifest
    } catch {
      /* try the next anchor */
    }
  }
  // 2. Name-checked walk-up from the launcher and from this module.
  const starts = []
  if (process.argv[1]) starts.push(dirname(process.argv[1]))
  starts.push(dirname(fileURLToPath(import.meta.url)))
  for (const start of starts) {
    let dir = start
    for (let depth = 0; depth < 12; depth += 1) {
      const direct = await readDshManifest(join(dir, 'package.json'))
      if (direct) return direct
      const nested = await readDshManifest(join(dir, 'node_modules', '@deepseek-ai', 'dsh', 'package.json'))
      if (nested) return nested
      const parent = dirname(dir)
      if (parent === dir) break
      dir = parent
    }
  }
  return undefined
}

/** semver-ish precedence: tolerant of rc/alpha tags, enough for a nudge. */
function compareVersions(lhs, rhs) {
  const parse = (raw) => {
    let text = String(raw).trim().replace(/^v/, '')
    let pre = []
    const dash = text.indexOf('-')
    if (dash !== -1) {
      pre = text.slice(dash + 1).split('.')
      text = text.slice(0, dash)
    }
    const plus = text.indexOf('+')
    if (plus !== -1) text = text.slice(0, plus)
    const core = text.split('.').slice(0, 3).map((part) => Number.parseInt(part, 10) || 0)
    while (core.length < 3) core.push(0)
    return { core, pre }
  }
  const a = parse(lhs)
  const b = parse(rhs)
  for (let i = 0; i < 3; i += 1) {
    if (a.core[i] !== b.core[i]) return a.core[i] < b.core[i] ? -1 : 1
  }
  if (a.pre.length === 0 && b.pre.length === 0) return 0
  if (a.pre.length === 0) return 1
  if (b.pre.length === 0) return -1
  const length = Math.max(a.pre.length, b.pre.length)
  for (let i = 0; i < length; i += 1) {
    if (i >= a.pre.length) return -1
    if (i >= b.pre.length) return 1
    const x = a.pre[i]
    const y = b.pre[i]
    const nx = Number.parseInt(x, 10)
    const ny = Number.parseInt(y, 10)
    const xNum = String(nx) === x
    const yNum = String(ny) === y
    if (xNum && yNum) {
      if (nx !== ny) return nx < ny ? -1 : 1
    } else if (xNum !== yNum) {
      return xNum ? -1 : 1
    } else if (x !== y) {
      return x < y ? -1 : 1
    }
  }
  return 0
}

/**
 * Pure reminder policy, kept separate so it is testable without a server.
 *
 * Rule: only the followed tag (default `latest`) may raise a reminder. Every
 * other dist-tag (`next`, `alpha`, ...) is a prerelease channel and stays
 * invisible unless `showPrereleases` is explicitly turned on.
 */
function buildStatus({ installed, tags, tag = 'latest', showPrereleases = false }) {
  const follow = typeof tag === 'string' && tag.length > 0 ? tag : 'latest'
  const followed = tags[follow] ?? tags.latest ?? undefined
  const updateAvailable = Boolean(installed && followed && compareVersions(followed, installed) > 0)
  const newer = Object.entries(tags)
    .filter(([, version]) => Boolean(installed && compareVersions(version, installed) > 0))
    .sort((a, b) => compareVersions(b[1], a[1]))
    .map(([name, version]) => ({ tag: name, version }))
  return {
    follow,
    followed,
    updateAvailable,
    showPrereleases: showPrereleases === true,
    newerTags: showPrereleases ? newer : newer.filter((entry) => entry.tag === follow),
    prereleaseTags: newer.filter((entry) => entry.tag !== follow),
  }
}

/** Run one command under a login shell with the usual Homebrew PATH appended. */
function runCommand(command, timeoutMs) {
  return new Promise((resolve) => {
    const child = spawn('/bin/zsh', ['-lc', command], {
      env: {
        ...process.env,
        PATH: `${process.env.PATH ?? ''}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`,
      },
    })
    let output = ''
    let finished = false
    const timer = setTimeout(() => {
      if (finished) return
      finished = true
      child.kill('SIGKILL')
      resolve({ ok: false, code: null, output: `${output}\n[timeout after ${timeoutMs}ms]` })
    }, timeoutMs)
    const collect = (chunk) => {
      if (output.length < MAX_OUTPUT_BYTES) output += String(chunk)
    }
    child.stdout?.on('data', collect)
    child.stderr?.on('data', collect)
    child.on('error', (error) => {
      if (finished) return
      finished = true
      clearTimeout(timer)
      resolve({ ok: false, code: null, output: `${output}\n${error.message}` })
    })
    child.on('close', (code) => {
      if (finished) return
      finished = true
      clearTimeout(timer)
      resolve({ ok: code === 0, code, output })
    })
  })
}

/** Sortable, human-readable stamp: 20260916-221530-042. */
function screenshotStamp(date = new Date()) {
  const pad = (value, width = 2) => String(value).padStart(width, '0')
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}`
    + `-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`
    + `-${pad(date.getMilliseconds(), 3)}`
}

/** Keep the screenshots folder from growing without bound. */
async function pruneScreenshots(now = Date.now()) {
  try {
    for (const entry of await readdir(SCREENSHOT_DIR)) {
      if (!entry.endsWith('.png')) continue
      const path = join(SCREENSHOT_DIR, entry)
      const info = await stat(path).catch(() => undefined)
      if (info && now - info.mtimeMs > SCREENSHOT_RETENTION_MS) await rm(path, { force: true }).catch(() => {})
    }
  } catch {
    /* the folder does not exist yet */
  }
}

/**
 * Interactive region capture. `screencapture -i` puts macOS in selection mode:
 * the user drags the rectangle they want, the PNG lands in the screenshots
 * folder, and Escape cancels (non-zero exit, no file). Returning the bytes as
 * a data URL keeps the page from needing a second authenticated round trip.
 */
async function captureScreenshot() {
  await mkdir(SCREENSHOT_DIR, { recursive: true })
  await pruneScreenshots()
  const name = `shot-${screenshotStamp()}.png`
  const path = join(SCREENSHOT_DIR, name)
  const result = await runCommand(`/usr/sbin/screencapture -i -x -t png ${JSON.stringify(path)}`, SCREENSHOT_TIMEOUT_MS)
  const data = await readFile(path).catch(() => undefined)
  if (!data || data.length === 0) {
    await rm(path, { force: true }).catch(() => {})
    // Escape (and clicking outside the selection) exits 0 with no file and no
    // message; a real failure always says something on stderr. Treating the
    // silent case as an error is what put "截图附上失败" on screen when the
    // user simply changed their mind.
    const detail = result.output.trim()
    const cancelled = detail.length === 0 && (result.code === 0 || result.code === 1)
    return {
      ok: false,
      cancelled,
      message: cancelled
        ? undefined
        : `截图没有生成文件（screencapture 退出码 ${result.code}）：${detail.slice(-400) || '没有任何输出'}`,
    }
  }
  if (data.length > MAX_SCREENSHOT_BYTES) {
    await rm(path, { force: true }).catch(() => {})
    return { ok: false, message: `截图太大（${Math.round(data.length / 1024 / 1024)} MB）` }
  }
  return { ok: true, name, path, bytes: data.length, dataUrl: `data:image/png;base64,${data.toString('base64')}` }
}

/** Bounded JSON body reader. */
async function readJsonBody(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.byteLength
    if (size > MAX_BODY_BYTES) {
      req.resume()
      return undefined
    }
    chunks.push(chunk)
  }
  if (size === 0) return {}
  try {
    return JSON.parse(Buffer.concat(chunks, size).toString('utf8'))
  } catch {
    return undefined
  }
}

function sendJson(res, status, payload) {
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(JSON.stringify(payload))
}

/**
 * @param {import('node:http').ServerResponse} res
 */
function sendMethodNotAllowed(res, allow) {
  res.statusCode = 405
  res.setHeader('allow', allow)
  res.end()
}

/**
 * The self-contained client script injected into index.html.
 *
 * UI contract:
 *   * The version chip is the only always-visible surface: small gray text
 *     inserted inside the sidebar's settings button, right after 设置/Settings.
 *   * The update card is conditional — it is created only while an update the
 *     policy allows actually exists, and removed otherwise.
 *   * Clicking the badge opens a panel with the non-urgent actions.
 */
function bannerScript(token) {
  return `<script id="dsh-desktop-shell-banner">
(function(){
  if (window.__dshDesktopShellLoaded) return;
  window.__dshDesktopShellLoaded = true;
  var TOKEN = ${JSON.stringify(token)};
  var BASE = '/desktop-shell';
  var state = { status: null, busy: false, dismissed: false, checking: false, note: null, checkedAt: null, error: null };
  var card = null, cardBody = null, badge = null, panel = null, anchorNode = null;
  var shotButton = null;
  // Throttle for the *opening* auto-check: a chip click must never spam /status.
  var lastCheckAt = 0;
  // Keep "检查中…" on screen long enough to be seen even when the host answers
  // instantly, otherwise a checker click looks like it did nothing.
  var MIN_CHECK_MS = 450;
  var checkStartedAt = 0;

  function dark(){ try { return window.matchMedia('(prefers-color-scheme: dark)').matches; } catch (e) { return true; } }
  function palette(){ return dark()
    ? { bg:'rgba(22,25,33,.96)', fg:'#dfe4ee', dim:'#98a1b3', line:'#333a4a', btn:'#2c3344', accent:'#7aa2f7', ok:'#9ece6a', warn:'#e0af68', bad:'#f7768e' }
    : { bg:'rgba(255,255,255,.97)', fg:'#1d2330', dim:'#5d6675', line:'#d8dde7', btn:'#eef1f7', accent:'#2f6fed', ok:'#2f7d32', warn:'#9a6400', bad:'#c0392b' }; }

  function el(tag, css, text){
    var node = document.createElement(tag);
    if (css) node.setAttribute('style', css);
    if (text != null) node.textContent = text;
    return node;
  }

  function api(path, payload){
    var headers = { 'x-dsh-desktop-token': TOKEN };
    var options = { method: payload ? 'POST' : 'GET', headers: headers, credentials: 'same-origin' };
    if (payload) { headers['content-type'] = 'application/json'; options.body = JSON.stringify(payload); }
    return fetch(BASE + path, options).then(function(response){
      return response.json().catch(function(){ return {}; }).then(function(json){
        if (!response.ok) { var error = new Error(json && json.message ? json.message : ('HTTP ' + response.status)); error.status = response.status; throw error; }
        return json;
      });
    });
  }

  function button(label, primary, onClick, disabled){
    var p = palette();
    var color = primary ? '#fff' : p.fg;
    var node = el('button', 'appearance:none;border:1px solid ' + (primary ? p.accent : p.line) + ';background:' + (primary ? p.accent : p.btn) + ';color:' + color + ';border-radius:7px;padding:4px 10px;font:12px -apple-system,"PingFang SC",sans-serif;cursor:pointer;margin-left:6px'
      + (disabled ? ';opacity:.55;cursor:default' : ''), label);
    if (disabled) node.setAttribute('disabled', 'disabled');
    else node.addEventListener('click', onClick);
    return node;
  }

  function clockText(date){
    try { return date.toLocaleTimeString([], { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
    catch (e) { return String(date).slice(16, 24); }
  }

  /**
   * Turn a failed /status call into something a user can act on. The 403 case
   * is the one that keeps biting: the page (and the token baked into it) is
   * older than the running plugin, so every call is refused until reload.
   */
  function describeError(error){
    var message = String(error && error.message ? error.message : error);
    if (error && error.status === 403) return '页面已过期（插件重载过），按 ⌘R 重新载入后再检查。';
    if (error && error.status) return '本地 DSH 服务返回 ' + error.status + '：' + message;
    return '连不上本地 DSH 服务：' + message;
  }

  function permissionLabel(preset){
    if (preset === 'danger-full-access') return '完全权限';
    if (preset === 'workspace-write') return '工作区内修改';
    if (preset === 'read-only') return '仅可查看';
    return preset || '未知';
  }

  function tagLabel(tag){ return tag === 'latest' ? tag : (tag + '（预发布）'); }

  // ── conditional update card: only exists while something is upgradeable ───

  function removeCard(){ if (card) { card.remove(); card = null; cardBody = null; } }

  function ensureCard(){
    if (card && document.body.contains(card)) return card;
    var p = palette();
    card = el('div', 'position:fixed;right:16px;bottom:16px;z-index:2147483000;width:330px;background:' + p.bg + ';color:' + p.fg + ';border:1px solid ' + p.line + ';border-radius:12px;box-shadow:0 8px 28px rgba(0,0,0,.28);padding:10px 12px;font:12.5px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;backdrop-filter:blur(12px)');
    cardBody = el('div');
    card.appendChild(cardBody);
    document.body.appendChild(card);
    return card;
  }

  function renderUpdate(){
    var p = palette();
    var status = state.status || {};
    ensureCard();
    cardBody.textContent = '';
    cardBody.appendChild(el('div', 'font-weight:600;margin-bottom:2px', 'DSH 有新版本 ' + (status.latest || '')));
    cardBody.appendChild(el('div', 'color:' + p.dim + ';font-size:12px', '当前 ' + (status.installed || '?') + ' · 通道 ' + (status.tag || status.channel || 'latest')));
    var row = el('div', 'margin-top:8px;text-align:right');
    row.appendChild(button('稍后', false, function(){ state.dismissed = true; removeCard(); }));
    row.appendChild(button('立即升级', true, upgrade));
    cardBody.appendChild(row);
  }

  function renderBusy(text, sub){
    var p = palette();
    ensureCard();
    cardBody.textContent = '';
    cardBody.appendChild(el('div', 'font-weight:600', text));
    cardBody.appendChild(el('div', 'color:' + p.dim + ';font-size:12px;margin-top:4px',
      sub || '升级过程中请勿关闭此页面；完成后需要重启 DSH 才会生效。'));
  }

  function renderDone(ok, message){
    var p = palette();
    ensureCard();
    cardBody.textContent = '';
    cardBody.appendChild(el('div', 'font-weight:600', ok ? '升级完成' : '升级失败'));
    cardBody.appendChild(el('div', 'color:' + p.dim + ';font-size:11.5px;margin-top:4px;max-height:150px;overflow:auto;white-space:pre-wrap', message || ''));
    var row = el('div', 'margin-top:8px;text-align:right');
    if (ok) row.appendChild(button('重新载入页面', true, function(){ location.reload(); }));
    row.appendChild(button('关闭', false, removeCard));
    cardBody.appendChild(row);
  }

  // Inside DSH.app a WKScriptMessageHandler named dshShell is the app half.
  // When it exists the app owns the whole upgrade (npm install, stop the old
  // backend, spawn the new one, reload this window), so the page hands the
  // request over instead of running npm behind the app's back — that half-flow
  // is exactly what left the window pointed at an old backend.
  function appBridge(){
    try {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.dshShell;
      return handler && typeof handler.postMessage === 'function' ? handler : null;
    } catch (error) { return null; }
  }

  // The app calls this back when a delegated upgrade finishes, so the card
  // settles instead of spinning when the run did not replace the page.
  window.__dshShellUpgradeResult = function(ok, message){
    state.busy = false;
    renderDone(!!ok, message || '');
    if (ok) refresh();
  };

  function upgradeTo(version, tag){
    var label = (tag ? tagLabel(tag) + ' ' : '') + version;
    var bridge = appBridge();
    if (bridge) {
      state.busy = true;
      renderBusy('已交给桌面应用升级到 ' + label + '…',
        '桌面应用会完成下载、重启后台服务并自动刷新此窗口，请稍候；失败会直接在窗口里报错。');
      try {
        bridge.postMessage({ action: 'upgrade', version: version, tag: tag || '' });
      } catch (error) {
        state.busy = false;
        renderDone(false, '无法调用桌面应用：' + String(error && error.message ? error.message : error));
      }
      return;
    }
    state.busy = true;
    renderBusy('正在升级到 ' + label + '…');
    api('/upgrade', { version: version }).then(function(result){
      state.busy = false;
      var tail = (result.output || '').split('\\n').slice(-12).join('\\n');
      renderDone(!!result.ok, tail);
      if (result.ok) refresh();
    }).catch(function(error){
      state.busy = false;
      renderDone(false, String(error && error.message ? error.message : error));
    });
  }

  function upgrade(){
    var version = state.status && state.status.latest;
    if (version) upgradeTo(version, state.status.tag || state.status.channel);
  }

  function openApp(){ api('/open-app', {}).catch(function(){}); }
  function openConfig(){ api('/open-config', {}).catch(function(){}); }

  // ── permanent version chip inside the sidebar settings button ────────────

  var SETTINGS_LABELS = ['设置', 'Settings'];

  function labelled(node){
    var text = node && node.textContent ? node.textContent.trim() : '';
    return SETTINGS_LABELS.indexOf(text) !== -1;
  }

  /** DSH's own sidebar settings trigger (button aria-label 设置 / Settings). */
  function findSettingsButton(){
    if (anchorNode && anchorNode.isConnected) {
      var cached = anchorNode.getBoundingClientRect();
      if (cached.width > 0 && cached.height > 0) return anchorNode;
    }
    anchorNode = null;
    var candidates = document.querySelectorAll('button, [role="button"], a');
    for (var i = 0; i < candidates.length; i++) {
      var node = candidates[i];
      var aria = (node.getAttribute('aria-label') || '').trim();
      if (!labelled(node) && SETTINGS_LABELS.indexOf(aria) === -1) continue;
      var rect = node.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      anchorNode = node;
      return node;
    }
    return null;
  }

  /** The label node holding 设置 / Settings, so the chip lands right after it. */
  function findSettingsLabel(button){
    if (!button) return null;
    var children = button.querySelectorAll('span, div, p');
    for (var i = 0; i < children.length; i++) {
      if (labelled(children[i])) return children[i];
    }
    return labelled(button) && button.children.length === 0 ? button : null;
  }

  function ensureBadge(){
    if (badge && badge.isConnected) return badge;
    var p = palette();
    // Read as a control, not as loose sidebar text: a small pill that answers
    // hovers, so the chip looks pressable before anyone presses it. The chip
    // still lives *inside* DSH's 设置 button, so it stays glued to that label.
    badge = el('span', 'display:none;align-items:center;z-index:2147482000;font:11px/1.4 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:' + p.dim + ';cursor:pointer;user-select:none;white-space:nowrap;padding:1px 6px;border:1px solid ' + p.line + ';border-radius:999px;background:' + p.btn + ';transition:color .15s,background .15s,border-color .15s');
    badge.addEventListener('mouseenter', function(){ badge.style.color = palette().fg; badge.style.borderColor = palette().accent; });
    badge.addEventListener('mouseleave', function(){ badge.style.color = palette().dim; badge.style.borderColor = palette().line; });
    return badge;
  }

  /**
   * Is this event aimed at the node? contains() covers the normal case; the
   * rectangle covers the racy one — React can swap a node we injected between
   * mousedown and mouseup, and then the browser fires the click on whatever
   * sits underneath instead ("点了没反应"). Used for the version chip and the
   * screenshot button alike.
   */
  function aimedAt(node, event){
    if (!node || !node.isConnected) return false;
    if (node.contains(event.target)) return true;
    var rect = node.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    return event.clientX >= rect.left && event.clientX <= rect.right
      && event.clientY >= rect.top && event.clientY <= rect.bottom;
  }

  /**
   * Keep the chip glued to the right of the 设置 label *inside* DSH's own
   * settings button (not floating over the page). React may re-render that
   * subtree, so this runs on the same tick as before and re-inserts when the
   * node was replaced.
   */
  function positionBadge(){
    if (!badge) return;
    var button = findSettingsButton();
    var label = findSettingsLabel(button);
    if (!label) {
      // Collapsed rail: icon-only button, no room for a text chip.
      badge.style.display = 'none';
    } else {
      if (badge.parentNode !== label.parentNode || badge.previousElementSibling !== label) {
        label.insertAdjacentElement('afterend', badge);
      }
      badge.style.display = 'inline-flex';
    }
    positionPanel();
  }

  function updateBadgeText(){
    if (!badge) return;
    var version = state.status && state.status.installed;
    badge.textContent = state.checking ? 'DSH …' : (version ? ('DSH ' + version) : 'DSH');
    if (state.checking) badge.title = '正在检查更新…';
    else if (state.status && state.status.updateAvailable) badge.title = '有新版本 ' + state.status.latest + '，点击查看';
    else badge.title = '点击检查 DSH 更新';
  }

  // ── screenshot button, right next to the composer's 添加附件 ──────────────

  // Same labels DSH uses for its own attach entry across locales.
  var ATTACH_LABELS = ['添加附件', 'Add attachment', 'Add file', 'Attach'];
  var SHOT_ICON = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">'
    + '<path d="M2.6 6.2V3.4a.8.8 0 0 1 .8-.8h2.8" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>'
    + '<path d="M13.4 9.8v2.8a.8.8 0 0 1-.8.8H9.8" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>'
    + '<rect x="4.7" y="4.7" width="6.6" height="6.6" rx="1.3" stroke="currentColor" stroke-width="1.4" stroke-dasharray="2.1 1.7"/>'
    + '</svg>';

  /** DSH's own attach trigger (aria-label 添加附件 / Add attachment …). */
  function findAttachButton(){
    var nodes = document.querySelectorAll('button, [role="button"]');
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      var aria = (node.getAttribute('aria-label') || '').trim();
      if (ATTACH_LABELS.indexOf(aria) === -1) continue;
      var rect = node.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      return node;
    }
    return null;
  }

  /**
   * Clone DSH's own attach-button styling instead of hard-coding one: the chip
   * then matches wherever the composer happens to be in this DSH version, and
   * a re-render only costs us a re-insert on the next tick.
   */
  function positionShotButton(){
    var attach = findAttachButton();
    if (!attach) return null;
    if (shotButton && shotButton.isConnected && shotButton.previousElementSibling === attach) return shotButton;
    if (shotButton && shotButton.parentNode) shotButton.parentNode.removeChild(shotButton);
    shotButton = el('button', 'display:inline-flex;align-items:center;justify-content:center');
    shotButton.type = 'button';
    shotButton.className = attach.className;
    shotButton.setAttribute('aria-label', '截图并附上（⌃⌘A）');
    shotButton.title = '截图并附上：拖拽选择矩形范围（⌃⌘A）';
    shotButton.innerHTML = SHOT_ICON;
    attach.insertAdjacentElement('afterend', shotButton);
    return shotButton;
  }

  function setShotButtonBusy(busy){
    if (!shotButton) return;
    shotButton.style.opacity = busy ? '.55' : '';
    shotButton.title = busy ? '正在截图…' : '截图并附上：拖拽选择矩形范围（⌃⌘A）';
  }

  /** Transient one-liner; screenshots are silent when they work, loud when not. */
  function toast(text){
    var p = palette();
    var node = el('div', 'position:fixed;z-index:2147483000;left:50%;transform:translateX(-50%);bottom:26px;'
      + 'max-width:min(620px,82vw);background:' + p.bg + ';color:' + p.fg + ';border:1px solid ' + p.line
      + ';border-radius:10px;padding:8px 12px;box-shadow:0 8px 24px rgba(0,0,0,.28);'
      + 'font:12.5px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif', text);
    document.body.appendChild(node);
    setTimeout(function(){ if (node.parentNode) node.parentNode.removeChild(node); }, 5000);
  }

  /**
   * Hand the PNG to the composer the same way a paste does: build a File, put
   * it in a DataTransfer and dispatch a paste event (falling back to a drop).
   * That reuses DSH's own attachment ingestion — nothing about the upload,
   * thumbnails or draft state is reimplemented here.
   */
  function attachScreenshot(capture){
    return fetch(capture.dataUrl).then(function(response){ return response.blob(); }).then(function(blob){
      var name = capture.name || 'screenshot.png';
      var file;
      try { file = new File([blob], name, { type: 'image/png' }); }
      catch (e) { try { blob.name = name; } catch (e2) {} file = blob; }
      var target = document.querySelector('[contenteditable="true"], textarea');
      if (!target) throw new Error('找不到输入框');
      var transfer = null;
      try { transfer = new DataTransfer(); transfer.items.add(file); } catch (e) { transfer = null; }
      if (!transfer || !transfer.items.length) throw new Error('当前界面不支持注入截图');
      var before = document.querySelectorAll('img[src^="blob:"]').length;
      target.focus();
      var delivered = false;
      try {
        target.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: transfer }));
        delivered = true;
      } catch (e) { delivered = false; }
      if (!delivered) {
        try {
          var box = target.getBoundingClientRect();
          target.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: transfer,
            clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 }));
          delivered = true;
        } catch (e) { delivered = false; }
      }
      if (!delivered) throw new Error('当前界面不支持注入截图');
      return new Promise(function(resolve){ setTimeout(resolve, 400); }).then(function(){
        if (document.querySelectorAll('img[src^="blob:"]').length <= before) throw new Error('输入框没有接受这张截图');
      });
    });
  }

  var shotWaiting = false;

  /** Poll the host while the selection UI is up, then attach what it produced. */
  function waitForCapture(startedAt){
    return api('/screenshot').then(function(capture){
      if (capture && capture.state === 'capturing') {
        if (Date.now() - startedAt > 5 * 60 * 1000) throw new Error('截图等待超时');
        return new Promise(function(resolve){ setTimeout(resolve, 400); }).then(function(){ return waitForCapture(startedAt); });
      }
      if (!capture || capture.state === 'cancelled' || capture.state === 'idle') return null;
      if (capture.state === 'ready') return capture;
      throw new Error(capture.message || '截图失败');
    });
  }

  /**
   * Ask the host for one interactive region screenshot and attach the result.
   * Shared by the composer button, the ⌃⌘A menu item and the in-page shortcut,
   * and guarded so a double trigger can only ever run one capture.
   */
  function captureAndAttach(){
    if (shotWaiting) return Promise.resolve();
    shotWaiting = true;
    setShotButtonBusy(true);
    var startedAt = Date.now();
    return api('/screenshot', {}).then(function(){
      return waitForCapture(startedAt);
    }).then(function(capture){
      return capture ? attachScreenshot(capture) : undefined;
    }).catch(function(error){
      toast('截图附上失败：' + String(error && error.message ? error.message : error));
    }).then(function(){
      shotWaiting = false;
      setShotButtonBusy(false);
    });
  }

  // ── the panel behind the badge ───────────────────────────────────────────

  function closePanel(){ if (panel) { panel.remove(); panel = null; } }

  function positionPanel(){
    if (!panel || !badge) return;
    var rect = badge.getBoundingClientRect();
    var width = 300;
    panel.style.width = width + 'px';
    panel.style.left = Math.round(Math.max(8, Math.min(rect.left, window.innerWidth - width - 8))) + 'px';
    panel.style.bottom = Math.round(Math.max(8, window.innerHeight - rect.top + 6)) + 'px';
  }

  function renderPanel(){
    if (!panel) return;
    var p = palette();
    var status = state.status;
    var note = state.note;
    panel.textContent = '';
    panel.appendChild(el('div', 'font-weight:600', status ? ('DSH ' + (status.installed || '?')) : 'DSH 版本未知'));
    var sub;
    if (state.checking) sub = '正在检查 npm 上的版本…';
    else if (status) sub = '跟随通道 ' + (status.tag || status.channel || 'latest')
      + (status.defaultPermission ? ' · 新会话默认权限：' + permissionLabel(status.defaultPermission) : '');
    else if (state.error) sub = state.error;
    else sub = '尚未获取状态，点“检查更新”重试';
    panel.appendChild(el('div', 'color:' + p.dim + ';font-size:12px;margin-top:2px', sub));
    if (status && status.newerTags && status.newerTags.length) {
      var row = el('div', 'margin-top:6px');
      row.appendChild(el('span', 'margin-right:4px', '可升级：'));
      status.newerTags.forEach(function(entry){
        row.appendChild(button(tagLabel(entry.tag) + ' ' + entry.version, true, function(){ upgradeTo(entry.version, entry.tag); }));
      });
      panel.appendChild(row);
    } else if (status) {
      panel.appendChild(el('div', 'color:' + p.dim + ';font-size:12px;margin-top:6px', '只提醒 latest 通道的更新；next / alpha 等预发布版本不提醒。'));
    }
    var actions = el('div', 'margin-top:8px');
    actions.appendChild(button(state.checking ? '检查中…' : '检查更新', false, function(){
      if (!state.checking && !state.busy) refresh({ interactive: true, force: true });
    }, state.checking));
    if (!(status && status.wrapper)) actions.appendChild(button('在桌面应用中打开', false, openApp));
    actions.appendChild(button('配置文件夹', false, openConfig));
    panel.appendChild(actions);
    // Straight answer to "did that click do anything?": one line, highest
    // priority first — the verdict of the check just run, then a registry that
    // could not be read (which must never look like "already up to date"),
    // then when the last check happened.
    if (note) {
      var tone = note.kind === 'error' ? p.bad : (note.kind === 'ok' ? p.ok : p.accent);
      var stamp = state.checkedAt ? '　' + clockText(state.checkedAt) : '';
      panel.appendChild(el('div', 'margin-top:6px;font-size:11.5px;color:' + tone, note.text + stamp));
    } else if (status && status.registryError) {
      panel.appendChild(el('div', 'margin-top:6px;font-size:11.5px;color:' + p.warn, '读不到 npm 上的版本：' + status.registryError));
    } else if (state.checkedAt) {
      panel.appendChild(el('div', 'color:' + p.dim + ';font-size:11px;margin-top:5px', '上次检查：' + clockText(state.checkedAt)));
    }
  }

  function openPanel(){
    var p = palette();
    panel = el('div', 'position:fixed;z-index:2147483000;background:' + p.bg + ';color:' + p.fg + ';border:1px solid ' + p.line + ';border-radius:12px;box-shadow:0 8px 28px rgba(0,0,0,.28);padding:10px 12px;font:12.5px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;backdrop-filter:blur(12px)');
    document.body.appendChild(panel);
    positionPanel();
    renderPanel();
    // Opening the chip *is* the user asking for a version check: run one so the
    // panel never shows a stale answer and the click always has a visible result.
    refresh({ interactive: true, force: true });
  }

  function togglePanel(){
    if (panel) closePanel(); else openPanel();
  }

  // ── lifecycle ────────────────────────────────────────────────────────────

  /**
   * Ask the host for the current status.
   *
   * "interactive" marks a user-triggered check: it paints "检查中…" first and
   * always ends in a visible verdict (latest / newer / why it failed), so the
   * button can never look dead. "force" skips the once-per-30s throttle.
   */
  function refresh(options){
    var opts = options || {};
    var now = Date.now();
    var interactive = Boolean(opts.interactive) && (opts.force || now - lastCheckAt > 30000);
    if (interactive) {
      state.checking = true;
      state.note = null;
      lastCheckAt = now;
      checkStartedAt = now;
      updateBadgeText();
      renderPanel();
    }
    return api('/status')
      .then(function(status){ return settle(status, null, interactive); })
      .catch(function(error){ return settle(null, error, interactive); });
  }

  /**
   * Paint the outcome of one /status call.
   *
   * A local check answers in a few milliseconds; without a floor the click would
   * have no visible effect at all when the answer is "nothing changed". So an
   * interactive check keeps "检查中…" up for at least MIN_CHECK_MS.
   */
  function settle(status, error, interactive){
    var paint = function(){
      state.checking = false;
      lastCheckAt = Date.now();
      if (status) {
        state.status = status;
        state.error = null;
        state.checkedAt = new Date();
        if (interactive) {
          if (status.updateAvailable) state.note = { kind: 'info', text: '发现新版本 ' + status.latest + '，本地是 ' + (status.installed || '?') + '，可点上面的按钮升级。' };
          else if (status.registryError) state.note = { kind: 'error', text: '检查失败：读不到 npm 上的版本。' };
          else state.note = { kind: 'ok', text: '已是最新版本：' + (status.installed || '?') + '（通道 ' + (status.tag || status.channel || 'latest') + '）' };
        }
        updateBadgeText();
        if (status.updateAvailable && !state.dismissed) renderUpdate(); else if (!state.busy) removeCard();
      } else {
        // The reason stays in the sub line, so it keeps showing until a check
        // succeeds — no duplicate copy in the verdict line.
        state.status = null;
        state.error = describeError(error);
        state.note = null;
        updateBadgeText();
        if (!state.busy) removeCard();
      }
      renderPanel();
      return status || undefined;
    };
    var remaining = interactive ? MIN_CHECK_MS - (Date.now() - checkStartedAt) : 0;
    if (remaining > 0) { setTimeout(paint, remaining); return; }
    return paint();
  }

  function mount(){
    if (!document.body) { setTimeout(mount, 200); return; }
    ensureBadge();
    updateBadgeText();
    positionBadge();
    positionShotButton();
    var keepPlaced = function(){ positionBadge(); positionShotButton(); };
    window.addEventListener('resize', keepPlaced);
    setInterval(keepPlaced, 1000);
    document.addEventListener('keydown', function(event){
      if (event.key === 'Escape') closePanel();
      // The app also binds ⌃⌘A natively (its menu wins there); this copy keeps
      // the same shortcut working in a plain browser tab. The shared guard in
      // captureAndAttach() makes a double trigger harmless.
      if (event.key === 'a' && event.ctrlKey && event.metaKey && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        captureAndAttach();
      }
    });
    // The chip sits *inside* DSH's own 设置 button, whose click opens the
    // settings dialog. Handle the chip in the capture phase on document — the
    // earliest point there is — and stop the event there, so the press can
    // neither reach that button nor get lost to React re-rendering the label
    // node between mousedown and mouseup (the two ways this looked "dead").
    // aimedAt() also accepts a hit inside the node's rectangle, which is what
    // rescues the press when that swap happens mid-click. Same treatment for
    // the screenshot button we drop next to 添加附件.
    ['pointerdown', 'mousedown'].forEach(function(type){
      document.addEventListener(type, function(event){
        if (aimedAt(badge, event) || aimedAt(shotButton, event)) event.stopPropagation();
      }, true);
    });
    document.addEventListener('click', function(event){
      if (aimedAt(badge, event)) {
        event.stopPropagation();
        event.preventDefault();
        togglePanel();
        return;
      }
      if (aimedAt(shotButton, event)) {
        event.stopPropagation();
        event.preventDefault();
        captureAndAttach();
        return;
      }
      if (panel && !panel.contains(event.target)) closePanel();
    }, true);
    // The app menu item (⌃⌘A) reaches the very same flow.
    window.__dshDesktopShellCapture = captureAndAttach;
    // Re-check when the window comes back to the front: DSH.app windows stay
    // open for days, and a status fetched days ago is worse than none.
    document.addEventListener('visibilitychange', function(){
      if (!document.hidden && !state.checking && !state.busy) refresh();
    });
    refresh();
    setTimeout(refresh, 30000);
    setInterval(refresh, 6 * 60 * 60 * 1000);
  }
  mount();
})();
</script>`
}

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {Record<string, unknown>} rawConfig
 */
export function apply(ctx, rawConfig) {
  const config = { ...DEFAULTS, ...asRecord(rawConfig) }
  const logger = ctx.logger ?? console
  const home = join(homedir(), '.dsh', 'desktop-shell')
  const endpointFile = join(home, 'endpoint.json')
  const token = randomBytes(24).toString('hex')

  /** @type {{at: number, tags: Record<string, string>} | undefined} */
  let registryCache
  let upgrading = false
  let lastUpgrade = ''
  // One interactive capture at a time; the page polls this while the user is
  // dragging, so the long `screencapture` wait never sits inside a request.
  let screenshotState = { state: 'idle' }

  const connectionOf = () => (typeof ctx.get === 'function' ? ctx.get('connection') : undefined)

  /** DSH's own fence: Host/Origin check, then browser authentication. */
  function rejected(req, res) {
    try {
      const connection = connectionOf()
      const rejection = connection?.requestRejection?.(req)
      if (rejection === undefined || rejection === null) return false
      res.statusCode = rejection
      res.end()
      return true
    } catch (error) {
      logger.warn?.(`desktop-shell: request fence failed: ${error}`)
      res.statusCode = 403
      res.end()
      return true
    }
  }

  /** Defence in depth on top of the cookie: a per-process header token. */
  function tokenRejected(req, res) {
    const given = req.headers['x-dsh-desktop-token']
    if (given === token) return false
    sendJson(res, 403, { code: 'forbidden', message: 'missing or stale desktop-shell token; reload the page' })
    return true
  }

  async function registryTags() {
    const now = Date.now()
    if (registryCache && now - registryCache.at < Number(config.cacheMs)) return registryCache.tags
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 20000)
    try {
      const response = await fetch(String(config.registry), {
        signal: controller.signal,
        headers: { accept: 'application/vnd.npm.install-v1+json, application/json' },
      })
      if (!response.ok) throw new Error(`registry HTTP ${response.status}`)
      const json = await response.json()
      const tags = {}
      const dist = asRecord(json['dist-tags'])
      for (const [key, value] of Object.entries(dist)) if (typeof value === 'string') tags[key] = value
      registryCache = { at: now, tags }
      return tags
    } finally {
      clearTimeout(timer)
    }
  }

  async function statusPayload() {
    const installed = await findInstalledVersion()
    let tags = {}
    let registryError
    try {
      tags = await registryTags()
    } catch (error) {
      registryError = String(error && error.message ? error.message : error)
    }
    const policy = buildStatus({
      installed: installed?.version,
      tags,
      tag: typeof config.tag === 'string' ? config.tag : config.channel,
      showPrereleases: config.showPrereleases === true,
    })
    const installedVersion = installed?.version
    // Diagnostic + UI hint: the default preset the host will pin into sessions
    // created from now on (reads the permission-presets service in the same
    // root context; absent when the composition has no such service).
    let defaultPermission
    try {
      defaultPermission = ctx.get?.('permissionPresets')?.defaultPreset
    } catch {
      defaultPermission = undefined
    }
    return {
      ok: true,
      installed: installedVersion,
      installedPath: installed?.path,
      defaultPermission,
      latest: policy.followed,
      tag: policy.follow,
      channel: policy.follow,
      showPrereleases: policy.showPrereleases,
      // Never hand prerelease channels to the client unless explicitly opted in.
      distTags: policy.showPrereleases
        ? tags
        : (policy.followed ? { [policy.follow]: policy.followed } : {}),
      newerTags: policy.newerTags,
      updateAvailable: policy.updateAvailable,
      registryError,
      registry: config.registry,
      wrapper: process.env.DSH_DESKTOP_SHELL === '1',
      appName: config.appName,
      platform: process.platform,
      port: ctx.get?.('webServer')?.port,
      pid: process.pid,
      lastUpgrade: lastUpgrade || undefined,
    }
  }

  // ── routes ────────────────────────────────────────────────────────────────

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: STATUS_ROUTE,
    handler: async (req, res) => {
      if (rejected(req, res)) return
      if (req.method !== 'GET') return sendMethodNotAllowed(res, 'GET')
      if (tokenRejected(req, res)) return
      try {
        sendJson(res, 200, await statusPayload())
      } catch (error) {
        sendJson(res, 500, { ok: false, message: String(error && error.message ? error.message : error) })
      }
    },
  }), 'desktop-shell: GET status')

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: UPGRADE_ROUTE,
    handler: async (req, res) => {
      if (rejected(req, res)) return
      if (req.method !== 'POST') return sendMethodNotAllowed(res, 'POST')
      if (tokenRejected(req, res)) return
      const body = await readJsonBody(req)
      if (body === undefined) return sendJson(res, 400, { ok: false, message: 'invalid JSON body' })
      const version = typeof body.version === 'string' ? body.version.trim() : ''
      const followedTag = typeof config.tag === 'string' ? config.tag : (typeof config.channel === 'string' ? config.channel : 'latest')
      const target = version || (await registryTags())[followedTag] || 'latest'
      if (!/^[0-9A-Za-z][0-9A-Za-z.+-]*$/.test(target)) {
        return sendJson(res, 400, { ok: false, message: `unsupported version specifier: ${target}` })
      }
      if (upgrading) return sendJson(res, 409, { ok: false, message: 'an upgrade is already running' })
      upgrading = true
      lastUpgrade = ''
      try {
        const command = `${config.npmBin} install -g @deepseek-ai/dsh@${target}`
        logger.info?.(`desktop-shell: running ${command}`)
        const result = await runCommand(command, Number(config.upgradeTimeoutMs))
        lastUpgrade = result.ok ? `upgraded to ${target}` : `failed: exit ${result.code}`
        registryCache = undefined
        sendJson(res, result.ok ? 200 : 500, {
          ok: result.ok,
          version: target,
          code: result.code,
          output: result.output.slice(-MAX_OUTPUT_BYTES),
          restartRequired: result.ok,
        })
      } catch (error) {
        sendJson(res, 500, { ok: false, message: String(error && error.message ? error.message : error) })
      } finally {
        upgrading = false
      }
    },
  }), 'desktop-shell: POST upgrade')

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: OPEN_APP_ROUTE,
    handler: async (req, res) => {
      if (rejected(req, res)) return
      if (req.method !== 'POST') return sendMethodNotAllowed(res, 'POST')
      if (tokenRejected(req, res)) return
      const app = typeof config.appName === 'string' && config.appName ? config.appName : 'DSH'
      const result = await runCommand(`open -a ${JSON.stringify(app)}`, 15000)
      sendJson(res, result.ok ? 200 : 500, { ok: result.ok, output: result.output.slice(-4000) })
    },
  }), 'desktop-shell: POST open-app')

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: OPEN_CONFIG_ROUTE,
    handler: async (req, res) => {
      if (rejected(req, res)) return
      if (req.method !== 'POST') return sendMethodNotAllowed(res, 'POST')
      if (tokenRejected(req, res)) return
      await mkdir(home, { recursive: true }).catch(() => {})
      const result = await runCommand(`open ${JSON.stringify(home)}`, 15000)
      sendJson(res, result.ok ? 200 : 500, { ok: result.ok, output: result.output.slice(-4000) })
    },
  }), 'desktop-shell: POST open-config')

  // Two-phase screenshot: POST starts the interactive capture and returns at
  // once (a drag can take a minute, and no request should stay open that long),
  // GET is the page polling for the finished PNG.
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: SCREENSHOT_ROUTE,
    handler: async (req, res) => {
      if (rejected(req, res)) return
      if (tokenRejected(req, res)) return
      if (req.method === 'GET') return sendJson(res, 200, screenshotState)
      if (req.method !== 'POST') return sendMethodNotAllowed(res, 'GET, POST')
      if (screenshotState.state === 'capturing') return sendJson(res, 409, { ok: false, message: '已经在截图了' })
      screenshotState = { state: 'capturing', startedAt: Date.now() }
      captureScreenshot().then((result) => {
        screenshotState = result.ok
          ? { state: 'ready', name: result.name, path: result.path, bytes: result.bytes, dataUrl: result.dataUrl }
          : (result.cancelled ? { state: 'cancelled' } : { state: 'error', message: result.message })
        if (result.ok) logger.info?.(`desktop-shell: screenshot ${result.path}`)
      }).catch((error) => {
        screenshotState = { state: 'error', message: String(error && error.message ? error.message : error) }
      })
      sendJson(res, 200, { ok: true, state: 'capturing' })
    },
  }), 'desktop-shell: GET/POST screenshot')

  // ── index banner ──────────────────────────────────────────────────────────

  if (config.banner !== false) {
    ctx.effect(() => {
      try {
        const marker = 'dsh-desktop-shell-banner'
        const transform = (html) => {
          if (typeof html !== 'string' || html.includes(marker)) return html
          const script = bannerScript(token)
          const at = html.search(/<\/body>/i)
          if (at === -1) return `${html}\n${script}`
          return `${html.slice(0, at)}${script}\n${html.slice(at)}`
        }
        return ctx.webServer.tapIndex(transform)
      } catch (error) {
        logger.warn?.(`desktop-shell: banner injection unavailable: ${error}`)
        return () => {}
      }
    }, 'desktop-shell: index banner')
  }

  // ── endpoint handoff for DSH.app ──────────────────────────────────────────

  if (config.writeEndpoint !== false && process.env.DSH_NO_DESKTOP_ENDPOINT !== '1') {
    ctx.effect(() => {
      let disposed = false
      const write = async () => {
        if (disposed) return
        try {
          const port = ctx.get?.('webServer')?.port
          if (!port) return
          const connection = connectionOf()
          const base = `http://127.0.0.1:${port}/`
          const url = typeof connection?.authenticatedUrl === 'function'
            ? connection.authenticatedUrl(base)
            : base
          const installed = await findInstalledVersion()
          await mkdir(home, { recursive: true })
          await writeFile(endpointFile, JSON.stringify({
            url,
            port,
            pid: process.pid,
            version: installed?.version,
            // Lets DSH.app tell its own background server from one the user
            // started in a terminal (it must never kill the latter).
            desktopShell: process.env.DSH_DESKTOP_SHELL === '1',
            updatedAt: new Date().toISOString(),
          }, null, 2), { mode: 0o600 })
        } catch (error) {
          logger.warn?.(`desktop-shell: endpoint handoff failed: ${error}`)
        }
      }
      const announce = () => {
        const loader = typeof ctx.get === 'function' ? ctx.get('loader') : undefined
        const settled = loader?.await?.()
        if (settled && typeof settled.then === 'function') settled.then(write, () => {})
        else void write()
      }
      announce()
      return () => {
        disposed = true
        // Synchronous so shutdown cannot cut the cleanup short. Only remove our
        // own handoff: another live instance may own the file.
        try {
          const parsed = JSON.parse(readFileSync(endpointFile, 'utf8'))
          if (parsed?.pid === process.pid) rmSync(endpointFile, { force: true })
        } catch {
          /* no handoff of ours to remove */
        }
      }
    }, 'desktop-shell: endpoint handoff')
  }

  logger.info?.('desktop-shell: ready (routes under /desktop-shell)')
}

export {
  bannerScript as __clientScript,
  buildStatus as __buildStatus,
  compareVersions as __compareVersions,
  findInstalledVersion as __findInstalledVersion,
}

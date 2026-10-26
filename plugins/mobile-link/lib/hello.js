/**
 * What this connector is and what it can do.
 *
 * The connector and the app are deployed separately, so the app has to ask
 * rather than assume. It asks over the link — a reserved method the connector
 * answers locally — because the HTTP status route only exists on the direct
 * path, and the direct path is not what users run.
 *
 * Feature detection, not version comparison: a connector that lacks a
 * capability simply does not list it, and the app hides that entry instead of
 * calling something that would come back as a 404 from the Host.
 */

import { readFileSync } from 'node:fs'

/** Reserved method the app calls once per connection. */
export const HELLO_METHOD = '_link/hello'

/**
 * The connector's own version.
 *
 * Read from package.json rather than written out twice: the two drifting apart
 * is exactly the kind of thing nobody notices until a support question depends
 * on it (they had drifted: the manifest said 0.1.0 and this said 0.2.0).
 *
 * 用 `readFileSync` 而不是 `require('../package.json')`：`require` 会把 JSON 缓存在
 * CJS 模块表里，而这个文件走热更（模块 URL 带参数重新求值，**缓存表不清**）。实测
 * 2026-10-17：DSH 进程 10-12 起就一直报 `0.6.0`，而仓库 10-13 已经升到 `0.6.5`——
 * 报的还是进程启动那天的版本号。读文件没有这层缓存，热更后一问就是真值。
 */
export const SERVER_VERSION = readManifestVersion()

function readManifestVersion() {
  try {
    const manifest = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
    return typeof manifest.version === 'string' && manifest.version ? manifest.version : '0.0.0'
  } catch {
    return '0.0.0'
  }
}

/**
 * 宿主 DSH 的版本，取不到时为 `null`。
 *
 * 为什么读环境变量而不是 package.json：连接器跑在宿主进程里，宿主把自己的版本放在
 * `DSH_CLIENT_VERSION`（桌面版与 `dsh web` 都设）；而连接器是从仓库 / npm 链接进档案的，
 * 它自己的 `package.json` 里没有宿主的版本，从 `node_modules` 里猜路径又会随打包形态变
 * （Electron 的 asar 路径 fs 未必读得到）。读不到就如实报 null，不编一个数。
 *
 * 用函数而不是常量：热更会重新求值模块，但环境变量在进程生命周期内可能被测试替换；
 * 每次问都读一次，代价可以忽略。
 */
export function hostVersion() {
  const value = process.env.DSH_CLIENT_VERSION
  return typeof value === 'string' && value.trim() ? value.trim() : null
}

/**
 * Capabilities the app may rely on.
 *
 * - `file-transfer`  files can be staged on the computer (see files.js)
 * - `events`         the per-device `$events` stream is served
 * - `session-streams` logical streams (`session/follow`, …) are served
 * - `pair-code`      this connector can mint a pairing code on request
 * - `qr-pairing`     this connector renders the pairing QR itself (the `svg`
 *                    field of `POST /mobile-link/pair-code`), so the DSH client
 *                    needs no QR library of its own
 * - `self-enroll`    this connector can register itself with an invite code
 * - `git`            git status / diff / log / show can be read from the work
 *                    tree on this computer (see git.js)
 * - `background-transfer`
 *                    this connector speaks the `fsPut*` / `fsGet*` bridge frames,
 *                    so the app may **send and fetch** large files over the
 *                    relay's HTTPS surface with a background URL session instead
 *                    of the WebSocket. An app that does not see this falls back to
 *                    the WSS path — which is why adding the capability is the
 *                    *only* switch the client needs.
 */
export const SERVER_CAPABILITIES = [
  'file-transfer', 'events', 'session-streams', 'pair-code', 'qr-pairing', 'self-enroll', 'git',
  'background-transfer',
  // history-window: the connector answers `_link/sessionWindow` (exact seq window);
  // session-search: it answers `_link/sessionFind` (in-session literal search). The
  // phone switches channels on these and falls back to `session/page` without them.
  'history-window', 'session-search',
  // session-digest: 连接器答 `_link/sessionDigest`（`session/list` 的精简同形副本，
  // 去掉 App 侧零读取点的字段、可按要求 gzip）。手机侧按这条能力切换，缺了就回退到
  // `session/list`——spec 021 只做连接器侧，切换在后续规格。
  'session-digest',
  // history-role-filter: `_link/sessionWindow` accepts `roles` (e.g. just the
  // "me" role) and returns only matching records; seq cursor semantics are
  // unchanged (spec 009 T031).
  'history-role-filter',
  // history-scan-boundary: such a page also carries `scanBoundary` — the seq the
  // scan actually reached — so a caller whose page was filtered empty can still
  // advance instead of asking for the same stretch forever (spec 009 T039).
  'history-scan-boundary',
  // search-progress: 扫描式搜索的每一页都带 `totalChunks` / `remainingChunks`，
  // 界面据此从第一页起就能显示「已扫 k/N 片」（026 之后的 App 才读）。
  'search-progress',
  // history-compression: `_link/sessionWindow` 可按要求把回包压成
  // `deflate-raw` 的 base64 信封（见 history/compress.js）。手机只在看到这条
  // 能力时请求；旧客户端不传 encoding，回包与改动前逐字一致。
  'history-compression',
  // history-fold-summary: `_link/sessionWindow` 接受 `fold: true`，把已完成轮次的
  // 过程事件折成一条 `+link/fold` 摘要（见 history/fold.js）；手机展开时用普通请求取回。
  'history-fold-summary',
  // history-fold-summary-v2: `_link/sessionWindow` 另接受 `fold: "summary"`——概要先行
  // 取数（只回讲话 + `+link/fold` v2 概要 + 正式回答，按整轮切页，见
  // history/fold-summary.js 与 history/summary-window.js）。**独立能力位**：
  // 不声明 `"summary"` 的老客户端拿到的回包与改动前逐字节相同。
  'history-fold-summary-v2',
  'history-coverage',
  // jobs-roster: 连接器答 `_link/jobRoster`（逐活会话聚合宿主任务），并推
  // `link/jobs` 帧（spec 018）。手机**只按这条能力**决定是否渲染任务面板、列表行
  // 右侧计数与卡片新行：无此能力的旧连接器，手机整块不出现（界面与升级前逐屏一致）。
  'jobs-roster',
  // dir-mtimes: 连接器答 `_link/dirListing`——宿主 `workspaceFiles/list` 的同形副本，
  // 在电脑本机对每个条目补一个 `mtimeMs`（宿主类型里没有时间字段，`stat` 的 version
  // 是 opaque token，推不出时间）。手机**只按这条能力**决定要不要走新方法：没有它的
  // 旧连接器仍走 `workspaceFiles/list`，文件页与升级前逐屏一致（只是没有时间），不报错。
  'dir-mtimes',
  'device-subprotocol-auth', 'persistent-pair-code', 'account-state', 'account-state-push',
]

export function isHelloMethod(method) {
  return method === HELLO_METHOD
}

/**
 * What the phone says it is, out of the handshake arguments.
 *
 * The app sends this on every connection — the only place the *client's* build
 * travels, since the relay's device row is otherwise written once at pairing and
 * then never again. Older clients send `{}`, which yields nulls: reporting
 * "unknown" beats reporting a version that may be days old.
 *
 * Exported for testing: what it returns ends up in a log line a person will read
 * when they ask "did that phone update?".
 */
export function parseClientInfo(args) {
  const text = (value) => (typeof value === 'string' && value.trim().length > 0 ? value.trim() : null)
  const name = text(args?.clientName)
  const version = text(args?.clientVersion)
  const build = text(args?.clientBuild)
  if (!name && !version && !build) return null
  return {
    name,
    version,
    build,
    // `DSHMobile 1.0 (20260919.0005)`, skipping whatever is missing.
    label: [name, version ? `${version}${build ? ` (${build})` : ''}` : build].filter(Boolean).join(' '),
    at: Date.now(),
  }
}

/** The answer to {@link HELLO_METHOD}. */
export function helloPayload({ protocolVersion, agentId, name } = {}) {
  return {
    serverVersion: SERVER_VERSION,
    // 宿主 DSH 的版本：手机据此显示「DSH 版本」，中转据此记录这台电脑跑的是哪个宿主。
    // 老客户端不认识这个键，忽略即可；取不到时是 null（如实表示"不知道"）。
    hostVersion: hostVersion(),
    capabilities: SERVER_CAPABILITIES,
    protocolVersion,
    agentId: agentId ?? null,
    name: name ?? null,
  }
}

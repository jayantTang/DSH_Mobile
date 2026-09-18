#!/usr/bin/env node
/**
 * Builds a **synthetic** transcript for the README screenshots.
 *
 * `docs/artifacts/screenshots/` is deliberately gitignored: those pictures come
 * from real sessions and carry device names, home paths and private project
 * content. Advertising pictures therefore cannot reuse them — they have to be
 * shot again over a session that contains nothing of the author's.
 *
 * This script makes that session. It writes a small, invented project into a
 * dedicated workspace, creates a session there, and asks a real agent turn to
 * find and fix a planted bug. The result is a genuine transcript (streaming
 * output, tool cards, a diff, a test run) whose *content* is invented, so the
 * pictures can be published.
 *
 *   node scripts/dev/demo-session.mjs                 # seed, print the session id
 *   node scripts/dev/demo-session.mjs --cleanup <id>  # remove it again
 *   node scripts/dev/demo-session.mjs --cleanup-all   # remove every demo session
 *
 * Everything it touches lives under `/tmp/dsh-mobile-demo/` and the session
 * group that path maps to; no real session is read or modified.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const HOME = homedir()
const ENDPOINT = join(HOME, '.dsh', 'desktop-shell', 'endpoint.json')

/// Where the invented project lives.
///
/// `/tmp`, not a directory under `~/.dsh`: the agent echoes absolute paths into
/// the transcript, and those paths end up in the pictures. A workspace under the
/// home directory would print the author's account name in every tool card —
/// `/Users/<name>/.dsh/...` — which is exactly the kind of thing a published
/// screenshot must not carry. `/tmp/dsh-mobile-demo` says nothing about anyone.
const DEMO_DIR = '/tmp/dsh-mobile-demo'
/// The host groups sessions under a directory named after the workspace path
/// with the separators flattened. Its exact escaping is the host's business —
/// and it is not the obvious one (the dot in `.dsh` survives) — so the group is
/// *matched* by the workspace's own name instead of rebuilt from it. A rebuild
/// silently matched nothing and left three demo sessions behind.
const SESSION_GROUP_GLOB = /dsh-mobile-demo/
const CACHE_DIR = join(HOME, '.dsh', 'storages', 'session_projcache', 'sessions')

function demoSessionGroups() {
  const root = join(HOME, '.dsh', 'sessions')
  if (!existsSync(root)) return []
  return readdirSync(root)
    .filter((name) => SESSION_GROUP_GLOB.test(name))
    .map((name) => join(root, name))
}

// ── the invented project ────────────────────────────────────────────────────

const FILES = {
  'package.json': `${JSON.stringify({
    name: 'feeds',
    version: '0.1.0',
    private: true,
    type: 'module',
    scripts: { test: 'node --test' },
  }, null, 2)}\n`,

  'README.md': `# feeds

把几个 RSS 源拉下来，筛掉看过的，按时间倒序打印。

\`\`\`bash
node bin/feeds.js <源地址>
node --test
\`\`\`

## 说明

- 只记条目 id，不存正文
- \`filterSeen\` 不许改动传入的数组：调用方还在用它
`,

  'src/feeds.js': `/** 把源里的条目整理成看得懂的形状。 */
export function normalize(items) {
  return items.map((item) => ({
    id: item.guid ?? item.link,
    title: (item.title ?? '（无标题）').trim(),
    at: item.pubDate ? new Date(item.pubDate) : undefined,
  }))
}

/** 按时间倒序；没有时间的排在最后。 */
export function sortByTime(entries) {
  return [...entries].sort((a, b) => (b.at?.getTime?.() ?? 0) - (a.at?.getTime?.() ?? 0))
}

/** 挑出没读过的。 */
export function filterSeen(entries, seen) {
  return entries.map((entry) => (seen.has(entry.id) ? undefined : entry))
}
`,

  'src/render.js': `import { normalize, sortByTime, filterSeen } from './feeds.js'

/** 源 → 要打印的行。 */
export function linesFor(feed, seen = new Set()) {
  return sortByTime(filterSeen(normalize(feed.items ?? []), seen))
    .map((entry) => \`\${entry.at ? entry.at.toISOString().slice(0, 10) : '----------'}  \${entry.title}\`)
}
`,

  'bin/feeds.js': `#!/usr/bin/env node
import { linesFor } from '../src/render.js'

const SEEN = new Set(['post-2'])

if (process.argv[2] === '--demo') {
  const feed = {
    items: [
      { guid: 'post-1', title: '第一条', pubDate: '2026-09-01T00:00:00Z' },
      { guid: 'post-2', title: '第二条（已读）', pubDate: '2026-09-03T00:00:00Z' },
      { guid: 'post-3', title: '第三条', pubDate: '2026-09-02T00:00:00Z' },
    ],
  }
  console.log(linesFor(feed, SEEN).join('\\n'))
  process.exit(0)
}

console.log('用法: feeds.js --demo')
`,

  'test/feeds.test.js': `import { test } from 'node:test'
import assert from 'node:assert/strict'
import { filterSeen, sortByTime } from '../src/feeds.js'
import { linesFor } from '../src/render.js'

const entries = [
  { id: 'a', title: '第一条', at: new Date('2026-09-01T00:00:00Z') },
  { id: 'b', title: '第二条', at: new Date('2026-09-03T00:00:00Z') },
  { id: 'c', title: '第三条', at: new Date('2026-09-02T00:00:00Z') },
]

test('已读的条目整条被丢掉，不是只留一个洞', () => {
  const kept = filterSeen(entries, new Set(['b']))
  assert.equal(kept.length, 2)
  assert.deepEqual(kept.map((entry) => entry.id), ['a', 'c'])
})

test('filterSeen 不改动传入的数组', () => {
  const input = [...entries]
  filterSeen(input, new Set(['b']))
  assert.deepEqual(input.map((entry) => entry.id), ['a', 'b', 'c'])
})

test('sortByTime 按时间倒序', () => {
  assert.deepEqual(sortByTime(entries).map((entry) => entry.id), ['b', 'c', 'a'])
})

test('渲染出来的行数与条目数一致', () => {
  const feed = {
    items: [
      { guid: 'a', title: '第一条', pubDate: '2026-09-01T00:00:00Z' },
      { guid: 'b', title: '第二条', pubDate: '2026-09-03T00:00:00Z' },
    ],
  }
  assert.equal(linesFor(feed, new Set(['b'])).length, 1)
})
`,
}

// ── host access ─────────────────────────────────────────────────────────────

function endpoint() {
  if (!existsSync(ENDPOINT)) throw new Error(`no live DSH: ${ENDPOINT} is missing (start \`dsh web\`)`)
  const raw = JSON.parse(readFileSync(ENDPOINT, 'utf8'))
  const token = /token=([^&]+)/.exec(raw.url ?? '')?.[1]
  if (!raw.port || !token) throw new Error('endpoint.json carries no port/token')
  return { port: raw.port, token }
}

async function host() {
  const { port, token } = endpoint()
  const exchange = await fetch(`http://127.0.0.1:${port}/?token=${token}`, { redirect: 'manual' })
  const cookie = (exchange.headers.getSetCookie?.() ?? [])[0]?.split(';')[0]
  if (!cookie) throw new Error(`token exchange failed with HTTP ${exchange.status}`)
  let seq = 0
  return {
    port,
    async call(method, args) {
      const response = await fetch(`http://127.0.0.1:${port}/api/${method}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', cookie },
        body: JSON.stringify({ type: 'client-request', rpcId: `demo${++seq}`, method, payload: { args } }),
      })
      const body = await response.json()
      if (!body.result?.ok) throw new Error(`${method}: ${JSON.stringify(body.result?.error)}`)
      return body.result.value
    },
  }
}

// ── cleanup ─────────────────────────────────────────────────────────────────

function removeSession(sessionId) {
  let removed = 0
  if (existsSync(join(HOME, '.dsh', 'sessions'))) {
    for (const group of readdirSync(join(HOME, '.dsh', 'sessions'))) {
      const directory = join(HOME, '.dsh', 'sessions', group, sessionId)
      if (existsSync(directory)) {
        rmSync(directory, { recursive: true, force: true })
        removed += 1
      }
    }
  }
  rmSync(join(CACHE_DIR, `${sessionId}.json`), { force: true })
  return removed
}

function removeAllDemoSessions() {
  const groups = demoSessionGroups()
  const removedIds = []
  for (const group of groups) {
    for (const id of readdirSync(group)) {
      rmSync(join(group, id), { recursive: true, force: true })
      removedIds.push(id)
    }
    rmSync(group, { recursive: true, force: true })
  }
  // The host's session list is served from a projection cache; an entry left in
  // it still shows up in the app — and therefore in a screenshot — as a phantom
  // row for a session that no longer exists. Only these ids' entries are
  // touched: the directory name of a session *is* its id, so there is no
  // guessing about which cache files belong to the demo.
  for (const id of removedIds) rmSync(join(CACHE_DIR, `${id}.json`), { force: true })
  return removedIds.length
}

// ── main ────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2)
const cleanupAt = argv.indexOf('--cleanup')
if (cleanupAt >= 0) {
  const sessionId = argv[cleanupAt + 1]
  if (!sessionId) throw new Error('--cleanup needs a session id')
  console.log(`removed ${sessionId} (${removeSession(sessionId)} entries)`)
  process.exit(0)
}
if (argv.includes('--cleanup-all')) {
  console.log(`removed ${removeAllDemoSessions()} demo session(s) and the workspace`)
  rmSync(DEMO_DIR, { recursive: true, force: true })
  process.exit(0)
}

/// Writes the demo project to disk, replacing whatever was there.
///
/// The pictures have to match the files, and a half-stale workspace would put
/// yesterday's shape in the README, so the directory is rebuilt from scratch.
function writeDemoProject() {
  rmSync(DEMO_DIR, { recursive: true, force: true })
  for (const [name, body] of Object.entries(FILES)) {
    const target = join(DEMO_DIR, name)
    mkdirSync(dirname(target), { recursive: true })
    writeFileSync(target, body)
  }
}

/// Commits the buggy state, so the fix the demo turn makes is an **uncommitted
/// change** — which is what the app's file screen can show as a diff. Without
/// this the README's third picture would have nothing to show.
function commitBaseline() {
  const git = (...args) => execFileSync('git', args, { cwd: DEMO_DIR, stdio: 'pipe' })
  git('init', '-q')
  git('config', 'user.email', 'demo@example.com')
  git('config', 'user.name', 'DSH demo')
  git('add', '-A')
  git('commit', '-q', '-m', 'feeds: 拉取与筛选')
}

if (argv.includes('--files-only')) {
  writeDemoProject()
  // The failing test is the point of the exercise; show it before seeding.
  try {
    execFileSync('node', ['--test'], { cwd: DEMO_DIR, stdio: 'pipe' })
    console.log('demo project: tests pass — the planted bug is gone, check FILES')
  } catch {
    console.log('demo project: one test fails on purpose (that is the bug the demo turn fixes)')
  }
  console.log(DEMO_DIR)
  process.exit(0)
}

// Fresh workspace every time, so the transcript always matches these files.
writeDemoProject()
commitBaseline()

const { call } = await host()
const created = await call('session/create', { request: { cwd: DEMO_DIR, agentPreset: 'standard' } })
const sessionId = created.sessionId ?? created.id

// 先灌几轮"填充"对话，把转写撑到远超一屏 —— 否则"打开是否停在底部"根本测不出来：
// 内容不足一屏时，停在顶部和停在底部看到的是同一屏。
//
// 填充轮里**不能出现收尾标记**，否则标记会出现在转写中段，"看得见标记"就不再等价于
// "滚到了底"。所以填充轮用一句最简单的指令，标记只留给最后那一轮。
const fillerTurns = Number(process.env.DEMO_FILLER_TURNS ?? 3)
for (let turn = 0; turn < fillerTurns; turn += 1) {
  await call('session/prompt', {
    request: {
      requestId: `demo-filler-${turn}-${Date.now()}`,
      sessionId,
      mode: 'queue',
      clientTimeZone: 'Asia/Shanghai',
      content: [{ type: 'text', text: `第 ${turn + 1} 次填充：只回复「好」，不要调用任何工具。` }],
    },
  })
}

await call('session/prompt', {
  request: {
    requestId: `demo-${Date.now()}`,
    sessionId,
    mode: 'queue',
    clientTimeZone: 'Asia/Shanghai',
    content: [{
      type: 'text',
      text: [
        '这个项目里有两个测试是失败的。请跑一次 `node --test` 找到它们，然后只改 `src/feeds.js` 让测试全绿，',
        '再跑一次确认。改动保持最小，不要顺手重构别的部分，也不要提交。',
        '最后用中文、三句话以内说清根因和修法。这段回答会出现在首页截图里，',
        '所以不要寒暄，也不要复述测试输出。',
        // 末尾必须带一个独一无二的收尾标记：截图用例要判"是否停在最底部"，
        // 而"某句话在屏幕上"这种判据只有在这句话**只可能**出现在结尾时才成立。
        //
        // 这里刻意把标记拆成两段（`ZQ7` 与 `X4P` 直接相连）：
        // 提示词本身就显示在转写第一屏上，如果提示词里出现完整标记，
        // 那么"看得见标记"在停在顶部时也会成立——判据会被自己的提示词骗过（实测踩过两次：
        // 一次是完整标记写在提示词里，一次是"DEMO-END 与 MARKER 相连"这种说法会被模型
        // 只当成 DEMO-END）。
        '整段回答的最后一行只写一个标记：把 `ZQ7` 和 `X4P` 这两段直接拼起来，中间不加任何字符。',
      ].join(''),
    }],
  },
})
console.log(sessionId)
console.error(`seeded ${DEMO_DIR}；等这一轮跑完（约 30–60 秒）再截图；用完：`)
console.error(`  node scripts/dev/demo-session.mjs --cleanup ${sessionId}`)
console.error(`  node scripts/dev/demo-session.mjs --cleanup-all`)

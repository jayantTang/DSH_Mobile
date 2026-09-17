#!/usr/bin/env node
/**
 * Reproduce the read-only DSH captures in this directory.
 *
 *   node docs/samples/capture.mjs [outputDir]
 *
 * Default outputDir is /tmp/dsh-samples-repro so that re-running this script
 * never clobbers the curated (and deliberately truncated) samples committed
 * next to it. Pass `.` to write into this directory instead.
 *
 * READ-ONLY BY CONSTRUCTION: the endpoint list below contains only reads and
 * streams. No mutating method (session/prompt, session/cancel, session/create,
 * session/rename, session/fork, workspace/* mutations, settings/* mutations,
 * credentials/set|unset, directoryPicker/pick|createDirectory) is ever called.
 *
 * Requires the `ws` package bundled with DSH. It is resolved from the DSH
 * installation, never from a hardcoded path: `DSH_INSTALL_DIR` overrides the
 * ladder, otherwise it is derived from the running DSH (`$DSH_HOME`, the `dsh`
 * executable on PATH, or npm's global root). The same ladder lives in the two
 * plugin packages (doubao-image 的 lib 与 mobile-link 的 test) — keep them in step.
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';

const DSH_PACKAGE = '@deepseek-ai/dsh';

/** Anchors to hand to `createRequire`, best first. */
function dshAnchors() {
  const home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
  const exec = (cmd, args) =>
    execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  const isDshPackage = (dir) => {
    try {
      return JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8')).name === DSH_PACKAGE;
    } catch {
      return false;
    }
  };
  let fromExecutable;
  try {
    let dir = path.dirname(fs.realpathSync(exec('which', ['dsh'])));
    for (let depth = 0; depth < 6; depth += 1) {
      if (isDshPackage(dir)) { fromExecutable = path.join(dir, 'package.json'); break; }
      const parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  } catch { /* not on PATH */ }
  let fromNpmRoot;
  try {
    const dir = path.join(exec('npm', ['root', '-g']), ...DSH_PACKAGE.split('/'));
    if (isDshPackage(dir)) fromNpmRoot = path.join(dir, 'package.json');
  } catch { /* no npm */ }
  return [
    process.env.DSH_INSTALL_DIR ? path.join(process.env.DSH_INSTALL_DIR, 'package.json') : undefined,
    import.meta.url,
    path.join(home, 'profiles', 'web', 'package.json'),
    fromExecutable,
    fromNpmRoot,
  ].filter(Boolean);
}

function requireFromDsh(specifier) {
  for (const anchor of dshAnchors()) {
    try {
      return createRequire(anchor)(specifier);
    } catch { /* try the next anchor */ }
  }
  throw new Error(
    `找不到 ${specifier}：DSH 安装目录解析失败（可用 DSH_INSTALL_DIR 指定 DSH 安装位置）`,
  );
}

const wsPkg = requireFromDsh('ws');

const { WebSocket } = wsPkg;

/** Where the running DSH desktop shell publishes its rotating launch token. */
const ENDPOINT_JSON = path.join(
  process.env.HOME ?? '/Users/example',
  '.dsh/desktop-shell/endpoint.json',
);

const OUT = path.resolve(process.argv[2] ?? '/tmp/dsh-samples-repro');
fs.mkdirSync(OUT, { recursive: true });

// ---------------------------------------------------------------------------
// Transport helpers
// ---------------------------------------------------------------------------

function endpoint() {
  return JSON.parse(fs.readFileSync(ENDPOINT_JSON, 'utf8'));
}

/**
 * Exchange the launch token for the authority-bound session cookie.
 * GET /?token=... answers 303 with Set-Cookie; the redirect must NOT be followed.
 */
async function auth() {
  const ep = endpoint();
  const token = new URL(ep.url).searchParams.get('token');
  const base = `http://127.0.0.1:${ep.port}`;
  const res = await fetch(`${base}/?token=${encodeURIComponent(token)}`, { redirect: 'manual' });
  const setCookie = res.headers.get('set-cookie');
  if (!setCookie) throw new Error(`no Set-Cookie on token exchange (status ${res.status})`);
  // Keep only "name=value"; the attributes are not part of the credential.
  const cookie = setCookie.split(';')[0];
  return { base, cookie, version: ep.version, port: ep.port };
}

let rpcSeq = 0;

/**
 * One unary RPC. `payload.args` is an OBJECT of named fields (never an array),
 * and the fields must match the endpoint descriptor exactly.
 */
async function rpc(session, method, args = {}, timeoutMs = 20000) {
  const rpcId = `capture-${Date.now()}-${++rpcSeq}`;
  const body = { type: 'client-request', rpcId, method, payload: { args } };
  const res = await fetch(`${session.base}/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie: session.cookie },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const raw = await res.text();
  // HTTP status is 200 even for business errors; only routing misses return 404.
  if (res.status !== 200) throw new Error(`${method}: HTTP ${res.status} ${raw.slice(0, 120)}`);
  return { json: JSON.parse(raw), rawBytes: Buffer.byteLength(raw, 'utf8') };
}

/** Open one logical stream on the shared WS mux and collect frames for `ms`. */
function stream(session, endpointName, args, ms, maxFrames = 1e9) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${session.base.replace(/^http/, 'ws')}/api/remote.mux`, {
      headers: { cookie: session.cookie },
    });
    const frames = [];
    const errors = [];
    let rawBytes = 0;
    let opened = false;
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      clearInterval(poll);
      try { ws.close(); } catch { /* already closing */ }
      resolve({ frames, errors, opened, rawBytes });
    };
    const timer = setTimeout(finish, ms);
    const poll = maxFrames < 1e9
      ? setInterval(() => { if (frames.length >= maxFrames) finish(); }, 50)
      : null;
    ws.on('open', () => {
      opened = true;
      // Client -> host frame shape.
      ws.send(JSON.stringify({ type: 'open', streamId: 's1', endpoint: endpointName, payload: { args } }));
    });
    ws.on('message', (data) => {
      const text = data.toString();
      rawBytes += Buffer.byteLength(text, 'utf8');
      frames.push(JSON.parse(text));
      if (frames.length >= maxFrames) finish();
    });
    ws.on('error', (e) => errors.push(String((e && e.message) || e)));
    ws.on('close', finish);
  });
}

function dump(name, value) {
  const file = path.join(OUT, `${name}.json`);
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
  console.log(`${name}.json  ${fs.statSync(file).size} bytes`);
}

/** Capture metadata wrapper, matching the curated samples' shape. */
function wrap(meta, value) {
  return { _capture: { ...meta, capturedAt: new Date().toISOString() }, ...value };
}

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

const session = await auth();
console.log(`DSH ${session.version} @ ${session.base}\n`);

/** Unary reads: [output name, method, args]. */
const UNARY = [
  ['session_list', 'session/list', { _request: {} }],
  ['session_modelCatalog', 'session/modelCatalog', {}],
  ['settings_describe', 'settings/describe', {}],
  ['session_canOpenWorkspacePath', 'session/canOpenWorkspacePath', {}],
  ['settings_canOpenAgentPresetDirectory', 'settings/canOpenAgentPresetDirectory', {}],
  ['credentials_describe', 'credentials/describe', { refs: [] }],
];

for (const [name, method, args] of UNARY) {
  const { json, rawBytes } = await rpc(session, method, args);
  dump(name, wrap({ method, args, rawResponseBytes: rawBytes, truncated: false }, json));
}

// Pick real sessions from the list we just captured.
const list = JSON.parse(fs.readFileSync(path.join(OUT, 'session_list.json'), 'utf8')).result.value.items;
const running = list.find((x) => x.running);
const idle = list.find((x) => !x.running);
if (!running || !idle) throw new Error('need at least one running and one idle session');

// Session-scoped reads.
for (const [name, method, args, scope] of [
  ['skills_list', 'skills/list', { request: { sessionId: running.sessionId } }],
  ['session_search', 'session/search', { request: { query: 'dsh' } }],
  ['fileReferences_list', 'fileReferences/list', { agentId: running.sessionId, query: 'src' }],
  ['directoryPicker_list', 'directoryPicker/list', {}],
  ['workspaceFiles_list', 'workspaceFiles/list', { workspaceFileScopeId: running.sessionId, path: '.' }],
  ['workspaceFiles_list_docs', 'workspaceFiles/list', { workspaceFileScopeId: running.sessionId, path: 'docs' }],
]) {
  const { json, rawBytes } = await rpc(session, method, args);
  dump(name, wrap({ method, args, rawResponseBytes: rawBytes, truncated: false }, json));
}

// `session/follow` on an idle session: shows the opening snapshot and the
// record/event envelope. Follow it first so we can reuse its cursor.
let follow = await stream(
  session,
  'session/follow',
  { request: { address: { kind: 'session', sessionId: idle.sessionId }, assistantStream: true } },
  3000,
  4,
);
const snapshot = follow.frames[0]?.value;
dump('session_follow', wrap({
  method: 'session/follow',
  args: { request: { address: { kind: 'session', sessionId: idle.sessionId }, assistantStream: true } },
  rawWebSocketBytes: follow.rawBytes,
  framesReceived: follow.frames.length,
  recordsInSnapshot: snapshot?.records?.length ?? 0,
  truncated: false,
  note: 'Full opening snapshot; nothing was trimmed.',
}, follow));

// `session/page` newest page, cut at the follow snapshot's cursor.
const cursor = snapshot?.cursor;
if (cursor != null) {
  const { json, rawBytes } = await rpc(
    session,
    'session/page',
    { request: { address: { kind: 'session', sessionId: idle.sessionId }, throughSeq: cursor } },
  );
  const records = json.result?.value?.records ?? [];
  const keep = 5;
  const trimmed = records.length > keep * 2
    ? {
        ...json,
        result: {
          ...json.result,
          value: {
            ...json.result.value,
            records: records.slice(0, keep).concat(
              [{ _truncated: true, omittedRecords: records.length - keep * 2 }],
              records.slice(-keep),
            ),
          },
        },
      }
    : json;
  dump('session_page', wrap({
    method: 'session/page',
    args: { request: { address: { kind: 'session', sessionId: idle.sessionId }, throughSeq: cursor } },
    rawResponseBytes: rawBytes,
    recordsReturned: records.length,
    truncated: records.length > keep * 2,
    truncationNote: `records truncated to the first ${keep} and last ${keep}; the full response was ${rawBytes} bytes.`,
  }, trimmed));
}

// `session/follow` on a running session: catches live assistant-stream frames.
let best = null;
for (let attempt = 1; attempt <= 5; attempt++) {
  const r = await stream(
    session,
    'session/follow',
    { request: { address: { kind: 'session', sessionId: running.sessionId }, assistantStream: true } },
    9000,
    25,
  );
  const live = r.frames.filter((f) => f.value?.type === 'assistant-stream').length;
  console.log(`  running-session follow attempt ${attempt}: ${r.frames.length} frames, ${live} live`);
  if (!best || live > best.live) best = { r, live };
  if (live >= 3) break;
}
dump('session_follow_running', wrap({
  method: 'session/follow',
  args: { request: { address: { kind: 'session', sessionId: running.sessionId }, assistantStream: true } },
  rawWebSocketBytes: best.r.rawBytes,
  framesReceived: best.r.frames.length,
  assistantStreamFramesReceived: best.live,
  truncated: false,
}, best.r));

// Host-wide control stream.
dump('session_control', wrap(
  { method: 'session/control', args: {}, truncated: false },
  await stream(session, 'session/control', {}, 2000, 6),
));

// Workspace registry stream.
dump('workspace_follow', wrap(
  { method: 'workspace/follow', args: {}, truncated: false },
  await stream(session, 'workspace/follow', {}, 1500, 6),
));

// Filesystem observation stream for one session's workspace root.
dump('workspaceFiles_changes', wrap(
  { method: 'workspaceFiles/changes', args: { workspaceFileScopeId: idle.sessionId }, truncated: false },
  await stream(session, 'workspaceFiles/changes', { workspaceFileScopeId: idle.sessionId }, 1500, 5),
));

// `$events`: the ready handshake, plus whatever emits the host happens to push.
const events = await stream(session, '$events', {}, 5000, 12);
dump('events_stream', wrap(
  { method: '$events', args: {}, truncated: false, note: 'First item is always the ready frame. Emit frames appear only when host activity occurs.' },
  events,
));

// `$events/result` ack shape. Answering a synthetic eventId for our own live
// client generation is a no-op on the host (the gateway drops unknown ids).
const ready = events.frames.find((f) => f.value?.type === 'ready')?.value;
if (ready) {
  const { json, rawBytes } = await rpc(session, '$events/result', {
    clientId: ready.clientId,
    eventId: '0192f0aa-0000-4000-8000-000000000000',
    outcome: { kind: 'next' },
  });
  dump('events_result_ack', wrap(
    {
      method: '$events/result',
      args: { clientId: ready.clientId, eventId: '<synthetic, matches no pending waterfall>', outcome: { kind: 'next' } },
      rawResponseBytes: rawBytes,
      truncated: false,
      note: 'Success envelope for a void-returning endpoint: the value key is absent.',
    },
    json,
  ));
}

console.log(`\nDone -> ${OUT}`);
process.exit(0);

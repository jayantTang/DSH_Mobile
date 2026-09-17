# Live capture samples

> **这些样本是脱敏后的。** 它们从真实会话抓来，保留的是协议形状（字段名、类型、
> 嵌套、id 之间的互相引用），内容一律不留：中文文本、长文本（命令、目标、正文）、
> 会话/客户端/设备 id、家目录路径、IP 与仿真器 UDID 都已替换成占位符或合成值。
> 重新抓取时请照做——仓库里不留任何会话内容与机器标识。

Raw, unmodified JSON captured from the running DSH host at `http://127.0.0.1:54499`
(desktop shell, DSH `0.1.5-rc.1`) on 2026-09-13. Every file here is a genuine
response/frame sequence, not a hand-written example.

**Read-only only.** No mutating endpoint was called at any point. Another process
was actively using this DSH instance throughout; it was treated as production.

- `../DSH-PROTOCOL.md` — the prose reference these samples illustrate.
- `../dsh-rpc-catalog.json` — the machine-readable endpoint catalog.
- `capture.mjs` — a self-contained script that reproduces every capture below.

---

## Reproducing

### 0. Preconditions

- DSH is running and has written `/Users/<you>/.dsh/desktop-shell/endpoint.json`.
- The `ws` package that ships with DSH is resolvable. `capture.mjs` locates the
  DSH installation by derivation — `DSH_INSTALL_DIR`, then `$DSH_HOME`, then the
  `dsh` executable on `PATH`, then `npm root -g` — so nothing is hardcoded to a
  particular machine.

**Re-read `endpoint.json` before every session** — the launch token rotates on restart.

### 1. Token → cookie (`curl`)

```bash
TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/.dsh/desktop-shell/endpoint.json'))['url'].split('token=')[1])")
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.dsh/desktop-shell/endpoint.json'))['port'])")

# 303 with Set-Cookie. Do NOT follow the redirect; capture only name=value.
curl -s -i -o /dev/null -D - "http://127.0.0.1:$PORT/?token=$TOKEN" \
  | grep -i '^set-cookie:' | sed 's/^[Ss]et-[Cc]ookie: //' | cut -d';' -f1 > /tmp/dsh.cookie

cat /tmp/dsh.cookie   # e.g. dsh-auth-<random>=v1.<payload>.<sig>
```

The cookie is **authority-bound** to `127.0.0.1:$PORT`. Requesting through
`localhost` with the same cookie returns `401 unauthorized`.

### 2. A unary call (`curl`)

```bash
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.dsh/desktop-shell/endpoint.json'))['port'])")

curl -s -X POST "http://127.0.0.1:$PORT/api/session/list" \
  -H "content-type: application/json" \
  -H "cookie: $(cat /tmp/dsh.cookie)" \
  -d '{"type":"client-request","rpcId":"r1","method":"session/list","payload":{"args":{"_request":{}}}}' \
  | python3 -m json.tool
```

Notes: `payload.args` is an **object of named fields**; `session/list`'s field is
literally `_request` (with the leading underscore). Business errors still come
back with HTTP 200 — inspect `result.ok`.

Discovering an endpoint's exact signature empirically:

```bash
curl -s -X POST "http://127.0.0.1:$PORT/api/session/page" \
  -H "content-type: application/json" -H "cookie: $(cat /tmp/dsh.cookie)" \
  -d '{"type":"client-request","rpcId":"r2","method":"session/page","payload":{"args":{"__probe__":1}}}'
# → gateway/arguments-invalid ... missing "request"; unexpected "__probe__"
```

### 3. A stream (Node + bundled `ws`)

```js
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';

// Resolve DSH's own copy of `ws` (see capture.mjs for the full anchor ladder).
const dshRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim()
  + '/@deepseek-ai/dsh';
const wsPkg = createRequire(dshRoot + '/package.json')('ws');
const ws = new wsPkg.WebSocket('ws://127.0.0.1:54499/api/remote.mux',
  { headers: { cookie: process.env.DSH_COOKIE } });
ws.on('open', () => ws.send(JSON.stringify({
  type: 'open', streamId: 's1', endpoint: 'session/follow',
  payload: { args: { request: { address: { kind: 'session', sessionId: '<id>' }, assistantStream: true } } },
})));
ws.on('message', (d) => console.log(d.toString()));
```

### 4. Everything at once

```bash
node docs/samples/capture.mjs /tmp/dsh-samples-repro
```

Defaults to writing into `/tmp/dsh-samples-repro` so it never overwrites the
curated (and partly truncated) samples in this directory. Pass `.` to write here.

---

## Inventory

`raw bytes` is the size of the compact wire payload as received (before
pretty-printing). Files marked **truncated** carry an inline `_capture` block
that states exactly what was trimmed and the full byte size.

### Reads

| File | Method | `payload.args` | Raw bytes | Notes |
|---|---|---|---|---|
| `session_list.json` | `session/list` | `{"_request":{}}` | 62 492 | Full. 26 `items`; each has `sessionId`, `updatedAt`, `running`, `blank`, `cwd`, `projections:{asOfSeq,values}`. No pagination cursor is returned. |
| `session_page.json` | `session/page` | `{"request":{"address":{"kind":"session","sessionId":"<id>"},"throughSeq":"<cursor from session/follow snapshot>"}}` | 680 480 | **Truncated.** Paged history for one session: `{records, hasMore}`, where a record is one transcript entry (not a session summary). Keeps the first 3 and last 3 records with an inline marker; `hasMore: true` here. |
| `session_modelCatalog.json` | `session/modelCatalog` | `{}` | 2 354 | Full. `default`, `routableProviders`, `groups`, `failures`. |
| `settings_describe.json` | `settings/describe` | `{}` | 23 255 | Full. `writable`, `hasDocument`, and one redacted `SettingsNamespaceView` per namespace (schema JSON, redacted value/base/user, secrets slots, `revision`). |
| `skills_list.json` | `skills/list` | `{"request":{"sessionId":"<running>"}}` | 101 | Full. `{skills:[…]}`. |
| `credentials_describe.json` | `credentials/describe` | `{"refs":[]}` | 90 | Full. Empty `refs` → `{}`. |
| `session_canOpenWorkspacePath.json` | `session/canOpenWorkspacePath` | `{}` | 92 | Full. `true` on this host. |
| `settings_canOpenAgentPresetDirectory.json` | `settings/canOpenAgentPresetDirectory` | `{}` | 92 | Full. |
| `fileReferences_list.json` | `fileReferences/list` | `{"agentId":"<running>","query":"src"}` | 1 343 | Full. `FileReferenceCandidate[]`. |
| `directoryPicker_list.json` | `directoryPicker/list` | `{}` | 262 | **Error capture**: `directory-picker/unavailable`, `details.capability = "native"`. This deployment uses the native picker, so the browse verbs are refused. |
| `session_search.json` | `session/search` | `{"request":{"query":"dsh"}}` | 284 | **Error capture**: the session-query index is configured `openAt: "never"`, so search is disabled here. |
| `workspaceFiles_list.json` | `workspaceFiles/list` | `{"workspaceFileScopeId":"<running>","path":"."}` | 966 | Workspace-relative `path`; result `path` is `""` for the root. |
| `workspaceFiles_list_abs.json` | `workspaceFiles/list` | `{"workspaceFileScopeId":"<running>","path":"docs"}` | 574 | A subdirectory listing. |
| `workspaceFiles_stat.json` | `workspaceFiles/stat` | `{"workspaceFileScopeId":"<running>","path":"<absolute>"}` | 248 | Absolute path. `{absolutePath, version, bytes}`. |
| `workspaceFiles_read.json` | `workspaceFiles/read` | `{…,"path":"<absolute>","range":{"offset":1,"limit":5}}` | 543 | Line window; extends `WorkspaceFileStat` with `offset`, `text`, `lines`, `eof`. |
| `workspaceFiles_readAll.json` | `workspaceFiles/readAll` | `{…,"path":"<absolute>"}` | 27 568 | Whole file. `data` is base64; `bytes` is the complete file size. |
| `workspaceFiles_readBytes.json` | `workspaceFiles/readBytes` | `{…,"range":{"offset":0,"length":32}}` | 325 | Byte window. |

### Streams

| File | Endpoint | `payload.args` | Raw WS bytes | Notes |
|---|---|---|---|---|
| `session_follow.json` | `session/follow` | `{"request":{"address":{"kind":"session","sessionId":"<idle>"},"assistantStream":true}}` | 685 961 | **truncated.** Opening `snapshot` frame only. The snapshot held 279 records; the file keeps the first 4 and last 2 with an inline marker. Shows `header`, `cursor`, `hasMore`, `projections`, `assistantStream`, and the `{type:'event',event:{type,seq,time,data}}` envelope. |
| `session_follow_running.json` | `session/follow` | same, for a **running** session | 1 101 971 | **truncated.** Opening snapshot (first 3 records) plus the first 5 of 22 live `{type:'assistant-stream'}` frames — real `start` and `chunk` frames (`block-start`, `reasoning-delta`). |
| `session_control.json` | `session/control` | `{}` | 53 896 | Full. Starts with exactly one `baseline` (`queues`, `jobs`, `projections` for every live session). |
| `workspace_follow.json` | `workspace/follow` | `{}` | 1 949 | Full. Starts with exactly one `baseline`. |
| `workspaceFiles_changes.json` | `workspaceFiles/changes` | `{"workspaceFileScopeId":"<idle>"}` | 56 | Full. `{"kind":"ready"}` — nothing in this workspace changed during the 1.5 s window. |
| `events_stream.json` | `$events` | `{}` | ~1 430 | Full. The `ready` handshake plus three real `emit` frames (`api-session/status`, `api-session/activity`) captured from another session's activity. |
| `events_stream_waterfall.json` | `$events` | `{}` | ~3 771 | Full. The `ready` handshake plus a **real `waterfall` frame** (`user-questions/request`). This is the frame shape that requires a `$events/result` answer keyed by the same `clientId` + `eventId`. |
| `events_result_ack.json` | `$events/result` | `{"clientId":"<live>","eventId":"<synthetic>","outcome":{"kind":"next"}}` | ~70 | Full. The success envelope for a void endpoint: `{"result":{"ok":true}}` — no `value` key. The synthetic `eventId` matched no pending waterfall, which the gateway treats as a no-op. |

### What is *not* here, and why

No sample exists for any mutating endpoint, for `directoryPicker/pick`
(opens a modal OS dialog on the host), for `settings/openSettingsDocument` /
`openAgentPresetDirectory` (host UI), or for a *successful* `approval/request`
answer (answering a real approval would inject a decision into another
session's flow). Their request/response types are still fully specified in
`../DSH-PROTOCOL.md` Section 3 and `../dsh-rpc-catalog.json`.

`session/follow` captures are timing-dependent: only a session that is actively
streaming produces `assistant-stream` frames, so `session_follow_running.json`
may not reproduce on a quiet host.

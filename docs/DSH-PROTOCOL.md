# DSH Client Protocol Reference

> 面向：实现者 · 状态：stable（随 DSH 上游变动） · 最近核对：2026-09-20

Authoritative, implementation-oriented reference for the **DeepSeek Harness (DSH) browser/client Remote API**, sufficient to build a native client (iOS) against a running DSH host **without access to the DSH source**.

| | |
|---|---|
| **DSH version** | `0.1.5-rc.1` |
| **Generated at** | `2026-09-13T05:51:44.713Z` |
| **Probed server** | `http://127.0.0.1:54499` (pid 43814, desktop shell) |
| **Endpoints catalogued** | **47** (42 unary, 5 stream) |
| **Method** | Host FaceModels (`typert.host.js` `TYPERT.invocations`) cross-checked against the live server with the descriptor-validation probe, plus verbatim `.d.ts` extraction and live captures in `docs/artifacts/samples/`. |

> **Provenance rules used throughout.** Every argument name in Section 2 was confirmed **empirically** against the live server, not read from source alone. Every type in Section 3 is copied **verbatim** from the installed `.d.ts` files. Where the two disagree, or where a feature is absent from this deployment, it is called out explicitly in Section 7.

---

## 1. Transport and authentication

### 1.1 Discovery

A running DSH desktop shell writes a JSON endpoint file:

```jsonc
// /Users/<user>/.dsh/desktop-shell/endpoint.json
{
  "url": "http://127.0.0.1:54499/?token=<launch-token>",
  "port": 54499,
  "pid": 43814,
  "version": "0.1.5-rc.1",
  "desktopShell": true,
  "updatedAt": "2026-09-12T09:06:58.959Z"
}
```

- The **base URL** is `http://127.0.0.1:<port>`.
- The **launch token** is the `token` query parameter of `url`.
- **The token rotates every time DSH restarts.** Re-read this file before *every* capture/connection session; never cache it across restarts. `updatedAt` changes when it is rewritten.

### 1.2 The token → cookie exchange

```
GET http://127.0.0.1:<port>/?token=<launch-token>
```

The server answers **HTTP 303 See Other** with:

```
cache-control: no-store
location: /
referrer-policy: no-referrer
set-cookie: dsh-auth-<32 random chars>=v1.<payload>.<sig>; Max-Age=2592000; Path=/; Expires=<+30d>; HttpOnly; SameSite=Strict
```

Rules that matter:

1. **Do not follow the redirect.** It points at `/` and serves the SPA, which is useless to a native client. Use a manual/`no-redirect` HTTP mode and read `Set-Cookie` off the 303.
2. Capture **only the `name=value` prefix** of `Set-Cookie` (drop attributes) for later use.
3. The cookie name is **random per issuance** (`dsh-auth-<opaque>` in one capture). Do not hardcode a name; parse it.
4. Cookie lifetime is **30 days** (`Max-Age=2592000`) by default.
5. Send it back on every subsequent request as `Cookie: <name>=<value>` (HTTP) or as an explicit `Cookie` header on the WebSocket upgrade.

The `v1.<payload>.<sig>` value is a signed envelope whose payload contains the **authority** it was minted for:

```json
{"version":1,"authority":"127.0.0.1:54499","issuedAt":1789277959975,"expiresAt":1791869959975}
```

### 1.3 Authority binding (cookie is authority-bound)

The cookie is valid **only** for the exact `host:port` it was minted for. Concretely, all of the following were verified live:

| Request | Result |
|---|---|
| `POST http://127.0.0.1:54499/api/...` + cookie | **200** |
| `POST http://localhost:54499/api/...` + same cookie | **401 `unauthorized`** |
| `POST .../api/...` with **no** cookie | **401 `unauthorized`** |
| `POST .../api/...` with a tampered cookie | **401 `unauthorized`** |
| `POST .../api/...` + cookie + `Origin: http://evil.example` | **403 `forbidden`** |
| `POST .../api/...` + cookie, no `Origin` | **200** |
| `WS ws://127.0.0.1:54499/api/remote.mux` with no cookie | upgrade rejected **401** |

So:

- Always address the host by the **literal authority from `endpoint.json`** (`127.0.0.1:<port>`). `localhost`, `[::1]`, or a LAN IP alias will fail authentication even though it resolves to the same server.
- `Origin` is only enforced **when present**; a native client that sends no `Origin` is accepted.

### 1.4 The `/api` trust fence and `--trusted-host`

The `/api` channel has a Host/trust fence: it refuses any request whose `Host` is neither loopback nor an explicitly declared trusted authority. A non-loopback deployment (`--host 0.0.0.0`) must declare the names it is reached by:

```
dsh --profile web --host 0.0.0.0 --port 54499 --trusted-host 192.0.2.1.20 --trusted-host my-mac.local
```

`--trusted-host <authority...>` (repeatable) adds an extra authority the fence accepts — either a bare `host` (any port) or an exact `host:port`. This is the same value as the `trustedHosts` config of the `client-connection` plugin. **A native client on another device must connect through a trusted authority, and the authority-bound cookie must have been minted through that same authority.**

### 1.5 Unary RPC

```
POST http://127.0.0.1:<port>/api/<method>
Content-Type: application/json
Cookie: <cookie>

{
  "type": "client-request",
  "rpcId": "<any unique string>",
  "method": "<method>",
  "payload": { "args": { "<field>": <value>, ... } }
}
```

Response (always HTTP **200** for a well-formed envelope, even when the business call failed):

```json
{
  "type": "server-response",
  "rpcId": "<the same rpcId>",
  "result": { "ok": true, "value": <method-specific value> }
}
```

or

```json
{
  "type": "server-response",
  "rpcId": "<the same rpcId>",
  "result": {
    "ok": false,
    "error": { "code": "<stable code>", "message": "<human text>", "details": { } }
  }
}
```

Key facts:

- **`payload.args` is an OBJECT of named fields, never a positional array.** This is the single most common integration mistake. The field names are exactly those in Section 2 (`request`, `_request`, `workspaceFileScopeId`, `refs`, `ns`, …).
- **`rpcId` is echoed verbatim** and is the only correlation mechanism. Any unique string works.
- **`type`, `rpcId`, `method`, `payload` are all required.** A malformed envelope is *not* rejected with a 4xx; it returns HTTP 200 with `rpcId: "invalid-request"` and:
  ```json
  {"type":"server-response","rpcId":"invalid-request","result":{"ok":false,
   "error":{"code":"gateway/bad-request","message":"invalid client-request message",
   "details":{"issues":[{"code":"invalid_value","values":["client-request"],"path":["type"],"message":"Invalid input: expected \"client-request\""}, ...]}}}}
  ```
- **An unknown method is HTTP 404 with body `not found`** — plain text, not a JSON envelope. Note this is a *transport* miss: the route is not registered.
- `POST` is the only accepted verb on `/api/<method>`; a `GET` returns 404.
- Success `value` may be absent entirely when the method returns `void` (e.g. `$events/result` answers `{"result":{"ok":true}}`).

### 1.6 Error codes

Codes seen live on the wire:

| Code | Meaning |
|---|---|
| `gateway/arguments-invalid` | `payload.args` fields do not match the endpoint descriptor (missing/unexpected). |
| `gateway/input-invalid` | A field was present but failed boundary validation (`details.field` names it). |
| `gateway/bad-request` | Malformed envelope, or endpoint-specific request rejection. |
| `gateway/internal` | Endpoint-specific internal failure (e.g. session search disabled). |
| `gateway/method-unavailable`, `gateway/lookup-not-found`, `gateway/service-unavailable`, `gateway/result-invalid`, `gateway/signature-invalid`, `gateway/context-*`, `gateway/definition-unavailable`, `gateway/invocation-unavailable`, `gateway/binding-invalid`, `gateway/ambiguous-endpoint`, `gateway/lookup-failed`, `gateway/lookup-unavailable`, `gateway/provider-mismatch` | Full `TypertGatewayErrorCode` union (Section 3.1). |
| `session/not-found` | The addressed Session does not exist. |
| `session/model-unavailable`, `session/conflict`, `session/agent-busy`, `session/invalid-time-zone`, `session/workspace-attach-failed`, `session/attachment-invalid`, `session/queue-item-not-found`, `session/steer-unavailable`, `session/title-invalid`, `session/fork-unavailable`, `agent-preset/conflict` | Session-controller business refusals. |
| `workspace/invalid-path`, `workspace/name-conflict`, `workspace/move-invalid` | Workspace business refusals. |
| `directory-picker/unavailable`, `directory-picker/unreadable`, `directory-picker/exists`, `directory-picker/create-failed` | Directory-picker refusals. |
| `settings/rejected`, `settings/conflict`, `credential/rejected` | Settings/credentials refusals. |
| `workspace-file/not-found`, `workspace-file/outside-workspace`, `workspace-file/too-large`, `workspace-file/not-text`, `workspace-file/not-regular-file`, `workspace-file/not-directory` | workspaceFiles refusals. |

### 1.7 Streaming over the WebSocket mux

All streams — including `$events` — share **one** WebSocket route:

```
ws://127.0.0.1:<port>/api/remote.mux
Cookie: <cookie>
```

Client → host frames (JSON text):

```json
{ "type": "open",   "streamId": "<your id>", "endpoint": "<method>", "payload": { "args": { } } }
{ "type": "cancel", "streamId": "<your id>" }
```

Host → client frames (JSON text):

```json
{ "type": "item",  "streamId": "<your id>", "value": <one stream value> }
{ "type": "error", "streamId": "<your id>", "error": { "code": "...", "message": "...", "details": { } } }
{ "type": "end",   "streamId": "<your id>" }
```

Notes:

- Many logical streams can be multiplexed on one socket; `streamId` is yours to choose and is echoed back.
- A stream that cannot be opened (bad args, unknown session) produces an **`error` frame**, not an HTTP error: e.g. `{"type":"error","streamId":"s1","error":{"code":"gateway/arguments-invalid","message":"typert gateway: session/follow: args fields do not match the descriptor: missing \"request\"; unexpected \"__probe__\"","details":{"endpoint":"session/follow"}}}`.
- Sending `cancel` (or closing the socket) ends the generation. There is no per-stream acknowledgement.
- `streamId` values must be strings and are not validated for uniqueness by the client SDK, but reuse across concurrent streams is obviously wrong.

### 1.8 The `$events` stream: handshake, emit, waterfall, ack

`$events` is a **gateway-internal** endpoint (not part of any package's FaceModel). It is the only channel over which the host pushes *application* events to a client.

**Open it with an empty args object** — non-empty args are rejected:

```json
{ "type": "open", "streamId": "ev", "endpoint": "$events", "payload": { "args": {} } }
```

The **first item is always the ready frame**, which binds your client generation:

```json
{ "type": "item", "streamId": "ev",
  "value": { "type": "ready", "clientId": "id-00000000-0000-4000-8000-000000000001", "host": { "home": "/Users/example" } } }
```

After that, the host delivers two kinds of downlink frames:

**(a) `emit` — a notification. No answer.** The `args` array is the Cordis listener argument list, positionally:

```json
{ "type": "item", "streamId": "ev",
  "value": { "type": "emit", "event": "api-session/status", "args": ["session-7a20fc5d-…", false] } }
{ "type": "item", "streamId": "ev",
  "value": { "type": "emit", "event": "api-session/activity", "args": ["session-7a20fc5d-…", 1789278565895] } }
```

Both of the above were captured live (see `docs/artifacts/samples/events_stream.json`).

**(b) `waterfall` — a pending host-to-client question. You MUST answer it**, otherwise the host-side operation that raised it stays blocked until its own timeout:

```json
{ "type": "item", "streamId": "ev",
  "value": { "type": "waterfall", "event": "user-questions/request",
             "eventId": "<RemoteEventId>", "agentId": "<RemoteEventAgentId>",
             "request": { } } }
```

The host may also **cancel** a pending waterfall it no longer needs:

```json
{ "type": "item", "streamId": "ev", "value": { "type": "cancel", "eventId": "<RemoteEventId>" } }
```

**Answering a waterfall** is a *unary* RPC to `$events/result` whose args are the three named fields:

```
POST /api/$events/result
{ "type": "client-request", "rpcId": "…", "method": "$events/result",
  "payload": { "args": { "clientId": "<the clientId from the ready frame>",
                         "eventId":  "<the eventId from the waterfall frame>",
                         "outcome":  { "kind": "result", "value": <answer> } } } }
```

`outcome` is exactly one of:

```json
{ "kind": "next" }                                  // delegate back to the host chain
{ "kind": "result" }                                // claim with no value
{ "kind": "result", "value": <lossless-JSON value> } // claim with an answer
{ "kind": "rejected", "error": { "name": "...", "message": "...", "code": "...", "details": ... } }
```

A successful ack is `{"type":"server-response","rpcId":"…","result":{"ok":true}}` — **no `value` key** (the value is `undefined` and JSON drops it). Verified live and saved as `docs/artifacts/samples/events_result_ack.json`.

Live captures of all three frame kinds are in `docs/artifacts/samples/`: `events_stream.json` (ready + real `emit` frames) and `events_stream_waterfall.json` (ready + a real `user-questions/request` waterfall).

Important details:

- `$events/result` args are **not** descriptor-validated. A malformed payload yields `gateway/internal` / `"api gateway: invalid Remote event result"`; a well-formed payload naming no active generation yields `"typert gateway: Remote event result identifies no active event stream"`.
- `$events/result` does **not** exist as an HTTP route for streams: `POST /api/$events` returns 404. `$events` is reachable only through the WS mux.
- Only **two** waterfalls exist in this build: `approval/request` and `user-questions/request` (Section 4.2).
- The `ready` frame's `clientId` is per-connection-generation. If the socket drops and you reopen `$events`, you get a **new** `clientId`; answers must use the current one.
- Pending waterfalls raised while you were disconnected are replayed to a new generation.

### 1.9 Descriptor self-documentation (how Section 2 was verified)

Posting an endpoint with a deliberately wrong args object returns an error that names the **exact** expected fields:

```
POST /api/session/page   {"args": {"__probe__": 1}}
→ gateway/arguments-invalid
  "typert gateway: session/page: args fields do not match the descriptor: missing \"request\"; unexpected \"__probe__\""
```

Rules the validator enforces:

- **Unexpected fields are rejected**, not ignored. `payload.args` must match the descriptor key-for-key.
- Only **required** fields appear in the `missing "…"` list. Optional fields (e.g. `expectedRevision`, `directoryPicker/list`'s `path`) are silently omittable — they are listed as optional in `dsh-rpc-catalog.json` and marked in Section 2 where relevant.
- A no-argument endpoint accepts `"args": {}` and rejects anything else with only an `unexpected` clause.
- Streams validate identically, but report the failure as a WS `error` frame.

---

## 2. Endpoint catalog

**47 endpoints** (42 unary, 5 stream). `args` is the exact set of wire field names accepted in `payload.args`; a field marked **?** is optional on the wire, and `—` means the endpoint takes no arguments and requires `"args": {}`. Request/response columns give the TypeScript type name defined verbatim in Section 3.

| Method | Kind | `payload.args` fields | Request type | Response type | Semantics |
|---|---|---|---|---|---|
| `$events` | stream | — | — | `RemoteEventDownlinkFrame` | Gateway-internal forwarded-event stream. First item is always {"type":"ready","clientId","host"}; then emit and waterfall frames. The payload must be exactly {"args":{}}. |
| `$events/result` | unary | `clientId`, `eventId`, `outcome` | `RemoteEventResult` | `void (result.value is undefined, so the wire envelope is {"result":{"ok":true}} with no value key)` | Answer one delivered waterfall event. outcome is {kind:"next"} \| {kind:"result",value?} \| {kind:"rejected",error:RemoteEventRejection}. |
| `credentials/describe` | unary | `refs` | — | `Record<string, CredentialInfo>` | Describe several credential references (configured/source/writable) without revealing values. |
| `credentials/set` | unary | `ref`, `value` | — | `void` | Store one credential value under a reference (write-only; no read path returns it). |
| `credentials/unset` | unary | `ref` | — | `void` | Remove one credential reference. |
| `directoryPicker/createDirectory` | unary | `path`, `name` | — | `string` | Create one child directory from an in-app browser. |
| `directoryPicker/list` | unary | `path` **?** | — | `DirectoryListing` | List one directory level plus ancestry for an in-app browser (needs the browse backend; unavailable in this deployment). |
| `directoryPicker/pick` | unary | — | — | `string \| null` | Open the Host OS directory chooser and return the chosen absolute path (or null when cancelled). |
| `fileReferences/list` | unary | `agentId`, `query` | — | `FileReferenceCandidate[]` | Complete path-only file reference candidates inside an Agent/session cwd for a query prefix. |
| `session/attachment` | unary | `request` | `SessionAttachmentRequest` | `SessionAttachmentValue` | Read one durable image attachment's metadata and base64 bytes. |
| `session/cancel` | unary | `request` | `SessionCancelRequest` | `SessionCancelValue` | Request cancellation of the addressed Session's active turn. |
| `session/canOpenWorkspacePath` | unary | — | — | `boolean` | Whether the Host can hand a workspace path to a native opener. |
| `session/control` | stream | — | — | `SessionControlFrame` | Stream Host-wide live state: one baseline of queues/jobs/projections, then queue, jobs, and projection updates. |
| `session/create` | unary | `request` | `SessionCreateRequest` | `SessionCreateValue` | Create a Session (optionally with an explicit id, cwd, workspace, and agent preset). |
| `session/follow` | stream | `request` | `SessionFollowRequest` | `SessionFollowFrame` | Stream one Session generation: opening snapshot, then ordered durable events and (if opted in) live assistant stream frames. |
| `session/fork` | unary | `request` | `SessionForkRequest` | `SessionForkValue` | Fork a Session at an optional seq, returning the new Session id. |
| `session/list` | unary | `_request` | `SessionListRequest` | `SessionListValue` | List Sessions known to the Host, newest-activity first, each with cached projections (title, goal, todos, ...). |
| `session/modelCatalog` | unary | — | — | `ModelCatalog` | Return the Host model catalog: default selection, routable providers, provider groups, and failures. |
| `session/openWorkspacePath` | unary | `request` | `SessionOpenWorkspacePathRequest` | `SessionOpenWorkspacePathValue` | Ask the Host desktop to open or reveal one workspace path. |
| `session/page` | unary | `request` | `SessionPageRequest` | `SessionPage` | Read one message-aligned backwards page of a Session log at or below an inclusive seq cut. |
| `session/prompt` | unary | `request` | `SessionPromptRequest` | `SessionPromptValue` | Submit user content into a Session inbox, either queued for the next turn or as a steering message. |
| `session/rename` | unary | `request` | `SessionRenameRequest` | `SessionRenameValue` | Set a Session title; returns the normalized title and the committing seq. |
| `session/search` | unary | `request` | `SessionSearchRequest` | `SessionSearchValue` | Full-text search across session content (needs the session-query index; disabled in this deployment). |
| `session/selectModel` | unary | `request` | `SessionSelectModelRequest` | `SessionSelectModelValue` | Persist the model selection (provider/model/reasoningEffort) for subsequent requests. |
| `session/updateQueue` | unary | `request` | `SessionUpdateQueueRequest` | `SessionUpdateQueueValue` | Edit, remove, or steer one still-pending queue item. |
| `settings/canOpenAgentPresetDirectory` | unary | — | — | `boolean` | Whether the Host can open a local Agent preset directory. |
| `settings/describe` | unary | — | — | `SettingsDescribeValue` | Read every registered settings namespace as a redacted view with its revision. |
| `settings/mutate` | unary | `ns`, `ops`, `expectedRevision` **?** | — | `SettingsNamespaceView` | Apply path-addressed set/unset operations to one settings namespace, guarded by expectedRevision. |
| `settings/openAgentPresetDirectory` | unary | `agentPreset` | — | `AgentPresetDirectoryOpenValue` | Open or reveal a locally authored Agent preset directory. |
| `settings/openSettingsDocument` | unary | — | — | `SettingsDocumentOpenValue` | Hand the settings document to the Host's native editor. |
| `settings/replace` | unary | `ns`, `section`, `expectedRevision` **?** | — | `SettingsNamespaceView` | Replace one settings namespace section wholesale, guarded by expectedRevision. |
| `settings/update` | unary | `ns`, `patch`, `expectedRevision` **?** | — | `SettingsNamespaceView` | Merge a shallow patch into one settings namespace section, guarded by expectedRevision. |
| `skills/list` | unary | `request` | `SkillListRequest` | `SkillListValue` | List human-invocable skills available to one Session. |
| `workspace/archiveSession` | unary | `request` | `WorkspaceArchiveSessionRequest` | `WorkspaceArchiveValue` | Archive a Session out of Workspace grouping surfaces. |
| `workspace/create` | unary | `request` | `WorkspaceCreateRequest` | `WorkspaceCreateValue` | Register an existing directory as a Workspace. |
| `workspace/delete` | unary | `request` | `WorkspaceDeleteRequest` | `WorkspaceDeleteValue` | Delete a Workspace registration. |
| `workspace/follow` | stream | — | — | `WorkspaceFollowFrame` | Stream Workspace state: one baseline, then upsert/remove/order/archived increments. |
| `workspace/insertBefore` | unary | `request` | `WorkspaceInsertBeforeRequest` | `WorkspaceOrderValue` | Reorder the Workspace registry (DOM insertBefore semantics). |
| `workspace/insertSessionBefore` | unary | `request` | `WorkspaceInsertSessionBeforeRequest` | `WorkspaceValue` | Reorder a Session inside a Workspace's manual order. |
| `workspace/rename` | unary | `request` | `WorkspaceRenameRequest` | `WorkspaceValue` | Rename a Workspace title. |
| `workspaceFiles/changes` | stream | `workspaceFileScopeId` | — | `WorkspaceFileWatchFrame` | Stream filesystem observations inside a Session workspace root: ready, then change frames. |
| `workspaceFiles/list` | unary | `workspaceFileScopeId`, `path` | — | `WorkspaceDirectoryListing` | List direct children of one workspace-relative directory. |
| `workspaceFiles/read` | unary | `workspaceFileScopeId`, `path`, `range` | — | `WorkspaceFileText` | Read a line window of a text file by absolute path. |
| `workspaceFiles/readAll` | unary | `workspaceFileScopeId`, `path` | — | `WorkspaceFileBytes` | Read an entire file's bytes (base64) by absolute path. |
| `workspaceFiles/readBytes` | unary | `workspaceFileScopeId`, `path`, `range` | — | `WorkspaceFileBytes` | Read a byte window of a file by absolute path. |
| `workspaceFiles/readRelated` | unary | `workspaceFileScopeId`, `path`, `relativePath` | — | `WorkspaceFileBytes` | Read a path resolved relative to another file's directory. |
| `workspaceFiles/stat` | unary | `workspaceFileScopeId`, `path` | — | `WorkspaceFileStat` | Stat one file by absolute path (absolutePath, version, bytes). |

### 2.1 Endpoints that mutate or are dangerous

The following are catalogued for completeness but must not be called unless you intend the side effect. Everything else in the table is read-only (streams are read-only).

`session/prompt`, `session/cancel`, `session/create`, `session/rename`, `session/fork`, `session/selectModel`, `session/updateQueue`, `session/openWorkspacePath`, `workspace/create|rename|delete|insertBefore|insertSessionBefore|archiveSession`, `directoryPicker/createDirectory`, `directoryPicker/pick` (opens a native OS dialog), `settings/update|replace|mutate|openSettingsDocument|openAgentPresetDirectory`, `credentials/set|unset`.

Borderline cases that are formally reads but have side effects a client should not trigger casually: `directoryPicker/pick` (opens a modal OS dialog on the host, listed above), and `session/attachment` (read-only, but only meaningful with a real durable attachment id obtained from a session event).

---

## 3. Verbatim TypeScript definitions

Copied byte-for-byte from the installed `.d.ts` files; leading JSDoc is preserved. Only declarations relevant to building a chat client are included (the full set of package exports is larger).

### 3.1 Transport envelopes

```ts
// dsh-client-connection/lib/types/rpc.d.ts

/** Correlation id minted by a caller and echoed by the Connection response. */
export type RpcId = Branded<'rpc-id'>;

/** Carrier-neutral failure returned by one logical RPC endpoint. */
export interface ConnectionRpcFailure {
    readonly code: string;
    readonly message: string;
    readonly details: object;
}

/** Carrier-neutral result returned by one logical RPC endpoint. */
export type ConnectionRpcResult<T> = {
    readonly ok: true;
    readonly value: T;
} | {
    readonly ok: false;
    readonly error: ConnectionRpcFailure;
};

/** Historical short name for a generic Connection result. */
export type RpcResult<T> = ConnectionRpcResult<T>;

/** Full request envelope carried by Connection RPC transports. */
export interface ClientRequest {
    readonly type: 'client-request';
    readonly rpcId: RpcId;
    readonly method: string;
    readonly payload: unknown;
}

/** Full response envelope carried by Connection RPC transports. */
export interface ServerResponse {
    readonly type: 'server-response';
    readonly rpcId: RpcId;
    readonly result: ConnectionRpcResult<unknown>;
}

/** Complete Connection RPC envelope union. */
export type RpcMessage = ClientRequest | ServerResponse;
```

```ts
// dsh-api-gateway/lib/types/stream-protocol.d.ts

/** Exact WebSocket route carrying every Typert Remote stream. */
export declare const REMOTE_STREAM_MUX_PATH = "/api/remote.mux";

/** Gateway-internal logical stream carrying application-selected Cordis events. */
export declare const REMOTE_EVENT_STREAM_ENDPOINT = "$events";

/** Gateway-internal unary endpoint returning one Client Remote Event outcome. */
export declare const REMOTE_EVENT_RESULT_ENDPOINT = "$events/result";

/** Empty standard Remote payload used to open the forwarded-event stream. */
export declare const REMOTE_EVENT_STREAM_PAYLOAD: {
    readonly args: {};
};

/** Opaque identity for one active Client Remote Event generation. */
export type RemoteEventClientId = Branded<'RemoteEventClientId'>;

/** Opaque correlation id for one pending Host-to-Client Remote Event. */
export type RemoteEventId = Branded<'RemoteEventId'>;

/** Stable Host facts published with every established Client event generation. */
export interface RemoteEventHostInfo {
    /** Host account home used only to abbreviate displayed filesystem paths. */
    readonly home: string;
}

/** Opening item that binds later HTTP results to this active event stream. */
export interface RemoteEventReadyFrame {
    readonly type: 'ready';
    readonly clientId: RemoteEventClientId;
    /** Stable Host facts attached to this connection generation. */
    readonly host: RemoteEventHostInfo;
}

/** Opaque Agent identity carried by one scoped Remote Event. */
export type RemoteEventAgentId = Branded<'RemoteEventAgentId'>;

/** One Host notification delivered to a Client generation. */
export interface RemoteEventEmitFrame {
    readonly type: 'emit';
    readonly event: string;
    readonly args: readonly unknown[];
}

/** One pending Agent-scoped waterfall delivered to a Client generation. */
export interface RemoteEventInvocationFrame {
    readonly type: 'waterfall';
    readonly event: string;
    readonly eventId: RemoteEventId;
    readonly agentId: RemoteEventAgentId;
    readonly request: Readonly<Record<string, unknown>>;
}

/** Cancellation of a pending waterfall previously delivered under the same id. */
export interface RemoteEventCancellationFrame {
    readonly type: 'cancel';
    readonly eventId: RemoteEventId;
}

/** Every item carried by the Gateway-internal forwarded-event stream. */
export type RemoteEventDownlinkFrame = RemoteEventReadyFrame | RemoteEventEmitFrame | RemoteEventInvocationFrame | RemoteEventCancellationFrame;

/** JSON request fields plus the Host cancellation lifetime removed for transport. */
export interface ProjectedRemoteEventRequest {
    readonly request: Readonly<Record<string, unknown>>;
    readonly signal?: AbortSignal;
}

/** Error fields retained when a Client listener rejects a Host waterfall. */
export interface RemoteEventRejection {
    readonly name: string;
    readonly message: string;
    readonly code?: string;
    readonly details?: unknown;
}

/** Client response to one scoped Remote Event delivery. */
export interface RemoteEventResult {
    readonly clientId: RemoteEventClientId;
    readonly eventId: RemoteEventId;
    readonly outcome: {
        readonly kind: 'next';
    } | {
        readonly kind: 'result';
        readonly value?: unknown;
    } | {
        readonly kind: 'rejected';
        readonly error: RemoteEventRejection;
    };
}

/** One logical stream request sent from the browser. */
export type RemoteStreamClientMessage = {
    readonly type: 'open';
    readonly streamId: string;
    readonly endpoint: string;
    readonly payload: unknown;
} | {
    readonly type: 'cancel';
    readonly streamId: string;
};

/** Carrier-safe failure delivered by the Host. */
export interface RemoteStreamFailure {
    readonly code: string;
    readonly message: string;
    readonly details: object;
}

/** One logical stream frame sent from the Host. */
export type RemoteStreamServerMessage = {
    readonly type: 'item';
    readonly streamId: string;
    readonly value?: unknown;
} | {
    readonly type: 'error';
    readonly streamId: string;
    readonly error: RemoteStreamFailure;
} | {
    readonly type: 'end';
    readonly streamId: string;
};
```

```ts
// dsh-api-gateway/lib/types/types.d.ts  (error-code union and gateway failure shape)

/** Stable infrastructure and boundary failures emitted before or after business execution. */
export type TypertGatewayErrorCode = 'gateway/ambiguous-endpoint' | 'gateway/arguments-invalid' | 'gateway/binding-invalid' | 'gateway/context-failed' | 'gateway/context-not-found' | 'gateway/context-unavailable' | 'gateway/definition-unavailable' | 'gateway/input-invalid' | 'gateway/invocation-unavailable' | 'gateway/lookup-failed' | 'gateway/lookup-not-found' | 'gateway/lookup-unavailable' | 'gateway/method-unavailable' | 'gateway/provider-mismatch' | 'gateway/result-invalid' | 'gateway/service-unavailable' | 'gateway/signature-invalid';
```

### 3.2 Session controller — list and summaries

```ts
// dsh-api-session-controller/lib/types/types.d.ts

/** Session list request. */
export interface SessionListRequest {
    readonly cursor?: string;
}

/** Session list response value. */
export interface SessionListValue {
    readonly items: readonly SessionSummary[];
}

/** One Session list entry. */
export interface SessionSummary {
    readonly sessionId: SessionId;
    readonly updatedAt: number;
    readonly running: boolean;
    readonly blank: boolean;
    readonly parentSessionId?: SessionId;
    readonly origin?: 'subagent';
    readonly cwd?: string;
    readonly projections?: SessionProjectionHints;
}

/** Every available cached wire value used as partial, possibly stale Session-list hints. */
export interface SessionProjectionHints {
    readonly asOfSeq: number;
    /** Provider-validated values present in the cache; omitted keys remain unknown. */
    readonly values: SessionProjectionValues;
}

/** Complete projection values at an exact Session event cursor. */
export interface SessionProjectionBaseline {
    readonly asOfSeq: number;
    /** Provider-validated values; omitted keys are absent capabilities at this cut. */
    readonly values: SessionProjectionValues;
}

/** Typed known projections plus JSON-safe values contributed outside this compilation face. */
export type SessionProjectionValues = Partial<SessionProjectionMap> & Readonly<Record<string, SessionProjectionValue>>;

/** JSON-compatible projection value accepted by list consumers. */
export type SessionProjectionValue = JsonValue;

/** Persisted hints used to summarize a cold Session. */
export interface SessionListMetadata {
    /** Whether the folded prefix contains no turn. */
    readonly blank: boolean;
    /** Latest human-authored prompt time in the folded prefix. */
    readonly lastPromptAt: number | null;
}
```

### 3.3 Session controller — model catalog and skills

```ts
// dsh-api-session-controller/lib/types/types.d.ts

/** Complete model selection for one Session. */
export interface ModelSelection {
    readonly provider: string;
    readonly model: string;
    readonly reasoningEffort?: string;
}

/** Host-generation model catalog and the default used by unconfigured Sessions. */
export interface ModelCatalog {
    readonly default: ModelSelection;
    /** Provider routes currently able to serve a request, including empty catalogs. */
    readonly routableProviders: readonly string[];
    readonly groups: readonly ModelProviderGroup[];
    readonly failures: readonly ModelCatalogFailure[];
}

/** One provider and its successfully loaded model catalog. */
export interface ModelProviderGroup {
    readonly id: string;
    readonly name: string;
    readonly models: readonly ModelCatalogModel[];
}

/** One model displayed inside its provider group. */
export interface ModelCatalogModel {
    readonly id: string;
    readonly name: string;
    readonly description?: string;
    readonly reasoning?: ModelReasoning;
}

/** Selectable reasoning metadata for one exact model route. */
export interface ModelReasoning {
    readonly efforts: readonly ModelReasoningEffort[];
    readonly defaultEffort?: string;
}

/** One adapter-owned reasoning effort for an exact model route. */
export interface ModelReasoningEffort {
    readonly id: string;
    readonly name: string;
    readonly description?: string;
}

/** One provider whose model catalog lookup failed. */
export interface ModelCatalogFailure {
    readonly id: string;
    readonly name: string;
    readonly message: string;
}

/** Client view of the durable model-selection fold. */
export interface ModelSelectionProjection {
    /** Selection consumed by the latest recorded model request. */
    readonly lastUsed: ModelSelection | null;
    /** Selection the next request should use, falling back to {@link lastUsed}. */
    readonly next: ModelSelection | null;
}

/** Host fold state for durable model selection. */
export interface ModelSelectionProjectionState {
    /** Selection consumed by the latest recorded model request. */
    readonly lastUsed: ModelSelection | null;
    /** Later user selection not yet consumed by a matching model request. */
    readonly pending: ModelSelection | null;
}

/** Session-addressed request for the human-invocable skill catalog. */
export interface SkillListRequest {
    readonly sessionId: SessionId;
}

/** One skill available to the Session's human-facing composer. */
export interface SkillEntry {
    /** Kebab-case identifier referenced as `/name`. */
    readonly name: string;
    /** Short routing description. */
    readonly description: string;
    /** Optional extra routing guidance. */
    readonly whenToUse?: string;
    /** Whether the same skill is also advertised to the model. */
    readonly modelInvocable: boolean;
}

/** Human-invocable skills visible through one Session's composition. */
export interface SkillListValue {
    readonly skills: readonly SkillEntry[];
}
```

### 3.4 Session controller — page, follow, and control streams

```ts
// dsh-api-session-controller/lib/types/types.d.ts

/** Durable identity selecting an ordinary Session or one direct subagent child. */
export type SessionAddress = {
    readonly kind: 'session';
    readonly sessionId: SessionId;
} | {
    readonly kind: 'subagent';
    readonly parentSessionId: SessionId;
    readonly childSessionId: SessionId;
    readonly mode: 'one-shot' | 'continuable';
};

/** One message-aligned backwards-history request. */
export interface SessionPageRequest {
    readonly address: SessionAddress;
    /** Inclusive log cut obtained from the corresponding follow opening frame. */
    readonly throughSeq: number;
    readonly beforeSeq?: number;
    readonly maxMessages?: number;
}

/** One contiguous backwards page of a Session log. */
export interface SessionPage {
    readonly records: readonly SessionHistoryRecord[];
    readonly hasMore: boolean;
}

/** One live event request for a durable Session address. */
export interface SessionFollowRequest {
    readonly address: SessionAddress;
    readonly maxMessages?: number;
    /** Include process-local assistant presentation frames for the Web client. */
    readonly assistantStream?: true;
}

/** Complete opening window followed by ordered durable events and opted-in assistant frames. */
export type SessionFollowFrame = {
    readonly type: 'snapshot';
    readonly header: SessionWireHeader;
    readonly cursor: number;
    readonly records: readonly SessionHistoryRecord[];
    readonly hasMore: boolean;
    readonly projections: SessionProjectionBaseline;
    readonly assistantStream?: SessionAssistantStreamBaseline;
} | SessionEventEntry | {
    readonly type: 'assistant-stream';
    readonly frame: SessionAssistantStreamFrame;
};

/** Current logical Session metadata carried on the browser wire. */
export interface SessionWireHeader {
    readonly version: number;
    readonly id: SessionId;
    readonly createdAt: number;
    readonly cwd?: string;
    readonly parentSession?: SessionId;
    /** Whether the Session contains a fork-inherited prefix. */
    readonly isSeeded: boolean;
    readonly origin?: 'subagent';
    readonly delegationDepth?: number;
    readonly agentPreset?: string;
}

/** One raw Session event in the Remote journal. */
export interface SessionEventEntry {
    readonly type: 'event';
    readonly event: SessionWireEvent;
}

/** One history-page record with compact Assistant streams embedded inside events. */
export type SessionHistoryRecord = SessionEventEntry;

/**
 * Exact Session event envelope accepted by the Client journal adapter.
 * Surface events require surfaceOp; only non-Assistant surface events may cite earlier sources.
 * Durable readers own recognition of merge-extensible event names.
 */
export interface SessionWireEvent {
    readonly type: string;
    readonly seq: number;
    readonly time: number;
    readonly data: JsonValue;
    readonly ignorable?: true;
    /** Earlier sources on current surface events; opaque JSON on unknown ignorable events. */
    readonly sourceEventSeqs?: JsonValue;
    /** Canonical placement on current surface events; opaque JSON on unknown ignorable events. */
    readonly surfaceOp?: JsonValue;
}

/** Browser wire surface operation; replacement endpoints are earlier event seqs in surface order. */
export type SessionWireSurfaceOp = 'append' | {
    readonly op: 'replace';
    readonly startSeq: number;
    readonly endSeq: number;
};

/** Complete process-local assistant state at one follow opening. */
export interface SessionAssistantStreamBaseline {
    readonly revision: number;
    readonly activeAttempt?: SessionAssistantStreamAttempt;
}

/** One active assistant attempt in a reconnect opening snapshot. */
export interface SessionAssistantStreamAttempt {
    readonly attemptId: LlmAttemptId;
    /** Last durable Session seq observed when this attempt started. */
    readonly startedAfterSeq: SessionSeqCursor;
    readonly turn: number;
    readonly step: number;
    /** Dense position expected for the next live chunk frame. */
    readonly nextIndex: number;
    /** Compact detached stream accumulated at this opening revision. */
    readonly stream: readonly JsonValue[];
}

/** Browser wire form of one process-local assistant frame. */
export type SessionAssistantStreamFrame = {
    readonly type: 'start';
    readonly attemptId: LlmAttemptId;
    readonly revision: number;
    readonly startedAfterSeq: SessionSeqCursor;
    readonly turn: number;
    readonly step: number;
} | {
    readonly type: 'chunk';
    readonly attemptId: LlmAttemptId;
    readonly revision: number;
    readonly index: number;
    readonly time: number;
    readonly chunk: JsonValue;
} | {
    readonly type: 'end';
    readonly attemptId: LlmAttemptId;
    readonly revision: number;
    /** Number of chunk frames represented by this terminal marker. */
    readonly index: number;
    readonly outcome: {
        readonly kind: 'committed';
        readonly eventType: 'assistant/message' | 'assistant/attempt';
        readonly seq: number;
    } | {
        readonly kind: 'abandoned';
    };
};

/** Host-wide live state stream. Each generation starts with exactly one baseline. */
export type SessionControlFrame = {
    readonly type: 'baseline';
    readonly value: SessionControlBaseline;
} | {
    readonly type: 'queue';
    readonly sessionId: SessionId;
    readonly items: readonly SessionQueuedItem[];
} | {
    readonly type: 'jobs';
    readonly sessionId: SessionId;
    readonly jobs: readonly SessionJob[];
} | ({
    readonly type: 'projection';
} & SessionProjectionUpdate);

/** Complete live control baseline emitted once per control stream generation. */
export interface SessionControlBaseline {
    readonly queues: Readonly<Record<SessionId, readonly SessionQueuedItem[]>>;
    readonly jobs: Readonly<Record<SessionId, readonly SessionJob[]>>;
    readonly projections: Readonly<Record<SessionId, SessionProjectionBaseline>>;
}

/** One pending inbox occurrence in the authoritative queue snapshot. */
export interface SessionQueuedItem {
    readonly id: MessageId;
    readonly placement: 'queued' | 'steering' | 'context';
    /** Prompt-RPC identity from the queued message's user source; clients retire the matching local submission echo on it. */
    readonly rpcId?: SessionRequestId;
    /** JSON-safe message fields consumed by pending-queue presentation. */
    readonly message: {
        readonly id: MessageId;
        readonly content: readonly JsonValue[];
    };
}

/** Browser-safe background-job row. */
export interface SessionJob {
    readonly id: JobId;
    readonly kind: string;
    readonly label: string;
    readonly status: 'running' | 'stopping' | 'completed' | 'killed' | 'failed';
    readonly detail?: string;
    readonly startedAt: number;
    readonly finishedAt?: number;
}

/** One finished projection value and its durable watermark. */
export interface SessionProjectionUpdate {
    readonly sessionId: SessionId;
    readonly key: string;
    readonly value: JsonValue;
    readonly seq: number;
}
```

### 3.5 Session controller — prompt, cancel, create, fork, rename, selectModel, updateQueue, search, attachment, openWorkspacePath

```ts
// dsh-api-session-controller/lib/types/types.d.ts

/** Client-minted prompt identity used to reconcile optimistic and durable messages. */
export type SessionRequestId = Branded<'session-request-id'>;

/**
 * Browser-submitted prompt content; the Host promotes image bytes to durable
 * references. File parts carry the opaque receipt returned by a preceding
 * `uploadFile` call on the same Session.
 */
export type PromptContentPart = {
    readonly type: 'text';
    readonly text: string;
} | {
    readonly type: 'image';
    readonly mediaType: ImageMediaType;
    readonly data: string;
    readonly name?: string;
} | {
    readonly type: 'file';
    readonly receiptId: Branded<'file-upload-receipt-id'>;
};

/** Session prompt request. */
export interface SessionPromptRequest {
    /** Client-minted identity persisted on the exact accepted user message. */
    readonly requestId: SessionRequestId;
    readonly sessionId: SessionId;
    readonly mode: 'queue' | 'steer';
    /** At least one non-whitespace text part or attachment. */
    readonly content: readonly PromptContentPart[];
    readonly clientTimeZone?: string;
}

/** Receipt after one prompt enters the target Agent inbox. */
export interface SessionPromptValue {
    readonly accepted: true;
}

/** Active-turn cancellation request. */
export interface SessionCancelRequest {
    readonly sessionId: SessionId;
}

/** Receipt after cancellation is admitted to the live Agent. */
export interface SessionCancelValue {
    readonly accepted: true;
}

/** Session creation or explicit-id adoption request. */
export interface SessionCreateRequest {
    readonly workspaceId?: WorkspaceId;
    readonly cwd?: string;
    readonly sessionId?: SessionId;
    readonly agentPreset?: string;
}

/** Session creation response value. */
export interface SessionCreateValue {
    readonly sessionId: SessionId;
    readonly agentPreset?: string;
}

/** Session fork request. */
export interface SessionForkRequest {
    readonly sessionId: SessionId;
    readonly atSeq?: number;
}

/** Identity of a newly forked Session. */
export interface SessionForkValue {
    readonly sessionId: SessionId;
}

/** Session rename request. */
export interface SessionRenameRequest {
    readonly sessionId: SessionId;
    readonly title: string;
}

/** Normalized title and the durable event position that committed it. */
export interface SessionRenameValue {
    readonly title: string;
    readonly seq: number;
}

/** Session model-selection request. */
export interface SessionSelectModelRequest extends ModelSelection {
    readonly sessionId: SessionId;
}

/** Accepted model selection after Host resolution. */
export interface SessionSelectModelValue {
    readonly selected: ModelSelection;
}

/** Pending queue mutation request. */
export interface SessionUpdateQueueRequest {
    readonly sessionId: SessionId;
    readonly itemId: MessageId;
    readonly action: QueueAction;
}

/** Receipt after one pending queue mutation commits. */
export interface SessionUpdateQueueValue {
    readonly accepted: true;
}

/** One client-requested mutation of a still-pending queue item. */
export type QueueAction = {
    readonly kind: 'edit';
    /** Non-empty text-only replacement content. */
    readonly content: readonly ContentBlock[];
} | {
    readonly kind: 'remove';
} | {
    readonly kind: 'steer';
};

/** Session search request. */
export interface SessionSearchRequest {
    readonly query: string;
}

/** Session search response value. */
export interface SessionSearchValue {
    readonly items: readonly SessionSearchItem[];
    readonly hasMore: boolean;
}

/** One session-content search result. */
export interface SessionSearchItem {
    readonly sessionId: SessionId;
    readonly snippet: string;
}

/** Durable image read request. */
export interface SessionAttachmentRequest {
    readonly sessionId: SessionId;
    readonly attachmentId: AttachmentIdType;
}

/** Durable image read response value. */
export interface SessionAttachmentValue {
    readonly attachment: ImageAttachmentRef;
    readonly data: string;
}

/** Request to open one path prepared by a Session-aware caller on the Host desktop. */
export interface SessionOpenWorkspacePathRequest {
    /** File-manager navigation when requested; omission uses the default application. */
    readonly action?: 'reveal';
    /** Path after best-effort Session workspace resolution, in Host filesystem syntax. */
    readonly path: string;
}

/** Confirmation that the Host handed a workspace path to its native opener. */
export interface SessionOpenWorkspacePathValue {
    readonly opened: true;
}
```

### 3.6 Workspace controller and directory picker

```ts
// dsh-api-workspace-controller/lib/types/types.d.ts

/** One durable Workspace projected for browser consumers. */
export interface WorkspaceView {
    readonly workspaceId: WorkspaceId;
    /** Canonical host directory path. */
    readonly path: string;
    /** User-visible title. */
    readonly title: string;
    /** Sessions accounted to this Workspace in manual order. */
    readonly sessionIds: readonly SessionId[];
    /** ISO-8601 creation instant. */
    readonly createdAt: string;
    /** ISO-8601 last-mutation instant. */
    readonly updatedAt: string;
}

/** Existing directory requested for Workspace adoption. */
export interface WorkspaceCreateRequest {
    readonly path: string;
}

/** Created or previously registered Workspace. */
export interface WorkspaceCreateValue {
    readonly workspace: WorkspaceView;
    readonly created: boolean;
}

/** Workspace title mutation. */
export interface WorkspaceRenameRequest {
    readonly workspaceId: WorkspaceId;
    readonly title: string;
}

/** Workspace mutation returning the complete changed row. */
export interface WorkspaceValue {
    readonly workspace: WorkspaceView;
}

/** Workspace registration deletion. */
export interface WorkspaceDeleteRequest {
    readonly workspaceId: WorkspaceId;
}

/** Receipt after one Workspace registration is deleted. */
export interface WorkspaceDeleteValue {
    readonly deleted: true;
}

/** DOM-insertBefore-like Workspace order mutation. */
export interface WorkspaceInsertBeforeRequest {
    readonly workspaceId: WorkspaceId;
    readonly beforeWorkspaceId?: WorkspaceId;
}

/** Complete Workspace registry order after a mutation. */
export interface WorkspaceOrderValue {
    readonly workspaceIds: readonly WorkspaceId[];
}

/** DOM-insertBefore-like Session membership order mutation. */
export interface WorkspaceInsertSessionBeforeRequest {
    readonly workspaceId: WorkspaceId;
    readonly sessionId: SessionId;
    readonly beforeSessionId?: SessionId;
}

/** Session requested for archival from Workspace grouping surfaces. */
export interface WorkspaceArchiveSessionRequest {
    readonly sessionId: SessionId;
}

/** Complete archived Session set after a mutation. */
export interface WorkspaceArchiveValue {
    readonly archivedSessionIds: readonly SessionId[];
}

/** Complete reconnect baseline for Workspace browser state. */
export interface WorkspaceBaseline {
    readonly items: readonly WorkspaceView[];
    readonly archivedSessionIds: readonly SessionId[];
}

/** One ordered Workspace change after a generation's baseline. */
export type WorkspaceFollowIncrement = {
    readonly type: 'upsert';
    readonly workspace: WorkspaceView;
} | {
    readonly type: 'remove';
    readonly workspaceId: WorkspaceId;
} | {
    readonly type: 'order';
    readonly workspaceIds: readonly WorkspaceId[];
} | {
    readonly type: 'archived';
    readonly archivedSessionIds: readonly SessionId[];
};

/** Workspace state stream; every generation starts with exactly one baseline. */
export type WorkspaceFollowFrame = {
    readonly type: 'baseline';
    readonly value: WorkspaceBaseline;
} | WorkspaceFollowIncrement;
```

```ts
// dsh-host-directory-picker/lib/types/types.d.ts  (re-exported by the workspace-controller types)

/** One directory row: a listing child or a breadcrumb ancestor. */
export interface DirectoryEntry {
    /** Base name shown in a browser row (a root crumb carries its full path). */
    name: string;
    /** Absolute host path — clients never join path segments themselves. */
    path: string;
    /** Hidden by the host platform's convention (dot-prefixed on POSIX); the client owns whether to show it. */
    hidden: boolean;
}

/** One directory level plus its ancestry, as a browse backend reports it. */
export interface DirectoryListing {
    /** Absolute path of the listed directory. */
    path: string;
    /** The host account's home directory (breadcrumb "Home" rooting). */
    home: string;
    /**
     * Ancestor chain from the filesystem root to the listed directory
     * inclusive; every crumb is a jump target (crumb `hidden` is always false).
     */
    crumbs: DirectoryEntry[];
    /** Direct child directories, name-sorted; symlinks to directories included. */
    entries: DirectoryEntry[];
    /**
     * True when the backend cut `entries` at its complete-result bound: the
     * level has more child directories than reported, and the missing rows are
     * the name-sorted tail (hidden rows count toward the bound).
     */
    truncated: boolean;
}
```

### 3.7 Settings and credentials controllers

```ts
// dsh-api-settings-controller/lib/types/types.d.ts

/** Confirmation that the settings document was handed to the native editor. */
export interface SettingsDocumentOpenValue {
    readonly opened: true;
}

/** Result of opening or revealing one locally authored Agent preset directory. */
export type AgentPresetDirectoryOpenValue = {
    readonly opened: true;
} | {
    readonly opened: false;
    readonly path: string;
};
```

```ts
// dsh-settings/lib/types/types.d.ts

/** Nominal id of one registered settings namespace. */
export type SettingsNamespace = Branded<'SettingsNamespace'>;

/** Origin of one committed settings change. */
export type SettingsUpdateSource = 'update' | 'provider';

/** One schema-declared secret slot inside a redacted namespace value. */
export interface SettingsSecretView {
    /** Path from the section root to the removed field. */
    path: string[];
    /** Whether the slot currently holds a value; the value itself never rides. */
    set: boolean;
}

/**
 * Wire view of one registered namespace, always read under `redactSecrets`. The
 * JSON-valued fields are `JsonValue` rather than the descriptor's `unknown`
 * because the Remote boundary admits no unconstrained data.
 */
export interface SettingsNamespaceView {
    /** Namespace key (`llm-deepseek`, `llm-pi-ai`, …). */
    ns: string;
    /** Serialized schemastery schema envelope (`schema.toJSON()`); rehydrate with `new Schema(json)`. */
    schema: JsonValue;
    /** Redacted resolved value (schema defaults → composition base → user layer). */
    value: JsonValue;
    /** Redacted composition base layer, when the registrant declared one. */
    base?: JsonValue;
    /** Redacted raw user section, when one exists; a field's presence here marks it user-overridden. */
    user?: JsonValue;
    /** When the owner applies changes. */
    applies: 'live' | 'restart';
    /** Every schema-declared secret slot with its configured state. */
    secrets: SettingsSecretView[];
    /**
     * Monotonic revision of the raw user section this view was read at. Send it
     * back as `expectedRevision` on a write so a stale editor is refused rather
     * than silently overwriting a concurrent change.
     */
    revision: number;
}

/**
 * One path-addressed edit carried by a remote settings write. `set` writes the
 * value at the path, creating intermediate objects; `unset` removes it. The
 * empty path addresses the section root.
 */
export type SettingsPathOpView = {
    op: 'set';
    path: string[];
    value: JsonValue;
} | {
    op: 'unset';
    path: string[];
};

/** Every registered namespace with the deployment facts a configuration page renders around them. */
export interface SettingsDescribeValue {
    /** Whether the provider accepts writes; `false` disables every write control. */
    writable: boolean;
    /** Whether a file-backed provider owns a local document, without exposing its Host path. */
    hasDocument: boolean;
    /** One view per registered namespace. */
    namespaces: SettingsNamespaceView[];
}
```

```ts
// dsh-credentials/lib/types/types.d.ts

/** Nominal reference to one credential: a POSIX-style environment-variable name. */
export type CredentialRef = Branded<'CredentialRef'>;

/**
 * Nominal address of one stored credential record: `<scope>/<id>`, where
 * `scope` is the registered name of the plugin that owns the record and `id`
 * is that plugin's own addressing unit (an LLM adapter uses its provider route
 * key).
 *
 * The scope is the owner rather than the domain because a record's payload is
 * written in its owner's format: two plugins serving the same provider name
 * would otherwise read each other's payload, and a record left behind by an
 * uninstalled plugin could not be told apart from a live one. The `/` also
 * keeps this grammar disjoint from {@link CredentialRef}, so the two key
 * spaces can never collide.
 */
export type CredentialKey = Branded<'CredentialKey'>;

/**
 * A credential the harness itself understands: an api key, provider
 * environment values, or both. Either field may be absent — a record carrying
 * neither states that the owner confirmed this route authenticates from its
 * own ambient discovery, which is a different fact from having no record.
 */
export interface ApiKeyRecord {
    /** Discriminant. */
    readonly kind: 'api-key';
    /** The non-empty secret value, when this credential is a key at all. */
    readonly key?: string;
    /** Provider environment values such as `AWS_PROFILE`; names are POSIX identifiers. */
    readonly env?: Readonly<Record<string, string>>;
}

/**
 * The product of one authorization grant, kept verbatim for its owner. The
 * seam never reads, validates, or reshapes {@link payload}: it is written in
 * the owning plugin's format and only that plugin can interpret it. The single
 * constraint is that it survives a JSON round trip.
 */
export interface GrantRecord {
    /** Discriminant. */
    readonly kind: 'grant';
    /** Owner-defined JSON value; opaque to the seam and to every other plugin. */
    readonly payload: unknown;
}

/** One durable credential record, tagged by what the seam may do with it. */
export type CredentialRecord = ApiKeyRecord | GrantRecord;

/**
 * Source and writability facts for one reference, safe for configuration UIs —
 * never the value. The view has no slot a value could ride in, which is what
 * lets the whole read half cross the Remote wire.
 */
export interface CredentialInfo {
    /** Whether resolving the reference would currently return a value. */
    configured: boolean;
    /** Source layer currently supplying the value; absent while unconfigured. */
    source?: string;
    /** Whether the active provider can write this reference. */
    writable: boolean;
}
```

### 3.8 workspaceFiles

```ts
// dsh-api-workspace-files/lib/types/types.d.ts

/** Identity and freshness of one workspace file, without its content. */
export interface WorkspaceFileStat {
    /**
     * Absolute path of the file in the filesystem's execution world, symlinks
     * resolved: `/`-separated on POSIX, drive-rooted with the platform separator
     * on Windows. What a `dsh-resource://file/absolute/…` address carries, and
     * what a `dsh-resource://file/session/<sessionId>/…` address's
     * workspace-relative path resolves to against that Session's root.
     */
    readonly absolutePath: string;
    /** Opaque freshness token at the time of the stat; never parsed. */
    readonly version: string;
    /** Byte size of the complete file, when the backend reports it. */
    readonly bytes?: number;
}

/**
 * The line window one `read` returns. Lines are 1-based and end at `\n`; a
 * final `\n` terminates the last line rather than starting an empty one.
 */
export interface WorkspaceFileRange {
    /** First line of the page. Defaults to 1. */
    readonly offset?: number;
    /** Largest number of lines on the page. Defaults to, and may not exceed, the configured `maxLines`. */
    readonly limit?: number;
}

/** One page of a workspace text file as a Client reads it. */
export interface WorkspaceFileText extends WorkspaceFileStat {
    /** First line of the page, as requested. */
    readonly offset: number;
    /**
     * The page's lines joined by `\n`, without a terminator after the last one.
     * Empty for a page past the file's last line and for a page holding one
     * empty line; `lines` tells them apart.
     */
    readonly text: string;
    /** How many lines the page holds; `0` when `offset` lies past the file's last line. */
    readonly lines: number;
    /** Whether the page includes the file's last line. */
    readonly eof: boolean;
}

/** The byte window one `readBytes` returns. Offsets are 0-based. */
export interface WorkspaceByteRange {
    /** First byte of the window. Defaults to 0. */
    readonly offset?: number;
    /** Largest number of bytes in the window. Defaults to, and may not exceed, the configured `maxBytes`. */
    readonly length?: number;
}

/**
 * One byte window of a workspace file as a Client reads it: raw bytes, no text
 * decoding and no binary rejection. `bytes` is the complete file's size.
 */
export interface WorkspaceFileBytes extends WorkspaceFileStat {
    /** First byte of the window, as requested. */
    readonly offset: number;
    /** The window's bytes in base64; empty when `offset` lies at or past the file's end. */
    readonly data: string;
    /** Whether the window includes the file's last byte. */
    readonly eof: boolean;
}

/** One direct child of a listed workspace directory. */
export interface WorkspaceDirectoryEntry {
    /** Basename inside the listed directory. */
    readonly name: string;
    /**
     * What the child resolves to. A symlink reports the type of its destination,
     * and `other` covers everything that is neither a regular file nor a
     * directory; `read` still refuses a symlink, so `file` here is a listing fact,
     * not a promise that the content is readable.
     */
    readonly type: 'file' | 'directory' | 'other';
    /** Byte size, present only for a regular file whose backend reports it. */
    readonly size?: number;
}

/** Direct children of one workspace directory. */
export interface WorkspaceDirectoryListing {
    /**
     * The listed directory as a workspace path, relative to the workspace root
     * and empty for the root itself. A child's path is this value joined with
     * {@link WorkspaceDirectoryEntry.name} by `/`.
     */
    readonly path: string;
    /**
     * Direct children in the backend's stable name order, cut to the configured
     * entry cap. Presentation order is the caller's choice.
     */
    readonly entries: readonly WorkspaceDirectoryEntry[];
    /** Whether the entry cap dropped children from {@link entries}. */
    readonly truncated: boolean;
}

/**
 * One observation of a workspace file made by an instrumented filesystem
 * operation. Frames report observations, not deltas: a consumer already
 * holding `version` learns nothing new from the frame and can ignore it.
 */
export type WorkspaceFileChange = {
    /** Absolute path of the observed file, in the same form as {@link WorkspaceFileStat.absolutePath}. */
    readonly absolutePath: string;
    /** Opaque freshness token after the observed operation; never parsed. */
    readonly version: string;
} | {
    /** Absolute path of the observed file, in the same form as {@link WorkspaceFileStat.absolutePath}. */
    readonly absolutePath: string;
    /** The file was observed to be gone. */
    readonly absent: true;
};

/**
 * One frame of a workspace file watch generation. `ready` confirms that the
 * Host is observing filesystem operations and has resolved the workspace
 * root; observations queued during that resolution follow as `change` frames.
 */
export type WorkspaceFileWatchFrame = {
    readonly kind: 'ready';
} | {
    readonly kind: 'change';
    readonly change: WorkspaceFileChange;
};
```

### 3.9 fileReferences

```ts
// dsh-file-reference/lib/types/types.d.ts

/** One path-only completion candidate inside the target session cwd. */
export interface FileReferenceCandidate {
    /** User-facing path accepted by normal prompts and filesystem tools. */
    path: string;
    /** Directories keep completion open; files finish the mention. */
    kind: 'file' | 'directory';
}
```

### 3.10 Message and content vocabulary (needed to render events)

```ts
// dsh-llm/lib/types/types.d.ts

/** Plain text visible to the end user. */
export interface TextBlock {
    type: 'text';
    text: string;
}

/** Reasoning / thinking content, distinct from visible text. */
export interface ReasoningBlock {
    type: 'reasoning';
    text: string;
}

/**
 * A durable raster image reference, valid in user or assistant content. The
 * block is deliberately role-neutral; assistant-side rendering is forward
 * compatibility — the current production adapters declare text-only output,
 * so only user messages may carry images.
 */
export interface ImageBlock {
    type: 'image';
    /** Immutable bytes and intrinsic display metadata owned by the attachment service. */
    attachment: ImageAttachmentRef;
}

/**
 * A durable verbatim file reference, valid in user content. Files never reach
 * a provider natively: request assembly projects every occurrence to
 * deterministic handle text (name, byte size, and the read-only saved path),
 * so adapters and providers see text in its place while the durable log keeps
 * the structured reference for presentation and authorization.
 */
export interface FileBlock {
    type: 'file';
    /** Immutable verbatim bytes and display metadata owned by the attachment service. */
    attachment: FileAttachmentRef;
}

/** A tool invocation requested by the model. */
export interface ToolCallBlock {
    type: 'tool-call';
    /** Provider-issued call id; correlates with the matching tool result. */
    id: ToolCallId;
    name: string;
    /** Raw JSON string as produced by the model. */
    arguments: string;
}

/** The result of a tool invocation, sent back to the model. */
export interface ToolResultBlock {
    type: 'tool-result';
    toolCallId: ToolCallId;
    content: ContentBlock[];
    isError?: boolean;
}

/**
 * Merge-extensible content blocks keyed by `type`. New core blocks must land
 * with adapter, UI, and compaction support.
 */
export interface ContentBlockMap {
    'text': TextBlock;
    'reasoning': ReasoningBlock;
    'image': ImageBlock;
    'file': FileBlock;
    'tool-call': ToolCallBlock;
    'tool-result': ToolResultBlock;
}

/** The block `type` tag vocabulary; widens as plugins add entries to {@link ContentBlockMap}. */
export type ContentBlockType = keyof ContentBlockMap;

/** Any known content block, derived from {@link ContentBlockMap}; switch on `type` and fall through unknowns (merge-extensible). */
export type ContentBlock = ContentBlockMap[ContentBlockType];

/**
 * Why a model response stopped.
 * Merge-extensible so adapters can surface provider-specific reasons.
 */
export interface FinishReasonMap {
    'stop': {
        kind: 'stop';
    };
    'tool-calls': {
        kind: 'tool-calls';
    };
    'max-tokens': {
        kind: 'max-tokens';
    };
    'aborted': {
        kind: 'aborted';
        failure: LlmFailure;
    };
    'error': {
        kind: 'error';
        failure: LlmFailure;
    };
}

/** Any known finish reason, derived from {@link FinishReasonMap}; switch on `kind` and fall through unknowns (merge-extensible). */
export type FinishReason = FinishReasonMap[keyof FinishReasonMap];

/**
 * Token accounting for one model call (cache fields are optional).
 *
 * Counts are DISJOINT: `inputTokens` is uncached input only; cached input is
 * reported separately as `cacheReadTokens`/`cacheWriteTokens` (billed input =
 * sum of the three). Adapters whose providers fold cache hits into a total
 * prompt count (DeepSeek's `prompt_tokens`) subtract them out.
 */
export interface TokenUsage {
    inputTokens: number;
    outputTokens: number;
    /**
     * Exact full-call total including aggregate prompt and output tokens.
     *
     * Adapters preserve a provider total or derive it from authoritative
     * aggregate prompt/output counters; they omit it when unavailable or
     * inconsistent.
     */
    totalTokens?: number;
    cacheReadTokens?: number;
    cacheWriteTokens?: number;
    reasoningTokens?: number;
}

/**
 * Raw streaming protocol emitted by adapters.
 * Block indexes correlate interleaved deltas, and `block-end` carries the
 * assembled block. Adapters emit usage before the terminal finish and nothing
 * afterward; tool arguments remain raw JSON strings. An adapter implementation
 * may throw, but `LlmRuntime.stream()` normalizes that failure to a terminal
 * `error` or `aborted` finish before exposing it to consumers.
 */
export type StreamChunk = {
    type: 'block-start';
    index: number;
    blockType: ContentBlockType;
} | {
    type: 'text-delta';
    index: number;
    text: string;
} | {
    type: 'reasoning-delta';
    index: number;
    text: string;
} | {
    type: 'tool-call-delta';
    index: number;
    id: ToolCallId;
    name?: string;
    argumentsDelta: string;
} | {
    type: 'block-end';
    index: number;
    block: ContentBlock;
} | {
    type: 'usage';
    usage: TokenUsage;
} | {
    type: 'finish';
    reason: FinishReason;
    /** Replay metadata for a successful response; see {@link ReplayEnvelope}. */
    replayState?: ReplayEnvelope;
};
```

```ts
// dsh-llm/lib/types/message.d.ts

/** Provider/model identity and adapter-private replay data for an assistant message. */
export interface AssistantProvenance {
    /** Provider route that produced the message. */
    provider: string;
    /** Provider model id that produced the message. */
    model: string;
    /**
     * Lossless-JSON adapter state needed to replay the provider response.
     * `LlmRuntime` exposes it to a target adapter only when that adapter instance
     * currently owns both this historical provider and the target provider.
     */
    replayState?: unknown;
}

/** Required source of an assistant message produced by a routed model. */
export interface ModelMessageSource extends AssistantProvenance {
    kind: 'model';
}

/** Required source of a user-role message carrying one tool result. */
export interface ToolMessageSource {
    kind: 'tool';
    callId: ToolCallId;
}

/**
 * The kind of information in producer-supplied context, declared by the
 * producer beside its provenance.
 *
 * `MessageSource.kind` answers *who produced this*; `form` answers *what kind
 * of thing it is*, and the two axes are deliberately independent — several
 * producers share one form, and one producer may emit more than one form over
 * a session.
 *
 * The vocabulary is SEMANTIC, never visual: a value states that the content is
 * a file's instructions or a catalog of available items, and a consumer decides
 * what that looks like. Colors, icons, ordering, and collapse defaults are the
 * consumer's business and must not enter this union. It grows one value at a
 * time as producers gain the structured fields their form needs; an absent or
 * unknown value is the documented default, presented as opaque content.
 */
export type ContextForm = 
/** Instructions read out of workspace files the model is expected to follow. */
'instructions'
/** A catalog of items available in this session, republished as it changes. */
 | 'catalog'
/** Current state, where a later snapshot from the same producer supersedes an earlier one. */
 | 'snapshot'
/** A one-off account of something that just happened; it supersedes nothing. */
 | 'notice'
/** A message another agent addressed to this one. */
 | 'relay'
/** Material lifted out of another session's log, possibly reduced on the way in. */
 | 'recall';

/** One named contribution to a `snapshot`-form context, in assembly order. */
export interface ContextSnapshotSection {
    /** The contributing subsystem's name. */
    readonly name: string;
    /** That contribution's model-facing text, exactly as assembled. */
    readonly text: string;
}

/**
 * Producer-declared {@link ContextForm} and the fields that form requires,
 * mixed into the source types that carry one.
 *
 * Discriminated by `form` so a producer cannot select a form without the
 * fields needed to present it: a `notice` must record its one-line
 * account, a `snapshot` its sections. Omitting `form` stays valid — an
 * undeclared context is the documented default.
 */
export type ContextFormed = {
    readonly form?: never;
} | {
    readonly form: 'instructions';
} | {
    readonly form: 'catalog';
} | {
    readonly form: 'snapshot';
    /** The named contributions this snapshot assembled, in order. */
    readonly sections: readonly ContextSnapshotSection[];
} | {
    readonly form: 'notice';
    /** One-line account of what happened, shown without expanding the row. */
    readonly summary: string;
} | {
    readonly form: 'relay';
} | {
    readonly form: 'recall';
};

/**
 * Where a message (or injected content) came from.
 * Merge-extensible sum type — plugins add their own `kind`s.
 */
export interface MessageSourceMap {
    user: {
        kind: 'user';
    };
    plugin: {
        kind: 'plugin';
        plugin: string;
    } & ContextFormed;
    model: ModelMessageSource;
    tool: ToolMessageSource;
}

/** Any known message source, derived from {@link MessageSourceMap}; switch on `kind` and fall through unknowns (merge-extensible). */
export type MessageSource = MessageSourceMap[keyof MessageSourceMap];

/** One immutable message representation shared by delivery, durable history, and model requests. */
export interface Message {
    /** Stable identity preserved across every representation boundary. */
    readonly id: MessageId;
    /** Provider-neutral conversation role. */
    readonly role: 'system' | 'user' | 'assistant';
    /** Exact model-facing blocks. */
    readonly content: ContentBlock[];
    /** Required source fields supplied by the producer. */
    readonly source: MessageSource;
}

/** A user-role specialization of the one shared message representation. */
export interface UserMessage extends Message {
    readonly role: 'user';
}

/** A model-produced assistant specialization of the shared message representation. */
export interface AssistantMessage extends Message {
    readonly role: 'assistant';
    readonly source: ModelMessageSource;
}

/**
 * A system-role specialization of the shared message representation: one
 * rendered system prompt attributed to the plugin that assembled it. Empty
 * `content` means "no system prompt" and projects to no wire message.
 */
export interface SystemMessage extends Message {
    readonly role: 'system';
    readonly source: MessageSourceMap['plugin'];
}

/** A tool-result specialization whose model-facing block retains call correlation. */
export interface ToolResultMessage extends Message {
    readonly role: 'user';
    readonly content: [ToolResultBlock];
    readonly source: ToolMessageSource;
}
```

```ts
// dsh-llm/lib/types/assistant-stream.d.ts

/** One model chunk paired with its original Session timestamp. */
export interface TimedStreamChunk {
    readonly time: number;
    readonly chunk: StreamChunk;
}

/** Lossless compact records embedded in durable Assistant attempt events. */
export type AssistantStreamRecord = {
    readonly type: 'text-chunks';
    readonly time0: number;
    readonly index: number;
    readonly dt: readonly number[];
    readonly texts: readonly string[];
} | {
    readonly type: 'reasoning-chunks';
    readonly time0: number;
    readonly index: number;
    readonly dt: readonly number[];
    readonly texts: readonly string[];
} | {
    readonly type: 'tool-call-chunks';
    readonly time0: number;
    readonly index: number;
    readonly dt: readonly number[];
    readonly id: ToolCallId;
    readonly name?: string;
    readonly args: readonly string[];
} | {
    readonly type: 'chunk';
    readonly time: number;
    readonly chunk: StreamChunk;
};

/** One packed delta run: every compact record except a raw `chunk`. */
export type AssistantStreamRun = Exclude<AssistantStreamRecord, {
    type: 'chunk';
}>;
```

```ts
// dsh-session/lib/types/types.d.ts

/**
 * One immutable entry in the session log.
 *
 * A proper discriminated union over `type` (not independent `type`/`data`
 * unions), so `switch (event.type)` narrows `event.data` without casts.
 *
 * The {@link sourceEventSeqs} and {@link surfaceOp} fields are conditional:
 * they only exist on {@link SurfaceEventType} variants (`system/message`, `user/message`,
 * `assistant/message`, `tool/result`).
 * Non-surface events (boundary markers, attempts, errors) never carry
 * surface metadata — the compiler enforces this at `Session.append()`
 * call sites.
 */
export type SessionEvent<T extends SessionEventType = SessionEventType> = {
    [K in SessionEventType]: {
        type: K;
        /** Monotonic sequence number within the session. */
        seq: SessionSeq;
        /** Unix epoch milliseconds. */
        time: number;
        data: SessionEventMap[K];
        /**
         * Marks an event a reader may safely skip when it does not recognize
         * `type`. Absent means required: a reader meeting an unrecognized type
         * without this marker MUST refuse to reconstruct the session instead of
         * silently dropping the event, because an unrecognized required event may
         * change how the rest of the log is interpreted. A writer sets `true` only
         * on purely informational records whose loss cannot affect reconstruction;
         * defaulting to required means a forgotten marker over-refuses (an
         * inconvenience) rather than silently resuming a gutted session.
         */
        ignorable?: true;
    } & (K extends SurfaceEventType ? SurfaceIntent<K> : {
        surfaceOp?: never;
        sourceEventSeqs?: never;
    });
}[T];

/**
 * The subset of {@link SessionEventType} values whose events produce LLM
 * messages and are eligible to appear on the ordered surface. Only these
 * event types may carry {@link SurfaceOp}; system, user, and tool events may also cite
 * earlier sources through {@link SessionEvent.sourceEventSeqs}.
 */
export type SurfaceEventType = 'system/message' | 'user/message' | 'assistant/message' | 'tool/result';

/** A message-producing event carrying its required surface operation. */
export type SurfaceEvent = SessionEvent<SurfaceEventType>;

/**
 * How a session event entered the ordered surface. Only valid on
 * {@link SurfaceEventType} events.
 *
 * - `'append'`: added to the tail — normal path for user/assistant/tool
 *   messages.
 * - `{ op: 'replace', startSeq, endSeq }`: replaces surface nodes from `startSeq`
 *   (inclusive) through `endSeq` (inclusive) with this node. Both must exist as
 *   surface nodes in the current surface. `startSeq === endSeq` replaces a single
 *   node. The node's {@link SessionEvent.sourceEventSeqs} must include every
 *   shadowed surface node. Used by compaction; any surface-replacing producer
 *   may use it.
 */
export type SurfaceOp = 'append' | {
    op: 'replace';
    startSeq: SessionSeq;
    endSeq: SessionSeq;
};

/**
 * Surface placement and cited source-event seqs for {@link Session.append}. Required on
 * message-producing events and forbidden on log-only events.
 */
export type SurfaceIntent<T extends SurfaceEventType = SurfaceEventType> = {
    surfaceOp: SurfaceOp;
} & (T extends 'assistant/message' ? {
    /** Assistant messages embed their provider stream instead of citing source events. */
    sourceEventSeqs?: never;
} : {
    /** Complete non-empty set of known earlier source-event seqs. */
    sourceEventSeqs?: SessionSeq[];
});

/**
 * The merge-extensible, append-only source of truth for an agent interaction.
 * Message history is derived from this log. Every event is lossless JSON and
 * sequence numbers stay contiguous. Assistant attempt events embed their exact
 * compact raw streams so persistence stores one durable settlement per attempt.
 */
export interface SessionEventMap {
    /**
     * Opens turn `turn` before the loop claims queued input or runs pre-step.
     * Rejection, empty input, cancellation, or failure may close it with no
     * step; otherwise the following identified `user/message` event or batch
     * records the messages entering the step.
     */
    'turn/start': {
        turn: number;
    };
    /**
     * Closes turn `turn` with the {@link TurnEndReason} that ended it. A turn
     * with no entered step has no `step/start` or `step/end`. The loop does not await a
     * flush at turn boundaries: `dsh-session-checkpoint-policy` owns the
     * per-request durability checkpoint, and consumers that read storage after
     * `whenIdle()` flush themselves. Success commits the turn; rejection is
     * reported live and does not prevent later work.
     */
    'turn/end': {
        turn: number;
        reason: TurnEndReason;
    };
    /** Opens step `step` of turn `turn` — one model call plus the tool executions it requested. */
    'step/start': {
        turn: number;
        step: number;
    };
    /** Closes step `step` of turn `turn`. */
    'step/end': {
        turn: number;
        step: number;
    };
    /**
     * A user-role message on the model-visible surface: a direct human prompt
     * (the queued message claimed for this turn), a synthetic `agent.inject()`
     * context (file-change notices, subdir AGENTS.md, skill content, cron
     * notifications, …), or an entered goal continuation round. All three
     * project their `content` verbatim; `source` tells them apart.
     */
    'user/message': UserMessage;
    /**
     * The rendered system prompt on the model-visible surface. The loop appends
     * the first one as surface node 0 before the step's first `user/message`.
     * A prepared in-history route can append nonempty changes in a continuing
     * series. An incapable route or new series normalizes text to the first system
     * node. Normalization empties nonempty later nodes, then rewrites the head if
     * needed, through logged per-node replacements. An empty rendering always
     * clears all active system nodes, leaving no older instructions model-visible.
     * Empty later nodes are dormant and project to no message; an empty head with
     * no active later node records "no system prompt". Restored nonempty text follows
     * the same route and series rule; empty nodes never restore older text.
     */
    'system/message': {
        turn: number;
        step: number;
        message: SystemMessage;
    };
    /**
     * Assembled assistant message for one step (derived history uses this).
     * Carries the step's `usage` when the adapter reported token accounting, so
     * the model output and its accounting travel together (there is no separate
     * usage record). `usage` is absent when the adapter reported none. A turn
     * cancelled mid-stream finalizes its delivered text/reasoning prefix as this
     * event with `interrupted: true`; undispatched tool calls are absent. The
     * marker distinguishes that prefix without re-deriving interruption from turn
     * boundaries. An aborted turn with no such event streamed no visible content.
     */
    'assistant/message': {
        turn: number;
        step: number;
        message: AssistantMessage;
        /** Exact timed model stream, compacted without joining delta boundaries. */
        stream: AssistantStreamRecord[];
        usage?: TokenUsage;
        interrupted?: true;
    };
    /**
     * One model attempt that committed no surface message. The embedded stream
     * preserves a failed, retried, cancelled, or stream-error attempt that
     * reached settlement without fabricating model-visible history.
     */
    'assistant/attempt': {
        turn: number;
        step: number;
        stream: AssistantStreamRecord[];
    };
    /**
     * The model requested one tool invocation: `name` with the raw `arguments`
     * JSON string exactly as the model produced it (unparsed). `callId` pairs the
     * call with its `tool/result`.
     */
    'tool/call': {
        turn: number;
        step: number;
        callId: ToolCallId;
        name: string;
        arguments: string;
    };
    /**
     * A completed tool call's model-facing result, optional internal failure
     * identity, and optional tool-private `meta` presentation payload. `meta` is
     * opaque to the core (the producing tool owns its shape and reads it back in
     * `presentResult`) but MUST be JSON-serializable: `Session.append`
     * runtime-validates all event data with `isJsonValue`, so a non-serializable
     * `meta` is rejected at the source, and the durable log reproduces the
     * identical card on replay. Absent
     * unless the tool attaches one (e.g. `dsh-tool-fs` carries its result-time
     * contextual diff here).
     */
    'tool/result': {
        turn: number;
        step: number;
        message: ToolResultMessage;
        /** Optional failure identity; allowed only when the tool-result block has `isError: true`. */
        error?: {
            name: string;
            code: string;
        };
        meta?: JsonValue;
    };
    /**
     * Full header for the next request, appended inside its step before dispatch.
     * It is log-only; the latest snapshot reconstructs the request header.
     */
    'request/header': {
        header: EpochHeader;
        reason: RequestHeaderReason;
        /** A changed header also begins a distinct model-message series. */
        startsSeries?: true;
    };
    /**
     * Route metadata for the next request, logged only when the route, capacity,
     * or system prompt update mode changes. It does not participate in request
     * reconstruction or header equality. Prompt admission uses the bound prepared
     * call's capability, not this snapshot from an earlier request.
     */
    'request/context': RequestContext;
    /**
     * Marks the end of a constructor seed. Events before it have smaller seq
     * values and came from the seed (resume, fork, or replay); this lifecycle
     * produced none of them. This log-only event is the durable projection of
     * {@link Session.firstLiveSeq}.
     *
     * A fresh fork child owns one `{ inherited: true }` marker at its exact
     * inherited-prefix cut, even when that prefix ends in an ancestor marker.
     * The last tagged marker is the current Session's cut; untagged markers keep
     * ordinary restore and replay lifecycle boundaries.
     *
     * `Session`'s constructor is the only legitimate writer. The invariant
     * companion deliberately constrains nothing here, so a plugin appending one
     * would silently classify every live bracket before it as seed history.
     *
     * An owner of a standalone open/close bracket (`compaction/start` …
     * `compaction/end`) reads it because seed history and live work are otherwise
     * byte-identical: an unmatched opening marker before this event belongs to
     * an ended lifecycle, whatever ended it. NOT a liveness signal about other
     * writers — a concurrently live session holds its own boundary elsewhere,
     * so tolerating concurrent writers needs a signal beyond the log.
     */
    'session/end-seed': {
        inherited?: true;
    };
}

/** The appendable event-type keys of {@link SessionEventMap}, plugin-merged extensions included. */
export type SessionEventType = keyof SessionEventMap;

/**
 * Why a turn ended. Merge-extensible sum type.
 */
export interface TurnEndReasonMap {
    completed: {
        kind: 'completed';
    };
    /** A cancellation request interrupted the live turn. */
    aborted: {
        kind: 'aborted';
        reason: TurnEndCancelCause;
    };
    blocked: {
        kind: 'blocked';
    };
    /**
     * The turn failed. `error` is always a structured failure: the `LlmError`
     * facts verbatim, or `{ message: errorChain(error), code: 'UNKNOWN' }`
     * flattened from any other error.
     */
    error: {
        kind: 'error';
        error: LlmFailure;
    };
    /** At least one step reached its output-token ceiling, even if a plugin continued the turn. */
    'max-tokens': {
        kind: 'max-tokens';
    };
    /**
     * A crash-orphaned turn was closed after the fact: agent-loop resume appends
     * this closer for a stored log whose last turn never ended, and session-query
     * synthesizes it on cold reads. The loop never emits this marker live, and
     * the events recorded before the crash remain intact.
     */
    interrupted: {
        kind: 'interrupted';
    };
}

/** The union over {@link TurnEndReasonMap} — why a turn ended; plugins extend it by merging variants into the map. */
export type TurnEndReason = TurnEndReasonMap[keyof TurnEndReasonMap];
```

### 3.11 Named event payload types (auto-resolved from every bundled `.d.ts`)

These are the named payload types referenced by the durable session-event catalog in Section 5.3 and the `$events` waterfall catalog in Section 5.2. Their declarations are copied verbatim from the owning package.

```ts
// dsh-tool-subagent/lib/types/model-selection.d.ts

/** One exact child LLM route authorized by a user setting. */
export interface AllowedModelRoute {
    /** Registered LLM provider id. */
    readonly provider: string;
    /** Provider-owned exact model id. */
    readonly model: string;
}

```

```ts
// dsh-user-approval/lib/types/types.d.ts

/**
 * Closed approval outcomes: a one-shot grant, explicit rejection, withdrawn
 * request, or unavailable answerer. Callers fail closed on `unavailable`.
 */
export type ApprovalOutcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable';

```

```ts
// dsh-user-approval/lib/types/index.d.ts

/**
 * A session's approval policy — what happens to an {@link ApprovalService}
 * ask BEFORE any interactive answerer sees it:
 *
 * - `'ask'` (the default) — delegate to the composed answerers; with none
 *   composed the chain falls through to the fail-closed `'unavailable'`.
 * - `'never'` — never prompt anyone: every ask resolves `'rejected'`
 *   deterministically. The strict headless stance (CI, unattended runs) and
 *   the policy whose outcome is knowable without asking.
 */
export type ApprovalPolicy = 'ask' | 'never';

```

```ts
// dsh-user-approval/lib/types/types.d.ts

/** Client-safe payload declared for the approval answerer waterfall. */
export interface ApprovalRequestEvent {
    /** Agent identity projected to the corresponding Client Context in transit. */
    readonly agent: Agent;
    /** Tool whose operation requires a decision. */
    readonly toolName: string;
    /** Exact tool call being decided, when available. */
    readonly callId?: ToolCallId;
    /** Human-readable reason supplied by the asker. */
    readonly reason?: string;
    /** Cancellation lifetime of the pending request. */
    readonly signal?: AbortSignal;
}

```

```ts
// dsh-cordis-host-runner/lib/types/index.d.ts

/**
 * Brand a Host-minted approval request ID.
 * @param id - opaque identifier minted by the Host registry.
 * @returns the branded approval request identifier.
 */
export declare function ApprovalRequestId(id: string): ApprovalRequestId;

```

```ts
// dsh-user-questions/lib/types/types.d.ts

/** The human's answer. */
export interface AskUserQuestionAnswer {
    /** Structured answers keyed by question id. */
    answers: AskUserQuestionAnswerItem[];
}

/** Client-safe payload declared for the user-question answerer waterfall. */
export interface AskUserQuestionRequestEvent {
    /** Questions to display. */
    questions: AskUserQuestionItem[];
    /** Agent identity projected to the corresponding Client Context in transit. */
    agent?: Agent;
    /** Cancellation lifetime of the pending request. */
    signal?: AbortSignal;
}

```

```ts
// dsh-llm/lib/types/message.d.ts

/** A model-produced assistant specialization of the shared message representation. */
export interface AssistantMessage extends Message {
    readonly role: 'assistant';
    readonly source: ModelMessageSource;
}

```

```ts
// dsh-llm/lib/types/assistant-stream.d.ts

/** Lossless compact records embedded in durable Assistant attempt events. */
export type AssistantStreamRecord = {
    readonly type: 'text-chunks';
    readonly time0: number;
    readonly index: number;
    readonly dt: readonly number[];
    readonly texts: readonly string[];
} | {
    readonly type: 'reasoning-chunks';
    readonly time0: number;
    readonly index: number;
    readonly dt: readonly number[];
    readonly texts: readonly string[];
} | {
    readonly type: 'tool-call-chunks';
    readonly time0: number;
    readonly index: number;
    readonly dt: readonly number[];
    readonly id: ToolCallId;
    readonly name?: string;
    readonly args: readonly string[];
} | {
    readonly type: 'chunk';
    readonly time: number;
    readonly chunk: StreamChunk;
};

```

```ts
// dsh-attachment/lib/types/types.d.ts

// `AttachmentIdType` is a re-export alias: `export type { AttachmentId as AttachmentIdType, ... } from "./types.ts"` in dsh-attachment/lib/types/index.d.ts. The resolved declaration is `AttachmentId`.

/** Opaque content-addressed identifier for one immutable attachment object. */
export type AttachmentId = Branded<'AttachmentId'>;

```

```ts
// dsh-commands/lib/types/brand.d.ts

/**
 * Pairs one command execution's `command/run`/`command/done` lifecycle
 * records with each other and with the `command.execute` admission response.
 * Minted by the executor, monotonic per service instance.
 */
export type CommandId = Branded<'CommandId'>;

```

```ts
// dsh-commands/lib/types/types.d.ts

/** The union over {@link CommandSourceMap} — who issued a command line. */
export type CommandSource = CommandSourceMap[keyof CommandSourceMap];

```

```ts
// dsh-compaction/lib/types/brand.d.ts

/** Stable identity shared by one compact start/summary/checkpoint/end transaction. */
export type CompactionId = Branded<'CompactionId'>;

```

```ts
// dsh-llm/lib/types/types.d.ts

/** Any known content block, derived from {@link ContentBlockMap}; switch on `type` and fall through unknowns (merge-extensible). */
export type ContentBlock = ContentBlockMap[ContentBlockType];

```

```ts
// dsh-token-meter/lib/types/projection.d.ts

/**
 * Heuristic composition of the next request's context: what the prompt is
 * made of, not what it costs. All three figures use the meter's fixed
 * density estimate, so they will not sum to the provider-anchored
 * `projectedTokens`: the estimator systematically underprices CJK text and
 * JSON schemas, which is exactly the error the anchoring in
 * {@link ContextPressureProjection.projectedTokens} keeps out of the occupancy
 * figure. Present these as approximations of composition, never as a total.
 */
export interface ContextBreakdownProjection {
    /** Heuristic tokens of the last nonempty surviving system prompt in surface order; 0 when none exists. */
    systemTokens: number;
    /** Heuristic tokens of the newest request envelope's tool schemas; 0 before any request. */
    toolsTokens: number;
    /** Heuristic tokens of every other visible surface node, including superseded system prompts. */
    messageTokens: number;
}

/**
 * Approximate context occupancy for a status display.
 *
 * The fields, when present, are deliberately NOT one atomic request
 * observation: each is a last-wins record of a different moment. Switching
 * models can therefore pair a fresh capacity with the previous route's
 * pressure until the next request reports usage. This is an intentional trade
 * — the value is a user-facing reference, not a billing or gating input. See
 * the token-meter README for the full rationale.
 */
export interface ContextPressureProjection {
    /**
     * Provider-reported prompt size of the most recent request: uncached input
     * plus cache reads and writes. Response output is excluded, so this does not
     * grow as the current turn streams. Absent until a provider reports usage.
     */
    pressureTokens?: number;
    /**
     * What the NEXT request's prompt would cost: {@link pressureTokens} plus the
     * heuristic repricing of everything the surface gained or lost since that
     * sample. Only the delta is estimated, so the figure stays anchored to the
     * provider while still reacting the moment a compaction shadows a span —
     * which `pressureTokens` alone cannot do, since compaction reports no usage
     * of its own. Absent until a provider reports usage.
     */
    projectedTokens?: number;
    /** Newest recorded route capacity; absent when no adapter advertised one. */
    contextWindow?: number;
}

```

```ts
// dsh-web-search-deepseek/lib/types/provider.d.ts

/**
 * Exact secret-free DeepSeek Messages request recorded immediately before one
 * auxiliary search dispatch.
 */
export interface DeepSeekSearchLlmRequest {
    /** Fully resolved Messages endpoint. */
    readonly endpoint: string;
    /** `anthropic-version` header value. */
    readonly apiVersion: string;
    /** Exact JSON body sent to the provider. */
    readonly body: {
        readonly model: string;
        readonly max_tokens: number;
        readonly messages: readonly [
            {
                readonly role: 'user';
                readonly content: readonly [
                    {
                        readonly type: 'text';
                        readonly text: string;
                    }
                ];
            }
        ];
        readonly tools: readonly [
            {
                readonly type: 'web_search_20250305';
                readonly name: 'web_search';
                readonly max_uses: number;
            }
        ];
    };
}

```

```ts
// dsh-session/lib/types/types.d.ts

/**
 * Logged request state outside derived history: call config and tools. The
 * system prompt is derived history — surface node 0, a `system/message` event.
 * The latest full `request/header` snapshot reconstructs the header; canonical
 * empty optional fields are absent.
 */
export interface EpochHeader {
    /** The conversation's call configuration (provider, model, reasoning effort, and sampling scalars). */
    config: LlmCallConfig;
    /** Effective config fields materialized from the exact adapter rather than proposed by a caller. */
    adapterDefaults?: LlmCallConfigAdapterDefaults;
    /** Assembled tool schemas; absent for a tool-less request. */
    tools?: ToolSchema[];
}

```

```ts
// dsh-command-feedback/lib/types/types.d.ts

/** One of the fixed feedback categories; the ids are durable log vocabulary. */
export type FeedbackCategory = 'task-result' | 'instruction-following' | 'product-interaction' | 'service-stability' | 'resource-cost' | 'security-privacy-permission' | 'other';

/**
 * One recorded human remark about a Session. Both members are optional: a
 * submission with neither still records that the human asked for the
 * Session to be reviewed, which is what authorizes log delivery.
 */
export interface FeedbackRecord {
    /** Free-text remark with surrounding whitespace removed; never empty when present. */
    readonly text?: string;
    /** Category the human filed the remark under. */
    readonly category?: FeedbackCategory;
}

```

```ts
// dsh-goal/lib/types/domain.d.ts

/** Durable change union carried by the goal domain's own session event. */
export type GoalChangeMeta = GoalSnapshotChangeMeta | GoalClearChangeMeta;

```

```ts
// dsh-goal/lib/types/runtime.d.ts

/**
 * Brand a string as a goal id.
 * @param id - raw goal identifier.
 * @returns the same string with the compile-time brand.
 */
export declare function GoalId(id: string): GoalIdType;

```

```ts
// dsh-hook-protocol/lib/types/types.d.ts

/**
 * The bridge that ran a hook — the CC bridge stamps `'claude-code'`, the Codex
 * bridge `'codex'`. A native plugin at the interception points is not a bridge
 * and writes no `hook/*` invocation/result records (see the interception extension-points Agent Note).
 */
export type HookDialect = 'claude-code' | 'codex';

```

```ts
// dsh-attachment/lib/types/types.d.ts

/** Deployment-resolved limits used by upload admission and request buffering. */
export interface ImageAttachmentLimits {
    maxImageBytes: number;
    maxImagesPerMessage: number;
    maxMessageImageBytes: number;
    maxImagePixels: number;
    /** Maximum intrinsic width and maximum intrinsic height in pixels for one image. */
    maxImageDimension: number;
    mediaTypes: readonly ImageMediaType[];
}

/** Durable, serializable reference to one immutable normalized image. */
export interface ImageAttachmentRef {
    /** Opaque storage identifier; never a filesystem path or bearer URL. */
    attachmentId: AttachmentId;
    /** Media type verified from the stored bytes. */
    mediaType: ImageMediaType;
    /** Exact encoded byte length. */
    bytes: number;
    /** Intrinsic encoded width in pixels. */
    width: number;
    /** Intrinsic encoded height in pixels. */
    height: number;
    /** Optional display name stripped of local path information. */
    name?: string;
    /**
     * Input dimensions after applying EXIF orientation and before normalization
     * scaling. Present only when normalization reduced the image.
     */
    originalDimensions?: {
        width: number;
        height: number;
    };
}

/** Raster image formats accepted by the version-one attachment path. */
export type ImageMediaType = 'image/png' | 'image/jpeg' | 'image/webp' | 'image/gif';

```

```ts
// dsh-agent/lib/types/types.d.ts

/** One of the two ordered pending-message lists owned by an agent. */
export type InboxTarget = 'next-turn' | 'next-step';

```

```ts
// dsh-jobs/lib/types/brand.d.ts

/**
 * Identifies a background job. The registry generates `<kind>-N`; predictable
 * ids rely on owner authorization rather than secrecy.
 */
export type JobId = Branded<'JobId'>;

```

```ts
// dsh-util-values/lib/types/index.d.ts

/** A value that round-trips through JSON without loss. */
export type JsonValue = null | boolean | number | string | JsonValue[] | {
    [key: string]: JsonValue;
};

```

```ts
// dsh-llm/lib/types/brand.d.ts

/** Identity of one model streaming attempt, unique within one Agent lifecycle. */
export type LlmAttemptId = Branded<'LlmAttemptId'>;

```

```ts
// dsh-llm-retry/lib/types/types.d.ts

/** Durable payload recorded before one provider-routed model-request retry wait. */
export type LlmRetryEventData = {
    retryId: RetryId;
    turn: number;
    step: number;
    provider: string;
    mode: 'normal';
    policyKey: string;
    retry: number;
    maxRetries: number;
    delayMs: number;
    failure: LlmFailure;
} | {
    retryId: RetryId;
    turn: number;
    step: number;
    provider: string;
    mode: 'always';
    policyKey: string;
    retry: number;
    delayMs: number;
    failure: LlmFailure;
};

/** Durable transition recorded after one retry delay completes. */
export interface LlmRetryStartedEventData {
    retryId: RetryId;
    turn: number;
    step: number;
    retry: number;
}

```

```ts
// dsh-message-feedback/lib/types/types.d.ts

/** A material deletion of one current feedback item. */
export interface MessageFeedbackDelete {
    /** Session that owns the deleted feedback. */
    readonly sessionId: SessionId;
    /** Message whose feedback was removed. */
    readonly messageId: MessageId;
}

/** A material creation or edit, retaining its complete current value. */
export interface MessageFeedbackPut {
    /** Owning Session; inherited feedback in a fork belongs to its parent. */
    readonly sessionId: SessionId;
    /** Value after this mutation, including the original creation time. */
    readonly item: MessageFeedbackItem;
}

```

```ts
// dsh-llm/lib/types/brand.d.ts

/** Stable identity carried by one message across inbox, log, and model-request boundaries. */
export type MessageId = Branded<'MessageId'>;

```

```ts
// dsh-agent/lib/types/model-selection.d.ts

/** Complete provider, model, and optional reasoning effort selected for one live Agent. */
export interface ModelSelection {
    /** Registered provider route. */
    provider: string;
    /** Provider-owned model id. */
    model: string;
    /** Adapter-owned reasoning effort, or provider/default behavior when absent. */
    reasoningEffort?: ReasoningEffortId;
}

```

```ts
// dsh-client-ui-conversation/lib/types/client/skeleton/PermissionSelect.d.ts

export declare function PermissionSelect({ value, locked, command, t }: PermissionSelectProps): import("react").JSX.Element | null;

```

```ts
// dsh-plan-mode/lib/types/types.d.ts

/**
 * The plan projection's wire value. `active` is the logged state in force
 * (the last `plan/mode`, inactive before the first); `pending` is true while
 * a logged `/plan` selection targets a state other than `active`, has not
 * failed through its paired `command/done`, and no later `plan/mode` event has
 * recorded that state. Capability absence (plan-mode not composed) is the
 * key's absence, never a value.
 */
export interface PlanProjection {
    active: boolean;
    pending: boolean;
}

```

```ts
// dsh-tool-present/lib/types/types.d.ts

/** A declared filesystem file whose current contents remain at its source path. */
export interface PresentedFile {
    /** Original absolute path or path relative to the Session working directory. */
    path: string;
    /** Optional description supplied by the model. */
    description?: string;
}

```

```ts
// dsh-tools/lib/types/types.d.ts

/** Payload recorded when one nested PTC mode Tool dispatch settles. */
export interface PtcDispatchEventData extends PtcDispatchStartEventData {
    isError: boolean;
    content: ContentBlock[];
}

/** Payload recorded when one nested PTC mode Tool dispatch starts. */
export interface PtcDispatchStartEventData {
    rootCallId: ToolCallId;
    parentCallId: ToolCallId;
    subCallId: ToolCallId;
    name: string;
    arguments: unknown;
}

```

```ts
// dsh-llm/lib/types/brand.d.ts

/** Adapter-owned identifier for one model's selectable reasoning effort. */
export type ReasoningEffortId = Branded<'ReasoningEffortId'>;

```

```ts
// dsh-session/lib/types/types.d.ts

/** Registration-bound metadata for one resolved model route. */
export interface RequestContext {
    /** Registered provider route the metadata belongs to. */
    provider: string;
    /** Provider-owned model id the metadata belongs to. */
    model: string;
    /** Maximum combined request and response context in tokens, when advertised. */
    contextWindow?: number;
    /** `'in-history'` when the route reads the latest `system` message at any position as the effective system prompt. */
    systemPromptUpdate?: SystemPromptUpdate;
}

/**
 * Why a `request/header` snapshot was appended: `'initial'` — the log's first
 * header (a new conversation); `'resume'` — a loop instance's first request
 * over a log that already has header events (process restart, fork seed);
 * `'change'` — a later request used a different header, with `startsSeries`
 * preserving a coincident series boundary; `'series'` — an unchanged header
 * began an explicitly distinct message series or followed a surface replacement.
 */
export type RequestHeaderReason = 'initial' | 'resume' | 'change' | 'series';

```

```ts
// dsh-sandbox/lib/types/index.d.ts

/**
 * File-effect policy for confined processes. `read-only` permits only required
 * sinks such as `/dev/null`; `workspace-write` also permits the workspace and a
 * backend-defined temp area; `danger-full-access` bypasses confinement. Network
 * and process visibility are outside this vocabulary.
 */
export type SandboxMode = 'read-only' | 'workspace-write' | 'danger-full-access';

```

```ts
// dsh-schedule/lib/types/types.d.ts

/** Strict version-1 durable Schedule mutation union. */
export type ScheduleChange = ScheduleCreateChange | ScheduleDeleteChange | ScheduleDispatchChange;

/** The v1 durable reminder record union. */
export type ScheduleRecord = OneShotScheduleRecord | EveryScheduleRecord;

```

```ts
// dsh-session/lib/types/types.d.ts

/** Identifies one session in the store (and its persistence artifacts). */
export type SessionId = Branded<'SessionId'>;

/** Sequence number of one existing event in a Session log. */
export type SessionSeq = BrandedNumber<'SessionSeq'>;

/** Inclusive Session event watermark, or `-1` before any event exists. */
export type SessionSeqCursor = SessionSeq | -1;

```

```ts
// dsh-session-stats/lib/types/types.d.ts

/**
 * Whole-log conversation figures, independent of how much history a client
 * has paged in. Counts and wall times all fold from the complete durable log;
 * every field is 0 until its first contributing event lands. Field names
 * mirror the client window fold so an assembly without this unit can fall
 * back to it wholesale.
 */
export interface SessionStatsProjection {
    /** Distinct turns carrying at least one closed step (`step/end`); rejected or empty turns are uncounted. */
    turns: number;
    /** Closed steps (`step/end` events) — completed, failed, and cancelled steps alike. */
    steps: number;
    /** Summed model wall time (`step/start` → `assistant/message`) over steps that assembled a message. */
    llmMs: number;
    /** Summed tool wall time over `tool/call` → `tool/result` pairs matched by callId. */
    toolMs: number;
    /** Summed first-token latency (`step/start` → first non-empty delta chunk) over `ttftSteps`. */
    ttftMs: number;
    /** Steps carrying a recorded first token. */
    ttftSteps: number;
    /** Summed decode wall time (first token → `assistant/message`) over steps that also report output tokens. */
    decodeMs: number;
    /** Summed provider output tokens over the same decode-timed steps. */
    decodeTokens: number;
}

```

```ts
// dsh-session-title/lib/types/types.d.ts

/** Payload of the log-only `session/title` event. */
export interface SessionTitleEventData {
    /** Normalized non-empty title text. */
    readonly title: string;
    /** Exact human `user/message` seqs used to derive this title; empty for an explicit user rename. */
    readonly messageSeqs: SessionSeq[];
    /** Whether the built-in fallback, a registered provider, or the user supplied the title. */
    readonly source: SessionTitleSource;
}

```

```ts
// dsh-session-title-llm/lib/types/index.d.ts

/** Exact model-visible request recorded before one auxiliary title dispatch. */
export interface SessionTitleLlmRequestEventData {
    /** Registered title-provider identity responsible for the request. */
    readonly titleProvider: SessionTitleProviderId;
    /** Exact human `user/message` seqs represented in `messages`. */
    readonly messageSeqs: SessionSeq[];
    /** Exact auxiliary LLM route. */
    readonly route: SessionTitleModelProvenance;
    /** Exact auxiliary system prompt. */
    readonly system: string;
    /** Exact auxiliary message list. */
    readonly messages: Message[];
    /** Exact auxiliary output-token cap. */
    readonly maxTokens: number;
}

```

```ts
// dsh-subagent/lib/types/projection-types.d.ts

/** One current direct-child discovery row materialized from parent facts. */
export type SubagentCatalogEntry = {
    readonly id: SessionId;
    readonly createdAt: number;
} & ({
    readonly mode: 'one-shot';
    readonly label?: string;
} | {
    readonly mode: 'continuable';
    readonly label: string;
});

```

```ts
// dsh-subagent/lib/types/catalog.d.ts

/** One complete parent-owned catalog fact. */
export type SubagentCatalogEvent = {
    readonly version: 0;
    readonly childId: SessionId;
    readonly childCreatedAt: number;
} & ({
    readonly mode: 'one-shot';
    readonly label?: string;
} | {
    readonly mode: 'continuable';
    readonly label: string;
});

```

```ts
// dsh-subagent/lib/types/descriptor.d.ts

/** The supported durable subagent identity and optional continuation composition. */
export type SubagentDescriptorData = OneShotSubagentDescriptorData | ContinuableSubagentDescriptorData;

```

```ts
// dsh-llm/lib/types/message.d.ts

/**
 * A system-role specialization of the shared message representation: one
 * rendered system prompt attributed to the plugin that assembled it. Empty
 * `content` means "no system prompt" and projects to no wire message.
 */
export interface SystemMessage extends Message {
    readonly role: 'system';
    readonly source: MessageSourceMap['plugin'];
}

```

```ts
// dsh-tool-todo/lib/types/types.d.ts

/**
 * One entry in an agent's todo list — the unit of the `todo/write`
 * whole-list snapshot declared by this package.
 *
 * Deliberately minimal: a human-readable `content` line and a three-state
 * `status`. No id, priority, or `activeForm` — the list is replaced wholesale
 * on every write (last-write-wins), so entries need no stable identity. The
 * three statuses describe the complete portable lifecycle needed by model and
 * UI consumers.
 */
export interface TodoItem {
    /** What this task is — a short imperative line shown in the UI. */
    content: string;
    /** Lifecycle state. `in_progress` marks a task being worked now; parallel work may mark several. */
    status: 'pending' | 'in_progress' | 'completed';
}

```

```ts
// dsh-llm/lib/types/types.d.ts

/**
 * Token accounting for one model call (cache fields are optional).
 *
 * Counts are DISJOINT: `inputTokens` is uncached input only; cached input is
 * reported separately as `cacheReadTokens`/`cacheWriteTokens` (billed input =
 * sum of the three). Adapters whose providers fold cache hits into a total
 * prompt count (DeepSeek's `prompt_tokens`) subtract them out.
 */
export interface TokenUsage {
    inputTokens: number;
    outputTokens: number;
    /**
     * Exact full-call total including aggregate prompt and output tokens.
     *
     * Adapters preserve a provider total or derive it from authoritative
     * aggregate prompt/output counters; they omit it when unavailable or
     * inconsistent.
     */
    totalTokens?: number;
    cacheReadTokens?: number;
    cacheWriteTokens?: number;
    reasoningTokens?: number;
}

```

```ts
// dsh-token-meter/lib/types/projection.d.ts

/**
 * Durable cumulative provider usage for a complete session log.
 *
 * The four buckets are disjoint. In particular, reasoning tokens are already
 * included in `outputTokens` and are not accumulated again.
 */
export interface TokenUsageProjection {
    uncachedInputTokens: number;
    outputTokens: number;
    cacheReadTokens: number;
    cacheWriteTokens: number;
}

```

```ts
// dsh-client-ui-chat/lib/types/client/contract/store.d.ts

/** Tool call identity as carried by Chat nodes. */
export type ToolCallId = string;

```

```ts
// dsh-llm/lib/types/message.d.ts

/** A tool-result specialization whose model-facing block retains call correlation. */
export interface ToolResultMessage extends Message {
    readonly role: 'user';
    readonly content: [ToolResultBlock];
    readonly source: ToolMessageSource;
}

```

```ts
// dsh-tool-workflow/lib/types/types.d.ts

/** Settles one previously started workflow member. */
export interface ToolWorkflowAgentEndData {
    readonly runId: WorkflowRunId;
    readonly seq: number;
    readonly outcome: WorkflowAgentOutcome;
}

/** Records one workflow member after its child Session is published. */
export interface ToolWorkflowAgentStartData {
    readonly runId: WorkflowRunId;
    readonly seq: number;
    readonly label: string;
    readonly phase?: string;
    readonly childId: SessionId;
}

/** Settles one workflow run after its live resources reach quiescence. */
export interface ToolWorkflowRunEndData {
    readonly runId: WorkflowRunId;
    readonly stopReason: WorkflowStopReason;
}

/** Opens one durable top-level workflow run record. */
export interface ToolWorkflowRunStartData {
    readonly runId: WorkflowRunId;
    readonly name: string;
}

```

```ts
// dsh-session/lib/types/types.d.ts

/** The union over {@link TurnEndReasonMap} — why a turn ended; plugins extend it by merging variants into the map. */
export type TurnEndReason = TurnEndReasonMap[keyof TurnEndReasonMap];

```

```ts
// dsh-session-turn-outline/lib/types/types.d.ts

/** One started turn's outline facts, independent of what a client has paged in. */
export interface TurnOutlineEntry {
    /** Host-assigned turn number (the `turn/start` payload). */
    readonly turn: number;
    /** The turn's `turn/start` event seq — paging a window back through this seq loads the whole turn. */
    readonly seq: SessionSeq;
    /** Bounded first-human-prompt preview (one rail-card line); `''` until an eligible prompt lands. */
    readonly prompt: string;
    /** Bounded final-response preview (up to three rail-card lines); `''` until the turn ends with assistant text. */
    readonly response: string;
}

```

```ts
// dsh-llm/lib/types/message.d.ts

/** A user-role specialization of the one shared message representation. */
export interface UserMessage extends Message {
    readonly role: 'user';
}

```

```ts
// dsh-workspace/lib/types/index.d.ts

/** Identifies one workspace record (see `src/types.ts` for the brand rationale). */
export type WorkspaceId = WorkspaceIdBrand;

```


---

## 4. Event catalog

### 4.1 The three event channels (do not confuse them)

| Channel | What arrives | Where it arrives | Answer needed? |
|---|---|---|---|
| **Forwarded application events** | `RemoteEventReadyFrame` / `EmitFrame` / `InvocationFrame` / `CancellationFrame` | `$events` WS stream (Section 1.8) | Only `waterfall` frames |
| **Durable session events** | `SessionEventEntry` = `{type:'event', event: SessionWireEvent}` | `session/follow` WS stream (inside the snapshot's `records` and as later items) | Never |
| **Client-only live frames** | `{type:'assistant-stream', frame: SessionAssistantStreamFrame}` | `session/follow` WS stream, only when you open with `assistantStream: true` | Never |

The streaming chat surface that an implementer cares about — `turn/start`, `step/start`, `assistant/message`, `tool/call`, `tool/result`, `user/message`, `session/title`, `goal/change`, `todo/write`, `approval/asked`, `approval/decided`, `compaction/*`, `subagent/*`, `feedback/*` — is **durable session-event traffic carried inside `session/follow`**. It does **not** come over `$events`. `$events` carries only the 19-event forwarded allowlist in Section 4.2.

`SessionWireEvent` is the envelope for every durable event:

```ts
interface SessionWireEvent {
  readonly type: string;        // the event name, e.g. "turn/start"
  readonly seq: number;         // monotonic within the session
  readonly time: number;        // unix epoch ms
  readonly data: JsonValue;     // the payload object from Section 4.3
  readonly ignorable?: true;
  readonly sourceEventSeqs?: JsonValue;  // surface events only
  readonly surfaceOp?: JsonValue;        // surface events only
}
```

`surfaceOp` is `'append'` or `{op:'replace', startSeq, endSeq}`. A `replace` means this event **supersedes** the surface nodes from `startSeq` through `endSeq` inclusive (this is what compaction does) — a client rendering a linear transcript must honor it. `sourceEventSeqs` lists the earlier surface nodes a replacement shadowed.

### 4.2 `$events` forwarded-event allowlist (19 events)

This list is the *complete* set of application events the host forwards to clients; it is the authoritative allowlist in `@deepseek-ai/dsh-api-remotes`. `emit` frames need no answer; **waterfall** frames must be answered with `$events/result` (Section 1.8).

| Event | Mode | Cordis signature (verbatim) | When it fires | Source |
|---|---|---|---|---|
| `agent-preset/selected` | emit — no answer required | `'agent-preset/selected'(sessionId: SessionId, agentPreset: string): void` | One session committed a different agent preset to its durable log. | `dsh-agent-presets/lib/types/types.d.ts` |
| `approval/request` | **waterfall** — must be answered with `$events/result` | `'approval/request'(this: Scoped<Agent>, req: ApprovalRequestEvent, next: () => Promise<ApprovalOutcome>): Promise<ApprovalOutcome>` | Ask composed answerers for one decision. | `dsh-user-approval/lib/types/types.d.ts` |
| `api-session/activity` | emit — no answer required | `'api-session/activity'(sessionId: SessionId, updatedAt: number): void` | One user-authored durable message advanced Session list activity. | `dsh-api-session-controller/lib/types/types.d.ts` |
| `api-session/added` | emit — no answer required | `'api-session/added'(summary: SessionSummary): void` | A Session became visible to Session list consumers. | `dsh-api-session-controller/lib/types/types.d.ts` |
| `api-session/error` | emit — no answer required | `'api-session/error'(sessionId: SessionId, message: string): void` | One Agent failed outside a durable turn position. | `dsh-api-session-controller/lib/types/types.d.ts` |
| `api-session/removed` | emit — no answer required | `'api-session/removed'(sessionId: SessionId): void` | A Session left the live Host registry. | `dsh-api-session-controller/lib/types/types.d.ts` |
| `api-session/status` | emit — no answer required | `'api-session/status'(sessionId: SessionId, running: boolean): void` | One Agent changed running state. | `dsh-api-session-controller/lib/types/types.d.ts` |
| `commands/change` | emit — no answer required | `'commands/change'(): void` | A command was registered or unregistered. | `dsh-commands/lib/types/types.d.ts` |
| `credentials/reference-updated` | emit — no answer required | `'credentials/reference-updated'(ref: CredentialRef): void` | Committed change to a provider-managed credential source: a `set`, an `unset`, or an external edit observed in storage. | `dsh-credentials/lib/types/types.d.ts` |
| `goal/activation-changed` | emit — no answer required | `'goal/activation-changed'(payload: GoalActivationChanged): void` | Process-local goal activation changed for one session. | `dsh-goal/lib/types/types.d.ts` |
| `cordis/request-run` | emit — no answer required | `'cordis/request-run'(request: DynamicCordisRunRequest): void` | A Client-bearing activation needs a browser page, and may require a user decision. | `dsh-cordis-host-runner/lib/types/types.d.ts` |
| `cordis/request-run-resolved` | emit — no answer required | `'cordis/request-run-resolved'(resolved: DynamicCordisRequestResolved): void` | A pending Client activation request left the answerable state. | `dsh-cordis-host-runner/lib/types/types.d.ts` |
| `cordis/dynamic-package` | emit — no answer required | `'cordis/dynamic-package'(pkg: DynamicCordisPackage): void` | One exact Plugin/Package activation is now live in the Host. | `dsh-cordis-host-runner/lib/types/types.d.ts` |
| `cordis/dynamic-retract` | emit — no answer required | `'cordis/dynamic-retract'(retracted: DynamicCordisRetracted): void` | One exact activation was withdrawn. | `dsh-cordis-host-runner/lib/types/types.d.ts` |
| `cordis/inspect-query` | emit — no answer required | `'cordis/inspect-query'(request: CordisInspectQueryRequest): void` | Request a live read-only query from the Client inspect registry. | `dsh-cordis-host-runner/lib/types/types.d.ts` |
| `cordis/inspect-query-resolved` | emit — no answer required | `'cordis/inspect-query-resolved'(resolved: CordisInspectQueryResolved): void` | Notify every Client that an inspect query has settled or been cancelled. | `dsh-cordis-host-runner/lib/types/types.d.ts` |
| `llm/adapters-updated` | emit — no answer required | `'llm/adapters-updated'(): void` | The provider topology changed: an adapter registered or unregistered routes, or the configurable-provider directory gained or lost entries. | `dsh-llm/lib/types/types.d.ts` |
| `settings/document-updated` | emit — no answer required | `'settings/document-updated'(ns: SettingsNamespace, revision: number): void` | One registered namespace's RAW user section changed, whether or not the resolved value did. | `dsh-settings/lib/types/types.d.ts` |
| `user-questions/request` | **waterfall** — must be answered with `$events/result` | `'user-questions/request'(this: Scoped<Agent>, request: AskUserQuestionRequestEvent, next: () => Promise<AskUserQuestionAnswer>): Promise<AskUserQuestionAnswer>` | Ask composed answerers for structured user input. | `dsh-user-questions/lib/types/types.d.ts` |

**Waterfall payloads in practice.**

- `approval/request` — `(this: Scoped<Agent>, req: ApprovalRequestEvent, next: () => Promise<ApprovalOutcome>): Promise<ApprovalOutcome>`. The host is asking whether a tool call may proceed. The client answers `{kind:'result', value: <ApprovalOutcome>}` to claim the decision, or `{kind:'next'}` to delegate to the next answerer in the host chain.
- `user-questions/request` — `(this: Scoped<Agent>, request: AskUserQuestionRequestEvent, next: () => Promise<AskUserQuestionAnswer>): Promise<AskUserQuestionAnswer>`. The `ask_user_question` tool wants structured input; the client answers with an `AskUserQuestionAnswer`.

Both are **scope-filtered**: an agent-scoped listener receives only events for that agent, and the waterfall frame carries the `agentId` that scopes it. A multi-session client should filter on `agentId` (which is the session id for a top-level session).

### 4.3 Durable session events (56 known types)

`@deepseek-ai/dsh-session`'s runtime catalog `KNOWN_SESSION_EVENT_TYPES` enumerates exactly the event names this build understands. A persisted or streamed event whose `type` is **not** in this list and which lacks `"ignorable": true` **must not be silently skipped** — the documented behavior is to refuse to reconstruct the session, because an unrecognized required event may change how the rest of the log is interpreted. Out-of-repo plugins may add events; `ignorable` is the forward-compatibility mechanism.

Payload column is the `event.data` shape. `(untyped here)` means the payload type is not declared in this installation (Section 7).

| Event | `data` shape | When it fires | Declared in |
|---|---|---|---|
| `agent-preset/selected` | `{ agentPreset: string; }` | The session agent preset was selected. | `dsh-agent-presets/lib/types/session.d.ts` |
| `agent/inbox/spliced` | `{ target: InboxTarget; start: number; removedCount?: number; inserted: UserMessage[]; outcome?: 'canceled'; }` | A pending-inbox splice occurred. | `dsh-agent/lib/types/types.d.ts` |
| `approval/asked` | `{ id: ApprovalRequestId; toolName: string; callId?: ToolCallId; reason?: string; }` | An approval question was put to the answerer chain (log-only audit). | `dsh-user-approval/lib/types/types.d.ts` |
| `approval/decided` | `{ id: ApprovalRequestId; outcome: ApprovalOutcome; }` | The outcome of one previously asked approval. | `dsh-user-approval/lib/types/types.d.ts` |
| `approval/policy` | `{ policy: ApprovalPolicy; source?: 'delegation'; }` | The session's approval policy was switched — log-only, durable, replayable, never in the model transcript (the model learns the policy from the runtime-context snapshot and live switch notices). | `dsh-user-approval/lib/types/index.d.ts` |
| `assistant/attempt` | `{ turn: number; step: number; stream: AssistantStreamRecord[]; }` | One model attempt that committed no surface message (failed, retried, cancelled, or stream-error). | `dsh-session/lib/types/types.d.ts` |
| `assistant/message` | `{ turn: number; step: number; message: AssistantMessage; stream: AssistantStreamRecord[]; usage?: TokenUsage; interrupted?: true; }` | Assembled assistant message for one step, with the exact timed model stream and optional usage. | `dsh-session/lib/types/types.d.ts` |
| `command/done` | `{ commandId: CommandId; kind: 'success' \| 'error'; text?: string; sourceEventSeq?: import('@deepseek-ai/dsh-session/types').SessionSeq; }` | A slash command finished. | `dsh-commands/lib/types/types.d.ts` |
| `command/run` | `{ commandId: CommandId; name: string; args?: string; source: CommandSource; }` | A slash command began running. | `dsh-commands/lib/types/types.d.ts` |
| `compaction/end` | `{ compactionId: CompactionId; sourceCommandId?: CommandId; turn: number \| null; error?: string; }` | Closes a compaction bracket. | `dsh-compaction/lib/types/types.d.ts` |
| `compaction/prune` | `{ shadowedRange:{ start: SessionSeq; end: SessionSeq; } ; shadowedSeqs: SessionSeq[]; shadowedTokenCount: number; }` | Records a shadowed range pruned from the request projection. | `dsh-compaction/lib/types/types.d.ts` |
| `compaction/start` | `{ compactionId: CompactionId; sourceCommandId?: CommandId; turn: number \| null; }` | Opens an owner-scoped compaction bracket. | `dsh-compaction/lib/types/types.d.ts` |
| `compaction/summary` | `{ compactionId: CompactionId; sourceCommandId?: CommandId; summary: ContentBlock[]; shadowedRange:{ start: SessionSeq; end: SessionSeq; } ; shadowedSeqs: SessionSeq[]; shadowedTokenCount: number; provider: string; model: string; maxTokens?: number; usage?: TokenUsage; } & ({ rawOutput: ContentBlock[]; llmStreamCall: true; } \|{ rawOutput?: ContentBlock[]; llmStreamCall?: never; } )` | The summary produced by a compaction. | `dsh-compaction/lib/types/types.d.ts` |
| `deliverables/presented` | `{ turn: number; callId: ToolCallId; files: PresentedFile[]; }` | Files presented to the user through the present tool. | `dsh-tool-present/lib/types/types.d.ts` |
| `feedback/message-delete` | `MessageFeedbackDelete` | Feedback removed from one message. | `dsh-message-feedback/lib/types/types.d.ts` |
| `feedback/message-put` | `MessageFeedbackPut` | Feedback attached to / updated on one message. | `dsh-message-feedback/lib/types/types.d.ts` |
| `feedback/record` | `FeedbackRecord` | One message feedback record. | `dsh-command-feedback/lib/types/types.d.ts` |
| `goal/change` | `GoalChangeMeta` | Complete post-mutation goal state or clear tombstone. | `dsh-goal/lib/types/domain.d.ts` |
| `hook/invoked` | `{ turn: number; point: string; dialect: HookDialect; matcher?: string; handlerId: string; }` | A hook handler was invoked. | `dsh-hook-protocol/lib/types/types.d.ts` |
| `hook/result` | `{ turn: number; point: string; handlerId: string; decision: string; exitCode?: number; stderrSummary?: string; durationMs: number; }` | A hook handler returned a decision. | `dsh-hook-protocol/lib/types/types.d.ts` |
| `llm/retry` | `LlmRetryEventData` | One model call is being retried. | `dsh-llm-retry/lib/types/types.d.ts` |
| `llm/retry-started` | `LlmRetryStartedEventData` | A retry attempt started. | `dsh-llm-retry/lib/types/types.d.ts` |
| `model/selection` | `ModelSelection` | The validated model selection for subsequent requests (log-only). | `dsh-api-session-controller/lib/types/types.d.ts` |
| `permission/preset` | `{ preset: string; }` | The session permission preset changed. | `dsh-permission-presets/lib/types/index.d.ts` |
| `plan/mode` | `{ active: boolean; }` | The session plan-mode flag changed. | `dsh-plan-mode/lib/types/index.d.ts` |
| `request/context` | `RequestContext` | Route metadata for the next request (log-only). | `dsh-session/lib/types/types.d.ts` |
| `request/header` | `{ header: EpochHeader; reason: RequestHeaderReason; startsSeries?: true; }` | Full header for the next request (log-only). | `dsh-session/lib/types/types.d.ts` |
| `sandbox/mode` | `{ mode: SandboxMode; source?: 'delegation'; }` | The session sandbox mode changed. | `dsh-sandbox-policy/lib/types/session-mode.d.ts` |
| `schedule/change` | `ScheduleChange` | A schedule record changed. | `dsh-schedule/lib/types/types.d.ts` |
| `session-log-deepseek/delivery-accepted` | `{ sessionId: import('@deepseek-ai/dsh-session/types').SessionId; sessionFormatVersion?: number; throughSeq: import('@deepseek-ai/dsh-session/types').SessionSeq; }` | Records that the configured endpoint accepted one delivery through `throughSeq`. | `dsh-session-log-deepseek/lib/types/types.d.ts` |
| `session/end-seed` | `{ inherited?: true; }` | Marks the end of a constructor seed (resume/fork/replay boundary). | `dsh-session/lib/types/types.d.ts` |
| `session/title` | `SessionTitleEventData` | Latest-wins session title snapshot (log-only). | `dsh-session-title/lib/types/index.d.ts` |
| `session/title-llm-request` | `SessionTitleLlmRequestEventData` | Log-only pre-dispatch record of one session-title model request. | `dsh-session-title-llm/lib/types/index.d.ts` |
| `step/end` | `{ turn: number; step: number; }` | Closes one step. | `dsh-session/lib/types/types.d.ts` |
| `step/start` | `{ turn: number; step: number; }` | Opens one step (one model call plus the tool executions it requested). | `dsh-session/lib/types/types.d.ts` |
| `subagent/catalog` | `SubagentCatalogEvent` | The subagent catalog projection snapshot. | `dsh-subagent/lib/types/catalog.d.ts` |
| `subagent/descriptor` | `SubagentDescriptorData` | A subagent descriptor became durable on the parent session. | `dsh-subagent/lib/types/descriptor.d.ts` |
| `subagent/model-selection-policy` | `{ allowedModels: AllowedModelRoute[]; }` | Records that this session's delegation tool exposes child provider, model, and reasoning-effort selection. | `dsh-tool-subagent/lib/types/model-selection-state.d.ts` |
| `system/message` | `{ turn: number; step: number; message: SystemMessage; }` | The rendered system prompt on the model-visible surface. | `dsh-session/lib/types/types.d.ts` |
| `todo/write` | `{ todos: TodoItem[]; }` | Whole-list todo snapshot; latest write wins (log-only UI state). | `dsh-tool-todo/lib/types/types.d.ts` |
| `tool-workflow/agent-end` | `ToolWorkflowAgentEndData` | Records one member settlement. | `dsh-tool-workflow/lib/types/types.d.ts` |
| `tool-workflow/agent-start` | `ToolWorkflowAgentStartData` | Records one published workflow member. | `dsh-tool-workflow/lib/types/types.d.ts` |
| `tool-workflow/run-end` | `ToolWorkflowRunEndData` | Closes one workflow record after cleanup. | `dsh-tool-workflow/lib/types/types.d.ts` |
| `tool-workflow/run-start` | `ToolWorkflowRunStartData` | Opens one top-level workflow record. | `dsh-tool-workflow/lib/types/types.d.ts` |
| `tool/call` | `{ turn: number; step: number; callId: ToolCallId; name: string; arguments: string; }` | The model requested one tool invocation; `arguments` is the raw JSON string. | `dsh-session/lib/types/types.d.ts` |
| `tool/ptc-dispatch` | `PtcDispatchEventData` | One bridged sub-dispatch SETTLING: the pairing ids (matching the `tool/ptc-dispatch-start` with the same `subCallId`), the tool `name` with the same JSON-normalized `arguments`, and the sub-call's complete model-facing... | `dsh-tools/lib/types/types.d.ts` |
| `tool/ptc-dispatch-start` | `PtcDispatchStartEventData` | One sub-dispatch STARTING inside a `run_code` program: the parent `run_code` call id, the opaque sub-call id (new calls use `<parent>:ptc:<n>`, numbered in submission order), and the tool `name` with its JSON-normalized... | `dsh-tools/lib/types/types.d.ts` |
| `tool/result` | `{ turn: number; step: number; message: ToolResultMessage; error?:{ name: string; code: string; } ; meta?: JsonValue; }` | A completed tool call's model-facing result, optional failure identity, and optional tool-private meta. | `dsh-session/lib/types/types.d.ts` |
| `turn/end` | `{ turn: number; reason: TurnEndReason; }` | Closes a turn with the reason that ended it. | `dsh-session/lib/types/types.d.ts` |
| `turn/start` | `{ turn: number; }` | Opens a turn before the loop claims queued input or runs pre-step. | `dsh-session/lib/types/types.d.ts` |
| `user/message` | `UserMessage` | A user-role message on the model-visible surface: a human prompt, synthetic injected context, or a goal continuation round. | `dsh-session/lib/types/types.d.ts` |
| `web/deepseek-search-llm-request` | `DeepSeekSearchLlmRequest` | Secret-free auxiliary DeepSeek search request recorded before dispatch. | `dsh-web-search-deepseek/lib/types/provider.d.ts` |
| `team/member` | `{ version; teamId; member }` (untyped here) | field names recovered from dsh-session-format-v0-to-v1 eligibility/disposition table only | (no declaration in this install) |
| `team/message/delivered` | `{ version; teamId; messageId; targetId }` (untyped here) | field names recovered from dsh-session-format-v0-to-v1 only | (no declaration in this install) |
| `team/message/queued` | `{ version; teamId; message }` (untyped here) | field names recovered from dsh-session-format-v0-to-v1 only | (no declaration in this install) |
| `team/task` | `{ version; teamId; task }` (untyped here) | field names recovered from dsh-session-format-v0-to-v1 only | (no declaration in this install) |

**Reading order.** Durable events arrive in non-decreasing `seq`. The `session/follow` opening snapshot gives you a contiguous window ending at `cursor` plus `hasMore`; older history is fetched with `session/page` using `throughSeq` (from the snapshot cursor) and then `beforeSeq` (the smallest `seq` you already hold). `assistant/message` and `assistant/attempt` are *settlements*: they replace any live `assistant-stream` frames for the same `attemptId`.

### 4.4 `session/control` frames

`session/control` takes no arguments and streams host-wide live state. Its first frame is always a `baseline`; afterwards you get `queue`, `jobs`, and `projection` increments. Frame union is `SessionControlFrame` (Section 3.4).

### 4.5 `workspace/follow` and `workspaceFiles/changes` frames

- `workspace/follow` (no args): first frame is always `{type:'baseline', value:{items, archivedSessionIds}}`, then `upsert` / `remove` / `order` / `archived` increments. Frame union is `WorkspaceFollowFrame` (Section 3.6).
- `workspaceFiles/changes` (`workspaceFileScopeId`): first frame is always `{kind:'ready'}` once the workspace root is resolved, then `{kind:'change', change}` frames whose `change` is either `{absolutePath, version}` or `{absolutePath, absent:true}`. Frames report *observations*, not deltas — if you already hold the same `version`, ignore the frame.

### 4.6 Assistant live-stream frames

Only produced when `session/follow` is opened with `"assistantStream": true`. Three frame variants (Section 3.4):

- `start` — a new attempt began (`attemptId`, `revision`, `startedAfterSeq`, `turn`, `step`).
- `chunk` — one raw `StreamChunk` at a dense `index`. Live chunks are the **adapter's raw stream protocol** (`block-start`, `text-delta`, `reasoning-delta`, `tool-call-delta`, `block-end`, `usage`, `finish`), not assembled messages.
- `end` — terminal marker with `outcome: {kind:'committed', eventType, seq}` or `{kind:'abandoned'}`.

The opening snapshot may carry `assistantStream: {revision, activeAttempt?}`, where `activeAttempt.stream` is a **compacted** `AssistantStreamRecord[]` (packed `text-chunks` / `reasoning-chunks` / `tool-call-chunks` runs plus raw `chunk` records). Live frames and compacted baselines therefore use *different* encodings for the same content; a client must handle both.

---

## 5. Session projections

`session/list` items carry `projections: {asOfSeq, values}` and `session/control` streams `projection` updates; `session/follow`'s snapshot carries `projections: {asOfSeq, values}`. `values` is a partial map — absent keys are *unknown at that cut*, not empty.

| Key | Type | Declared in |
|---|---|---|
| `agentPreset` | `string \| null` | `dsh-agent-presets/lib/types/types.d.ts` |
| `contextBreakdown` | `ContextBreakdownProjection` | `dsh-token-meter/lib/types/projection.d.ts` |
| `contextPressure` | `ContextPressureProjection` | `dsh-token-meter/lib/types/projection.d.ts` |
| `goal` | `GoalProjection \| null` | `dsh-goal/lib/types/types.d.ts` |
| `imageLimits` | `ImageAttachmentLimits` | `dsh-api-session-controller/lib/types/types.d.ts` |
| `inbox` | `InboxWireState` | `dsh-agent/lib/types/types.d.ts` |
| `modelSelection` | `ModelSelectionProjection` | `dsh-api-session-controller/lib/types/types.d.ts` |
| `permissions` | `PermissionSelect` | `dsh-permission-presets/lib/types/types.d.ts` |
| `plan` | `PlanProjection` | `dsh-plan-mode/lib/types/types.d.ts` |
| `schedule` | `readonly ScheduleRecord[]` | `dsh-schedule/lib/types/types.d.ts` |
| `sessionListMetadata` | `SessionListMetadata` | `dsh-api-session-controller/lib/types/types.d.ts` |
| `sessionStats` | `SessionStatsProjection` | `dsh-session-stats/lib/types/types.d.ts` |
| `subagent` | `SubagentIdentityProjection \| null` | `dsh-subagent/lib/types/projection-types.d.ts` |
| `subagentCatalog` | `SubagentCatalogEntry[]` | `dsh-subagent/lib/types/projection-types.d.ts` |
| `subagentTiming` | `SubagentTimingProjection` | `dsh-subagent/lib/types/projection-types.d.ts` |
| `title` | `string \| null` | `dsh-session-title/lib/types/types.d.ts` |
| `todos` | `TodoItem[] \| null` | `dsh-tool-todo/lib/types/types.d.ts` |
| `tokenUsage` | `TokenUsageProjection` | `dsh-token-meter/lib/types/projection.d.ts` |
| `turnOutline` | `readonly TurnOutlineEntry[]` | `dsh-session-turn-outline/lib/types/types.d.ts` |

Projection updates (`{type:'projection', sessionId, key, value, seq}`) carry a durable watermark `seq`; drop an update whose `seq` is older than what you already applied for that `(sessionId, key)`.

---

## 6. Gotchas

1. **`payload.args` is a named-field object, not an array.** `{"args":{"request":{…}}}` — never `{"args":[{…}]}`.
2. **The cookie is authority-bound.** Connect to the literal `127.0.0.1:<port>` from `endpoint.json`. `localhost` returns 401 with a perfectly valid cookie (verified).
3. **Re-read `endpoint.json` before each connect.** The token rotates on restart and `Set-Cookie` must be re-exchanged.
4. **Do not follow the 303.** Read `Set-Cookie` off the 303 response body-less redirect. The redirect target is the SPA.
5. **Unary errors are HTTP 200.** Only malformed routing (unknown method, `GET`) yields 404, with a plain-text `not found` body. Branch on `result.ok`, not on the HTTP status.
6. **Descriptor validation is strict both ways.** Unexpected fields are rejected, not ignored. This is also the best way to discover an endpoint's exact signature at runtime (Section 1.9).
7. **Optional args are invisible to the missing-field message.** `settings/*`'s `expectedRevision` and `directoryPicker/list`'s `path` are optional despite appearing in the signature; the probe error will not list them as missing.
8. **`session/follow` yields two different things on one stream.** Opening it with `assistantStream: true` interleaves durable `SessionEventEntry` items with `{type:'assistant-stream'}` items. If you only want durable history, omit `assistantStream`.
9. **`maxMessages` must be a positive safe integer.** `0` is rejected with `gateway/bad-request` / `"maxMessages must be a positive safe integer"`.
10. **`session/page` needs `throughSeq`.** Get it from the `session/follow` snapshot's `cursor`. Addresses are structured: `{kind:'session', sessionId}` or `{kind:'subagent', parentSessionId, childSessionId, mode}`.
11. **`session/list`'s `cursor` is accepted but ignored in this deployment** — a bogus cursor returns the same full list (verified). There is no `nextCursor` in `SessionListValue`. Do not build pagination on it.
12. **The `session/follow` snapshot can be very large.** A real session returned 279 records / ~670 KB compact JSON and `hasMore: true` in a single opening frame. Budget for it and stream-parse.
13. **Timestamps are unix epoch milliseconds** (`updatedAt`, `time`, `createdAt`). `WorkspaceView.createdAt`/`updatedAt` are the exception: ISO-8601 strings.
14. **`session/search` is disabled in this deployment** (`"session search is disabled: this deployment configures the session-query index with openAt \"never\""`). Treat it as an optional capability, not a given.
15. **`directoryPicker/list` and `directoryPicker/createDirectory` are unavailable here.** The composed picker serves the `native` capability, so the browse verbs refuse with `directory-picker/unavailable` / `{"capability":"native"}`. Only `directoryPicker/pick` works — **and it opens a modal OS dialog on the host machine**, so a client should never call it speculatively.
16. **`workspaceFiles` uses two path vocabularies.** `read`, `readBytes`, `readAll`, `stat`, and `changes` take an **absolute** filesystem path (`absolutePath` in `WorkspaceFileStat`); `list` takes a **workspace-relative** path (`""` for the root) and returns workspace-relative paths. Passing a relative path to `stat` yields `workspace-file/not-found` (verified).
17. **`workspaceFileScopeId` is an agent/session id**, and the lookup argument is resolved server-side. `workspaceFiles/*` will refuse a session that is not live.
18. **Credential reads never return values.** `credentials/describe` returns only `{configured, source?, writable}` per ref. `credentials/set` is a one-way write. Never log the value you send.
19. **`settings/*` writes are optimistic-concurrency guarded.** Read `SettingsNamespaceView.revision`, pass it back as `expectedRevision`; a mismatch yields `settings/conflict` with `{expected, actual}` and you must re-read and re-apply.
20. **Secret settings fields are redacted.** `SettingsNamespaceView.secrets` lists schema-declared secret slots as `{path, set}` — the value never crosses the wire.
21. **Binary content is base64 in JSON.** `SessionAttachmentValue.data` and `WorkspaceFileBytes.data` are base64 strings; `WorkspaceFileBytes.bytes` is the *complete file size*, not the window size.
22. **`session/control` can be chatty and host-wide.** Its baseline contains queues, jobs, and projections for *every* live session. A mobile client should filter by the session it is displaying.
23. **The `$events` `clientId` is per-connection-generation.** A reconnect invalidates the old id; `$events/result` answers must use the current one, and the host replays still-pending waterfalls to the new generation.
24. **Answer every waterfall.** An unanswered `approval/request` or `user-questions/request` blocks the host-side operation. If you cannot answer, send `{kind:'next'}` (delegate) rather than nothing.
25. **`Origin`, when present, must match the server authority.** A native client should simply omit `Origin`; sending a wrong one yields 403.
26. **No `Content-Type` flexibility.** The unary route wants `application/json`; a missing/incorrect type is not accepted by the shared `/api` channel.
27. **`$events` requires literally `{"args":{}}`.** Any extra key — even a `null` — is rejected by the gateway (`"forwarded Remote event stream requires an empty args object"`).

---

## 7. Discrepancies, gaps, and unresolved items

### 7.1 The brief's endpoint count is inconsistent with its own list

The task text says "The full endpoint list (36 methods)" but the enumerated list contains **45**. The installed packages expose exactly **45** package endpoints (4 streams + 41 unary), which is what the enumeration names. This document catalogues **47** rows: those 45 plus the two gateway-internal endpoints `$events` and `$events/result`, which are not in any package FaceModel but are required to implement the event channel.

### 7.2 `team/*` event payloads are not declared in this installation

`KNOWN_SESSION_EVENT_TYPES` includes `team/member`, `team/message/delivered`, `team/message/queued`, and `team/task`, but **no installed package declares their `SessionEventMap` members**, so no payload type can be copied. The only field information available comes from the session-format migration table in `dsh-session-format-v0-to-v1`, which lists the top-level field names:

- `team/member`: `version`, `teamId`, `member`
- `team/message/delivered`: `version`, `teamId`, `messageId`, `targetId`
- `team/message/queued`: `version`, `teamId`, `message`
- `team/task`: `version`, `teamId`, `task`

These are **not** authoritative type declarations; treat them as best-effort. A client should treat unknown `team/*` events as opaque unless it needs them.

### 7.3 Source vs. live-server disagreements found

| Area | Source says | Live server | Resolution |
|---|---|---|---|
| `session/list` pagination | `SessionListRequest.cursor?: string` | `cursor` accepted but **ignored**; no `nextCursor` returned | Documented as inert in this deployment; do not rely on it. |
| `directoryPicker/list` args | `path: string \| undefined` | `path` is **optional** on the wire (absent = home dir per the controller JSDoc), but the verb refuses with `directory-picker/unavailable` because the composed backend is `native` | Both facts documented. |
| `settings/*` args | `expectedRevision: number \| undefined` | Optional on the wire; omitted from the "missing" list | Marked optional in `dsh-rpc-catalog.json`. |
| `$events/result` args | `RemoteEventResult` with `{clientId,eventId,outcome}` | **Not** descriptor-validated; custom error text | Documented separately. |
| `session/follow` assistant frame `chunk` | `SessionAssistantStreamFrame.chunk: JsonValue` | Carries a raw `StreamChunk`; the *baseline* carries compact `AssistantStreamRecord`s | Documented in Section 4.6. |
| `POST /api/<stream-method>` | Streams are WS-only | Returns HTTP 404 `not found` | Route is WS-only, confirmed. |

### 7.4 Features that could not be exercised read-only

The following are catalogued from source + descriptor probes only; their success responses were **not** captured because doing so would mutate state (the brief forbids it) or would block on host UI:

`session/prompt`, `session/cancel`, `session/create`, `session/fork`, `session/rename`, `session/selectModel`, `session/updateQueue`, `session/openWorkspacePath`, all `workspace/*` mutations, `directoryPicker/pick` and `directoryPicker/createDirectory`, `settings/update`, `settings/replace`, `settings/mutate`, `settings/openSettingsDocument`, `settings/openAgentPresetDirectory`, `credentials/set`, `credentials/unset`.

`session/search` was attempted and is disabled at the deployment level (Section 6.14).

The two waterfalls (`approval/request`, `user-questions/request`) were not triggered, so their payload types are copied from source rather than from a capture. The `$events/result` **success** envelope was captured by answering a synthetic, non-existent `eventId` for a live client generation (a no-op on the host); see `docs/artifacts/samples/events_result_ack.json`.

### 7.5 Not covered

- The `/api` JSON body cap (default **300 MiB** per `ConnectionConfig.maxRequestBodyBytes`) and the `workspaceFile` `maxLines`/`maxBytes` caps are configuration-dependent and were not probed.
- Non-loopback hosting and `--trusted-host` were not exercised (this host is loopback-only).
- Client plugin/HMR routes (`/api/client-modules`, resource routes) are outside the scope of this Remote API reference.
- The `$events` forwarded allowlist is complete for **this** deployment; a differently-composed host may forward a different set.

---

## Appendix A — Reproduction

All live captures are in `docs/artifacts/samples/` with a `README.md` explaining the exact command used for each. The machine-readable endpoint catalog is `docs/dsh-rpc-catalog.json`.

Generation pipeline (throwaway scripts, kept out of the repo):

1. Read the host **FaceModel** from `<pkg>/lib/typert.host.js` (`TYPERT.invocations`) for declared parameter wire names and `mode: 'stream' | undefined`.
2. Read `<pkg>/lib/typert.remote-client.d.ts` for the generated TS request/response signatures.
3. `GET /?token=…` to capture the cookie, then `POST /api/<method>` with `{"args":{"__probe__":1}}` for **every** endpoint to confirm existence, kind, and the required-vs-optional field split.
4. Open the WS mux for `$events`, `session/control`, `session/follow` (idle and running), `workspace/follow`, and `workspaceFiles/changes` and record raw frames.
5. Extract declarations verbatim from the `.d.ts` files by name and splice them into Section 3 unmodified.

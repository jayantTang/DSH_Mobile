# plugins/ — 电脑侧插件

> 面向：使用者与实现者 · 状态：stable · 最近核对：2026-09-20

## mobile-link — the PC half of DLP v1

A DSH host plugin that dials the DLP relay over WSS and serves the iOS client's
session and event traffic from the local DSH instance. One relay socket, one DSH
multiplexing socket, any number of phones.

```
plugins/mobile-link/
├── package.json          # type: module, dsh.bundle.patch, exports
├── cordis.patch.yml      # bundle patch: the loader row + the config block
├── lib/
│   ├── index.js          # cordis plugin: lifecycle + route registration
│   ├── link.js           # MobileLinkAgent — relay dial, heartbeats, reconnect
│   ├── router.js         # per-device routing, $events streams, waterfall dedupe
│   ├── dsh-client.js     # local DSH discovery, auth, unary RPC, mux socket
│   ├── pairing.js        # relay /pair/code call + QR payload
│   ├── dlp.js            # pure frame codec, stream table, dedupe, backoff
│   ├── ws.js             # WebSocket adapter (global WebSocket, `ws` fallback)
│   ├── state.js          # ~/.dsh/mobile-link/agent.json (mode 0600)
│   ├── routes.js         # GET /mobile-link/status, POST /mobile-link/pair-code
│   └── cli.js            # standalone runner for dev/tests/headless use
└── test/                 # node --test (no DSH, no network)
```

Design deviations and spec gaps are recorded in
[`docs/RELAY-NOTES.md`](../docs/RELAY-NOTES.md); the connector-specific ones are in
[`docs/notes/connector.md`](../docs/CONNECTOR-NOTES.md).

## Install

```bash
# from the repository root — the leading ./ matters: DSH anchors relative specs
# against your current directory, otherwise pnpm would resolve it inside the profile
dsh plugin --profile web add ./plugins/mobile-link

# an absolute path works too
dsh plugin --profile web add "$PWD/plugins/mobile-link"
```

`dsh plugin` forwards to pnpm inside the profile, then appends the package to
`dsh.profile.bundles` because it declares `dsh.bundle.patch`. Restart DSH (or
reload the profile) and the plugin joins the tree.

Verify:

```bash
curl -s http://127.0.0.1:54499/mobile-link/status -H "cookie: <your dsh-auth cookie>"
# or open the DSH UI and read the same route from the browser console
```

## Pair a phone

1. **Provision the PC identity** (once). On the relay host:

   ```bash
   /opt/dsh-relay/.venv/bin/python /opt/dsh-relay/admin.py --db /var/lib/dsh-relay/state.db \
       agent-register --account acc_xxx --name "MacBook Pro" \
       --relay wss://relay.example.com/dsh-link \
       --write-config ~/.dsh/mobile-link/agent.json
   ```

   The relay URL is the public base, **including its path prefix**
   (`/dsh-link`). The connector keeps that path and appends `/link/agent`, so it
   dials `wss://relay.example.com/dsh-link/link/agent`; `/pair/code` is joined
   the same way.

   Run that as your desktop user so the file lands in your own home directory
   with mode `0600`. It contains `relayUrl`, `agentId` and `agentSecret`:

   ```json
   { "relayUrl": "wss://relay.example.com/dsh-link", "agentId": "agt_…", "agentSecret": "as_…" }
   ```

2. **Mint a pairing code** — either from the desktop:

   ```bash
   curl -sX POST http://127.0.0.1:54499/mobile-link/pair-code \
        -H 'content-type: application/json' -H "cookie: <dsh-auth cookie>" -d '{}'
   ```

   or from the relay host: `admin.py … code-mint --agent agt_…`.

   The response carries `code` (`XXXX-XXXX`), `expiresAt` and a
   `dsh://pair?relay=<relay-url>&code=<code>` payload to render as a QR code.
   Codes are one-time and expire after 10 minutes. From a shell you can also
   mint one without the desktop:

   ```bash
   node lib/cli.js --mint-pair-code \
     --relay wss://relay.example.com/dsh-link \
     --agent-id agt_… --agent-secret as_…
   ```

3. Scan it with the iOS app. The app calls `POST /pair/claim`, stores the device
   token, and connects to `wss://…/link/device`.

## Routes

Both routes sit behind DSH's own request fence
(`ctx.get('connection')?.requestRejection?.(req)`: Host/Origin check + browser
auth), exactly like `dsh-plugin-desktop-shell`.

### `GET /mobile-link/status`

```json
{
  "ok": true, "enabled": true, "protocolVersion": 1,
  "state": "connected", "connected": true,
  "relayUrl": "wss://relay.example.com/dsh-link",
  "agentId": "agt_…", "agentName": "MacBook Pro",
  "stateFile": "/Users/you/.dsh/mobile-link/agent.json",
  "dsh": { "endpoint": "http://127.0.0.1:54499", "source": "endpoint.json:…",
           "port": 54499, "authenticated": true, "muxUp": true, "error": null },
  "devices": [{ "deviceId": "dev_…", "name": "iPhone", "model": "iPhone17,1",
                "connectedAt": 1790000000000, "eventsReady": true, "openStreams": 1 }],
  "deviceCount": 1, "openStreams": 1, "pendingWaterfalls": 0,
  "lastError": null, "startedAt": 1790000000000, "connectedAt": 1790000000000,
  "reconnectAttempts": 0
}
```

### `POST /mobile-link/pair-code`

Body (optional): `{"ttlMs": 600000}` (capped at 1 hour). Returns
`{"ok":true,"code":"XXXX-XXXX","expiresAt":…,"ttlMs":…,"relayUrl":…,"agentId":…,"qrPayload":"dsh://pair?relay=…&code=…"}`.
`502` with `code: "relay/unavailable"` when the relay cannot be reached.

## Configuration

Everything lives in the plugin's `config` block in `cordis.patch.yml` (or the
profile's own patch layer, which is applied after it):

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | `false` keeps the plugin loaded but stops the outbound link |
| `relayUrl` | `wss://relay.example.com/dsh-link` | relay base, **including its path prefix**. The connector keeps the path and appends the endpoint, so the default dials `wss://relay.example.com/dsh-link/link/agent`; a trailing slash is tolerated and `ws://`/`http://` are accepted for local testing |
| `agentId` | — | overrides `agent.json` |
| `agentSecret` | — | overrides `agent.json` |
| `stateFile` | `~/.dsh/mobile-link/agent.json` | identity file |
| `dshUrl` | — | explicit local DSH base URL; skips `endpoint.json` discovery |
| `endpointFile` | `$DSH_HOME/desktop-shell/endpoint.json` | discovery file |
| `heartbeatMs` | `20000` | DLP `ping` cadence to the relay |
| `pongTimeoutMs` | `60000` | no `pong` for this long ⇒ reconnect |
| `maxBackoffMs` | `30000` | reconnect backoff ceiling (1s → 2s → … with ±20 % jitter) |
| `pairTtlMs` | `600000` | default lifetime for `/mobile-link/pair-code` |

Environment overrides (useful for headless runs):
`DSH_MOBILE_LINK_RELAY`, `DSH_MOBILE_LINK_AGENT_ID`, `DSH_MOBILE_LINK_AGENT_SECRET`.

## Standalone / headless

The same agent runs without DSH, which is how the integration test drives it:

```bash
node lib/cli.js --relay ws://127.0.0.1:8787 \
  --agent-id agt_… --agent-secret as_… \
  --dsh-url http://127.0.0.1:54499 \
  --status-file /tmp/mobile-link.json --log-level debug

# print one pairing code (and its dsh:// payload) as JSON and exit
node lib/cli.js --mint-pair-code --relay ws://127.0.0.1:8787/dsh-link \
  --agent-id agt_… --agent-secret as_…
```

Each state transition prints one machine-readable line:
`MOBILE_LINK_STATE {"state":"connected","connected":true,…}`.

## Tests

```bash
cd plugins/mobile-link
node --test test/*.test.js        # 62 tests: codec, URL joining, stream mapping,
                                  # dedupe, routing, identity persistence, pairing
                                  # helper, and plugin wiring through the real
                                  # cordis runtime
```

The full middle-tier proof lives in `../../relay/tests/integration_e2e.py`.

## How it behaves

* **Discovery** — re-reads `endpoint.json` on every (re)connect, so a DSH restart
  is picked up automatically. Falls back to `$DSH_WEB_URL`, then
  `http://127.0.0.1:54499`.
* **Auth** — `GET <base>/?token=…` with `redirect: 'manual'`, captures the
  `dsh-auth-*` cookie, and re-does the exchange (after re-reading discovery) on
  any `401`. The cookie is bound to the authority, so the agent always dials
  `127.0.0.1:<port>` and never rewrites `Host`.
* **One mux socket** — every logical stream from every device shares one
  `/api/remote.mux` WebSocket; DLP ids are namespaced per device, so two phones
  can both call a stream `"2"`.
* **Per-device `$events`** — each device gets its own `$events` stream and
  therefore its own `clientId`; waterfalls are answered first-answer-wins with a
  TTL-pruned claim set.
* **Cleanup** — a device disconnect cancels every stream it owned; a DSH mux
  failure notifies the affected devices and re-arms their `$events` streams.
* **Reconnect** — exponential backoff 1s → 30s with ±20 % jitter, re-reading
  discovery and re-authenticating as needed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `mobile-link: no agent identity` | run `admin.py agent-register --write-config ~/.dsh/mobile-link/agent.json`, or set the env vars |
| status shows `state: "backoff"` and `lastError: "unknown or disabled agent token"` | the secret was rotated; re-run `agent-register --write-config` |
| status shows `dsh.error: "no DSH launch token found"` | DSH has not written `endpoint.json` yet, or you set `dshUrl` without a `?token=` |
| `401` from DSH keeps repeating | restart DSH so a fresh `endpoint.json` exists; the agent re-reads it on every reconnect |
| `POST /mobile-link/pair-code` returns `relay/unavailable` | the relay is down or `relayUrl` is wrong; the agent itself needs no relay to *serve* devices |
| the link never connects and the relay logs nothing | the configured `relayUrl` is missing its `/dsh-link` path prefix — the connector keeps the path it is given and never invents one |
| routes return `403` | DSH's fence rejected the request (wrong Host/Origin or missing cookie); call it from the DSH UI origin |
| `no WebSocket implementation available` | DSH is running on Node < 22 and `ws` is not resolvable from the profile; upgrade Node |

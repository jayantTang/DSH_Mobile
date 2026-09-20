# Connector NOTES — decisions the spec did not pin down

> 面向：实现者 · 状态：stable · 最近核对：2026-09-20

Protocol-level findings (including the stale `session/follow` example and the
unnecessary `--trusted-host` requirement) are in
[`relay.md`](RELAY-NOTES.md). This file records the connector-side
choices.

## 1. The plugin requires no DSH services (`inject` is empty)

`dsh-plugin-desktop-shell` declares `inject = ['webServer', 'connection']`, which
makes those services hard requirements for the plugin to load at all. This plugin
deliberately does not: the DLP link must keep working if a future DSH renames or
drops a host service. Only `ctx.logger`, `ctx.effect` and `ctx.get` are used, all
optional-chained, and the HTTP routes are attached with

```js
ctx.inject(['webServer'], (scope) => registerMobileLinkRoutes(scope, …))
```

so the link starts regardless and only the routes depend on `webServer`.

## 2. The request fence fails closed for `/pair-code`

`GET /mobile-link/status` mirrors the desktop-shell helper exactly: if
`ctx.get('connection')` is missing it stays readable (it is diagnostic).
`POST /mobile-link/pair-code` mints a credential, so when the `connection`
service cannot be reached it answers `403` instead of allowing the request.
No extra per-process header token is used, because DSH's own fence already
authenticates the browser session.

## 3. WebSocket client implementation

The agent uses `globalThis.WebSocket` (Node ≥ 22) with its non-standard
`{ headers }` option, which is how the bearer token is sent without putting a
secret in the URL. If the global is absent it falls back to the `ws` package
resolved from the DSH profile. Both are adapted to the same small interface in
`lib/ws.js`; if neither exists the agent reports
`no WebSocket implementation available` instead of failing obscurely.

## 3b. The relay URL keeps its path prefix

The relay is published as `https://relay.example.com/dsh-link`, so the
configured `relayUrl` carries a path. `joinRelayPath` / `agentEndpoint` /
`pairCodeEndpoint` append `link/agent` and `pair/code` **to** that path instead of
replacing it, and a trailing slash is normalised away:

| configured `relayUrl` | dialled agent endpoint | pairing endpoint |
|---|---|---|
| `wss://relay.example.com/dsh-link` | `wss://relay.example.com/dsh-link/link/agent` | `https://relay.example.com/dsh-link/pair/code` |
| `wss://relay.example.com/dsh-link/` | `wss://relay.example.com/dsh-link/link/agent` | `https://relay.example.com/dsh-link/pair/code` |
| `wss://host` | `wss://host/link/agent` | `https://host/pair/code` |
| `ws://127.0.0.1:8787` | `ws://127.0.0.1:8787/link/agent` | `http://127.0.0.1:8787/pair/code` |

Covered by `test/dlp.test.js` and `test/state.test.js`; the integration run mounts
the relay under `/dsh-link` and drives the real agent through it.

The pairing deep link is `dsh://pair?relay=<relay-url>&code=<code>` — the full
prefixed URL, so the phone reaches `/pair/claim` and `/link/device` under the same
base. `agentId` stays a sibling JSON field rather than a query parameter.

## 4. The agent always dials loopback

Whatever host `endpoint.json` contains, the agent keeps only the port and dials
`http://127.0.0.1:<port>`, because the `dsh-auth-*` cookie is bound to the
authority it was issued for. An explicit `dshUrl` override is honoured verbatim
(that is the escape hatch for a deliberately non-loopback setup).

## 5. Deliberately no client bundle and no UI

The plugin ships no browser code and no `tapIndex` injection, unlike the
desktop-shell plugin. The desktop UI is expected to change; a JSON status route
plus the QR payload string lets any UI (or a future iOS "pair from desktop"
flow) consume it without pinning the plugin to a DOM shape.

## 6. Identity is read on every reconnect

`resolveIdentity()` runs inside each connection attempt rather than once at boot,
so an operator who provisions `agent.json` after DSH has already started is
picked up automatically, and a rotated secret is used on the next reconnect
instead of requiring a DSH restart.

## 7. `$events` delivery channel

As described in `relay.md` §10: unsolicited `event` frames until the
device opens `$events`, then `item` frames on that stream id, with the cached
`ready` item replayed as the first item so the device always learns its
`clientId`.

## 8. Unverifiable in this environment

* No real iOS client exists yet, so the device side of the protocol is exercised
  by the Python fake in `../relay/tests/integration_e2e.py` and by the Node unit
  tests — not by the shipping app.
* The public WSS path (`wss://relay.example.com/dsh-link/link/agent`) has not
  been exercised end to end: nothing is deployed yet. Everything was tested over
  plain `ws://` on loopback **including the `/dsh-link` path prefix**, which is
  the same code path minus TLS. The TLS/WebSocket termination itself is Caddy's,
  and the spliced configuration validates with a real `caddy` binary
  (`relay/tests/test_caddy_splice.py`).
* The systemd unit and `deploy.sh` were syntax-checked and their Caddy splice was
  exercised against a scratch Caddyfile, but nothing was installed on
  `relay.example.com` (deployment is a separate, user-approved step).

# Relay NOTES — deviations and fills for DLP v1

[`../RELAY-PROTOCOL.md`](../RELAY-PROTOCOL.md) is treated as normative. Everything below is either
(a) a place where the spec was silent and a concrete choice was required, or
(b) a place where following the spec literally would not work. Each entry says
what the spec says, what we do, and why.

## 1. Spec §7 (“电脑侧必须声明 `dsh web --trusted-host relay.example.com`”) is unnecessary — not implemented

The spec assumes DSH sees the relay's `Host`. It never does: the connector dials
`127.0.0.1:<port>` directly and **never rewrites `Host`**, which is also what
§4.1.2 demands (the auth cookie is bound to the authority). DSH's trust fence
sees a loopback authority and accepts the request, so `--trusted-host` is not
required and the agent does not demand it.

The agent therefore verifies the things that actually matter on boot: it re-reads
`endpoint.json`, performs the token → cookie exchange, and reports the failure
verbatim in `GET /mobile-link/status` (`dsh.error`) and in its logs. If DSH is
started on a non-loopback authority via the explicit `dshUrl` override, the
override is honoured as-is.

## 2. Added endpoint `POST /pair/code` (spec §2 has no way for the connector to obtain a code)

§2.1 says the pairing code is “由电脑侧连接器生成并展示”, but §2's endpoint table
only exposes `/pair/claim` and `/pair/refresh`, and the code must be *validated*
by the relay — so the relay has to be the one that mints it.

`POST /pair/code` with `Authorization: Bearer <agentSecret>` and an optional
`{"ttlMs": 600000}` returns `{"ok":true,"code":"XXXX-XXXX","expiresAt":<ms>,"agentId":...}`.
The connector calls it from `POST /mobile-link/pair-code`. Codes are one-time and
default to 10 minutes.

## 2b. The QR deep link is `dsh://pair?relay=…&code=…`

The spec does not name a QR payload scheme. The desktop route returns
`dsh://pair?relay=<relay-url-with-its-path-prefix>&code=<code>` (the iOS client
parses `dsh://`). The `relay` value keeps the full path prefix so the phone
reaches `/pair/claim` and `/link/device` under exactly the same base. The
connector also returns `agentId` as a sibling JSON field; it is deliberately not
part of the deep link, because the phone learns it from the `/pair/claim`
response.

## 2c. Path-prefix publishing and `--base-path`

The relay is published under `https://relay.example.com/dsh-link` rather than
on its own hostname. Caddy's `handle_path /dsh-link/*` strips the prefix, so the
relay's own routes stay root-relative; `--base-path /dsh-link` additionally
registers every route under the prefix so the relay also works when a front end
forwards the path verbatim. Both forms are always live, and both are covered by
`tests/test_base_path.py`. CORS preflight is a middleware rather than a
catch-all route, so an unknown path still answers 404 instead of a confusing 405.

## 3. Added relay control frames `deviceAttach` / `deviceDetach` and the `deviceId` field

§5 requires the relay to “通知 agent 清理该 device 的流”, but §3 has no frame for
it — and it *cannot* be inferred by the agent, because one agent WebSocket
multiplexes every device, so an inbound frame is not self-identifying.

* Relay → agent, on connect/disconnect of a device:
  `{"t":"deviceAttach","deviceId":"dev_…","device":{"name":…,"model":…}}` and
  `{"t":"deviceDetach","deviceId":"dev_…","reason":…}`.
* Every frame forwarded **from** a device carries an extra `"deviceId"` key so
  the agent knows which device owns it; every frame the agent sends **to** a
  device must carry the same key so the relay can route it. The relay strips the
  key before the frame reaches the device, so the device sees the agent's frame
  byte-for-byte.

This is additive and compatible with §3's forward-compatibility rule (unknown
`t` is ignored; unknown JSON keys are not consulted). Neither frame changes any
DSH semantics, and the `id` of an RPC/stream is never rewritten.

The relay also *forwards* unknown frame types instead of dropping them, so a
newer device/agent pair keeps working through an older relay; it only ignores
those frames itself.

## 4. `hello` is accepted but redundant

§2 says `agentId` may arrive in a first `hello` frame. Because the bearer token
is looked up in the registry at upgrade time, the identity is already known —
the query parameter is just a cross-check (mismatch → HTTP 403 at upgrade). If a
`hello` frame does arrive, its `agentId` is validated and a mismatch produces
`{"t":"error","code":"auth/agent-mismatch","fatal":true}` plus a close.

## 5. `eventResult.clientId` is supplied by the agent, not the device

§3.3's example has the device send `clientId`, but §3.2's `event` frame carries
no clientId and §4.1.5 requires the clientId of *that device's own* `$events`
stream. The device therefore cannot know it. The agent ignores any `clientId` in
the frame and injects the one from that device's `ready` item; `eventId` and
`outcome` come from the device. A device does not need to send `clientId` at all.

## 6. §3.3's `session/follow` args example is stale (DLP itself is unaffected)

The spec shows
`{"request":{"agentId":"session-…","afterSeq":3883}}`. DSH 0.1.5-rc.1 rejects
that with `gateway/input-invalid`. The real request is:

```json
{"request":{"address":{"kind":"session","sessionId":"session-…"},
            "maxMessages":50,"assistantStream":true}}
```

DLP forwards `args` verbatim, so this is a documentation bug in the example, not
a protocol problem. Verified against the running instance; the integration test
uses the working shape.

## 7. `/pair/refresh` is unspecified; defined here

Input: `Authorization: Bearer <deviceToken>` **or** `{"deviceToken":"dt_…"}`.
Output: `{"ok":true,"deviceId":…,"agentId":…,"accountId":…,"deviceToken":"dt_…","expiresAt":…}`.
The old token is invalidated in the same write, so a refresh is atomic from the
device's point of view.

## 8. Extra fields in the `/pair/claim` response

`deviceId` (not a secret) is added so the operator can list, correlate and revoke
the device. `agentName` is included as §2.1 requires.

## 9. A device `req` while the agent is offline gets an explicit error

§5 only defines the `hostStatus` notification. Waiting for a reply that cannot
come is worse than failing fast, so the relay also answers
`{"t":"error","code":"host/offline","message":…}` (non-fatal) for a `req`
received while no agent is connected. The device stays connected and receives
`hostStatus online:true` when the agent returns.

## 10. `$events` ready handling and delivery channel

§4.1.5 says the agent broadcasts every `$events` item as an `event` frame to all
connected devices, and that each device needs its own `clientId`. With a
per-device `$events` stream, the `ready` item can easily arrive *before* the
device sends `open $events`; the device would then never learn its clientId.

Two consequences, both additive:

* the agent caches each device's `ready` item and replays it as the first `item`
  of that device's `$events` stream when the device opens it;
* while a device has `$events` open, its items are delivered as `item` frames on
  that stream id (as §3.2's `item` implies) instead of unsolicited `event`
  frames, so nothing is delivered twice. Without an open stream they are sent as
  `event` frames exactly as §4.1.5 describes.

## 11. Heartbeats are terminated by the relay

`ping`/`pong` are answered by the relay itself in both directions rather than
forwarded, so device heartbeats never reach the agent and vice versa. The agent
still sends `{"t":"ping"}` to the relay every 20s and treats 60s without a
`pong` as a dead link (§4.2); the WebSocket layer adds an independent protocol
level heartbeat at the same cadence.

## 12. Backpressure accounting

§5's “512 unacked frames” has no application-level ack on a raw WebSocket, so it
is implemented as a bound on queued frames. Each device owns **two** bounded
queues of 512 — relay → device and device → agent — and overflowing either one
closes that device with WebSocket code `4008` and tells the agent to clean up
its streams. The agent link uses a larger bound (4096) because losing it would
drop every device simultaneously; the natural backpressure from a slow agent
still surfaces as a device overflow, one device at a time.

## 13. Naming: `agentSecret` is the DLP agent bearer token

§4.2 calls the persisted credential `agentToken`; the connector task calls it
`agentSecret`. `agent.json` uses `{"relayUrl","agentId","agentSecret"}` and the
relay accepts it as `Authorization: Bearer <agentSecret>`. There is no separate
token.

## 14. Caddy mounting detail (deployment, not protocol)

`deploy/Caddyfile.snippet` is a *fragment*, not a site block: it is spliced
inside the existing `relay.example.com, example.com` site block,
immediately before the first `handle` / `handle_path` / `route` / `reverse_proxy`
directive. That position is not cosmetic — Caddy's `handle` family is
mutually exclusive and order-sensitive, so a fragment placed after the site's
catch-all `handle { … }` would never be reached. `deploy/caddy_splice.py` finds
the site block by address, counts braces while ignoring quoted text, comments and
`{placeholders}`, inserts between the marker comments, and can remove the block
again byte-for-byte. `tests/test_caddy_splice.py` asserts the compiled route
order with the real `caddy adapt` when a `caddy` binary is available.

## 15. Small hardening beyond the spec

* 32 MiB is enforced three times: WebSocket `max_msg_size`, `client_max_size`,
  and an explicit length check in `dlp.parse_frame`.
* `/pair/claim` is rate-limited per client IP (10 failures / 5 minutes) and
  scrypt verification is capped at 2 concurrent executions.
* `/healthz` returns exactly `{"ok":true,"version":1}` as specified; richer
  state is available from the agent's `/mobile-link/status` and from the relay
  logs, so the spec'd shape is preserved for uptime probes.

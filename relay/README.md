# DLP relay — DSH Link Protocol v1

A small Python 3.12 + aiohttp relay that lets an iOS client reach a DSH instance
running behind NAT. The PC-side connector (`../plugins/mobile-link/`) dials out to it; the
phone dials out to it; the relay authenticates both and forwards frames by
`agentId`. It never parses DSH semantics — it is a protocol-transparent tunnel.

Normative specification: [`../docs/RELAY-PROTOCOL.md`](../docs/RELAY-PROTOCOL.md).
Where the implementation had to make a judgement call, it is written down in
[`notes/relay.md`](../docs/notes/relay.md).

```
  iOS app                          relay (public)                  PC
    │  WSS /dsh-link/link/device       │       WSS /dsh-link/link/agent │
    ├─────────────────────────────────►│◄───────────────────────────────┤
    │  Bearer <deviceToken>            │       Bearer <agentSecret>     │
    │                                  │                          ┌─────┴──────┐
    │                                  │                          │ dsh web    │
    │                                  │                          │ 127.0.0.1  │
    │                                  │                          └────────────┘
```

The public endpoint is a **path prefix on an existing, already-certified site**
(`https://relay.example.com/dsh-link`) — no new DNS record and no new
certificate. Caddy's `handle_path /dsh-link/*` strips the prefix, so the relay
itself keeps serving root-relative routes; it also accepts the un-stripped
`/dsh-link/...` form (via `--base-path`), so it works behind either kind of
front end.

## Layout

| File | Purpose |
|---|---|
| `relay.py` | aiohttp wiring: the two WebSocket endpoints, the app factory, base path, CLI entrypoint |
| `api.py` | plain-HTTP surface: `/healthz`, `/pair/{claim,refresh,code}`, CORS, bearer parsing |
| `dlp.py` | frame codec, validation, additive relay control frames |
| `store.py` | SQLite persistence (accounts, agents, devices, pair codes), hashes only |
| `hub.py` | agent/device registry, routing, per-device backpressure |
| `admin.py` | operator CLI (accounts, agents, pairing codes, devices) |
| `deploy/` | systemd unit, Caddy route fragment, `caddy_splice.py`, idempotent `deploy.sh` |
| `tests/` | pytest unit tests, `integration_e2e.py` (the full middle-tier run) and its `e2e_support.py` helpers |

## Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| `GET` | `/healthz` | — | `{"ok":true,"version":1}` |
| `WS` | `/link/agent?agentId=<id>` | `Bearer <agentSecret>` | one live connection per `agentId`; a new one supersedes the old (close `4001`) |
| `WS` | `/link/device?agentId=<id>` | `Bearer <deviceToken>` | any number per agent |
| `POST` | `/pair/claim` | — | `{pairCode, deviceName, deviceModel, appVersion}` → device token |
| `POST` | `/pair/refresh` | device token | rotates the token; the old one dies immediately |
| `POST` | `/pair/code` | agent secret | mints a one-time pairing code (see `notes/relay.md` §2) |
| `POST` | `/agents/enroll` | invite code | redeems a one-time invite for `agentId`/`agentSecret` (closed: no valid invite, no identity) |
| `GET` | `/devices` | device token | the caller's own pairings |
| `POST` | `/devices/revoke` | device token | revokes one of the caller's own pairings |
| `OPTIONS` | `*` | — | CORS preflight |

Every path above is served **both** as `/healthz` and as `/dsh-link/healthz`
(configurable with `--base-path`), which is what makes the relay indifferent to
whether the front end strips the prefix.

## Quick start (local, no server)

```bash
cd relay
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt

# provision an account + agent, and write the PC identity file
.venv/bin/python admin.py --db state.db account-create --name "Example"
.venv/bin/python admin.py --db state.db agent-register \
    --account acc_xxx --name "MacBook Pro" \
    --relay ws://127.0.0.1:8787 --write-config ~/.dsh/mobile-link/agent.json

# run the relay (add --base-path /dsh-link to mimic the production mount)
.venv/bin/python relay.py --host 127.0.0.1 --port 8787 --db state.db

# mint a pairing code for the phone
.venv/bin/python admin.py --db state.db code-mint --agent agt_xxx

# let somebody else's computer register itself (one code per computer)
.venv/bin/python admin.py --db state.db invite-mint --note "for Sam"
```

The invitee then runs the connector's own enrollment on their machine, which
calls `POST /agents/enroll` and writes `~/.dsh/mobile-link/agent.json`:

```bash
dsh-mobile-link enroll --invite <code> --relay wss://relay.example.com/dsh-link
```

That is the whole distribution story: the operator mints codes, and nobody has
to hand a credential around. Enrollment is deliberately *not* open — the relay
is on the public internet, so an invite is the only way in.

`code-mint` prints the code plus a `dsh://pair?relay=…&code=…` deep link — that
is the string to render as a QR code.

## Tests

From the repository root:

```bash
relay/.venv/bin/python -m pytest -q                                 # 83 relay unit tests, no network
                                                                    # (Caddy validation tests skip without a caddy binary)
relay/.venv/bin/python relay/tests/integration_e2e.py               # full middle tier vs the real local DSH
DSH_E2E=1 relay/.venv/bin/python -m pytest relay/tests -q           # unit + end-to-end under pytest
```

The integration run starts a real relay, provisions through `admin.py`, runs the
real Node agent against the local DSH instance, and drives a fake device through
`session/list`, `$events`, `session/follow` and a reconnect. It only touches
read-only DSH endpoints.

## Operations

### Provisioning

```bash
A=.venv/bin/python  # or /opt/dsh-relay/.venv/bin/python on the server
DB=/var/lib/dsh-relay/state.db

$A admin.py --db $DB account-create --name "Example"
$A admin.py --db $DB agent-register --account acc_x --name "MacBook Pro" \
      --relay wss://relay.example.com/dsh-link --write-config ~/.dsh/mobile-link/agent.json
$A admin.py --db $DB code-mint --agent agt_x                 # 10-minute, one-time
$A admin.py --db $DB agent-list
$A admin.py --db $DB agent-rotate --agent agt_x              # new secret, same agentId
$A admin.py --db $DB agent-disable --agent agt_x
$A admin.py --db $DB device-list --agent agt_x
$A admin.py --db $DB device-revoke --device dev_x            # or --token dt_x
$A admin.py --db $DB purge                                   # drop expired codes
```

`agent-register --write-config` writes `agent.json` with mode `0600`. Run it as
*your* desktop user so the file lands in your own home directory. The pairing
code is shown as `XXXX-XXXX` plus a `dsh://pair?relay=…&code=…` QR payload.

### Deploying to the relay host

```bash
export DSH_RELAY_SITE=<your.site>        # 仓库里只有占位符，真值在你自己的环境里
sudo -E relay/deploy/deploy.sh           # enable or update; safe to re-run
sudo -E relay/deploy/deploy.sh --uninstall  # revert the Caddy change
journalctl -u dsh-relay -f
```

`deploy.sh` 的 `DSH_RELAY_SITE` 默认值是占位符 `relay.example.com`——站点地址属于
部署方，不进仓库。`DSH_RELAY_URL` / `DSH_OTA_HOST` 同理，见仓库根的
`.env.example`。

`deploy.sh` creates a `dsh-relay` system user, builds a venv under
`/opt/dsh-relay`, installs the sandboxed unit, and splices a marked
`handle_path /dsh-link/*` route **inside the existing `relay.example.com`
site block** of `/etc/caddy/Caddyfile` — before the first `handle` /
`handle_path` / `route` / `reverse_proxy` directive, so the site's own catch-all
`handle` block can never swallow it. It then runs `caddy validate`, and only
reloads Caddy if the configuration is valid; on failure it restores the original
file byte for byte. Finally it health-checks the loopback port (both path forms)
and `https://relay.example.com/dsh-link/healthz`.

Nothing else in the Caddyfile is rewritten, reordered or deleted.

**Enabling / reverting the Caddy change**

* Enable: `sudo relay/deploy/deploy.sh` (or re-run it after an edit).
* Revert: `sudo relay/deploy/deploy.sh --uninstall`, which removes the unit and
  the marked block and reloads Caddy. The SQLite database and `/opt/dsh-relay`
  are left in place.
* Manual revert: delete the marked block from `/etc/caddy/Caddyfile`, i.e.
  everything from
  `# >>> dsh-relay managed block (managed by relay/deploy/deploy.sh) >>>`
  through
  `# <<< dsh-relay managed block <<<`,
  then `caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` and
  `systemctl reload caddy`.
* `python3 relay/deploy/caddy_splice.py check /etc/caddy/Caddyfile` reports
  whether the block is present; `… remove` takes it out.

Overridable: `DSH_RELAY_USER`, `DSH_RELAY_DIR`, `DSH_RELAY_DATA`,
`DSH_RELAY_PORT`, `DSH_RELAY_SITE` (default `relay.example.com`),
`DSH_RELAY_BASE_PATH` (default `/dsh-link`), `DSH_RELAY_PYTHON`, `CADDYFILE`.

### Configuration

| Flag / env | Default | Meaning |
|---|---|---|
| `--host` / `DLP_HOST` | `127.0.0.1` | bind address (Caddy terminates TLS) |
| `--port` / `DLP_PORT` | `8787` | bind port |
| `--db` / `DLP_DB` | `relay/state.db` | SQLite path |
| `--pair-ttl-seconds` | `600` | pairing-code lifetime |
| `--device-ttl-days` | `365` | device-token lifetime |
| `--queue-depth` | `512` | per-device backpressure bound |
| `--base-path` / `DLP_BASE_PATH` | *(empty)* | optional mount prefix; every route is served with and without it |
| `--log-level` / `DLP_LOG_LEVEL` | `INFO` | log verbosity |

### Security posture

* Secrets are generated with `secrets.token_urlsafe(32)` and stored **hashed**:
  SHA-256 for tokens, scrypt (`n=2^14`) for the short human-typed pairing codes.
* `/pair/claim` is throttled per client IP (10 failures / 5 minutes) and scrypt
  verification is capped at 2 concurrent calls, so a claim flood cannot burn the
  CPU.
* The systemd unit runs as a dedicated user with `NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, a syscall filter and
  exactly one writable path (`/var/lib/dsh-relay`).
* The relay listens on loopback only; TLS and the public hostname are Caddy's job.

### Troubleshooting

| Symptom | Check |
|---|---|
| device never gets `hostStatus online:true` | is the agent connected? `journalctl -u dsh-relay -f` logs `agent <id> connected` |
| `401` on the device WebSocket | the device token is unknown, revoked, or expired (`admin.py device-list --all`) |
| `pair/invalid-code` | the code is one-time only and lives 10 minutes; mint a new one |
| device is dropped every few seconds | it is not draining frames; the relay closes on 512 queued frames (code `4008`) |
| phone shows "host offline" repeatedly | the agent is reconnecting; check its `lastError` via `GET /mobile-link/status` or `MOBILE_LINK_STATE` lines |
| `https://relay.example.com/dsh-link/healthz` is 404 | the marked block is missing from the right site block; run `caddy_splice.py check` then `deploy.sh` |
| WebSockets close every 30–60s through Caddy | `read_timeout`/`write_timeout` were overridden; they must stay `0` (no timeout) in the reverse_proxy transport |

### Database

```sql
accounts(accountId, name, createdAt)
agents(agentId, accountId, name, secretHash, createdAt, updatedAt, disabled, lastSeenAt)
devices(deviceId, deviceTokenHash, agentId, accountId, name, model, appVersion,
        createdAt, expiresAt, lastSeenAt, revokedAt)
pairCodes(codeHash, agentId, accountId, createdAt, expiresAt, usedAt, deviceId)
```

Back up by copying `state.db` (plus `-wal`/`-shm`) with the service stopped, or
use `sqlite3 state.db ".backup /path/backup.db"`.

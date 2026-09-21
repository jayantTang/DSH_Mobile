# DLP relay — DSH Link Protocol v1

> 面向：部署与运维方 · 状态：stable · 最近核对：2026-09-20

A small Python 3.12 + aiohttp relay that lets an iOS client reach a DSH instance behind NAT. Both
the connector (`../plugins/mobile-link/`) and the phone dial out to it; it authenticates both sides
and forwards frames by `agentId`, never parsing DSH semantics.

Normative specification: [`../docs/RELAY-PROTOCOL.md`](../docs/RELAY-PROTOCOL.md).
Where the implementation had to make a judgement call, it is written down in
[`RELAY-NOTES.md`](../docs/RELAY-NOTES.md).

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
| `api.py` | plain-HTTP surface: `/healthz`, `/stats`, `/pair/{claim,refresh,code}`, CORS, bearer parsing |
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
| `GET` | `/stats` | — (loopback only) | operator view: live load, effective limits, egress per device. JSON, or an HTML page when the client sends `Accept: text/html` |
| `WS` | `/link/agent?agentId=<id>` | `Bearer <agentSecret>` | one live connection per `agentId`; a new one supersedes the old (close `4001`) |
| `WS` | `/link/device?agentId=<id>` | `Bearer <deviceToken>` | up to `--max-devices-per-agent` per agent (`403` past it) |
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
$A admin.py --db $DB usage --days 7 --by account             # 最近 7 天的出口用量
```

### Daily usage accounting

`usageDaily` 一天一台设备一行：出口字节、连接次数、当天最后上报的构建号。
记账点只有一个（`DeviceLink._count_egress`），累加在内存里，**每 30 秒或累计 1 MiB
冲一次盘**，另外在设备断开、跨本地日、进程收尾时各冲一次——所以账最多丢最后一次
冲盘前的那点字节，一次正常的重启（systemd stop/start）不丢。

口径：**日界是服务器本地日**（回答"今天"）；设备每日额度的 UTC 日（`DailyQuota`）是
另一套，两者不要混。这张表只记中转自己转发的字节，不含 SSH、OTA 下载和主机上的其它流量。

```bash
$A admin.py --db $DB usage --days 7 --by device    # 按设备
curl -s localhost:8787/stats | python3 -m json.tool | head -40   # 今天的汇总（含未冲盘部分）
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
| `--max-devices-per-agent` / `DLP_MAX_DEVICES_PER_AGENT` | `0` (unlimited) | how many devices one agent may keep attached; a reconnect never counts twice |
| `--device-rate-kbps` / `DLP_DEVICE_RATE_KBPS` | `0` (no pacing) | per-device egress pacing, in **kilobits per second** |
| `--device-daily-mb` / `DLP_DEVICE_DAILY_MB` | `0` (unlimited) | per-device egress allowance per **UTC** day, in megabytes |
| `--base-path` / `DLP_BASE_PATH` | *(empty)* | optional mount prefix; every route is served with and without it |
| `--log-level` / `DLP_LOG_LEVEL` | `INFO` | log verbosity |

### Why the three limits exist (and how to pick numbers)

The relay is normally deployed on a **fixed-bandwidth** host, and that bandwidth is
shared by every device on it. The limits are not about abuse — they are about one
perfectly ordinary session not ruining everybody else's:

* **`--device-rate-kbps`** — a device that downloads ten screenshots moves ~27 MB
  of egress. On a 5 Mbps pipe that is 43 seconds of the *entire* link. Pacing one
  device at, say, 2 Mbps leaves the rest of the pipe for everyone else, and the
  device itself only sees a slower picture, never a dropped frame: the writer
  sleeps and streams, it does not discard. Pick roughly *pipe ÷ expected
  simultaneous heavy devices*, not *pipe ÷ devices*.
* **`--device-daily-mb`** — pacing bounds how fast, this bounds how much. A device
  that spends its allowance is closed with code **`4011`** after being told why
  (`{"t":"error","code":"quota/device-daily"}`), and may connect again after UTC
  midnight. Set it to a comfortable multiple of a heavy day (a few hundred MB)
  rather than to a typical day.
* **`--max-devices-per-agent`** — one computer, one person. This is what stops a
  leaked device token (or a pairing script) from filling the relay with sockets
  that all multiplex onto one connector. A device reconnecting is counted once,
  so a phone can never lock itself out.

### Watching the load

`GET /stats` returns the relay's own accounting — live agents and devices, the
effective limits, and egress bytes per device since the process started:

```bash
curl -s http://127.0.0.1:8787/stats | python3 -m json.tool | head -40
# or open http://127.0.0.1:8787/stats in a browser (through an SSH tunnel) for a
# self-refreshing page: agent/device counts, total egress, per-device bytes,
# how many seconds each device spent paced, and the remaining daily allowance.
```

The host's own interface counters cannot answer "which device is using the
bandwidth" — they mix in SSH, OTA downloads and everything else on the machine.
These numbers are the relay's, so they can.

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
| device stops receiving mid-session, close code `4011` | it spent its daily allowance (`--device-daily-mb`); the frame before the close is an `error` with code `quota/device-daily` |
| a device feels slow but nothing is dropped | it is being paced (`--device-rate-kbps`); `GET /stats` shows the seconds each device spent waiting |
| a second phone cannot connect at all (`403`) | `--max-devices-per-agent` is reached; raise it or revoke a pairing (`admin.py device-revoke`) |
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

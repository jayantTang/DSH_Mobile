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
| `purge-revoked-devices.py` | 清理库里"已撤销 / 已过期"的设备行；默认预演，`--apply` 才删，由 `deploy/dsh-relay-purge.timer` 每天调一次 |
| `deploy/` | systemd unit 与 timer、Caddy route fragment、`caddy_splice.py`, idempotent `deploy.sh` |
| `tests/` | pytest unit tests, `integration_e2e.py` (the full middle-tier run) and its `e2e_support.py` helpers |

## Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| `GET` | `/healthz` | — | `{"ok":true,"version":1,"relayVersion":"20261017.1240"}`（`version` 是协议版本；`relayVersion` 是部署构建号 `yyyyMMdd.HHmm`，`build` 带 commit/部署时刻，见 `version.py`） |
| `GET` | `/stats` | — (loopback only) | operator view: live load, effective limits, egress per device, and how many device records are dead (`deviceRecords`: counts only, never device ids). JSON, or an HTML page when the client sends `Accept: text/html` |
| `WS` | `/link/agent?agentId=<id>` | `Bearer <agentSecret>` | one live connection per `agentId`; a new one supersedes the old (close `4001`) |
| `WS` | `/link/device?agentId=<id>` | `Bearer <deviceToken>` | up to `--max-devices-per-agent` per agent (past it: an `error` frame `limit/devices`, then close `4012`) |
| `POST` | `/pair/claim` | — | `{pairCode, deviceName, deviceModel, appVersion}` → device token |
| `POST` | `/pair/refresh` | device token | rotates the token; the old one dies immediately |
| `POST` | `/pair/code` | agent secret | mints a one-time pairing code (see `docs/RELAY-NOTES.md` §2) |
| `POST` | `/agents/enroll` | invite code | redeems a one-time invite for `agentId`/`agentSecret` (closed: no valid invite, no identity) |
| `GET` | `/devices` | device token | the caller's own pairings |
| `POST` | `/devices/revoke` | device token | revokes one of the caller's own pairings |
| `POST` | `/feedback/submit` | optional device token | `{text, appVersion, deviceModel, systemVersion, clientRef}` → `{threadId, ticketKey}`; anonymous works, the ticket key is the capability |
| `POST` | `/feedback/inbox` | optional device token | `{tickets:[{threadId, ticketKey}], messagesPerThread}` → threads, notices, `unreadCount`; notices are the caller's **account** inbox; **does not mark anything read** |
| `POST` | `/feedback/append` | optional device token | `{threadId, ticketKey, text, clientRef}` → a follow-up on the same thread |
| `POST` | `/feedback/read` | optional device token | `{threadIds, noticeIds}` → marks them read for the caller's ticket(s) and **account** (one read mark per account) |
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
relay/.venv/bin/python -m pytest -q                                 # relay unit tests, no network
                                                                    # (条数以 pytest --collect-only -q 为准)
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
$A admin.py --db $DB device-hygiene --agent agt_x            # 在用/已撤销/已过期各多少条
$A admin.py --db $DB purge                                   # drop expired codes
$A admin.py --db $DB usage --days 7 --by account             # 最近 7 天的出口用量
```

`device-revoke` 只写库——**库里撤销即完成**。在线设备由中转自己的对账踢下线，最长一个
对账周期（`DLP_REVOKE_RECONCILE_S`，默认 5 秒；`0` = 关）；连接器在它下次连上时会被告知
放下那台设备的记录。`--device` 与 `--token` 的结果因此完全相同——`admin.py` 是另一个进程，
够不着 relay 的 hub，拿被撤对象的令牌去打 relay 也只会得到 401（`device_by_token` 对已撤销
令牌返回 None），所以那条直连路径已经删掉，不再有第二条会漂移的实现。

### Daily usage accounting

`usageDaily` 一天一台设备一行：出口字节、连接次数、当天最后上报的构建号。
记账点只有一个（`DeviceLink._count_egress`），累加在内存里，**每 30 秒或累计 1 MiB
冲一次盘**，另外在设备断开、跨本地日、进程收尾时各冲一次——所以账最多丢最后一次
冲盘前的那点字节，一次正常的重启（systemd stop/start）不丢。

口径：**日界是服务器本地日**（`store.local_day()`，回答"今天"）。设备每日额度
（`DailyQuota`）用的是**同一个**函数——额度基线就是这张表里 `(deviceId, 今天)` 那一行的
`egressBytes`，所以"今天用了多少"和"今天还剩多少"永远是同一件事。这张表只记中转自己
转发的字节，不含 SSH、OTA 下载和主机上的其它流量。

```bash
$A admin.py --db $DB usage --days 7 --by device    # 按设备
curl -s localhost:8787/stats | python3 -m json.tool | head -40   # 今天的汇总（含未冲盘部分）
```

`agent-register --write-config` writes `agent.json` with mode `0600`. Run it as
*your* desktop user so the file lands in your own home directory. The pairing
code is shown as `XXXX-XXXX` plus a `dsh://pair?relay=…&code=…` QR payload.

### Account state（032）

`GET /account/state` 与 `PUT /account/state` 存"一台设备改了、同账户其他设备要跟着变"的
那几项：会话已读水位、角标水位、提醒开关、待回应已回答。表是 `accountState(accountId, key,
value, updatedAt, updatedByDeviceId)`，值是一段 JSON，**中转不解释内容**。

两条要记住的规则：

* **只前进不后退**：`updatedAt` 不大于已存的写会被拒（`applied` 里不出现该 key）。多台设备
  并发写同一项时，这条防止"旧设备晚到一步把新状态盖回去"。合并在写入方做（已读取 `max`）。
* **推送是尽力而为**：写成功后给同账户其他在线设备发一帧 `{t:"accountState",keys:[…]}`，
  不入队、不重试、不确认；收不到的一方靠前台拉取兜底。别把它改成可靠投递——那等于又加一条
  会自己重连重试的路径。

信件服务（`mail`）在已读落库后调环回端点 `POST /internal/account-state/touch` 借这条通道
通知同账户设备；它只发通知，不写状态（信件的已读本来就在 mail 库里、且是账户级）。

## Dead device records

每配一台手机就多一行 `devices`；撤销之后（`device-revoke`、App 里解除配对）或配对满
365 天（`--device-ttl-days`）之后，那一行**永远回不来了**——`device_by_token` 两种都拒。
留着行的代价在**连接器每次连上时**：中转会把该 agent 名下所有这种行逐条重放给它
（`hub.py:_tell_agent_about_the_gone`，一条一帧 `deviceDetach`），连接器要为每条放下一条
值班流。2026-10-12 库里攒到 **2012 条**（历次用例与调试设备留下的），一次重连灌 2012 帧，
把连接器的处理链堵住，手机跟着断断续续（那次的分析记在本机
`maintainers/ANALYSIS-20261012-connector-flap.md`，不随仓库发布）。每跑一次仿真器用例
就会新配一台、再撤销一台，所以这个数字只会涨，得有人清。

**看得到**（三个出口；设备明细不外露）：

```bash
curl -s localhost:8787/stats | python3 -c 'import json,sys;print(json.load(sys.stdin)["deviceRecords"])'
# {"total": 436, "live": 87, "revoked": 349, "expired": 0, "dead": 349}
$A admin.py --db $DB device-hygiene                  # 全库
$A admin.py --db $DB device-hygiene --agent agt_x    # 单个 agent，多给一个 overThreshold 结论
```

`dead` 才是会被重放的条数（已撤销 ∪ 已过期，去重后）；一条记录可以既撤销又过期，
所以 `revoked + expired` 可能比它大。`/stats` 的 `deviceRecords` 只有计数，
没有 `deviceId`、没有设备名——要看明细是 `admin.py device-list --all`。

**告警**：一个 agent 的死记录超过 `--dead-device-warn-threshold`
（`DLP_DEAD_DEVICE_WARN_THRESHOLD`，默认 200，`0` = 不告警）时，它下次连上会记一条 WARNING，
里面带条数、阈值与清理命令：

```
relay: agent agt_x has 349 dead device records (revoked or expired), over the 200 threshold;
every reconnect replays that many deviceDetach frames — purge them with
`purge-revoked-devices.py --agent agt_x --apply`
```

**清理**：`purge-revoked-devices.py`。默认只预演；`--apply` 才真删，删前做一份 SQLite 备份
（`.backup` API，含 WAL 内容）并把待删行导出成 JSON，落在库文件旁边的 `backups/`。
它只删已撤销 / 已过期的行，**在用的设备一行都不碰**（预演输出里会把它们逐条列出来核对），
也不碰 `usageDaily` / `feedbackThreads` / `noticeDeliveries`。

```bash
$A purge-revoked-devices.py --db $DB --agent agt_x                     # 预演
$A purge-revoked-devices.py --db $DB --agent agt_x --apply             # 真删
$A purge-revoked-devices.py --db $DB --all-agents --apply --keep 14    # 清全部 agent，留 14 组备份
```

**每天自动清**：`deploy/dsh-relay-purge.timer` 配 `deploy/dsh-relay-purge.service`，
每天 04:30 以 `dsh-relay` 用户跑一次
`--all-agents --apply --backup-dir /var/lib/dsh-relay/backups --keep 14`。
`deploy.sh` 只负责把脚本装进 `/opt/dsh-relay/`，timer 需要单独装一次：

```bash
sudo install -m 0644 relay/deploy/dsh-relay-purge.service /etc/systemd/system/
sudo install -m 0644 relay/deploy/dsh-relay-purge.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh-relay-purge.timer
systemctl list-timers dsh-relay-purge.timer        # 下次触发时刻
journalctl -u dsh-relay-purge -n 20                # 上一轮清了多少
sudo systemctl start dsh-relay-purge.service       # 手动跑一次，不等 04:30
sudo systemctl disable --now dsh-relay-purge.timer # 不想要了就这一条
```

一条待删行都没有时脚本**不写备份、不动库**，所以常态下不会每天多一份库；真有东西可清时
每次一份全库备份，`--keep N` 决定留几组（备份放在 `--backup-dir`，默认是库文件旁边的
`backups/`；磁盘紧就调小或设 0）。

`device-hygiene`、`/stats` 与清理脚本用的是同一个判据：`revoked` = `revokedAt IS NOT NULL`，
`expired` = `expiresAt <= now`，`live` = 两者都不成立。

### Feedback and notices

In-app feedback lands in `feedbackThreads`/`feedbackMessages`; broadcast notices
land in `notices`/`noticeDeliveries` — **one row per recipient account** (019), with
one read mark shared by every device under it. A phone authenticates with its device
token, but the inbox it reads belongs to the account: re-pairing the phone (which mints
a new `deviceId`) never loses the notices already delivered. The phone's pickup key is
never stored — only its SHA-256, like an agent secret — so a thread is readable with
that key, with the device token it was submitted from, or by the operator.

```bash
$A admin.py --db $DB feedback-list --status open      # 待回复的反馈（也可以 --limit/--since）
$A admin.py --db $DB feedback-show --thread th_x      # 完整往返；顺带把 ownerReadAt 推到最新一条
$A admin.py --db $DB feedback-reply --template        # 打印官方邮件式骨架（称呼/正文/署名/日期）
$A admin.py --db $DB feedback-reply --thread th_x --body-file /tmp/reply.txt
$A admin.py --db $DB feedback-notify --body-file /tmp/notice.txt --all        # 预演：只打印收件账号数
$A admin.py --db $DB feedback-notify --body-file /tmp/notice.txt --account acc_x --yes  # 只发一个账号
$A admin.py --db $DB feedback-notify --body-file /tmp/notice.txt --all --yes  # 真正落库
$A admin.py --db $DB feedback-delete --thread th_x --yes                      # 响应删除请求
$A admin.py --db $DB ops-report --days 30                                     # 日报原始数据（JSON）
$A admin.py --db $DB ops-report --days 30 --as-of yesterday                   # 刚过去的一整天
```

`feedback-notify` **默认只预演**：不加 `--yes` 不写库，先给出收件账号数与清单；
收件人必须**显式**点名（`--account`，可重复；或 `--all` 表示全部账号）——两个都不给是错误，
不会默认广播给所有人；没有任何账号时即使加了 `--yes` 也不写库，退出码 1——设备维度在 019 里删掉了，因为手机每次
重新配对都会换 `deviceId`。本机侧还有一层薄包装（`scripts/dev/feedback.mjs`）走 SSH 调这些命令，
并负责把 `ops-report` 渲染成带图表的日报；写操作在那里同样默认预演，要 `--send`/`--yes`
才落库，日报的收件账号取 `.env.local` 的 `DSH_ACCOUNT_ID`。

`ops-report --as-of` 是报告的时间锚点，取值 `now`（默认，当天 00:00 到此刻的部分数据）、
`yesterday`（刚过去的一整天）或 `YYYY-MM-DD`（指定那一天）；后两者把「今日」板块与
`--days` 窗口都锚到那一整天，`generatedAt` 仍是真实的生成时刻。本机包装对应
`feedback.mjs report --date today|yesterday|YYYY-MM-DD`（`today` → `--as-of now`）；`--full-day`
是 `--date yesterday` 的简写——每天 00:02 的自动日报用它报刚结束的那一天。

`ops-report` 是**视图**，不是账本：调试设备（`DSH-` 前缀、`Node`/`simulator` 机型）的用量、
设备与账号一律不进报告，`usage` 命令仍读全量。设备行已被清理工具删掉、账号又不在邀请码
登记名单里的孤儿用量行同样剔除（见 `admin.py:_is_orphan_usage`：清理工具为治连接器重连
卡顿会删已撤销设备行、按约定保留 `usageDaily`，留下找不到设备主体的历史行）。外部账号的
孤儿行保留——那是真人真事的历史。

「新增手机」（`devices.newPerDay`、`today.devices.new`）数的是手机，不是设备行：同一账号 +
同一机型只算第一次出现（`admin.py:_first_device_rows`）。App 重装或换版本会重新配对、插一行
新的 `deviceId`，不去重的话同一台手机会被反复记成新用户——2026-10-14 报的 2 台里就有 1 台是
换版本重配。设备行口径留在 `newRawPerDay` / `newRawInWindow` / `today.devices.newRaw` 里，
两个数字的差就是当天的重装行数。

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

`deploy.sh` 同时把 `purge-revoked-devices.py` 装进 `/opt/dsh-relay/`，但**不装也不开**
清理 timer——那是一次独立决定，装法见上面「Dead device records」一节。

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
| `--max-paired-devices` / `DLP_MAX_PAIRED_DEVICES` | `8` | 一个账户最多多少台**已配对**的 client（iOS / Web），`0` = 不限。与上一行是两层：这一层在**认领配对码**时拦（`409 limit/devices`，`details.maxPairedDevices`），上一行在**同时连接**时拦。持久配对码可以反复认领（032），所以它同时是"一枚持久码最多能给多少台设备用" |
| `--device-rate-kbps` / `DLP_DEVICE_RATE_KBPS` | `0` (no pacing) | per-device egress pacing, in **kilobits per second** |
| `--device-daily-mb` / `DLP_DEVICE_DAILY_MB` | `0` (unlimited) | per-device egress allowance per **local** day, in megabytes; the count is read from `usageDaily`, so a reconnect or a restart does not reset it |
| `--dead-device-warn-threshold` / `DLP_DEAD_DEVICE_WARN_THRESHOLD` | `200` | 一个 agent 名下的死设备记录（已撤销 ∪ 已过期）超过它就在该连接器连上时记一条 WARNING；`0` = 不告警。只告警、不自动删——清理见「Dead device records」 |
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
  (`{"t":"error","code":"quota/device-daily"}`), and may connect again after local
  midnight. The count comes from `usageDaily`, so it is the day's total rather
  than the connection's: reconnecting, or a relay restart, continues where it left
  off. Set it to a comfortable multiple of a heavy day (a few hundred MB) rather
  than to a typical day.
* **`--max-paired-devices`**（默认 8，032）— 账户里"配过几台 client"的上限，含 Web。
  为什么要它：日流量额度是按**设备**算的，连接器又为每台接入过的设备各留一条 `$events`
  值班流，而一枚持久配对码可以反复认领——没有这个数，一枚流出去的码就是无限个入口。
  到顶时**拒绝新认领**（不自动替换任何已有设备：被悄悄踢掉的那台可能是用户唯一在用的），
  提示用户到设置里删一台。同一台设备带 `deviceKey` 回来（重装/换机）复用原身份，不占新名额。
* **`--max-devices-per-agent`** — one computer, one person. This is what stops a
  leaked device token (or a pairing script) from filling the relay with sockets
  that all multiplex onto one connector. A device reconnecting is counted once,
  so a phone can never lock itself out. A refusal is delivered as a DLP `error`
  frame (code `limit/devices`) on an accepted socket followed by a clean close
  with code **`4012`**, not as a bare HTTP `403` — the phone can then tell the
  person the host is full.

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

同一份响应里的 `deviceRecords` 是设备行的卫生计数（在用 / 已撤销 / 已过期 / 死记录
`dead`，以及 `limits.deadDeviceWarnThreshold`）；只有计数，没有设备明细。
为什么这个数字重要、怎么清，见「Dead device records」。

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
| `pair/invalid-code` | no such code: mistyped, or older than the classification window |
| `pair/used-code` | the code was already claimed — one code pairs one device; a second phone needs a fresh one |
| `pair/expired-code` | the code outlived its TTL (10 minutes by default); mint a new one |
| a rejected claim, and which code it was | the log line names the reason and, when the code matched a row, when it was minted / used / expired — `journalctl -u dsh-relay \| grep 'pair claim rejected'` |
| device is dropped every few seconds | it is not draining frames; the relay closes on 512 queued frames (code `4008`) |
| device stops receiving mid-session, close code `4011` | it spent its daily allowance (`--device-daily-mb`); the frame before the close is an `error` with code `quota/device-daily` |
| a device feels slow but nothing is dropped | it is being paced (`--device-rate-kbps`); `GET /stats` shows the seconds each device spent waiting |
| a second phone cannot connect at all (`limit/devices` / close `4012`) | `--max-devices-per-agent` is reached; raise it or revoke a pairing (`admin.py device-revoke`) |
| phone shows "host offline" repeatedly | the agent is reconnecting; check its `lastError` via `GET /mobile-link/status` or `MOBILE_LINK_STATE` lines |
| `https://relay.example.com/dsh-link/healthz` is 404 | the marked block is missing from the right site block; run `caddy_splice.py check` then `deploy.sh` |
| `admin.py device-revoke` 之后手机还连着 | 等一个对账周期；仍连着就看 `journalctl -u dsh-relay` 有没有 `was revoked in the database but still connected; detaching`——没有就是 `DLP_REVOKE_RECONCILE_S=0` 或对账任务挂了（日志里有 `revoke reconcile tick failed`） |
| WebSockets close every 30–60s through Caddy | `read_timeout`/`write_timeout` were overridden; they must stay `0` (no timeout) in the reverse_proxy transport |
| 手机每隔几十秒就断一下、日志里有 `has N dead device records` | 库里攒的已撤销/已过期设备行太多，连接器每次重连都被灌 N 帧；清掉它们（见「Dead device records」），再看 `journalctl -u dsh-relay-purge` |

### Database

```sql
accounts(accountId, name, createdAt)
agents(agentId, accountId, name, secretHash, createdAt, updatedAt, disabled, lastSeenAt)
devices(deviceId, deviceTokenHash, agentId, accountId, name, model, appVersion,
        createdAt, expiresAt, lastSeenAt, revokedAt)
pairCodes(codeHash, agentId, accountId, createdAt, expiresAt, usedAt, deviceId)
usageDaily(day, deviceId, agentId, accountId, egressBytes, connections,
           firstSeenAt, lastSeenAt, lastBuild)
invites(codeHash, createdAt, expiresAt, usedAt, usedByAgentId, note)
feedbackThreads(threadId, ticketHash, accountId, deviceId, appVersion, deviceModel,
                systemVersion, createdAt, lastMessageAt, ownerReadAt, userReadAt,
                status, clientRef)
feedbackMessages(messageId, threadId, author, body, createdAt, clientRef)
notices(noticeId, subject, body, createdAt, createdBy)
noticeDeliveries(noticeId, accountId, createdAt, readAt)
```

Back up by copying `state.db` (plus `-wal`/`-shm`) with the service stopped, or
use `sqlite3 state.db ".backup /path/backup.db"`.

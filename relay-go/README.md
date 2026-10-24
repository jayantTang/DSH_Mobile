# relay-go — DSH 中转的 Go 实现（生产）

DSH Link Protocol v1 中转的 Go 单二进制实现，自 2026-10-24 03:21 CST 起承担生产流量
（`relayVersion=go-0.1.2`）。安装、升级与回滚见 [`deploy/README.md`](deploy/README.md)。

三类入口共用一个二进制：`serve`、`admin`、`alert-dispatch` / `purge`。功能面覆盖 HTTP
（配对、设备、账户状态、自助登记、`/stats`、限流）、两条 WebSocket `/link/*`（帧转发、
心跳、背压、设备上限、每日配额）、文件通道、反馈通道、APNs 推送、监控告警与运维 timer。

## 构建与测试

```bash
cd relay-go
make build            # bin/dsh-relay（CGO_ENABLED=1，SQLite 用 mattn/go-sqlite3）
make test             # 单元测试
make build-purego     # 无 cgo 回退：bin/dsh-relay-purego（modernc.org/sqlite）
make test-purego      # 纯 Go 构建下再跑一遍测试
make test-blackbox    # tests/blackbox 契约套件对 bin/dsh-relay 跑一遍
make soak-smoke       # 20 秒 soak 冒烟（scripts/m4b/soak.py，不进默认测试）
```

需要 Go 1.27（见 `go.mod`）。所有 go 命令经 `make` 执行，环境变量在 Makefile 里固定。

## 运行

```bash
# 不带子命令时默认 serve（黑盒测试的 RELAY_CMD 直接指向二进制）
./bin/dsh-relay --host 127.0.0.1 --port 8787 --db /var/lib/dsh-relay/state.db
./bin/dsh-relay serve --host 127.0.0.1 --port 8787 --db /var/lib/dsh-relay/state.db
curl -s http://127.0.0.1:8787/healthz

# 管理面是同一二进制的 admin 子命令（JSON 输出固定，供脚本消费）
./bin/dsh-relay admin --db state.db account-create --name "Example"
./bin/dsh-relay admin --db state.db agent-register --account acc_x --name "MacBook Pro"
./bin/dsh-relay admin --db state.db invite-mint --note "for Sam"
./bin/dsh-relay admin --db state.db code-mint --agent agt_x
./bin/dsh-relay admin --db state.db device-list --agent agt_x
./bin/dsh-relay admin --db state.db device-revoke --device dev_x
./bin/dsh-relay admin --db state.db device-hygiene --agent agt_x
./bin/dsh-relay admin --db state.db usage --days 7 --by account
./bin/dsh-relay admin --db state.db ops-report --days 30 --as-of yesterday
./bin/dsh-relay admin --db state.db push-test --device dev_x --kind attention
./bin/dsh-relay admin alert-dispatch --alert-dir /var/lib/dsh-relay/alerts \
  --account acc_owner --mail-db /var/lib/dsh-mail/mail.db \
  --mail-admin /opt/dsh-mail/admin.py --mail-python /opt/dsh-mail/.venv/bin/python

# 运维 timer 的两个顶层子命令（与 admin 的同名动作共用实现）
./bin/dsh-relay alert-dispatch --dry-run --alert-dir /var/lib/dsh-relay/alerts
./bin/dsh-relay purge --db state.db --all-agents              # 预演
./bin/dsh-relay purge --db state.db --all-agents --apply \
  --backup-dir backups --keep 14                              # 真删（先备份再删）
```

健康检查响应：

```json
{"ok":true,"version":1,"relayVersion":"0.0.0","capabilities":["device-subprotocol-auth","persistent-pair-code","account-state","account-state-push","file-transfer"]}
```

`relayVersion` 取可执行文件旁的 `build.json`（`{"version":"20261023.1200","commit":"…","deployedAt":"…"}`），
读不到就是 `0.0.0`（表示"这不是一次部署"）。部署脚本负责生成该文件。

`--port 0` 由内核分配端口，启动日志的 `addr` 字段是实际地址。

SIGINT / SIGTERM 后停止接收请求、5 秒内收尾并关闭数据库；日志是 `log/slog` JSON。

### 参数与环境变量

参数名、环境变量名与默认值：

| 参数 | 环境变量 | 默认值 |
|---|---|---|
| `--host` | `DLP_HOST` | `127.0.0.1` |
| `--port` | `DLP_PORT` | `8787` |
| `--db` | `DLP_DB` | `.local/state.db` |
| `--pair-ttl-seconds` | — | `600` |
| `--device-ttl-days` | — | `365` |
| `--queue-depth` | — | `512` |
| `--queue-bytes` | — | `4 MiB` |
| `--bridge-bytes` | `DLP_BRIDGE_BYTES` | `16 MiB` |
| `--max-devices-per-agent` | `DLP_MAX_DEVICES_PER_AGENT` | `0`（不限） |
| `--max-paired-devices` | `DLP_MAX_PAIRED_DEVICES` | `8` |
| `--device-rate-kbps` | `DLP_DEVICE_RATE_KBPS` | `0`（不限速） |
| `--device-daily-mb` | `DLP_DEVICE_DAILY_MB` | `0`（不限量） |
| `--dead-device-warn-threshold` | `DLP_DEAD_DEVICE_WARN_THRESHOLD` | `200` |
| `--base-path` | `DLP_BASE_PATH` | `""` |
| `--log-level` | `DLP_LOG_LEVEL` | `INFO` |
| `--access-log` | `DLP_ACCESS_LOG` | `errors`（只记 5xx 与 >500ms 慢请求） |
| `--pprof-addr` | `DLP_PPROF_ADDR` | `""`（关闭） |
| `--gogc` | `DLP_GOGC` | `50`（Go 默认 100） |
| — | `DLP_REVOKE_RECONCILE_S` | `5`（秒；0 或负数关闭对账） |

`--base-path` 同时服务带前缀与去前缀两种路径（Caddy `handle_path` 剥不剥前缀都能用）。

### 文件上行桥的字节额度（`--bridge-bytes`，默认 16 MiB）

上行分片是不可丢的 `ClassControl` 帧，因此绕过了每连接的
`--queue-bytes` 上限；慢连接器读时，4096 深度的队列最坏能堆到 4096 × 1.33 MB。
额度把"能堆多少"从队列深度改成字节数（按 base64 之后的真实排队字节计），必须为正数；
放宽就传一个大数。

* 入队前取得、帧写出（或被丢弃、随连接关闭清空）之后归还；
* 额度不足时 handler 停在读请求体之前：不丢数据，也不把整份文件读进内存；
* 请求取消、读体出错、连接器被顶替都会归还已取得的额度；
* `/stats` 的 `limits.bridgeBytes` 是上限，`snapshot.agents[].bridgeBytesInUse`
  是当前占用（慢连接器时贴着上限，正好是背压生效的观测点）。

### GC 百分比（`--gogc`，默认 50）

中转的堆里常驻的是连接、队列与缓冲（300 档实测：存活堆 33 MiB，其中队列 11 MiB），
垃圾周转快。Go 默认 GOGC=100 会留一倍余量，配对高峰（100 台设备要 200 次 scrypt，
每次 16 MiB 临时缓冲）把峰值推到 71 MiB。M2.5 实测把 GOGC 降到 50：

| 100 设备档 | GOGC=100 | GOGC=50 |
|---|---|---|
| 供给阶段峰值 RSS | 71.5 MiB | **52.7 MiB** |
| 转发阶段峰值 RSS | 41.9 MiB | **37.2 MiB** |
| 供给 CPU | 3.83 s | 3.78 s |
| 转发 CPU | 1.77 s | 1.81 s |

CPU 差异在噪声内（GC 本身的 CPU 占比不到 1%）。想恢复 Go 默认行为传 `--gogc 100`。
`--gogc` 必须为正数：0 等于每次分配都 GC，负数在 Go 里是"关闭 GC"，两者都会让一个
长连接服务进入不可控状态，启动时直接拒绝。想要硬上限可以用 Go 原生的 `GOMEMLIMIT`
环境变量，它和 `--gogc` 分别控制"速率"与"上限"，不会互相覆盖。

### pprof（诊断，默认关闭）

pprof 只在显式给 `--pprof-addr` 时开启，且只接受环回地址（`127.0.0.1` / `::1` /
`localhost`）；`0.0.0.0`、`192.168.*`、只写端口的形式都会被启动校验拒绝。

```bash
./bin/dsh-relay --pprof-addr 127.0.0.1:6060 --db /tmp/state.db
curl -s "http://127.0.0.1:6060/debug/pprof/heap?gc=1"        > heap.pb.gz      # 存活对象
curl -s "http://127.0.0.1:6060/debug/pprof/heap?alloc_space=1" > alloc.pb.gz    # 累计分配
curl -s "http://127.0.0.1:6060/debug/pprof/goroutine?debug=2"  > goroutine.txt
curl -s "http://127.0.0.1:6060/debug/pprof/profile?seconds=10" > cpu.pb.gz
go tool pprof -top -nodecount=20 heap.pb.gz
```

开启后 `runtime.MemProfileRate` 会从默认 512 KiB 降到 16 KiB，让每帧分配也能被采到；
采样本身有开销，**不要带着 pprof 取性能数字**。pprof 端口不是对外的服务面：它不进
`/stats`、不做鉴权，靠"只绑环回 + 默认关闭"限制访问。

pprof 在 M2.5 加入（DESIGN §8 要求）。

## WebSocket 转发（M2）

| 项 | 口径 |
|---|---|
| 端点 | `GET /link/agent?agentId=<id>`、`GET /link/device?agentId=<id>`（base path 的两种形式都挂） |
| 鉴权 | 电脑：`Authorization: Bearer <agentSecret>`；设备：Bearer **或** `Sec-WebSocket-Protocol: dsh.device.<deviceToken>`（头优先，服务端回显被接受的子协议） |
| 寻址 | 设备 → 电脑的每一帧盖上 `deviceId`；电脑 → 设备的帧按 `deviceId` 路由，到达手机前摘掉该键 |
| 队列 | 每连接一个有界队列（设备 512 帧、电脑 4096 帧），并叠加 `--queue-bytes` 的字节上限（默认 4 MiB）；`res`/`item` 是流式帧，队列满（帧数或字节）时丢弃并计数；其余按控制帧处理，塞不进去就断开慢连接（4008）。比字节上限还大的单帧永远放行，避免大图被自己的体积挡住 |
| 心跳 | 服务端每 30 秒 ping，60 秒内没有 pong（或任何入站帧）即关闭：3 个连接器 20 秒心跳周期的余量，与连接器 `pongTimeoutMs=60s` 同口径 |
| 限速 | `--device-rate-kbps` 换成每设备令牌桶，在写循环里把字节摊开（不丢帧），累计等待秒数进 `/stats` |
| 日额度 | `--device-daily-mb` 按设备、按本地日累计；账本按 deviceId 记在 hub 上，重连不清零；超限先发 `error quota/device-daily`（带 `details.limitBytes`），再以 4011 关闭 |
| 设备上限 | `--max-devices-per-agent`：先升级 socket，再发 `error limit/devices`（fatal），最后以 4012 关闭；同一台设备重连不占新名额 |
| 撤销 | `POST /devices/revoke` 落库后立刻断开在线 socket（1001），并给电脑发 `deviceDetach reason=revoked` |
| 账户状态 | `PUT /account/state` 落库后给同账户其他在线设备发 `accountState`（尽力而为，排除写入者） |
| 关闭码 | 4001 被顶替 / 4008 背压 / 4010 电脑不可用 / 4011 额度用尽 / 4012 设备上限 |

写只发生在每条连接的写循环里（DESIGN §5.1），其他 goroutine 只能入队。注册表按
`agentId` 哈希分 64 片，查找/挂接/摘除只锁一片；代码不同时持有两把分片锁。

转发路径不做 JSON 全量解析：读循环把消息读进池化缓冲（`internal/dlp.BufferPool`），
`dlp.Scan` 只在原始字节上取顶层字段，`deviceId` 的注入/摘除是就地改写（`internal/dlp.Wire`）。
控制帧、ping 的 `ts`、连接器的 `args`/`info` 这类需要语义的路径才 `Decode()`。
一帧 48 字节的 `req`/`res` 因此是**零分配**转发（M2 是每帧 1.8–2.3 KiB、34–44 次分配）；
对照基准见 `internal/dlp/wire_bench_test.go`。

## 文件通道（M3a）

中转只做管道，**不存字节**：`PUT /files/up` 把请求体按 1 MB 切片经连接器 WebSocket
转发，`GET /files/down` 把连接器的窗口直接写进 HTTP 正文。桥的状态机在
`internal/hub/bridge.go`，HTTP 面在 `internal/files/`。

| 项 | 口径 |
|---|---|
| 上行帧序列 | `fsPutBegin`（含 sessionId/name/bytes）→ 等 `fsPutAck` → `fsPutChunk`（seq 从 0 连续）→ `fsPutEnd` → 等 `fsPutDone` |
| 下行帧序列 | 中转现铸 bid 发 `fsGetBegin`（App 的 bid 只作 `replaces`）→ 等 `fsGetAck` → `fsGetChunk` 写正文 → `fsGetEnd`；放弃时发 `fsGetCancel` |
| ack 期限 | 5 秒。连接器静默忽略这族帧是"版本太旧"的唯一信号，超时回 501 `file/unsupported` |
| 无连接器 | 立刻 503 `host/offline`（不排队、不落盘） |
| 连接器拒绝 | `fsErr` 的 `code`/`message` 原样带回，HTTP 409 |
| 分片 | 1 MB 原始字节；上行请求体边读边发，内存里最多一个分片 |
| 上行大小限制 | **不受** HTTP 客户端 32 MB 上限约束（Go 的 HTTP 服务不预读 body） |
| Range | 只认 `Range: bytes=N-`；同时给了 `offset` 以 Range 为准；`offset >= total` 回 416 |
| 响应头 | `Content-Length`（可续传的总长或额度截短后的长度）、`Content-Range`（206）、`ETag: "dsh-<version>-<size>"`、`Accept-Ranges: bytes`、`Cache-Control: no-store`、`X-DSH-Offset`（206） |
| If-Range | 与当前 ETag 不一致且带 offset 时**重开一次 fetch 从 0 读**，旧 run 发 `fsGetCancel`（只改状态行会让正文缺开头） |
| 中断/续传 | 中途 `fsErr` 停写正文（客户端看到短包）；下一次请求用 Range 从已收字节继续 |
| 客户端取消 | 请求 context 结束或正文写失败都会 `abandon` 桥并发 `fsGetCancel`，不让连接器为空读者读完整份文件 |
| 计费 | 下载每一片都过该设备的令牌桶与 `usageDaily` 日额度（与 WebSocket 路径同一份账本），并计入 `/stats` 的出口字节；`Content-Length` 按剩余额度截短 |
| 并发 | 一条 HTTP 下载与 WebSocket 写循环会同时用同一个令牌桶，`tokenBucket` 因此加了互斥锁 |

## 服务间端点（M3a）

| 端点 | 契约 |
|---|---|
| `POST /internal/tokens/resolve` | 信件服务拿设备令牌换 `{deviceId, accountId, expiresAt}`；未知/撤销/过期一律 404 `internal/not-found`（两者逐字节相同），请求体不合法 400 `internal/bad-request`，600 次/10 分钟预算（429） |
| `POST /internal/account-state/touch` | 已读落库后给同账号**在线**设备扇一帧 `accountState`（`keys` 缺省 `["feedback"]`，不写任何状态）；回 `{"ok":true,"notified":N}` |

两个端点都只认**环回来源**（socket peer，不看请求头）：公网到达回 404，探测者分辨不出
端点是否存在。

## 反馈通道（M3b1）

四个端点都是追加式写入，SQL 在 `internal/store/feedback.go`，HTTP 面在
`internal/feedback/`，owner 侧命令在 `internal/admincli/feedback.go`。

| 项 | 口径 |
|---|---|
| 鉴权 | 可选 `Authorization: Bearer <deviceToken>`；有效才绑定设备与账号，**无效/撤销/缺失一律按匿名处理，不返回 401** |
| `POST /feedback/submit` | 建线程 + 首条留言；回 `{ok, threadId, ticketKey, createdAt}`，取件凭据只在这里出现一次（库里存 SHA-256） |
| `POST /feedback/inbox` | 按凭据 ∪ 设备/账号拉线程；**只读**，不改已读；`notices:false` 跳过通知 |
| `POST /feedback/append` | 用户补充；线程回到 `open`；带设备令牌时给匿名线程补绑定 |
| `POST /feedback/read` | 只标调用方能证明的线程（凭据命中 ∪ 设备/账号命中）；通知按账号标 |
| 校验 | 正文 4000 字符 / 8000 字节；主题 ≤80；技术字段各 ≤64；`clientRef` ≤64 且 `[A-Za-z0-9._-]`；请求体 >16 KB 回 413 `feedback/too-large` |
| `clientRef` | 同一来源重试返回同一线程并换发新凭据（旧凭据作废、不重复写留言）；别的来源复用回 400 |
| 限流 | submit/append 来源 30 次、设备 60 次；inbox/read 120 次；窗口 10 分钟；命中 429 `feedback/rate-limited` 且**不写库** |
| 留言形状 | `{messageId, author, body, format, createdAt}`；`attachments` 按现有契约忽略 |
| 未读 | 线程的 `unread` 只数 owner 留言且只算 `userReadAt` 之后的；通知已读按**账号**共享 |
| 管理面 | `feedback-list` / `feedback-show`（看即已读）/ `feedback-reply` / `feedback-notify` / `feedback-delete`，JSON 字段固定 |

## APNs 推送（M3b2）

代码在 `internal/push/`；接入点是 `POST /devices/push` 与连接器的 `notify` 控制帧。

| 项 | 口径 |
|---|---|
| `POST /devices/push` | 设备令牌鉴权；`apnsToken` 必填且必须是字符串；`env` 只认 `sandbox` / `production`（大小写敏感）；空令牌 = 清除登记并清环境；`turnEnd` / `attention` 缺省为真 |
| 环境变量 | `DLP_APNS_ENABLED`（`1/true/yes/on` 才开）、`DLP_APNS_KEY_PATH/KEY_ID/TEAM_ID/TOPIC`、`DLP_APNS_ENV_DEFAULT`（默认 sandbox）、`DLP_APNS_MIN_INTERVAL_S`（默认 60） |
| 禁用 | 开关关闭、配置不全、密钥文件不存在 → 禁用实例；`send` 回 `skipped=disabled`，转发与登记照常工作 |
| 签名 | 标准库 `crypto/ecdsa` 自签 ES256 JWT；`alg/kid/iss/iat`；50 分钟内复用，过期或被 403 拒绝时重签一次 |
| payload | 只有 `aps.alert.title-loc-key`、`sound`、`thread-id`、`kind`、`sid`、`eid`；不含标题/正文/工具名/路径 |
| 失效令牌 | `410`、`BadDeviceToken`、`Unregistered`、`DeviceTokenNotForTopic` → `deadToken=true`；hub 与 `push-test` 据此清掉登记 |
| 投递时机 | 只推**此刻不在线**、有登记、且该类开关打开的设备和类型；投递在 goroutine 里，不阻塞转发 |

## 连接生命周期（M7）

代码在 `internal/presence/`；hub 只做编排（等待旧连接退出、按顺序关闭、把事件转给
策略层），策略窗口与计数都在这个独立包里。

- **重复连接抑制**：同一 agent 的旧连接仍然活跃时，新连接不会被立即接受并顶替。
  hub 先等旧连接自己退出（`WaitForOld`，默认 1.5 秒；正常网络抖动/连接器重启时旧
  socket 已经关了，这一步是毫秒级），等不到才在**握手前**回 429。连接器把非 101 的
  握手当成连接失败，走它自己的指数退避；先升级再以 4001 关闭会让它把退避归零，
  回到每秒重连（2026-10-23 两次回滚的形态）。
- **僵死判据**：连接从「挂上」与「最后入站」里较晚的时刻起算，超过 `ActiveIdle`
  （45 秒，覆盖中转 30 秒/连接器 20 秒两套心跳）没有任何入站帧才算僵死，允许被新
  连接顶替。刚连上还没发过帧的连接**不算**僵死。
- **未上报版本的连接器**：连上超过 `HelloTimeout`（10 秒）仍没有
  `connectorVersion/hostVersion`，或一次版本都没报就断开，标记 `unverified`；之后
  的重连按 5 秒 → 10 秒 → … → 60 秒退避（只在允许窗口过后升一档，风暴本身不会把
  窗口无限拉长）。上报版本即清除标记与退避。扫描是一个进程级 5 秒循环，不为每条
  连接起定时器。
- **关闭顺序**：标记旧连接 superseded（路由层丢弃它的残留帧）→ `RequestClose`
  排空写队列 → 等写循环退出（上限 2 秒）→ 才登记并启动新连接。关闭码仍是 4001
  （协议语义不变）；循环的消除靠“不关仍在工作的连接”与“握手前拒绝”，不靠换关闭码。
- `/stats` 新增 `superseded` / `reconnectStorm` / `unverifiedAgents`，以及细分
  `unverifiedTotal` / `refusedDuplicate` / `refusedUnverified`；旧字段不变。
  `Accept: text/html` 时返回运维页（连接数、限额、死设备记录、
  每设备流量、今日用量），其余客户端继续拿 JSON。

## 可观测性（M7.5）

### 请求关联与访问日志

每个 HTTP 请求都会带一个 `X-Request-Id`：客户端带合法值时透传，否则生成
`req_<16 hex>`。它写进请求 context、响应头（包括 WebSocket 101 握手）、访问日志、
panic 日志与告警记录；5xx 的错误信封顶层额外带 `requestId` 字段（4xx 与旧响应
逐字不变）。只接受 1–128 个 `[A-Za-z0-9._:-]`，换行/引号/空格一律替换成新 ID。

访问日志由 `--access-log` 控制：

| 档位 | 记录范围 |
|---|---|
| `off` | 不记 |
| `errors`（默认） | 5xx（ERROR）与耗时 ≥ 500 ms 的慢请求（WARN） |
| `all` | 每个请求一条（INFO；5xx/慢请求仍按上面的级别） |

字段（JSON 日志，`msg` 为 `relay: access` 或 `relay: slow request`）：

| 字段 | 含义 |
|---|---|
| `requestId` | 本次请求的关联 ID（与响应头、5xx 信封、告警相同） |
| `method` | HTTP 方法 |
| `route` | 路由模板（如 `/files/down`）；未匹配到路由时为 `<unmatched>`。**不含 query 与路径值** |
| `status` | 响应状态码（WebSocket 升级还原为 101） |
| `duration_ms` | 处理耗时（毫秒，保留 3 位小数） |
| `remote_ip` | 来源 IP：socket 对端；对端是回环前置时取 `X-Forwarded-For` 最左项（与限流同一口径） |
| `bytes` | 响应字节数 |
| `agentId` / `deviceId` | 认证成功后写入的身份；没有认证时不出现 |

排查一次 5xx：`grep <requestId> relay.log` 能同时拿到访问日志（含路由、耗时、来源）、
处理函数写的错误日志、panic 栈，以及 `alerts.jsonl` 里对应类别的告警（含
`requestId`）。同一端点 5xx 的告警按类别去重：首次（或 24 小时后）那一条带当时的
requestId，后续同类只累计次数。

### 连接与 presence 日志

| 事件 | 级别 | 字段 |
|---|---|---|
| `relay: agent connected` | INFO | `agentId` `name` `accountId` `devices` `generation` `remote_ip` `connectorVersion` `hostVersion` |
| `relay: agent disconnected` | INFO | `agentId` `name` `generation` `duration_ms` `closeCode` `reason` `remote_ip` `connectorVersion` `hostVersion` `lastInbound` `lastInboundAge` `lastError` |
| `relay: device attached` | INFO | `deviceId` `name` `agentId` `accountId` `remote_ip` `hostOnline` |
| `relay: device detached` | INFO | `deviceId` `agentId` `reason` `closeCode` `duration_ms` `remote_ip` `notified` `lastInboundAge` `lastError` |
| `relay: agent superseded by a new connection` | INFO | `agentId` `oldGeneration` `newGeneration` `oldDurationMs` `oldLastInboundAge` `remote_ip` `connectorVersion` `hostVersion` |
| `relay: refused a duplicate agent connection` | INFO | `agentId` `name` `reason` `retryAfterMs` `streak` `waitResult`（exited/timeout/canceled/not-waited） `waitedMs` `unverified` `oldGeneration` `oldConnected` `oldIdleMs` |
| `relay: refused a reconnect from an agent that never reported its versions; backing off` | WARN | 同上 |
| `relay: dropped a lossy control frame under backpressure` | WARN | `link` `frame` `total` `linkControlDrops` `queueDepth` `queuedBytes` `remote_ip` `lastInboundAge` |
| `relay: heartbeat timed out, closing` / `relay: heartbeat failed, closing` | WARN | `link` `timeout` `silentFor`/`error` `lastInbound` `lastInboundAge` `queueDepth` |
| `relay: write timed out; closing the link` | WARN | `link` `error` `timeout` `queueDepth` `queuedBytes` `lastInboundAge` |

`refused` 不再落在 DEBUG：连接风暴在 journal 里必须看得见。`/stats` 的
`superseded` / `reconnectStorm` / `unverifiedAgents` 与这些日志同源。

### `/debug/conns`（仅环回）

`GET /debug/conns` 返回 live 连接快照，与 `/stats`、`/internal/*` 共用同一道守卫：
非环回来源回 **404**（不暴露端点是否存在），并记一条拒绝日志。响应：

```json
{"ok":true,"now":1790000000000,
 "agents":[{"kind":"agent","agentId":"agt_x","remote":"203.0.113.9:5555",
            "connectedAt":1790000000000,"lastInbound":1790000000123,
            "lastInboundAgeMs":10,"queueDepth":0,"queuedBytes":0,
            "controlDrops":0,"droppedFrames":0,
            "connectorVersion":"0.6.6","hostVersion":"1.0.0",
            "generation":3,"closing":false,"closeCode":0,"lastError":""}],
 "devices":[{"kind":"device","agentId":"agt_x","deviceId":"dev_x","remote":"198.51.100.8:5555",
             "connectedAt":1790000000000,"lastInbound":0,"lastInboundAgeMs":0,
             "queueDepth":2,"queuedBytes":512,"controlDrops":1,"droppedFrames":0,
             "connectorVersion":"","hostVersion":"","generation":0,
             "closing":false,"closeCode":0,"lastError":""}]}
```

`lastInbound` 为 0 表示这条连接还没收到过任何帧；`lastError` 只记异常结束（正常
关闭不写）。快照里没有令牌、Authorization、帧内容或文件路径。

### 数据库

- 单条语句超过 100 ms → `relay: slow database query`（WARN，`sql` 是名称如
  `select devices`、`insert paircodes`，**不是 SQL 全文**）。
- 写事务超过 100 ms → `relay: slow database transaction`（WARN，`sql=write transaction`）。
- `database is locked` / `SQLITE_BUSY` → `relay: database is busy`（WARN，带 `sql`、
  `duration_ms`；写事务的带 `tx=true`）。业务结果（冲突、未找到）不按数据库故障记。
- 阈值目前固定为 100 ms（`store.DefaultSlowQuery`），由 `store.OpenWith` 注入进程日志器。

### 文件 / 反馈 / 推送

- 文件：`relay: file transfer started` / `relay: file transfer finished`，字段
  `op`（upload/download）`deviceId` `agentId` `bid` `scope` `status` `bytes`
  `duration_ms` `code` `ok`。`scope` 是上传的 `sessionId` 或下载的 `scopeId`；
  **不记 `name`/`path`**（可能是用户目录里的完整文件名）。
- 反馈：`relay: feedback handled`，字段 `requestId` `op`（submit/inbox/append/read）
  `threadId`/`threads`/`messageId` `unread` `anonymous` `status` `ok`。不记正文、凭据。
- 推送：`relay: pushed a reminder` / `push failed` / `push skipped` / `device push
  token is dead; clearing it`，字段 `deviceId` `kind` `status` `reason`；不记 APNs 令牌。

### 日志隐私边界

诊断日志**不记录**：设备令牌 / 连接器密钥 / `Authorization` 头、请求或响应正文、
消息帧内容、完整文件路径。路由只记模板，file 传输只记 `bid` 与 `scope`，DB 只记
SQL 名称。`/debug/conns` 与 `/stats` 同样只描述连接与计数。

## 运维 timer（M7）

`deploy/` 交付四个 unit，**默认不启用**（安装与启用顺序见 `deploy/README.md` §6）：

| unit | 动作 |
|---|---|
| `dsh-relay-go-alerts.{service,timer}` | `dsh-relay alert-dispatch`（每 2 分钟） |
| `dsh-relay-go-purge.{service,timer}` | `dsh-relay purge --all-agents --apply --keep 14`（每天 04:30） |

`dsh-relay purge` 是设备死记录的清理（只删已撤销/已过期，先做整库备份并核对行数），
与 `dsh-relay admin purge`（删过期配对码）不是同一件事。
不带 `--apply` 只预演；没有待删行时不写备份。

## 监控告警（M3b2）

代码在 `internal/monitor/`；开关是 `DLP_ALERT_DIR`（空 = 完全关闭）。

- **异常分类**按"类型 + 最内层位置"归并；HTTP 中间件同时处理 panic（500 JSON）与 5xx。
  非 panic 的异常取"观察到该错误的调用点"；
  panic 取 recover 栈里的真实位置。
- 新类别立刻入队；同类别后续只累计，默认 24 小时后再报；每小时 6 条、每天 40 条上限，
  被压掉的条数记在下一封的 `suppressedSinceLastAlert`。
- agent 断开在窗口（默认 300 秒）内达到阈值（默认 5 次）算一次 flap，同一窗口只报一次。
- 上游落单代理项按天限量抽样（默认 20 条），详情只含位置/长度/片段。
- 队列 `alerts.jsonl`、状态 `state.json`（原子替换）；投递侧用 rename 原子取走成
  `alerts.taken.jsonl`，成功才删，失败原样追加回队列。

## 告警投递（M3b2）

`dsh-relay admin alert-dispatch` 与 `dsh-relay alert-dispatch` 同一份实现：`--alert-dir`、
`--account`（或 `DLP_ALERT_ACCOUNT`）、`--mail-db/--mail-admin/--mail-python`、
`--format text|html`、`--dry-run`。退出码 0 = 空队列或投递成功，2 = 用法/配置错误，
3 = 投递失败（记录已放回）。

## 用量冲盘与撤销对账（M3a）

- 账本按 `(本地日, deviceId)` 记在内存里，周期任务每 30 秒或累计 1 MiB 出口字节冲一次；
  跨日、设备断开、进程收尾也各冲一次。冲盘用 `usageLedger.Drain`（原子的"取走并清空"），
  写成功才算数；失败时 `Restore` 把这一批合并回内存（期间新到的字节相加，不覆盖）。
- 撤销对账每 5 秒扫一次：只查**当前在线**设备 id，`store.RevokedIDsAmong` 命中就以
  1001 断开并给连接器发 `deviceDetach reason=revoked`。token 过期不在这一臂里
  （在线 socket 不重新鉴权，踢它会打断一条仍能工作的连接）。

## 缓存与产物

本机沙箱不允许写 `~/go`，Makefile 把 Go 缓存固定在仓库内（均已 gitignore）：

| 路径 | 用途 |
|---|---|
| `relay-go/.gocache/mod` | `GOMODCACHE` |
| `relay-go/.gocache/build` | `GOCACHE` |
| `relay-go/bin` | 构建产物、基准 JSON |

Makefile 同时固定 `GOPROXY=https://goproxy.cn,direct` 与 `GOSUMDB=off`。`GOSUMDB=off`
只用于本机开发，发布构建按 CI 口径恢复校验。

不要在 `relay-go` 里直接跑 `go` 命令：默认 `GOCACHE` 指向 `~/Library/Caches/go-build`，
本机沙箱不可写，会报 `operation not permitted`。`make` 已把缓存固定到 `.gocache/`。

## 目录

```
cmd/dsh-relay/      serve / admin 子命令（参数、store、hub、HTTP、信号）
internal/config/    参数、环境变量、默认值与换算
internal/store/     SQLite：schema、迁移、账户/电脑/邀请码/配对码/设备/状态/用量仓储
internal/httpapi/   HTTP 端点、错误信封、Bearer 鉴权、CORS、限流、/stats（JSON+HTML）、/internal/*
internal/files/     /files/up 与 /files/down 的 HTTP 面（分片、Range/ETag、正文流、计费）
internal/dlp/       帧编解码、结构校验、错误帧、关闭码、deviceId 注入/剥离、代理项诊断
internal/hub/       分片注册表、路由、有界队列与写循环、心跳、背压、设备上限、配额、
                    文件桥状态机、用量账本与冲盘、撤销对账、/stats 的 load/traffic/snapshot
internal/presence/  连接器准入策略：重复连接抑制、僵死判定、未验证退避与计数
internal/purge/     `dsh-relay purge`：设备死记录清理（备份、核对、--keep 轮转）
internal/wsapi/     /link/agent 与 /link/device 的握手、鉴权与读循环
internal/authn/     Bearer 与设备子协议凭据解析（HTTP 与 WS 共用一份）
internal/apierr/    错误信封（HTTP 与 WS 握手共用一份）
internal/admincli/  管理子命令（account-create / agent-register / code-mint /
                    invite-mint / device-list），JSON 输出固定
```

## 存储层

- `store.Schema` 是唯一的建表定义，`store.SchemaVersion` = 8，迁移步骤 1–8 与
  `_MIGRATIONS` 一一对应。
- 打开时设置 `journal_mode=WAL`、`busy_timeout=15000`、`foreign_keys=ON`。
- 并发模型：写走一条专用连接并在 `BEGIN IMMEDIATE` 事务里串行化；读走 4 条连接的池。
  账户状态批量写入是单事务（DESIGN §6：64 条要么全生效、要么全不生效）。
- 令牌只存 SHA-256；配对码用 scrypt（n=1<<14, r=8, p=1, dklen=32）。
- 建表与迁移在同一个 `BEGIN IMMEDIATE` 事务里执行，版本写进 `PRAGMA user_version`；
  版本比代码新时保持原样（回滚到旧版不降级）。

## 驱动选择

默认（`CGO_ENABLED=1`）用 `mattn/go-sqlite3`，纯 Go 构建退回 `modernc.org/sqlite`
（`internal/store/driver_cgo.go` / `driver_nocgo.go`，schema 与 SQL 完全相同）。
选择依据与实测数字见 `maintainers/20261023-SQLite驱动基准.md`。

## 尚未覆盖

- APNs 只验证到 sandbox：生产 unit 已加载 `apns.env` 并真发成功，production 环境未验。
- systemd 日志的 72 小时分布图未做；取不到该数据时 `/healthz` 如实回 `null`。
- `/files/*` 已与真实连接器联调，大文件与断点续传仍缺长跑证据。
- 1000 设备档 RSS 约 182 MB（每连接预分配队列槽）；
  当前线上规模余量充足。

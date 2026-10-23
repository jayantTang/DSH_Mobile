# relay-go — DSH 中转的 Go 实现（M3b2）

DSH Link Protocol v1 中转的全 Go 重写。M0 交付骨架（配置、SQLite 存储层、schema 与
版本迁移、`/healthz`、驱动基准）；M1 补齐 HTTP 面：配对、设备、账户状态、自助登记、
`/stats`、错误信封、CORS、限流与 `admin` 管理子命令；M2 补齐 WebSocket：两条
`/link/*` 端点、帧转发、心跳、背压、设备上限、每日配额与账户状态实时通知；M2.5 做
转发层的内存与 CPU 调优（pprof 诊断面、零解析转发、按字节限额的队列）；M3a 补齐
文件通道（`/files/up`、`/files/down`，经连接器 `fs*` 帧桥接）、`/internal/*` 两个
服务间端点、`usageDaily` 周期冲盘与撤销对账；M3b1 补齐反馈通道四个追加式端点
（`/feedback/{submit,inbox,append,read}`）、线程/留言/通知仓储与 `admin` 的五个
`feedback-*` 子命令；M3b2 补齐 APNs 推送（`POST /devices/push`、`notify` → 提醒、
失效令牌清理）、监控告警（异常分类、去重、限量、flap、坏字符、告警队列）与 `admin`
其余子命令（设备/用量/日报/邀请码/推送测试/告警投递）。对外契约以 Python 版
`relay/` 为准。

## 构建与测试

```bash
cd relay-go
make build            # bin/dsh-relay（CGO_ENABLED=1，SQLite 用 mattn/go-sqlite3）
make test             # 单元测试
make build-purego     # 无 cgo 回退：bin/dsh-relay-purego（modernc.org/sqlite）
make test-purego      # 纯 Go 构建下再跑一遍测试
```

需要 Go 1.27（见 `go.mod`）。所有 go 命令经 `make` 执行，环境变量在 Makefile 里固定。

## 运行

```bash
# 不带子命令时默认 serve（黑盒测试的 RELAY_CMD 直接指向二进制）
./bin/dsh-relay --host 127.0.0.1 --port 8787 --db /var/lib/dsh-relay/state.db
./bin/dsh-relay serve --host 127.0.0.1 --port 8787 --db /var/lib/dsh-relay/state.db
curl -s http://127.0.0.1:8787/healthz

# 管理面是同一二进制的 admin 子命令（JSON 输出对齐 relay/admin.py）
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
```

健康检查响应与 Python 版逐字段一致：

```json
{"ok":true,"version":1,"relayVersion":"0.0.0","capabilities":["device-subprotocol-auth","persistent-pair-code","account-state","account-state-push","file-transfer"]}
```

`relayVersion` 取可执行文件旁的 `build.json`（`{"version":"20261023.1200","commit":"…","deployedAt":"…"}`），
读不到就是 `0.0.0`（表示"这不是一次部署"）。部署脚本负责生成该文件。

`--port 0` 由内核分配端口，启动日志的 `addr` 字段是实际地址。

SIGINT / SIGTERM 后停止接收请求、5 秒内收尾并关闭数据库；日志是 `log/slog` JSON。

### 参数与环境变量

参数名、环境变量名与默认值逐项对齐 `relay/relay.py` 的 `build_parser`：

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
| `--pprof-addr` | `DLP_PPROF_ADDR` | `""`（关闭） |
| `--gogc` | `DLP_GOGC` | `50`（Go 默认 100） |
| — | `DLP_REVOKE_RECONCILE_S` | `5`（秒；0 或负数关闭对账） |

`--base-path` 同时服务带前缀与去前缀两种路径（Caddy `handle_path` 剥不剥前缀都能用）。

### 文件上行桥的字节额度（`--bridge-bytes`，默认 16 MiB）

Python 版没有对应开关。上行分片是不可丢的 `ClassControl` 帧，因此绕过了每连接的
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
| 心跳 | 服务端每 15 秒 ping，10 秒内没有 pong 即关闭 |
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
对照基准见 `internal/dlp/wire_bench_test.go`，数字与 profile 证据在
`maintainers/REPORT-20261023-go-relay-m2.5.md`。

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
| 上行大小限制 | **不受** HTTP 客户端 32 MB 上限约束（与 Python 实测行为一致；Go 的 HTTP 服务本来也不预读 body） |
| Range | 只认 `Range: bytes=N-`；同时给了 `offset` 以 Range 为准；`offset >= total` 回 416 |
| 响应头 | `Content-Length`（可续传的总长或额度截短后的长度）、`Content-Range`（206）、`ETag: "dsh-<version>-<size>"`、`Accept-Ranges: bytes`、`Cache-Control: no-store`、`X-DSH-Offset`（206） |
| If-Range | 与当前 ETag 不一致且带 offset 时**重开一次 fetch 从 0 读**，旧 run 发 `fsGetCancel`（只改状态行会让正文缺开头） |
| 中断/续传 | 中途 `fsErr` 停写正文（客户端看到短包）；下一次请求用 Range 从已收字节继续 |
| 客户端取消 | 请求 context 结束或正文写失败都会 `abandon` 桥并发 `fsGetCancel`，不让连接器为空读者读完整份文件 |
| 计费 | 下载每一片都过该设备的令牌桶与 `usageDaily` 日额度（与 WebSocket 路径同一份账本），并计入 `/stats` 的出口字节；`Content-Length` 按剩余额度截短 |
| 并发 | 一条 HTTP 下载与 WebSocket 写循环会同时用同一个令牌桶，`tokenBucket` 因此加了互斥锁（Python 单事件循环不需要） |

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
| 管理面 | `feedback-list` / `feedback-show`（看即已读）/ `feedback-reply` / `feedback-notify` / `feedback-delete`，JSON 字段与 `admin.py` 对齐 |

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

## 监控告警（M3b2）

代码在 `internal/monitor/`；开关是 `DLP_ALERT_DIR`（空 = 完全关闭）。

- **异常分类**按"类型 + 最内层位置"归并；HTTP 中间件同时处理 panic（500 JSON）与 5xx。
  Go 的 error 不携带 Python 的 traceback，非 panic 的异常取"观察到该错误的调用点"；
  panic 取 recover 栈里的真实位置。
- 新类别立刻入队；同类别后续只累计，默认 24 小时后再报；每小时 6 条、每天 40 条上限，
  被压掉的条数记在下一封的 `suppressedSinceLastAlert`。
- agent 断开在窗口（默认 300 秒）内达到阈值（默认 5 次）算一次 flap，同一窗口只报一次。
- 上游落单代理项按天限量抽样（默认 20 条），详情只含位置/长度/片段。
- 队列 `alerts.jsonl`、状态 `state.json`（原子替换）；投递侧用 rename 原子取走成
  `alerts.taken.jsonl`，成功才删，失败原样追加回队列。

## 告警投递（M3b2）

`dsh-relay admin alert-dispatch` 复刻 `relay/alert-dispatch.py`：`--alert-dir`、
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
cmd/driverbench/    SQLite 驱动基准（mattn vs modernc）
internal/config/    参数、环境变量、默认值与换算
internal/store/     SQLite：schema、迁移、账户/电脑/邀请码/配对码/设备/状态/用量仓储
internal/httpapi/   HTTP 端点、错误信封、Bearer 鉴权、CORS、限流、/stats、/internal/*
internal/files/     /files/up 与 /files/down 的 HTTP 面（分片、Range/ETag、正文流、计费）
internal/dlp/       帧编解码、结构校验、错误帧、关闭码、deviceId 注入/剥离、代理项诊断
internal/hub/       分片注册表、路由、有界队列与写循环、心跳、背压、设备上限、配额、
                    文件桥状态机、用量账本与冲盘、撤销对账、/stats 的 load/traffic/snapshot
internal/wsapi/     /link/agent 与 /link/device 的握手、鉴权与读循环
internal/authn/     Bearer 与设备子协议凭据解析（HTTP 与 WS 共用一份）
internal/apierr/    错误信封（HTTP 与 WS 握手共用一份）
internal/admincli/  管理子命令（account-create / agent-register / code-mint /
                    invite-mint / device-list），JSON 输出对齐 admin.py
```

## 存储层

- `store.Schema` 与 Python 版 `relay/store.py` 的 `SCHEMA` 逐表、逐列一致；
  `store.SchemaVersion` = 8，迁移步骤 1–8 与 `_MIGRATIONS` 一一对应。
- 打开时设置 `journal_mode=WAL`、`busy_timeout=15000`（与 Python 的
  `sqlite3.connect(timeout=15)` 一致）、`foreign_keys=ON`。
- 并发模型：写走一条专用连接并在 `BEGIN IMMEDIATE` 事务里串行化；读走 4 条连接的池。
  账户状态批量写入是单事务（DESIGN §6：64 条要么全生效、要么全不生效）。
- 令牌只存 SHA-256；配对码用 scrypt（n=1<<14, r=8, p=1, dklen=32），参数与 Python 版一致。
- 建表与迁移在同一个 `BEGIN IMMEDIATE` 事务里执行，版本写进 `PRAGMA user_version`；
  版本比代码新时保持原样（回滚到旧版不降级）。
- Go 建的库可被 Python 版直接打开：表名集合、每表列名与列序、索引集合、`user_version`
  已逐项对比一致（见 `maintainers/BENCH-20261023-sqlite-driver.md`）。

## 驱动选择

默认（`CGO_ENABLED=1`）用 `mattn/go-sqlite3`，纯 Go 构建退回 `modernc.org/sqlite`
（`internal/store/driver_cgo.go` / `driver_nocgo.go`，schema 与 SQL 完全相同）。
选择依据与实测数字见 `maintainers/BENCH-20261023-sqlite-driver.md`。

## 与 Python 版的已知差异

1. `--db` 默认值是工作目录下的 `.local/state.db`。Python 版落在源码目录下；生产部署
   systemd 显式传 `--db`，不受影响。
2. `DLP_DB=""` 视为未设置；Python 版会把空路径交给 sqlite3，得到一个临时库。
3. `/stats` 只返回 JSON，不按 `Accept: text/html` 渲染运维页；`load`/`traffic`/
   `snapshot` 已由 hub 实时填充，`traffic.devices[]` 与 `snapshot.*` 多一个
   `droppedFrames`（DESIGN §8 要求丢帧可见）。
4. 文件通道的四处实现差异：① 冲盘用 `Drain`（原子的 Snapshot+清空）而不是
   `Snapshot` 后再清，避免两份状态；② 下载即使设备没有 WebSocket 也按 deviceId
   记日额度（Python 只在 `link` 存在时计费）；③ 被新连接顶替的旧连接器上的文件桥
   会立刻以 `host/offline` 收尾（Python 只在真断线路径收尾，旧路径下上传会一直等）；
   ④ 令牌桶加了互斥锁（两条写路径共用）。
5. 账户状态批量写入是单事务：某一条校验失败时整批不生效。Python 版逐条提交，
   会留下半批（这是 DESIGN §6 要求的修复，不是回归）。
6. 所有 5xx 都是 JSON 错误信封；Python 版未捕获异常会回 aiohttp 默认文本页。
7. 落单 UTF-16 代理项（`"\ud83d"`）由 Go 的 `encoding/json` 在**解析阶段**换成
   U+FFFD，因此不需要 Python 的发送前修复；中转仍会记一条告警（含位置与上下文）
   用于定位上游。非法 UTF-8 字节显式判 `protocol/bad-frame`——Go 标准库默认会静默
   替换成 U+FFFD，这里补齐了 Python 的行为（见 `internal/dlp/surrogate.go`）。
8. 大帧不再按 512 KiB 切成多条 WebSocket 消息。Python 这样做是为了让限速更平滑，
   代价是客户端必须重组；Go 版一条消息一帧，服务端在写之前整体计费并等待。
9. WS 握手被拒（401/403）回 JSON 错误信封，Python 回纯文本；状态码不变。
10. 电脑链路饱和时设备收到 4010（`agent unavailable`）。Python 在设备自身队列满时
    给 4008；Go 版没有中间队列，直接入电脑队列，因此如实报"电脑不可用"。
11. 控制帧入队失败一律断开慢连接（4008）。Python 对部分控制帧（如 hostStatus 广播）
    是忽略入队结果，Go 版按 DESIGN §5.1 不允许控制帧静默丢失。
12. 反馈的 16 KB 上限在 Go 侧是"最多读 16 KB + 1 字节"就回 413，Python 是先读完
    再判；状态码与错误码相同，差别只在超限请求的剩余字节是否被读掉。
13. `feedback-notify` 写进 `notices.createdBy` 的值仍是 `admin.py`：这一列是审计
    标记，与既有记录保持同一口径，不按可执行文件名改写。
14. 监控把 5xx 也当作事故（Python 只记未处理异常）。5xx 的类别是"状态码 + 方法 +
    路径"，同一端点只在首次或 24 小时后再报。
15. Go 的 error 不携带 traceback：非 panic 异常按"观察到该错误的调用点"归并；panic
    用 recover 栈里的真实位置。Python 用的是异常抛出位置的 traceback。
16. 留存的分队列边界用 `dayShift` 做日历加减；Python 在 `first_seen <= today - gap`
    这一处用整数相减，跨月会把边界算错（本仓库按语义修正，输出仅在跨月日期不同）。
17. `alert-dispatch` 放回队列时，如果追加失败会**保留** `alerts.taken.jsonl`
    （Python 的 finally 会删掉它，可能丢记录）；成功路径与正文逐字一致。

## M4 之前仍未覆盖

- 真实 APNs 联调：没有调用 Apple（按任务约束），`push-test` 与投递只用注入桩验证。
- 真实 systemd 日志的 72 小时分布图：本机没有 `dsh-relay` 单元，只验证了"取不到 → null"。
- `/files/*` 只有黑盒与 Go 单测；真实连接器（plugins/mobile-link）联调记录见
  `maintainers/REPORT-20261023-go-relay-m3a.md`。
- `/stats` 的 HTML 运维页（只回 JSON）。
- 文件通道桥的字节限额（M4）。

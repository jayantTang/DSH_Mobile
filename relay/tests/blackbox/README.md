# 黑盒测试基座（阶段 1）

本目录是对中转的**语言无关**验收用例：只通过 HTTP、WebSocket、子进程与
`ADMIN_CMD` 交互，不 import `relay` / `store` / `hub` / `api` / `dlp` 任何内部模块。
同一份用例先用现在的 Python 实现跑通、作为基线，Go 版必须逐条通过。

设计与分层（L0 契约 / L1 场景 / L2 性能 / L3 可靠性）见
`maintainers/DESIGN-20261023-go-migration-testbed.md`。目前包含第一批（HTTP、WS、
配对与账户状态）、第二批（反馈、文件、登记、限流、配额、`/internal/*`、设备子协议）
与第三批的可靠性用例；性能基线是手动脚本，不进默认套件。

## 文件

| 文件 | 内容 |
|---|---|
| `conftest.py` | `RelayProcess`（临时库、随机端口、等 `/healthz`、退出清理）、`ADMIN_CMD` 助手、会话级夹具 |
| `support.py` | HTTP/WS 客户端、错误信封断言、带超时的帧读取、账号与设备初始化；第二批加了原始字节、单请求超时与子协议握手 |
| `test_contract_http.py` | 方法、路径、鉴权、状态码、错误码、JSON 形状 |
| `test_contract_ws.py` | WS 鉴权、首帧、错误帧、关闭码、重连替换、设备上限 |
| `test_scenarios_pairing.py` | 邀请码 → 登记 → 配对 → 双 WS 的端到端路径 |
| `test_scenarios_account_state.py` | 单调写、跨账户隔离、跨设备通知、并发探针 |
| `test_contract_feedback.py` | `/feedback/*` 四接口、取件凭据、设备绑定、owner 回信、通知、管理面输出 |
| `test_contract_files.py` | `/files/up`、`/files/down`、连接器帧、Range 续传、中断重试、错误码 |
| `test_contract_enroll.py` | `/agents/enroll`、四种拒绝、按码的失败预算 |
| `test_contract_limits.py` | `/pair/claim` 失败预算、每日额度的错误帧与关闭码 4011 |
| `test_contract_internal.py` | `/internal/tokens/resolve`、`/internal/account-state/touch` 的环回路径 |
| `test_contract_ws_subprotocol.py` | `dsh.device.<token>` 子协议认证与 `/healthz` 能力广告 |
| `test_reliability.py` | kill -9 重启同库、50 设备连接风暴、数据库写锁与恢复 |
| `performance/bench.py` | 手动性能基线（启动、HTTP 吞吐/分位、WS 回显、RSS/CPU），输出 JSON |

## 运行

默认即当前 Python 实现（`sys.executable` + `relay/relay.py` / `relay/admin.py`）：

```bash
cd relay
.venv/bin/python -m pytest tests/blackbox -q
```

当前 118 项（117 passed + 1 xfailed，约 31 秒）：一个会话级中转进程（临时库、随机端口），
每个用例自建账户与 agent，互不影响；设备上限、每日额度与配对限流各自再起一个专用进程。
最慢的两条各约 5 秒，等的是连接器 ack 期限（`file/unsupported` 的 501 路径）；第三批的
三条可靠性用例各约 0.4–2.3 秒。本批没有单条超过 10 秒的用例，因此未使用 `slow` 标记。
将来出现 >10 秒的用例时加 `@pytest.mark.slow` 并在本节说明。

只看用例清单与耗时：

```bash
.venv/bin/python -m pytest tests/blackbox -q --collect-only
.venv/bin/python -m pytest tests/blackbox -q --durations=10
```

### 换实现：`RELAY_CMD`

被测中转只由 `RELAY_CMD` 决定。命令后面会被追加
`--host 127.0.0.1 --port <随机端口> --db <临时库>`，所以任何实现都要接这三个参数：

```bash
# 未来的 Go 二进制
RELAY_CMD="./dsh-relay" .venv/bin/python -m pytest tests/blackbox -q

# 换一个绝对路径 / 带参数也支持（按 shell 引号规则切分）
RELAY_CMD="/opt/dsh/bin/dsh-relay --log-level warn" .venv/bin/python -m pytest tests/blackbox -q
```

本目录用到的额外启动参数：`--max-devices-per-agent 1`（设备上限）、
`--device-daily-mb 0.25`（每日额度）。Go 版必须接受这两个参数，否则对应用例无法运行。

### 管理面：`ADMIN_CMD`

管理命令只用于初始化数据（建账户、铸邀请码、读反馈、回信、发通知），不属于被测协议。
调用形式是 `ADMIN_CMD --db <临时库> <子命令> ...`，stdout 必须是 JSON：

```bash
ADMIN_CMD="python3 relay/admin.py" .venv/bin/python -m pytest tests/blackbox -q
```

Go 版若自带管理命令，把 `ADMIN_CMD` 指过去即可，用例不动。它必须至少支持本目录
用到的子命令：

| 子命令 | 用例依赖的输出 |
|---|---|
| `invite-mint --ttl-seconds <n>` | `code`（0 秒 = 一出生就过期） |
| `code-mint --agent <id> --ttl-seconds <n>` | `code`、`expiresAt` |
| `feedback-list [--status] [--limit]` | `threadId`、`status`、`messages`、`ownerUnread`、`excerpt`、`format`、`source.{kind,deviceId,accountId,deviceModel,appVersion,systemVersion}` |
| `feedback-show --thread <id>` | `threadId`、`messages[]`（并把 owner 未读清零） |
| `feedback-reply --thread <id> --body <text> [--subject]` | `ok`、`threadId`、`messageId` |
| `feedback-notify --account <id> --subject --body --yes` | `ok`、`noticeId`、`recipients` |

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `RELAY_CMD` | `sys.executable relay/relay.py` | 被测中转的启动命令 |
| `ADMIN_CMD` | `sys.executable relay/admin.py` | 管理命令（追加 `--db`） |
| `BLACKBOX_STARTUP_TIMEOUT_S` | `20` | 等 `/healthz` 的上限 |

子进程环境里的 `DLP_*` 会被全部清掉（并显式设 `DLP_APNS_ENABLED=0`），不会继承
本机真实部署的配置；数据库与日志都落在 pytest 的 `tmp_path` 下，不碰
`~/.dsh`、真实数据库与真实设备。

限流用例里的客户端全部来自 `127.0.0.1`，而线上前置（Caddy）会把
`X-Forwarded-For` 替换成真实来源；因此配对限流用例显式带一个合成
`X-Forwarded-For` 来隔离来源桶，这也顺带钉住了「环回来源的 XFF 才是可信的」这条口径。

若想连 Python 侧 `tests/conftest.py` 都不加载（该文件为了服务原有测试会 import
中转模块），加 `--confcutdir`：

```bash
.venv/bin/python -m pytest tests/blackbox -q --confcutdir=tests/blackbox
```

## 性能基线（手动，不收集）

`performance/bench.py` 文件名不以 `test_` 开头，pytest 不会收集它。手动执行：

```bash
.venv/bin/python tests/blackbox/performance/bench.py --out /tmp/bench.json
.venv/bin/python tests/blackbox/performance/bench.py --out /tmp/bench.json --with-300
```

场景：启动 5 次；`/healthz` 并发 32 × 5 秒；`/account/state` GET 并发 16 × 5 秒；
100 台设备各带一台 agent、每台 10 帧/秒 × 10 秒的回显；`--with-300` 追加 300 设备档。
除启动外每个场景跑 3 次，中位数写进报告的 `median`，三次原始值留在 `runs`。
RSS 与 CPU 由 `/usr/bin/time -l` 包裹被测进程取得（本机 `ps`/`psutil` 不可用），
读的是 `maximum resident set size`（字节）与 user+sys 秒。

默认全程约 80 秒，加 `--with-300` 约 155 秒。2026-10-23 的实测数字与口径见
`maintainers/BASELINE-20261023-python-relay.md`。

## 可靠性（第三批）

| 用例 | 断言 | 本机单条耗时 |
|---|---|---|
| `test_kill_9_and_restart_keeps_the_account_device_and_account_state` | SIGKILL 后 `-wal` 仍在且有内容；同库重启后设备令牌、账户状态、agent 凭据可用，`journal_mode=wal`、`integrity_check=ok` | 约 0.4 s |
| `test_fifty_devices_connecting_together_all_receive_host_status` | 50 台同时连：全部 `hostStatus(online=true)`、50 条 `deviceAttach`、ping/pong 正常、无错误帧 | 约 2.3 s |
| `test_a_held_write_lock_is_recorded_and_the_relay_recovers` | 另开连接 `BEGIN IMMEDIATE` 持锁 2 秒，记录那次写的耗时与结果；锁释放后新写 200 且读得回 | 约 2.1 s |

第三条对“持锁期间那次写”**只记录不判定**（SQLite busy 行为属于实现选择），硬断言只落在
“锁释放后恢复”。准备数据有意串行：`/pair/code` 的 `count_paired_devices` 与
`/account/state` 的 GET 共用一条未加锁的 SQLite 连接，并发准备会偶发 500（已知缺陷，
见基线报告）。慢客户端/背压没有稳定构造方法，按设计文档“不硬造”留给后续批次。

## 已覆盖（第二批新增的契约事实）

### `/feedback/*`（014）

* 鉴权**不是 401**：没带令牌、令牌无效或已撤销都按匿名处理，`submit` 仍然 200；
  只有凭据（`threadId` + `ticketKey`）或有效设备令牌能把它读回来。
* `POST /feedback/submit` → `{ok, threadId: "th_…", ticketKey: "fk_"+43, createdAt}`；
  `ticketKey` 只在这一次响应里出现，管理面清单与详情都没有它。
* `POST /feedback/inbox` → `{ok, threads[], notices[], unreadCount}`；线程带
  `threadId/subject/status/createdAt/lastMessageAt/unread/messages[]`，留言只有
  `messageId/author/body/format/createdAt` 五个字段。
* 400 的 `feedback/bad-request`：缺正文、空白正文、`text`/`subject` 类型不对、
  `format` 非 `text|html`、`tickets` 超 50 对或缺键、`threadIds/noticeIds` 不是字符串列表。
* 400 的 `feedback/too-long`：正文 >4000 字符或 >8000 字节、主题 >80 字符、技术字段 >64 字符。
* 413 的 `feedback/too-large`：请求体 >16 KB（与 WebSocket 的 32 MB 无关）。
* 404 的 `feedback/not-found`：线程不存在与凭据不匹配共用同一个响应。
* 同一 `clientRef` 重试：返回同一 `threadId`、不重复写留言、**新凭据可用、旧凭据作废**。
* `append` 把线程拨回 `open`；owner 回信（`admin.py feedback-reply`）置 `replied`，
  `unread` 是 owner 留言数；`read` 幂等，返回 `{ok, unreadCount}`。
* 设备令牌提交会把线程绑定到 `deviceId/accountId`；匿名线程后来用设备令牌 `append`
  也会补上绑定。管理面 `feedback-list` 的 `source.kind` 是 `device` 或 `anonymous`。
* 通知按**账号**投递：同账号多台设备共享一份，任一台 `read` 即全账号已读；
  别的账号看不到。`admin.py feedback-notify` 的输出与 `inbox.notices[]` 的字段已钉住。
* **附件不在当前契约里**：请求体里的 `attachments` 被忽略，留言形状不变。

### `/files/*`（R-1 C-17 / C-19）

* 上传帧：中转 → 连接器 `fsPutBegin{deviceId,bid,sessionId,name,bytes}`、
  `fsPutChunk{seq,data(base64)}`、`fsPutEnd`；连接器 → 中转 `fsPutAck`、`fsPutDone{path,bytes}`。
  分片按 **1 MB** 原始字节切，`seq` 从 0 连续，`bid` 全程一致；正文拼起来逐字节相同。
* `PUT /files/up` → 200 `{ok, path, bytes}`；400 `request/incomplete` / `request/bytes`
  （非整数、负数、正文比声明短）；401 `auth/invalid-token`；503 `host/offline`（连接器不在线）；
  409 透传连接器的 `fsErr.code`（如 `workspace-file/too-large`）；501 `file/unsupported`
  （连接器不认这族帧，5 秒 ack 期限后）。
* **`/files/up` 没有 413**：handler 自己 `readany()` 消费请求体，`client_max_size` 不生效。
  32 MB + 64 KB 的正文照常 200，连接器收到全部字节。Go 版若加 413，是行为差异，需要决定。
* 下载帧：中转 → 连接器 `fsGetBegin{deviceId,bid,scopeId,path,offset,replaces?}`；
  连接器 → 中转 `fsGetAck{size?,version?}`、`fsGetChunk{data,eof?}`、`fsGetEnd`、`fsErr`。
* **bid 由中转现铸**：请求里的 `bid` 只作为 `replaces` 告诉连接器「这次替代哪一次 run」，
  不沿用；这是避免续传时新旧 run 的窗口串进同一个正文。
* `GET /files/down` → 200（或带 `Range` / `offset` 时 206）；响应头有
  `Content-Length`（连接器报了 size 时）、`Accept-Ranges: bytes`、
  `ETag: "dsh-<version>-<total>"`、`Cache-Control: no-store`；206 另有
  `Content-Range: bytes N-(total-1)/total` 与 `X-DSH-Offset: N`。
* `Range: bytes=N-` 与查询参数 `offset=N` 都映射到连接器看到的 `offset`；`offset >= total`
  → 416 `request/offset`（不是「200 + 空正文」）。
* 连接器中途 `fsErr`：HTTP 状态已经发出，正文停在已写处；客户端拿到不完整正文后可用
  `Range` 重试补齐（用例从已收字节处续传）。**实测这一版不会主动关闭 HTTP 连接**，
  客户端要等自己的超时；Go 版提前关闭也符合「中断」语义。
* 错误路径：400 `request/incomplete` / `request/offset`；401；409 透传连接器错误码
  （如 `workspace-file/not-found`）；501 `file/unsupported`；503 `host/offline`。

### `/agents/enroll`

* 成功 → 200 `{ok, agentId: "agt_…", agentSecret: "as_…", agentName, accountId: "acc_…"}`；
  返回的 secret 立即能铸配对码并配对（用例走完整链路验证）。
* 缺 `name` → `agentName = "My computer"`；码容忍大小写与分隔符（重敲场景）。
* 400 `enroll/bad-request`（缺码、空白、非字符串）；404 `enroll/unknown|expired|used`。
* 同一个码失败 **5 次**后冻结，第 6 次 → 429 `enroll/rate-limited`；换一个没人猜过的码
  仍按 404 处理（桶按码）。
* 同一来源失败 5 次之后，**合法邀请码仍然 200**（来源桶只记账、不否决，2026-09-25 owner 决定）。

### 限流与配额

* `/pair/claim` 同一来源失败 **10 次** → 第 11 次 429 `pair/rate-limited`（300 秒窗口）；
  桶按来源（`X-Forwarded-For`）分，换来源可用；被限的来源带着合法码也进不来（先查限流）。
* 每日额度（`--device-daily-mb 0.25` = 262144 字节）以**设备**为单位：额度内正常送达；
  超限时先收到 `{t:"error", code:"quota/device-daily", details:{limitBytes:262144}}`，
  随后 socket 以 **4011** 关闭，电脑侧收到 `deviceDetach{reason:"daily quota"}`。
  同账户另一台设备不受影响。

### `/internal/*`

* `POST /internal/tokens/resolve` → 200 `{deviceId, accountId, expiresAt}`；
  400 `internal/bad-request`（缺/空/非字符串）；未知、已撤销都是 404 `internal/not-found`，
  **两者正文逐字节相同**；纯空白按未知令牌查（404），不是缺字段。
* `POST /internal/account-state/touch` → 200 `{ok, notified}`，并给同账号在线设备扇一帧
  `{"t":"accountState","keys":[…]}`；缺 `keys` 时默认 `["feedback"]`；没有在线设备时
  `notified` 为 0；缺 `accountId` → 400 `internal/bad-request`。

### 设备子协议认证

* `Sec-WebSocket-Protocol: dsh.device.<deviceToken>`（无 `Authorization` 头）可完成设备接入，
  服务端回显该子协议，首帧是 `hostStatus`。
* 子协议令牌无效 → 握手 401；子协议认证仍校验查询里的 `agentId`，不匹配 → 403。
* `Authorization` 头有效时优先于子协议（子协议乱填不影响）。
* `/healthz` 的 `capabilities` 含 `device-subprotocol-auth`。

## 未覆盖（及原因）

| 项 | 原因 |
|---|---|
| `/internal/*`、`/stats` 的非环回 404 | 环回判定用的是 socket peer；用例把中转绑在 `127.0.0.1`，客户端也来自环回，本机无法造出非环回来源。需要独立网络命名空间或真实前置，未伪造。 |
| `/files/up` 的 413 | 当前实现**没有**这条路径（流式读取绕过 `client_max_size`）；已用「33 MB 仍 200」钉住实测行为。Go 版若要加 413，先决定这是不是契约变化。 |
| 下载途中的客户端物理断线（RST/关 App） | 时序不可控，未稳定复现；已用「连接器中途报错 + 客户端超时后 Range 续传」覆盖同一用户路径。中转 `_PeerGone` 分支本身未由黑盒用例打到。 |
| 中途报错后 HTTP 连接不关闭 | 这是实测到的现状（短正文 + 连接保持），已写进用例注释；未改业务代码。是否要主动关闭留给实现方决定。 |
| 配额跨重连 / 跨重启保持（`usageDaily`） | 需要先把额度用到接近上限、断开、再重连验证基线不重置；属于使用记账的持久化语义，本批未覆盖（白盒 `test_daily_quota_persistence.py` 覆盖）。 |
| `/files/down` 的 `If-Range` 过期 ETag 重开 fetch | 契约是「文件变了就从头回整份并重开一次 `fsGetBegin`」；需要 stub 连续服务两次 begin，本批未加（白盒覆盖）。 |
| `/files/down` 的额度计费（HTTP 下载也扣配额与限速） | 需要先把设备额度压到很小，再触发下载截断；本批只覆盖了 WS 帧的额度路径，未覆盖下载路径。 |
| 反馈接口的限流（写 30 次/来源、60 次/设备、读 120 次/10 分钟） | 会写 30+ 条记录、拖长套件；且本套件自己必须留在预算内。未覆盖。 |
| 反馈的 `messagesPerThread` 上限 200、`notices:false` 开关 | 需要 200+ 条留言或专门夹具；优先级低，未覆盖。 |
| APNs 推送（`/devices/push`、`notify` 帧、`push-test`） | 黑盒夹具显式 `DLP_APNS_ENABLED=0`；真实 APNs 不可在用例里调用。 |
| WS 心跳超时、背压丢弃（4008）、限速关闭（4009）、agent 离线（4010） | 第一批 README 已列为后续批次；本批未加。设备上限 4012 已在第一批覆盖。 |
| 慢客户端 / 背压（4008） | 需要把读取方卡在内核发送缓冲或让它停住，时序不可控，本机没有稳定构造方法；按设计文档“不硬造”留给后续批次。 |
| 2 小时 soak、磁盘满 / 只读库 | 需要长时间计时或破坏文件系统，均不在单条 10 秒的套件预算内；soak 属于 L3 的单独执行项。 |
| 1000 设备、1 / 50 帧/秒、1 / 8 / 32 MB 大帧 | 设计文档 L2 的完整矩阵；基线脚本当前只覆盖 100 与 300 设备、10 帧/秒、小帧。 |
| 跨机器网络与前置换（Caddy） | 本机回环不经过 TLS 终止与公网，延迟与连接上限不可比；以线上 24 小时观察补足。 |

## 已知缺陷探针

`test_scenarios_account_state.py::test_concurrent_account_state_traffic_is_answered_without_5xx`
是并发 GET/PUT 探针（16 个并发任务 × 12 轮）。当前 Python 版在并发读写同一账户状态时
会偶发 500（共享 SQLite 连接，线上三天 8 次），所以该用例标了
`pytest.mark.xfail(strict=False)`：

* 缺陷仍在 → `xfailed`，套件保持绿；
* 缺陷没能在这一轮复现（它是概率性的），或 Go 版已修好 → `XPASS`，同样不红。

第三批把触发面量化了：`bench.py` 用 16 并发 GET 打 5 秒，三次分别出现
1017 / 1057 / 1071 个 500（约 3.4%），响应体是 aiohttp 的默认 500 页（不是 JSON 错误信封），
服务端日志是 `sqlite3.InterfaceError: bad parameter or other API misuse`。
同一条未加锁连接也被 `/pair/code` 的 `count_paired_devices` 用到，因此并发配对同样会 500
（准备 50 台设备时实测到两次）。这两条都只记录、不在套件里当门槛。

每次运行结束会打出一行实际数字（`-q` 下也可见）：

```
------------------------------------ 黑盒探针 -------------------------------------
16 并发任务 × 12 轮：状态码 {200: 375, 500: 8}，5xx/异常 8 次
```

要连原因一起看：`pytest tests/blackbox -q -rxX`。

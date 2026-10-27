# DSH Link Protocol (DLP) v1

> 面向：实现者与自建中转的部署方 · 状态：stable（DLP v1） · 最近核对：2026-10-27

规范版本：`1`
状态：stable（已按本规范实现 relay-go / agent / iOS 客户端）

DLP 解决的核心问题：**电脑端 DSH 没有公网 IP**。电脑侧连接器（agent）主动外连中转服务器，
手机（device）也连中转服务器，由中转按 `agentId` 配对并转发帧。

设计目标：

1. **不重新定义 DSH 语义**。DLP 只是 DSH 原生协议（HTTP `/api/<method>` + WS `/api/remote.mux`）
   的**多路复用隧道**。转发层不认识 session、不解析事件，因此 DSH 升级不会破坏 DLP。
2. **单连接多路复用**。手机与电脑之间只有一条 WSS，承载全部一元 RPC、全部逻辑流、以及宿主事件。
3. **多设备 / 多用户可扩展**。同一 agent 可被多台设备连接；中转按账号隔离，为后续上架预留。

---

## 1. 拓扑

```
 iOS App (device)                Relay (公网)                 PC (agent)
      │                              │                            │
      │  WSS /link/device            │       WSS /link/agent      │
      ├─────────────────────────────►│◄───────────────────────────┤
      │  Bearer <deviceToken>        │      Bearer <agentToken>   │
      │                              │                            │
      │                              │                     ┌──────┴───────┐
      │                              │                     │ dsh web      │
      │                              │                     │ 127.0.0.1:P  │
      │                              │                     └──────────────┘
```

Relay 只做两件事：**鉴权**与**按 `agentId` 转发**。它不解析 DLP 之外的任何 DSH 语义。

---

## 2. 端点

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET`  | `/healthz` | 健康检查，返回 `{"ok":true,"version":1,"relayVersion":"go-0.2.3"}`；`version` 是**协议版本**，`relayVersion` 是这次部署的版本（语义化 `go-X.Y.Z`），`build` 另带 commit 与部署时刻 |
| `GET`  | `/stats` | **运维侧**实时负载与流量（不属于协议，见 §5.3）；**仅回环可达**（回环校验 + 网关显式拒绝，两半缺一不可） |
| `WS`   | `/link/agent?agentId=<id>` | 电脑侧连接器接入；`Authorization: Bearer <agentToken>` |
| `WS`   | `/link/device?agentId=<id>` | 手机侧接入；`Authorization: Bearer <deviceToken>`；浏览器客户端可在 `Sec-WebSocket-Protocol` 里携带 `dsh.device.<deviceToken>`（头优先，子协议仅在无头时生效；握手响应显式回显该子协议） |
| `POST` | `/pair/claim` | 手机用配对码换取 `deviceToken` |
| `POST` | `/pair/refresh` | 刷新 `deviceToken`（长期使用） |
| `POST` | `/pair/code` | 电脑侧用 agent secret 铸配对码；**不带 `ttlMs`（或给 `null`）= 持久码**（不过期） |
| `POST` | `/pair/code/regenerate` | 用户点「重新生成」：作废该电脑现存的所有码并铸一枚新的（**不影响已配对设备**） |
| `GET` | `/account/state` | 读调用方账户的状态条目（设备令牌鉴权；`?keys=a,b` 取子集） |
| `PUT` | `/account/state` | 写账户状态（只前进不后退），成功后给同账户其他在线设备发一帧 `accountState` |
| `POST` | `/internal/account-state/touch` | **仅回环**：信件服务已读落库后，让中转替它向同账户设备扇一声"去看看信件" |
| `POST` | `/dsh-link/feedback/{submit,inbox,append,read,notice}` | 信件端点，由**独立信件服务**（非中转）应答，见 §2.3 |
| `POST` | `/agents/enroll` | 用邀请码自助登记，换 `agentId` / `agentSecret` |
| `GET`  | `/devices` | 用 device token 列出**自己的**配对设备 |
| `POST` | `/devices/revoke` | 用 device token 撤销自己的某台配对设备 |
| `OPTIONS` | `*` | CORS 预检 |

`agentId` 也允许放在首帧 `hello` 中；query 参数优先。

文件传输走 `PUT /files/up` 与 `GET /files/down`（`Range` 与 `If-Range` 续传）：两者都在 CORS 放行
范围内，下载的 200/206 **正文响应**自带 `access-control-allow-origin: *` 与
`access-control-expose-headers: content-range, etag`。预检（`OPTIONS`）通过不代表正文可读，理由与
实现位置见 [`RELAY-NOTES.md`](RELAY-NOTES.md) 第 16 条。

### 2.1 `/pair/claim`

请求：

```json
{ "pairCode": "7F3K-9Q2M", "deviceName": "Example iPhone", "deviceModel": "iPhone17,1",
  "appVersion": "1.0.0", "deviceKey": "9f2c…（可选，同一台 client 的持久标识）" }
```

响应 `200`：

```json
{ "ok": true, "agentId": "agt_...", "deviceToken": "dt_...", "accountId": "acc_...",
  "agentName": "Example 的 MacBook Pro", "expiresAt": 1790000000000, "reused": false }
```

失败：`{"ok":false,"error":{"code":"pair/invalid-code","message":"..."}}`

`error.code` 区分几种失败（**除限额是 `409`，其余都是 `404`**），因为下一步动作不同：

| `error.code` | HTTP | 含义 | 该做什么 |
|---|---|---|---|
| `pair/invalid-code` | 404 | 没有这张码（打错，或早于判定窗口） | 核对屏幕上的码 |
| `pair/expired-code` | 404 | 限时码过了有效期 | 重新生成一张 |
| `pair/revoked-code` | 404 | 这张码被「重新生成」顶掉了 | 看屏幕上现在那张 |
| `limit/devices` | 409 | 该账户已配对的 client 到上限（默认 8） | 到设置里删掉一台再用；`details` 带 `maxPairedDevices` / `pairedDevices` |

判定「过期 / 作废」要逐行核对最近两小时内的码，因此超出这个窗口的码一律按
`pair/invalid-code` 回答；判定失败同样计入限流桶。

- **配对码可以反复认领**：持久码（`/pair/code` 不带 `ttlMs`、或给 `null` 铸出来的那种）一直有效，
  直到用户点「重新生成」。带 `ttlMs` 的限时码（老连接器走这条路）语义与以前一致。
- **一个账户最多 8 台已配对的 client**（含 Web，`DLP_MAX_PAIRED_DEVICES`）。上限在**认领**处拦，
  与「同时连接数」上限（`DLP_MAX_DEVICES_PER_AGENT`）是两层。
- **`deviceKey`**：同一台 client 的持久标识（iOS 放钥匙串、Web 放 localStorage）。带了它并命中一台
  未撤销的设备，就复用那台的 `deviceId`、只换发新 token，响应里 `reused: true`——重装/换机不占新名额。
  格式非法按「没带」处理（不因一个坏字段拒绝整次认领）。
- **重新生成不影响已连接的设备**：`/pair/code/regenerate` 只把旧码置为作废；设备靠各自的
  `deviceToken` 活着，要下线一台走 `POST /devices/revoke`。
- `deviceToken` 长期有效（默认 365 天），并随 `/pair/refresh` 轮换。

### 2.1b `/account/state` 与 `accountState` 帧

账户级状态是"一台设备改了、同账户其他设备要跟着变"的那几项（032）：会话已读水位、
角标水位、提醒开关、待回应已回答。**中转不解释值**，只做两件事：按 `(accountId, key)` 存取，
以及保证 `updatedAt` 单调。

读：

```http
GET /account/state?keys=alertPrefs,badgeWatermark     Authorization: Bearer <deviceToken>
```

```json
{ "ok": true, "accountId": "acc_...",
  "entries": { "alertPrefs": { "value": { "turnEnd": true }, "updatedAt": 1790000000000,
                               "updatedByDeviceId": "dev_..." } } }
```

写：

```http
PUT /account/state     Authorization: Bearer <deviceToken>
{ "entries": [ { "key": "sessionRead.agt_x", "value": { "sess_a": 42 }, "updatedAt": 1790000000000 } ] }
```

- **只前进不后退**：来件的 `updatedAt` 不大于已存的就拒收（`applied` 里不出现该 key），
  返回已存的那份。这条规则是为了让"旧设备晚到一步"盖不掉新状态；相等按幂等处理。
- **合并在写入方**：例如已读水位取 `max`、开关后写覆盖。中转只看时间戳。
- 上限：一次最多 64 条，单条值序列化后最多 8 KiB（超了回 `413 account-state/too-large`）。
- 写入成功后，中转给**同账户其他在线设备**各发一帧（写入者自己不收）：

```json
{ "t": "accountState", "keys": ["sessionRead.agt_x"] }
```

这帧是**尽力而为**：不入队、不重试、不确认；收不到的一方靠前台拉取兜底。
不认识这帧的旧客户端按"未知帧"忽略即可（与 DLP 既有约定一致）。

### 2.2 鉴权失败

WS 升级阶段失败直接回 HTTP `401` / `403`（不进入 WS 状态机）。
两条凭据通道的优先级：`Authorization: Bearer` 头存在且格式正确时一律以头为准、完全忽略子协议；头缺失时子协议缺失/前缀不符/后缀为空/令牌无效均回 401，文案与既有通道一致。令牌字符必须是合法 token 字符（当前 `token_urlsafe` 产物只含 `A-Za-z0-9-_`）。
进入 WS 后鉴权失败回 `{"t":"error","code":"auth/...","fatal":true}` 并关闭。

### 2.3 信件端点（信件服务）

信件（用户反馈线程 + 通知收件箱）由独立服务提供：网关把 `/dsh-link/feedback/*` 剥掉
`/dsh-link` 前缀后转到信件服务，公网路径与拆分前一致。以下五个端点都是
`POST`，请求与响应均为 JSON，`Authorization: Bearer <deviceToken>` 可选
（缺省或无效即匿名，不是 401）。

| 路径 | 语义 | 鉴权 |
|---|---|---|
| `/feedback/submit` | 新建一条线程，返回一次性取件凭据 `ticketKey`（库里只存 SHA-256） | 可选令牌；`clientRef` 幂等 |
| `/feedback/inbox` | 拉取线程与通知；**只读**，不改已读 | 凭据对 + 设备/账号归属 |
| `/feedback/append` | 在线程里补一句（异步留言，不是即时对话） | 取件凭据、设备归属、或团队侧 |
| `/feedback/read` | 标记已读（线程按侧、通知按账号） | 同上 |
| `/feedback/notice` | 取一条通知的正文（v2 列表不再内联正文） | 只按 `(accountId, noticeId)` 投递 |

**授权失败一律同一条 404** `{"ok":false,"error":{"code":"feedback/not-found"}}`：
匿名、线程/通知不存在、凭据不匹配、这个账号没有该投递，四者响应的状态码与字节完全相同，
不泄露"它是否存在"。写入路径另有按来源（以及按设备）的限流桶，超限回
`429 feedback/rate-limited`；读取（`inbox`/`read`/`notice`）共用更宽的一只桶。

#### 2.3.1 收件箱的两个版本

形状只由请求显式声明，不按客户端版本嗅探：

- 不带 `inboxVersion`（老客户端）= **v1**：线程不设窗口（可见多少给多少）、
  通知最多 200 条且无游标、正文内联、`unread` 与 `teamUnread` 双口径并列。
  字段名、语义、错误码与拆分前逐字一致（`unread` = 团队发出的留言里收件方还没读的
  条数，`teamUnread` = 收件方写的留言里团队还没读的条数；团队自有信的
  `teamUnread` 恒为 0）。
- 带 `"inboxVersion": 2` = **v2**：摘要 + 游标 + 每线程一个视角。响应回显
  `"inboxVersion": 2`；客户端据此选定语义分支，两个分支不混读。

v2 请求（追加字段，老字段含义不变）：

```json
{ "inboxVersion": 2,
  "tickets": [{"threadId": "th_…", "ticketKey": "fk_…"}],
  "messagesPerThread": 6,
  "notices": true,
  "threadsPage": {"limit": 30, "before": {"lastMessageAt": 1793063836987, "threadId": "th_…"}},
  "noticePage":  {"limit": 40, "before": {"createdAt": 1793063836987, "noticeId": "nt_…"}} }
```

`before` 缺省即第一页；`limit` 缺省 30（线程）/ 40（通知），区间 `1..100`，
越界回 `400 feedback/bad-request`。`messagesPerThread` v2 缺省 6、上限 200。

v2 响应：

```json
{ "ok": true, "inboxVersion": 2, "teamPerspective": true,
  "threads": [{"threadId": "th_…", "subject": "…", "status": "replied",
               "createdAt": 0, "lastMessageAt": 0, "mySide": "owner", "unread": 0,
               "source": {"kind": "device", "deviceModel": "iPhone12,1",
                          "appVersion": "…", "systemVersion": "…", "accountHint": "acc_…"},
               "messages": []}],
  "threadsPage": {"more": true, "nextBefore": {"lastMessageAt": 0, "threadId": "th_…"}},
  "notices": [{"noticeId": "nt_…", "subject": "…", "format": "html",
               "createdAt": 0, "read": false}],
  "noticesPage": {"more": true, "nextBefore": {"createdAt": 0, "noticeId": "nt_…"}},
  "unreadCount": 3,
  "limits": {"textChars": 4000, "textBytes": 12000, "subjectChars": 80,
             "maxTicketPairs": 200, "messagesPerThread": 6,
             "threadPageSize": 30, "noticePageSize": 40} }
```

v2 不再下发 `body`（走 `/feedback/notice`）、`teamUnread` 与 `source.teamBound`。

#### 2.3.2 视角、未读与计数的所有者

- **`mySide`（每线程一个事实）**：`"owner"` 仅当调用方是团队账号、且这条线程是
  "写给团队的用户来信"（不是团队自己写的、也不是测试机型）；其余情形一律 `"user"`。
  客户端只用它决定两栏方向、未读归哪一侧、回信入口，不再按账号级布尔去推断。
- **每线程两个原始未读计数**：`ownerUnread` = 团队发出的留言里收件方还没读的条数；
  `userUnread` = 收件方写的留言里团队还没读的条数。两者来自同一次分组查询，不出网。
- **v1 的 `unread` / `teamUnread` 是这两个原始计数的兼容视图**，语义与拆分前一致：
  `unread` = `ownerUnread`、`teamUnread` = `userUnread`；只有团队**自有信**的
  `teamUnread` 归 0（P0-2 的修复：角标不再把团队自己的提交算成来信）。
- **v2 的 `unread`（每线程一个数）**：调用方**自己这一侧**还没读的条数——
  `mySide="owner"` 取 `userUnread`，否则取 `ownerUnread`。v2 不下发 `teamUnread`。
- **`unreadCount`（一个响应一个数）**：Σ 每条**可见**线程"我这一侧"的未读（按 `mySide`
  取侧，不是把每线程的 `unread` 字段相加——v1 的 `unread` 是兼容视图）+ 该账号未读通知数
  （SQL 聚合，与通知窗口无关）。`notices:false` 也照算。v1 与 v2 用同一次计算，因此
  同一次请求的 `unreadCount` 与 `feedback/read` 回包永远是同一个数；旧实现的"对 200 条
  窗口求和"已删除，窗口外的未读不再被截断。

#### 2.3.3 游标与翻页

两条列表共用一套"幂等键倒序 + 多取一条判 `more`"：

- 线程：`(lastMessageAt DESC, threadId DESC)`；`lastMessageAt` 会因新回信**前移**，
  所以翻页可能把同一条线程返回两次（不会漏，因为键只增不减）。客户端按 `threadId` 去重。
- 通知：`(createdAt DESC, noticeId DESC)`；`createdAt` 不可变。
- `nextBefore` 取本页最后一条的键；`more=false` 时没有下一页。

**两路各自独立，未声明的那一路按第一页返回**：每次 `inbox` 响应总是带两路的第一页
（除非该路被请求关掉，如 `notices:false`）。客户端翻页时只在请求里写要推进的那一路
（`threadsPage` 或 `noticePage`），被省掉的那一路按第一页返回，**属预期**——不是
"回退了"，也不需要客户端合并时特殊处理（同一 id 以本次响应为准）。因此单次响应的
体积按"一路的一页 + 另一路的第一页"计：线程首页约 30 条 × 6 条留言（约 30 KB）+
通知首页 40 条摘要（约 7 KB），仍在 §2.1 的 128 KB 预算内。服务端**不**提供
"只取这一路"的开关：两路首页对齐是客户端每次刷新都能看到的同一份事实，
加开关会让"某一路停在旧位置"变成一个新的状态。

#### 2.3.4 正文与请求体的上限

正文两条判定同时生效：4000 字符且 12000 字节（传输时必须发原始 UTF-8；
把非 ASCII 转义成 `\uXXXX` 会让每个字符变成 6 字节，先撞上请求体上限得到 413）。
超限回 `400 feedback/too-long`。

请求体上限 40 KB（`413 feedback/too-large`）。它与凭据条数、单对字节数是一个
**耦合三元组**：`maxTicketPairs` 200 对按真实形状是 20,413 B；只把条数从 50 抬到 200
而不同时抬体上限，整个收件箱会从 400 变成 413 而照样打不开。

#### 2.3.5 v1 投影的退出条件

v1 与 v2 是**同一批行的两种投影**，没有第二份存储、也没有第二套未读算法。删除 v1
分支的条件写死如下：中转 `devices` 表里 `appVersion` 低于新构建的未撤销设备数为 0，
且发布方书面确认最低支持版本。届时删除 v1 投影分支，并同步删除只服务 v1 的
`source.teamBound` 与 `teamUnread` 两个字段。

---

## 3. 帧格式

- 传输：WebSocket **文本帧**，UTF-8 JSON 对象。
- 每条帧必须有 `t`（string）。
- 未知 `t` **必须忽略**（前向兼容）。
- 二进制帧保留给附件传输（v2）。

### 3.1 device → agent

| `t` | 字段 | 语义 |
|---|---|---|
| `req` | `id`, `method`, `args` | 一元 RPC。`method` 为 DSH 端点名（如 `session/list`），`args` 为 DSH 命名字段对象 |
| `open` | `id`, `endpoint`, `args` | 打开逻辑流（如 `session/follow`、`$events`） |
| `cancel` | `id` | 取消逻辑流 |
| `eventResult` | `id`, `result` | 回应宿主 `$events/result`（waterfall 应答） |
| `ping` | `ts` | 心跳，agent 回 `pong` |
| `hello` | `agentId`? | **v1 保留，当前两端都不发**：`agentId` 走 query 参数（query 优先）。声明在表里只为前向兼容，三端都不得依赖它 |

### 3.2 agent → device

| `t` | 字段 | 语义 |
|---|---|---|
| `res` | `id`, `ok`, `value`? / `error`? | 一元 RPC 响应 |
| `item` | `id`, `value` | 逻辑流数据项 |
| `end` | `id` | 逻辑流正常结束 |
| `streamError` | `id`, `error` | 逻辑流失败 |
| `event` | `value` | 宿主事件（来自 `$events` 流） |
| `hostStatus` | `info` | agent/DSH 状态变化（上线、离线、版本、工作区）。版本三项：连接器发的 `version`（连接器版本）与 `hostVersion`（宿主 DSH 版本），中转发的 `relayVersion`（中转版本）；都只在控制帧上出现，不随业务帧重复 |
| `pong` | `ts` | 心跳回应 |
| `error` | `code`, `message`, `fatal`? | 协议级错误 |

`id` 为 device 生成的字符串，唯一标识一次 RPC 或一条逻辑流。agent 必须原样回填。

`error` 对象统一为 `{"code":string,"message":string,"details":object}`，与 DSH 的失败形状一致。

**机器可读的唯一事实来源是 [`relay-contract.json`](relay-contract.json)**：上面两张帧类型表、
`id` 帧集合、默认错误码、关闭码与 `hostStatus.info` 的字段清单都在那里，两端各有测试读它
（连接器 `plugins/mobile-link/test/dlp-contract.test.js`、iOS
`DSHKit/Tests/DSHKitTests/DLPContractTests.swift`）；中转侧的帧实现由
`relay-go/internal/dlp` 的用例覆盖。它同时**记录已知漂移**（心跳三套、
校验不对称、错误码两套、`hostStatus.info` 字段不一致、只有 iOS 做分片重组）——那些是记账，
不是认可。改动帧协议时改那份文件，不要改本文的表格了事。

### 3.3 示例

手机列出会话：

```json
{"t":"req","id":"1","method":"session/list","args":{"_request":{}}}
```
```json
{"t":"res","id":"1","ok":true,"value":{"items":[...]}}
```

手机订阅某会话实时事件：

```json
{"t":"open","id":"2","endpoint":"session/follow","args":{"request":{"agentId":"session-...","afterSeq":3883}}}
```
```json
{"t":"item","id":"2","value":{"type":"event","event":{...}}}
{"t":"item","id":"2","value":{"type":"assistant-stream","frame":{...}}}
```

手机回答宿主的交互提问：

```json
{"t":"eventResult","id":"3","result":{"clientId":"ae3f...","eventId":"5e51...","outcome":{"kind":"result","value":{"answers":[...]}}}}
```

### 3.4 agent 侧控制帧

上面两张表是**设备与 agent 之间的 DLP**。还有第三类帧：**agent → relay 的控制帧**，
由中转自己消费，**不跨到设备**——手机既不发送也不接收它们（所以不在
`deviceToAgent`/`agentToDevice` 两张表里，iOS 那侧也不认识它们）。

| `t` | 字段 | 语义 |
|---|---|---|
| `notify` | `kind`, `sid`, `eid`? | 「这台电脑上有事发生」：`kind` 为 `turnEnd`（一轮跑完了）或 `attention`（有提问/审批在等人）；`sid` 是会话语义标识，`eid` 仅 `attention` 带。**不带 `deviceId`**——连接器不知道、也不需要知道这台电脑配了哪些手机 |
| `fsPutBegin` / `fsPutChunk` / `fsPutEnd` | `deviceId`, `bid`, `seq`, `data`, … | 后台上传的桥接：中转的 `PUT /files/up` 把手机传来的字节泵给连接器，连接器落进 `~/.dsh/inbox/<sessionId>/`。分片**不回 ack**（流水线） |
| `fsPutAck` / `fsPutDone` | `bid`, `received` / `path`, `bytes` | 上行的两个同步点。**不带 `deviceId`**：中转靠 `bid` 把它对回那条 HTTP 请求 |
| `fsGetBegin` | `deviceId`, `bid`, `scopeId`, `path`, `offset` | 后台下载的桥接：中转的 `GET /files/down` 要连接器去读 host。`offset` 来自请求的 `Range: bytes=N-`，**这是续传能成立的唯一依据** |
| `fsGetChunk` | `bid`, `data`（base64）, `eof` | 一片下载数据；中转**边收边写进 HTTP 响应体**，不落盘 |
| `fsGetAck` / `fsGetEnd` | `bid` | 下行的两个同步点，同样**不带 `deviceId`** |
| `fsErr` | `bid`, `code`, `message` | 这一族任一步失败。`code` 是**原错误码**（如 `workspace-file/not-found`），App 靠它分辨「不该重试」与「网络抖了一下」 |
| `fsGetCancel`（中转发） | `bid` | 中转告诉连接器**停止**为这个 `bid` 继续读：读的人走了（手机挂断、日额度截断响应），而读是连接器那一侧驱动的，不叫停它就会把整个文件读完、每一片都在中转被丢掉。未知 `bid` 是空操作，所以中转可以每个死桥接都发一次而不必跟踪谁还活着 |

**`fsGetBegin` 的 `bid` 是中转自己铸的，不是 App 传来的。** 续传请求带着上一次尝试的
`bid`（它冻结在系统的 resume data 里，App 改不了），若中转照抄，同一个名字就会对应两次
不同的 run：新桥接开在旧名字上，而旧 run 已经在途、收不回来的分片会落进新桥接——正文被
截到声明的长度，于是**大小对、内容错**，还会被按版本缓存下来。铸新 id 从根上去掉这个碰撞：
App 传来的那个 id 中转**丢弃、不建别名**——别名会把碰撞原样装回去，那正是旧 run 的在途分片
还在用的名字。它只转成 `fsGetBegin.replaces` 交给连接器，用途是说明「这次取代的是哪个 run」：
连接器据此停掉那个仍在读的旧 run，否则它会一直读到新 `fsGetBegin` 抵达为止，而那批分片正是
中转收不回来的。`replaces` 是建议性的，连接器不认得这个名字就什么都不做，所以不发这个字段的
老中转能与新连接器并存。

上传与下载这两族由中转的两个 HTTP 入口驱动，**relay 全程不落盘**：字节只在中转的内存里过
一手，落点是连接器（上行）或手机的响应体（下行）。下行必须走**设备自己的**限速与日额度桶
——否则新通道就成了绕过它们的一条后门。

`notify` 的用法（R-1）：连接器在 `$events` 上认出这两类事件就发一条。中转手里有「这台设备
此刻在不在线」——**在线就不推**（App 自己会弹本地通知，再推就是重复），不在线才转成一条
APNs 提醒。所以它是一条**尽力而为**的帧：中转没连上就丢掉、不重试；`attention` 侧另有
待答记账，手机回来会补发。

**加新帧时注意**：这类 agent 侧控制帧登记进 `relay-contract.json` 的 `agentControl`（与
`relayControl` 并列）。**绝不能**加进 `deviceToAgent` / `agentToDevice`——iOS 的
`DLPContractTests` 对那两张表做双向全等断言，加进去会让 iOS 契约测试直接红。

---

## 4. agent 行为规范

### 4.1 与本地 DSH 的对接

1. **发现端点**：按顺序取候选——显式配置 → **宿主进程内注入**（`ctx.inject(['webServer',
   'connection'])` 拿 `authenticatedUrl`）→ `DSH_WEB_URL` → 兜底 `http://127.0.0.1:54499`；
   **认证成功的那一个才算命中**。token 每次宿主启动都会变，**每次重连都要重新解析**，不得缓存。
   连接器另外把带令牌地址写进 `$DSH_HOME/mobile-link/endpoint.json`（0600）供宿主进程之外的工具读取，
   但**自己不读回它**。
2. **认证换取**：`GET <base>/?token=<token>`，**不要跟随重定向**，从 `Set-Cookie` 取
   `dsh-auth-*`，后续所有请求带该 Cookie。token 失效（401）时重新解析一次并重试。
   - 注意：DSH 的认证 Cookie **绑定 authority（host:port）**，因此 agent 必须始终以
     `127.0.0.1:<port>` 这个 authority 访问，不得改写 Host。
3. **一元 RPC**：`POST <base>/api/<method>`，
   body `{"type":"client-request","rpcId":"<id>","method":"<method>","payload":{"args":<args>}}`，
   响应 `{"type":"server-response","rpcId":"<id>","result":{"ok":true,"value":...}|{"ok":false,"error":{...}}}`。
   agent 把 `result` 直接映射为 DLP 的 `res`。
4. **逻辑流**：agent 维护**一条**到 `<ws-base>/api/remote.mux` 的 WebSocket，承载所有设备的
   所有逻辑流。device 的 `id` ↔ mux `streamId` 一一映射。
   - 打开：`{"type":"open","streamId":"<muxId>","endpoint":"<endpoint>","payload":{"args":<args>}}`
   - 上行收到 `item`/`error`/`end` 后转成对应 DLP 帧。
   - 设备 `cancel` → 发 `{"type":"cancel","streamId":"<muxId>"}`。
5. **宿主事件**：agent 在 mux 上额外打开 `$events`（`{"args":{}}`），把每条 `item` 以
   `{"t":"event","value":<item>}` 广播给**所有已连接设备**。
   其中 `ready` 帧携带 `clientId`，**每个 device 需要自己的 clientId**：
   `$events/result` 的 `clientId` 必须与开启该流时收到的 `ready.clientId` 一致。
   → 因此 agent 为**每个 device** 单独打开一条 `$events` 流。
6. **waterfall 去重**：同一个 `eventId` 的 waterfall 会推给多台设备。**首答生效**，
   其余丢弃（agent 按 `eventId` 记录已答集合，TTL 清理）。

### 4.2 可靠性

- 心跳：device 每 20s 发 `ping`；agent 每 20s 也主动 `ping` relay。`pong` 超时 60s 判定断线。
- 重连：指数退避 `1s → 2s → 4s ... 上限 30s`，加 ±20% 抖动。
- device 断开时，agent 必须 `cancel` 该 device 拥有的全部逻辑流，避免泄漏。
- agent 重启后 `agentId`/`agentToken` 保持不变（持久化到 `$DSH_HOME/mobile-link/agent.json`）。

---

## 5. relay 行为规范

- 维护 `agentId → agentConnection` 注册表；同一 `agentId` 重复接入时**新连接顶掉旧连接**。
- device 连上时若 agent 不在线，回 `{"t":"hostStatus","info":{"online":false}}`，
  并在 agent 上线时补发 `{"t":"hostStatus","info":{"online":true,...}}`。device 无需轮询。
- 转发时**保留原帧**，不改写 `id`。
- 帧大小上限 32 MiB（对齐 DSH 的图片附件上限）。
- 单 device 未确认帧上限（背压）512 条，超限断开防止内存膨胀。
- device 断开：通知 agent 清理该 device 的流。

### 5.1 共享带宽下的三种限制（可选，默认全关）

中转通常部署在**固定带宽**的主机上，而那条带宽由所有设备共享。以下三项由运维按主机
带宽开启，**协议本身不要求它们存在**；device 与 agent 都必须能容忍它们生效：

| 限制 | 默认 | 生效时的可观测行为 |
|---|---|---|
| 单设备出口限速 | 关 | 设备**不会掉帧**，只是收得慢：relay 在写侧限速，必要时把一个大帧拆成多条 WebSocket 消息。**WebSocket 消息不是字节流**：relay 会把超过阈值的大帧拆开发，**客户端必须自己重组**（iOS 见 `DSHKit/FrameAssembler.swift`，连接器与未来的客户端同样必须），否则会把第一片当畸形 JSON 丢掉、把余下的当垃圾，背后的调用永远不返回 |
| 单设备每日（服务器本地日）出口额度 | 关 | 计数按 `(deviceId, 本地日)` 从 `usageDaily` 读，**重连与 relay 重启都不会重置**。超额时先收到 `{"t":"error","code":"quota/device-daily","details":{"limitBytes":N}}`，随后连接以 **4011** 关闭；次日本地零点后可重新连接 |
| 每 agent 设备数上限 | 关 | 超出时 device 收到 `{"t":"error","code":"limit/devices","fatal":true}`（DLP `error` 帧，不是 HTTP 403），随后以 **4012** 干净关闭。**同一 deviceId 的重连不占第二个名额**，所以手机不会把自己锁在外面 |

relay 的关闭码（应用区间）：

| 码 | 含义 |
|---|---|
| `4001` | 同一 `agentId` 的新连接顶掉了旧的 |
| `4008` | 背压：该 device 未取走的帧超过 512 条 |
| `4009` | 保留：限速相关的断开（当前实现用限速而非断开，故未使用） |
| `4010` | agent 不在线或已饱和 |
| `4011` | 单设备每日额度用尽 |
| `4012` | 该 agent 的设备数已达上限（同意升级后立刻以此码关闭，先发 `error` 帧） |

### 5.2 限流与信任边界

relay 的两个开放端点（`/pair/claim`、`/agents/enroll`）都按**客户端标识**限流。这个标识
怎么算出来，是 relay 唯一的信任边界，规则只有一条：

> **只有来源是回环地址时，才采信 `X-Forwarded-For`；否则一律用 TCP 对端地址。**

具体地（实现见 `relay-go/internal/httpapi/auth.go` 的 `isLoopback` 与 `ClientIdentifier`，**只有这一处**）：

| 对端（`request.remote`） | `X-Forwarded-For` | 用作限流键的地址 |
|---|---|---|
| 回环 且 头里有可用地址 | `A, B` | **`A`**（最左一个；在替换语义下它就是唯一那一个） |
| 回环 且 头缺失/为空 | — | 对端地址（此时就是网关，等于全网一个桶） |
| 非回环 | 任意（可伪造） | **对端地址**；头**完全忽略** |

为什么必须是这个方向：请求头是调用方可以自己写的。若对非回环来源也采信它，任何人只要发一个
`X-Forwarded-For: <别人的地址>` 就能把失败次数记到别人头上——既躲开自己的额度，又能把别人
锁在门外。反过来（少采信一次）最坏只是分桶变粗，不会变成绕过，所以宁可保守。

**部署方的义务**：网关**必须**把真实来源写进 `X-Forwarded-For`（`relay-go/deploy/Caddyfile.snippet`
已经加了 `header_up X-Forwarded-For {remote_host}`）。Caddy 用 `header_up` 把这个头
**替换**成真实对端地址（实测 v2.11.4；**不是**追加）——所以客户端自带的值得不到利用。
缺了它也不会造成绕过——relay 会退回用对端地址，也就是**所有调用方共用一个限流桶**：
一个人打满，别人一起被限。**若换成会追加的网关**，就必须把取值改成取**最后一个**
（或改用 `X-Real-IP`），否则可被伪造；当前实现取最左（`relay-go/internal/httpapi/auth.go` 的
`ClientIdentifier`）只对替换语义安全。

两个端点的桶：

- `/pair/claim`：按客户端标识分桶，10 次失败 / 5 分钟（阈值是产品参数，不随部署变）。桶满即
  返回 `429`，一次成功认领清空该桶。
- `/agents/enroll`：**两个桶都在记账，但只有邀请码那个桶拦人**——按邀请码哈希一个，按客户端
  标识一个，各 5 次失败 / 15 分钟。

  - **邀请码桶**是准入闸门：同一个码被猜错 5 次后，此后凡是再提交这个码一律 `429`，不论来源。
  - **客户端桶**是失败来源的记录：它把这台来源的每一次失败累计下来（运维可查，用于观察谁在
    猜），但**不否决一个有效邀请码**。

  这是 2026-09-25 owner 定下的口径：**有效邀请码是准入通过的充分条件**。邀请码是运营方主动
  决定放人的凭据，一段失败历史是「值得盯」，不是「可以推翻这个决定」；因此一个来源先失败 5 次
  之后再拿到有效码，照样放行。

  **这个口径的代价要写清楚：客户端桶记账，但不拦人。** 它挡不住「换码继续猜」——真正拦人的是
  **每个码自己的 5 次额度**：同一个码被猜错 5 次后，此后凡提交这个码一律 429，与来源无关；
  换一个码就等于换一份新额度，所以同一来源对一批全新的未知码可以一直猜下去（实测：被记账
  10 次以上的来源，对 3 个新码各猜 5 次，15 次全部 404、无一次 429）。客户端桶的价值是让运维
  看得见「谁在猜」，不是拦人。

  若需要「同一来源换码也限速」，做法是让客户端桶**只在码无效时**参与拦截；那是一个新的口径
  决定，本轮没有做。

  一次成功兑换会清空两个桶。

### 5.3 `/stats` 的对外面

`GET /stats` 给出当前 agent/设备数、生效中的限制、以及每个设备本次启动以来的出口字节数与被
限速时长。主机的网卡计数器回答不了「是哪台设备在用带宽」——它混进了 SSH 与 OTA 下载；这份
数据是 relay 自己算的。

**它只应当能从回环读到，而这由两半各自独立保证**：

1. relay 侧：handler 拒绝一切非回环来源（`is_loopback`），返回 **404**——不是 403，403 等于
   告诉探测者「这里确实有个东西」；
2. 网关侧：`relay-go/deploy/Caddyfile.snippet` 对 `/dsh-link/stats` 与 `/stats` 有**显式拒绝**，
   请求根本到不了 relay。

两半缺一不可：只有第 2 条时，一旦站点多了一条通往 relay 的路由、或 relay 换到非回环监听，
页面立刻就公开了；只有第 1 条时，网关一旦全量转发，同样公开。页面上是设备名与各自的字节数，
不是无关紧要的数据，所以两边都留着。

**网关那半必须写成 `handle` 块，不能写成裸的 `respond @relay_stats`。** Caddy 会对指令排序，
裸 `respond` **无论写在片段哪个位置**都排在 `handle_path /dsh-link/*` 之后，于是公网请求被代理
到 relay（TCP 对端是网关自己＝回环），relay 的回环校验放行，两半同时失效、返回 200 加完整
stats 页——这正是 2026-09-28 批 1 测试抓到的 CI-01。改成 `handle` 之后，`handle` 块之间按路径
精确度排序，`/dsh-link/stats` 比 `/dsh-link/*` 更精确，所以先于代理被求值。

这条**只有真实请求能验**：`caddy adapt` 产物看着正常、片段文本看着也对，运行时照样漏。
每次改片段后都要在主机上用真请求核对（`curl -s -o /dev/null -w '%{http_code}' \
http://<本机>/dsh-link/stats` 应为 404，`/stats` 从主机环回仍为 200），不要用文本断言代替。

运维正常读它的方式是在主机上（或经 SSH）`curl -s localhost:8787/stats`；带
`Accept: text/html` 时同一份数据渲染成自刷新页面。

---

## 6. 局域网直连（历史路径，已不在产品里）

早期版本把「手机与电脑同一局域网时直连」当作优先路径（性能最好、不消耗中转流量）。
**产品上已经去掉**：只保留经公网中转一条连接方式，不给用户选（理由见 `PAIRING.md`）。
残留的实现只有一处——App 里 DEBUG-only 的 `dsh://direct` 测试通道，只给仿真器自动化用，
不出现在任何用户界面里。

这一段保留下来是因为协议层仍然支持它：`LinkCarrier` 的传输抽象不关心对端是本地 DSH
还是中转；要做局域网直连只需要另一个 carrier 实现，不需要改帧格式。

## 7. 中转侧 DSH 配置

> **本节的前提不成立，实现未采用。** 见 `RELAY-NOTES.md` §1。

本节假设 DSH 看到的 `Host` 是中转域名。实际上 agent 直接连
`127.0.0.1:<port>`，并且**不改写 `Host`**（§4.1.2 也要求如此，认证 Cookie 绑定
authority），所以 trust fence 看到的是回环地址、直接放行：

```
dsh web          # 不需要 --trusted-host
```

agent 改为在启动时校验真正要紧的三件事：重读 `endpoint.json`、完成
token → cookie 交换、失败时把原始错误写进 `GET /mobile-link/status` 的 `dsh.error`
与日志。若通过 `dshUrl` 显式指定了非回环地址，则按指定值处理。

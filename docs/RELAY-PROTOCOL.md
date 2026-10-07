# DSH Link Protocol (DLP) v1

> 面向：实现者与自建中转的部署方 · 状态：stable（DLP v1） · 最近核对：2026-09-20

规范版本：`1`
状态：draft-1（已按本规范实现 relay / agent / iOS 客户端）

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
| `GET`  | `/healthz` | 健康检查，返回 `{"ok":true,"version":1}` |
| `GET`  | `/stats` | **运维侧**实时负载与流量（不属于协议，见 §5.3）；**仅回环可达**（回环校验 + 网关显式拒绝，两半缺一不可） |
| `WS`   | `/link/agent?agentId=<id>` | 电脑侧连接器接入；`Authorization: Bearer <agentToken>` |
| `WS`   | `/link/device?agentId=<id>` | 手机侧接入；`Authorization: Bearer <deviceToken>` |
| `POST` | `/pair/claim` | 手机用配对码换取 `deviceToken` |
| `POST` | `/pair/refresh` | 刷新 `deviceToken`（长期使用） |
| `POST` | `/pair/code` | 电脑侧用 agent secret 铸一次性配对码 |
| `POST` | `/agents/enroll` | 用邀请码自助登记，换 `agentId` / `agentSecret` |
| `GET`  | `/devices` | 用 device token 列出**自己的**配对设备 |
| `POST` | `/devices/revoke` | 用 device token 撤销自己的某台配对设备 |
| `OPTIONS` | `*` | CORS 预检 |

`agentId` 也允许放在首帧 `hello` 中；query 参数优先。

### 2.1 `/pair/claim`

请求：

```json
{ "pairCode": "7F3K-9Q2M", "deviceName": "Example iPhone", "deviceModel": "iPhone17,1", "appVersion": "1.0.0" }
```

响应 `200`：

```json
{ "ok": true, "agentId": "agt_...", "deviceToken": "dt_...", "accountId": "acc_...",
  "agentName": "Example 的 MacBook Pro", "expiresAt": 1790000000000 }
```

失败：`{"ok":false,"error":{"code":"pair/invalid-code","message":"..."}}`

- 配对码一次性、有时效（默认 10 分钟），由电脑侧连接器生成并展示（二维码 / 终端）。
- `deviceToken` 长期有效（默认 365 天），并随 `/pair/refresh` 轮换。

### 2.2 鉴权失败

WS 升级阶段失败直接回 HTTP `401` / `403`（不进入 WS 状态机）。
进入 WS 后鉴权失败回 `{"t":"error","code":"auth/...","fatal":true}` 并关闭。

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
| `hostStatus` | `info` | agent/DSH 状态变化（上线、离线、版本、工作区） |
| `pong` | `ts` | 心跳回应 |
| `error` | `code`, `message`, `fatal`? | 协议级错误 |

`id` 为 device 生成的字符串，唯一标识一次 RPC 或一条逻辑流。agent 必须原样回填。

`error` 对象统一为 `{"code":string,"message":string,"details":object}`，与 DSH 的失败形状一致。

**机器可读的唯一事实来源是 [`relay-contract.json`](relay-contract.json)**：上面两张帧类型表、
`id` 帧集合、默认错误码、关闭码与 `hostStatus.info` 的字段清单都在那里，三端各有测试读它
（连接器 `plugins/mobile-link/test/dlp-contract.test.js`、relay `relay/tests/test_dlp_contract.py`、
iOS `DSHKit/Tests/DSHKitTests/DLPContractTests.swift`）。它同时**记录已知漂移**（心跳三套、
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

具体地（实现见 `relay/api.py` 的 `is_loopback` 与 `client_identifier`，**只有这一处**）：

| 对端（`request.remote`） | `X-Forwarded-For` | 用作限流键的地址 |
|---|---|---|
| 回环 且 头里有可用地址 | `A, B` | **`A`**（最左一个；在替换语义下它就是唯一那一个） |
| 回环 且 头缺失/为空 | — | 对端地址（此时就是网关，等于全网一个桶） |
| 非回环 | 任意（可伪造） | **对端地址**；头**完全忽略** |

为什么必须是这个方向：请求头是调用方可以自己写的。若对非回环来源也采信它，任何人只要发一个
`X-Forwarded-For: <别人的地址>` 就能把失败次数记到别人头上——既躲开自己的额度，又能把别人
锁在门外。反过来（少采信一次）最坏只是分桶变粗，不会变成绕过，所以宁可保守。

**部署方的义务**：网关**必须**把真实来源写进 `X-Forwarded-For`（`deploy/Caddyfile.snippet`
已经加了 `header_up X-Forwarded-For {remote_host}`）。Caddy 用 `header_up` 把这个头
**替换**成真实对端地址（实测 v2.11.4；**不是**追加）——所以客户端自带的值得不到利用。
缺了它也不会造成绕过——relay 会退回用对端地址，也就是**所有调用方共用一个限流桶**：
一个人打满，别人一起被限。**若换成会追加的网关**，就必须把取值改成取**最后一个**
（或改用 `X-Real-IP`），否则可被伪造；当前实现取最左（`relay/api.py` 的
`client_identifier`）只对替换语义安全。

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
2. 网关侧：`deploy/Caddyfile.snippet` 对 `/dsh-link/stats` 与 `/stats` 有**显式拒绝**，
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
回归测试在 `relay/tests/test_caddy_runtime.py`（真实 caddy + 真实 relay 进程 + 真实 HTTP 请求），
不要把它退化成对片段文本的正则断言。

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

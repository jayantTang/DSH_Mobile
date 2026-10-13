# Contract: 诊断事件目录（`kind` 词表）

**范围**：连接器 journal、App JSONL、诊断包合并时间线三处共用的 `kind` 词表与字段规则。
**只增**：既有 `kind` 的名称、必填字段与含义一律不变；新增 `kind` 与新增可选字段允许，老读者
**必须忽略**不认识的 `kind`（`specs/020-link-diagnostics/data-model.md` §1 校验规则 2）。

## 1. 事件信封（三种存储共用）

```json
{ "at": "2026-10-13T01:10:10.506Z", "ms": 1791825010506, "kind": "device.attach",
  "deviceId": "dev_…", "name": "iPhone", "model": "iPhone15,4" }
```

诊断包内的每一行再补 `source`（`connector` / `relay` / `app`）。`kind` 不含 `.` 以外的分隔符。

## 2. 既有 kind（本次之前就已存在，语义不变）

| kind | 关键字段 | 含义 |
|---|---|---|
| `link.start` | `configuredRelay`、`agentId`、`attempt`、`host` | 链路循环启动 |
| `link.open` | `relay`、`agentId`、`attempt`、`sinceCloseMs` | 到中转的链路建立（`relay` 是**实际**地址） |
| `link.close` | `reason`、`from`、`connectedForMs` | `socketError` | 链路被拆（`reason` 来自调用点）；`socketError` 只在 socket 报过系统错误时出现，内容是系统给的原文（判断网络/代理/对端靠它） |
| `link.backoff` | `attempt`、`delayMs` | 进入重连退避 |
| `link.failed` | `error`、`attempt` | 一次会话失败 |
| `link.unregistered` | `error` | 本机尚未登记（setup 状态，不重试） |
| `link.stop` | — | 主动停止 |
| `watchdog.repull` | `idleMs` | 看门狗发现链路循环不在了，重新拉起 |
| `watchdog.drop` | `idleMs`、`state` | 看门狗拆连接重建 |
| `dsh.ok` | `endpoint` | 本机 DSH 可达（每次链路建立后一次） |
| `dsh.unreachable` | `error`、`kind` | 本机 DSH 不可达（会让手机侧探针必然超时） |
| `device.attach` | `deviceId`、`name`、`model` | 设备接入 |
| `device.reattach` | `deviceId`、`offlineForMs`、`pending` | 断开过又连上（回头客） |
| `device.attach-again` | `deviceId`、`connectedForMs` | **同一设备在仍连接时又开了一条**（socket 重叠） |
| `device.detach` | `deviceId`、`reason` | 设备断开（`$events` 流继续替它值班） |
| `device.revoked` | `deviceId` | 设备被撤销，连接器放下它 |

## 3. 本次新增（只增）

| kind | 必填字段 | 可选字段 | 含义 |
|---|---|---|---|
| `device.phase` | `deviceId`、`phases`、`missing` | — | 一次接入的阶段耗时；在**三段全齐时**写出（握手 + 首个数据请求 + 它的响应；App 的真实顺序是先探针后握手，所以不能一见数据请求就写），到断开仍缺则补一条带 `missing` 的。未发生的阶段必须在 `missing` 里且对应值为 null。`phases.firstResponseMs` 指首个**数据请求**的响应，不含握手响应 |
| `request.slow` | `deviceId`、`method`、`elapsedMs`、`bytes` | — | 单次请求超过 `slowRequestMs` |
| `device.summary` | `deviceId`、`requests`、`slow`、`maxMs`、`p50Ms`、`p95Ms`、`top3` | — | 一次接入的耗时汇总（断开时 / 每 200 个请求一次） |
| `app.dial` | `phase` | `code`、`reason`、`attempt` | `phase` ∈ `start` / `transport-up` / `transport-closed` |
| `app.hello` | `elapsedMs` | — | 自拨号开始的握手耗时 |
| `app.first-request` | `elapsedMs`、`method` | — | 首个数据请求发出 |
| `app.first-response` | `method`、`elapsedMs`、`bytes` | — | 首个数据响应到达（它的耗时与字节） |
| `app.request` | `method`、`elapsedMs`、`bytes`、`ok` | `error` | **每一次**交互的耗时与字节（App 侧视角；环有上限兜底，最慢若干条在采集时算出来）。`ok: false` 时必须带 `error`（错误码）；`ok: true, bytes: 0` 表示成功但空响应——两者不得混淆 |
| `app.first-screen` | `elapsedMs` | — | 首屏就绪（状态机已连接，可以开始要数据） |
| `app.first-render` | `elapsedMs`、`cached` | `bytes` | 首批内容**真的画出来**的时刻（与"状态机已连接"分开）。`cached: true` 表示画的是本地缓存、新数据还没到（实测拨号后 410 ms 就触发，而首个响应在 10 秒后）——不标它会把"有缓存"读成"加载很快" |
| `app.scene` | `phase` | `cold` | `phase` ∈ `background` / `foreground`；`cold: true` 表示这次进前台是**冷启动**（进程刚从零起来），缺省/`false` 是热启动 |
| `app.push` | `count`、`sentAt` | `dropped`、`skewMs` | 本设备向连接器推送的条数（对账用）；`skewMs = 连接器收到时的本机时刻 − App 上报的 sentAt`，是手机时钟对齐的唯一来源 |
| `journal.error` | `originalKind`、`bytes`、`reason` | — | **内部**：写失败或超大条目被降级时自报（它保证"丢了什么"也留痕，而不是静默消失） |

**信封与耗时的命名规则**：`at`/`ms`/`kind` 是**信封字段**（`ms` = 时刻，写入侧的钟），
detail 里一律不许出现同名键——耗时一律叫 `elapsedMs`（或 `maxMs`/`p50Ms`/`p95Ms` 这类不会撞的名字）。
这不是洁癖：2026-10-13 之前 `request.slow`/`app.hello` 都用 `ms` 表示耗时，摊平后把事件的时刻冲掉，
时间线上那条事件会跑到 1970 年。写入侧由 `journal.js` 的 `PROTECTED_KEYS` 强制。

## 4. 中转日志行的解析契约

中转只写系统日志（纯文本），由采集工具解析成事件。解析规则按下面的**稳定片段**匹配
（不得依赖时间前缀的格式）：

| 行内稳定片段 | 解析为 | 取出的字段 |
|---|---|---|
| `device <id> (<name>) attached to agent <agentId>` | `relay.device-attach` | `deviceId`、`name`、`agentId` |
| `device <id> detached (<reason>)` | `relay.device-detach` | `deviceId`、`reason`、`agentId`（行尾的 `(agent <id>)`，见下） |
| `device <id> attached again while its previous socket is still open` | `relay.device-replaced` | `deviceId`、`agentId`（同上） |
| `device <id> closed a socket that had already been replaced` | `relay.device-superseded-close` | `deviceId`、`agentId`（同上） |
| `device <id> socket error: <text>` | `relay.pong-timeout` | `deviceId`、`error`、`agentId`（同上） |

**agentId 后缀（本次新增）**：上表后四类行的行尾可能带 ` (agent <agentId>)`。
没有它时，采集侧只能按 agentId 过滤、而那四类行本来不带 agentId，于是**别的账号的设备行会全部
混进本机诊断包**（2026-10-13 实测：111 条中转行只有 9 条是本机的）。解析器 MUST 取该后缀；
没有后缀的老行按"归属未知"处理，由采集侧用设备清单判定归属（FR-021）。
| `agent <agentId> connected (<name>)` | `relay.agent-connect` | `agentId`、`name` |
| `agent <agentId> disconnected` | `relay.agent-disconnect` | `agentId` |
| `agent <agentId> superseded by a new connection` | `relay.agent-superseded` | `agentId` |

未匹配的行**丢弃**（不猜），但采集工具必须在 `coverage.json` 里给出"读了 N 行、解析出 M 行"。

## 5. 兼容规则（硬约束）

1. 既有 `kind` 不得改名、不得改变必填字段、不得改变含义。
2. 新增 `kind` 或可选字段后，老读者必须仍能工作（忽略未知 `kind`、忽略未知字段）。
3. `kind` 词表以本文件为准；新增 `kind` 必须同时更新本文件与连接器/App 的单测。
